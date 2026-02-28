#!/bin/bash
# =============================================================================
# fix_build_errors.sh — SUSFS patch reject + compile error fixer
# Written against exact source content from susfs-patch-debug.zip
#
# Fixes 6 problems across 4 files:
#
# fs/namespace.c  (3 failed hunks from susfs_patch_to_4.19.patch)
#   Hunk #1  — Add susfs_def.h include and extern declarations
#              FAIL reason: patch expected sched/task.h → pnode.h directly,
#              but kernel has <linux/fs_context.h> between them.
#   Hunk #7  — SKIP: whitespace-only change inside vfs_kern_mount(); this
#              kernel uses fs_context API (not the old alloc_vfsmnt path that
#              the patch was written for). Safe to skip — no functional change.
#   Hunk #9  — Add SUS_MOUNT guard block in clone_mnt() before alloc_vfsmnt()
#   Hunk #10 — Add blank line before lock_mount_hash() in clone_mnt()
#
# fs/proc/task_mmu.c  (1 failed hunk)
#   Hunk #8  — Add SUS_MAP guard block after mmap_read_unlock(mm)
#              FAIL reason: patch expected up_read(&mm->mmap_sem) but kernel
#              uses the newer mmap_read_unlock(mm) wrapper.
#              NOTE: hunk #7 already succeeded and declared
#              "struct vm_area_struct *vma;" in the while-loop body.
#              Without hunk #8, that declaration is unused → build error.
#              This fix adds hunk #8's block which uses the vma variable.
#
# include/linux/mount.h  (1 failed hunk)
#   Hunk #1  — Replace ANDROID_KABI_RESERVE(4) with conditional KABI_USE
#              for susfs_mnt_id_backup
#
# drivers/kernelsu/supercalls.c  (3 compile errors — API name mismatch)
#   KernelSU-Next was integrated against a newer SUSFS API; the kernel-side
#   patch (v2.0.0) uses older names. Three identifiers need patching:
#     CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#     susfs_set_hide_sus_mnts_for_all_procs  → susfs_set_hide_sus_mnts_for_non_su_procs
#     susfs_add_try_umount()                  → add_try_umount() (static, same file)
#
# Usage:
#   cd <kernel-root>
#   bash $GITHUB_WORKSPACE/patches/fix_build_errors.sh
#   # or:
#   bash fix_build_errors.sh [kernel-root-dir]
# =============================================================================

set -euo pipefail
KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
skip() { echo -e "${YLW}[SKIP]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

for f in fs/namespace.c fs/proc/task_mmu.c include/linux/mount.h drivers/kernelsu/supercalls.c; do
    [[ -f "$f" ]] || err "Required file not found: $f  (run from kernel root)"
done

echo "================================================================="
echo " SUSFS patch reject + compile-error fixer"
echo "================================================================="

# ─────────────────────────────────────────────────────────────────────────────
# FILE 1:  fs/namespace.c
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── fs/namespace.c ──────────────────────────────────────────────"
python3 << 'PYEOF'
import sys, re

path = "fs/namespace.c"
with open(path) as f:
    src = f.read()

changed = False

# ── Hunk #1a: susfs_def.h include after <linux/sched/task.h> ─────────────────
# The patch failed because <linux/fs_context.h> sits between sched/task.h and
# pnode.h, breaking the context match. We anchor on sched/task.h directly.
INC_MARKER = '#include <linux/sched/task.h>\n'
INC_INSERT = (
    '#include <linux/sched/task.h>\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
)

if 'susfs_def.h' in src:
    print("[SKIP] namespace.c hunk#1a: susfs_def.h already included")
elif INC_MARKER not in src:
    print("[ERR]  namespace.c hunk#1a: anchor '#include <linux/sched/task.h>' not found")
    sys.exit(1)
else:
    src = src.replace(INC_MARKER, INC_INSERT, 1)
    print("[OK]   namespace.c hunk#1a: susfs_def.h include added after sched/task.h")
    changed = True

# ── Hunk #1b: extern declarations after #include "internal.h" ────────────────
INTERNAL_MARKER = '#include "internal.h"\n'
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

if 'susfs_is_current_ksu_domain' in src:
    print("[SKIP] namespace.c hunk#1b: extern declarations already present")
elif INTERNAL_MARKER not in src:
    print("[ERR]  namespace.c hunk#1b: anchor '#include \"internal.h\"' not found")
    sys.exit(1)
else:
    src = src.replace(INTERNAL_MARKER, INTERNAL_INSERT, 1)
    print("[OK]   namespace.c hunk#1b: extern declarations added after internal.h")
    changed = True

# ── Hunk #7: SKIP ─────────────────────────────────────────────────────────────
# Whitespace-only change inside vfs_kern_mount(); that function uses the new
# fs_context API in this kernel, not the old alloc_vfsmnt path. Nothing to do.
print("[SKIP] namespace.c hunk#7: not applicable (fs_context vfs_kern_mount)")

# ── Hunk #9: SUS_MOUNT guard block in clone_mnt() ────────────────────────────
# Exact anchor from namespace.c.orig lines 1040-1045 (inside clone_mnt):
#   \tint err;\n\n\tmnt = alloc_vfsmnt(old->mnt_devname);\n\tif (!mnt)\n...
H9_OLD = (
    '\tint err;\n'
    '\n'
    '\tmnt = alloc_vfsmnt(old->mnt_devname);\n'
    '\tif (!mnt)\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
)
H9_NEW = (
    '\tint err;\n'
    '\n'
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

if 'bypass_orig_flow' in src:
    print("[SKIP] namespace.c hunk#9: SUS_MOUNT guard block already present")
elif H9_OLD not in src:
    print("[ERR]  namespace.c hunk#9: clone_mnt alloc_vfsmnt anchor not found")
    sys.exit(1)
else:
    src = src.replace(H9_OLD, H9_NEW, 1)
    print("[OK]   namespace.c hunk#9: SUS_MOUNT guard block added to clone_mnt()")
    changed = True

# ── Hunk #10: blank line before lock_mount_hash() in clone_mnt() ─────────────
# Exact anchor from namespace.c.orig lines 1093-1094:
H10_OLD = '\tmnt->mnt_parent = mnt;\n\tlock_mount_hash();\n'
H10_NEW = '\tmnt->mnt_parent = mnt;\n\n\tlock_mount_hash();\n'

if H10_NEW in src:
    print("[SKIP] namespace.c hunk#10: blank line before lock_mount_hash() already present")
elif H10_OLD not in src:
    print("[ERR]  namespace.c hunk#10: mnt_parent/lock_mount_hash anchor not found")
    sys.exit(1)
else:
    # Only the first occurrence is inside clone_mnt()
    src = src.replace(H10_OLD, H10_NEW, 1)
    print("[OK]   namespace.c hunk#10: blank line added before lock_mount_hash()")
    changed = True

if changed:
    with open(path, "w") as f:
        f.write(src)
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# FILE 2:  fs/proc/task_mmu.c
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── fs/proc/task_mmu.c ──────────────────────────────────────────"
python3 << 'PYEOF'
import sys

path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

changed = False

# ── Hunk #8: SUS_MAP block after mmap_read_unlock(mm) ────────────────────────
#
# The patch failed because it expected up_read(&mm->mmap_sem) but the kernel
# uses the newer mmap_read_unlock(mm) wrapper. Hunk #7 already succeeded and
# added "struct vm_area_struct *vma;" inside the while-loop body. Without
# hunk #8 (which uses that variable), it stays unused → compile error.
#
# Exact anchor from task_mmu.c.orig lines 1619-1621:
H8_OLD = (
    '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
    '\t\tmmap_read_unlock(mm);\n'
    '\t\tstart_vaddr = end;\n'
)
H8_NEW = (
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
)

if 'BIT_SUS_MAPS' in src:
    print("[SKIP] task_mmu.c hunk#8: SUS_MAP block already present")
elif H8_OLD not in src:
    print("[ERR]  task_mmu.c hunk#8: mmap_read_unlock anchor not found")
    sys.exit(1)
else:
    src = src.replace(H8_OLD, H8_NEW, 1)
    print("[OK]   task_mmu.c hunk#8: SUS_MAP block added after mmap_read_unlock()")
    changed = True

if changed:
    with open(path, "w") as f:
        f.write(src)
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# FILE 3:  include/linux/mount.h
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── include/linux/mount.h ───────────────────────────────────────"
python3 << 'PYEOF'
import sys

path = "include/linux/mount.h"
with open(path) as f:
    src = f.read()

# ── Hunk #1: ANDROID_KABI_RESERVE(4) → conditional KABI_USE ─────────────────
# Exact anchor from mount.h.rej context (surrounding RESERVE lines + void *data):
H_OLD = '\tANDROID_KABI_RESERVE(4);\n'
H_NEW = (
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n'
    '#else\n'
    '\tANDROID_KABI_RESERVE(4);\n'
    '#endif\n'
)

if 'susfs_mnt_id_backup' in src:
    print("[SKIP] mount.h hunk#1: susfs_mnt_id_backup already present")
elif H_OLD not in src:
    print("[ERR]  mount.h hunk#1: ANDROID_KABI_RESERVE(4) anchor not found")
    sys.exit(1)
else:
    src = src.replace(H_OLD, H_NEW, 1)
    with open(path, "w") as f:
        f.write(src)
    print("[OK]   mount.h hunk#1: ANDROID_KABI_RESERVE(4) replaced with conditional KABI_USE")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# FILE 4:  drivers/kernelsu/supercalls.c
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── drivers/kernelsu/supercalls.c ───────────────────────────────"
python3 << 'PYEOF'
import sys, re

path = "drivers/kernelsu/supercalls.c"
with open(path) as f:
    src = f.read()

changed = False

# ── Errors (a) + (b): CMD/function name mismatch ─────────────────────────────
# KernelSU-Next calls:
#   CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS          (line 797)
#   susfs_set_hide_sus_mnts_for_all_procs()         (line 798)
# but susfs.h (v2.0.0) only defines:
#   CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#   susfs_set_hide_sus_mnts_for_non_su_procs()
#
# Inject a compat shim block right after the last #include in the file.

SHIM_SENTINEL = 'SUSFS_v2_compat_shim'
SHIM_BLOCK = (
    '\n'
    '/* ' + SHIM_SENTINEL + ' — auto-added by fix_build_errors.sh\n'
    ' * KernelSU-Next SUSFS integration uses newer "FOR_ALL_PROCS" API names;\n'
    ' * the kernel-side SUSFS patch (v2.0.0) only has "FOR_NON_SU_PROCS" names. */\n'
    '#if defined(CONFIG_KSU_SUSFS) && !defined(CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS)\n'
    '#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS \\\n'
    '        CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS\n'
    'static __always_inline void\n'
    'susfs_set_hide_sus_mnts_for_all_procs(void __user **arg)\n'
    '{\n'
    '        susfs_set_hide_sus_mnts_for_non_su_procs(arg);\n'
    '}\n'
    '#endif /* SUSFS_v2_compat_shim */\n'
)

if SHIM_SENTINEL in src:
    print("[SKIP] supercalls.c (a+b): compat shim already present")
else:
    last_inc = None
    for m in re.finditer(r'^#include\s+[<"][^\n]+', src, re.MULTILINE):
        last_inc = m
    if not last_inc:
        print("[ERR]  supercalls.c (a+b): no #include found — cannot inject shim")
        sys.exit(1)
    pos = last_inc.end()
    src = src[:pos] + SHIM_BLOCK + src[pos:]
    print("[OK]   supercalls.c (a+b): CMD/function compat shim injected after includes")
    changed = True

# ── Error (c): susfs_add_try_umount → add_try_umount ─────────────────────────
# KernelSU-Next calls susfs_add_try_umount() expecting an exported symbol, but
# v2.0.0 only has static add_try_umount() in this same file (line 586).
# The compiler itself hints: "did you mean 'add_try_umount'?"

if 'susfs_add_try_umount' in src:
    src = src.replace('susfs_add_try_umount(', 'add_try_umount(')
    print("[OK]   supercalls.c (c): susfs_add_try_umount() → add_try_umount()")
    changed = True
else:
    print("[SKIP] supercalls.c (c): susfs_add_try_umount not present")

if changed:
    with open(path, "w") as f:
        f.write(src)
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================="
echo " All fixes applied. Summary:"
echo ""
echo "  fs/namespace.c"
echo "    hunk#1a  susfs_def.h include after <linux/sched/task.h>"
echo "    hunk#1b  extern declarations + CL_COPY_MNT_NS after internal.h"
echo "    hunk#7   SKIPPED (fs_context vfs_kern_mount — no applicable change)"
echo "    hunk#9   SUS_MOUNT guard block + bypass_orig_flow in clone_mnt()"
echo "    hunk#10  blank line before lock_mount_hash() in clone_mnt()"
echo ""
echo "  fs/proc/task_mmu.c"
echo "    hunk#8   SUS_MAP block after mmap_read_unlock(mm)  [resolves unused vma]"
echo ""
echo "  include/linux/mount.h"
echo "    hunk#1   ANDROID_KABI_RESERVE(4) → conditional KABI_USE"
echo "             for susfs_mnt_id_backup"
echo ""
echo "  drivers/kernelsu/supercalls.c"
echo "    (a+b)  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS + function compat shim"
echo "    (c)    susfs_add_try_umount() → add_try_umount()"
echo ""
echo " Re-run the kernel build."
echo "================================================================="
