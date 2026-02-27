#!/bin/bash
# susfs_api_compat.sh
#
# Combined SUSFS compatibility fix. Handles two classes of build errors:
#
# CLASS 1 — Compiler errors
#   Fix 1: fs/proc/task_mmu.c — "unused variable 'vma'"
#   Fix 2: drivers/kernelsu/supercalls.c — 3 renamed API symbols
#          (rsuntk fork only; KernelSU-Next uses different names, skip if absent)
#
# CLASS 2 — Linker errors
#   Fix 3: fs/susfs_compat.c — defines 3 symbols absent from installed susfs.c:
#           susfs_ksu_sid, susfs_priv_app_sid, susfs_is_current_ksu_domain
#
# Usage:
#   bash susfs_api_compat.sh [path/to/android-kernel]

set -e
KERNEL_ROOT="${1:-.}"
TASK_MMU="${KERNEL_ROOT}/fs/proc/task_mmu.c"
SUPERCALLS="${KERNEL_ROOT}/drivers/kernelsu/supercalls.c"
SUSFS_H="${KERNEL_ROOT}/include/linux/susfs.h"
SUSFS_C="${KERNEL_ROOT}/fs/susfs.c"
FS_MAKEFILE="${KERNEL_ROOT}/fs/Makefile"
COMPAT_C="${KERNEL_ROOT}/fs/susfs_compat.c"

echo "=== SUSFS API & linker compatibility fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

for f in "$SUSFS_H" "$FS_MAKEFILE"; do
    [ -f "$f" ] || { echo "ERROR: required file not found: $f"; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: task_mmu.c — __maybe_unused on the SUSFS-added vma declaration
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 1: task_mmu.c unused 'vma' variable ---"
if [ -f "$TASK_MMU" ]; then
    python3 << PYEOF
import sys
path = "$TASK_MMU"
with open(path, "r") as f:
    lines = f.readlines()

LOOKAHEAD = 30
target_idx = None
guard_line = None

for i, line in enumerate(lines):
    stripped = line.strip()
    if ("vm_area_struct" in stripped and
            ("*vma;" in stripped or "* vma;" in stripped) and
            "__maybe_unused" not in stripped):
        for j in range(i + 1, min(len(lines), i + LOOKAHEAD)):
            if "CONFIG_KSU_SUSFS_SUS_MAP" in lines[j]:
                target_idx = i
                guard_line = j
                break
    if target_idx is not None:
        break

if target_idx is None:
    print("  [skip] vma declaration not found or already fixed")
    sys.exit(0)

old = lines[target_idx]
new = old.replace("*vma;", "*vma __maybe_unused;", 1)
if new == old:
    new = old.replace("* vma;", "* vma __maybe_unused;", 1)
lines[target_idx] = new
with open(path, "w") as f:
    f.writelines(lines)
print(f"  [fix]  Added __maybe_unused at line {target_idx + 1} (guard at line {guard_line + 1})")
PYEOF
else
    echo "  [skip] task_mmu.c not found"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 2: supercalls.c — renamed API symbols (rsuntk fork only)
# KernelSU-Next uses entirely different code; these old names simply won't
# exist, so we skip silently. Track what was actually replaced.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 2: supercalls.c API name mismatches ---"
FIX2_REPLACED_HIDE=0
FIX2_REPLACED_FUNC=0

if [ -f "$SUPERCALLS" ]; then
    if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" "$SUPERCALLS"; then
        sed -i "s/CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS/CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS/g" "$SUPERCALLS"
        echo "  [fix]  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS"
        FIX2_REPLACED_HIDE=1
    else
        echo "  [skip] CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS not found (KernelSU-Next or already fixed)"
    fi

    if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUPERCALLS"; then
        sed -i "s/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g" "$SUPERCALLS"
        echo "  [fix]  susfs_set_hide_sus_mnts_for_all_procs → susfs_set_hide_sus_mnts_for_non_su_procs"
        FIX2_REPLACED_FUNC=1
    else
        echo "  [skip] susfs_set_hide_sus_mnts_for_all_procs not found (KernelSU-Next or already fixed)"
    fi

    if grep -q "susfs_add_try_umount" "$SUPERCALLS"; then
        sed -i "s/susfs_add_try_umount/add_try_umount/g" "$SUPERCALLS"
        echo "  [fix]  susfs_add_try_umount → add_try_umount"
    else
        echo "  [skip] susfs_add_try_umount not found (KernelSU-Next or already fixed)"
    fi
else
    echo "  [skip] supercalls.c not found"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 3: Missing linker symbols
# Creates fs/susfs_compat.c and wires it into fs/Makefile.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 3: missing linker symbols ---"

ALREADY_HAVE=0
{ [ -f "$SUSFS_C" ] && grep -q "^u32 susfs_ksu_sid" "$SUSFS_C"; } && ALREADY_HAVE=1
{ [ -f "$COMPAT_C" ] && grep -q "susfs_ksu_sid" "$COMPAT_C"; } && ALREADY_HAVE=1

if [ "$ALREADY_HAVE" -eq 1 ]; then
    echo "  [skip] symbols already defined"
else
    echo "  [fix]  creating fs/susfs_compat.c"
    cat > "$COMPAT_C" << 'CEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_compat.c — stub definitions for SUSFS symbols absent from the
 * installed fs/susfs.c due to a version mismatch.
 *
 * Referenced unconditionally by patched security/selinux/avc.c and
 * fs/proc_namespace.c but not defined in the 4.19 susfs.c.
 */
#include <linux/types.h>
#include <linux/export.h>

/* SELinux SID of the KernelSU process. Default 0 = audit suppression inactive. */
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL_GPL(susfs_ksu_sid);

/* SELinux SID of privileged app processes. Default 0 = inactive. */
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL_GPL(susfs_priv_app_sid);

/* Returns true if current task is in KernelSU domain.
 * Default false = mount hiding inactive (safe). */
bool susfs_is_current_ksu_domain(void)
{
	return false;
}
EXPORT_SYMBOL_GPL(susfs_is_current_ksu_domain);
CEOF

    if grep -q "susfs_compat" "$FS_MAKEFILE"; then
        echo "  [skip] susfs_compat.o already in fs/Makefile"
    elif grep -q "susfs\.o" "$FS_MAKEFILE"; then
        sed -i '/susfs\.o/a obj-y += susfs_compat.o' "$FS_MAKEFILE"
        echo "  [fix]  susfs_compat.o added to fs/Makefile"
    else
        echo "obj-y += susfs_compat.o" >> "$FS_MAKEFILE"
        echo "  [fix]  susfs_compat.o appended to fs/Makefile"
    fi
fi

# Ensure header declarations exist
add_decl() {
    local sym="$1" decl="$2"
    if grep -q "\b${sym}\b" "$SUSFS_H"; then
        echo "  [skip] ${sym} already in susfs.h"
    else
        echo "  [fix]  ${sym} → susfs.h"
        python3 - "$SUSFS_H" "$decl" << 'PYEOF'
import sys
path, decl = sys.argv[1], sys.argv[2]
with open(path) as f: src = f.read()
idx = src.rfind('#endif')
src = (src[:idx] + decl + '\n\n' + src[idx:]) if idx != -1 else (src + '\n' + decl + '\n')
with open(path, 'w') as f: f.write(src)
PYEOF
    fi
}
add_decl "susfs_ksu_sid"               "extern u32 susfs_ksu_sid;"
add_decl "susfs_priv_app_sid"          "extern u32 susfs_priv_app_sid;"
add_decl "susfs_is_current_ksu_domain" "extern bool susfs_is_current_ksu_domain(void);"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Verification ---"
FAIL=0

# Fix 1: vma check
if [ -f "$TASK_MMU" ]; then
    python3 -c "
lines = open('$TASK_MMU').readlines()
found = any(
    'vm_area_struct' in lines[i] and '__maybe_unused' in lines[i] and
    any('CONFIG_KSU_SUSFS_SUS_MAP' in lines[j]
        for j in range(i+1, min(len(lines), i+30)))
    for i in range(len(lines))
)
print('  ✅ task_mmu.c vma fix confirmed' if found else '  ⚠️  task_mmu.c vma: no SUS_MAP guard nearby (may be pre-patched or clean)')
"
fi

# Fix 2: only verify replacement names if we actually did a replacement
if [ "$FIX2_REPLACED_HIDE" -eq 1 ]; then
    if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" "$SUPERCALLS"; then
        echo "  ✅ CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS present in supercalls.c"
    else
        echo "  ❌ CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS missing after replacement"
        FAIL=$((FAIL+1))
    fi
fi
if [ "$FIX2_REPLACED_FUNC" -eq 1 ]; then
    if grep -q "susfs_set_hide_sus_mnts_for_non_su_procs" "$SUPERCALLS"; then
        echo "  ✅ susfs_set_hide_sus_mnts_for_non_su_procs present in supercalls.c"
    else
        echo "  ❌ susfs_set_hide_sus_mnts_for_non_su_procs missing after replacement"
        FAIL=$((FAIL+1))
    fi
fi

# Fix 3: compat file and Makefile
if [ -f "$COMPAT_C" ] && grep -q "susfs_ksu_sid" "$COMPAT_C"; then
    echo "  ✅ fs/susfs_compat.c present with definitions"
elif [ -f "$SUSFS_C" ] && grep -q "^u32 susfs_ksu_sid" "$SUSFS_C"; then
    echo "  ✅ susfs_ksu_sid defined in susfs.c"
else
    echo "  ❌ linker symbols not defined anywhere"
    FAIL=$((FAIL+1))
fi

if grep -q "susfs_compat" "$FS_MAKEFILE"; then
    echo "  ✅ susfs_compat.o in fs/Makefile"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL check(s) failed"
    exit 1
fi
echo "✅ All fixes applied successfully"
