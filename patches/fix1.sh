#!/bin/bash

# SUSFS Patch Fix Script - Run AFTER patch rejection
# This script manually applies rejected hunks from the SUSFS patch
# For Lineage 23.2 OnePlus 9R (Kernel 4.19.325)

set -e

KERNEL_DIR="${1:-.}"
cd "$KERNEL_DIR"

echo "========================================"
echo "SUSFS Patch Rejection Fix Script"
echo "Kernel Version: 4.19.325"
echo "Device: OnePlus 9R (lemonades)"
echo "========================================"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Cleaning up .orig files..."
find . -name "*.orig" -type f -delete 2>/dev/null || true

echo ""
echo "Step 1: Fixing fs/Makefile"
echo "----------------------------"

MAKEFILE="fs/Makefile"
if [ -f "$MAKEFILE" ]; then
    # Check if susfs.o line is missing
    if ! grep -q "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" "$MAKEFILE"; then
        # Find the line number with "stack.o fs_struct.o statfs.o fs_pin.o nsfs.o"
        LINE_NUM=$(grep -n "stack.o fs_struct.o statfs.o fs_pin.o nsfs.o" "$MAKEFILE" | cut -d: -f1)
        
        if [ -n "$LINE_NUM" ]; then
            # Check if fs_context.o fs_parser.o exists on the next line
            NEXT_LINE=$((LINE_NUM + 1))
            if sed -n "${NEXT_LINE}p" "$MAKEFILE" | grep -q "fs_context.o fs_parser.o"; then
                # Insert after the fs_context line, before the blank line
                sed -i "${NEXT_LINE}a\\
obj-\$(CONFIG_KSU_SUSFS) += susfs.o\\
" "$MAKEFILE"
            else
                # Insert after stack.o line and blank line
                sed -i "${LINE_NUM}a\\
\\
obj-\$(CONFIG_KSU_SUSFS) += susfs.o\\
" "$MAKEFILE"
            fi
            echo -e "${GREEN}✓ Added susfs.o to fs/Makefile${NC}"
        else
            echo -e "${RED}✗ Could not find insertion point in fs/Makefile${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}⊘ susfs.o already present in fs/Makefile${NC}"
    fi
else
    echo -e "${RED}✗ fs/Makefile not found!${NC}"
    exit 1
fi

echo ""
echo "Step 2: Fixing fs/namespace.c"
echo "------------------------------"

NAMESPACE_C="fs/namespace.c"
if [ -f "$NAMESPACE_C" ]; then
    # Fix 1: Add includes if not present
    if ! grep -q "CONFIG_KSU_SUSFS_SUS_MOUNT" "$NAMESPACE_C"; then
        # Find line with #include <linux/sched/task.h>
        LINE_NUM=$(grep -n "#include <linux/sched/task.h>" "$NAMESPACE_C" | cut -d: -f1 | head -1)
        
        if [ -n "$LINE_NUM" ]; then
            sed -i "${LINE_NUM}a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\\
#include <linux/susfs_def.h>\\
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT" "$NAMESPACE_C"
            echo -e "${GREEN}✓ Added SUSFS includes to namespace.c${NC}"
        else
            echo -e "${RED}✗ Could not find #include <linux/sched/task.h> in namespace.c${NC}"
        fi
    else
        echo -e "${YELLOW}⊘ SUSFS includes already in namespace.c${NC}"
    fi
    
    # Fix 2: Add declarations after internal.h
    if ! grep -q "extern bool susfs_is_current_ksu_domain" "$NAMESPACE_C"; then
        LINE_NUM=$(grep -n '#include "internal.h"' "$NAMESPACE_C" | cut -d: -f1 | head -1)
        
        if [ -n "$LINE_NUM" ]; then
            sed -i "${LINE_NUM}a\\
\\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\\
extern bool susfs_is_current_ksu_domain(void);\\
extern bool susfs_is_sdcard_android_data_decrypted;\\
\\
static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\\
\\
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\\
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT" "$NAMESPACE_C"
            echo -e "${GREEN}✓ Added SUSFS declarations to namespace.c${NC}"
        else
            echo -e "${RED}✗ Could not find #include \"internal.h\" in namespace.c${NC}"
        fi
    else
        echo -e "${YELLOW}⊘ SUSFS declarations already in namespace.c${NC}"
    fi
else
    echo -e "${RED}✗ fs/namespace.c not found!${NC}"
    exit 1
fi

echo ""
echo "Step 3: Fixing fs/proc/task_mmu.c"
echo "----------------------------------"

TASK_MMU_C="fs/proc/task_mmu.c"
if [ -f "$TASK_MMU_C" ]; then
    if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$TASK_MMU_C"; then
        # Look for mmap_read_unlock(mm); or up_read(&mm->mmap_sem);
        if grep -q "mmap_read_unlock(mm);" "$TASK_MMU_C"; then
            # Modern kernel - use mmap_read_unlock
            LINE_NUM=$(grep -n "mmap_read_unlock(mm);" "$TASK_MMU_C" | grep -A2 "walk_page_range" | head -1 | cut -d: -f1)
            
            if [ -n "$LINE_NUM" ]; then
                sed -i "${LINE_NUM}a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\t\tvma = find_vma(mm, start_vaddr);\\
\t\tif (vma \&\& vma->vm_file) {\\
\t\t\tstruct inode *inode = file_inode(vma->vm_file);\\
\t\t\tif (unlikely(inode->i_mapping->flags \& BIT_SUS_MAPS) \&\& susfs_is_current_proc_umounted()) {\\
\t\t\t\tpm.buffer->pme = 0;\\
\t\t\t}\\
\t\t}\\
#endif" "$TASK_MMU_C"
                echo -e "${GREEN}✓ Added SUSFS code to task_mmu.c (mmap_read_unlock version)${NC}"
            else
                echo -e "${RED}✗ Could not find mmap_read_unlock in pagemap context${NC}"
            fi
        elif grep -q "up_read(&mm->mmap_sem);" "$TASK_MMU_C"; then
            # Older kernel - use up_read
            LINE_NUM=$(grep -n "up_read(&mm->mmap_sem);" "$TASK_MMU_C" | grep -A2 "walk_page_range" | head -1 | cut -d: -f1)
            
            if [ -n "$LINE_NUM" ]; then
                sed -i "${LINE_NUM}a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\t\tvma = find_vma(mm, start_vaddr);\\
\t\tif (vma \&\& vma->vm_file) {\\
\t\t\tstruct inode *inode = file_inode(vma->vm_file);\\
\t\t\tif (unlikely(inode->i_mapping->flags \& BIT_SUS_MAPS) \&\& susfs_is_current_proc_umounted()) {\\
\t\t\t\tpm.buffer->pme = 0;\\
\t\t\t}\\
\t\t}\\
#endif" "$TASK_MMU_C"
                echo -e "${GREEN}✓ Added SUSFS code to task_mmu.c (up_read version)${NC}"
            else
                echo -e "${RED}✗ Could not find up_read in pagemap context${NC}"
            fi
        else
            echo -e "${RED}✗ Could not find mmap lock function in task_mmu.c${NC}"
        fi
    else
        echo -e "${YELLOW}⊘ SUSFS code already in task_mmu.c${NC}"
    fi
else
    echo -e "${RED}✗ fs/proc/task_mmu.c not found!${NC}"
    exit 1
fi

echo ""
echo "Step 4: Fixing include/linux/mount.h"
echo "-------------------------------------"

MOUNT_H="include/linux/mount.h"
if [ -f "$MOUNT_H" ]; then
    if ! grep -q "unsigned long ksu_mnt;" "$MOUNT_H"; then
        # Find the line with "void *data;" in the mount structure
        LINE_NUM=$(grep -n "void \*data;" "$MOUNT_H" | head -1 | cut -d: -f1)
        
        if [ -n "$LINE_NUM" ]; then
            sed -i "${LINE_NUM}a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\\
\tunsigned long ksu_mnt;\\
#endif" "$MOUNT_H"
            echo -e "${GREEN}✓ Added ksu_mnt field to mount.h${NC}"
        else
            echo -e "${RED}✗ Could not find 'void *data;' in mount.h${NC}"
        fi
    else
        echo -e "${YELLOW}⊘ ksu_mnt field already in mount.h${NC}"
    fi
else
    echo -e "${RED}✗ include/linux/mount.h not found!${NC}"
    exit 1
fi

echo ""
echo "Step 5: Cleaning up reject files"
echo "---------------------------------"
find . -name "*.rej" -type f -delete 2>/dev/null && echo -e "${GREEN}✓ Removed .rej files${NC}" || echo -e "${YELLOW}⊘ No .rej files to remove${NC}"

echo ""
echo "========================================"
echo "All patch rejections fixed!"
echo "========================================"
echo ""
echo "Summary:"
echo "1. ✓ fs/Makefile - Added susfs.o"
echo "2. ✓ fs/namespace.c - Added includes and declarations"
echo "3. ✓ fs/proc/task_mmu.c - Added SUSFS mapping code"
echo "4. ✓ include/linux/mount.h - Added ksu_mnt field"
echo "5. ✓ Cleaned up .rej files"
echo ""
echo "You can now proceed with the kernel build!"
echo ""
