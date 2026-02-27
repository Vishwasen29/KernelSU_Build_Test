#!/usr/bin/env python3
"""
susfs_reject_fix.py  —  Fix the 5 files whose reject hunks represent
genuinely missing changes that will cause compile errors.

All other rejects are "Reversed / already applied" because KernelSU-Next
legacy-susfs already patched those files correctly.

Files that still need changes
──────────────────────────────
1. include/linux/mount.h
   → vfsmount struct missing  susfs_mnt_id_backup  field
     (namespace.c already uses it; without this the build fails)

2. fs/proc_namespace.c
   → Missing  #include <linux/susfs_def.h>  (provides DEFAULT_KSU_MNT_ID)
   → Missing extern declarations for susfs_hide_sus_mnts_for_non_su_procs
     and susfs_is_current_ksu_domain  (already called without decls)
   → show_mountinfo() missing the sus-mount filter block
     (show_vfsmnt/show_vfsstat already have it)

3. fs/proc/cmdline.c
   → Missing SPOOF_CMDLINE_OR_BOOTCONFIG hook
     (adapted to current seq_puts+seq_putc API, not old seq_printf)

4. fs/namei.c
   → Missing CONFIG_KSU_SUSFS_OPEN_REDIRECT block in do_filp_open()

5. kernel/kallsyms.c
   → s_show() missing CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS block
     (extern was added by hunk #1 which succeeded; hunk #2 which
     modifies s_show itself failed)
"""

import sys
import os
import re

# ── helpers ───────────────────────────────────────────────────────────────────

def read(path):
    with open(path, 'r') as f:
        return f.read()

def write(path, content):
    with open(path, 'w') as f:
        f.write(content)

def fix(path, old, new, label, required=True):
    rel = os.path.relpath(path, KDIR)
    content = read(path)
    if old in content:
        write(path, content.replace(old, new, 1))
        print(f"  [OK]   {rel}: {label}")
        return True
    if new in content:
        print(f"  [SKIP] {rel}: {label}  (already applied)")
        return True
    if required:
        print(f"  [FAIL] {rel}: {label}  — context not found, manual fix needed")
        # Dump a few lines of the expected context to aid debugging
        snippet = old.strip()[:80].replace('\n', '\\n')
        print(f"         expected: {snippet!r}")
    else:
        print(f"  [WARN] {rel}: {label}  — optional, context not found")
    return False

KDIR = sys.argv[1] if len(sys.argv) > 1 else '.'

def p(relpath):
    return os.path.join(KDIR, relpath)

# ── 1. include/linux/mount.h ──────────────────────────────────────────────────
print("\n[1/5] include/linux/mount.h  — add susfs_mnt_id_backup field")

# This kernel uses ANDROID_KABI_RESERVE slots.
# Repurpose slot 4 with ANDROID_KABI_USE when CONFIG_KSU_SUSFS is set,
# and keep the plain RESERVE otherwise.
fix(p("include/linux/mount.h"),
    # what is there
    "\tANDROID_KABI_RESERVE(4);\n} __randomize_layout;",
    # what we want
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n"
    "#else\n"
    "\tANDROID_KABI_RESERVE(4);\n"
    "#endif\n"
    "} __randomize_layout;",
    "repurpose ANDROID_KABI_RESERVE(4) → susfs_mnt_id_backup")

# ── 2. fs/proc_namespace.c ───────────────────────────────────────────────────
print("\n[2/5] fs/proc_namespace.c  — missing includes, externs, show_mountinfo block")

# 2a. Add #include + extern declarations after the last existing #include
fix(p("fs/proc_namespace.c"),
    '#include "internal.h"\n\nstatic __poll_t mounts_poll',
    '#include "internal.h"\n\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    'extern bool susfs_hide_sus_mnts_for_non_su_procs;\n'
    'extern bool susfs_is_current_ksu_domain(void);\n'
    '#endif\n\n'
    'static __poll_t mounts_poll',
    "add susfs_def.h include + extern declarations")

# 2b. Add the filter block inside show_mountinfo()
# Context: the function starts, declares variables, then directly calls seq_printf.
# We insert the filter before that first seq_printf call.
fix(p("fs/proc_namespace.c"),
    "static int show_mountinfo(struct seq_file *m, struct vfsmount *mnt)\n"
    "{\n"
    "\tstruct proc_mounts *p = m->private;\n"
    "\tstruct mount *r = real_mount(mnt);\n"
    "\tstruct super_block *sb = mnt->mnt_sb;\n"
    "\tstruct path mnt_path = { .dentry = mnt->mnt_root, .mnt = mnt };\n"
    "\tint err;\n"
    "\n"
    "\tseq_printf(m, \"%i %i %u:%u \",",
    "static int show_mountinfo(struct seq_file *m, struct vfsmount *mnt)\n"
    "{\n"
    "\tstruct proc_mounts *p = m->private;\n"
    "\tstruct mount *r = real_mount(mnt);\n"
    "\tstruct super_block *sb = mnt->mnt_sb;\n"
    "\tstruct path mnt_path = { .dentry = mnt->mnt_root, .mnt = mnt };\n"
    "\tint err;\n"
    "\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "\tif (susfs_hide_sus_mnts_for_non_su_procs &&\n"
    "\t\t\tr->mnt_id >= DEFAULT_KSU_MNT_ID &&\n"
    "\t\t\t!susfs_is_current_ksu_domain())\n"
    "\t{\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "#endif\n"
    "\n"
    "\tseq_printf(m, \"%i %i %u:%u \",",
    "add sus-mount filter block inside show_mountinfo()")

# ── 3. fs/proc/cmdline.c ─────────────────────────────────────────────────────
print("\n[3/5] fs/proc/cmdline.c  — add SPOOF_CMDLINE_OR_BOOTCONFIG hook")

# Current file uses seq_puts(m, saved_command_line) + seq_putc(m, '\n')
# (newer kernel API, NOT seq_printf as the patch expected).
# We adapt the hook to this style.
fix(p("fs/proc/cmdline.c"),
    "#include <linux/seq_file.h>\n"
    "\n"
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n"
    "{\n"
    "\tseq_puts(m, saved_command_line);\n"
    "\tseq_putc(m, '\\n');\n"
    "\treturn 0;\n"
    "}",
    "#include <linux/seq_file.h>\n"
    "\n"
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
    "extern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n"
    "#endif\n"
    "\n"
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n"
    "{\n"
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
    "\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n"
    "\t\tseq_putc(m, '\\n');\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "#endif\n"
    "\tseq_puts(m, saved_command_line);\n"
    "\tseq_putc(m, '\\n');\n"
    "\treturn 0;\n"
    "}",
    "add SPOOF_CMDLINE_OR_BOOTCONFIG hook (seq_puts API variant)")

# ── 4. fs/namei.c ─────────────────────────────────────────────────────────────
print("\n[4/5] fs/namei.c  — add CONFIG_KSU_SUSFS_OPEN_REDIRECT block in do_filp_open()")

# 4a. Add extern declaration + fake_pathname variable declaration
fix(p("fs/namei.c"),
    "struct file *do_filp_open(int dfd, struct filename *pathname,\n"
    "\t\tconst struct open_flags *op)\n"
    "{\n"
    "\tstruct nameidata nd;\n"
    "\tint flags = op->lookup_flags;\n"
    "\tstruct file *filp;\n",
    "struct file *do_filp_open(int dfd, struct filename *pathname,\n"
    "\t\tconst struct open_flags *op)\n"
    "{\n"
    "\tstruct nameidata nd;\n"
    "\tint flags = op->lookup_flags;\n"
    "\tstruct file *filp;\n"
    "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
    "\tstruct filename *fake_pathname;\n"
    "#endif\n",
    "add fake_pathname variable declaration")

# 4b. Add extern declaration before do_filp_open
fix(p("fs/namei.c"),
    "struct file *do_filp_open(int dfd, struct filename *pathname,",
    "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
    "extern struct filename *susfs_get_redirected_path(unsigned long ino);\n"
    "#endif\n"
    "\n"
    "struct file *do_filp_open(int dfd, struct filename *pathname,",
    "add susfs_get_redirected_path extern before do_filp_open")

# 4c. Add the OPEN_REDIRECT check before restore_nameidata() at end of function.
# The bare function tail currently is:
#   filp = path_openat(...LOOKUP_REVAL);
#   restore_nameidata();
#   return filp;
# }
fix(p("fs/namei.c"),
    "\tif (unlikely(filp == ERR_PTR(-ESTALE)))\n"
    "\t\tfilp = path_openat(&nd, op, flags | LOOKUP_REVAL);\n"
    "\trestore_nameidata();\n"
    "\treturn filp;\n"
    "}\n"
    "\n"
    "struct file *do_file_open_root(",
    "\tif (unlikely(filp == ERR_PTR(-ESTALE)))\n"
    "\t\tfilp = path_openat(&nd, op, flags | LOOKUP_REVAL);\n"
    "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
    "\tif (!IS_ERR(filp) && unlikely(filp->f_inode->i_state & BIT_OPEN_REDIRECT) &&\n"
    "\t\t\tcurrent_uid().val < 11000) {\n"
    "\t\tfake_pathname = susfs_get_redirected_path(filp->f_inode->i_ino);\n"
    "\t\tif (!IS_ERR(fake_pathname)) {\n"
    "\t\t\trestore_nameidata();\n"
    "\t\t\tfilp_close(filp, NULL);\n"
    "\t\t\t/* no need to putname(pathname) here — done by calling process */\n"
    "\t\t\tset_nameidata(&nd, dfd, fake_pathname);\n"
    "\t\t\tfilp = path_openat(&nd, op, flags | LOOKUP_RCU);\n"
    "\t\t\tif (unlikely(filp == ERR_PTR(-ECHILD)))\n"
    "\t\t\t\tfilp = path_openat(&nd, op, flags);\n"
    "\t\t\tif (unlikely(filp == ERR_PTR(-ESTALE)))\n"
    "\t\t\t\tfilp = path_openat(&nd, op, flags | LOOKUP_REVAL);\n"
    "\t\t\trestore_nameidata();\n"
    "\t\t\tputname(fake_pathname);\n"
    "\t\t\treturn filp;\n"
    "\t\t}\n"
    "\t}\n"
    "#endif\n"
    "\trestore_nameidata();\n"
    "\treturn filp;\n"
    "}\n"
    "\n"
    "struct file *do_file_open_root(",
    "add OPEN_REDIRECT redirect block before restore_nameidata()")

# ── 5. kernel/kallsyms.c ─────────────────────────────────────────────────────
print("\n[5/5] kernel/kallsyms.c  — add HIDE_KSU_SUSFS_SYMBOLS block in s_show()")

# The s_show() else-branch currently is:
#   } else
#       seq_printf(m, "%px %c %s\n", value, iter->type, iter->name);
#   return 0;
# }
# Hunk #1 (extern) already succeeded. Hunk #2 (s_show body) failed.
fix(p("kernel/kallsyms.c"),
    "\t} else\n"
    "\t\tseq_printf(m, \"%px %c %s\\n\", value,\n"
    "\t\t\t   iter->type, iter->name);\n"
    "\treturn 0;\n"
    "}",
    "\t} else {\n"
    "#ifndef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n"
    "\t\tseq_printf(m, \"%px %c %s\\n\", value,\n"
    "\t\t\t   iter->type, iter->name);\n"
    "#else\n"
    "\t\tif (susfs_starts_with(iter->name, \"ksu_\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"__ksu_\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"susfs_\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"ksud\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"is_ksu_\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"is_manager_\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"escape_to_\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"setup_selinux\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"track_throne\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"on_post_fs_data\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"try_umount\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"kernelsu\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"__initcall__kmod_kernelsu\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"apply_kernelsu\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"handle_sepolicy\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"getenforce\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"setenforce\") ||\n"
    "\t\t\tsusfs_starts_with(iter->name, \"is_zygote\"))\n"
    "\t\t{\n"
    "\t\t\treturn 0;\n"
    "\t\t}\n"
    "\t\tseq_printf(m, \"%px %c %s\\n\", value,\n"
    "\t\t\t   iter->type, iter->name);\n"
    "#endif\n"
    "\t}\n"
    "\treturn 0;\n"
    "}",
    "add HIDE_KSU_SUSFS_SYMBOLS conditional in s_show()")

print("\nDone.")
