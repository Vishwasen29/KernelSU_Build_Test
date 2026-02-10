#!/usr/bin/env bash
set -e

KERNEL_ROOT="$(pwd)"
SUSFS_BRANCH="kernel-4.19"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
DEFCONFIG_PATH="arch/arm64/configs/vendor/kona-perf_defconfig"

echo "[+] Kernel root: $KERNEL_ROOT"

# ---- Clone SUSFS ----
rm -rf susfs4ksu
git clone "$SUSFS_REPO" -b "$SUSFS_BRANCH" susfs4ksu

# ---- Copy kernel source files ----
echo "[+] Copying SUSFS kernel files"

# fs
cp -v susfs4ksu/kernel_patches/fs/susfs.c fs/
cp -v susfs4ksu/kernel_patches/fs/sus_su.c fs/

# headers (IMPORTANT: include all)
cp -v susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/
cp -v susfs4ksu/kernel_patches/include/linux/susfs_def.h include/linux/
cp -v susfs4ksu/kernel_patches/include/linux/sus_su.h include/linux/

# ---- Patch KernelSU-Next ----
echo "[+] Applying SUSFS → KernelSU patch"
cd KernelSU-Next
patch -p1 -f -F 3 < ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
cd ..

# ---- Patch kernel ----
echo "[+] Applying SUSFS → kernel 4.19 patch"
patch -p1 -f -F 3 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch || true


echo "Fixing SUSFS alloc_vfsmnt call sites..."
    sed -i 's/alloc_vfsmnt(\(fc->source[^)]*\))/alloc_vfsmnt(\1, false, -1)/' fs/namespace.c
    sed -i 's/alloc_vfsmnt(\(old->mnt_devname[^)]*\))/alloc_vfsmnt(\1, false, -1)/' fs/namespace.c
    
# ---- Enable configs ----
echo "[+] Enabling SUSFS configs"

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
} >> "$DEFCONFIG_PATH"

echo "[✓] SUSFS integration complete"
