#!/bin/bash
set -e

KERNEL_DIR="$(pwd)"

echo "[*] Starting SUSFS auto-fix..."

########################################
# 1. Fix fs/namespace.c
########################################

NS_FILE="fs/namespace.c"

if ! grep -q "susfs_def.h" "$NS_FILE"; then
    echo "[*] Patching namespace.c includes..."

    sed -i '/#include <linux\/sched\/task.h>/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\
#include <linux/susfs_def.h>\n\
#endif\n' "$NS_FILE"
fi

if ! grep -q "susfs_is_current_ksu_domain" "$NS_FILE"; then
    echo "[*] Injecting SUSFS clone_mnt logic..."

    sed -i '/static struct mount \*clone_mnt/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\
extern bool susfs_is_current_ksu_domain(void);\n\
extern bool susfs_is_sdcard_android_data_decrypted;\n\
#endif\n' "$NS_FILE"

    sed -i '/mnt = alloc_vfsmnt(old->mnt_devname);/i \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\
    if (susfs_is_current_ksu_domain()) {\n\
        mnt = alloc_vfsmnt(old->mnt_devname);\n\
        if (mnt)\n\
            mnt->mnt_id = DEFAULT_KSU_MNT_ID;\n\
        goto bypass_orig_flow;\n\
    }\n\
#endif\n' "$NS_FILE"

    sed -i '/mnt = alloc_vfsmnt(old->mnt_devname);/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\
bypass_orig_flow:\n\
#endif\n' "$NS_FILE"
fi

########################################
# 2. Fix fs/proc/task_mmu.c
########################################

MMU_FILE="fs/proc/task_mmu.c"

if ! grep -q "BIT_SUS_MAPS" "$MMU_FILE"; then
    echo "[*] Patching task_mmu.c..."

    sed -i '/up_read(&mm->mmap_sem);/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\
        vma = find_vma(mm, start_vaddr);\n\
        if (vma && vma->vm_file) {\n\
            struct inode *inode = file_inode(vma->vm_file);\n\
            if (inode->i_mapping->flags & BIT_SUS_MAPS)\n\
                pm.buffer->pme = 0;\n\
        }\n\
#endif\n' "$MMU_FILE"
fi

########################################
# 3. Fix include/linux/mount.h
########################################

MOUNT_FILE="include/linux/mount.h"

if ! grep -q "susfs_mnt_id_backup" "$MOUNT_FILE"; then
    echo "[*] Patching mount.h..."

    sed -i 's/ANDROID_KABI_RESERVE(4);/#ifdef CONFIG_KSU_SUSFS\n\
    ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n\
#else\n\
    ANDROID_KABI_RESERVE(4);\n\
#endif/' "$MOUNT_FILE"
fi

echo "[✓] SUSFS auto-fix completed!"
echo "Now run:"
echo "make clean && make -j$(nproc)"
