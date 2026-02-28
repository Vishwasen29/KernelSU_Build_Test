#!/bin/bash

# Define Tab character
T=$(printf '\t')

echo "Starting robust manual fix for SUSFS patch rejects..."

# 1. Fix include/linux/mount.h
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
    echo "Fixed: include/linux/mount.h"
fi

# 2. Fix fs/namespace.c (headers and externs)
if ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    
    # Using a different delimiter | to avoid conflict with / in code
    sed -i '/#include "internal.h"/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
    echo "Fixed: fs/namespace.c (headers)"
fi

# 3. Fix fs/proc/task_mmu.c (The Pagemap injection)
# We use a temporary file to avoid shell quoting hell with sed
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    cat <<EOF > susfs_temp_block.txt
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
${T}${T}vma = find_vma(mm, start_vaddr);
${T}${T}if (vma && vma->vm_file) {
${T}${T}${T}struct inode *inode = file_inode(vma->vm_file);
${T}${T}${T}if (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {
${T}${T}${T}${T}pm.buffer->pme = 0;
${T}${T}${T}}
${T}${T}}
#endif
EOF
    # Inject the block after 'up_read(&mm->mmap_sem);'
    sed -i '/up_read(&mm->mmap_sem);/r susfs_temp_block.txt' fs/proc/task_mmu.c
    rm susfs_temp_block.txt
    echo "Fixed: fs/proc/task_mmu.c"
fi

echo "All manual fixes applied successfully."
