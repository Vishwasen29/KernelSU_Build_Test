#!/bin/bash

# Define Tab character for kernel-compliant indentation
T=$(printf '\t')

echo "Applying Absolute Comprehensive SUSFS & KernelSU-Next Fixes..."

# --- 1. Fix fs/proc/task_mmu.c (Resolve 'unused vma' error) ---
# This error occurs because the variable is declared but the code using it failed to patch.
echo "Patching fs/proc/task_mmu.c..."
# Wrap the declaration in an IFDEF to satisfy the compiler
sed -i 's/struct vm_area_struct \*vma;/#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif/g' fs/proc/task_mmu.c

# Inject the missing logic from Hunk #8 after walk_page_range
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    cat <<EOF > susfs_vma_logic.txt
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
    # Matches both up_read and mmap_read_unlock styles
    sed -i '/walk_page_range.*pagemap_walk/!b;n;r susfs_vma_logic.txt' fs/proc/task_mmu.c
    rm susfs_vma_logic.txt
fi

# --- 2. Fix drivers/kernelsu/supercalls.c (KSU-Next Compatibility) ---
# Resolves: error: use of undeclared identifier 'CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS'
if [ -f "drivers/kernelsu/supercalls.c" ]; then
    echo "Patching drivers/kernelsu/supercalls.c..."
    # Define the missing constant at the top of the file
    if ! grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" drivers/kernelsu/supercalls.c; then
        sed -i '1i #define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS 0x511' drivers/kernelsu/supercalls.c
    fi
    # Map KSU-Next function names to SUSFS function names
    sed -i 's/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g' drivers/kernelsu/supercalls.c
    sed -i 's/susfs_add_try_umount/add_try_umount/g' drivers/kernelsu/supercalls.c
fi

# --- 3. Fix fs/namespace.c (Resolve 4 failed hunks) ---
echo "Patching fs/namespace.c..."
# [span_4](start_span)Add missing headers and externs[span_4](end_span)
if ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    sed -i '/#include "internal.h"/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

# [span_5](start_span)Manually inject the clone_mnt logic from Hunks #9 and #10[span_5](end_span)
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

# --- 4. Fix include/linux/mount.h (KABI Rejects) ---
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    echo "Patching include/linux/mount.h..."
    sed -i '/ANDROID_KABI_RESERVE(4);/c\#ifdef CONFIG_KSU_SUSFS\n'"$T"'ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else\n'"$T"'ANDROID_KABI_RESERVE(4);\n#endif' include/linux/mount.h
fi

echo "All fixes applied successfully. Please restart your build."
