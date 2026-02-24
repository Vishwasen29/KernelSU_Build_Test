#!/usr/bin/env bash
# =============================================================================
# patch_susfs_symbols.sh
#
# Adds the 2 symbols missing from SUSFS v2.0.0 that both
# sidex15/KernelSU-Next and rsuntk/KernelSU require:
#
#   1. CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS  → include/linux/susfs_def.h
#   2. susfs_set_hide_sus_mnts_for_all_procs  → include/linux/susfs.h + fs/susfs.c
#
# Fix over v1: sed \& escape sequences no longer leak into generated C code.
#
# Usage:
#   ./patch_susfs_symbols.sh [KERNEL_DIR]
# =============================================================================

set -euo pipefail

KERNEL_DIR="${1:-$(pwd)}"
SUSFS_DEF_H="${KERNEL_DIR}/include/linux/susfs_def.h"
SUSFS_H="${KERNEL_DIR}/include/linux/susfs.h"
SUSFS_C="${KERNEL_DIR}/fs/susfs.c"

echo "🔍 Patching SUSFS v2.0.0 symbols under: ${KERNEL_DIR}"
echo ""

for f in "$SUSFS_DEF_H" "$SUSFS_H" "$SUSFS_C"; do
    if [ ! -f "$f" ]; then
        echo "❌ File not found: $f"
        echo "   Pass the kernel source root as the first argument."
        exit 1
    fi
done

PATCHED=0

# ── 1. CMD define in susfs_def.h ──────────────────────────────────────────────
if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" "$SUSFS_DEF_H"; then
    echo "ℹ️  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS already present — skipping."
else
    sed -i \
        's/#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS\(.*\)/#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS\1\n#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS   0x55563/' \
        "$SUSFS_DEF_H"
    echo "✅ [susfs_def.h] Added CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS (0x55563)"
    PATCHED=$((PATCHED + 1))
fi

# ── 2a. Declaration in susfs.h ────────────────────────────────────────────────
if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUSFS_H"; then
    echo "ℹ️  susfs_set_hide_sus_mnts_for_all_procs already declared — skipping."
else
    sed -i \
        's/void susfs_set_hide_sus_mnts_for_non_su_procs\(.*\);/void susfs_set_hide_sus_mnts_for_non_su_procs\1;\nvoid susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info);/' \
        "$SUSFS_H"
    echo "✅ [susfs.h]     Added susfs_set_hide_sus_mnts_for_all_procs() declaration"
    PATCHED=$((PATCHED + 1))
fi

# ── 2b. Implementation in susfs.c ─────────────────────────────────────────────
# Uses Python to write the C block directly — no shell escaping involved,
# so & and tabs land in the file exactly as written in the Python string.

if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUSFS_C"; then
    echo "ℹ️  susfs_set_hide_sus_mnts_for_all_procs already implemented — skipping."
else
    python3 << PYEOF
import sys

filepath = "${SUSFS_C}"

# The C block to insert — written as a plain Python string, no shell escaping
new_func = r"""
/* Added by patch_susfs_symbols.sh — susfs_set_hide_sus_mnts_for_all_procs */
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bool susfs_hide_sus_mnts_for_all_procs = false;

void susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info) {
	struct st_susfs_hide_sus_mnts_for_non_su_procs info = {0};

	if (copy_from_user(&info, (struct st_susfs_hide_sus_mnts_for_non_su_procs __user *)*user_info, sizeof(info))) {
		info.err = -EFAULT;
		goto out_copy_to_user;
	}
	spin_lock(&susfs_spin_lock_sus_mount);
	susfs_hide_sus_mnts_for_all_procs = info.enabled;
	spin_unlock(&susfs_spin_lock_sus_mount);
	SUSFS_LOGI("susfs_hide_sus_mnts_for_all_procs: %d\n", info.enabled);
	info.err = 0;
out_copy_to_user:
	if (copy_to_user(&((struct st_susfs_hide_sus_mnts_for_non_su_procs __user *)*user_info)->err, &info.err, sizeof(info.err))) {
		info.err = -EFAULT;
	}
	SUSFS_LOGI("CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS -> ret: %d\n", info.err);
}
#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */
"""

with open(filepath, 'r') as f:
    content = f.read()

# Find the closing #endif of susfs_set_hide_sus_mnts_for_non_su_procs block.
# Anchor: the SUSFS_LOGI for NON_SU_PROCS is unique, find the #endif after it.
anchor = 'CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS -> ret:'
anchor_pos = content.find(anchor)
if anchor_pos == -1:
    print("❌ Could not find anchor — appending to end of file")
    content += new_func
else:
    # Find the closing brace of the function after the anchor
    close_brace = content.find('\n}\n', anchor_pos)
    if close_brace == -1:
        print("❌ Could not find closing brace — appending to end of file")
        content += new_func
    else:
        # Find the #endif immediately after the closing brace
        endif_pos = content.find('#endif', close_brace)
        endif_end = content.find('\n', endif_pos) + 1
        content = content[:endif_end] + new_func + content[endif_end:]
        print(f"  Inserted after position {endif_end}")

with open(filepath, 'w') as f:
    f.write(content)
PYEOF

    echo "✅ [susfs.c]     Added susfs_set_hide_sus_mnts_for_all_procs() implementation"
    PATCHED=$((PATCHED + 1))
fi

# ── Verification ──────────────────────────────────────────────────────────────
echo ""
echo "── Verification ──────────────────────────────────────────────────────────"
ALL_OK=true

check() {
    local label="$1" file="$2" symbol="$3"
    if grep -q "$symbol" "$file"; then
        printf "  ✅ %-14s %s\n" "[$label]" "$symbol"
    else
        printf "  ❌ %-14s %s  ← STILL MISSING\n" "[$label]" "$symbol"
        ALL_OK=false
    fi
}

check "susfs_def.h" "$SUSFS_DEF_H" "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"
check "susfs.h"     "$SUSFS_H"     "susfs_set_hide_sus_mnts_for_all_procs"
check "susfs.c"     "$SUSFS_C"     "susfs_set_hide_sus_mnts_for_all_procs"
check "susfs_def.h" "$SUSFS_DEF_H" "susfs_is_current_proc_umounted"

echo ""
if [ "$ALL_OK" = true ]; then
    echo "✅ All symbols present — $PATCHED change(s) applied."
else
    echo "❌ One or more symbols still missing — review output above."
    exit 1
fi
