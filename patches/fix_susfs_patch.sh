#!/bin/bash

# Define Tab character
T=$(printf '\t')

echo "Starting robust manual fix for SUSFS and KernelSU-Next rejects..."

# 1. Fix include/linux/mount.h
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
fi

# 2. Fix fs/namespace.c
if ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    sed -i '/#include "internal.h"/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

# 3. Fix fs/proc/task_mmu.c (Unused variable & Logic)
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    sed -i 's/struct vm_area_struct \*vma;/#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif/' fs/proc/task_mmu.c
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
    sed -i '/up_read(&mm->mmap_sem);/r susfs_temp_block.txt' fs/proc/task_mmu.c
    rm susfs_temp_block.txt
fi

# 4. NEW: Fix drivers/kernelsu/supercalls.c
# Fix the missing constant and function name mismatches
if [ -f "drivers/kernelsu/supercalls.c" ]; then
    echo "Patching KernelSU-Next supercalls.c for SUSFS compatibility..."
    
    # Define the missing CMD constant if it's missing (mapping it to the 0x511 equivalent)
    if ! grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" drivers/kernelsu/supercalls.c; then
        sed -i '/#include "ksu.h"/a #define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS 0x511' drivers/kernelsu/supercalls.c
    fi

    # Fix: susfs_set_hide_sus_mnts_for_all_procs -> susfs_set_hide_sus_mnts_for_non_su_procs
    sed -i 's/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g' drivers/kernelsu/supercalls.c
    
    # Fix: susfs_add_try_umount -> add_try_umount (local function call)
    sed -i 's/susfs_add_try_umount/add_try_umount/g' drivers/kernelsu/supercalls.c
    
    echo "Fixed KernelSU-Next supercalls.c"
fi

echo "All fixes applied. Ready for build."
