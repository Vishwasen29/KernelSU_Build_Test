#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

detect_ksu_tree() {
  local d
  for d in \
    "drivers/kernelsu" \
    "common/drivers/kernelsu" \
    "KernelSU-Next/kernel" \
    "KernelSU/kernel"
  do
    if [ -d "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

KSU_TREE="$(detect_ksu_tree || true)"
if [ -z "$KSU_TREE" ]; then
  warn "KernelSU tree not found. Run KernelSU-Next setup first, or clone/link it under drivers/kernelsu."
  exit 1
fi

ksu_has_symbol() {
  grep -Rqs "$1" "$KSU_TREE"
}

insert_once_before() {
  local file="$1" needle="$2" block="$3"
  python3 - "$file" "$needle" "$block" <<'PY'
import sys
from pathlib import Path
file, needle, block = sys.argv[1:4]
p = Path(file)
text = p.read_text()
if block in text:
    sys.exit(0)
idx = text.find(needle)
if idx == -1:
    print(f"needle not found: {needle} in {file}", file=sys.stderr)
    sys.exit(2)
text = text[:idx] + block + "\n" + text[idx:]
p.write_text(text)
PY
}

insert_once_after() {
  local file="$1" needle="$2" block="$3"
  python3 - "$file" "$needle" "$block" <<'PY'
import sys
from pathlib import Path
file, needle, block = sys.argv[1:4]
p = Path(file)
text = p.read_text()
if block in text:
    sys.exit(0)
idx = text.find(needle)
if idx == -1:
    print(f"needle not found: {needle} in {file}", file=sys.stderr)
    sys.exit(2)
idx += len(needle)
text = text[:idx] + "\n" + block + text[idx:]
p.write_text(text)
PY
}

insert_once_before_any() {
  local file="$1" block="$2"
  shift 2
  local needle
  for needle in "$@"; do
    if grep -Fq "$needle" "$file"; then
      insert_once_before "$file" "$needle" "$block"
      return 0
    fi
  done
  printf 'needle not found in %s; tried:\n' "$file" >&2
  for needle in "$@"; do
    printf '  - %s\n' "$needle" >&2
  done
  return 2
}

replace_once() {
  local file="$1" old="$2" new="$3"
  python3 - "$file" "$old" "$new" <<'PY'
import sys
from pathlib import Path
file, old, new = sys.argv[1:4]
p = Path(file)
text = p.read_text()
if new in text:
    sys.exit(0)
if old not in text:
    print(f"needle not found: {old} in {file}", file=sys.stderr)
    sys.exit(2)
text = text.replace(old, new, 1)
p.write_text(text)
PY
}

patch_exec() {
  local f="fs/exec.c"
  [ -f "$f" ] || return 0

  if ksu_has_symbol "ksu_handle_execve_sucompat"; then
    insert_once_before "$f" "SYSCALL_DEFINE3(execve," '#ifdef CONFIG_KSU
extern int ksu_handle_execve_sucompat(const char __user **filename_user,
\t\t\t\t      void *__never_use_argv,
\t\t\t\t      void *__never_use_envp,
\t\t\t\t      int *__never_use_flags);
#endif'

    insert_once_before_any "$f" '#ifdef CONFIG_KSU
\tksu_handle_execve_sucompat(&filename, NULL, NULL, NULL);
#endif' \
      "return do_execve(getname(filename), argv, envp);"

    if grep -q "COMPAT_SYSCALL_DEFINE3(execve," "$f"; then
      insert_once_before_any "$f" '#ifdef CONFIG_KSU
\tksu_handle_execve_sucompat(&filename, NULL, NULL, NULL);
#endif' \
        "return compat_do_execve(getname(filename), argv, envp);"
    fi

    log "[+] Patched fs/exec.c for KernelSU-Next legacy execve_sucompat"
    return 0
  fi

  if ksu_has_symbol "ksu_handle_execveat"; then
    insert_once_before "$f" "int do_execve(struct filename *filename," '#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
\t\t\t\t      void *envp, int *flags);
#endif'

    insert_once_before_any "$f" '#ifdef CONFIG_KSU
\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif' \
      "return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);"

    if grep -q "static int compat_do_execve(struct filename \*filename," "$f"; then
      insert_once_before_any "$f" '#ifdef CONFIG_KSU
\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif' \
        "return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);"
    fi

    log "[+] Patched fs/exec.c for ksu_handle_execveat"
    return 0
  fi

  warn "No supported execve hook symbol found in $KSU_TREE"
}

patch_open() {
  local f="fs/open.c"
  [ -f "$f" ] || return 0
  if ! ksu_has_symbol "ksu_handle_faccessat"; then
    warn "ksu_handle_faccessat not found; skipping fs/open.c"
    return 0
  fi

  insert_once_before "$f" "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)" '#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
\t\t\t\t      int *flags);
#endif'

  insert_once_before "$f" "return do_faccessat(dfd, filename, mode);" '#ifdef CONFIG_KSU
\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif'

  log "[+] Patched fs/open.c"
}

patch_read_write() {
  local f="fs/read_write.c"
  [ -f "$f" ] || return 0
  if ! ksu_has_symbol "ksu_vfs_read_hook"; then
    warn "ksu_vfs_read_hook not found; skipping fs/read_write.c"
    return 0
  fi

  if ksu_has_symbol "ksu_handle_sys_read"; then
    insert_once_before "$f" "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)" '#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
\t\t\t\t       size_t *count_ptr);
#endif'

    insert_once_before "$f" "return ksys_read(fd, buf, count);" '#ifdef CONFIG_KSU
\tif (unlikely(ksu_vfs_read_hook))
\t\tksu_handle_sys_read(fd, (char __user **)&buf, &count);
#endif'

    log "[+] Patched fs/read_write.c for ksu_handle_sys_read"
    return 0
  fi

  if ksu_has_symbol "ksu_handle_vfs_read"; then
    insert_once_before "$f" "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)" '#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
\t\t\t\t      size_t *count_ptr, loff_t **pos);
#endif'

    insert_once_before_any "$f" '#ifdef CONFIG_KSU
\tif (unlikely(ksu_vfs_read_hook))
\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif' \
      "if (!(file->f_mode & FMODE_READ))" \
      "if (unlikely(!(file->f_mode & FMODE_READ)))"

    log "[+] Patched fs/read_write.c for ksu_handle_vfs_read"
    return 0
  fi

  warn "No supported read hook symbol found in $KSU_TREE"
}

patch_stat() {
  local f="fs/stat.c"
  [ -f "$f" ] || return 0
  if ! ksu_has_symbol "ksu_handle_stat"; then
    warn "ksu_handle_stat not found; skipping fs/stat.c"
    return 0
  fi

  insert_once_before "$f" "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)" '#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif'

  if grep -q "SYSCALL_DEFINE4(newfstatat, int, dfd," "$f"; then
    insert_once_before "$f" "error = vfs_fstatat(dfd, filename, &stat, flag);" '#ifdef CONFIG_KSU
\tksu_handle_stat(&dfd, &filename, &flag);
#endif'
  fi
  if grep -q "SYSCALL_DEFINE4(fstatat64, int, dfd," "$f"; then
    insert_once_before_any "$f" '#ifdef CONFIG_KSU
\tksu_handle_stat(&dfd, &filename, &flag);
#endif' \
      "error = vfs_fstatat(dfd, filename, &stat, flag);"
  fi

  log "[+] Patched fs/stat.c"
}

patch_reboot() {
  local f="kernel/reboot.c"
  [ -f "$f" ] || return 0
  if ! ksu_has_symbol "ksu_handle_sys_reboot"; then
    warn "ksu_handle_sys_reboot not found; skipping kernel/reboot.c"
    return 0
  fi

  insert_once_before "$f" "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd," '#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif'

  insert_once_before "$f" "int ret = 0;" '#ifdef CONFIG_KSU
\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'

  log "[+] Patched kernel/reboot.c"
}

patch_path_umount_support() {
  local fh="fs/internal.h"
  local fn="fs/namespace.c"
  [ -f "$fh" ] || return 0
  [ -f "$fn" ] || return 0

  if ! grep -Fq 'int path_umount(struct path *path, int flags);' "$fh"; then
    insert_once_before "$fh" 'extern int __mnt_want_write_file(struct file *);' 'int path_umount(struct path *path, int flags);'
    log "[+] Added path_umount declaration to fs/internal.h"
  fi

  if ! grep -Fq 'static int can_umount(const struct path *path, int flags)' "$fn"; then
    insert_once_before "$fn" 'static bool is_mnt_ns_file(struct dentry *dentry)' 'static int can_umount(const struct path *path, int flags)
{
\tstruct mount *mnt = real_mount(path->mnt);

\tif (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
\t\treturn -EINVAL;
\tif (!may_mount())
\t\treturn -EPERM;
\tif (path->dentry != path->mnt->mnt_root)
\t\treturn -EINVAL;
\tif (!check_mnt(mnt))
\t\treturn -EINVAL;
\tif (mnt->mnt.mnt_flags & MNT_LOCKED)
\t\treturn -EINVAL;
\tif (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
\t\treturn -EPERM;
\treturn 0;
}

int path_umount(struct path *path, int flags)
{
\tstruct mount *mnt = real_mount(path->mnt);
\tint ret;

\tret = can_umount(path, flags);
\tif (!ret)
\t\tret = do_umount(mnt, flags);
\tdput(path->dentry);
\tmntput_no_expire(mnt);
\treturn ret;
}
'
    log "[+] Added path_umount support to fs/namespace.c"
  fi
}

patch_ksunext_try_umount_compat() {
  local f=""
  if [ -f drivers/kernelsu/supercalls.c ]; then
    f="drivers/kernelsu/supercalls.c"
  elif [ -f common/drivers/kernelsu/supercalls.c ]; then
    f="common/drivers/kernelsu/supercalls.c"
  else
    warn "supercalls.c not found; skipping TRY_UMOUNT compat patch"
    return 0
  fi

  if grep -Fq 'susfs_add_try_umount(arg);' "$f" && grep -Fq 'static int add_try_umount(void __user *arg)' "$f"; then
    replace_once "$f" '            susfs_add_try_umount(arg);' '            add_try_umount(arg);'
    log "[+] Patched $f to use KernelSU's add_try_umount() for CONFIG_KSU_SUSFS_TRY_UMOUNT"
  fi
}

patch_exec
patch_open
patch_read_write
patch_stat
patch_reboot
patch_path_umount_support
patch_ksunext_try_umount_compat

log "[+] Done. Review changes with: git diff -- fs/exec.c fs/open.c fs/read_write.c fs/stat.c kernel/reboot.c fs/internal.h fs/namespace.c drivers/kernelsu/supercalls.c common/drivers/kernelsu/supercalls.c"
