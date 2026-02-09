#!/usr/bin/env bash
set -e

# ========= CONFIG =========
KERNEL_ROOT="$(pwd)"
SUSFS_BRANCH="kernel-4.19"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
DEFCONFIG_PATH="arch/arm64/configs/vendor/kona-perf_defconfig"

echo "[+] Kernel root: $KERNEL_ROOT"

# ========= CLONE SUSFS =========
if [ -d "susfs4ksu" ]; then
  echo "[*] Removing existing susfs4ksu directory"
  rm -rf susfs4ksu
fi

echo "[+] Cloning susfs4ksu ($SUSFS_BRANCH)"
git clone "$SUSFS_REPO" -b "$SUSFS_BRANCH" susfs4ksu

# ========= COPY KERNEL FILES =========
echo "[+] Copying SUSFS kernel sources"

cp -v susfs4ksu/kernel_patches/fs/susfs.c fs/
cp -v susfs4ksu/kernel_patches/fs/sus_su.c fs/

cp -v susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/
cp -v susfs4ksu/kernel_patches/include/linux/sus_su.h include/linux/

# ========= APPLY KERNELSU PATCH =========
if [ ! -d "KernelSU-Next" ]; then
  echo "[!] KernelSU-Next directory not found!"
  exit 1
fi

echo "[+] Applying SUSFS patch to KernelSU-Next"
cd KernelSU-Next
patch -p1 -f -F 3 < ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
cd ..

# ========= APPLY KERNEL PATCH =========
echo "[+] Applying SUSFS kernel patch (4.19)"
patch -p1 -f -F 3 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch || true

# ========= ENABLE CONFIGS =========
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
} >> "$DEFCONFIG_PATH"

echo "[✓] SUSFS integration completed successfully"
