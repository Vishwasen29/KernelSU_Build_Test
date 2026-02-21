#!/usr/bin/env bash
set -e

echo "[+] Running SUSFS fix5.sh..."

KERNEL_DIR=$(pwd)

# ------------------------------------------------
# 1️⃣ Ensure KernelSU-Next exists
# ------------------------------------------------
if [ ! -d "KernelSU-Next" ]; then
    echo "[-] ERROR: KernelSU-Next directory not found!"
    exit 1
fi

# ------------------------------------------------
# 2️⃣ Verify SUSFS Kconfig exists inside KSU-Next
# ------------------------------------------------
if ! grep -R "config KSU_SUSFS" KernelSU-Next/kernel >/dev/null 2>&1; then
    echo "[-] ERROR: SUSFS Kconfig not found in KernelSU-Next!"
    echo "Your sus4.patch did not apply correctly."
    exit 1
fi

echo "[+] SUSFS Kconfig detected"

# ------------------------------------------------
# 3️⃣ Fix fs/Makefile if missing
# ------------------------------------------------
if [ -f "fs/Makefile" ]; then
    if ! grep -q "susfs" fs/Makefile; then
        echo "[+] Injecting susfs into fs/Makefile"
        echo 'obj-$(CONFIG_KSU_SUSFS) += susfs/' >> fs/Makefile
    fi
fi

# ------------------------------------------------
# 4️⃣ Fix namespace.c include (common hunk fail)
# ------------------------------------------------
if [ -f "fs/namespace.c" ]; then
    if ! grep -q "susfs" fs/namespace.c; then
        echo "[+] Injecting SUSFS include into namespace.c"
        sed -i '/#include <linux/mount.h>/a #include <linux/susfs.h>' fs/namespace.c || true
    fi
fi

# ------------------------------------------------
# 5️⃣ Fix mount.h include if needed
# ------------------------------------------------
if [ -f "include/linux/mount.h" ]; then
    if ! grep -q "susfs" include/linux/mount.h; then
        echo "[+] Injecting SUSFS include into mount.h"
        echo '#include <linux/susfs.h>' >> include/linux/mount.h
    fi
fi

# ------------------------------------------------
# 6️⃣ Ensure KernelSU-Next Kconfig is sourced
# ------------------------------------------------
if [ -f "init/Kconfig" ]; then
    if ! grep -q 'KernelSU-Next/kernel/Kconfig' init/Kconfig; then
        echo "[+] Injecting KernelSU-Next Kconfig source"
        echo 'source "KernelSU-Next/kernel/Kconfig"' >> init/Kconfig
    fi
fi

# ------------------------------------------------
# 7️⃣ Final verification
# ------------------------------------------------
echo "[+] Verifying KSU_SUSFS exists in tree..."

if ! grep -R "config KSU_SUSFS" . >/dev/null 2>&1; then
    echo "[-] ERROR: SUSFS not properly registered!"
    exit 1
fi

echo "[+] fix5.sh completed successfully."
