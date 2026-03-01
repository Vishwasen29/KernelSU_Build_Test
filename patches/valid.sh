#!/bin/bash
# =============================================================================
# check_susfs.sh — Validates and repairs SUSFS wiring for kernel 4.19
#
# What this script does:
#   1. REMOVES any bogus 'source "fs/susfs/Kconfig"' lines from fs/Kconfig
#      (fs/susfs/Kconfig does not exist — this line breaks the build)
#   2. Ensures fs/Makefile has: obj-$(CONFIG_KSU_SUSFS) += susfs.o
#   3. Ensures drivers/kernelsu/Kconfig contains the full KSU + SUSFS config
#
# Usage: bash check_susfs.sh [kernel_root]
#   kernel_root: path to kernel source root (default: current directory)
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pass()  { echo -e "${GREEN}  [PASS]${NC} $*"; }
fail()  { echo -e "${RED}  [FAIL]${NC} $*"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "${CYAN}  [INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $*"; }
title() { echo -e "\n${CYAN}=== $* ===${NC}"; }
fixed() { echo -e "${YELLOW}  [FIXED]${NC} $*"; }

ERRORS=0

# ── Resolve kernel root ───────────────────────────────────────────────────────
KERNEL_ROOT="${1:-$(pwd)}"
KERNEL_ROOT="$(realpath "$KERNEL_ROOT")"

FS_KCONFIG="$KERNEL_ROOT/fs/Kconfig"
FS_MAKEFILE="$KERNEL_ROOT/fs/Makefile"
SUSFS_C="$KERNEL_ROOT/fs/susfs.c"
SUSFS_H="$KERNEL_ROOT/include/linux/susfs.h"
SUSFS_DEF_H="$KERNEL_ROOT/include/linux/susfs_def.h"
KSU_KCONFIG="$KERNEL_ROOT/drivers/kernelsu/Kconfig"

MAKEFILE_ENTRY='obj-$(CONFIG_KSU_SUSFS) += susfs.o'
BOGUS_KCONFIG_ENTRY='source "fs/susfs/Kconfig"'

# =============================================================================
# The full correct content for drivers/kernelsu/Kconfig
# =============================================================================
read -r -d '' KSU_KCONFIG_CONTENT << 'EOF'
menu "KernelSU"

config KSU
	tristate "KernelSU function support"
	default y
	help
	  Enable kernel-level root privileges on Android System.
	  Requires CONFIG_KPROBES for kernel hooking support.
	  To compile as a module, choose M here: the
	  module will be called kernelsu.

config KSU_DEBUG
	bool "KernelSU debug mode"
	depends on KSU
	default n
	help
	  Enable KernelSU debug mode.

# For easier extern ifdef handling
config KSU_MANUAL_HOOK
	bool "KernelSU manual hook mode."
	depends on KSU && KSU != m
	default y if !KPROBES
	default n
	help
	  Enable manual hook support.

config KSU_KPROBES_HOOK
	bool "KernelSU tracepoint+kretprobe hook"
	depends on KSU && !KSU_MANUAL_HOOK
	depends on KRETPROBES && KPROBES && HAVE_SYSCALL_TRACEPOINTS
	default y if KPROBES && KRETPROBES && HAVE_SYSCALL_TRACEPOINTS
	default n
	help
	  Enable KPROBES, KRETPROBES and TRACEPOINT hook for KernelSU core.
	  This should not be used on kernel below 5.10.

menu "KernelSU - SUSFS"
config KSU_SUSFS
	bool "KernelSU addon - SUSFS"
	depends on KSU
	depends on THREAD_INFO_IN_TASK
	default y
	help
		Patch and Enable SUSFS to kernel with KernelSU.

config KSU_SUSFS_SUS_PATH
	bool "Enable to hide suspicious path (NOT recommended)"
	depends on KSU_SUSFS
	default y
	help
		- Allow hiding the user-defined path and all its sub-paths from various system calls.
		- Includes temp fix for the leaks of app path in /sdcard/Android/data directory.
		- Effective only on zygote spawned user app process.
		- Use with cautious as it may cause performance loss and will be vulnerable to side channel attacks,
		  just disable this feature if it doesn't work for you or you don't need it at all.

config KSU_SUSFS_SUS_MOUNT
	bool "Enable to hide suspicious mounts"
	depends on KSU_SUSFS
	default y
	help
		- Allow hiding the user-defined mount paths from /proc/self/[mounts|mountinfo|mountstat].
		- Effective on all processes for hiding mount entries.
		- mnt_id and mnt_group_id of the sus mount will be assigned to a much bigger number to solve the issue of id not being contiguous.

config KSU_SUSFS_SUS_KSTAT
	bool "Enable to spoof suspicious kstat"
	depends on KSU_SUSFS
	default y
	help
		- Allow spoofing the kstat of user-defined file/directory.
		- Effective only on zygote spawned user app process.

config KSU_SUSFS_TRY_UMOUNT
	bool "Enable to use ksu's try_umount"
	depends on KSU_SUSFS
	default y
	help
		- Allow using try_umount to umount other user-defined mount paths prior to ksu's default umount paths.
		- Effective only on zygote spawned umounted user app process.

config KSU_SUSFS_SPOOF_UNAME
	bool "Enable to spoof uname"
	depends on KSU_SUSFS
	default y
	help
		- Allow spoofing the string returned by uname syscall to user-defined string.
		- Effective on all processes.

config KSU_SUSFS_ENABLE_LOG
	bool "Enable logging susfs log to kernel"
	depends on KSU_SUSFS
	default y
	help
		- Allow logging susfs log to kernel, uncheck it to completely disable all susfs log.

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "Enable to automatically hide ksu and susfs symbols from /proc/kallsyms"
	depends on KSU_SUSFS
	default y
	help
		- Automatically hide ksu and susfs symbols from '/proc/kallsyms'.
		- Effective on all processes.

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "Enable to spoof /proc/bootconfig (gki) or /proc/cmdline (non-gki)"
	depends on KSU_SUSFS
	default y
	help
		- Spoof the output of /proc/bootconfig (gki) or /proc/cmdline (non-gki) with a user-defined file.
		- Effective on all processes.

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable to redirect a path to be opened with another path (experimental)"
	depends on KSU_SUSFS
	default y
	help
		- Allow redirecting a target path to be opened with another user-defined path.
		- Effective only on processes with uid < 2000.
		- Please be reminded that process with open access to the target and redirected path can be detected.

config KSU_SUSFS_SUS_MAP
	bool "Enable to hide some mmapped real file from different proc maps interfaces"
	depends on KSU_SUSFS
	default y
	help
		- Allow hiding mmapped real file from /proc/<pid>/[maps|smaps|smaps_rollup|map_files|mem|pagemap]
		- It does NOT support hiding for anon memory.
		- It does NOT hide any inline hooks or plt hooks cause by the injected library itself.
		- It may not be able to evade detections by apps that implement a good injection detection.
		- Effective only on zygote spawned umounted user app process.

endmenu

endmenu
EOF

# =============================================================================
# 0. Sanity check
# =============================================================================
title "Checking kernel source tree at: $KERNEL_ROOT"

[ -f "$FS_KCONFIG"  ] && pass "fs/Kconfig found"  || { fail "fs/Kconfig not found — wrong kernel root?"; exit 1; }
[ -f "$FS_MAKEFILE" ] && pass "fs/Makefile found" || { fail "fs/Makefile not found"; exit 1; }

# =============================================================================
# 1. Check SUSFS patch was applied
# =============================================================================
title "Checking SUSFS patch was applied"

PATCH_OK=true
[ -f "$SUSFS_C"     ] && pass "fs/susfs.c exists"               || { fail "fs/susfs.c missing — patch not applied?"; PATCH_OK=false; }
[ -f "$SUSFS_H"     ] && pass "include/linux/susfs.h exists"    || { fail "include/linux/susfs.h missing";            PATCH_OK=false; }
[ -f "$SUSFS_DEF_H" ] && pass "include/linux/susfs_def.h exists" || { fail "include/linux/susfs_def.h missing";       PATCH_OK=false; }

if [ "$PATCH_OK" = false ]; then
    echo -e "\n${RED}SUSFS patch must be applied before running this script. Aborting.${NC}"
    exit 1
fi

# =============================================================================
# 2. Backup originals
# =============================================================================
title "Backing up originals"

for f in "$FS_KCONFIG" "$FS_MAKEFILE"; do
    bak="${f}.susfs_bak"
    if [ ! -f "$bak" ]; then
        cp "$f" "$bak"
        info "Backed up $(basename $f) → $(basename $bak)"
    else
        info "$(basename $bak) already exists — skipping"
    fi
done

# =============================================================================
# 3. REMOVE the bogus 'source "fs/susfs/Kconfig"' from fs/Kconfig
#    This file does not exist and causes:
#    fs/Kconfig:NNN: can't open file "fs/susfs/Kconfig"
# =============================================================================
title "Removing bogus source line from fs/Kconfig"

COUNT=$(grep -cF "$BOGUS_KCONFIG_ENTRY" "$FS_KCONFIG" 2>/dev/null || true)
if [ "$COUNT" -gt 0 ]; then
    warn "Found $COUNT occurrence(s) of '$BOGUS_KCONFIG_ENTRY' — removing all"
    grep -vF "$BOGUS_KCONFIG_ENTRY" "$FS_KCONFIG" > "${FS_KCONFIG}.tmp"
    mv "${FS_KCONFIG}.tmp" "$FS_KCONFIG"
    fixed "Removed bogus source line from fs/Kconfig"
else
    pass "No bogus source line present in fs/Kconfig"
fi

# =============================================================================
# 4. Ensure fs/Makefile has susfs.o
# =============================================================================
title "Checking fs/Makefile"

COUNT=$(grep -cF "$MAKEFILE_ENTRY" "$FS_MAKEFILE" 2>/dev/null || true)
if [ "$COUNT" -eq 0 ]; then
    warn "Missing: '$MAKEFILE_ENTRY' — adding"
    printf '\n%s\n' "$MAKEFILE_ENTRY" >> "$FS_MAKEFILE"
    fixed "Appended '$MAKEFILE_ENTRY' to fs/Makefile"
elif [ "$COUNT" -eq 1 ]; then
    pass "fs/Makefile entry correct (1 occurrence)"
else
    warn "$COUNT duplicate entries found in fs/Makefile — deduplicating"
    local tmp seen line
    tmp=$(mktemp)
    seen=0
    while IFS= read -r line; do
        if [ "$line" = "$MAKEFILE_ENTRY" ]; then
            [ "$seen" -eq 0 ] && printf '%s\n' "$line" >> "$tmp"
            seen=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$FS_MAKEFILE"
    mv "$tmp" "$FS_MAKEFILE"
    fixed "Deduplicated fs/Makefile"
fi

# =============================================================================
# 5. Ensure drivers/kernelsu/Kconfig has the full correct content
# =============================================================================
title "Checking drivers/kernelsu/Kconfig"

KSU_DIR="$(dirname "$KSU_KCONFIG")"
if [ ! -d "$KSU_DIR" ]; then
    fail "drivers/kernelsu/ directory does not exist — KernelSU not set up"
    exit 1
fi

# Check if key markers are already present
NEEDS_WRITE=false
if [ ! -f "$KSU_KCONFIG" ]; then
    warn "drivers/kernelsu/Kconfig does not exist — creating it"
    NEEDS_WRITE=true
elif ! grep -q "config KSU_SUSFS" "$KSU_KCONFIG"; then
    warn "drivers/kernelsu/Kconfig exists but is missing SUSFS config blocks — overwriting"
    NEEDS_WRITE=true
elif ! grep -q "config KSU_SUSFS_SUS_MAP" "$KSU_KCONFIG"; then
    warn "drivers/kernelsu/Kconfig is missing newer SUSFS entries (e.g. SUS_MAP) — overwriting"
    NEEDS_WRITE=true
else
    pass "drivers/kernelsu/Kconfig already contains full KSU + SUSFS config"
fi

if [ "$NEEDS_WRITE" = true ]; then
    # Backup existing Kconfig if present
    [ -f "$KSU_KCONFIG" ] && cp "$KSU_KCONFIG" "${KSU_KCONFIG}.susfs_bak" && \
        info "Backed up existing drivers/kernelsu/Kconfig"
    printf '%s\n' "$KSU_KCONFIG_CONTENT" > "$KSU_KCONFIG"
    fixed "Written full Kconfig to drivers/kernelsu/Kconfig"
fi

# =============================================================================
# 6. Final validation
# =============================================================================
title "Final validation"

# fs/Kconfig must NOT have the bogus source line
if grep -qF "$BOGUS_KCONFIG_ENTRY" "$FS_KCONFIG"; then
    fail "fs/Kconfig still contains bogus source line — manual fix needed"
else
    pass "fs/Kconfig — no bogus source line"
fi

# fs/Makefile must have exactly 1 susfs.o entry
COUNT=$(grep -cF "$MAKEFILE_ENTRY" "$FS_MAKEFILE" 2>/dev/null || true)
if [ "$COUNT" -eq 1 ]; then
    LINE=$(grep -nF "$MAKEFILE_ENTRY" "$FS_MAKEFILE" | head -1 | cut -d: -f1)
    pass "fs/Makefile — susfs.o entry at line $LINE"
elif [ "$COUNT" -eq 0 ]; then
    fail "fs/Makefile — susfs.o entry still missing"
else
    fail "fs/Makefile — $COUNT duplicate entries remain"
fi

# drivers/kernelsu/Kconfig must have key config symbols
for symbol in "config KSU" "config KSU_SUSFS" "config KSU_SUSFS_SUS_MAP" \
              "config KSU_MANUAL_HOOK" "config KSU_KPROBES_HOOK"; do
    if grep -q "$symbol" "$KSU_KCONFIG" 2>/dev/null; then
        pass "drivers/kernelsu/Kconfig — '$symbol' present"
    else
        fail "drivers/kernelsu/Kconfig — '$symbol' missing"
    fi
done

# =============================================================================
# 7. Summary
# =============================================================================
title "Summary"
echo ""
printf "  Kernel root             : %s\n" "$KERNEL_ROOT"
printf "  fs/Kconfig bogus line   : %s\n" \
    "$(grep -cF "$BOGUS_KCONFIG_ENTRY" "$FS_KCONFIG" 2>/dev/null || echo 0) occurrences (should be 0)"
printf "  fs/Makefile susfs.o     : line %s\n" \
    "$(grep -nF "$MAKEFILE_ENTRY" "$FS_MAKEFILE" 2>/dev/null | head -1 | cut -d: -f1 || echo 'NOT FOUND')"
printf "  drivers/kernelsu/Kconfig: %s\n" \
    "$([ -f "$KSU_KCONFIG" ] && echo "exists ($(wc -l < "$KSU_KCONFIG") lines)" || echo "MISSING")"
echo ""

if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}All checks passed. SUSFS is correctly wired into the build system.${NC}"
    exit 0
else
    echo -e "${RED}$ERRORS error(s) remain. See output above.${NC}"
    exit 1
fi
