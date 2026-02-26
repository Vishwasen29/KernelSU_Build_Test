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

# Helper: run Python and propagate its exit code into bash (set -e compatible)
run_python() {
    python3 "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "ERROR: Python step failed (exit $rc)"
        exit $rc
    fi
}

require_file fs/namespace.c
require_file fs/proc/task_mmu.c
require_file include/linux/mount.h

# ─────────────────────────────────────────────────────────────────────────────
# fs/namespace.c  – Hunk #1
# Add susfs_def.h include + extern declarations.
#
# IMPORTANT: Do NOT guard this block with grep for CONFIG_KSU_SUSFS_SUS_MOUNT.
# The main patch already writes that string in other (successful) hunks, so
# that check gives a false positive and silently skips this step.
# Guard ONLY on "susfs_def.h" which is unique to this hunk.
# ─────────────────────────────────────────────────────────────────────────────
echo "[1/5] fs/namespace.c – adding susfs_def.h include + extern block..."

if grep -q 'susfs_def\.h' fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 << 'PYEOF'
import sys, re

with open('fs/namespace.c', 'r') as f:
    content = f.read()

# ── Step A: insert susfs_def.h guard after sched/task.h ──
# Use regex so any text following on the next line doesn't matter
# (KernelSU-Next setup may insert its own includes between sched/task.h
#  and fs_context.h, changing the plain-string context).
INCLUDE_ANCHOR_RE = r'(#include <linux/sched/task\.h>\n)'
INCLUDE_INSERT = (
    r'\1'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
)

if not re.search(INCLUDE_ANCHOR_RE, content):
    print('ERROR: #include <linux/sched/task.h> not found in fs/namespace.c')
    sys.exit(1)

content = re.sub(INCLUDE_ANCHOR_RE, INCLUDE_INSERT, content, count=1)

# ── Step B: insert extern declarations after #include "internal.h" ──
INTERNAL_ANCHOR = '#include "internal.h"\n'
INTERNAL_INSERT = (
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

if INTERNAL_ANCHOR not in content:
    print('ERROR: #include "internal.h" not found in fs/namespace.c')
    sys.exit(1)

content = content.replace(INTERNAL_ANCHOR, INTERNAL_INSERT, 1)

with open('fs/namespace.c', 'w') as f:
    f.write(content)

print('      Done.')
sys.exit(0)
PYEOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Python failed for namespace.c hunk #1"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# fs/namespace.c  – Hunk #7
# Cosmetic whitespace inside vfs_kern_mount() – N/A for this kernel which uses
# the fs_context-based implementation. Safely skipped.
# ─────────────────────────────────────────────────────────────────────────────
echo "[2/5] fs/namespace.c – hunk #7 (vfs_kern_mount whitespace) – SKIPPING (cosmetic, N/A)."

# ─────────────────────────────────────────────────────────────────────────────
# fs/namespace.c  – Hunks #9 and #10
# SUS_MOUNT guard block inside clone_mnt() + blank line before lock_mount_hash.
# ─────────────────────────────────────────────────────────────────────────────
echo "[3/5] fs/namespace.c – clone_mnt() SUS_MOUNT guard (hunks #9 and #10)..."

if grep -q 'susfs_alloc_sus_vfsmnt\|bypass_orig_flow' fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 << 'PYEOF'
import sys

with open('fs/namespace.c', 'r') as f:
    content = f.read()

# alloc_vfsmnt(old->mnt_devname) is unique to clone_mnt (fc_mount uses fc->source)
OLD_ALLOC = (
    '\tmnt = alloc_vfsmnt(old->mnt_devname);\n'
    '\tif (!mnt)\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
)

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

if OLD_ALLOC not in content:
    print('ERROR: alloc_vfsmnt(old->mnt_devname) block not found in fs/namespace.c')
    sys.exit(1)

content = content.replace(OLD_ALLOC, NEW_ALLOC, 1)

# Hunk #10: blank line before lock_mount_hash() inside clone_mnt
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

if content.count(OLD_LOCK) == 0:
    print('WARNING: lock_mount_hash context not found – hunk #10 skipped (cosmetic).')
else:
    content = content.replace(OLD_LOCK, NEW_LOCK, 1)

with open('fs/namespace.c', 'w') as f:
    f.write(content)

print('      Done.')
sys.exit(0)
PYEOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Python failed for namespace.c hunks #9/#10"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# fs/proc/task_mmu.c  – Hunk #8
# Patch expected up_read(&mm->mmap_sem) but kernel uses mmap_read_unlock(mm).
# ─────────────────────────────────────────────────────────────────────────────
echo "[4/5] fs/proc/task_mmu.c – pagemap_read() SUS_MAP guard (hunk #8)..."

if grep -q 'BIT_SUS_MAPS\|CONFIG_KSU_SUSFS_SUS_MAP' fs/proc/task_mmu.c; then
    echo "      Already patched – skipping."
else
    python3 << 'PYEOF'
import sys

with open('fs/proc/task_mmu.c', 'r') as f:
    content = f.read()

SUS_MAP_BLOCK = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\t\tvma = find_vma(mm, start_vaddr);\n'
    '\t\tif (vma && vma->vm_file) {\n'
    '\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n'
    '\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n'
    '\t\t\t\tpm.buffer->pme = 0;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '#endif\n'
)

UNLOCK_VARIANTS = [
    '\t\tmmap_read_unlock(mm);\n',       # modern kernel API
    '\t\tup_read(&mm->mmap_sem);\n',     # legacy kernel API
]

patched = False
for unlock_line in UNLOCK_VARIANTS:
    old = (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        + unlock_line
        + '\t\tstart_vaddr = end;\n'
    )
    new = (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        + unlock_line
        + SUS_MAP_BLOCK
        + '\t\tstart_vaddr = end;\n'
    )
    if old in content:
        content = content.replace(old, new, 1)
        patched = True
        print(f'      Matched: {unlock_line.strip()}')
        break

if not patched:
    print('ERROR: walk_page_range/unlock context not found in fs/proc/task_mmu.c')
    sys.exit(1)

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)

print('      Done.')
sys.exit(0)
PYEOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Python failed for task_mmu.c hunk #8"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# include/linux/mount.h  – Hunk #1
# Replace ANDROID_KABI_RESERVE(4) with CONFIG-guarded ANDROID_KABI_USE.
# ─────────────────────────────────────────────────────────────────────────────
echo "[5/5] include/linux/mount.h – ANDROID_KABI_RESERVE(4) → KABI_USE..."

if grep -q 'susfs_mnt_id_backup' include/linux/mount.h; then
    echo "      Already patched – skipping."
else
    python3 << 'PYEOF'
import sys

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
    sys.exit(1)

content = content.replace(OLD, NEW, 1)

with open('include/linux/mount.h', 'w') as f:
    f.write(content)

print('      Done.')
sys.exit(0)
PYEOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Python failed for mount.h hunk #1"
        exit 1
    fi
fi

echo ""
echo "=== All supplementary fixes applied successfully! ==="
echo ""
echo "Summary of changes:"
echo "  fs/namespace.c         – susfs_def.h include (regex anchor),"
echo "                           extern declarations, clone_mnt() SUS_MOUNT guard"
echo "  fs/proc/task_mmu.c     – pagemap_read() SUS_MAP guard"
echo "  include/linux/mount.h  – ANDROID_KABI_USE(4, susfs_mnt_id_backup)"
echo ""
echo "NOTE: hunk #7 (vfs_kern_mount whitespace) intentionally skipped –"
echo "      this kernel uses the fs_context-based vfs_kern_mount implementation"
echo "      and the change was purely cosmetic whitespace."
