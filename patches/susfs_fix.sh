#!/bin/bash
set -e

# ----------------------------------------------------------------------
# SUSFS integration script for OnePlus 9R (lemonades) LineageOS 23.2
# Kernel version: 4.19
# Usage: ./apply_susfs.sh <path-to-kernel-source> <path-to-susfs-patch>
# Example: ./apply_susfs.sh ~/kernel/oneplus_sm8250 susfs_patch_to_4.19.patch
# ----------------------------------------------------------------------

KERNEL_SRC="$1"
PATCH_FILE="$2"

if [ -z "$KERNEL_SRC" ] || [ -z "$PATCH_FILE" ]; then
    echo "Usage: $0 <kernel-source-dir> <patch-file>"
    exit 1
fi

if [ ! -d "$KERNEL_SRC" ]; then
    echo "Error: Kernel source directory not found: $KERNEL_SRC"
    exit 1
fi

if [ ! -f "$PATCH_FILE" ]; then
    echo "Error: Patch file not found: $PATCH_FILE"
    exit 1
fi

cd "$KERNEL_SRC"

echo "------------------------------------------------------------"
echo "  Applying SUSFS patch to kernel source"
echo "------------------------------------------------------------"

# Apply the main SUSFS patch
patch -p1 < "$PATCH_FILE"
if [ $? -ne 0 ]; then
    echo "❌ Patch failed. Check for .rej files above."
    exit 1
fi
echo "✅ Patch applied successfully."

# ----------------------------------------------------------------------
# SUSFS requires its own Kconfig symbol. The patch does not add it,
# so we create it manually.
# ----------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "  Adding SUSFS Kconfig entries"
echo "------------------------------------------------------------"

# Create the SUSFS Kconfig file
mkdir -p fs/susfs
cat > fs/susfs/Kconfig << 'EOF'
config KSU_SUSFS
	bool "SUSFS (KernelSU Safe Security Feature)"
	depends on KSU
	default y
	help
	  Enable SUSFS to hide sensitive paths, mounts, and other system information.
	  If unsure, say Y.

if KSU_SUSFS

config KSU_SUSFS_SUS_PATH
	bool "Hide sensitive paths"
	default y
	help
	  Hide specified paths from non-root processes.

config KSU_SUSFS_SUS_MOUNT
	bool "Hide sensitive mounts"
	default y
	help
	  Hide specified mounts from non-root processes.

config KSU_SUSFS_SUS_KSTAT
	bool "Spoof stat() results"
	default y
	help
	  Spoof inode numbers, device IDs, and other stat fields.

config KSU_SUSFS_SUS_OVERLAYFS
	bool "OverlayFS enhancements"
	default y
	help
	  Additional OverlayFS hiding features.

config KSU_SUSFS_TRY_UMOUNT
	bool "Try unmount feature"
	default y
	help
	  Attempt to unmount specific mounts.

config KSU_SUSFS_SPOOF_UNAME
	bool "Spoof uname"
	default y
	help
	  Spoof kernel release and version strings.

config KSU_SUSFS_OPEN_REDIRECT
	bool "Open file redirection"
	default y
	help
	  Redirect opens of certain files to another path.

config KSU_SUSFS_ENABLE_LOG
	bool "Enable SUSFS logging"
	default y
	help
	  Allow SUSFS to print debug messages (can be turned off at runtime).

config KSU_SUSFS_SUS_SU
	bool "SUS SU feature"
	default y
	help
	  Additional SU hiding mechanisms.

endif # KSU_SUSFS
EOF

# Source the new Kconfig in fs/Kconfig
if ! grep -q "source \"fs/susfs/Kconfig\"" fs/Kconfig; then
    echo "source \"fs/susfs/Kconfig\"" >> fs/Kconfig
    echo "✅ Added SUSFS Kconfig to fs/Kconfig"
else
    echo "ℹ️ SUSFS Kconfig already sourced"
fi

# ----------------------------------------------------------------------
# Enable SUSFS options in the device defconfig
# ----------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "  Enabling SUSFS in defconfig"
echo "------------------------------------------------------------"

DEFCONFIG="arch/arm64/configs/vendor/kona-perf_defconfig"
if [ ! -f "$DEFCONFIG" ]; then
    echo "⚠️  Defconfig not found at $DEFCONFIG, skipping automatic enable."
    echo "   Please manually add the following lines to your defconfig:"
else
    # Backup original defconfig
    cp "$DEFCONFIG" "$DEFCONFIG.bak"

    # Add SUSFS configs (if not already present)
    grep -q "CONFIG_KSU_SUSFS=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_SUS_PATH=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_SUS_MOUNT=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_SUS_KSTAT=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_ENABLE_LOG=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$DEFCONFIG"
    grep -q "CONFIG_KSU_SUSFS_SUS_SU=y" "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_SUS_SU=y" >> "$DEFCONFIG"

    echo "✅ SUSFS options added to $DEFCONFIG"
fi

# ----------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "  SUSFS integration completed successfully!"
echo "------------------------------------------------------------"
echo ""
echo "Next steps:"
echo "1. Build your kernel (e.g., make ARCH=arm64 ...)"
echo "2. The final .config must contain CONFIG_KSU_SUSFS=y and its sub-options."
echo "3. If you encounter build errors, check for any rejected patches."
echo ""
