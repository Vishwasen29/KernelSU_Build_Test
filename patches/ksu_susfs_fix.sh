#!/usr/bin/env bash
set -e

echo "[+] Running KernelSU-Next SUSFS fix..."

KERNEL_ROOT=$(pwd)

# -----------------------------
# 1️⃣ Verify KernelSU-Next exists
# -----------------------------
if [ ! -d "KernelSU-Next" ]; then
    echo "[-] ERROR: KernelSU-Next directory not found!"
    exit 1
fi

if [ ! -f "KernelSU-Next/kernel/Kconfig" ]; then
    echo "[-] ERROR: KernelSU-Next/kernel/Kconfig not found!"
    exit 1
fi

echo "[+] KernelSU-Next verified"

# -----------------------------
# 2️⃣ Remove wrong KernelSU references
# -----------------------------
find . -type f -name "Kconfig" -exec sed -i 's|KernelSU/kernel/Kconfig|KernelSU-Next/kernel/Kconfig|g' {} \;

# -----------------------------
# 3️⃣ Ensure KernelSU-Next Kconfig is sourced
# -----------------------------
MAIN_KCONFIG="init/Kconfig"

if ! grep -q 'KernelSU-Next/kernel/Kconfig' $MAIN_KCONFIG; then
    echo '[+] Injecting KernelSU-Next Kconfig source'
    echo 'source "KernelSU-Next/kernel/Kconfig"' >> $MAIN_KCONFIG
else
    echo '[+] KernelSU-Next Kconfig already sourced'
fi

# -----------------------------
# 4️⃣ Ensure Makefile inclusion
# -----------------------------
if ! grep -q "KernelSU-Next/kernel/" Makefile; then
    echo "[+] Adding KernelSU-Next to top Makefile"
    echo 'obj-y += KernelSU-Next/kernel/' >> Makefile
fi

# -----------------------------
# 5️⃣ Validate SUSFS config exists
# -----------------------------
if ! grep -R "config KSU_SUSFS" KernelSU-Next/kernel > /dev/null; then
    echo "[-] ERROR: SUSFS Kconfig not found inside KernelSU-Next!"
    exit 1
fi

echo "[+] SUSFS Kconfig detected"

echo "[+] KernelSU-Next SUSFS fix complete."
