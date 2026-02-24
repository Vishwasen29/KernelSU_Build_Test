#!/usr/bin/env bash
# =============================================================================
# inject_susfs_kconfig.sh
# Injects SUSFS Kconfig symbols into the kernel source tree so that
# CONFIG_KSU_SUSFS=y (and friends) are not silently dropped by olddefconfig.
#
# Usage:
#   ./inject_susfs_kconfig.sh [KERNEL_DIR]
#
# KERNEL_DIR defaults to the current working directory if not supplied.
# =============================================================================

set -euo pipefail

# ── Resolve kernel root ───────────────────────────────────────────────────────
KERNEL_DIR="${1:-$(pwd)}"

if [ ! -f "${KERNEL_DIR}/fs/Kconfig" ]; then
    echo "❌ Cannot find fs/Kconfig under '${KERNEL_DIR}'"
    echo "   Pass the kernel source root as the first argument."
    exit 1
fi

FS_KCONFIG="${KERNEL_DIR}/fs/Kconfig"

# ── Guard: skip if symbols already present ────────────────────────────────────
if grep -q "config KSU_SUSFS" "${FS_KCONFIG}"; then
    echo "ℹ️  SUSFS Kconfig symbols already present in ${FS_KCONFIG} — nothing to do."
    exit 0
fi

# ── Inject ────────────────────────────────────────────────────────────────────
echo "➕ Injecting SUSFS Kconfig symbols into ${FS_KCONFIG} ..."

cat >> "${FS_KCONFIG}" << 'KCONFIG_EOF'

# -----------------------------------------------------------------------------
# KernelSU addon — SUSFS
# Injected by inject_susfs_kconfig.sh
# -----------------------------------------------------------------------------

config KSU_SUSFS
	bool "KernelSU addon - SUSFS"
	depends on KSU
	default n
	help
	  Enable SUSFS support for KernelSU. SUSFS is a kernel-level
	  filesystem overlay that hides root from detection.

config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool "SUSFS: Enable Magic Mount"
	depends on KSU_SUSFS
	default n
	help
	  Enable Magic Mount support within SUSFS.

config KSU_SUSFS_SUS_PATH
	bool "SUSFS: Enable Sus Path"
	depends on KSU_SUSFS
	default n
	help
	  Allow hiding of specified paths from the VFS layer.

config KSU_SUSFS_SUS_MOUNT
	bool "SUSFS: Enable Sus Mount"
	depends on KSU_SUSFS
	default n
	help
	  Allow hiding of specified mount entries.

config KSU_SUSFS_SUS_KSTAT
	bool "SUSFS: Enable Sus Kstat"
	depends on KSU_SUSFS
	default n
	help
	  Spoof kstat results for hidden paths.

config KSU_SUSFS_SUS_OVERLAYFS
	bool "SUSFS: Enable Sus OverlayFS"
	depends on KSU_SUSFS
	default n
	help
	  Handle susfs behaviour on overlayfs mounts.

config KSU_SUSFS_TRY_UMOUNT
	bool "SUSFS: Enable Try Umount"
	depends on KSU_SUSFS
	default n
	help
	  Attempt to unmount sus mounts before reporting them.

config KSU_SUSFS_SPOOF_UNAME
	bool "SUSFS: Enable Spoof Uname"
	depends on KSU_SUSFS
	default n
	help
	  Spoof the uname string to hide kernel modifications.

config KSU_SUSFS_OPEN_REDIRECT
	bool "SUSFS: Enable Open Redirect"
	depends on KSU_SUSFS
	default n
	help
	  Redirect file open calls for hidden paths to alternate targets.

config KSU_SUSFS_ENABLE_LOG
	bool "SUSFS: Enable Log"
	depends on KSU_SUSFS
	default n
	help
	  Enable kernel-log output from SUSFS (useful for debugging).

config KSU_SUSFS_SUS_SU
	bool "SUSFS: Enable Sus SU"
	depends on KSU_SUSFS
	default n
	help
	  Enable the Sus SU implementation within SUSFS.
KCONFIG_EOF

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "── Verification ─────────────────────────────────────────────────────────"

EXPECTED_SYMBOLS=(
    "config KSU_SUSFS"
    "config KSU_SUSFS_HAS_MAGIC_MOUNT"
    "config KSU_SUSFS_SUS_PATH"
    "config KSU_SUSFS_SUS_MOUNT"
    "config KSU_SUSFS_SUS_KSTAT"
    "config KSU_SUSFS_SUS_OVERLAYFS"
    "config KSU_SUSFS_TRY_UMOUNT"
    "config KSU_SUSFS_SPOOF_UNAME"
    "config KSU_SUSFS_OPEN_REDIRECT"
    "config KSU_SUSFS_ENABLE_LOG"
    "config KSU_SUSFS_SUS_SU"
)

ALL_OK=true
for sym in "${EXPECTED_SYMBOLS[@]}"; do
    if grep -q "${sym}" "${FS_KCONFIG}"; then
        echo "  ✅ ${sym}"
    else
        echo "  ❌ ${sym} — MISSING"
        ALL_OK=false
    fi
done

echo ""
if [ "${ALL_OK}" = true ]; then
    echo "✅ All SUSFS Kconfig symbols successfully injected into ${FS_KCONFIG}"
else
    echo "❌ One or more symbols failed to inject — review the output above."
    exit 1
fi
