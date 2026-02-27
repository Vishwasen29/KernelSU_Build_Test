#!/bin/bash
# patch_kconfig.sh
#
# Ensures ALL required CONFIG_KSU_SUSFS_* entries exist in the KernelSU
# (or KernelSU-Next) Kconfig. Safe to run multiple times — each entry is
# only appended if not already present.
#
# Covers both forks:
#   - rsuntk/KernelSU  (susfs-rksu-master)  — ships 7 core symbols, missing 3 newer ones
#   - sidex15/KernelSU-Next (legacy-susfs)  — ships only KSU_SUSFS, missing all 10 others
#
# Usage:
#   bash patch_kconfig.sh [path/to/android-kernel]

set -e

KERNEL_ROOT="${1:-.}"

# Auto-detect KernelSU directory name
if [ -f "${KERNEL_ROOT}/KernelSU-Next/kernel/Kconfig" ]; then
    KCONFIG="${KERNEL_ROOT}/KernelSU-Next/kernel/Kconfig"
    KSU_DIR="KernelSU-Next"
elif [ -f "${KERNEL_ROOT}/KernelSU/kernel/Kconfig" ]; then
    KCONFIG="${KERNEL_ROOT}/KernelSU/kernel/Kconfig"
    KSU_DIR="KernelSU"
else
    echo "ERROR: Could not find Kconfig in KernelSU-Next/ or KernelSU/"
    echo "       Make sure the KernelSU setup step has run first."
    exit 1
fi

echo "=== Patching missing SUSFS entries into ${KSU_DIR} Kconfig ==="
echo "    File: $KCONFIG"
echo ""

# Append a Kconfig entry only if not already present.
# Uses Python to write literal tab characters — YAML strips leading whitespace
# from heredocs, which would produce spaces and break Kconfig's tab requirement.
add_entry() {
    local symbol="$1"
    local body="$2"

    if grep -q "^config ${symbol}$" "$KCONFIG"; then
        echo "  [skip]  config ${symbol}"
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

# ── Core SUSFS symbols (present in rsuntk, MISSING in KernelSU-Next) ─────────

add_entry "KSU_SUSFS_SUS_PATH" \
"config KSU_SUSFS_SUS_PATH
	bool \"Enable suspicious path hiding\"
	depends on KSU_SUSFS
	default y
	help
	  Allow hiding suspicious paths from userspace."

add_entry "KSU_SUSFS_SUS_MOUNT" \
"config KSU_SUSFS_SUS_MOUNT
	bool \"Enable suspicious mount hiding\"
	depends on KSU_SUSFS
	default y
	help
	  Allow hiding suspicious mounts from userspace."

add_entry "KSU_SUSFS_SUS_KSTAT" \
"config KSU_SUSFS_SUS_KSTAT
	bool \"Enable spoofing kstat of sus files\"
	depends on KSU_SUSFS
	default y
	help
	  Allow spoofing kstat of suspicious files."

add_entry "KSU_SUSFS_TRY_UMOUNT" \
"config KSU_SUSFS_TRY_UMOUNT
	bool \"Enable try umount\"
	depends on KSU_SUSFS
	default y
	help
	  Allow umounting suspicious paths before a process becomes non-root."

add_entry "KSU_SUSFS_SPOOF_UNAME" \
"config KSU_SUSFS_SPOOF_UNAME
	bool \"Enable spoofing uname\"
	depends on KSU_SUSFS
	default y
	help
	  Allow spoofing the uname to hide KernelSU."

add_entry "KSU_SUSFS_OPEN_REDIRECT" \
"config KSU_SUSFS_OPEN_REDIRECT
	bool \"Enable open redirect\"
	depends on KSU_SUSFS
	default y
	help
	  Allow redirecting file opens for suspicious paths."

add_entry "KSU_SUSFS_ENABLE_LOG" \
"config KSU_SUSFS_ENABLE_LOG
	bool \"Enable logging\"
	depends on KSU_SUSFS
	default y
	help
	  Enable SUSFS kernel logging for debugging."

# ── Newer symbols (MISSING in both rsuntk and KernelSU-Next) ─────────────────

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
