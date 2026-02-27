#!/bin/bash
# verify_susfs_patches.sh
#
# Verifies that all SUSFS source patches, Kconfig entries, and kernel .config
# options are correctly applied on a LineageOS / AOSP 4.19 kernel tree before
# starting a full compile.
#
# Usage:
#   bash verify_susfs_patches.sh [path/to/android-kernel] [path/to/out/.config]
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed

set -euo pipefail

KERNEL_ROOT="${1:-.}"
CONFIG_FILE="${2:-${KERNEL_ROOT}/out/.config}"

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

PASS=0; FAIL=0; WARN=0

_ok()   { echo -e "  ${GREEN}✅ $*${RESET}";  PASS=$((PASS + 1)); }
_fail() { echo -e "  ${RED}❌ MISSING: $*${RESET}"; FAIL=$((FAIL + 1)); }
_warn() { echo -e "  ${YELLOW}⚠️  WARNING: $*${RESET}"; WARN=$((WARN + 1)); }
_head() { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; }

check_file() {
    local file="$1" pattern="$2" label="$3"
    if [ ! -f "${KERNEL_ROOT}/${file}" ]; then
        _fail "${label}  →  file '${file}' not found"
    elif grep -q "$pattern" "${KERNEL_ROOT}/${file}" 2>/dev/null; then
        _ok "${label}"
    else
        _fail "${label}  (pattern '${pattern}' not in ${file})"
    fi
}

check_file_absent() {
    local file="$1" pattern="$2" label="$3"
    if [ ! -f "${KERNEL_ROOT}/${file}" ]; then
        return
    elif grep -q "$pattern" "${KERNEL_ROOT}/${file}" 2>/dev/null; then
        _fail "${label}  (should be absent but found in ${file})"
    else
        _ok "${label}"
    fi
}

check_config() {
    local key="$1"
    if grep -q "^${key}=y" "$CONFIG_FILE" 2>/dev/null; then
        _ok "${key}=y"
    else
        _fail "${key} missing or not =y in .config"
    fi
}

check_kconfig_typed() {
    local kconfig="$1" symbol="$2"
    if ! grep -q "^config ${symbol}$" "$kconfig" 2>/dev/null; then
        _fail "config ${symbol} absent from Kconfig"
        return
    fi
    if awk "/^config ${symbol}$/{found=1; next} found && /^\t(bool|tristate|int|hex|string)/{ok=1; exit} found && /^config /{exit} END{exit !ok}" "$kconfig" 2>/dev/null; then
        _ok "config ${symbol}  (typed)"
    else
        _warn "config ${symbol} exists but has NO type declaration — olddefconfig will drop it"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}SUSFS Patch Verification${RESET}"
echo "Kernel root : ${KERNEL_ROOT}"
echo "Config file : ${CONFIG_FILE}"
echo "Date        : $(date '+%Y-%m-%d %H:%M:%S')"

# ── 1. Core SUSFS source files ────────────────────────────────────────────────
_head "1. Core SUSFS source files"
for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    [ -f "${KERNEL_ROOT}/${f}" ] && _ok "${f}" || _fail "${f} not found"
done

# ── 2. fs/Makefile ────────────────────────────────────────────────────────────
_head "2. fs/Makefile"
check_file "fs/Makefile" "susfs\.o" "susfs.o build entry"

# ── 3. fs/namespace.c ────────────────────────────────────────────────────────
_head "3. fs/namespace.c"
check_file "fs/namespace.c" "susfs_def\.h"                         "susfs_def.h #include"
check_file "fs/namespace.c" "extern bool susfs_is_current_ksu_domain" "extern susfs_is_current_ksu_domain declaration"
check_file "fs/namespace.c" "CL_COPY_MNT_NS"                       "CL_COPY_MNT_NS flag definition"
check_file "fs/namespace.c" "bypass_orig_flow"                      "bypass_orig_flow label in mnt_alloc_group_id()"
check_file "fs/namespace.c" "susfs_alloc_sus_vfsmnt"                "susfs_alloc_sus_vfsmnt function defined"
check_file "fs/namespace.c" "susfs_reuse_sus_vfsmnt"                "susfs_reuse_sus_vfsmnt function defined"
# Call-site checks — distinguishes from bare definition
check_file "fs/namespace.c" "susfs_alloc_sus_vfsmnt(old->mnt_devname)" \
    "susfs_alloc_sus_vfsmnt() CALL SITE in clone_mnt()  ← not just definition"
check_file "fs/namespace.c" "susfs_reuse_sus_vfsmnt(old->mnt_devname" \
    "susfs_reuse_sus_vfsmnt() CALL SITE in clone_mnt()  ← not just definition"
check_file "fs/namespace.c" "flag & CL_COPY_MNT_NS"                "CL_COPY_MNT_NS flag check inside clone_mnt()"
check_file "fs/namespace.c" "atomic64_inc(&susfs_ksu_mounts)"       "susfs_ksu_mounts counter increment in clone_mnt()"
check_file "fs/namespace.c" "copy_flags |= CL_COPY_MNT_NS"         "CL_COPY_MNT_NS set in copy_mnt_ns()"
check_file "fs/namespace.c" "susfs_reorder_mnt_id"                  "susfs_reorder_mnt_id() function"

# ── 4. include/linux/mount.h ─────────────────────────────────────────────────
_head "4. include/linux/mount.h"
check_file        "include/linux/mount.h" "susfs_mnt_id_backup"     "susfs_mnt_id_backup KABI field"
check_file_absent "include/linux/mount.h" "ANDROID_KABI_RESERVE(4)" "ANDROID_KABI_RESERVE(4) fully replaced"

# ── 5. fs/proc/task_mmu.c ────────────────────────────────────────────────────
_head "5. fs/proc/task_mmu.c"
check_file "fs/proc/task_mmu.c" "BIT_SUS_MAPS" "BIT_SUS_MAPS guard in pagemap_read()"

# ── 6. fs/proc/base.c ────────────────────────────────────────────────────────
_head "6. fs/proc/base.c"
check_file "fs/proc/base.c" "susfs" "susfs hooks present"

# ── 7. Other patched files ────────────────────────────────────────────────────
_head "7. Other patched files"
check_file "fs/namei.c"             "susfs" "susfs hooks in fs/namei.c"
check_file "fs/stat.c"              "susfs" "susfs hooks in fs/stat.c"
check_file "fs/statfs.c"            "susfs" "susfs hooks in fs/statfs.c"
check_file "fs/readdir.c"           "susfs" "susfs hooks in fs/readdir.c"
check_file "fs/proc_namespace.c"    "susfs" "susfs hooks in fs/proc_namespace.c"
check_file "fs/proc/cmdline.c"      "susfs" "susfs hooks in fs/proc/cmdline.c"
check_file "fs/proc/fd.c"           "susfs" "susfs hooks in fs/proc/fd.c"
check_file "kernel/kallsyms.c"      "susfs" "susfs hooks in kernel/kallsyms.c"
check_file "kernel/sys.c"           "susfs" "susfs hooks in kernel/sys.c"
check_file "security/selinux/avc.c" "susfs" "susfs hooks in security/selinux/avc.c"

# ── 8. fs/overlayfs ──────────────────────────────────────────────────────────
_head "8. fs/overlayfs"

# inode.c: This SUSFS version (KernelSU-Next legacy-susfs) does NOT expose
# susfs_sus_kstat() — that symbol does not exist. inode.c only needs the
# #include. Checking for the include guards against the previously-injected
# wrong call (susfs_sus_kstat(real.dentry, stat)) which caused 3 compiler errors.
check_file "fs/overlayfs/inode.c" "#include <linux/susfs" \
    "fs/overlayfs/inode.c has susfs.h include"
check_file_absent "fs/overlayfs/inode.c" "susfs_sus_kstat(" \
    "fs/overlayfs/inode.c has NO susfs_sus_kstat() call  ← would cause compiler error"

# readdir.c: the SUS_PATH hook function does exist in this SUSFS version
check_file "fs/overlayfs/readdir.c" "susfs" \
    "susfs hooks in fs/overlayfs/readdir.c"

# ── 9. KernelSU Kconfig symbols ──────────────────────────────────────────────
_head "9. KernelSU Kconfig symbols"

if [ -f "${KERNEL_ROOT}/KernelSU-Next/kernel/Kconfig" ]; then
    KCONFIG="${KERNEL_ROOT}/KernelSU-Next/kernel/Kconfig"
    echo "  Kconfig : KernelSU-Next/kernel/Kconfig"
elif [ -f "${KERNEL_ROOT}/KernelSU/kernel/Kconfig" ]; then
    KCONFIG="${KERNEL_ROOT}/KernelSU/kernel/Kconfig"
    echo "  Kconfig : KernelSU/kernel/Kconfig"
else
    _fail "KernelSU Kconfig not found"
    KCONFIG=""
fi

if [ -n "$KCONFIG" ]; then
    for sym in \
        KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
        KSU_SUSFS_SUS_OVERLAYFS KSU_SUSFS_TRY_UMOUNT KSU_SUSFS_SPOOF_UNAME \
        KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_ENABLE_LOG KSU_SUSFS_SUS_SU \
        KSU_SUSFS_HAS_MAGIC_MOUNT
    do
        check_kconfig_typed "$KCONFIG" "$sym"
    done
fi

# ── 10. Kernel .config options ────────────────────────────────────────────────
_head "10. Kernel .config options"

if [ ! -f "$CONFIG_FILE" ]; then
    _warn ".config not found at '${CONFIG_FILE}' — skipping (run after defconfig step)"
else
    echo "  Config: ${CONFIG_FILE}"
    for key in \
        CONFIG_KSU CONFIG_KSU_SUSFS \
        CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_MOUNT \
        CONFIG_KSU_SUSFS_SUS_KSTAT CONFIG_KSU_SUSFS_SUS_OVERLAYFS \
        CONFIG_KSU_SUSFS_TRY_UMOUNT CONFIG_KSU_SUSFS_SPOOF_UNAME \
        CONFIG_KSU_SUSFS_OPEN_REDIRECT CONFIG_KSU_SUSFS_ENABLE_LOG \
        CONFIG_KSU_SUSFS_SUS_SU CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT
    do
        check_config "$key"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=========================================${RESET}"
echo -e "  ${GREEN}Passed  : ${PASS}${RESET}"
[ "$WARN" -gt 0 ] && echo -e "  ${YELLOW}Warnings: ${WARN}${RESET}"
[ "$FAIL" -gt 0 ] && echo -e "  ${RED}Failed  : ${FAIL}${RESET}"
echo -e "${BOLD}=========================================${RESET}"

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}${BOLD}❌ Verification FAILED — ${FAIL} check(s) did not pass.${RESET}"
    echo    "   Fix the items marked ❌ above before starting a full build."
    echo    "   Re-run susfs_fix.sh then retry this script."
    exit 1
else
    echo -e "${GREEN}${BOLD}✅ All checks passed — SUSFS patches look complete.${RESET}"
    [ "$WARN" -gt 0 ] && echo -e "${YELLOW}   Review the ⚠️  warnings above before building.${RESET}"
    exit 0
fi
