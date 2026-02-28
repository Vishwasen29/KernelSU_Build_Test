#!/bin/bash

# Define the kernel root directory
KERNEL_ROOT="kernel_workspace/android-kernel"
cd "$KERNEL_ROOT" || exit 1

echo "Starting manual fix for SUSFS patch rejects..."

# 1. Fix include/linux/mount.h (ANDROID_KABI_RESERVE/USE mismatch)
# The patch failed because it couldn't find the exact KABI reserve lines to replace.
if grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    echo "mount.h already patched."
else
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n\tANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
    echo "Fixed include/linux/mount.h"
fi

# 2. Fix fs/namespace.c (Includes and Declarations)
# Add SUSFS headers and external declarations near other includes.
if ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    sed -i '/#include "internal.h"/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern bool susfs_is_sdcard_android_data_decrypted;\
static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\
#endif' fs/namespace.c
    echo "Fixed fs/namespace.c includes/externs"
fi

# 3. Fix fs/proc/task_mmu.c (Pagemap SUS_MAP logic)
# Inject the SUSFS check inside pagemap_read() before start_vaddr update.
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    # Locate the walk_page_range line which is a common anchor in this file
    sed -i '/up_read(&mm->mmap_sem);/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
		vma = find_vma(mm, start_vaddr);\
		if (vma && vma->vm_file) {\
			struct inode *inode = file_inode(vma->vm_file);\
			if (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\
				pm.buffer->pme = 0;\
			}\
		}\
#endif' fs/proc/task_mmu.c
    echo "Fixed fs/proc/task_mmu.c"
fi

echo "Manual fixes applied successfully."
