#!/bin/bash
# susfs_supplementary_fix.sh
#
# Applies the SUSFS patch hunks that failed in the main patch run.
# Must be run from the root of the kernel source tree (android-kernel/).
#
# Failed hunks being fixed:
#   - fs/namespace.c  hunks #1, #7, #9, #10
#   - fs/proc/task_mmu.c  hunk #8
#   - include/linux/mount.h  hunk #1

set -e
KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

echo "=== SUSFS Supplementary Fix Script ==="
echo "Kernel root: $(pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: abort if a file doesn't exist
# ─────────────────────────────────────────────────────────────────────────────
require_file() {
    if [ ! -f "$1" ]; then
        echo "ERROR: Required file not found: $1"
        exit 1
    fi
}

require_file fs/namespace.c
require_file fs/proc/task_mmu.c
require_file include/linux/mount.h

# ─────────────────────────────────────────────────────────────────────────────
# fs/namespace.c  – Hunk #1
# Add susfs_def.h include + extern declarations after kernel includes.
#
# The main patch failed because the kernel already has:
#   #include <linux/fs_context.h>
# which wasn't in the patch's context (it was added upstream after the patch
# was written).  We insert around it correctly here.
# ─────────────────────────────────────────────────────────────────────────────
echo "[1/5] fs/namespace.c – adding susfs_def.h include block..."

if grep -q "CONFIG_KSU_SUSFS_SUS_MOUNT" fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

with open('fs/namespace.c', 'r') as f:
    content = f.read()

# ── Insert #include <linux/susfs_def.h> BEFORE #include <linux/fs_context.h>
ANCHOR = '#include <linux/sched/task.h>\n'
INSERT_INCLUDES = (
    '#include <linux/sched/task.h>\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
)

if ANCHOR not in content:
    print('ERROR: anchor "#include <linux/sched/task.h>" not found in fs/namespace.c')
    sys.exit(1)

content = content.replace(ANCHOR, INSERT_INCLUDES, 1)

# ── Insert extern declarations + #define after "internal.h" include block
# The line we want to insert after looks like:
#   #include "internal.h"
# followed by a blank line and then the comment about maximum mounts.
ANCHOR2 = '#include "internal.h"\n'
INSERT_EXTERNS = (
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
)

if ANCHOR2 not in content:
    print('ERROR: anchor #include "internal.h" not found in fs/namespace.c')
    sys.exit(1)

content = content.replace(ANCHOR2, INSERT_EXTERNS, 1)

with open('fs/namespace.c', 'w') as f:
    f.write(content)

print('      Done.')
PYEOF
fi

# ─────────────────────────────────────────────────────────────────────────────
# fs/namespace.c  – Hunk #7
# The main patch tried to add whitespace tweaks inside vfs_kern_mount(), but
# this kernel version has a completely different vfs_kern_mount() implementation
# (using fs_context).  The change is cosmetic whitespace only and has NO
# functional impact – safely skipped.
# ─────────────────────────────────────────────────────────────────────────────
echo "[2/5] fs/namespace.c – hunk #7 (vfs_kern_mount whitespace) – SKIPPING (cosmetic, inapplicable to this kernel version)."

# ─────────────────────────────────────────────────────────────────────────────
# fs/namespace.c  – Hunks #9 and #10
# Add the SUS_MOUNT guard block inside clone_mnt() before alloc_vfsmnt().
# Also add blank line before lock_mount_hash().
# ─────────────────────────────────────────────────────────────────────────────
echo "[3/5] fs/namespace.c – clone_mnt() SUS_MOUNT guard (hunks #9 and #10)..."

if grep -q "susfs_alloc_sus_vfsmnt\|bypass_orig_flow" fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

with open('fs/namespace.c', 'r') as f:
    content = f.read()

# ── Hunk #9: replace the plain alloc_vfsmnt inside clone_mnt with the full
#    SUSFS guard block.  We match the exact lines present in the orig file.
OLD_ALLOC = (
    '\tmnt = alloc_vfsmnt(old->mnt_devname);\n'
    '\tif (!mnt)\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
)

# clone_mnt starts with "struct super_block *sb = old->mnt.mnt_sb;" – make
# sure we only replace the first occurrence (inside clone_mnt, not fc_mount).
# fc_mount uses alloc_vfsmnt(fc->source) so the text is different enough.
if OLD_ALLOC not in content:
    print('ERROR: expected alloc_vfsmnt block not found in clone_mnt context')
    sys.exit(1)

NEW_ALLOC = (
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
    '\t\treturn ERR_PTR(-ENOMEM);\n'
)

content = content.replace(OLD_ALLOC, NEW_ALLOC, 1)

# ── Hunk #10: add blank line between mnt_parent = mnt and lock_mount_hash()
#    inside clone_mnt.  We need to be specific – this pattern occurs only once
#    in clone_mnt (line ~1092 in orig).
OLD_LOCK = (
    '\tmnt->mnt_parent = mnt;\n'
    '\tlock_mount_hash();\n'
    '\tlist_add_tail(&mnt->mnt_instance, &sb->s_mounts);\n'
)

NEW_LOCK = (
    '\tmnt->mnt_parent = mnt;\n'
    '\n'
    '\tlock_mount_hash();\n'
    '\tlist_add_tail(&mnt->mnt_instance, &sb->s_mounts);\n'
)

# There may be multiple occurrences; we only want the one inside clone_mnt.
# clone_mnt's version is the first occurrence.
count = content.count(OLD_LOCK)
if count == 0:
    print('WARNING: lock_mount_hash context not found – skipping hunk #10 (cosmetic).')
else:
    content = content.replace(OLD_LOCK, NEW_LOCK, 1)

with open('fs/namespace.c', 'w') as f:
    f.write(content)

print('      Done.')
PYEOF
fi

# ─────────────────────────────────────────────────────────────────────────────
# fs/proc/task_mmu.c  – Hunk #8
# The main patch failed because the kernel uses the newer mmap_read_unlock(mm)
# API instead of up_read(&mm->mmap_sem).  We match the correct API here.
# ─────────────────────────────────────────────────────────────────────────────
echo "[4/5] fs/proc/task_mmu.c – pagemap_read SUS_MAP guard (hunk #8)..."

if grep -q "BIT_SUS_MAPS\|CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

with open('fs/proc/task_mmu.c', 'r') as f:
    content = f.read()

# Try modern API first (mmap_read_unlock), then legacy (up_read mmap_sem)
PATTERNS = [
    (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        '\t\tmmap_read_unlock(mm);\n'
        '\t\tstart_vaddr = end;\n',
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
        '\t\tstart_vaddr = end;\n'
    ),
    (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        '\t\tup_read(&mm->mmap_sem);\n'
        '\t\tstart_vaddr = end;\n',
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
        '\t\tstart_vaddr = end;\n'
    ),
]

patched = False
for old, new in PATTERNS:
    if old in content:
        content = content.replace(old, new, 1)
        patched = True
        break

if not patched:
    print('ERROR: walk_page_range/mmap_read_unlock context not found in task_mmu.c')
    sys.exit(1)

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)

print('      Done.')
PYEOF
fi

# ─────────────────────────────────────────────────────────────────────────────
# include/linux/mount.h  – Hunk #1
# Replace ANDROID_KABI_RESERVE(4) with a CONFIG-guarded ANDROID_KABI_USE
# that stores the susfs backup mount ID.
# The patch failed due to line-number mismatch (struct vfsmount is at a
# different offset in this tree).  We search for the pattern directly.
# ─────────────────────────────────────────────────────────────────────────────
echo "[5/5] include/linux/mount.h – vfsmount ANDROID_KABI_RESERVE(4) → KABI_USE..."

if grep -q "susfs_mnt_id_backup\|KABI_USE.*4.*susfs" include/linux/mount.h; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys, re

with open('include/linux/mount.h', 'r') as f:
    content = f.read()

OLD = '\tANDROID_KABI_RESERVE(4);\n'
NEW = (
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n'
    '#else\n'
    '\tANDROID_KABI_RESERVE(4);\n'
    '#endif\n'
)

if OLD not in content:
    print('ERROR: ANDROID_KABI_RESERVE(4) not found in include/linux/mount.h')
    print('       You may need to add susfs_mnt_id_backup manually.')
    sys.exit(1)

content = content.replace(OLD, NEW, 1)

with open('include/linux/mount.h', 'w') as f:
    f.write(content)

print('      Done.')
PYEOF
fi

echo ""
echo "=== All supplementary fixes applied successfully! ==="
echo ""
echo "Summary of changes:"
echo "  fs/namespace.c         – susfs_def.h include, extern declarations,"
echo "                           clone_mnt() SUS_MOUNT guard block"
echo "  fs/proc/task_mmu.c     – pagemap_read() SUS_MAP guard"
echo "  include/linux/mount.h  – ANDROID_KABI_USE(4, susfs_mnt_id_backup)"
echo ""
echo "NOTE: hunk #7 (vfs_kern_mount whitespace) was intentionally skipped –"
echo "      this kernel uses a different vfs_kern_mount implementation and the"
echo "      change was cosmetic whitespace only."
