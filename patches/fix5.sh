#!/usr/bin/env bash
# =============================================================================
#  fix3.sh — SUSFS patch reject fixer for lineage-23.2 sm8250 / lemonades
#
#  Handles the hunks from sus4.patch that consistently fail on this tree:
#    [1/4] fs/Makefile        — susfs.o build target
#    [2/4] include/linux/mount.h — ANDROID_KABI_RESERVE(4) guard
#    [3/4] fs/namespace.c     — include + extern declarations  ← BUG WAS HERE
#    [4/4] fs/proc/task_mmu.c — SUS_MAP block in pagemap_read()
# =============================================================================

set -euo pipefail

CYAN='\033[1m\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

echo ""
echo -e "${CYAN}============================================================${RESET}"
echo -e "${CYAN} SUSFS Reject Fixer — lineage-23.2 sm8250 / lemonades${RESET}"
echo -e "${CYAN}============================================================${RESET}"
echo ""

# ---------------------------------------------------------------------------
# [1/4] fs/Makefile — add susfs.o build target
# ---------------------------------------------------------------------------
echo -e "\033[1m[1/4]\033[0m fs/Makefile — adding susfs.o build target"

if grep -q "CONFIG_KSU_SUSFS.*susfs\.o" fs/Makefile 2>/dev/null; then
    echo -e "  ${YELLOW}[SKIP]${RESET} Already present."
else
    # Insert before the ifeq ($(CONFIG_BLOCK),y) line
    sed -i '/^ifeq ($(CONFIG_BLOCK),y)/i obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile
    if grep -q "CONFIG_KSU_SUSFS.*susfs\.o" fs/Makefile; then
        echo -e "  ${GREEN}[PASS]${RESET} 'obj-\$(CONFIG_KSU_SUSFS) += susfs.o' inserted before ifeq \$(CONFIG_BLOCK),y)"
    else
        echo -e "  ${RED}[FAIL]${RESET} Could not insert susfs.o into fs/Makefile"
        exit 1
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# [2/4] include/linux/mount.h — wrap ANDROID_KABI_RESERVE(4) with SUSFS guard
# ---------------------------------------------------------------------------
echo -e "\033[1m[2/4]\033[0m include/linux/mount.h — wrapping ANDROID_KABI_RESERVE(4)"

if grep -q "susfs_mnt_id_backup" include/linux/mount.h 2>/dev/null; then
    echo -e "  ${YELLOW}[SKIP]${RESET} susfs_mnt_id_backup already present."
else
    python3 - << 'PYEOF'
import re, sys

path = "include/linux/mount.h"
with open(path) as f:
    src = f.read()

old = "\tANDROID_KABI_RESERVE(4);"
new = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n"
    "#else\n"
    "\tANDROID_KABI_RESERVE(4);\n"
    "#endif"
)

if old not in src:
    print("  [WARN] 'ANDROID_KABI_RESERVE(4)' not found — mount.h may already be patched")
    sys.exit(0)

with open(path, "w") as f:
    f.write(src.replace(old, new, 1))
print("  done")
PYEOF
    if grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
        echo -e "  ${GREEN}[PASS]${RESET} ANDROID_KABI_RESERVE(4) wrapped with CONFIG_KSU_SUSFS guard"
        echo -e "          Struct size unchanged — ANDROID_KABI_USE consumes same u64 slot"
    else
        echo -e "  ${RED}[FAIL]${RESET} mount.h patch failed"
        exit 1
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# [3/4] fs/namespace.c — include and extern declarations
#
# THE BUG THAT CAUSED THE BUILD FAILURE:
#
# The original fix3.sh checked for 'susfs_is_current_ksu_domain' anywhere in
# the file to decide whether to inject the extern block. This produced a
# FALSE POSITIVE: the symbol was found in the CALL SITES that other hunks
# (#2–#6, #9–#17) had already applied successfully. The check said "already
# present" and skipped — but those are call sites, not declarations.
#
# Result: the compiler saw 6 undeclared identifiers at build time:
#   namespace.c:145   : implicit declaration of susfs_is_current_ksu_domain()
#   namespace.c:1189  : undeclared susfs_is_sdcard_android_data_decrypted
#   namespace.c:1193  : implicit declaration of susfs_is_current_ksu_domain()
#   namespace.c:1195  : undeclared identifier CL_COPY_MNT_NS
#   namespace.c:3252  : undeclared identifier CL_COPY_MNT_NS
#   namespace.c:3847  : undeclared identifier susfs_ksu_mounts
#   → make[2]: *** [fs/namespace.o] Error 1  → make: *** Error 2
#
# FIX: check for the DECLARATION form (extern keyword), not just the symbol
# name. If the extern block is absent, inject all 4 missing declarations.
# ---------------------------------------------------------------------------
echo -e "\033[1m[3/4]\033[0m fs/namespace.c — include and extern declarations"

# Part A: #include <linux/susfs_def.h>
if grep -q "susfs_def\.h" fs/namespace.c 2>/dev/null; then
    echo -e "  ${YELLOW}[SKIP]${RESET} Part A: susfs_def.h include already present."
else
    sed -i '/#include <linux\/bootmem\.h>/a #include <linux\/susfs_def.h>' fs/namespace.c
    if grep -q "susfs_def\.h" fs/namespace.c; then
        echo -e "  ${GREEN}[PASS]${RESET} Part A: susfs_def.h include inserted after: #include <linux/bootmem.h>"
    else
        echo -e "  ${RED}[FAIL]${RESET} Part A: could not insert susfs_def.h include"
        exit 1
    fi
fi

# Part B: extern declarations block
#
# THE FIX: grep for 'extern.*susfs_is_current_ksu_domain' (requires the
# 'extern' keyword). The old grep for 'susfs_is_current_ksu_domain' alone
# matched call sites and falsely reported the block as already present.
#
# The block must declare all symbols used in namespace.c call sites:
#   • susfs_is_current_ksu_domain()   — called at lines 145, 1193
#   • susfs_is_sdcard_android_data_decrypted — used at line 1189
#   • CL_COPY_MNT_NS                  — used at lines 1195, 3252
#   • susfs_ksu_mounts                — used at line 3847
if grep -q "extern.*susfs_is_current_ksu_domain\|extern bool susfs_is_current_ksu_domain" fs/namespace.c 2>/dev/null; then
    echo -e "  ${YELLOW}[SKIP]${RESET} Part B: extern declarations already present (confirmed by 'extern' keyword)."
else
    # Inject the full extern block immediately after the susfs_def.h include line
    python3 - << 'PYEOF'
path = "fs/namespace.c"
with open(path) as f:
    src = f.read()

anchor = "#include <linux/susfs_def.h>"
if anchor not in src:
    print("  [ERROR] anchor '#include <linux/susfs_def.h>' not found — run Part A first")
    raise SystemExit(1)

extern_block = (
    "\n"
    "#ifdef CONFIG_KSU_SUSFS\n"
    "extern bool susfs_is_current_ksu_domain(void);\n"
    "extern bool susfs_is_sdcard_android_data_decrypted;\n"
    "extern atomic64_t susfs_ksu_mounts;\n"
    "#define CL_COPY_MNT_NS 0x40\n"
    "#endif /* CONFIG_KSU_SUSFS */"
)

# Insert right after the anchor line
src = src.replace(anchor, anchor + extern_block, 1)

with open(path, "w") as f:
    f.write(src)
print("  done")
PYEOF
    if grep -q "extern.*susfs_is_current_ksu_domain\|extern bool susfs_is_current_ksu_domain" fs/namespace.c; then
        echo -e "  ${GREEN}[PASS]${RESET} Part B: extern declarations injected after susfs_def.h include"
        echo -e "           (susfs_is_current_ksu_domain, susfs_is_sdcard_android_data_decrypted,"
        echo -e "            susfs_ksu_mounts, CL_COPY_MNT_NS)"
    else
        echo -e "  ${RED}[FAIL]${RESET} Part B: extern block injection failed"
        exit 1
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# [4/4] fs/proc/task_mmu.c — SUS_MAP block in pagemap_read()
# ---------------------------------------------------------------------------
echo -e "\033[1m[4/4]\033[0m fs/proc/task_mmu.c — SUS_MAP block in pagemap_read()"

if grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c 2>/dev/null; then
    echo -e "  ${YELLOW}[SKIP]${RESET} Already contains CONFIG_KSU_SUSFS_SUS_MAP"
else
    # Locate the target line and insert the SUS_MAP block before it
    python3 - << 'PYEOF'
path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

# The anchor is the line just before where the SUS_MAP block should go.
# Adjust if your kernel version differs.
anchor = "\t\tlen = min(count, PM_ENTRY_BYTES * pm.pos);"
if anchor not in src:
    print("  [WARN] anchor not found in task_mmu.c — may already be patched or offset changed")
    raise SystemExit(0)

sus_map_block = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tif (susfs_is_current_ksu_domain())\n"
    "\t\t\tsusfs_sus_map_restore_pm(pm.buffer, pm.pos);\n"
    "#endif\n"
    "\t\t"
)

src = src.replace(anchor, sus_map_block + anchor.lstrip('\t'), 1)

with open(path, "w") as f:
    f.write(src)
print("  done")
PYEOF
    if grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
        echo -e "  ${GREEN}[PASS]${RESET} SUS_MAP block inserted in pagemap_read()"
    else
        echo -e "  ${RED}[FAIL]${RESET} Could not insert SUS_MAP block into fs/proc/task_mmu.c"
        exit 1
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Cleanup leftover .rej files
# ---------------------------------------------------------------------------
echo -e "\033[1m[cleanup]\033[0m Removing leftover .rej files..."
REJ_FILES=$(find . -name "*.rej" 2>/dev/null)
if [ -n "$REJ_FILES" ]; then
    echo "$REJ_FILES"
    find . -name "*.rej" -delete
    REJ_COUNT=$(echo "$REJ_FILES" | wc -l)
    echo -e "  ${GREEN}[DONE]${RESET} Removed ${REJ_COUNT} .rej file(s)"
else
    echo -e "  ${GREEN}[DONE]${RESET} No .rej files found."
fi
echo ""

echo -e "${CYAN}============================================================${RESET}"
echo -e " ${GREEN}\033[1mAll fixes applied successfully!${RESET}"
echo -e "${CYAN}============================================================${RESET}"
echo ""
echo "  Verify your defconfig has:"
echo "    CONFIG_KSU_SUSFS=y"
echo "    CONFIG_KSU_SUSFS_SUS_MOUNT=y"
echo "    CONFIG_KSU_SUSFS_SUS_MAP=y"
echo ""
echo "  Then run: git diff   — to review all changes before building"
echo ""
