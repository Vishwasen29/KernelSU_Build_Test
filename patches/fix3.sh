#!/bin/bash
# =============================================================================
# fix_susfs_rejects.sh
# Fixes the 4 rejected SUSFS patch hunks for LineageOS 23.2
# android_kernel_oneplus_sm8250 (OnePlus 9R / lemonades)
#
# Run from kernel source root:
#   cd $GITHUB_WORKSPACE/kernel_workspace/android-kernel
#   bash fix_susfs_rejects.sh
#
# Verified against actual source files:
#
# include/linux/mount.h:
#   struct vfsmount has void *data BEFORE ANDROID_KABI_RESERVE(1-4)
#   ANDROID_KABI_RESERVE(4) EXISTS — hunk failed only because patch context
#   expected void *data AFTER the reserves. Fix wraps it with #ifdef.
#
# fs/Makefile:
#   obj-y block ends with fs_context.o fs_parser.o (patch only saw up to nsfs.o)
#   Insert before ifeq ($(CONFIG_BLOCK),y) — always reliable.
#
# fs/namespace.c:
#   All 3 hunks were rejected. The extern block may already exist from a
#   separate KernelSU patch script — so we check susfs_def.h include and
#   extern declarations INDEPENDENTLY and only add what is missing.
#
# fs/proc/task_mmu.c:
#   Uses mmap_read_unlock(mm) NOT up_read(&mm->mmap_sem)
#   Hunk failed due to this API difference + line offset shift.
# =============================================================================

set -e
FAILED=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILED=$((FAILED+1)); }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }

echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN} SUSFS Reject Fixer — lineage-23.2 sm8250 / lemonades${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo ""

if [ ! -f "Makefile" ] || ! grep -qE "KERNELVERSION|PATCHLEVEL" Makefile 2>/dev/null; then
    echo -e "${RED}ERROR:${NC} Run this from the kernel source root directory."
    exit 1
fi

# =============================================================================
# FIX 1: fs/Makefile
# =============================================================================
echo -e "${BOLD}[1/4]${NC} fs/Makefile — adding susfs.o build target"

python3 << 'PYEOF'
import sys

fp = "fs/Makefile"
with open(fp) as f:
    content = f.read()

MARKER = "obj-$(CONFIG_KSU_SUSFS) += susfs.o"
if MARKER in content:
    print("  \033[33m[SKIP]\033[0m Already contains susfs.o entry")
    sys.exit(0)

INSERT = MARKER + "\n\n"
ANCHOR = "ifeq ($(CONFIG_BLOCK),y)"

if ANCHOR not in content:
    print("  \033[31m[FAIL]\033[0m 'ifeq ($(CONFIG_BLOCK),y)' not found in fs/Makefile")
    sys.exit(1)

content = content.replace(ANCHOR, INSERT + ANCHOR, 1)
with open(fp, 'w') as f:
    f.write(content)

print("  \033[32m[PASS]\033[0m 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' inserted before ifeq ($(CONFIG_BLOCK),y)")
PYEOF
[ $? -ne 0 ] && FAILED=$((FAILED+1))

# =============================================================================
# FIX 2: include/linux/mount.h
# =============================================================================
echo ""
echo -e "${BOLD}[2/4]${NC} include/linux/mount.h — wrapping ANDROID_KABI_RESERVE(4)"

python3 << 'PYEOF'
import sys, re

fp = "include/linux/mount.h"
with open(fp) as f:
    content = f.read()

if "susfs_mnt_id_backup" in content:
    print("  \033[33m[SKIP]\033[0m Already contains susfs_mnt_id_backup")
    sys.exit(0)

pattern = re.compile(r'([ \t]*)ANDROID_KABI_RESERVE\s*\(\s*4\s*\)\s*;')
m = pattern.search(content)
if not m:
    print("  \033[31m[FAIL]\033[0m ANDROID_KABI_RESERVE(4) not found in include/linux/mount.h")
    sys.exit(1)

indent = m.group(1)
replacement = (
    f"#ifdef CONFIG_KSU_SUSFS\n"
    f"{indent}ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n"
    f"#else\n"
    f"{indent}ANDROID_KABI_RESERVE(4);\n"
    f"#endif"
)

content = content[:m.start()] + replacement + content[m.end():]
with open(fp, 'w') as f:
    f.write(content)

print("  \033[32m[PASS]\033[0m ANDROID_KABI_RESERVE(4) wrapped with CONFIG_KSU_SUSFS guard")
print("        Struct size unchanged — ANDROID_KABI_USE consumes same u64 slot")
PYEOF
[ $? -ne 0 ] && FAILED=$((FAILED+1))

# =============================================================================
# FIX 3: fs/namespace.c
#
# IMPORTANT: All 3 namespace.c hunks were rejected by git apply.
# However, the extern block (susfs_is_current_ksu_domain etc.) may already
# exist if a separate KernelSU patch script added it independently.
# We therefore check and apply each part INDEPENDENTLY:
#   Part A — susfs_def.h include (after bootmem.h)
#   Part B — extern declarations (before /* Maximum number of mounts */)
# This way a partial state from another script is handled correctly.
#
# Hunks 7 & 8 only add blank lines in vfs_kern_mount — skipped (cosmetic).
# =============================================================================
echo ""
echo -e "${BOLD}[3/4]${NC} fs/namespace.c — include and extern declarations (checked independently)"

python3 << 'PYEOF'
import sys, re

fp = "fs/namespace.c"
with open(fp) as f:
    content = f.read()

applied_a = False
applied_b = False

# ------------------------------------------------------------------
# Part A: susfs_def.h include — check independently
# ------------------------------------------------------------------
if "susfs_def.h" in content:
    print("  \033[33m[SKIP]\033[0m Part A: susfs_def.h include already present")
    applied_a = True
else:
    INCLUDE_BLOCK = (
        "\n"
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "#include <linux/susfs_def.h>\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    )

    # Try anchors in order of preference
    anchor = None
    for candidate in [
        "#include <linux/bootmem.h>",
        "#include <linux/memblock.h>",
        "#include <linux/sched/task.h>",
        "#include <linux/task_work.h>",
        "#include <linux/fs_context.h>",
    ]:
        if candidate in content:
            anchor = candidate
            break

    if anchor is None:
        print("  \033[31m[FAIL]\033[0m Part A: Cannot find include anchor in fs/namespace.c")
        sys.exit(1)

    content = content.replace(anchor, anchor + INCLUDE_BLOCK, 1)
    print(f"  \033[32m[PASS]\033[0m Part A: susfs_def.h include inserted after: {anchor}")
    applied_a = True

# ------------------------------------------------------------------
# Part B: extern declarations — check independently
# ------------------------------------------------------------------
if "susfs_is_current_ksu_domain" in content:
    print("  \033[33m[SKIP]\033[0m Part B: extern declarations already present")
    applied_b = True
else:
    EXTERN_BLOCK = (
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "extern bool susfs_is_current_ksu_domain(void);\n"
        "extern bool susfs_is_sdcard_android_data_decrypted;\n"
        "\n"
        "static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n"
        "\n"
        "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "\n"
    )

    ANCHOR_EXTERN = "/* Maximum number of mounts in a mount namespace */"
    if ANCHOR_EXTERN in content:
        content = content.replace(ANCHOR_EXTERN, EXTERN_BLOCK + ANCHOR_EXTERN, 1)
        print("  \033[32m[PASS]\033[0m Part B: extern declarations inserted before '/* Maximum number of mounts */'")
        applied_b = True
    else:
        # Fallback: before sysctl_mount_max declaration
        m = re.search(r'unsigned int sysctl_mount_max', content)
        if m:
            content = content[:m.start()] + EXTERN_BLOCK + content[m.start():]
            print("  \033[32m[PASS]\033[0m Part B: extern declarations inserted before sysctl_mount_max (fallback)")
            applied_b = True
        else:
            print("  \033[31m[FAIL]\033[0m Part B: Cannot find extern insertion anchor in fs/namespace.c")
            sys.exit(1)

if applied_a or applied_b:
    with open(fp, 'w') as f:
        f.write(content)

print("  \033[33m[SKIP]\033[0m Hunks 7 & 8 — blank lines only in vfs_kern_mount, no functional effect")
PYEOF
[ $? -ne 0 ] && FAILED=$((FAILED+1))

# =============================================================================
# FIX 4: fs/proc/task_mmu.c
# Uses mmap_read_unlock(mm) — NOT up_read(&mm->mmap_sem)
# =============================================================================
echo ""
echo -e "${BOLD}[4/4]${NC} fs/proc/task_mmu.c — SUS_MAP block in pagemap_read()"

python3 << 'PYEOF'
import sys, re

fp = "fs/proc/task_mmu.c"
with open(fp) as f:
    content = f.read()

if "CONFIG_KSU_SUSFS_SUS_MAP" in content:
    print("  \033[33m[SKIP]\033[0m Already contains CONFIG_KSU_SUSFS_SUS_MAP")
    sys.exit(0)

INSERT = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tvma = find_vma(mm, start_vaddr);\n"
    "\t\tif (vma && vma->vm_file) {\n"
    "\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
    "\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n"
    "\t\t\t\tpm.buffer->pme = 0;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
)

# Primary: mmap_read_unlock(mm) — confirmed in this kernel
pattern = re.compile(
    r'([ \t]*mmap_read_unlock\s*\(\s*mm\s*\)\s*;\s*\n)'
    r'([ \t]*start_vaddr\s*=\s*end\s*;)'
)
m = pattern.search(content)
if m:
    content = content[:m.start()] + m.group(1) + INSERT + m.group(2) + content[m.end():]
    with open(fp, 'w') as f:
        f.write(content)
    print("  \033[32m[PASS]\033[0m SUS_MAP block inserted after mmap_read_unlock(mm)")
    sys.exit(0)

# Fallback: up_read(&mm->mmap_sem)
pattern2 = re.compile(
    r'([ \t]*up_read\s*\(\s*&mm->mmap_sem\s*\)\s*;\s*\n)'
    r'([ \t]*start_vaddr\s*=\s*end\s*;)'
)
m2 = pattern2.search(content)
if m2:
    content = content[:m2.start()] + m2.group(1) + INSERT + m2.group(2) + content[m2.end():]
    with open(fp, 'w') as f:
        f.write(content)
    print("  \033[32m[PASS]\033[0m SUS_MAP block inserted after up_read(&mm->mmap_sem) [fallback]")
    sys.exit(0)

# Fallback: up_read(&mm->mmap_lock)
pattern3 = re.compile(
    r'([ \t]*up_read\s*\(\s*&mm->mmap_lock\s*\)\s*;\s*\n)'
    r'([ \t]*start_vaddr\s*=\s*end\s*;)'
)
m3 = pattern3.search(content)
if m3:
    content = content[:m3.start()] + m3.group(1) + INSERT + m3.group(2) + content[m3.end():]
    with open(fp, 'w') as f:
        f.write(content)
    print("  \033[32m[PASS]\033[0m SUS_MAP block inserted after up_read(&mm->mmap_lock) [fallback]")
    sys.exit(0)

print("  \033[31m[FAIL]\033[0m No matching unlock pattern found before 'start_vaddr = end'")
m_ctx = re.search(r'static ssize_t pagemap_read', content)
if m_ctx:
    lines = content[m_ctx.start():m_ctx.start()+3000].split('\n')
    print("        Relevant lines in pagemap_read:")
    for i, line in enumerate(lines):
        if any(k in line for k in ['unlock', 'up_read', 'mmap', 'start_vaddr', 'walk_page']):
            print(f"          ~+{i}: {line.rstrip()}")
sys.exit(1)
PYEOF
[ $? -ne 0 ] && FAILED=$((FAILED+1))

# =============================================================================
# CLEANUP: Remove all .rej files created by git apply --reject
# These are no longer needed once the fix script has run
# =============================================================================
echo ""
echo -e "${BOLD}[cleanup]${NC} Removing leftover .rej files..."
REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
    find . -name "*.rej" -print -delete
    echo -e "  ${GREEN}[DONE]${NC} Removed $REJ_COUNT .rej file(s)"
else
    echo -e "  ${YELLOW}[SKIP]${NC} No .rej files found"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
if [ "$FAILED" -eq 0 ]; then
    echo -e " ${GREEN}${BOLD}All fixes applied successfully!${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""
    echo "  Verify your defconfig has:"
    echo "    CONFIG_KSU_SUSFS=y"
    echo "    CONFIG_KSU_SUSFS_SUS_MOUNT=y"
    echo "    CONFIG_KSU_SUSFS_SUS_MAP=y"
    echo ""
    echo "  Then run: git diff   — to review all changes before building"
else
    echo -e " ${RED}${BOLD}$FAILED fix(es) FAILED — see output above${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
fi
echo ""
[ "$FAILED" -gt 0 ] && exit 1 || exit 0
