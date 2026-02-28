#!/bin/bash

# Define Tab character for kernel-compliant indentation
T=$(printf '\t')

echo "Starting Absolute Comprehensive SUSFS & KernelSU-Next Fix..."

# ==========================================
# 1. Fix include/linux/mount.h (KABI Rejects)
# ==========================================
# This fixes the structure mismatch in the kernel's binary interface
if [ -f "include/linux/mount.h" ]; then
    if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
        echo "Patching include/linux/mount.h..."
        sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
    fi
fi

# ==========================================
# 2. Fix fs/namespace.c (Core Security Logic)
# ==========================================
# This restores the logic that actually hides the mounts
if [ -f "fs/namespace.c" ]; then
    echo "Patching fs/namespace.c..."
    # Add Headers and Externs if missing
    if ! grep -q "susfs_def.h" fs/namespace.c; then
        sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
        sed -i '/#include "internal.h"/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
    fi

    # Inject the clone_mnt bypass logic
    if ! grep -q "susfs_is_current_ksu_domain" fs/namespace.c; then
        cat <<EOF > susfs_clone_mnt.txt
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
${T}if (susfs_is_sdcard_android_data_decrypted) {
${T}${T}goto skip_checking_for_ksu_proc;
${T}}
${T}if (susfs_is_current_ksu_domain()) {
${T}${T}if (flag & CL_COPY_MNT_NS) {
${T}${T}${T}mnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);
${T}${T}${T}goto bypass_orig_flow;
${T}${T}}
${T}${T}mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);
${T}${T}goto bypass_orig_flow;
${T}}
skip_checking_for_ksu_proc:
${T}if (old->mnt_id == DEFAULT_KSU_MNT_ID) {
${T}${T}mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);
${T}${T}goto bypass_orig_flow;
${T}}
#endif
${T}mnt = alloc_vfsmnt(old->mnt_devname);
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif
EOF
        sed -i '/mnt = alloc_vfsmnt(old->mnt_devname);/ {
            r susfs_clone_mnt.txt
            d
        }' fs/namespace.c
        rm susfs_clone_mnt.txt
    fi
fi

# ==========================================
# 3. Fix fs/proc/task_mmu.c (Unused Variable vma)
# ==========================================
# This solves the 'unused variable vma' error and hides /proc/maps
if [ -f "fs/proc/task_mmu.c" ]; then
    echo "Patching fs/proc/task_mmu.c..."
    # Wrap the declaration to satisfy the compiler
    sed -i 's/^[[:space:]]*struct vm_area_struct \*vma;/#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif/g' fs/proc/task_mmu.c
    
    # Inject the usage logic after walk_page_range
    if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
        cat <<EOF > susfs_vma_usage.txt
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
        sed -i '/walk_page_range(start_vaddr, end, &pagemap_walk);/r susfs_vma_usage.txt' fs/proc/task_mmu.c
        rm susfs_vma_usage.txt
    fi
fi

# ==========================================
# 4. Fix drivers/kernelsu/supercalls.c (KSU-Next Bridge)
# ==========================================
# This fixes the 'undeclared identifier' CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS
if [ -f "drivers/kernelsu/supercalls.c" ]; then
    echo "Patching drivers/kernelsu/supercalls.c..."
    # Define the missing command ID
    if ! grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" drivers/kernelsu/supercalls.c; then
        sed -i '1i #define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS 0x511' drivers/kernelsu/supercalls.c
    fi
    # Map function names from KSU-Next to your SUSFS version
    sed -i 's/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g' drivers/kernelsu/supercalls.c
    sed -i 's/susfs_add_try_umount/add_try_umount/g' drivers/kernelsu/supercalls.c
fi

echo "✅ All fixes applied successfully. You can now build the kernel."
