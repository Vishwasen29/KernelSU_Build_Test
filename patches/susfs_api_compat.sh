#!/bin/bash
# susfs_api_compat.sh
#
# Fixes build errors from API mismatch between rsuntk/KernelSU (susfs-rksu-master)
# and the SUSFS 4.19 kernel patch.
#
#  Error 1 — fs/proc/task_mmu.c
#    "unused variable 'vma'" — the SUSFS patch adds a vma declaration inside
#    pagemap_read() but the compiler sees it as unused when the SUS_MAP guard
#    is not active in the analysis pass.
#    Strategy: find a bare `struct vm_area_struct *vma;` that is immediately
#    FOLLOWED by a CONFIG_KSU_SUSFS_SUS_MAP guard within the next 30 lines.
#    That is uniquely the SUSFS-added declaration — not any of the other vma
#    declarations in earlier functions.
#
#  Error 2 — drivers/kernelsu/supercalls.c
#    Three symbols renamed between SUSFS versions:
#      CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS  → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#      susfs_set_hide_sus_mnts_for_all_procs  → susfs_set_hide_sus_mnts_for_non_su_procs
#      susfs_add_try_umount                   → add_try_umount
#
# Usage:
#   bash susfs_api_compat.sh [path/to/android-kernel]

set -e

KERNEL_ROOT="${1:-.}"
TASK_MMU="${KERNEL_ROOT}/fs/proc/task_mmu.c"
SUPERCALLS="${KERNEL_ROOT}/drivers/kernelsu/supercalls.c"
SUSFS_H="${KERNEL_ROOT}/include/linux/susfs.h"

echo "=== SUSFS API compatibility fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

for f in "$TASK_MMU" "$SUPERCALLS" "$SUSFS_H"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file not found: $f"
        exit 1
    fi
done

if ! grep -q "susfs_set_hide_sus_mnts_for_non_su_procs" "$SUSFS_H"; then
    echo "ERROR: susfs.h does not have expected SUSFS API."
    echo "       Apply the SUSFS kernel patch (fic.sh) before running this script."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: task_mmu.c — __maybe_unused on the SUSFS-added vma declaration
#
# The file has multiple `struct vm_area_struct *vma;` declarations in different
# functions. The one added by SUSFS is uniquely identifiable because a
# `#ifdef CONFIG_KSU_SUSFS_SUS_MAP` guard appears within ~30 lines AFTER it
# (the guard wraps the code that actually uses vma).
#
# Algorithm:
#   For each bare vma declaration (no __maybe_unused yet), scan the next 30
#   lines for a CONFIG_KSU_SUSFS_SUS_MAP guard. If found, that is the target.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 1: task_mmu.c unused 'vma' variable ---"

python3 << PYEOF
import sys

path = "$TASK_MMU"
with open(path, "r") as f:
    lines = f.readlines()

LOOKAHEAD = 30  # lines to scan forward for the guard

target_idx = None
for i, line in enumerate(lines):
    stripped = line.strip()
    # Bare declaration: ends with *vma; and not yet __maybe_unused
    if ("vm_area_struct" in stripped and
            ("*vma;" in stripped or "* vma;" in stripped) and
            "__maybe_unused" not in stripped):
        # Scan forward for the SUS_MAP guard
        window_end = min(len(lines), i + LOOKAHEAD)
        for j in range(i + 1, window_end):
            if "CONFIG_KSU_SUSFS_SUS_MAP" in lines[j]:
                target_idx = i
                guard_line = j
                break
    if target_idx is not None:
        break

if target_idx is None:
    print("  [warn] Could not locate the SUSFS vma declaration.")
    print("         Searched for a bare vma decl followed by SUS_MAP guard within 30 lines.")
    print("         The patch structure may differ — check task_mmu.c manually.")
    sys.exit(0)

# Apply fix
old = lines[target_idx]
# Insert __maybe_unused before the semicolon that terminates the declaration
if "*vma;" in old:
    new = old.replace("*vma;", "*vma __maybe_unused;", 1)
elif "* vma;" in old:
    new = old.replace("* vma;", "* vma __maybe_unused;", 1)
else:
    new = old.rstrip("\n").rstrip(";") + " __maybe_unused;\n"

lines[target_idx] = new
with open(path, "w") as f:
    f.writelines(lines)

print(f"  [fix] Added __maybe_unused to vma at line {target_idx + 1}")
print(f"        (SUS_MAP guard confirmed at line {guard_line + 1})")
PYEOF

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 2: supercalls.c — three renamed API symbols
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 2: supercalls.c API name mismatches ---"

patch_symbol() {
    local old_sym="$1" new_sym="$2" file="$3"
    if ! grep -q "$old_sym" "$file"; then
        echo "  [skip] '$old_sym' not found (already fixed or not present)"
        return
    fi
    sed -i "s/${old_sym}/${new_sym}/g" "$file"
    echo "  [fix]  $old_sym  →  $new_sym"
}

patch_symbol "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" \
             "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" "$SUPERCALLS"

patch_symbol "susfs_set_hide_sus_mnts_for_all_procs" \
             "susfs_set_hide_sus_mnts_for_non_su_procs" "$SUPERCALLS"

patch_symbol "susfs_add_try_umount" \
             "add_try_umount" "$SUPERCALLS"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Verification ---"
FAIL=0

# task_mmu.c: confirm __maybe_unused appears on a line that precedes the guard
python3 << PYEOF
import sys
path = "$TASK_MMU"
with open(path) as f:
    lines = f.readlines()

LOOKAHEAD = 30
found = False
for i, line in enumerate(lines):
    if "vm_area_struct" in line and "__maybe_unused" in line:
        window_end = min(len(lines), i + LOOKAHEAD)
        for j in range(i + 1, window_end):
            if "CONFIG_KSU_SUSFS_SUS_MAP" in lines[j]:
                print(f"  ✅ vma __maybe_unused at line {i+1}, guard at line {j+1} — correct")
                found = True
                break
    if found:
        break

if not found:
    print("  ❌ Could not confirm vma __maybe_unused near SUS_MAP guard")
    sys.exit(1)
PYEOF

check_absent() {
    if grep -q "$1" "$2"; then
        echo "  ❌ '$1' still present in $(basename $2)"
        FAIL=$((FAIL + 1))
    else
        echo "  ✅ '$1' removed from $(basename $2)"
    fi
}

check_present() {
    if grep -q "$1" "$2"; then
        echo "  ✅ '$1' present in $(basename $2)"
    else
        echo "  ❌ '$1' missing from $(basename $2)"
        FAIL=$((FAIL + 1))
    fi
}

check_absent  "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"    "$SUPERCALLS"
check_absent  "susfs_set_hide_sus_mnts_for_all_procs"    "$SUPERCALLS"
check_absent  "susfs_add_try_umount"                     "$SUPERCALLS"
check_present "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" "$SUPERCALLS"
check_present "susfs_set_hide_sus_mnts_for_non_su_procs"  "$SUPERCALLS"
check_present "add_try_umount"                            "$SUPERCALLS"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL check(s) failed"
    exit 1
fi
echo "✅ All fixes applied successfully"
