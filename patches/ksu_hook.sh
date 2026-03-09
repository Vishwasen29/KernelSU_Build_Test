#!/bin/bash

patch_files=(
    drivers/input/input.c
    fs/exec.c
    fs/open.c
    fs/read_write.c
    fs/stat.c
    kernel/reboot.c
)

for i in "${patch_files[@]}"; do

    if grep -q "ksu" "$i"; then
        echo "Warning: $i contains KernelSU"
        continue
    fi

    case $i in

    # drivers/input/ changes
    ## input.c
    drivers/input/input.c)
        sed -i '/static void input_handle_event/i\#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif' drivers/input/input.c
        sed -i '/int disposition = input_get_disposition(dev, type, code, &value);/a\ \n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif' drivers/input/input.c
        ;;

    # fs/ changes
    ## exec.c
    # FIX: The full call `return __do_execve_file(fd, filename, argv, envp, flags, NULL);`
    # may be split across two lines in this kernel. Match only the start of the return
    # statement so it works regardless of formatting.
    fs/exec.c)
        sed -i '/static int do_execveat_common/i\#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\tvoid *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n\t\t\t\t\t\t void *argv, void *envp, int *flags);\n#endif' fs/exec.c
        sed -i '/return __do_execve_file/i\ \n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_execveat_hook))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n\telse\n\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n#endif' fs/exec.c
        ;;

    ## open.c
    # FIX: `do_faccessat` does not exist as a standalone function in Linux 4.19 base
    # kernels (it was factored out only in 5.8+). For this OOS 4.19 kernel we fall back
    # to patching `SYSCALL_DEFINE3(faccessat, ...)` directly, which is the correct
    # approach per the official KernelSU docs for kernels earlier than 4.17/4.19.
    fs/open.c)
        if grep -q "long do_faccessat" fs/open.c; then
            # Kernel has do_faccessat factored out (some CAF trees backport this)
            sed -i '/long do_faccessat(int dfd, const char __user \*filename, int mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t\tint *flags);\n#endif' fs/open.c
            sed -i '/long do_faccessat/,/if (mode & ~S_IRWXO)/{/if (mode & ~S_IRWXO)/i\ \n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif
            }' fs/open.c
        else
            # Kernel uses SYSCALL_DEFINE3(faccessat, ...) directly (standard 4.19)
            sed -i '/SYSCALL_DEFINE3(faccessat,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t\tint *flags);\n#endif' fs/open.c
            sed -i '/SYSCALL_DEFINE3(faccessat,/,/if (mode & ~S_IRWXO)/{/if (mode & ~S_IRWXO)/i\ \n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif
            }' fs/open.c
        fi
        ;;

    ## read_write.c
    fs/read_write.c)
        sed -i '/ssize_t vfs_read(struct file/i\#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n\t\t\t\t\t size_t *count_ptr, loff_t **pos);\n#endif' fs/read_write.c
        sed -i '/ssize_t vfs_read(struct file/,/ssize_t ret;/{/ssize_t ret;/a\
        #ifdef CONFIG_KSU\
        if (unlikely(ksu_vfs_read_hook))\
            ksu_handle_vfs_read(&file, &buf, &count, &pos);\
        #endif
        }' fs/read_write.c
        ;;

    ## stat.c
    # FIX: `vfs_statx` may initialise lookup_flags differently across kernel versions.
    # Try `vfs_statx` first (4.11+); if not found fall back to `vfs_fstatat` which uses
    # `unsigned int lookup_flags = 0;` and is the approach in the official KernelSU docs
    # for pre-4.17 kernels.
    fs/stat.c)
        if grep -q "int vfs_statx" fs/stat.c; then
            sed -i '/int vfs_statx(int dfd, const char __user \*filename, int flags,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
            sed -i '/unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a\ \n#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flags);\n#endif' fs/stat.c
        else
            # Fallback: patch vfs_fstatat (older kernel layout)
            sed -i '/int vfs_fstatat(int dfd, const char __user \*filename,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
            sed -i '/unsigned int lookup_flags = 0;/a\ \n#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif' fs/stat.c
        fi
        ;;

    # kernel/ changes
    ## reboot.c
    # FIX: `/int ret = 0;/` is too broad and may match in functions other than the
    # reboot syscall. Scope it inside the SYSCALL_DEFINE4(reboot, ...) block by using
    # a range match so only the first `int ret = 0;` after the syscall definition is
    # patched.
    kernel/reboot.c)
        sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif' kernel/reboot.c
        sed -i '/SYSCALL_DEFINE4(reboot,/,/int ret = 0;/{/int ret = 0;/a\ \n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif
        }' kernel/reboot.c
        ;;

    esac

done
