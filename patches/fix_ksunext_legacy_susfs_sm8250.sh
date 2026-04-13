#!/usr/bin/env bash
set -euo pipefail

KERNEL_ROOT="${1:-.}"
SUSFS_PATCH="${2:-}"

if [[ -z "$SUSFS_PATCH" ]]; then
  echo "Usage: $0 <kernel_root> <susfs_patch>"
  exit 2
fi

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
SUSFS_PATCH="$(cd "$(dirname "$SUSFS_PATCH")" && pwd)/$(basename "$SUSFS_PATCH")"

cd "$KERNEL_ROOT"

curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/legacy_susfs/kernel/setup.sh" | bash -s legacy_susfs

python3 - "$KERNEL_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def read(rel: str) -> str:
    return (root / rel).read_text()


def write(rel: str, data: str) -> None:
    (root / rel).write_text(data)


def insert_before_once(s: str, marker: str, block: str) -> str:
    if block.strip() in s:
        return s
    if marker not in s:
        raise SystemExit(f"needle not found: {marker}")
    return s.replace(marker, block + marker, 1)


def replace_once(s: str, old: str, new: str) -> str:
    if new in s:
        return s
    if old not in s:
        raise SystemExit(f"needle not found: {old}")
    return s.replace(old, new, 1)


def ensure_block_after_regex(s: str, pattern: str, block: str) -> str:
    if block.strip() in s:
        return s
    m = re.search(pattern, s, flags=re.S)
    if not m:
        raise SystemExit(f"pattern not found: {pattern}")
    i = m.end()
    return s[:i] + "\n" + block + s[i:]


exec_decl = '''#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                               void *argv, void *envp, int *flags);
extern int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user,
                                      void *argv, void *envp, int *flags);
#endif

'''
exec_do_hook = '''#ifdef CONFIG_KSU
    ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif
'''
exec_hook = '''#ifdef CONFIG_KSU
    ksu_handle_execve_sucompat(NULL, &filename, &argv, &envp, NULL);
#endif
    return do_execve(getname(filename), argv, envp);'''
compat_exec_hook = '''#ifdef CONFIG_KSU
    ksu_handle_execve_sucompat(NULL, &filename, &argv, &envp, NULL);
#endif
    return compat_do_execve(getname(filename), argv, envp);'''

s = read('fs/exec.c')
s = insert_before_once(s, 'SYSCALL_DEFINE3(execve,', exec_decl)
s = ensure_block_after_regex(s, r'static\s+int\s+do_execveat_common\s*\([^\)]*\)\s*\{', exec_do_hook)
s = replace_once(s, 'return do_execve(getname(filename), argv, envp);', exec_hook)
s = replace_once(s, 'return compat_do_execve(getname(filename), argv, envp);', compat_exec_hook)
write('fs/exec.c', s)

open_decl = '''#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
                                int *flags);
#endif

'''
open_hook = '''#ifdef CONFIG_KSU
    ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
    return do_faccessat(dfd, filename, mode);'''
s = read('fs/open.c')
s = insert_before_once(s, 'SYSCALL_DEFINE3(faccessat,', open_decl)
s = replace_once(s, 'return do_faccessat(dfd, filename, mode);', open_hook)
write('fs/open.c', s)

rw_decl = '''#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
                               size_t *count_ptr);
#endif

'''
rw_hook = '''#ifdef CONFIG_KSU
    if (unlikely(ksu_vfs_read_hook))
        ksu_handle_sys_read(fd, (char __user **)&buf, &count);
#endif
    return ksys_read(fd, buf, count);'''
s = read('fs/read_write.c')
s = insert_before_once(s, 'SYSCALL_DEFINE3(read,', rw_decl)
s = replace_once(s, 'return ksys_read(fd, buf, count);', rw_hook)
write('fs/read_write.c', s)

stat_decl = '''#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif

'''
stat_hook = '''#ifdef CONFIG_KSU
    ksu_handle_stat(&dfd, &filename, &flag);
#endif
    error = vfs_fstatat(dfd, filename, &stat, flag);'''
s = read('fs/stat.c')
s = insert_before_once(s, '#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)', stat_decl)
s = replace_once(s, 'error = vfs_fstatat(dfd, filename, &stat, flag);', stat_hook)
s = replace_once(s, 'error = vfs_fstatat(dfd, filename, &stat, flag);', stat_hook)
write('fs/stat.c', s)

reboot_decl = '''#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
reboot_hook = '''int ret = 0;
#ifdef CONFIG_KSU
    ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
s = read('kernel/reboot.c')
s = insert_before_once(s, 'SYSCALL_DEFINE4(reboot,', reboot_decl)
s = replace_once(s, 'int ret = 0;', reboot_hook)
write('kernel/reboot.c', s)

# path_umount compatibility for old 4.19 trees
internal = read('fs/internal.h')
proto = 'int path_umount(struct path *path, int flags);\n'
if 'path_umount(struct path *path, int flags)' not in internal:
    if 'int do_umount(struct mount *mnt, int flags);\n' in internal:
        internal = internal.replace('int do_umount(struct mount *mnt, int flags);\n', 'int do_umount(struct mount *mnt, int flags);\n' + proto, 1)
    else:
        internal += '\n' + proto
    write('fs/internal.h', internal)

namespace = read('fs/namespace.c')
path_umount_impl = '''
int path_umount(struct path *path, int flags)
{
    return do_umount(real_mount(path->mnt), flags);
}
EXPORT_SYMBOL_GPL(path_umount);

'''
if 'int path_umount(struct path *path, int flags)' not in namespace:
    marker = 'const struct proc_ns_operations mntns_operations = {'
    if marker not in namespace:
        raise SystemExit(f"needle not found: {marker}")
    namespace = namespace.replace(marker, path_umount_impl + marker, 1)
    write('fs/namespace.c', namespace)

# legacy_susfs TRY_UMOUNT bridge
for rel in ['KernelSU-Next/kernel/supercalls.c', 'drivers/kernelsu/supercalls.c', 'common/drivers/kernelsu/supercalls.c']:
    p = root / rel
    if not p.exists():
        continue
    sc = p.read_text()
    if 'susfs_add_try_umount(' in sc:
        if 'extern int add_try_umount(const char __user *pathname);' not in sc:
            m = re.search(r'((?:#include[^\n]*\n)+)', sc)
            decl = '#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT\nextern int add_try_umount(const char __user *pathname);\n#endif\n\n'
            if m:
                sc = sc[:m.end()] + decl + sc[m.end():]
            else:
                sc = decl + sc
        sc = sc.replace('susfs_add_try_umount(', 'add_try_umount(')
        p.write_text(sc)
        break
PY

if git apply --check "$SUSFS_PATCH" >/dev/null 2>&1; then
  git apply --whitespace=fix "$SUSFS_PATCH"
else
  patch -p1 --forward < "$SUSFS_PATCH"
fi

echo "[+] KernelSU-Next legacy_susfs + manual-hook fixes + SUSFS patch applied"
