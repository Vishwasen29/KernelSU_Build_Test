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
    sed -i '/#include "internal.h"/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
    echo "Fixed: fs/namespace.c (headers)"
fi

# 3. Fix fs/proc/task_mmu.c (The unused variable / missing logic fix)
# This part ensures that if CONFIG_KSU_SUSFS_SUS_MAP is NOT enabled, 
# we don't declare vma, or we ensure the logic is injected so it is used.
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    # First: Wrap the existing vma declaration in an ifdef to prevent "unused" error
    # We look for the exact line: struct vm_area_struct *vma; inside pagemap_read
    sed -i 's/struct vm_area_struct \*vma;/#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif/' fs/proc/task_mmu.c

    # Second: Inject the actual logic that uses vma
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
    # Inject after up_read
    sed -i '/up_read(&mm->mmap_sem);/r susfs_temp_block.txt' fs/proc/task_mmu.c
    rm susfs_temp_block.txt
    echo "Fixed: fs/proc/task_mmu.c (Unused variable & logic injection)"
fi

echo "All manual fixes applied successfully."
