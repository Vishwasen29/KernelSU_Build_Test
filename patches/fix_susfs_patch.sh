#!/bin/bash

# Define Tab character for proper kernel indentation
T=$(printf '\t')

echo "Starting manual fix for SUSFS patch rejects..."

# --- 1. Fix include/linux/mount.h ---
# Replaces the failed Hunk #1 (KABI mismatch)
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
    echo "Fixed: include/linux/mount.h"
fi

# --- 2. Fix fs/namespace.c (Includes & Declarations) ---
if ! grep -q "susfs_def.h" fs/namespace.c; then
    # Add includes after sched/task.h
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    
    # Add externs and atomic vars after internal.h
    sed -i '/#include "internal.h"/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern bool susfs_is_sdcard_android_data_decrypted;\
static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\
#define CL_COPY_MNT_NS BIT(25)\
#endif' fs/namespace.c
    echo "Fixed: fs/namespace.c (headers)"
fi

# --- 3. Fix fs/proc/task_mmu.c ---
# Injects the Pagemap SUS_MAP logic after up_read
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    sed -i '/up_read(&mm->mmap_sem);/a \
'"$T"'#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
'"$T"'vma = find_vma(mm, start_vaddr);\
'"$T"'if (vma && vma->vm_file) {\
'"$T"'"$T"'struct inode *inode = file_inode(vma->vm_file);\
'"$T"'"$T"'if (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\
'"$T"'"$T"'"$T"'pm.buffer->pme = 0;\
'"$T"'"$T"'}\
'"$T"'}\
'"$T"'#endif' fs/proc/task_mmu.c
    echo "Fixed: fs/proc/task_mmu.c"
fi

echo "All manual fixes applied."
