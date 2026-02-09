#!/bin/bash
set -e

echo "=============================="
echo " Applying KernelSU + SUSFS "
echo " Target: ARM64 non-GKI 4.19 "
echo "=============================="

KERNEL_DIR="$(pwd)"
SUSFS_DIR="../susfs4ksu"

# Sanity checks
[ -d "$SUSFS_DIR" ] || { echo "susfs4ksu not found"; exit 1; }
[ -d "drivers/kernelsu" ] || { echo "KernelSU not found"; exit 1; }

echo "[1/6] Copying SUSFS sources"

cp -v "$SUSFS_DIR/kernel_patches/fs/susfs.c" fs/ || true
cp -v "$SUSFS_DIR/kernel_patches/fs/sus_su.c" fs/ || true
cp -v "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" include/linux/ || true
cp -v "$SUSFS_DIR/kernel_patches/include/linux/sus_su.h" include/linux/ || true

echo "[2/6] Applying KernelSU SUSFS enable patch"

cd drivers/kernelsu
patch -p1 -f -F 3 < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true
cd "$KERNEL_DIR"

echo "[3/6] Applying core SUSFS kernel patch"

patch -p1 -f -F 3 < "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.19.patch" || true

echo "[4/6] Fixing KernelSU-Next compat layer for ARM64 4.19"

cat > drivers/kernelsu/kernel_compat.h << 'EOF'
#pragma once

#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/sched.h>
#include <linux/task_work.h>

/*
 * filp_open compat
 */
static inline struct file *
ksu_filp_open_compat(const char *filename, int flags, umode_t mode)
{
    return filp_open(filename, flags, mode);
}

/*
 * access_ok compat (ARM64 4.19 requires 3 args)
 */
static inline int
ksu_access_ok(const void *addr, unsigned long size)
{
#ifdef access_ok
    return access_ok(VERIFY_READ, addr, size);
#else
    return 1;
#endif
}

/*
 * kernel_read / kernel_write compat
 */
static inline ssize_t
ksu_kernel_read_compat(struct file *file, void *buf, size_t count, loff_t *pos)
{
    return kernel_read(file, buf, count, pos);
}

static inline ssize_t
ksu_kernel_write_compat(struct file *file, const void *buf, size_t count, loff_t *pos)
{
    return kernel_write(file, buf, count, pos);
}

/*
 * task_work_add flag compat
 */
#ifndef TWA_RESUME
#define TWA_RESUME TWA_SIGNAL
#endif

EOF

echo "[5/6] Fixing allowlist symbol mismatch"

sed -i 's/ksu_is_ksu_domain/is_ksu_domain/g' \
  drivers/kernelsu/allowlist.c || true

echo "[6/6] Enabling KernelSU + SUSFS config options"

DEFCONFIG="arch/arm64/configs/vendor/kona-perf_defconfig"

cat >> "$DEFCONFIG" << 'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_SU=y
EOF

echo "=================================="
echo " KernelSU + SUSFS patching DONE ✅ "
echo "=================================="cd ..

echo "[+] Applying SUSFS → kernel 4.19 patch"
patch -p1 -f -F 3 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch || true

# ================= FIX KERNELSU-NEXT (4.19 NON-GKI) =================
echo "[+] Fixing KernelSU-Next compat layer for 4.19 non-GKI"

cat > drivers/kernelsu/kernel_compat.h << 'EOF'
#pragma once

#include <linux/fs.h>
#include <linux/uaccess.h>

static inline struct file *
ksu_filp_open_compat(const char *filename, int flags, umode_t mode)
{
    return filp_open(filename, flags, mode);
}

static inline int
ksu_access_ok(const void *addr, unsigned long size)
{
#if defined(access_ok)
    return access_ok(addr, size);
#else
    return 1;
#endif
}
EOF

echo "[+] Fixing KernelSU domain hook naming"

sed -i 's/ksu_is_ksu_domain/is_ksu_domain/g' \
  drivers/kernelsu/allowlist.c || true

# ================= ENABLE CONFIGS =================
echo "[+] Enabling SUSFS configs in defconfig"

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y"
  echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_SUS_SU=y"
} >> "$DEFCONFIG"

echo "[✓] SUSFS + KernelSU-Next integration completed successfully"
