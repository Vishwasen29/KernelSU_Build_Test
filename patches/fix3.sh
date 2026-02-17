#!/bin/bash
# =============================================================================
# fix_susfs_rejects.sh
# Manually applies all failed SuSFS v2.0.00 patch hunks for the
# LineageOS android_kernel_oneplus_sm8250 (lineage-23.2) tree.
#
# Covers:
#   - fs/Makefile                  (susfs.o obj-y entry)
#   - include/linux/mount.h        (ANDROID_KABI_RESERVE(4) -> SuSFS ifdef)
#   - fs/namespace.c               (includes, externs, vfs_kern_mount, clone_mnt)
#   - fs/proc/task_mmu.c           (pagemap_read SUS_MAP block + vma decl fix)
#
# Run BEFORE the SuSFS patch step in your workflow.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; exit 1; }

# GitHub Actions kernel source root
KERNEL_DIR="${GITHUB_WORKSPACE}/kernel_workspace/android-kernel"
cd "$KERNEL_DIR" || error "Could not cd into $KERNEL_DIR — is GITHUB_WORKSPACE set?"
[ -f "Makefile" ] || error "Makefile not found in $KERNEL_DIR — wrong path?"

info "Working directory: $(pwd)"

# Clean up leftover .rej/.orig files from previous runs
info "Cleaning up leftover .rej and .orig files..."
find . -name "*.rej" -delete
find . -name "*.orig" -delete

BACKUP_DIR="${KERNEL_DIR}/.susfs_fix_backups"
mkdir -p "$BACKUP_DIR"

backup() {
    local file="$1"
    local dest="$BACKUP_DIR/$(echo "$file" | tr '/' '_').bak"
    cp "$file" "$dest"
    info "Backed up $file"
}

# =============================================================================
# 1. fs/Makefile
#    The patch adds susfs.o to the obj-y list but fails because the Makefile
#    line wraps differently in this kernel tree.
#    Fix: insert 'obj-y += susfs.o' after the obj-y block ends safely.
# =============================================================================
MAKEFILE="fs/Makefile"
info "Patching $MAKEFILE ..."
[ -f "$MAKEFILE" ] || error "File not found: $MAKEFILE"
backup "$MAKEFILE"

if grep -q "susfs.o" "$MAKEFILE"; then
    warn "$MAKEFILE already contains susfs.o, skipping."
else
    # The patch adds susfs.o to the obj-y list. We cannot safely inline it into
    # a multi-line obj-y block (lines ending with \) as that corrupts Makefile
    # syntax. Instead, find where the first obj-y block ends and insert a
    # standalone 'obj-y += susfs.o' line immediately after it.
    python3 - "$MAKEFILE" <<'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    lines = f.readlines()

in_block = False
insert_after = -1
for i, line in enumerate(lines):
    stripped = line.rstrip('\n')
    if not in_block and 'obj-y' in stripped and ':=' in stripped:
        in_block = True
    if in_block:
        if stripped.rstrip().endswith('\\'):
            insert_after = i
        else:
            insert_after = i
            break

if insert_after >= 0:
    lines.insert(insert_after + 1, 'obj-y += susfs.o\n')
    with open(filepath, 'w') as f:
        f.writelines(lines)
    print("[+] fs/Makefile patched — susfs.o added after obj-y block.")
else:
    with open(filepath, 'a') as f:
        f.write('\nobj-y += susfs.o\n')
    print("[!] fs/Makefile: used fallback append.")
PYEOF
fi

# =============================================================================
# 2. include/linux/mount.h
#    Replace ANDROID_KABI_RESERVE(4) with the SuSFS ifdef block
# =============================================================================
MOUNT_H="include/linux/mount.h"
info "Patching $MOUNT_H ..."
[ -f "$MOUNT_H" ] || error "File not found: $MOUNT_H"
backup "$MOUNT_H"

if grep -q "CONFIG_KSU_SUSFS" "$MOUNT_H"; then
    warn "$MOUNT_H already contains SuSFS changes, skipping."
elif grep -q "ANDROID_KABI_RESERVE(4);" "$MOUNT_H"; then
    awk '
    /ANDROID_KABI_RESERVE\(4\);/ && !done {
        print "#ifdef CONFIG_KSU_SUSFS"
        print "\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);"
        print "#else"
        print "\tANDROID_KABI_RESERVE(4);"
        print "#endif"
        done=1
        next
    }
    { print }
    ' "$MOUNT_H" > "${MOUNT_H}.tmp" && mv "${MOUNT_H}.tmp" "$MOUNT_H"
    info "$MOUNT_H patched successfully."
else
    warn "Could not find ANDROID_KABI_RESERVE(4) in $MOUNT_H — manual edit required."
fi

# =============================================================================
# 3. fs/namespace.c
#    3a. Include block at top (after sched/task.h)
#    3b. Extern declarations before pnode.h
#    3c. vfs_kern_mount() — mnt_id backup after alloc + SuSFS id on ksu domain
#    3d. clone_mnt() — SuSFS sus_mount block
# =============================================================================
NAMESPACE_C="fs/namespace.c"
info "Patching $NAMESPACE_C ..."
[ -f "$NAMESPACE_C" ] || error "File not found: $NAMESPACE_C"
backup "$NAMESPACE_C"

# 3a + 3b: includes and externs
if grep -q "CONFIG_KSU_SUSFS_SUS_MOUNT" "$NAMESPACE_C"; then
    warn "$NAMESPACE_C already has SUS_MOUNT changes, skipping 3a+3b."
else
    if grep -q '#include <linux/sched/task.h>' "$NAMESPACE_C"; then
        awk '
        /#include <linux\/sched\/task.h>/ && !done {
            print
            print ""
            print "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
            print "#include <linux/susfs_def.h>"
            print "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
            done=1
            next
        }
        { print }
        ' "$NAMESPACE_C" > "${NAMESPACE_C}.tmp" && mv "${NAMESPACE_C}.tmp" "$NAMESPACE_C"
        info "$NAMESPACE_C 3a (include) applied."
    else
        warn "Could not find '#include <linux/sched/task.h>' in $NAMESPACE_C."
    fi

    if grep -q '#include "pnode.h"' "$NAMESPACE_C" && ! grep -q "susfs_is_current_ksu_domain" "$NAMESPACE_C"; then
        awk '
        /#include "pnode.h"/ && !done {
            print "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
            print "extern bool susfs_is_current_ksu_domain(void);"
            print "extern bool susfs_is_sdcard_android_data_decrypted;"
            print ""
            print "static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);"
            print ""
            print "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */"
            print "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
            print ""
            done=1
        }
        { print }
        ' "$NAMESPACE_C" > "${NAMESPACE_C}.tmp" && mv "${NAMESPACE_C}.tmp" "$NAMESPACE_C"
        info "$NAMESPACE_C 3b (externs) applied."
    fi
fi

# 3c + 3d: vfs_kern_mount and clone_mnt
python3 - "$NAMESPACE_C" <<'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

changed = False

# --- 3c hunk ~949: mnt_id backup after alloc_vfsmnt(name) ---
if 'susfs_mnt_id_backup' not in content:
    old_949 = (
        '\tmnt = alloc_vfsmnt(name);\n'
        '\tif (!mnt)\n'
        '\t\treturn ERR_PTR(-ENOMEM);\n'
    )
    new_949 = (
        '\tmnt = alloc_vfsmnt(name);\n'
        '\tif (!mnt)\n'
        '\t\treturn ERR_PTR(-ENOMEM);\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
        '\tmnt->mnt.susfs_mnt_id_backup = mnt->mnt_id;\n'
        '#endif\n'
    )
    if old_949 in content:
        content = content.replace(old_949, new_949, 1)
        print("[+] namespace.c 3c hunk ~949 (mnt_id backup) applied.")
        changed = True
    else:
        print("[!] namespace.c 3c hunk ~949: pattern not found.")
        print("    Manually add after alloc_vfsmnt(name) success in vfs_kern_mount():")
        print("    #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT")
        print("    mnt->mnt.susfs_mnt_id_backup = mnt->mnt_id;")
        print("    #endif")
else:
    print("[!] namespace.c 3c: susfs_mnt_id_backup already present, skipping.")

# --- 3c hunk ~979: SuSFS mnt_id assignment in vfs_kern_mount lock block ---
if 'susfs_get_sus_mnt_id' not in content:
    old_979 = (
        '\tmnt->mnt.mnt_sb = root->d_sb;\n'
        '\tmnt->mnt_mountpoint = mnt->mnt.mnt_root;\n'
        '\tmnt->mnt_parent = mnt;\n'
        '\tlock_mount_hash();\n'
        '\tlist_add_tail(&mnt->mnt_instance, &root->d_sb->s_mounts);\n'
        '\tunlock_mount_hash();\n'
    )
    new_979 = (
        '\tmnt->mnt.mnt_sb = root->d_sb;\n'
        '\tmnt->mnt_mountpoint = mnt->mnt.mnt_root;\n'
        '\tmnt->mnt_parent = mnt;\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
        '\tif (susfs_is_current_ksu_domain()) {\n'
        '\t\tmnt->mnt_id = susfs_get_sus_mnt_id();\n'
        '\t\tmnt->mnt.susfs_mnt_id_backup = mnt->mnt_id;\n'
        '\t}\n'
        '#endif\n'
        '\tlock_mount_hash();\n'
        '\tlist_add_tail(&mnt->mnt_instance, &root->d_sb->s_mounts);\n'
        '\tunlock_mount_hash();\n'
    )
    if old_979 in content:
        content = content.replace(old_979, new_979, 1)
        print("[+] namespace.c 3c hunk ~979 (SuSFS mnt_id in lock block) applied.")
        changed = True
    else:
        print("[!] namespace.c 3c hunk ~979: pattern not found.")
        print("    Manually add SuSFS mnt_id block before lock_mount_hash() in vfs_kern_mount().")
else:
    print("[!] namespace.c 3c: susfs_get_sus_mnt_id already present, skipping.")

# --- 3d: clone_mnt SuSFS block ---
if 'bypass_orig_flow' not in content and 'susfs_reuse_sus_vfsmnt' not in content:
    old_3d = '\tmnt = alloc_vfsmnt(old->mnt_devname);\n'
    new_3d = (
        '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
        '\tif (susfs_is_sdcard_android_data_decrypted) {\n'
        '\t\tgoto skip_checking_for_ksu_proc;\n'
        '\t}\n'
        '\tif (susfs_is_current_ksu_domain()) {\n'
        '\t\tif (flag & CL_COPY_MNT_NS) {\n'
        '\t\t\tmnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);\n'
        '\t\t\tgoto bypass_orig_flow;\n'
        '\t\t}\n'
        '\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n'
        '\t\tgoto bypass_orig_flow;\n'
        '\t}\n'
        'skip_checking_for_ksu_proc:\n'
        '\tif (old->mnt_id == DEFAULT_KSU_MNT_ID) {\n'
        '\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n'
        '\t\tgoto bypass_orig_flow;\n'
        '\t}\n'
        '#endif\n'
        '\tmnt = alloc_vfsmnt(old->mnt_devname);\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
        'bypass_orig_flow:\n'
        '#endif\n'
    )
    if old_3d in content:
        content = content.replace(old_3d, new_3d, 1)
        print("[+] namespace.c 3d (clone_mnt SuSFS block) applied.")
        changed = True
    else:
        print("[!] namespace.c 3d: could not find alloc_vfsmnt(old->mnt_devname).")
else:
    print("[!] namespace.c 3d: clone_mnt SuSFS block already present, skipping.")

if changed:
    with open(filepath, 'w') as f:
        f.write(content)
PYEOF

# =============================================================================
# 4. fs/proc/task_mmu.c
#    4a. Insert the SUS_MAP block after up_read(&mm->mmap_sem)
#    4b. Fix compile error: 'unused variable vma' — ensure vma is declared
#        inside pagemap_read() when the SUS_MAP block is present
# =============================================================================
TASK_MMU="fs/proc/task_mmu.c"
info "Patching $TASK_MMU ..."
[ -f "$TASK_MMU" ] || error "File not found: $TASK_MMU"
backup "$TASK_MMU"

python3 - "$TASK_MMU" <<'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

sus_map_block = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\t\tvma = find_vma(mm, start_vaddr);\n'
    '\t\tif (vma && vma->vm_file) {\n'
    '\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n'
    '\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n'
    '\t\t\t\tpm.buffer->pme = 0;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '#endif\n'
)

# 4a: Insert SUS_MAP block
if 'CONFIG_KSU_SUSFS_SUS_MAP' not in content and 'BIT_SUS_MAPS' not in content:
    target_after  = '\t\tup_read(&mm->mmap_sem);\n'
    target_before = '\t\tstart_vaddr = end;\n'
    lines = content.splitlines(keepends=True)
    new_lines = []
    inserted = False
    i = 0
    while i < len(lines):
        new_lines.append(lines[i])
        if lines[i] == target_after and not inserted:
            for j in range(i + 1, min(i + 10, len(lines))):
                if lines[j] == target_before:
                    new_lines.append(sus_map_block)
                    inserted = True
                    break
        i += 1
    if inserted:
        content = ''.join(new_lines)
        print("[+] task_mmu.c 4a (SUS_MAP block) inserted.")
    else:
        print("[!] task_mmu.c 4a: could not find up_read/start_vaddr pattern.")
        print("    Manually insert SUS_MAP block after up_read(&mm->mmap_sem) in pagemap_read().")
else:
    print("[!] task_mmu.c 4a: SUS_MAP block already present, skipping.")

# 4b: Fix unused variable 'vma' compile error
# The SUS_MAP block references 'vma' but it may not be declared in pagemap_read().
# Find pagemap_read() and add 'struct vm_area_struct *vma = NULL;' after the
# first local variable declaration inside the function.
if 'CONFIG_KSU_SUSFS_SUS_MAP' in content or 'BIT_SUS_MAPS' in content:
    func_match = re.search(
        r'static ssize_t pagemap_read\s*\([^{]*\{',
        content, re.DOTALL
    )
    if func_match:
        func_start = func_match.end()
        snippet = content[func_start:func_start + 3000]
        if 'vm_area_struct *vma' not in snippet:
            lines = content.splitlines(keepends=True)
            in_func = False
            brace_depth = 0
            inserted_decl = False
            new_lines = []
            for line in lines:
                new_lines.append(line)
                if 'static ssize_t pagemap_read' in line:
                    in_func = True
                if in_func:
                    brace_depth += line.count('{') - line.count('}')
                    if brace_depth > 0 and line.strip().endswith(';') and not inserted_decl:
                        new_lines.append('\tstruct vm_area_struct *vma = NULL;\n')
                        inserted_decl = True
                        in_func = False
            if inserted_decl:
                content = ''.join(new_lines)
                print("[+] task_mmu.c 4b (vma declaration) added — fixes unused-variable error.")
            else:
                print("[!] task_mmu.c 4b: could not auto-insert vma declaration.")
                print("    Manually add 'struct vm_area_struct *vma = NULL;' inside pagemap_read().")
        else:
            print("[!] task_mmu.c 4b: vma already declared in pagemap_read(), skipping.")
    else:
        print("[!] task_mmu.c 4b: could not locate pagemap_read() — manual fix required.")

with open(filepath, 'w') as f:
    f.write(content)
PYEOF

# =============================================================================
# Final report
# =============================================================================
echo ""
info "==================================================="
info "All patches attempted. Backups in: $BACKUP_DIR/"
info "==================================================="
warn "IMPORTANT: This script must run BEFORE the SuSFS patch step."
echo ""
echo "  Correct workflow step order:"
echo "    1. Checkout kernel source"
echo "    2. Run: bash \$GITHUB_WORKSPACE/patches/fix3.sh   ← this script"
echo "    3. Run: <your existing SuSFS patch step>"
echo "    4. Build"
info "==================================================="
