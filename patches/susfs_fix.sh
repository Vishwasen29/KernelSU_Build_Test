#!/usr/bin/env bash
set -e

KERNEL_ROOT="$(pwd)"
SUSFS_BRANCH="kernel-4.19"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
DEFCONFIG_PATH="arch/arm64/configs/vendor/kona-perf_defconfig"

echo "======================================"
echo " Applying KernelSU + SUSFS (4.19)"
echo " Target: ARM64 non-GKI"
echo "======================================"

echo "[+] Kernel root: $KERNEL_ROOT"

# --------------------------------------------------
# Clone SUSFS
# --------------------------------------------------
rm -rf susfs4ksu
git clone --depth=1 "$SUSFS_REPO" -b "$SUSFS_BRANCH" susfs4ksu

if [ ! -d susfs4ksu/kernel_patches ]; then
  echo "[-] susfs4ksu clone failed"
  exit 1
fi

# --------------------------------------------------
# Copy SUSFS kernel sources
# --------------------------------------------------
echo "[+] Installing SUSFS kernel sources"

# fs
install -Dm644 susfs4ksu/kernel_patches/fs/susfs.c fs/susfs.c
install -Dm644 susfs4ksu/kernel_patches/fs/sus_su.c fs/sus_su.c

# headers (ALL required)
install -Dm644 susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/susfs.h
install -Dm644 susfs4ksu/kernel_patches/include/linux/susfs_def.h include/linux/susfs_def.h
install -Dm644 susfs4ksu/kernel_patches/include/linux/sus_su.h include/linux/sus_su.h

# --------------------------------------------------
# Patch KernelSU-Next
# --------------------------------------------------
if [ ! -d KernelSU-Next ]; then
  echo "[-] KernelSU-Next directory not found"
  exit 1
fi

echo "[+] Patching KernelSU-Next for SUSFS"
pushd KernelSU-Next >/dev/null
patch -p1 -f -F 3 < ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
popd >/dev/null

# --------------------------------------------------
# Patch kernel 4.19
# --------------------------------------------------
echo "[+] Applying kernel 4.19 SUSFS patch"
patch -p1 -f -F 3 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch || true

# --------------------------------------------------
# KernelSU 4.19 compatibility fixes
# --------------------------------------------------
echo "[+] Applying KernelSU 4.19 compatibility fixes"

KSU_COMPAT="drivers/kernelsu/kernel_compat.h"

# access_ok wrapper
if ! grep -q "ksu_access_ok" "$KSU_COMPAT"; then
cat >> "$KSU_COMPAT" << 'EOF'

#if LINUX_VERSION_CODE < KERNEL_VERSION(5,0,0)
static inline int ksu_access_ok(const void *addr, unsigned long size)
{
    return access_ok(VERIFY_READ, addr, size);
}
#endif
EOF
fi

# kernel_read / kernel_write compat
if ! grep -q "ksu_kernel_read_compat" "$KSU_COMPAT"; then
cat >> "$KSU_COMPAT" << 'EOF'

#if LINUX_VERSION_CODE < KERNEL_VERSION(5,10,0)
static inline ssize_t ksu_kernel_read_compat(
    struct file *file, void *buf, size_t count, loff_t *pos)
{
    return kernel_read(file, buf, count, pos);
}

static inline ssize_t ksu_kernel_write_compat(
    struct file *file, const void *buf, size_t count, loff_t *pos)
{
    return kernel_write(file, buf, count, pos);
}
#endif
EOF
fi

# TWA_RESUME fix
if ! grep -q "TWA_RESUME" drivers/kernelsu/allowlist.c; then
sed -i 's/TWA_RESUME/0/g' drivers/kernelsu/allowlist.c
fi

# ksu_is_ksu_domain fix
sed -i 's/ksu_is_ksu_domain/is_ksu_domain/g' drivers/kernelsu/allowlist.c

# --------------------------------------------------
# Enable SUSFS configs
# --------------------------------------------------
echo "[+] Enabling SUSFS configs in defconfig"

grep -q CONFIG_KSU=y "$DEFCONFIG_PATH" || cat >> "$DEFCONFIG_PATH" << 'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SUS_SU=y
EOF

echo "======================================"
echo "[✓] KernelSU + SUSFS integration DONE"
echo "======================================"
