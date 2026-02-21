#!/usr/bin/env bash
# =============================================================================
#  patch_ksu_kconfig.sh
#  Injects SUSFS Kconfig entries into KernelSU/kernel/Kconfig when absent.
#
#  Usage:
#    bash patch_ksu_kconfig.sh [path/to/KernelSU/kernel/Kconfig]
#
#  If no argument is given the script looks for the Kconfig relative to
#  the current working directory (expected: kernel source root).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve Kconfig path
# ---------------------------------------------------------------------------
KCONFIG="${1:-KernelSU/kernel/Kconfig}"

if [ ! -f "$KCONFIG" ]; then
    echo "  [ERROR] Kconfig not found: $KCONFIG"
    echo "          Run this script from the kernel source root, or pass the"
    echo "          Kconfig path as the first argument."
    exit 1
fi

# ---------------------------------------------------------------------------
# Idempotency check — skip if SUSFS entries are already present
# ---------------------------------------------------------------------------
if grep -q "config KSU_SUSFS" "$KCONFIG" 2>/dev/null; then
    echo "  [SKIP] KernelSU Kconfig already has SUSFS entries — nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Inject SUSFS Kconfig stanzas
# ---------------------------------------------------------------------------
echo "  [+] Appending SUSFS Kconfig entries to: $KCONFIG"

cat >> "$KCONFIG" << 'EOF'

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

# ---------------------------------------------------------------------------
# Verify injection succeeded
# ---------------------------------------------------------------------------
if grep -q "config KSU_SUSFS" "$KCONFIG"; then
    echo "  [DONE] SUSFS Kconfig entries added successfully."
else
    echo "  [ERROR] Injection appeared to succeed but verification failed."
    exit 1
fi
