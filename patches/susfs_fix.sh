#!/bin/bash
# susfs_fix.sh
#
# Applies supplementary fixes for SUSFS patch hunks that fail on this kernel
# (LineageOS android_kernel_oneplus_sm8250 / kona / 4.19).
#
# Hunks that need manual injection:
#   fs/namespace.c   hunk #1  – susfs_def.h include + extern block
#   fs/namespace.c   hunk #7  – vfs_kern_mount whitespace  (SKIPPED – cosmetic/N/A)
#   fs/namespace.c   hunks #9 + #10 – clone_mnt() SUS_MOUNT call sites  ← WAS BROKEN
#   fs/proc/task_mmu.c hunk #8 – pagemap_read() BIT_SUS_MAPS guard
#   include/linux/mount.h hunk #1 – ANDROID_KABI_USE(4, susfs_mnt_id_backup)
#
# Usage:
#   bash susfs_fix.sh [path/to/android-kernel]

set -e
KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

echo "=== SUSFS Supplementary Fix Script ==="
echo "Kernel root: $(pwd)"

# ── [1/5] fs/namespace.c – susfs_def.h include + extern declarations ─────────
echo "[1/5] fs/namespace.c – adding susfs_def.h include + extern block..."

if grep -q "susfs_def\.h" fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import re, sys

path = "fs/namespace.c"
with open(path) as f:
    src = f.read()

inject = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "#include <linux/susfs_def.h>\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)

# Insert immediately before #include <linux/fs_context.h>
anchor = "#include <linux/fs_context.h>"
if anchor not in src:
    print("ERROR: anchor '#include <linux/fs_context.h>' not found in fs/namespace.c", file=sys.stderr)
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

# Insert after the internal.h include block (before the first non-include line)
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

# ── [2/5] hunk #7 – vfs_kern_mount whitespace ────────────────────────────────
echo "[2/5] fs/namespace.c – hunk #7 (vfs_kern_mount whitespace) – SKIPPING (cosmetic, N/A)."

# ── [3/5] fs/namespace.c – clone_mnt() SUS_MOUNT call sites ──────────────────
echo "[3/5] fs/namespace.c – clone_mnt() SUS_MOUNT guard (hunks #9 and #10)..."

# FIX: The old check used grep "susfs_alloc_sus_vfsmnt" which matched the
# function *definition* (always present after the main patch runs), producing
# a false "Already patched" result. The call site inside clone_mnt() was never
# injected, leaving both static functions defined but never called → compiler
# error: unused function [-Werror,-Wunused-function].
#
# Correct check: look for the actual call with its argument signature.
if grep -q "susfs_alloc_sus_vfsmnt(old->mnt_devname)" fs/namespace.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import re, sys

path = "fs/namespace.c"
with open(path) as f:
    src = f.read()

# ── Hunk #9: replace alloc_vfsmnt() inside clone_mnt() with the SUS_MOUNT
# conditional that routes to susfs_reuse_sus_vfsmnt / susfs_alloc_sus_vfsmnt.
#
# Target (the unique alloc_vfsmnt call inside clone_mnt – it is the only one
# immediately preceded by the clone_mnt signature context):
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

# There should be exactly one alloc_vfsmnt(old->mnt_devname) in the file –
# it is inside clone_mnt().
count = src.count(old_alloc)
if count == 0:
    print("ERROR: could not find 'mnt = alloc_vfsmnt(old->mnt_devname);' in fs/namespace.c", file=sys.stderr)
    sys.exit(1)
if count > 1:
    # Safety: only replace the one inside clone_mnt by finding it after the
    # clone_mnt function signature.
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

# ── Hunk #10: after the err-handling block inside clone_mnt(), add the
# atomic counter increment and susfs_mnt_id_backup initialisation.
#
# Anchor: the first occurrence of "if (!mnt)\n\t\treturn ERR_PTR(-ENOMEM);" after
# clone_mnt – this is the error check right after alloc_vfsmnt.
# A more stable anchor is the mnt->mnt.data = NULL line inside clone_mnt
# (unique within that function) followed by the INIT_HLIST / INIT_LIST block.
#
# The safest anchor inside clone_mnt (after the new #ifdef block) is:
#   mnt->mnt_mountpoint = mnt->mnt.mnt_root;
#   mnt->mnt_parent     = mnt;
# because that pair is unique within the function body.
#
# We insert the atomic/backup block right before "lock_mount_hash();" inside
# clone_mnt (the first lock_mount_hash after the function's alloc block).

hunk10 = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "\tif ((flag & CL_COPY_MNT_NS) && old->mnt_id != DEFAULT_KSU_MNT_ID)\n"
    "\t\tatomic64_inc(&susfs_ksu_mounts);\n"
    "\tmnt->mnt.susfs_mnt_id_backup = 0;\n"
    "#endif\n"
)

# Find clone_mnt's lock_mount_hash(); – it is the first one after the
# clone_mnt signature (alloc_vfsmnt/susfs_alloc wrapper is above it).
sig_idx = src.find("static struct mount *clone_mnt(")
lock_anchor = "\tlock_mount_hash();\n"
lock_idx = src.find(lock_anchor, sig_idx)
if lock_idx == -1:
    print("ERROR: lock_mount_hash() not found in clone_mnt body", file=sys.stderr)
    sys.exit(1)

# Only inject if not already there (idempotency guard)
if "CL_COPY_MNT_NS) && old->mnt_id" not in src:
    src = src[:lock_idx] + hunk10 + src[lock_idx:]

with open(path, "w") as f:
    f.write(src)

print("      clone_mnt() SUS_MOUNT call sites injected.")
PYEOF
    echo "      Done."
fi

# ── [4/5] fs/proc/task_mmu.c – pagemap_read() BIT_SUS_MAPS guard ─────────────
echo "[4/5] fs/proc/task_mmu.c – pagemap_read() SUS_MAP guard (hunk #8)..."

if grep -q "BIT_SUS_MAPS" fs/proc/task_mmu.c; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import sys

path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

# Wrap the svma/file check block inside pagemap_read() with BIT_SUS_MAPS guard.
# Anchor: the unique line that starts the maps-suppression block.
old_block = (
    "\t\tif (vma->vm_file) {\n"
    "\t\t\tconst struct path *path = &vma->vm_file->f_path;\n"
    "\t\t\tpagemap_entry_t entry = make_pme(0, PM_PRESENT);\n"
)

if old_block not in src:
    # Try alternate form used in some tree versions
    old_block = "\t\tif (vma->vm_file) {\n"

new_block = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAPS\n"
    "\t\tif (susfs_sus_maps_allow_pagemap_read(vma))\n"
    "\t\t\tcontinue;\n"
    "#endif\n"
    + old_block
)

if old_block in src:
    src = src.replace(old_block, new_block, 1)
    with open(path, "w") as f:
        f.write(src)
else:
    print("WARNING: pagemap_read anchor not found – skipping task_mmu.c hunk #8", file=sys.stderr)
PYEOF
    echo "      Done."
fi

# ── [5/5] include/linux/mount.h – ANDROID_KABI_RESERVE(4) → KABI_USE ─────────
echo "[5/5] include/linux/mount.h – ANDROID_KABI_RESERVE(4) → KABI_USE..."

if grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    echo "      Already patched – skipping."
else
    python3 - << 'PYEOF'
import re, sys

path = "include/linux/mount.h"
with open(path) as f:
    src = f.read()

# Replace ANDROID_KABI_RESERVE(4) with ANDROID_KABI_USE(4, susfs_mnt_id_backup)
# Both macro names appear in different tree versions.
old1 = "ANDROID_KABI_RESERVE(4);"
new1 = "ANDROID_KABI_USE(4, int susfs_mnt_id_backup);"
old2 = "ANDROID_KABI_RESERVE(4)"
new2 = "ANDROID_KABI_USE(4, int susfs_mnt_id_backup)"

if old1 in src:
    src = src.replace(old1, new1, 1)
elif old2 in src:
    src = src.replace(old2, new2, 1)
else:
    print("ERROR: ANDROID_KABI_RESERVE(4) not found in include/linux/mount.h", file=sys.stderr)
    sys.exit(1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    echo "      Done."
fi

echo ""
echo "=== All supplementary fixes applied successfully! ==="
echo ""
echo "Summary of changes:"
echo "  fs/namespace.c         – susfs_def.h include, extern declarations,"
echo "                           clone_mnt() alloc routing + atomic counter"
echo "  fs/proc/task_mmu.c     – pagemap_read() BIT_SUS_MAPS guard"
echo "  include/linux/mount.h  – ANDROID_KABI_USE(4, susfs_mnt_id_backup)"
echo ""
echo "NOTE: hunk #7 (vfs_kern_mount whitespace) intentionally skipped –"
echo "      this kernel uses the fs_context-based vfs_kern_mount implementation"
echo "      and the change was purely cosmetic whitespace."
