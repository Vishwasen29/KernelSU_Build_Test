#!/usr/bin/env bash
# =============================================================================
# patch_susfs_symbols.sh
#
# Adds the 2 symbols missing from your SUSFS v2.0.0 files that both
# sidex15/KernelSU-Next and rsuntk/KernelSU require:
#
#   1. CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS  → include/linux/susfs_def.h
#   2. susfs_set_hide_sus_mnts_for_all_procs  → include/linux/susfs.h + fs/susfs.c
#
# Note: susfs_is_current_proc_umounted is already a static inline in
#       susfs_def.h (line 120) — it is NOT missing.
#
# Usage:
#   ./patch_susfs_symbols.sh [KERNEL_DIR]
#
# KERNEL_DIR defaults to current directory if not supplied.
# =============================================================================

set -euo pipefail

KERNEL_DIR="${1:-$(pwd)}"
SUSFS_DEF_H="${KERNEL_DIR}/include/linux/susfs_def.h"
SUSFS_H="${KERNEL_DIR}/include/linux/susfs.h"
SUSFS_C="${KERNEL_DIR}/fs/susfs.c"

echo "🔍 Patching SUSFS v2.0.0 symbols under: ${KERNEL_DIR}"
echo ""

# ── Sanity checks ─────────────────────────────────────────────────────────────
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
    # Insert on the line immediately after CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
    sed -i \
        's/\(#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS.*\)/\1\n#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS   0x55563/' \
        "$SUSFS_DEF_H"
    echo "✅ [susfs_def.h] Added CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS (0x55563)"
    PATCHED=$((PATCHED + 1))
fi

# ── 2a. Function declaration in susfs.h ───────────────────────────────────────
if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUSFS_H"; then
    echo "ℹ️  susfs_set_hide_sus_mnts_for_all_procs already declared — skipping."
else
    # Insert right after the _for_non_su_procs declaration
    sed -i \
        's/\(void susfs_set_hide_sus_mnts_for_non_su_procs.*;\)/\1\nvoid susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info);/' \
        "$SUSFS_H"
    echo "✅ [susfs.h]     Added susfs_set_hide_sus_mnts_for_all_procs() declaration"
    PATCHED=$((PATCHED + 1))
fi

# ── 2b. Function implementation in susfs.c ────────────────────────────────────
# The _for_all_procs variant works identically to _for_non_su_procs but sets a
# separate flag (susfs_hide_sus_mnts_for_all_procs) that affects ALL processes,
# not just non-root ones. We add a static bool + full implementation modelled
# exactly on the existing non_su_procs function.

if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUSFS_C"; then
    echo "ℹ️  susfs_set_hide_sus_mnts_for_all_procs already implemented — skipping."
else
    # Build the implementation block as a here-doc, then append it right after
    # the closing #endif of the non_su_procs function block.
    IMPL='
/* Added by patch_susfs_symbols.sh — required by KernelSU-Next */
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bool susfs_hide_sus_mnts_for_all_procs = false;

void susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info) {
\tstruct st_susfs_hide_sus_mnts_for_non_su_procs info = {0};

\tif (copy_from_user(\&info, (struct st_susfs_hide_sus_mnts_for_non_su_procs __user*)*user_info, sizeof(info))) {
\t\tinfo.err = -EFAULT;
\t\tgoto out_copy_to_user;
\t}
\tspin_lock(\&susfs_spin_lock_sus_mount);
\tsusfs_hide_sus_mnts_for_all_procs = info.enabled;
\tspin_unlock(\&susfs_spin_lock_sus_mount);
\tSUSFS_LOGI("susfs_hide_sus_mnts_for_all_procs: %d\\n", info.enabled);
\tinfo.err = 0;
out_copy_to_user:
\tif (copy_to_user(\&((struct st_susfs_hide_sus_mnts_for_non_su_procs __user*)*user_info)->err, \&info.err, sizeof(info.err))) {
\t\tinfo.err = -EFAULT;
\t}
\tSUSFS_LOGI("CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS -> ret: %d\\n", info.err);
}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT'

    # Find the line number of the closing #endif after susfs_set_hide_sus_mnts_for_non_su_procs
    # and insert our block right after it.
    AFTER_LINE=$(awk '
        /susfs_set_hide_sus_mnts_for_non_su_procs/{ found=1 }
        found && /#endif.*CONFIG_KSU_SUSFS_SUS_MOUNT/{ print NR; exit }
    ' "$SUSFS_C")

    if [ -z "$AFTER_LINE" ]; then
        echo "⚠️  Could not find insertion anchor in susfs.c — appending to end of file."
        printf '%b\n' "$IMPL" >> "$SUSFS_C"
    else
        # Use a Python one-liner for reliable multi-line insertion
        python3 - "$SUSFS_C" "$AFTER_LINE" "$IMPL" << 'PYEOF'
import sys

filepath   = sys.argv[1]
after_line = int(sys.argv[2])
block      = sys.argv[3]

with open(filepath, 'r') as f:
    lines = f.readlines()

lines.insert(after_line, block + '\n')

with open(filepath, 'w') as f:
    f.writelines(lines)

print(f"  Inserted after line {after_line}")
PYEOF
    fi

    echo "✅ [susfs.c]     Added susfs_set_hide_sus_mnts_for_all_procs() implementation"
    PATCHED=$((PATCHED + 1))
fi

# ── Final verification ────────────────────────────────────────────────────────
echo ""
echo "── Verification ──────────────────────────────────────────────────────────"
ALL_OK=true

check() {
    local label="$1" file="$2" symbol="$3"
    if grep -q "$symbol" "$file"; then
        printf "  ✅ %-12s %s\n" "[$label]" "$symbol"
    else
        printf "  ❌ %-12s %s  ← STILL MISSING\n" "[$label]" "$symbol"
        ALL_OK=false
    fi
}

check "susfs_def.h" "$SUSFS_DEF_H" "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"
check "susfs.h"     "$SUSFS_H"     "susfs_set_hide_sus_mnts_for_all_procs"
check "susfs.c"     "$SUSFS_C"     "susfs_set_hide_sus_mnts_for_all_procs"

# This one was never missing — just confirm it's still there
check "susfs_def.h" "$SUSFS_DEF_H" "susfs_is_current_proc_umounted"

echo ""
if [ "$ALL_OK" = true ]; then
    echo "✅ All symbols present — $PATCHED change(s) applied."
    echo "   Your SUSFS files are now compatible with both:"
    echo "   • sidex15/KernelSU-Next (legacy-susfs branch)"
    echo "   • rsuntk/KernelSU       (susfs-rksu-master branch)"
else
    echo "❌ One or more symbols still missing — review output above."
    exit 1
fi
