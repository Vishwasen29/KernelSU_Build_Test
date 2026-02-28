#!/bin/bash

# Define Tab character for kernel-compliant indentation
T=$(printf '\t')

echo "Starting Comprehensive SUSFS & KernelSU-Next Fix..."

# --- 1. Fix include/linux/mount.h (Resolve ANDROID_KABI Rejects) ---
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    echo "Patching include/linux/mount.h..."
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
fi

# --- 2. Fix fs/namespace.c (Headers and Externs) ---
if ! grep -q "susfs_def.h" fs/namespace.c; then
    echo "Patching fs/namespace.c..."
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    sed -i '/#include "internal.h"/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

# --- 3. Fix fs/proc/task_mmu.c (Resolve 'unused vma' and Missing Logic) ---
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    echo "Patching fs/proc/task_mmu.c..."
    # Wrap the declaration that was already added by the patch to prevent unused warning
    sed -i 's/struct vm_area_struct \*vma;/#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif/' fs/proc/task_mmu.c

    # Use a heredoc to inject the missing SUSFS usage logic
    cat <<EOF > susfs_task_mmu.txt
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
    sed -i '/up_read(&mm->mmap_sem);/r susfs_task_mmu.txt' fs/proc/task_mmu.c
    rm susfs_task_mmu.txt
fi

# --- 4. Fix drivers/kernelsu/supercalls.c (KSU-Next Compatibility Bridge) ---
if [ -f "drivers/kernelsu/supercalls.c" ]; then
    echo "Patching drivers/kernelsu/supercalls.c..."
    
    # Define the missing command ID required by KernelSU-Next
    if ! grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" drivers/kernelsu/supercalls.c; then
        sed -i '/#include "ksu.h"/a #define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS 0x511' drivers/kernelsu/supercalls.c
    fi

    # Bridge renamed functions from SUSFS patch to KSU-Next expectations
    # Fix: for_all_procs -> for_non_su_procs
    sed -i 's/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g' drivers/kernelsu/supercalls.c
    
    # Fix: susfs_add_try_umount -> add_try_umount (KSU-Next local implementation)
    sed -i 's/susfs_add_try_umount/add_try_umount/g' drivers/kernelsu/supercalls.c
fi

echo "All SUSFS rejects and compatibility issues have been fixed."
