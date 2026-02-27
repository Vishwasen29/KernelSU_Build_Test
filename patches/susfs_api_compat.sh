#!/bin/bash
# susfs_api_compat.sh
#
# Fixes two build errors caused by an API version mismatch between
# rsuntk/KernelSU (susfs-rksu-master) and the installed SUSFS patch:
#
#  Error 1 — fs/proc/task_mmu.c
#    "unused variable 'vma'" — the SUSFS patch adds a vma declaration
#    inside pagemap_read() outside its #ifdef guard. The fix marks it
#    __maybe_unused by targeting the declaration NEAR the SUS_MAP guard,
#    not the first occurrence in the file (which belongs to a different function).
#
#  Error 2 — drivers/kernelsu/supercalls.c (3 symbols)
#    KernelSU calls newer SUSFS API names; the 4.19 patch installs older ones.
#    Mapping (new KSU name → what susfs.h actually exports):
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
    echo "ERROR: susfs.h does not contain the expected SUSFS API."
    echo "       Apply the SUSFS kernel patch (fic.sh) before running this script."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: task_mmu.c — mark the SUSFS-added vma declaration __maybe_unused
#
# IMPORTANT: task_mmu.c has MANY `struct vm_area_struct *vma;` declarations
# in different functions. The broken one is specifically inside pagemap_read(),
# added by the SUSFS patch adjacent to the CONFIG_KSU_SUSFS_SUS_MAP guard.
# We find it by searching within a window around that guard, not by replacing
# the first occurrence in the file (which is in an unrelated function).
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 1: task_mmu.c unused 'vma' variable ---"

if grep -q "struct vm_area_struct \*vma __maybe_unused;" "$TASK_MMU" && \
   python3 -c "
import sys
src = open(sys.argv[1]).read()
lines = src.splitlines()
guard_lines = [i for i, l in enumerate(lines) if 'CONFIG_KSU_SUSFS_SUS_MAP' in l]
if not guard_lines:
    sys.exit(1)
guard = guard_lines[0]
window = lines[max(0, guard-60):guard+10]
fixed = any('__maybe_unused' in l and 'vm_area_struct' in l for l in window)
sys.exit(0 if fixed else 1)
" "$TASK_MMU" 2>/dev/null; then
    echo "  [skip] correct vma declaration already has __maybe_unused"
else
    python3 << PYEOF
import sys

path = "$TASK_MMU"
with open(path, "r") as f:
    lines = f.readlines()

# Find the CONFIG_KSU_SUSFS_SUS_MAP guard line index
guard_idx = None
for i, line in enumerate(lines):
    if "CONFIG_KSU_SUSFS_SUS_MAP" in line:
        guard_idx = i
        break

if guard_idx is None:
    print("  [skip] CONFIG_KSU_SUSFS_SUS_MAP guard not found in task_mmu.c")
    print("         The SUSFS patch may not have been applied yet.")
    sys.exit(0)

# Search for the bare vma declaration within 80 lines BEFORE the guard.
# The SUSFS patch declares vma just before the pagemap_read() body where
# the guard appears, so it will always be within a short window above it.
search_start = max(0, guard_idx - 80)
target_idx = None

for i in range(guard_idx, search_start - 1, -1):
    line = lines[i]
    stripped = line.strip()
    # Match the bare declaration: "struct vm_area_struct *vma;" (no __maybe_unused yet)
    if ("vm_area_struct" in stripped and
        "*vma" in stripped and
        stripped.endswith("*vma;") and
        "__maybe_unused" not in stripped):
        target_idx = i
        break

if target_idx is None:
    # Fallback: also try forward search up to 10 lines after guard
    for i in range(guard_idx, min(len(lines), guard_idx + 10)):
        line = lines[i]
        stripped = line.strip()
        if ("vm_area_struct" in stripped and
            "*vma" in stripped and
            stripped.endswith("*vma;") and
            "__maybe_unused" not in stripped):
            target_idx = i
            break

if target_idx is None:
    print("  [warn] Could not locate the SUSFS vma declaration near SUS_MAP guard")
    print(f"         Guard was at line {guard_idx + 1}. Check task_mmu.c manually.")
    sys.exit(0)

# Apply the fix: insert __maybe_unused before the semicolon
old_line = lines[target_idx]
new_line = old_line.rstrip()
if new_line.endswith("*vma;"):
    new_line = new_line[:-1] + " __maybe_unused;\n"
elif new_line.endswith("*vma ;"):
    new_line = new_line[:-2] + " __maybe_unused;\n"
else:
    # Generic: replace last semicolon
    new_line = new_line.replace(";", " __maybe_unused;", 1) + "\n"

lines[target_idx] = new_line
with open(path, "w") as f:
    f.writelines(lines)

print(f"  [fix] Added __maybe_unused to vma at line {target_idx + 1} (near SUS_MAP guard at line {guard_idx + 1})")
PYEOF
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 2: supercalls.c — three renamed API symbols
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
    echo "  [fix]  $old_sym  →  $new_sym"
}

patch_symbol \
    "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" \
    "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" \
    "$SUPERCALLS"

patch_symbol \
    "susfs_set_hide_sus_mnts_for_all_procs" \
    "susfs_set_hide_sus_mnts_for_non_su_procs" \
    "$SUPERCALLS"

patch_symbol \
    "susfs_add_try_umount" \
    "add_try_umount" \
    "$SUPERCALLS"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verification
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
        echo "  ❌ '$sym' missing from $(basename $file)"
        FAIL=$((FAIL + 1))
    fi
}

# task_mmu.c: verify the fix landed near the guard, not somewhere else
python3 << PYEOF
import sys
path = "$TASK_MMU"
with open(path) as f:
    lines = f.readlines()

guard_idx = next((i for i, l in enumerate(lines) if "CONFIG_KSU_SUSFS_SUS_MAP" in l), None)
if guard_idx is None:
    print("  ⚠️  SUS_MAP guard not found — skipping task_mmu.c check")
    sys.exit(0)

window_start = max(0, guard_idx - 80)
found_fix = any(
    "vm_area_struct" in lines[i] and "__maybe_unused" in lines[i]
    for i in range(window_start, min(len(lines), guard_idx + 10))
)
if found_fix:
    print("  ✅ vma __maybe_unused found near SUS_MAP guard in task_mmu.c")
else:
    print("  ❌ vma __maybe_unused NOT near SUS_MAP guard — fix may have hit wrong line")
    sys.exit(1)
PYEOF

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
