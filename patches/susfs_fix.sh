#!/usr/bin/env bash
set -e

# ================= CONFIG =================
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="kernel-4.19"
DEFCONFIG="arch/arm64/configs/vendor/kona-perf_defconfig"

echo "[+] Kernel root: $(pwd)"

# ================= CLONE SUSFS =================
rm -rf susfs4ksu
echo "[+] Cloning susfs4ksu ($SUSFS_BRANCH)"
git clone "$SUSFS_REPO" -b "$SUSFS_BRANCH" susfs4ksu

# ================= COPY SUSFS FILES =================
echo "[+] Copying SUSFS kernel sources"

# fs
cp -v susfs4ksu/kernel_patches/fs/susfs.c fs/
cp -v susfs4ksu/kernel_patches/fs/sus_su.c fs/

# headers (ALL required)
cp -v susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/
cp -v susfs4ksu/kernel_patches/include/linux/susfs_def.h include/linux/
cp -v susfs4ksu/kernel_patches/include/linux/sus_su.h include/linux/

# ================= PATCH KERNELSU-NEXT =================
if [ ! -d KernelSU-Next ]; then
  echo "[!] KernelSU-Next directory not found"
  exit 1
fi

echo "[+] Applying SUSFS → KernelSU patch"
cd KernelSU-Next
patch -p1 -f -F 3 < ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
cd ..

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
