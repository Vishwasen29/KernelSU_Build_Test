#!/usr/bin/env bash
# =============================================================================
#  kconfig.sh — SUSFS setup for KernelSU kernel builds
#
#  Does TWO things that are BOTH required for SUSFS to compile:
#
#    1. Injects "config KSU_SUSFS ..." stanzas into KernelSU/kernel/Kconfig
#       so the build system recognises the CONFIG_KSU_SUSFS_* symbols.
#
#    2. Appends CONFIG_KSU_SUSFS=y (and siblings) to the defconfig
#       so the build system actually enables them.
#
#  Both steps are necessary. Kconfig tells the build system the symbols
#  exist; the defconfig tells it to set them to =y. Without step 2 the
#  kernel config system sees the symbols but leaves them at their default
#  value (n), so susfs.c is never compiled regardless of what Kconfig says.
#
#  Usage (run from the kernel source root):
#    bash patches/kconfig.sh [DEFCONFIG_PATH]
#
#  DEFCONFIG_PATH defaults to:
#    arch/arm64/configs/vendor/kona-perf_defconfig
# =============================================================================

set -euo pipefail

KERNEL_ROOT="$(pwd)"
KCONFIG="KernelSU/kernel/Kconfig"
DEFCONFIG="${1:-arch/arm64/configs/vendor/kona-perf_defconfig}"

# Resolve to absolute paths so we can cd safely later
ABS_KCONFIG="${KERNEL_ROOT}/${KCONFIG}"
ABS_DEFCONFIG="${KERNEL_ROOT}/${DEFCONFIG}"

echo ""
echo "============================================================"
echo " SUSFS kconfig.sh"
echo "============================================================"
echo "  Kconfig  : ${ABS_KCONFIG}"
echo "  defconfig: ${ABS_DEFCONFIG}"
echo ""

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [ ! -f "${ABS_KCONFIG}" ]; then
    echo "  [ERROR] KernelSU Kconfig not found: ${ABS_KCONFIG}"
    echo "          Run this script from the kernel source root after"
    echo "          the KernelSU setup step has completed."
    exit 1
fi

if [ ! -f "${ABS_DEFCONFIG}" ]; then
    echo "  [ERROR] defconfig not found: ${ABS_DEFCONFIG}"
    echo "          Pass the correct path as the first argument."
    exit 1
fi

# ---------------------------------------------------------------------------
# STEP 1 — Inject SUSFS stanzas into KernelSU/kernel/Kconfig
# ---------------------------------------------------------------------------
echo "  [1/2] Patching KernelSU Kconfig..."

if grep -q "config KSU_SUSFS" "${ABS_KCONFIG}" 2>/dev/null; then
    echo "        [SKIP] SUSFS entries already present in Kconfig."
else
    cat >> "${ABS_KCONFIG}" << 'EOF'

config KSU_SUSFS
	bool "Enable SUSFS for KernelSU"
	depends on KSU
	default n
	help
	  SUSFS (SU SFS) provides additional kernel-level hiding for KernelSU.
	  Enable this to allow KernelSU to hide itself more effectively from
	  detection by user-space applications.

config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool "SUSFS works alongside magic mount"
	depends on KSU_SUSFS
	default n
	help
	  Enable this if your KernelSU version uses magic mount so that SUSFS
	  can co-operate correctly with it.

config KSU_SUSFS_SUS_PATH
	bool "Enable sus path hiding"
	depends on KSU_SUSFS
	default n
	help
	  Hide suspicious paths from user-space visibility.

config KSU_SUSFS_SUS_MOUNT
	bool "Enable sus mount hiding"
	depends on KSU_SUSFS
	default n
	help
	  Hide suspicious mount entries from /proc/mounts and related interfaces.

config KSU_SUSFS_SUS_KSTAT
	bool "Enable sus kstat spoofing"
	depends on KSU_SUSFS
	default n
	help
	  Spoof kstat results for hidden paths so stat() calls appear normal.

config KSU_SUSFS_SUS_OVERLAYFS
	bool "Enable sus overlayfs spoofing"
	depends on KSU_SUSFS
	default n
	help
	  Hide overlayfs layers used by KernelSU magic mount from user-space.

config KSU_SUSFS_TRY_UMOUNT
	bool "Enable sus path unmounting"
	depends on KSU_SUSFS
	default n
	help
	  Attempt to unmount suspicious paths before process inspection.

config KSU_SUSFS_SPOOF_UNAME
	bool "Enable uname spoofing"
	depends on KSU_SUSFS
	default n
	help
	  Spoof the kernel release string returned by uname() to hide build
	  artefacts that could reveal a rooted kernel.

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable open redirect"
	depends on KSU_SUSFS
	default n
	help
	  Redirect open() calls for hidden paths to alternative locations.

config KSU_SUSFS_ENABLE_LOG
	bool "Enable SUSFS logging"
	depends on KSU_SUSFS
	default n
	help
	  Enable kernel log output from SUSFS. Useful for debugging; disable
	  in production builds to avoid leaking information.

config KSU_SUSFS_SUS_SU
	bool "Enable sus_su"
	depends on KSU_SUSFS
	default n
	help
	  Enable the sus_su interface which allows controlled su access while
	  keeping the standard su path hidden from detection.
EOF

    # Verify
    if grep -q "config KSU_SUSFS" "${ABS_KCONFIG}"; then
        echo "        [PASS] Kconfig stanzas added."
    else
        echo "        [ERROR] Kconfig write appeared to succeed but verification failed."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# STEP 2 — Append CONFIG_KSU_SUSFS=y entries to the defconfig
#
# THIS IS THE STEP THAT WAS MISSING.
#
# The Kconfig stanzas above tell the build system that CONFIG_KSU_SUSFS_*
# symbols exist. But "make defconfig" resolves their values from the defconfig
# file — if no entry is present, each symbol falls back to its Kconfig
# default, which is "n". Without this step susfs.c is never compiled even
# though all the Kconfig stanzas are perfectly in place.
# ---------------------------------------------------------------------------
echo "  [2/2] Writing SUSFS entries to defconfig..."

if grep -q "CONFIG_KSU_SUSFS=y" "${ABS_DEFCONFIG}" 2>/dev/null; then
    echo "        [SKIP] CONFIG_KSU_SUSFS=y already present in defconfig."
else
    # No leading spaces — Kconfig parser silently ignores indented lines
    cat >> "${ABS_DEFCONFIG}" << 'EOF'
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

    # Verify
    if grep -q "CONFIG_KSU_SUSFS=y" "${ABS_DEFCONFIG}"; then
        echo "        [PASS] defconfig entries written."
    else
        echo "        [ERROR] defconfig write appeared to succeed but verification failed."
        exit 1
    fi
fi

echo ""
echo "============================================================"
echo " [DONE] Both steps completed successfully."
echo "  Kconfig symbols are declared and defconfig enables them."
echo "  SUSFS will be compiled into the kernel on next build."
echo "============================================================"
echo ""
