#!/bin/bash

# Define Tab character for kernel-compliant indentation
T=$(printf '\t')

echo "Starting Absolute Comprehensive SUSFS & KernelSU-Next Fix..."

# ==========================================
# 1. Fix include/linux/mount.h (ANDROID_KABI Rejects)
# ==========================================
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    echo "Patching include/linux/mount.h (KABI)..."
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
fi

# ==========================================
# 2. Fix fs/namespace.c (Headers, Externs & Core Logic)
# ==========================================
if ! grep -q "susfs_def.h" fs/namespace.c; then
    echo "Patching fs/namespace.c (Headers & Externs)..."
    # Add Headers
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    
    # Add Externs and missing BIT definition
    cat <<EOF > susfs_externs.txt
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_sdcard_android_data_decrypted;
static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);
#define CL_COPY_MNT_NS BIT(25)
#endif
EOF
    sed -i '/#include "internal.h"/r susfs_externs.txt' fs/namespace.c
    rm susfs_externs.txt
fi

# Restoring the Core clone_mnt Logic (Failed Hunks #9 & #10)
if ! grep -q "susfs_is_sdcard_android_data_decrypted" fs/namespace.c; then
    echo "Restoring clone_mnt logic in fs/namespace.c..."
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

# ==========================================
# 3. Fix fs/proc/task_mmu.c (Unused variable & Logic)
# ==========================================
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    echo "Patching fs/proc/task_mmu.c..."
    # Wrap 'vma' to stop the unused-variable error
    sed -i 's/^[[:space:]]*struct vm_area_struct \*vma;/#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif/' fs/proc/task_mmu.c

    # Inject the actual logic usage
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
    # Inject after the walk_page_range call
    sed -i '/walk_page_range(start_vaddr, end, &pagemap_walk);/r susfs_vma_usage.txt' fs/proc/task_mmu.c
    rm susfs_vma_usage.txt
fi

# ==========================================
# 4. Fix drivers/kernelsu/supercalls.c (KSU-Next Bridge)
# ==========================================
if [ -f "drivers/kernelsu/supercalls.c" ]; then
    echo "Patching drivers/kernelsu/supercalls.c..."
    
    # 1. Define the missing constant (Standard SUSFS ID is 0x511)
    if ! grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" drivers/kernelsu/supercalls.c; then
        sed -i '/#include "ksu.h"/a #define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS 0x511' drivers/kernelsu/supercalls.c
    fi

    # 2. Bridge function name mismatches
    sed -i 's/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g' drivers/kernelsu/supercalls.c
    sed -i 's/susfs_add_try_umount/add_try_umount/g' drivers/kernelsu/supercalls.c
fi

echo "✅ All known rejects and compiler errors have been addressed."
