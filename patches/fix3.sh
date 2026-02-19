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
# fs/Makefile:
#   obj-y block ends with: stack.o fs_struct.o statfs.o fs_pin.o nsfs.o \
#                           fs_context.o fs_parser.o
#   Followed by blank line then: ifeq ($(CONFIG_BLOCK),y)
#   → Insert susfs.o BEFORE ifeq ($(CONFIG_BLOCK),y)
#
# include/linux/mount.h:
#   struct vfsmount has void *data BEFORE ANDROID_KABI_RESERVE(1-4)
#   ANDROID_KABI_RESERVE(4) EXISTS → wrap with #ifdef CONFIG_KSU_SUSFS
#   Hunk failed only because patch context expected void *data AFTER reserves
#
# fs/namespace.c:
#   HAS #include <linux/bootmem.h> (patch anchor was correct)
#   HAS #include <linux/fs_context.h> added after sched/task.h → caused offset
#   HAS "/* Maximum number of mounts in a mount namespace */" exactly
#   → Use bootmem.h as anchor, insert after it
#
# fs/proc/task_mmu.c:
#   Uses mmap_read_unlock(mm) NOT up_read(&mm->mmap_sem)
#   Uses mmap_read_lock_killable(mm) NOT down_read(&mm->mmap_sem)
#   Pattern: walk_page_range(...) → mmap_read_unlock(mm) → start_vaddr = end
#   → Match mmap_read_unlock(mm) + start_vaddr = end
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
#
# Actual file ends the obj-y block with:
#   		stack.o fs_struct.o statfs.o fs_pin.o nsfs.o \
#   		fs_context.o fs_parser.o
# Then a blank line, then ifeq ($(CONFIG_BLOCK),y)
#
# The patch's context only showed up to nsfs.o so it failed to match
# because fs_context.o fs_parser.o continuation line was not in the
# patch's expected context.
#
# Fix: insert before ifeq ($(CONFIG_BLOCK),y) — always reliable.
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
#
# Actual struct vfsmount:
#   struct vfsmount {
#       struct dentry *mnt_root;
#       struct super_block *mnt_sb;
#       int mnt_flags;
#       void *data;              ← BEFORE the KABI reserves
#       ANDROID_KABI_RESERVE(1);
#       ANDROID_KABI_RESERVE(2);
#       ANDROID_KABI_RESERVE(3);
#       ANDROID_KABI_RESERVE(4); ← patch target
#   } __randomize_layout;
#
# Hunk failed because patch expected void *data AFTER KABI_RESERVE(4).
# Fix: regex match ANDROID_KABI_RESERVE(4) directly, no context dependency.
# ANDROID_KABI_USE(4, ...) expands to an anonymous union consuming the same
# u64 space — struct size and layout are completely unchanged.
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

# Match with any leading whitespace to be tab/space agnostic
pattern = re.compile(r'([ \t]*)ANDROID_KABI_RESERVE\s*\(\s*4\s*\)\s*;')
m = pattern.search(content)
if not m:
    print("  \033[31m[FAIL]\033[0m ANDROID_KABI_RESERVE(4) not found in include/linux/mount.h")
    sys.exit(1)

indent = m.group(1)  # preserve original tab indentation
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
# Actual includes at top (relevant lines):
#   #include <linux/bootmem.h>      ← patch anchor IS present (correct)
#   #include <linux/task_work.h>
#   #include <linux/sched/task.h>
#   #include <linux/fs_context.h>   ← this extra include shifted line numbers
#
# The hunk failed NOT because bootmem.h is missing, but because
# fs_context.h was added after sched/task.h, pushing all subsequent
# lines down and breaking the patch's line-number context.
#
# "/* Maximum number of mounts in a mount namespace */" IS present exactly.
#
# Hunks 7 & 8 only add blank lines inside vfs_kern_mount — cosmetic, skipped.
# =============================================================================
echo ""
echo -e "${BOLD}[3/4]${NC} fs/namespace.c — include and extern declarations"

python3 << 'PYEOF'
import sys, re

fp = "fs/namespace.c"
with open(fp) as f:
    content = f.read()

if "CONFIG_KSU_SUSFS_SUS_MOUNT" in content or "susfs_is_current_ksu_domain" in content:
    print("  \033[33m[SKIP]\033[0m Already contains SUSFS declarations")
    sys.exit(0)

# Part A — insert susfs_def.h include after bootmem.h
# bootmem.h IS confirmed present in this kernel
ANCHOR_INCLUDE = "#include <linux/bootmem.h>"
if ANCHOR_INCLUDE not in content:
    # Should not happen, but safe fallback
    for fallback in ["#include <linux/memblock.h>",
                     "#include <linux/sched/task.h>",
                     "#include <linux/fs_context.h>"]:
        if fallback in content:
            ANCHOR_INCLUDE = fallback
            break
    else:
        print("  \033[31m[FAIL]\033[0m Cannot find include anchor in fs/namespace.c")
        sys.exit(1)

INCLUDE_BLOCK = (
    "\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "#include <linux/susfs_def.h>\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)
content = content.replace(ANCHOR_INCLUDE, ANCHOR_INCLUDE + INCLUDE_BLOCK, 1)
print(f"  \033[32m[PASS]\033[0m susfs_def.h include inserted after: {ANCHOR_INCLUDE}")

# Part B — insert extern block before "/* Maximum number of mounts */"
# Confirmed present exactly in this kernel
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
if ANCHOR_EXTERN not in content:
    print("  \033[31m[FAIL]\033[0m '/* Maximum number of mounts */' not found in fs/namespace.c")
    sys.exit(1)

content = content.replace(ANCHOR_EXTERN, EXTERN_BLOCK + ANCHOR_EXTERN, 1)

with open(fp, 'w') as f:
    f.write(content)

print("  \033[32m[PASS]\033[0m Extern declarations inserted before '/* Maximum number of mounts */'")
print("  \033[33m[SKIP]\033[0m Hunks 7 & 8 — blank lines only in vfs_kern_mount, no functional effect")
PYEOF
[ $? -ne 0 ] && FAILED=$((FAILED+1))

# =============================================================================
# FIX 4: fs/proc/task_mmu.c
#
# CRITICAL: This kernel does NOT use up_read(&mm->mmap_sem).
# It uses the newer mmap locking API:
#   mmap_read_lock_killable(mm)   instead of down_read(&mm->mmap_sem)
#   mmap_read_unlock(mm)          instead of up_read(&mm->mmap_sem)
#
# The previous script would have SILENTLY FAILED on fix 4 because it
# searched for up_read(&mm->mmap_sem) which does not exist here.
#
# Actual pattern in pagemap_read():
#   ret = walk_page_range(start_vaddr, end, &pagemap_walk);
#   mmap_read_unlock(mm);        ← match this
#   start_vaddr = end;           ← insert between these two lines
#
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

# Primary pattern: mmap_read_unlock(mm) — confirmed in this kernel
pattern = re.compile(
    r'([ \t]*mmap_read_unlock\s*\(\s*mm\s*\)\s*;\s*\n)'  # group 1: mmap_read_unlock line
    r'([ \t]*start_vaddr\s*=\s*end\s*;)'                  # group 2: start_vaddr = end
)
m = pattern.search(content)
if m:
    content = content[:m.start()] + m.group(1) + INSERT + m.group(2) + content[m.end():]
    with open(fp, 'w') as f:
        f.write(content)
    print("  \033[32m[PASS]\033[0m SUS_MAP block inserted after mmap_read_unlock(mm)")
    sys.exit(0)

# Fallback: older kernels with up_read(&mm->mmap_sem)
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

# None matched — print diagnostic
print("  \033[31m[FAIL]\033[0m No matching unlock pattern found before 'start_vaddr = end'")
print("        Searched for: mmap_read_unlock / up_read mmap_sem / up_read mmap_lock")
m_ctx = re.search(r'static ssize_t pagemap_read', content)
if m_ctx:
    lines = content[m_ctx.start():m_ctx.start()+3000].split('\n')
    print("        Context lines in pagemap_read containing relevant keywords:")
    for i, line in enumerate(lines):
        if any(k in line for k in ['unlock', 'up_read', 'mmap', 'start_vaddr', 'walk_page']):
            print(f"          ~+{i}: {line.rstrip()}")
sys.exit(1)
PYEOF
[ $? -ne 0 ] && FAILED=$((FAILED+1))

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
if [ "$FAILED" -eq 0 ]; then
    echo -e " ${GREEN}${BOLD}All 4 fixes applied successfully!${NC}"
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
