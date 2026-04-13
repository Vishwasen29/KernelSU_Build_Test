#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# detect linked or embedded KernelSU tree
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
    local decl hook
    decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern int ksu_handle_execve_sucompat(const char __user **filename_user,
                                      void *__never_use_argv,
                                      void *__never_use_envp,
                                      int *__never_use_flags);
#endif
EOB
)
    hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    ksu_handle_execve_sucompat(&filename, NULL, NULL, NULL);
#endif
EOB
)

    insert_once_before "$f" "SYSCALL_DEFINE3(execve," "$decl"
    insert_once_before_any "$f" "$hook" \
      "return do_execve(getname(filename), argv, envp);"

    if grep -q "COMPAT_SYSCALL_DEFINE3(execve," "$f"; then
      insert_once_before_any "$f" "$hook" \
        "return compat_do_execve(getname(filename), argv, envp);"
    fi

    log "[+] Patched fs/exec.c for KernelSU-Next legacy execve_sucompat"
    return 0
  fi

  if ksu_has_symbol "ksu_handle_execveat"; then
    local decl hook
    decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
                               void *envp, int *flags);
#endif
EOB
)
    hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
EOB
)

    insert_once_before "$f" "int do_execve(struct filename *filename," "$decl"
    insert_once_before_any "$f" "$hook" \
      "return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);"

    if grep -q "static int compat_do_execve(struct filename \*filename," "$f"; then
      insert_once_before_any "$f" "$hook" \
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

  local decl hook
  decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
                                int *flags);
#endif
EOB
)
  hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
EOB
)

  insert_once_before "$f" "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)" "$decl"
  insert_once_before "$f" "return do_faccessat(dfd, filename, mode);" "$hook"

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
    local decl hook
    decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
                               size_t *count_ptr);
#endif
EOB
)
    hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    if (unlikely(ksu_vfs_read_hook))
        ksu_handle_sys_read(fd, (char __user **)&buf, &count);
#endif
EOB
)

    insert_once_before "$f" "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)" "$decl"
    insert_once_before "$f" "return ksys_read(fd, buf, count);" "$hook"

    log "[+] Patched fs/read_write.c for ksu_handle_sys_read"
    return 0
  fi

  if ksu_has_symbol "ksu_handle_vfs_read"; then
    local decl hook
    decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                               size_t *count_ptr, loff_t **pos);
#endif
EOB
)
    hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    if (unlikely(ksu_vfs_read_hook))
        ksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
EOB
)

    insert_once_before "$f" "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)" "$decl"
    insert_once_before_any "$f" "$hook" \
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

  local decl hook
  decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
EOB
)
  hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    ksu_handle_stat(&dfd, &filename, &flag);
#endif
EOB
)

  insert_once_before "$f" "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)" "$decl"

  if grep -q "SYSCALL_DEFINE4(newfstatat, int, dfd," "$f"; then
    insert_once_before "$f" "error = vfs_fstatat(dfd, filename, &stat, flag);" "$hook"
  fi
  if grep -q "SYSCALL_DEFINE4(fstatat64, int, dfd," "$f"; then
    insert_once_before_any "$f" "$hook" \
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

  local decl hook
  decl=$(cat <<'EOB'
#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
EOB
)
  hook=$(cat <<'EOB'
#ifdef CONFIG_KSU
    ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
EOB
)

  insert_once_before "$f" "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd," "$decl"
  insert_once_before "$f" "int ret = 0;" "$hook"

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
    local block
    block=$(cat <<'EOB'
static int can_umount(const struct path *path, int flags)
{
    struct mount *mnt = real_mount(path->mnt);

    if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
        return -EINVAL;
    if (!may_mount())
        return -EPERM;
    if (path->dentry != path->mnt->mnt_root)
        return -EINVAL;
    if (!check_mnt(mnt))
        return -EINVAL;
    if (mnt->mnt.mnt_flags & MNT_LOCKED)
        return -EINVAL;
    if ((flags & MNT_FORCE) && !capable(CAP_SYS_ADMIN))
        return -EPERM;
    return 0;
}

int path_umount(struct path *path, int flags)
{
    struct mount *mnt = real_mount(path->mnt);
    int ret;

    ret = can_umount(path, flags);
    if (!ret)
        ret = do_umount(mnt, flags);
    dput(path->dentry);
    mntput_no_expire(mnt);
    return ret;
}
EOB
)
    insert_once_before "$fn" 'static bool is_mnt_ns_file(struct dentry *dentry)' "$block"
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
    log "[+] Patched $f to use KernelSU\'s add_try_umount() for CONFIG_KSU_SUSFS_TRY_UMOUNT"
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
