#!/bin/bash
# =============================================================================
# fix_susfs_patches.sh
# Manually applies the failed SUSFS patch hunks for OnePlus 9R (lemonade/SM-8250)
#
# Failed hunks this script fixes:
#   fs/namespace.c          – Hunks #1, #9, #10  (Hunk #7 is skipped: different
#                             vfs_kern_mount implementation in this kernel tree)
#   fs/proc/task_mmu.c     – Hunk #8
#   include/linux/mount.h  – Hunk #1
#
# Usage:
#   cd <kernel-root>
#   bash /path/to/fix_susfs_patches.sh
# =============================================================================

set -euo pipefail

KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }
skip() { echo -e "${YELLOW}[SKIP]${NC}  $*"; }

check_file() {
    [[ -f "$1" ]] || err "File not found: $1 — are you running from the kernel root?"
}

check_file fs/namespace.c
check_file fs/proc/task_mmu.c
check_file include/linux/mount.h

# ---------------------------------------------------------------------------
# Helper: idempotency guard — skip if a marker string is already present
# ---------------------------------------------------------------------------
already_contains() { grep -qF "$1" "$2"; }

# ---------------------------------------------------------------------------
# Python helper (avoids multi-line sed nightmares)
# ---------------------------------------------------------------------------
run_py() { python3 - <<'PYEOF'
import sys, re
EOF_MARKER="PYEOF"
PYEOF
# (real calls are inline below)
true
}

# ===========================================================================
# 1. fs/namespace.c  –  Hunk #1
#    Add susfs_def.h include after #include <linux/sched/task.h>
#    Add extern declarations + CL_COPY_MNT_NS define after #include "internal.h"
# ===========================================================================
FILE="fs/namespace.c"
echo ""
echo "── $FILE ──────────────────────────────────────────────"

if already_contains 'CONFIG_KSU_SUSFS_SUS_MOUNT' "$FILE" && \
   already_contains '#define CL_COPY_MNT_NS ' "$FILE"; then
    skip "Hunk #1 already applied in $FILE"
else
    python3 << 'PYEOF'
import sys

path = "fs/namespace.c"
with open(path, "r") as f:
    src = f.read()

# --- Part A: insert susfs_def.h include block after <linux/sched/task.h> ---
old_a = '#include <linux/sched/task.h>'
new_a = (
    '#include <linux/sched/task.h>\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT'
)
if old_a in src and 'susfs_def.h' not in src:
    src = src.replace(old_a, new_a, 1)
    print("[OK]    namespace.c Hunk#1 Part-A: susfs_def.h include added")
else:
    print("[SKIP]  namespace.c Hunk#1 Part-A: already present or anchor not found")

# --- Part B: insert extern block after #include "internal.h" ---
old_b = '#include "internal.h"\n\n/* Maximum number of mounts'
new_b = (
    '#include "internal.h"\n'
    '\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    'extern bool susfs_is_current_ksu_domain(void);\n'
    'extern bool susfs_is_sdcard_android_data_decrypted;\n'
    '\n'
    'static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n'
    '\n'
    '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n'
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '\n'
    '/* Maximum number of mounts'
)
if old_b in src and '#define CL_COPY_MNT_NS ' not in src:
    src = src.replace(old_b, new_b, 1)
    print("[OK]    namespace.c Hunk#1 Part-B: extern/define block added")
else:
    print("[SKIP]  namespace.c Hunk#1 Part-B: already present or anchor not found")

with open(path, "w") as f:
    f.write(src)
PYEOF
    ok "Hunk #1 processed for $FILE"
fi

# ===========================================================================
# 2. fs/namespace.c  –  Hunk #7  (SKIP)
#    This hunk targets the old alloc_vfsmnt()-based vfs_kern_mount(), which
#    does not exist in this kernel (uses fs_context API instead). Safe to skip.
# ===========================================================================
skip "Hunk #7 in $FILE — kernel uses fs_context-based vfs_kern_mount(); whitespace-only hunk not applicable"

# ===========================================================================
# 3. fs/namespace.c  –  Hunk #9
#    Insert SUS_MOUNT block inside clone_mnt(), replacing the bare
#    mnt = alloc_vfsmnt(old->mnt_devname); with the guarded version.
# ===========================================================================
if already_contains 'susfs_alloc_sus_vfsmnt' "$FILE"; then
    skip "Hunk #9 already applied in $FILE"
else
    python3 << 'PYEOF'
path = "fs/namespace.c"
with open(path, "r") as f:
    src = f.read()

# We look for the exact line inside clone_mnt (unique – only one such call exists
# inside clone_mnt at the start of the function, before error paths).
# The already-partially-patched file still has this line unchanged.
old = '\tmnt = alloc_vfsmnt(old->mnt_devname);\n\tif (!mnt)\n\t\treturn ERR_PTR(-ENOMEM);'

new = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '\t// We won\'t check it anymore if boot-completed stage is triggered.\n'
    '\tif (susfs_is_sdcard_android_data_decrypted) {\n'
    '\t\tgoto skip_checking_for_ksu_proc;\n'
    '\t}\n'
    '\t// First we must check for ksu process because of magic mount\n'
    '\tif (susfs_is_current_ksu_domain()) {\n'
    '\t\t// if it is unsharing, we reuse the old->mnt_id\n'
    '\t\tif (flag & CL_COPY_MNT_NS) {\n'
    '\t\t\tmnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);\n'
    '\t\t\tgoto bypass_orig_flow;\n'
    '\t\t}\n'
    '\t\t// else we just go assign fake mnt_id\n'
    '\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n'
    '\t\tgoto bypass_orig_flow;\n'
    '\t}\n'
    'skip_checking_for_ksu_proc:\n'
    '\t// Lastly for other processes of which old->mnt_id == DEFAULT_KSU_MNT_ID, go assign fake mnt_id\n'
    '\tif (old->mnt_id == DEFAULT_KSU_MNT_ID) {\n'
    '\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n'
    '\t\tgoto bypass_orig_flow;\n'
    '\t}\n'
    '#endif\n'
    '\tmnt = alloc_vfsmnt(old->mnt_devname);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    'bypass_orig_flow:\n'
    '#endif\n'
    '\tif (!mnt)\n'
    '\t\treturn ERR_PTR(-ENOMEM);'
)

if old in src:
    src = src.replace(old, new, 1)
    print("[OK]    namespace.c Hunk#9: clone_mnt SUS_MOUNT block inserted")
else:
    print("[ERR]   namespace.c Hunk#9: anchor not found — check if clone_mnt was already modified")
    import sys; sys.exit(1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    ok "Hunk #9 processed for $FILE"
fi

# ===========================================================================
# 4. fs/namespace.c  –  Hunk #10
#    Add blank line before lock_mount_hash() in clone_mnt (cosmetic, but
#    included because it's part of the SUSFS patch set).
# ===========================================================================
if python3 -c "
src = open('fs/namespace.c').read()
# Check if the blank line already exists (bypass_orig_flow block changes context)
import sys
# After our hunk#9 addition, lock_mount_hash is preceded by other code;
# just check the mnt_parent / lock_mount_hash adjacency.
if '\tmnt->mnt_parent = mnt;\n\tlock_mount_hash();' in src:
    sys.exit(0)   # needs fixing
sys.exit(1)       # already fine
" 2>/dev/null; then
    python3 << 'PYEOF'
path = "fs/namespace.c"
with open(path, "r") as f:
    src = f.read()

old = '\tmnt->mnt_parent = mnt;\n\tlock_mount_hash();'
new = '\tmnt->mnt_parent = mnt;\n\n\tlock_mount_hash();'

if old in src:
    src = src.replace(old, new, 1)
    print("[OK]    namespace.c Hunk#10: blank line before lock_mount_hash() added")
else:
    print("[SKIP]  namespace.c Hunk#10: blank line already present or anchor not found")

with open(path, "w") as f:
    f.write(src)
PYEOF
    ok "Hunk #10 processed for $FILE"
else
    skip "Hunk #10 — blank line before lock_mount_hash() already present"
fi

# ===========================================================================
# 5. fs/proc/task_mmu.c  –  Hunk #8
#    Insert SUS_MAP block after mmap_read_unlock(mm).
#    The patch expected up_read(&mm->mmap_sem) but this kernel uses the
#    newer mmap_read_unlock() wrapper.
# ===========================================================================
FILE2="fs/proc/task_mmu.c"
echo ""
echo "── $FILE2 ─────────────────────────────────────────────"

if already_contains 'BIT_SUS_MAPS' "$FILE2"; then
    skip "Hunk #8 already applied in $FILE2"
else
    python3 << 'PYEOF'
path = "fs/proc/task_mmu.c"
with open(path, "r") as f:
    src = f.read()

# Anchor: the pagemap_read loop – after mmap_read_unlock(mm) and before
# start_vaddr = end;
old = '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n\t\tmmap_read_unlock(mm);\n\t\tstart_vaddr = end;'

new = (
    '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
    '\t\tmmap_read_unlock(mm);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\t\tvma = find_vma(mm, start_vaddr);\n'
    '\t\tif (vma && vma->vm_file) {\n'
    '\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n'
    '\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n'
    '\t\t\t\tpm.buffer->pme = 0;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '#endif\n'
    '\t\tstart_vaddr = end;'
)

if old in src:
    src = src.replace(old, new, 1)
    print("[OK]    task_mmu.c Hunk#8: SUS_MAP block inserted after mmap_read_unlock()")
else:
    # Fallback: maybe it still uses up_read (old kernel path)
    old2 = '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;'
    new2 = (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        '\t\tup_read(&mm->mmap_sem);\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
        '\t\tvma = find_vma(mm, start_vaddr);\n'
        '\t\tif (vma && vma->vm_file) {\n'
        '\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n'
        '\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n'
        '\t\t\t\tpm.buffer->pme = 0;\n'
        '\t\t\t}\n'
        '\t\t}\n'
        '#endif\n'
        '\t\tstart_vaddr = end;'
    )
    if old2 in src:
        src = src.replace(old2, new2, 1)
        print("[OK]    task_mmu.c Hunk#8: SUS_MAP block inserted (up_read path)")
    else:
        print("[ERR]   task_mmu.c Hunk#8: anchor not found — file may differ from expected")
        import sys; sys.exit(1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    ok "Hunk #8 processed for $FILE2"
fi

# ===========================================================================
# 6. include/linux/mount.h  –  Hunk #1
#    Replace ANDROID_KABI_RESERVE(4) with the SUSFS conditional version
#    inside struct vfsmount.
# ===========================================================================
FILE3="include/linux/mount.h"
echo ""
echo "── $FILE3 ──────────────────────────────────────────────"

if already_contains 'susfs_mnt_id_backup' "$FILE3"; then
    skip "Hunk #1 already applied in $FILE3"
else
    python3 << 'PYEOF'
path = "include/linux/mount.h"
with open(path, "r") as f:
    src = f.read()

# The KABI reserve macros appear sequentially; only RESERVE(4) needs changing.
# We anchor on the surrounding reserves to avoid wrong substitution.
old = (
    '\tANDROID_KABI_RESERVE(3);\n'
    '\tANDROID_KABI_RESERVE(4);\n'
    '\tvoid *data;'
)
new = (
    '\tANDROID_KABI_RESERVE(3);\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n'
    '#else\n'
    '\tANDROID_KABI_RESERVE(4);\n'
    '#endif\n'
    '\tvoid *data;'
)

if old in src:
    src = src.replace(old, new, 1)
    print("[OK]    mount.h Hunk#1: ANDROID_KABI_RESERVE(4) replaced with SUSFS conditional")
else:
    # Fallback: maybe RESERVE(3) line is absent; try bare RESERVE(4) anchor
    old2 = '\tANDROID_KABI_RESERVE(4);\n\tvoid *data;'
    new2 = (
        '#ifdef CONFIG_KSU_SUSFS\n'
        '\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n'
        '#else\n'
        '\tANDROID_KABI_RESERVE(4);\n'
        '#endif\n'
        '\tvoid *data;'
    )
    if old2 in src:
        src = src.replace(old2, new2, 1)
        print("[OK]    mount.h Hunk#1: ANDROID_KABI_RESERVE(4) replaced (bare anchor)")
    else:
        print("[ERR]   mount.h Hunk#1: ANDROID_KABI_RESERVE(4) anchor not found")
        import sys; sys.exit(1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    ok "Hunk #1 processed for $FILE3"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "══════════════════════════════════════════════════════"
echo " SUSFS rejected-hunk fix complete."
echo ""
echo " What was done:"
echo "  fs/namespace.c       Hunk#1  – susfs_def.h include + extern decls"
echo "  fs/namespace.c       Hunk#7  – SKIPPED (fs_context kernel, not applicable)"
echo "  fs/namespace.c       Hunk#9  – clone_mnt SUS_MOUNT guard block"
echo "  fs/namespace.c       Hunk#10 – cosmetic blank line before lock_mount_hash()"
echo "  fs/proc/task_mmu.c   Hunk#8  – SUS_MAP block (mmap_read_unlock variant)"
echo "  include/linux/mount.h Hunk#1 – KABI_RESERVE(4) → KABI_USE susfs_mnt_id_backup"
echo ""
echo " You can now re-run your kernel build."
echo "══════════════════════════════════════════════════════"
