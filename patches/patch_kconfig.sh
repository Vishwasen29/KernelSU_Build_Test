#!/bin/bash
# patch_kconfig.sh
#
# Ensures ALL required CONFIG_KSU_SUSFS_* entries exist in the KernelSU
# (or KernelSU-Next) Kconfig. Safe to run multiple times — each entry is
# only appended if not already present.
#
# Covers both forks:
#   - rsuntk/KernelSU  (susfs-rksu-master)  — ships 7 core symbols, missing 3 newer ones
#   - sidex15/KernelSU-Next (legacy-susfs)  — ships only bare KSU_SUSFS, missing all 10 others
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
# Uses Python to write literal tab characters — shell heredocs/printf can
# produce spaces which break Kconfig's strict tab-indentation requirement.
add_entry() {
    local symbol="$1"
    local body="$2"

    if grep -q "^config ${symbol}$" "$KCONFIG"; then
        echo "  [skip]  config ${symbol}"
    else
        echo "  [add]   config ${symbol}"
        # BUG FIX: body is passed as sys.argv[1], KCONFIG as sys.argv[2]
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

# ── BUG FIX: Parent symbol must be added first, with a proper bool type.
# KernelSU-Next/legacy-susfs ships a bare "config KSU_SUSFS" stub without
# a type declaration, so olddefconfig drops it silently. We replace/ensure
# a fully typed entry exists. We check for the typed version specifically.
if ! grep -q "^	bool" "$KCONFIG" 2>/dev/null || ! grep -q "^config KSU_SUSFS$" "$KCONFIG" 2>/dev/null; then
    # If the bare stub exists, sed it to a full entry; otherwise append.
    if grep -q "^config KSU_SUSFS$" "$KCONFIG"; then
        echo "  [fix]   config KSU_SUSFS (upgrading bare stub to typed entry)"
        # Insert the bool + depends + default lines after the bare config line
        sed -i '/^config KSU_SUSFS$/{
n
/^\tbool/!i\\tbool "Enable SUS filesystem support"\\n\\tdepends on KSU\\n\\tdefault y
}' "$KCONFIG"
    else
        echo "  [add]   config KSU_SUSFS"
        python3 -c "
import sys
with open(sys.argv[1], 'a') as f:
    f.write('\nconfig KSU_SUSFS\n\tbool \"Enable SUS filesystem support\"\n\tdepends on KSU\n\tdefault y\n\thelp\n\t  Enable SUSFS support for hiding KernelSU mounts and paths.\n')
" "$KCONFIG"
    fi
else
    echo "  [skip]  config KSU_SUSFS"
fi

# ── Core SUSFS symbols ────────────────────────────────────────────────────────
# BUG FIX: Every add_entry call must include a complete body with bool type
# and depends on. The original script left KSU_SUSFS_SUS_MOUNT and all
# subsequent entries with an empty body (trailing backslash, no continuation).

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
	bool \"Enable suspicious kstat spoofing\"
	depends on KSU_SUSFS
	default y
	help
	  Allow spoofing kstat results for suspicious files."

add_entry "KSU_SUSFS_TRY_UMOUNT" \
"config KSU_SUSFS_TRY_UMOUNT
	bool \"Enable try-umount support\"
	depends on KSU_SUSFS
	default y
	help
	  Allow userspace to request unmounting of suspicious mounts."

add_entry "KSU_SUSFS_SPOOF_UNAME" \
"config KSU_SUSFS_SPOOF_UNAME
	bool \"Enable uname spoofing\"
	depends on KSU_SUSFS
	default y
	help
	  Spoof the kernel uname string to hide KernelSU."

add_entry "KSU_SUSFS_OPEN_REDIRECT" \
"config KSU_SUSFS_OPEN_REDIRECT
	bool \"Enable open redirect\"
	depends on KSU_SUSFS
	default y
	help
	  Redirect file open calls for suspicious paths."

add_entry "KSU_SUSFS_ENABLE_LOG" \
"config KSU_SUSFS_ENABLE_LOG
	bool \"Enable SUSFS kernel logging\"
	depends on KSU_SUSFS
	default y
	help
	  Enable printk logging from the SUSFS subsystem."

add_entry "KSU_SUSFS_SUS_SU" \
"config KSU_SUSFS_SUS_SU
	bool \"Enable sus_su support\"
	depends on KSU_SUSFS
	default y
	help
	  Enable the sus_su interface for compatibility."

# ── Newer symbols (missing from older forks) ──────────────────────────────────

add_entry "KSU_SUSFS_HAS_MAGIC_MOUNT" \
"config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool \"Kernel has magic mount support\"
	depends on KSU_SUSFS
	default y
	help
	  Indicate that the kernel supports magic mount for SUSFS."

add_entry "KSU_SUSFS_SUS_OVERLAYFS" \
"config KSU_SUSFS_SUS_OVERLAYFS
	bool \"Enable suspicious overlayfs hiding\"
	depends on KSU_SUSFS
	default y
	help
	  Allow hiding overlayfs mounts used by KernelSU from userspace."

echo ""
echo "=== All config KSU_SUSFS entries now in Kconfig ==="
grep "^config KSU_SUSFS" "$KCONFIG"
echo "===================================================="
echo ""
echo "Done."
