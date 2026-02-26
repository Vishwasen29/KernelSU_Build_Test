#!/bin/bash
# susfs_api_compat.sh
#
# Fixes two build errors caused by an API version mismatch between
# rsuntk/KernelSU (susfs-rksu-master) and the installed SUSFS patch:
#
#  Error 1 — fs/proc/task_mmu.c:1642
#    "unused variable 'vma'" — vma is declared by the SUSFS patch but the
#    compiler can't prove it's used through the conditional guard.
#    Fix: mark the declaration with __maybe_unused.
#
#  Error 2 — drivers/kernelsu/supercalls.c (3 symbols)
#    The KernelSU fork calls functions/constants from a newer SUSFS API
#    that was renamed after the 4.19 patch was written.
#    Fix: sed-rename the calls in supercalls.c to match what susfs.h exports.
#
#    Mapping (new KSU name → what susfs.h actually provides):
#      CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS  → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#      susfs_set_hide_sus_mnts_for_all_procs  → susfs_set_hide_sus_mnts_for_non_su_procs
#      susfs_add_try_umount                   → add_try_umount
#
# Usage:
#   bash susfs_api_compat.sh [path/to/android-kernel]
#   (defaults to current directory)

set -e

KERNEL_ROOT="${1:-.}"
TASK_MMU="${KERNEL_ROOT}/fs/proc/task_mmu.c"
SUPERCALLS="${KERNEL_ROOT}/drivers/kernelsu/supercalls.c"
SUSFS_H="${KERNEL_ROOT}/include/linux/susfs.h"

echo "=== SUSFS API compatibility fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Sanity checks
# ─────────────────────────────────────────────────────────────────────────────
for f in "$TASK_MMU" "$SUPERCALLS" "$SUSFS_H"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file not found: $f"
        exit 1
    fi
done

# Confirm the SUSFS patch is already applied before we try to fix its API
if ! grep -q "susfs_set_hide_sus_mnts_for_non_su_procs" "$SUSFS_H"; then
    echo "ERROR: susfs.h does not contain the expected SUSFS API."
    echo "       Apply the SUSFS kernel patch (fic.sh) before running this script."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: task_mmu.c — unused variable 'vma'
#
# Our SUSFS patch inserts a block guarded by CONFIG_KSU_SUSFS_SUS_MAP that
# uses 'vma', but declares it outside the guard. The compiler flags it as
# unused even when the config is enabled because Clang's unused-variable
# analysis runs before dead-code elimination in this context.
#
# We find the declaration of `struct vm_area_struct *vma` inside pagemap_read
# and add __maybe_unused to silence the warning cleanly.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 1: task_mmu.c unused 'vma' variable ---"

if grep -q "struct vm_area_struct \*vma __maybe_unused" "$TASK_MMU"; then
    echo "  [skip] __maybe_unused already present"
else
    # The declaration our patch adds looks like:
    #   struct vm_area_struct *vma;
    # inside pagemap_read. We only want to touch the one near the SUSFS guard.
    # Strategy: if CONFIG_KSU_SUSFS_SUS_MAP guard is nearby, mark the vma decl.
    #
    # Use Python so we can do context-aware replacement (only the first
    # occurrence after we see the SUSFS guard region).
    python3 << PYEOF
import re, sys

path = "$TASK_MMU"
with open(path, "r") as f:
    src = f.read()

# Only patch if the SUS_MAP guard is present (SUSFS was applied)
if "CONFIG_KSU_SUSFS_SUS_MAP" not in src:
    print("  [skip] CONFIG_KSU_SUSFS_SUS_MAP guard not found in task_mmu.c")
    sys.exit(0)

# Replace `struct vm_area_struct *vma;` with `__maybe_unused` variant.
# We do a targeted replacement: only the bare declaration (no assignment,
# no other qualifiers) that is NOT already marked __maybe_unused.
old = "struct vm_area_struct *vma;"
new = "struct vm_area_struct *vma __maybe_unused;"

if old not in src:
    # Already patched or declaration spelled differently — check with pointer spacing
    old2 = "struct vm_area_struct * vma;"
    new2 = "struct vm_area_struct * vma __maybe_unused;"
    if old2 in src:
        src = src.replace(old2, new2, 1)
        print(f"  [fix] Added __maybe_unused to vma declaration (pointer-space variant)")
    else:
        print("  [warn] Could not locate bare 'struct vm_area_struct *vma;' declaration")
        print("         The compiler error may have a different root cause.")
        sys.exit(0)
else:
    src = src.replace(old, new, 1)
    print("  [fix] Added __maybe_unused to vma declaration")

with open(path, "w") as f:
    f.write(src)
PYEOF
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 2: supercalls.c — three renamed API symbols
#
# rsuntk KernelSU (susfs-rksu-master) was written against a newer SUSFS API.
# The 4.19 patch installs the older API names. We rename the call sites in
# supercalls.c to match what susfs.h actually exports.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 2: supercalls.c API name mismatches ---"

patch_symbol() {
    local old_sym="$1"
    local new_sym="$2"
    local file="$3"

    if ! grep -q "$old_sym" "$file"; then
        echo "  [skip] '$old_sym' not found (already fixed or not present)"
        return
    fi

    sed -i "s/${old_sym}/${new_sym}/g" "$file"
    echo "  [fix] $old_sym → $new_sym"
}

# CMD constant: _FOR_ALL_PROCS → _FOR_NON_SU_PROCS
patch_symbol \
    "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" \
    "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" \
    "$SUPERCALLS"

# Function: _for_all_procs → _for_non_su_procs
patch_symbol \
    "susfs_set_hide_sus_mnts_for_all_procs" \
    "susfs_set_hide_sus_mnts_for_non_su_procs" \
    "$SUPERCALLS"

# Function: susfs_add_try_umount → add_try_umount
patch_symbol \
    "susfs_add_try_umount" \
    "add_try_umount" \
    "$SUPERCALLS"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verify — make sure none of the broken symbols remain
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Verification ---"
FAIL=0

check_absent() {
    local sym="$1" file="$2"
    if grep -q "$sym" "$file"; then
        echo "  ❌ '$sym' still present in $(basename $file)"
        FAIL=$((FAIL + 1))
    else
        echo "  ✅ '$sym' removed from $(basename $file)"
    fi
}

check_present() {
    local sym="$1" file="$2"
    if grep -q "$sym" "$file"; then
        echo "  ✅ '$sym' present in $(basename $file)"
    else
        echo "  ❌ '$sym' not found in $(basename $file) — check manually"
        FAIL=$((FAIL + 1))
    fi
}

check_absent "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"   "$SUPERCALLS"
check_absent "susfs_set_hide_sus_mnts_for_all_procs"   "$SUPERCALLS"
check_absent "susfs_add_try_umount"                    "$SUPERCALLS"
check_present "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" "$SUPERCALLS"
check_present "susfs_set_hide_sus_mnts_for_non_su_procs"  "$SUPERCALLS"
check_present "add_try_umount"                            "$SUPERCALLS"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL check(s) failed"
    exit 1
fi
echo "✅ All fixes applied successfully"
