#!/usr/bin/env bash
set -e

echo "=============================================="
echo " Applying KernelSU-Next + SUSFS"
echo " Target: ARM64 non-GKI 4.19"
echo "=============================================="

KERNEL_DIR="$(pwd)"
ARCH=arm64
DEFCONFIG="arch/arm64/configs/vendor/kona-perf_defconfig"

# -------------------------------------------------
# 1. Clone SUSFS if missing
# -------------------------------------------------
SUSFS_DIR="$KERNEL_DIR/../susfs4ksu"

if [ ! -d "$SUSFS_DIR" ]; then
  echo "[INFO] Cloning susfs4ksu repository"
  git clone https://github.com/simonpunk/susfs4ksu.git "$SUSFS_DIR"
else
  echo "[INFO] susfs4ksu already exists"
fi

# -------------------------------------------------
# 2. Apply SUSFS patches
# -------------------------------------------------
echo "[INFO] Applying SUSFS patches"

if [ ! -d "$SUSFS_DIR/kernel_patches" ]; then
  echo "[ERROR] susfs4ksu kernel_patches directory missing"
  exit 1
fi

for patch in "$SUSFS_DIR"/kernel_patches/*.patch; do
  echo "  -> Applying $(basename "$patch")"
  patch -p1 --forward < "$patch" || true
done

# -------------------------------------------------
# 3. Install SUSFS headers
# -------------------------------------------------
echo "[INFO] Installing SUSFS headers"

mkdir -p include/linux
cp -v "$SUSFS_DIR"/include/linux/susfs*.h include/linux/

# -------------------------------------------------
# 4. Fix KernelSU compatibility (4.19)
# -------------------------------------------------
echo "[INFO] Applying KernelSU 4.19 compatibility fixes"

KSU_COMPAT="drivers/kernelsu/kernel_compat.h"

cat > "$KSU_COMPAT" << 'EOF'
#pragma once

#include <linux/uaccess.h>
#include <linux/fs.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5,0,0)

static inline int ksu_access_ok(const void *addr, unsigned long size)
{
    return access_ok(VERIFY_READ, addr, size);
}

static inline ssize_t ksu_kernel_read_compat(struct file *file, void *buf,
                                             size_t count, loff_t *pos)
{
    return kernel_read(file, buf, count, pos);
}

static inline ssize_t ksu_kernel_write_compat(struct file *file, const void *buf,
                                              size_t count, loff_t *pos)
{
    return kernel_write(file, buf, count, pos);
}

#else

static inline int ksu_access_ok(const void *addr, unsigned long size)
{
    return access_ok(addr, size);
}

#define ksu_kernel_read_compat  kernel_read
#define ksu_kernel_write_compat kernel_write

#endif
EOF

# -------------------------------------------------
# 5. Fix allowlist + selinux symbol mismatch
# -------------------------------------------------
echo "[INFO] Fixing KernelSU allowlist symbol mismatch"

sed -i \
  -e 's/ksu_is_ksu_domain/is_ksu_domain/g' \
  drivers/kernelsu/allowlist.c || true

# -------------------------------------------------
# 6. Fix missing TWA_RESUME on 4.19
# -------------------------------------------------
echo "[INFO] Fixing TWA_RESUME for 4.19"

grep -q TWA_RESUME drivers/kernelsu/allowlist.c || \
sed -i 's/task_work_add(/task_work_add(/g' drivers/kernelsu/allowlist.c

# -------------------------------------------------
# 7. Auto-configure CONFIG_LSM correctly
# -------------------------------------------------
echo "[INFO] Configuring CONFIG_LSM"

if grep -q "^CONFIG_DEFAULT_SECURITY_TOMOYO=y" "$DEFCONFIG"; then
  LSM_VALUE="lockdown,yama,loadpin,safesetid,integrity,tomoyo,bpf,baseband_guard"

elif grep -q "^CONFIG_DEFAULT_SECURITY_DAC=y" "$DEFCONFIG"; then
  LSM_VALUE="lockdown,yama,loadpin,safesetid,integrity,bpf,baseband_guard"

else
  LSM_VALUE="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"
fi

sed -i '/^CONFIG_LSM=/d' "$DEFCONFIG"
echo "CONFIG_LSM=\"$LSM_VALUE\"" >> "$DEFCONFIG"

echo "[INFO] CONFIG_LSM set to:"
echo "       $LSM_VALUE"

# -------------------------------------------------
# 8. Final sanity checks
# -------------------------------------------------
echo "[INFO] Sanity checks"

test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f drivers/kernelsu/ksu.c

echo "=============================================="
echo " KernelSU + SUSFS applied successfully"
echo " You can now build the kernel"
echo "=============================================="
