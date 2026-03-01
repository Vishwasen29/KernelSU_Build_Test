#!/bin/bash
# fix_namespace_decls.sh
# Fixes 3 errors in fs/namespace.c from SUSFS patch hunk#1 rejection:
#
#   error: implicit declaration of 'susfs_is_current_ksu_domain'
#   error: use of undeclared identifier 'CL_COPY_MNT_NS'
#   error: use of undeclared identifier 'susfs_ksu_mounts'
#
# Hunk#1 of the SUSFS patch failed because the kernel has
# <linux/fs_context.h> between sched/task.h and pnode.h, breaking
# the patch context. The other hunks (which USE these symbols) succeeded,
# leaving the file in a broken state without their declarations.
#
# Usage: bash fix_namespace_decls.sh [kernel-root-dir]

set -euo pipefail
FILE="${1:-.}/fs/namespace.c"
[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

changed = False

# ── susfs_def.h include ───────────────────────────────────────────────────────
INC_OLD = '#include <linux/sched/task.h>\n'
INC_NEW = (
    '#include <linux/sched/task.h>\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    '#endif\n'
)
if 'susfs_def.h' in src:
    print("[SKIP] susfs_def.h include already present")
elif INC_OLD not in src:
    print("[ERR]  anchor '#include <linux/sched/task.h>' not found"); sys.exit(1)
else:
    src = src.replace(INC_OLD, INC_NEW, 1)
    print("[OK]   susfs_def.h include added")
    changed = True

# ── extern declarations, susfs_ksu_mounts, CL_COPY_MNT_NS ───────────────────
# Try primary anchor: after #include "internal.h"
# Try fallback anchor: after #include "pnode.h"
DECL_BLOCK = (
    '\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    'extern bool susfs_is_current_ksu_domain(void);\n'
    'extern bool susfs_is_sdcard_android_data_decrypted;\n'
    '\n'
    'static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n'
    '\n'
    '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n'
    '#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */\n'
)

if 'susfs_is_current_ksu_domain' in src:
    print("[SKIP] extern declarations already present")
else:
    anchor = None
    for candidate in ('#include "internal.h"\n', '#include "pnode.h"\n'):
        if candidate in src:
            anchor = candidate
            break
    if anchor is None:
        print("[ERR]  no suitable anchor found for extern declarations"); sys.exit(1)
    src = src.replace(anchor, anchor + DECL_BLOCK, 1)
    print(f"[OK]   extern declarations + CL_COPY_MNT_NS + susfs_ksu_mounts added after {anchor.strip()}")
    changed = True

if changed:
    with open(path, 'w') as f:
        f.write(src)
PYEOF
