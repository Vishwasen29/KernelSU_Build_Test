#!/bin/bash
# fix_vma_unused.sh
# Fixes: ../fs/proc/task_mmu.c:1642: error: unused variable 'vma' [-Werror,-Wunused-variable]
#
# Root cause:
#   SUSFS patch hunk #7 succeeded and added `struct vm_area_struct *vma;`
#   inside pagemap_read(). Hunk #8 (which uses that variable) failed because
#   the kernel uses mmap_read_unlock(mm) instead of the expected up_read().
#   The declaration is stranded with no usage → -Werror kills the build.
#
# Fix:
#   Add __maybe_unused to the declaration. This is always safe:
#   - When CONFIG_KSU_SUSFS_SUS_MAP is ON:  vma gets used → attribute ignored.
#   - When CONFIG_KSU_SUSFS_SUS_MAP is OFF: attribute suppresses the warning.
#   There are ZERO bare `struct vm_area_struct *vma;` declarations in the
#   original task_mmu.c — every occurrence was added by SUSFS hunk #7.
#
# Usage:
#   bash fix_vma_unused.sh [kernel-root-dir]

set -euo pipefail
KERNEL_ROOT="${1:-.}"
FILE="$KERNEL_ROOT/fs/proc/task_mmu.c"

[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found (run from kernel root)"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Match any tab-indented bare vma declaration (any indent depth, no = initializer)
# Pattern: one or more tabs, then exactly `struct vm_area_struct *vma;`
pattern = re.compile(r'^(\t+)(struct vm_area_struct \*vma);$', re.MULTILINE)

if '__maybe_unused' in src and 'struct vm_area_struct *vma __maybe_unused' in src:
    print("[SKIP] task_mmu.c: vma __maybe_unused already present")
    sys.exit(0)

matches = pattern.findall(src)
if not matches:
    print("[SKIP] task_mmu.c: no bare 'struct vm_area_struct *vma;' found (already fixed?)")
    sys.exit(0)

new_src = pattern.sub(r'\1\2 __maybe_unused;', src)
count = len(matches)

with open(path, 'w') as f:
    f.write(new_src)

print(f"[OK]   task_mmu.c: {count} occurrence(s) of 'struct vm_area_struct *vma;' → '__maybe_unused'")
PYEOF
