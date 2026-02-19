#!/bin/bash

set -e

KSU_KCONFIG="${1:-KernelSU/kernel/Kconfig}"

if [ ! -f "$KSU_KCONFIG" ]; then
  echo "[ERROR] Kconfig file not found: $KSU_KCONFIG"
  exit 1
fi

if grep -q "config KSU_SUSFS" "$KSU_KCONFIG"; then
  echo "[OK] SUSFS Kconfig entries already exist, skipping."
  exit 0
fi

cat << 'EOF' >> "$KSU_KCONFIG"

config KSU_SUSFS
    bool "Enable SUSFS"
    depends on KSU
    default n

config KSU_SUSFS_HAS_MAGIC_MOUNT
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_PATH
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_MOUNT
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_KSTAT
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_OVERLAYFS
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_TRY_UMOUNT
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SPOOF_UNAME
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_OPEN_REDIRECT
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_ENABLE_LOG
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_SU
    bool
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_MAP
    bool
    depends on KSU_SUSFS
    default y

EOF

echo "[OK] SUSFS Kconfig entries injected
