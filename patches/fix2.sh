#!/bin/bash
set -e

KERNEL_DIR="${1:-$GITHUB_WORKSPACE/kernel_workspace/android-kernel}"

echo "[+] Fixing SUSFS patch rejections in $KERNEL_DIR"

cd "$KERNEL_DIR"

# Fix 1: fs/Makefile - Add susfs.o compilation
echo "[+] Fixing fs/Makefile..."
if ! grep -q "CONFIG_KSU_SUSFS" fs/Makefile; then
    # Find the line with "stack.o fs_struct.o statfs.o fs_pin.o nsfs.o" and add after it
    sed -i '/stack.o fs_struct.o statfs.o fs_pin.o nsfs.o/a\\n\obj-$(CONFIG_KSU_SUSFS) += susfs.o\n' fs/Makefile
    echo "  ✓ Added susfs.o to fs/Makefile"
else
    echo "  - Already patched"
fi

# Fix 2: include/linux/mount.h - Add susfs_mnt_id_backup field
echo "[+] Fixing include/linux/mount.h..."
if ! grep -q "susfs_mnt_id_backup" include/linux/mount.h; then
    # Find ANDROID_KABI_RESERVE(4) and replace with conditional
    sed -i '/ANDROID_KABI_RESERVE(3);/a\#ifdef CONFIG_KSU_SUSFS\n\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n#else' include/linux/mount.h
    sed -i 's/^\([[:space:]]*\)ANDROID_KABI_RESERVE(4);/\1ANDROID_KABI_RESERVE(4);\n#endif/' include/linux/mount.h
    echo "  ✓ Added susfs_mnt_id_backup to mount.h"
else
    echo "  - Already patched"
fi

# Fix 3: fs/namespace.c - Add includes and declarations
echo "[+] Fixing fs/namespace.c..."
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MOUNT" fs/namespace.c; then
    # Add includes after linux/sched/task.h
    sed -i '/#include <linux\/sched\/task.h>/a\#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif' fs/namespace.c
    
    # Add extern declarations and defines after internal.h include
    sed -i '/#include "internal.h"/a\\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern bool susfs_is_sdcard_android_data_decrypted;\n\nstatic atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n\n#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n#endif' fs/namespace.c
    echo "  ✓ Added SUSFS includes and declarations to namespace.c"
else
    echo "  - Already patched"
fi

# Fix 4: fs/proc/task_mmu.c - Add SUS_MAP check
echo "[+] Fixing fs/proc/task_mmu.c..."
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" fs/proc/task_mmu.c; then
    # Find the pattern and add the code block
    # This is tricky - we need to find "up_read(&mm->mmap_sem);" and add code after it
    awk '
    /up_read\(&mm->mmap_sem\);/ {
        print
        print "#ifdef CONFIG_KSU_SUSFS_SUS_MAP"
        print "\t\tvma = find_vma(mm, start_vaddr);"
        print "\t\tif (vma && vma->vm_file) {"
        print "\t\t\tstruct inode *inode = file_inode(vma->vm_file);"
        print "\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {"
        print "\t\t\t\tpm.buffer->pme = 0;"
        print "\t\t\t}"
        print "\t\t}"
        print "#endif"
        next
    }
    { print }
    ' fs/proc/task_mmu.c > fs/proc/task_mmu.c.tmp
    mv fs/proc/task_mmu.c.tmp fs/proc/task_mmu.c
    echo "  ✓ Added SUS_MAP check to task_mmu.c"
else
    echo "  - Already patched"
fi

echo "[+] All SUSFS patches applied successfully!"
