#!/bin/bash

# SUSFS Patch Fix Script - CORRECTED MAKEFILE VERSION
# This script manually applies rejected hunks from the SUSFS patch
# For Lineage 23.2 OnePlus 9R (Kernel 4.19.325)

set -e

KERNEL_DIR="${1:-.}"
cd "$KERNEL_DIR"

echo "========================================"
echo "SUSFS Patch Fix Script - Corrected"
echo "Kernel Version: 4.19.325"
echo "Device: OnePlus 9R (lemonades)"
echo "========================================"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Step 0: Cleaning up old files..."
find . -name "*.orig" -type f -delete 2>/dev/null || true

echo ""
echo "Step 1: Fixing fs/Makefile"
echo "----------------------------"

if [ ! -f "fs/Makefile" ]; then
    echo -e "${RED}✗ fs/Makefile not found!${NC}"
    exit 1
fi

# Check if susfs.o is already there
if grep -q "CONFIG_KSU_SUSFS" fs/Makefile; then
    echo -e "${YELLOW}⊘ susfs.o already in fs/Makefile${NC}"
else
    # Find the correct location - after the obj-y definition block
    # We want to insert after the line with nsfs.o and before the ifeq block
    
    # Create a temporary file with the fix
    awk '
    /stack.o fs_struct.o statfs.o fs_pin.o nsfs.o/ {
        print
        # Check if next line is fs_context.o
        getline
        print
        if ($0 ~ /fs_context.o fs_parser.o/) {
            # Print blank line and our config
            print ""
            print "obj-$(CONFIG_KSU_SUSFS) += susfs.o"
        } else {
            # Print our config after the current line
            print ""
            print "obj-$(CONFIG_KSU_SUSFS) += susfs.o"
        }
        next
    }
    { print }
    ' fs/Makefile > fs/Makefile.tmp
    
    # Check if the modification worked
    if grep -q "CONFIG_KSU_SUSFS" fs/Makefile.tmp; then
        mv fs/Makefile.tmp fs/Makefile
        echo -e "${GREEN}✓ Added susfs.o to fs/Makefile${NC}"
    else
        # Fallback: simple insertion after nsfs.o line
        rm -f fs/Makefile.tmp
        sed -i '/stack.o fs_struct.o statfs.o fs_pin.o nsfs.o.*\\$/a\\nobj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile
        echo -e "${GREEN}✓ Added susfs.o to fs/Makefile (fallback method)${NC}"
    fi
fi

# Verify Makefile syntax
echo -n "Verifying Makefile syntax... "
if make -C fs -n -f Makefile >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Makefile has syntax errors!${NC}"
    echo "Restoring original Makefile..."
    git checkout fs/Makefile 2>/dev/null || true
    exit 1
fi

echo ""
echo "Step 2: Fixing fs/namespace.c - INCLUDES"
echo "------------------------------------------"

if [ ! -f "fs/namespace.c" ]; then
    echo -e "${RED}✗ fs/namespace.c not found!${NC}"
    exit 1
fi

# Check if the include is already there
if grep -q 'include <linux/susfs_def.h>' fs/namespace.c; then
    echo -e "${YELLOW}⊘ SUSFS includes already in namespace.c${NC}"
else
    # Try multiple insertion points
    INSERTED=0
    
    # Try after <linux/fs_context.h>
    if grep -q '#include <linux/fs_context.h>' fs/namespace.c && [ $INSERTED -eq 0 ]; then
        sed -i '/#include <linux\/fs_context\.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif' fs/namespace.c
        echo -e "${GREEN}✓ Added SUSFS includes after fs_context.h${NC}"
        INSERTED=1
    fi
    
    # Try after <linux/sched/task.h>
    if grep -q '#include <linux/sched/task.h>' fs/namespace.c && [ $INSERTED -eq 0 ]; then
        sed -i '/#include <linux\/sched\/task\.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif' fs/namespace.c
        echo -e "${GREEN}✓ Added SUSFS includes after sched/task.h${NC}"
        INSERTED=1
    fi
    
    # Try after <linux/task_work.h>
    if grep -q '#include <linux/task_work.h>' fs/namespace.c && [ $INSERTED -eq 0 ]; then
        sed -i '/#include <linux\/task_work\.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif' fs/namespace.c
        echo -e "${GREEN}✓ Added SUSFS includes after task_work.h${NC}"
        INSERTED=1
    fi
    
    if [ $INSERTED -eq 0 ]; then
        echo -e "${RED}✗ Could not find suitable insertion point for includes${NC}"
        exit 1
    fi
fi

echo ""
echo "Step 3: Fixing fs/namespace.c - DECLARATIONS"
echo "---------------------------------------------"

# Check if declarations are already there
if grep -q "extern bool susfs_is_current_ksu_domain" fs/namespace.c; then
    echo -e "${YELLOW}⊘ SUSFS declarations already in namespace.c${NC}"
else
    # Insert after #include "internal.h"
    if grep -q '#include "internal.h"' fs/namespace.c; then
        sed -i '/#include "internal\.h"/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern bool susfs_is_sdcard_android_data_decrypted;\
\
static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\
\
#define CL_COPY_MNT_NS BIT(25)\
#endif' fs/namespace.c
        echo -e "${GREEN}✓ Added SUSFS declarations${NC}"
    else
        echo -e "${RED}✗ Could not find #include \"internal.h\"${NC}"
        exit 1
    fi
fi

echo ""
echo "Step 4: Fixing fs/proc/task_mmu.c"
echo "----------------------------------"

if [ ! -f "fs/proc/task_mmu.c" ]; then
    echo -e "${RED}✗ fs/proc/task_mmu.c not found!${NC}"
    exit 1
fi

# Check if SUSFS code is already there
if grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    echo -e "${YELLOW}⊘ SUSFS code already in task_mmu.c${NC}"
else
    # Find and insert after mmap_read_unlock or up_read
    if grep -q "mmap_read_unlock(mm);" fs/proc/task_mmu.c; then
        # Modern kernel
        sed -i '/while.*count.*start_vaddr.*end_vaddr/,/^[[:space:]]*}/ {
            /mmap_read_unlock(mm);/ {
                a\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
\t\tvma = find_vma(mm, start_vaddr);\
\t\tif (vma && vma->vm_file) {\
\t\t\tstruct inode *inode = file_inode(vma->vm_file);\
\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\
\t\t\t\tpm.buffer->pme = 0;\
\t\t\t}\
\t\t}\
#endif
            }
        }' fs/proc/task_mmu.c
        echo -e "${GREEN}✓ Added SUSFS code to task_mmu.c${NC}"
    elif grep -q "up_read(&mm->mmap_sem);" fs/proc/task_mmu.c; then
        # Older kernel
        sed -i '/while.*count.*start_vaddr.*end_vaddr/,/^[[:space:]]*}/ {
            /up_read(&mm->mmap_sem);/ {
                a\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
\t\tvma = find_vma(mm, start_vaddr);\
\t\tif (vma && vma->vm_file) {\
\t\t\tstruct inode *inode = file_inode(vma->vm_file);\
\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\
\t\t\t\tpm.buffer->pme = 0;\
\t\t\t}\
\t\t}\
#endif
            }
        }' fs/proc/task_mmu.c
        echo -e "${GREEN}✓ Added SUSFS code to task_mmu.c${NC}"
    else
        echo -e "${RED}✗ Could not find mmap lock function${NC}"
        exit 1
    fi
fi

echo ""
echo "Step 5: Fixing include/linux/mount.h"
echo "-------------------------------------"

if [ ! -f "include/linux/mount.h" ]; then
    echo -e "${YELLOW}⚠️  include/linux/mount.h not found${NC}"
else
    # Check if ksu_mnt is already there
    if grep -q "unsigned long ksu_mnt;" include/linux/mount.h; then
        echo -e "${YELLOW}⊘ ksu_mnt already in mount.h${NC}"
    else
        # Find void *data; and add after it
        if grep -q "void \*data;" include/linux/mount.h; then
            sed -i '/void \*data;/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
\tunsigned long ksu_mnt;\
#endif' include/linux/mount.h
            echo -e "${GREEN}✓ Added ksu_mnt to mount.h${NC}"
        else
            echo -e "${RED}✗ Could not find 'void *data;' in mount.h${NC}"
            exit 1
        fi
    fi
fi

echo ""
echo "Step 6: Cleanup"
echo "---------------"
find . -name "*.rej" -type f -delete 2>/dev/null && echo -e "${GREEN}✓ Removed .rej files${NC}" || echo -e "${YELLOW}⊘ No .rej files found${NC}"

echo ""
echo "Step 7: Verification"
echo "--------------------"

VERIFY_FAILED=0

echo -n "Checking fs/susfs.c... "
[ -f "fs/susfs.c" ] && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; VERIFY_FAILED=1; }

echo -n "Checking susfs.o in Makefile... "
grep -q "CONFIG_KSU_SUSFS" fs/Makefile && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; VERIFY_FAILED=1; }

echo -n "Checking SUSFS includes in namespace.c... "
grep -q 'include <linux/susfs_def.h>' fs/namespace.c && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; VERIFY_FAILED=1; }

echo -n "Checking SUSFS declarations in namespace.c... "
grep -q "extern bool susfs_is_current_ksu_domain" fs/namespace.c && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; VERIFY_FAILED=1; }

echo -n "Checking SUSFS code in task_mmu.c... "
grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; VERIFY_FAILED=1; }

echo -n "Checking no .rej files... "
[ $(find . -name "*.rej" -type f 2>/dev/null | wc -l) -eq 0 ] && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; VERIFY_FAILED=1; }

echo ""
echo "========================================"
if [ $VERIFY_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ ALL FIXES APPLIED SUCCESSFULLY!${NC}"
    echo "========================================"
    echo ""
    echo "SUSFS is now properly integrated."
    echo "You can proceed with the kernel build."
else
    echo -e "${RED}❌ SOME FIXES FAILED!${NC}"
    echo "========================================"
    echo ""
    echo "Please check the errors above."
    exit 1
fi

echo ""
