#!/usr/bin/env bash
# =============================================================================
# add_susfs_kconfig.sh
#
# Appends SUSFS config symbols to KernelSU-Next's Kconfig so that
# `make olddefconfig` keeps every CONFIG_KSU_SUSFS_* option instead of
# silently stripping them (they have no Kconfig entry without this step).
#
# Usage: bash add_susfs_kconfig.sh <kernel-root>
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-.}"
KCONFIG="$KERNEL_ROOT/KernelSU-Next/kernel/Kconfig"

if [[ ! -f "$KCONFIG" ]]; then
  echo "[FATAL] Kconfig not found: $KCONFIG"
  echo "        Did KernelSU-Next setup run before this script?"
  exit 1
fi

if grep -q "^config KSU_SUSFS$" "$KCONFIG"; then
  echo "[SKIP] SUSFS Kconfig entries already present — nothing to do"
  exit 0
fi

echo "[INFO] Appending SUSFS Kconfig symbols to $KCONFIG"

cat >> "$KCONFIG" << 'KCONFIG_EOF'

# ── SUSFS (SUS FileSystem) ───────────────────────────────────────────────────
# These entries are required for `make olddefconfig` to accept every
# CONFIG_KSU_SUSFS_* option set in the defconfig / scripts/config calls.
# Without them, olddefconfig silently drops all SUSFS options.

config KSU_SUSFS
	bool "Enable SUS FileSystem (SUSFS)"
	depends on KSU
	default y
	help
	  Integrates SUSFS into KernelSU-Next for advanced process hiding
	  and mount namespace spoofing.

config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool "SUSFS: magic-mount support"
	depends on KSU_SUSFS
	default y
	help
	  Required for magic-mount based path hiding.

config KSU_SUSFS_SUS_PATH
	bool "SUSFS: hide sus paths from userspace"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "SUSFS: hide sus mounts from /proc/mounts"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "SUSFS: spoof kstat results"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_OVERLAYFS
	bool "SUSFS: hide overlayfs artefacts"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_TRY_UMOUNT
	bool "SUSFS: try_umount helper"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_UNAME
	bool "SUSFS: spoof uname output"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "SUSFS: open-redirect support"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_ENABLE_LOG
	bool "SUSFS: enable kernel-side logging"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_SU
	bool "SUSFS: sus_su support"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MAP
	bool "SUSFS: hide entries in /proc/pid/maps"
	depends on KSU_SUSFS
	default y
KCONFIG_EOF

echo "[OK] SUSFS Kconfig entries added — grep check:"
grep "^config KSU_SUSFS" "$KCONFIG"
