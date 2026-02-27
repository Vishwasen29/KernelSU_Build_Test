#!/bin/bash
# patch_kconfig.sh
#
# Appends missing CONFIG_KSU_SUSFS_* entries into KernelSU/KernelSU-Next Kconfig.
# Automatically detects whether the folder is named KernelSU or KernelSU-Next.
# Safe to run multiple times — each entry is only added if not already present.
#
# Usage:
#   bash patch_kconfig.sh [path/to/android-kernel]
#   (defaults to current directory if no argument given)

set -e

KERNEL_ROOT="${1:-.}"

# Auto-detect KernelSU directory name (supports both forks)
if [ -f "${KERNEL_ROOT}/KernelSU-Next/kernel/Kconfig" ]; then
    KCONFIG="${KERNEL_ROOT}/KernelSU-Next/kernel/Kconfig"
    KSU_DIR="KernelSU-Next"
elif [ -f "${KERNEL_ROOT}/KernelSU/kernel/Kconfig" ]; then
    KCONFIG="${KERNEL_ROOT}/KernelSU/kernel/Kconfig"
    KSU_DIR="KernelSU"
else
    echo "ERROR: Could not find Kconfig in KernelSU-Next/ or KernelSU/"
    echo "       Make sure KernelSU setup has run first."
    exit 1
fi

echo "=== Patching missing SUSFS entries into ${KSU_DIR} Kconfig ==="
echo "    File: $KCONFIG"
echo ""

add_entry() {
    local symbol="$1"
    local body="$2"

    if grep -q "config ${symbol}" "$KCONFIG"; then
        echo "  [skip]  config ${symbol}  (already present)"
    else
        echo "  [add]   config ${symbol}"
        python3 -c "
import sys
body = sys.argv[1]
with open(sys.argv[2], 'a') as f:
    f.write('\n')
    f.write(body)
    f.write('\n')
" "$body" "$KCONFIG"
    fi
}

add_entry "KSU_SUSFS_SUS_SU" \
"config KSU_SUSFS_SUS_SU
	bool \"Enable sus_su support\"
	depends on KSU_SUSFS
	default y
	help
	  Allow KernelSU to use sus_su as an alternative way to grant a root
	  shell. Disable this if you are using kprobe-based hooks instead."

add_entry "KSU_SUSFS_HAS_MAGIC_MOUNT" \
"config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool \"Enable magic mount support for SUSFS\"
	depends on KSU_SUSFS
	default y
	help
	  Enable magic mount support. Required for module overlay mounts
	  to be hidden correctly from userspace processes."

add_entry "KSU_SUSFS_SUS_OVERLAYFS" \
"config KSU_SUSFS_SUS_OVERLAYFS
	bool \"Enable sus overlayfs support\"
	depends on KSU_SUSFS
	default y
	help
	  Hide KernelSU overlayfs mounts from userspace processes."

echo ""
echo "=== All config KSU_SUSFS entries now in Kconfig ==="
grep "config KSU_SUSFS" "$KCONFIG"
echo "===================================================="
echo ""
echo "Done."
