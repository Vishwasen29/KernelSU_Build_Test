#!/bin/bash
# fix_supercalls.sh
# Fixes: drivers/kernelsu/supercalls.c compile errors (SUSFS API name mismatch)
#
# KernelSU-Next was written against a newer SUSFS API; the kernel-side patch
# (v2.0.0) uses different names. Direct rename at the call sites:
#
#   CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS   → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#   susfs_set_hide_sus_mnts_for_all_procs() → susfs_set_hide_sus_mnts_for_non_su_procs()
#   susfs_add_try_umount()                   → add_try_umount()  (static fn in same file)
#
# Usage:
#   bash fix_supercalls.sh [kernel-root-dir]

set -euo pipefail
KERNEL_ROOT="${1:-.}"
FILE="$KERNEL_ROOT/drivers/kernelsu/supercalls.c"

[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

orig = src
fixes = [
    (
        'CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS',
        'CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS',
    ),
    (
        'susfs_set_hide_sus_mnts_for_all_procs(',
        'susfs_set_hide_sus_mnts_for_non_su_procs(',
    ),
    (
        'susfs_add_try_umount(',
        'add_try_umount(',
    ),
]

for old, new in fixes:
    if old not in src:
        print(f"[SKIP] already fixed or not present: {old}")
    else:
        count = src.count(old)
        src = src.replace(old, new)
        print(f"[OK]   {old}")
        print(f"    →  {new}  ({count} occurrence(s))")

if src != orig:
    with open(path, 'w') as f:
        f.write(src)
else:
    print("[INFO] No changes made.")
PYEOF
