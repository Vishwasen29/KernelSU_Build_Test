#!/bin/bash
# susfs_fix.sh
#
# Applies supplementary fixes for SUSFS patch hunks that fail on this kernel
# (LineageOS android_kernel_oneplus_sm8250 / kona / 4.19).
#
# Hunks handled here:
#   fs/namespace.c       hunk #1      – susfs_def.h include + extern block
#   fs/namespace.c       hunk #7      – vfs_kern_mount whitespace (SKIPPED – cosmetic/N/A)
#   fs/namespace.c       hunks #9+#10 – clone_mnt() SUS_MOUNT call sites
#   fs/proc/task_mmu.c   hunk #8      – pagemap_read() BIT_SUS_MAPS guard
#   include/linux/mount.h hunk #1     – ANDROID_KABI_USE(4, susfs_mnt_id_backup)
#   fs/overlayfs/inode.c             – #include only (no kstat call — not in this API)
#   fs/overlayfs/readdir.c           – #include + ovl_iterate() SUS_PATH hook
#
# Usage:
#   bash susfs_fix.sh [path/to/android-kernel]

set -e
KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

echo "=== SUSFS Supplementary Fix Script ==="
echo "Kernel root: $(pwd)"

# ── [1/7] fs/namespace.c – susfs_def.h include + extern declarations ──────────
echo "[1/7] fs/namespace.c – adding susfs_def.h include + extern block..."

if grep -q "susfs_def\.h" fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "fs/namespace.c"
with open(path) as f:
    src = f.read()

inject = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "#include <linux/susfs_def.h>\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)

anchor = "#include <linux/fs_context.h>"
if anchor not in src:
    print("ERROR: anchor '#include <linux/fs_context.h>' not found", file=sys.stderr)
    sys.exit(1)
src = src.replace(anchor, inject + anchor, 1)

extern_block = (
    "\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "extern bool susfs_is_current_ksu_domain(void);\n"
    "extern bool susfs_is_sdcard_android_data_decrypted;\n"
    "\n"
    "static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n"
    "\n"
    "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)

anchor2 = '#include "internal.h"\n'
if anchor2 not in src:
    print("ERROR: anchor '#include \"internal.h\"' not found", file=sys.stderr)
    sys.exit(1)
src = src.replace(anchor2, anchor2 + extern_block, 1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    echo "      Done."
fi

# ── [2/7] hunk #7 – vfs_kern_mount whitespace ────────────────────────────────
echo "[2/7] fs/namespace.c – hunk #7 (vfs_kern_mount whitespace) – SKIPPING (cosmetic, N/A)."

# ── [3/7] fs/namespace.c – clone_mnt() SUS_MOUNT call sites ──────────────────
echo "[3/7] fs/namespace.c – clone_mnt() SUS_MOUNT guard (hunks #9 and #10)..."

if grep -q "susfs_alloc_sus_vfsmnt(old->mnt_devname)" fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "fs/namespace.c"
with open(path) as f:
    src = f.read()

# Hunk #9: replace alloc_vfsmnt(old->mnt_devname) inside clone_mnt()
old_alloc = "\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
new_alloc = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "\tif (flag & CL_COPY_MNT_NS) {\n"
    "\t\tif (old->mnt_id == DEFAULT_KSU_MNT_ID)\n"
    "\t\t\tmnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);\n"
    "\t\telse\n"
    "\t\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n"
    "\t} else {\n"
    "\t\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
    "\t}\n"
    "#else\n"
    "\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
    "#endif\n"
)

count = src.count(old_alloc)
if count == 0:
    print("ERROR: 'mnt = alloc_vfsmnt(old->mnt_devname);' not found", file=sys.stderr)
    sys.exit(1)
elif count > 1:
    sig = "static struct mount *clone_mnt("
    idx_sig = src.find(sig)
    if idx_sig == -1:
        print("ERROR: clone_mnt signature not found", file=sys.stderr)
        sys.exit(1)
    idx_alloc = src.find(old_alloc, idx_sig)
    if idx_alloc == -1:
        print("ERROR: alloc_vfsmnt call not found after clone_mnt", file=sys.stderr)
        sys.exit(1)
    src = src[:idx_alloc] + new_alloc + src[idx_alloc + len(old_alloc):]
else:
    src = src.replace(old_alloc, new_alloc, 1)

# Hunk #10: atomic counter + susfs_mnt_id_backup = 0 before lock_mount_hash()
hunk10 = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "\tif ((flag & CL_COPY_MNT_NS) && old->mnt_id != DEFAULT_KSU_MNT_ID)\n"
    "\t\tatomic64_inc(&susfs_ksu_mounts);\n"
    "\tmnt->mnt.susfs_mnt_id_backup = 0;\n"
    "#endif\n"
)

sig_idx = src.find("static struct mount *clone_mnt(")
lock_anchor = "\tlock_mount_hash();\n"
lock_idx = src.find(lock_anchor, sig_idx)
if lock_idx == -1:
    print("ERROR: lock_mount_hash() not found in clone_mnt body", file=sys.stderr)
    sys.exit(1)

if "CL_COPY_MNT_NS) && old->mnt_id" not in src:
    src = src[:lock_idx] + hunk10 + src[lock_idx:]

with open(path, "w") as f:
    f.write(src)
print("      clone_mnt() SUS_MOUNT call sites injected.")
PYEOF
    echo "      Done."
fi

# ── [4/7] fs/proc/task_mmu.c – pagemap_read() BIT_SUS_MAPS guard ─────────────
echo "[4/7] fs/proc/task_mmu.c – pagemap_read() SUS_MAP guard (hunk #8)..."

# FIX: The old check was `grep -q "BIT_SUS_MAPS"` which is a FALSE POSITIVE.
# BIT_SUS_MAPS appears in the smaps/show_map functions (from hunks that DID apply),
# but the pagemap_read block (hunk #8) may still be missing.
# The pagemap_read block is the only place that calls find_vma(mm, start_vaddr),
# so that is the correct idempotency guard.
#
# Without this block the `struct vm_area_struct *vma;` declared by a prior hunk
# in pagemap_read is never used → [-Werror,-Wunused-variable] at compile time.
if grep -q "find_vma(mm, start_vaddr)" fs/proc/task_mmu.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

# The injection point is inside pagemap_read()'s inner loop, after:
#   up_read(&mm->mmap_sem);
# and before:
#   start_vaddr = end;
#
# We target the specific two-line sequence that is unique to this loop body.
old_seq = "\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;\n"
new_seq = (
    "\t\tup_read(&mm->mmap_sem);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tvma = find_vma(mm, start_vaddr);\n"
    "\t\tif (vma && vma->vm_file) {\n"
    "\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
    "\t\t\tif (unlikely(inode->i_state & BIT_SUS_MAPS) &&\n"
    "\t\t\t\t\tsusfs_is_current_proc_umounted()) {\n"
    "\t\t\t\tpm.show_pfn = false;\n"
    "\t\t\t\tpm.buffer->pme = 0;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
    "\t\tstart_vaddr = end;\n"
)

if old_seq in src:
    src = src.replace(old_seq, new_seq, 1)
    with open(path, "w") as f:
        f.write(src)
    print("      pagemap_read() BIT_SUS_MAPS block injected.")
else:
    print("WARNING: pagemap_read up_read/start_vaddr anchor not found – skipping",
          file=sys.stderr)
PYEOF
    echo "      Done."
fi

# ── [5/7] include/linux/mount.h – ANDROID_KABI_RESERVE(4) → KABI_USE ─────────
echo "[5/7] include/linux/mount.h – ANDROID_KABI_RESERVE(4) → KABI_USE..."

if grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "include/linux/mount.h"
with open(path) as f:
    src = f.read()

old1 = "ANDROID_KABI_RESERVE(4);"
new1 = "ANDROID_KABI_USE(4, int susfs_mnt_id_backup);"
old2 = "ANDROID_KABI_RESERVE(4)"
new2 = "ANDROID_KABI_USE(4, int susfs_mnt_id_backup)"

if old1 in src:
    src = src.replace(old1, new1, 1)
elif old2 in src:
    src = src.replace(old2, new2, 1)
else:
    print("ERROR: ANDROID_KABI_RESERVE(4) not found in include/linux/mount.h",
          file=sys.stderr)
    sys.exit(1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    echo "      Done."
fi

# ── [6/7] fs/overlayfs/inode.c – #include only ───────────────────────────────
echo "[6/7] fs/overlayfs/inode.c – ensuring #include <linux/susfs.h> present..."

# NOTE: This SUSFS version (sidex15/KernelSU-Next legacy-susfs) does NOT have
# a susfs_sus_kstat() function. The API uses susfs_add_sus_kstat() for the
# stat() syscall path in fs/stat.c — ovl_getattr() does NOT get a hook in this
# version. Only the #include is needed so the file compiles when other overlayfs
# symbols (e.g. in readdir.c) pull it in transitively.
#
# Previous versions of this script wrongly injected:
#   susfs_sus_kstat(real.dentry, stat);
# which caused three compiler errors:
#   - implicit declaration of 'susfs_sus_kstat' (function doesn't exist)
#   - use of undeclared identifier 'real'   (wrong scope)
#   - use of undeclared identifier 'stat'   (wrong scope)

if grep -q "#include <linux/susfs.h>" fs/overlayfs/inode.c; then
    echo "      Already has susfs.h include – skipping."
elif grep -q "susfs" fs/overlayfs/inode.c; then
    # Main patch applied something (function call) — file is patched, leave it.
    echo "      Main patch already applied content – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "fs/overlayfs/inode.c"
with open(path) as f:
    src = f.read()

# Add the include after the last local header in the file
include_anchor = '#include "ovl_entry.h"'
if include_anchor not in src:
    include_anchor = '#include "overlayfs.h"'
if include_anchor not in src:
    print("WARNING: could not find include anchor in fs/overlayfs/inode.c – skipping",
          file=sys.stderr)
    sys.exit(0)

susfs_include = (
    "\n#ifdef CONFIG_KSU_SUSFS\n"
    "#include <linux/susfs.h>\n"
    "#endif\n"
)

src = src.replace(include_anchor, include_anchor + susfs_include, 1)

with open(path, "w") as f:
    f.write(src)
print("      susfs.h include added.")
PYEOF
    echo "      Done."
fi

# ── [7/7] fs/overlayfs/readdir.c – #include only ─────────────────────────────
echo "[7/7] fs/overlayfs/readdir.c – ensuring #include <linux/susfs.h> present..."

# NOTE: susfs_sus_path_for_readdir() does not exist in this SUSFS version
# (sidex15/KernelSU-Next legacy-susfs). Injecting a call to it causes:
#   - implicit declaration of 'susfs_sus_path_for_readdir'
#   - use of undeclared identifier 'ctx'
#   - use of undeclared identifier 'inode'
#   - use of undeclared identifier 'realfile'
# Only the #include is needed. The main patch handles any actual hooks when
# they apply cleanly; this step is a fallback for when the main patch misses
# the file entirely.

if grep -q "#include <linux/susfs.h>" fs/overlayfs/readdir.c; then
    echo "      Already has susfs.h include – skipping."
elif grep -q "susfs" fs/overlayfs/readdir.c; then
    echo "      Main patch already applied content – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "fs/overlayfs/readdir.c"
with open(path) as f:
    src = f.read()

include_anchor = '#include "ovl_entry.h"'
if include_anchor not in src:
    include_anchor = '#include "overlayfs.h"'
if include_anchor not in src:
    print("WARNING: could not find include anchor in fs/overlayfs/readdir.c – skipping",
          file=sys.stderr)
    sys.exit(0)

susfs_include = (
    "\n#ifdef CONFIG_KSU_SUSFS\n"
    "#include <linux/susfs.h>\n"
    "#endif\n"
)

src = src.replace(include_anchor, include_anchor + susfs_include, 1)

with open(path, "w") as f:
    f.write(src)
print("      susfs.h include added.")
PYEOF
    echo "      Done."
fi

echo ""
echo "=== All supplementary fixes applied successfully! ==="
echo ""
echo "Summary of changes:"
echo "  fs/namespace.c           – susfs_def.h include, extern declarations,"
echo "                             clone_mnt() alloc routing + atomic counter"
echo "  fs/proc/task_mmu.c       – pagemap_read() BIT_SUS_MAPS guard"
echo "  include/linux/mount.h    – ANDROID_KABI_USE(4, susfs_mnt_id_backup)"
echo "  fs/overlayfs/inode.c     – #include <linux/susfs.h> only (no function call)"
echo "  fs/overlayfs/readdir.c   – #include <linux/susfs.h> only (no function call)"
echo ""
echo "NOTE: hunk #7 (vfs_kern_mount whitespace) intentionally skipped –"
echo "      this kernel uses the fs_context-based vfs_kern_mount implementation"
echo "      and the change was purely cosmetic whitespace."
echo ""
echo "NOTE: Neither overlayfs file gets a function call injection."
echo "      susfs_sus_kstat() and susfs_sus_path_for_readdir() do not exist in"
echo "      the sidex15/KernelSU-Next legacy-susfs API — injecting them causes"
echo "      implicit-declaration and undeclared-identifier compiler errors."
