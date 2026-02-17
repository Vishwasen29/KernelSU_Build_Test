#!/bin/bash
# =============================================================================
# fix_susfs_rejects.sh
# Manually applies failed SuSFS v2.0.00 patch hunks for:
#   - include/linux/mount.h
#   - fs/namespace.c
#   - fs/proc/task_mmu.c
#
# Run this from the ROOT of your kernel source directory.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[-]${NC} $1"; exit 1; }

# GitHub Actions kernel source root
KERNEL_DIR="${GITHUB_WORKSPACE}/kernel_workspace/android-kernel"
cd "$KERNEL_DIR" || error "Could not cd into $KERNEL_DIR — is GITHUB_WORKSPACE set?"

# Make sure we're in a kernel source tree
[ -f "Makefile" ] || error "Makefile not found in $KERNEL_DIR — is this the right kernel path?"

info "Working directory: $(pwd)"

# Clean up any leftover .rej files from previous runs so they don't confuse the build
info "Cleaning up any leftover .rej and .orig files from previous runs..."
find . -name "*.rej" -delete
find . -name "*.orig" -delete

BACKUP_DIR="${KERNEL_DIR}/.susfs_fix_backups"
mkdir -p "$BACKUP_DIR"

backup() {
    local file="$1"
    local dest="$BACKUP_DIR/$(echo "$file" | tr '/' '_').bak"
    cp "$file" "$dest"
    info "Backed up $file → $dest"
}

# =============================================================================
# 1. include/linux/mount.h
#    Replace ANDROID_KABI_RESERVE(4) with the SuSFS ifdef block
# =============================================================================
MOUNT_H="include/linux/mount.h"
info "Patching $MOUNT_H ..."

[ -f "$MOUNT_H" ] || error "File not found: $MOUNT_H"
backup "$MOUNT_H"

# Check if already patched
if grep -q "CONFIG_KSU_SUSFS" "$MOUNT_H"; then
    warn "$MOUNT_H already contains SuSFS changes, skipping."
else
    # The patch wants to replace:
    #   ANDROID_KABI_RESERVE(4);
    # with:
    #   #ifdef CONFIG_KSU_SUSFS
    #   ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);
    #   #else
    #   ANDROID_KABI_RESERVE(4);
    #   #endif
    #
    # We look for it inside the vfsmount struct, specifically after RESERVE(3)

    if grep -q "ANDROID_KABI_RESERVE(4);" "$MOUNT_H"; then
        # Use awk to replace only the first occurrence of ANDROID_KABI_RESERVE(4)
        # that follows ANDROID_KABI_RESERVE(3) (i.e., inside vfsmount)
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
        warn "Could not find 'ANDROID_KABI_RESERVE(4)' in $MOUNT_H."
        warn "Your kernel may not use ANDROID_KABI macros. Manual edit required."
        warn "Add this inside struct vfsmount, replacing or after any KABI reserve slot 4:"
        echo ""
        echo "  #ifdef CONFIG_KSU_SUSFS"
        echo "  ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);"
        echo "  #else"
        echo "  ANDROID_KABI_RESERVE(4);"
        echo "  #endif"
        echo ""
    fi
fi

# =============================================================================
# 2. fs/namespace.c — Hunk at line ~26 (includes block at top)
#    Add SuSFS include and extern declarations after the existing includes
# =============================================================================
NAMESPACE_C="fs/namespace.c"
info "Patching $NAMESPACE_C (hunk 1 — includes) ..."

[ -f "$NAMESPACE_C" ] || error "File not found: $NAMESPACE_C"
backup "$NAMESPACE_C"

if grep -q "CONFIG_KSU_SUSFS_SUS_MOUNT" "$NAMESPACE_C"; then
    warn "$NAMESPACE_C already contains SuSFS changes, skipping hunk 1."
else
    # Insert after: #include <linux/sched/task.h>
    # The patch adds susfs_def.h include and extern declarations before pnode.h
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
        info "$NAMESPACE_C hunk 1 (include) applied."
    else
        warn "Could not find '#include <linux/sched/task.h>' in $NAMESPACE_C."
        warn "Manually add after your last #include block:"
        echo ""
        echo "  #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        echo "  #include <linux/susfs_def.h>"
        echo "  #endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        echo ""
    fi
fi

# Insert extern declarations and atomic after the includes, before pnode.h
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
    info "$NAMESPACE_C hunk 1 (externs) applied."
fi

# =============================================================================
# 2b. fs/namespace.c — Hunk at ~1090 (whitespace-only change in vfs_kern_mount)
#     This hunk is just a trailing space added then removed — safe to skip.
#     The patch failure here was cosmetic (fuzz issue). No code change needed.
# =============================================================================
info "Skipping $NAMESPACE_C hunk 2 (whitespace-only change, no functional impact)."

# =============================================================================
# 2c. fs/namespace.c — Hunk at ~1150 (clone_mnt SuSFS logic)
# =============================================================================
info "Patching $NAMESPACE_C (hunk 3 — clone_mnt SuSFS logic) ..."

if grep -q "susfs_reuse_sus_vfsmnt\|bypass_orig_flow" "$NAMESPACE_C"; then
    warn "$NAMESPACE_C clone_mnt SuSFS block already present, skipping."
else
    # Find 'mnt = alloc_vfsmnt(old->mnt_devname);' inside clone_mnt and insert before it
    # We use a pattern unique to clone_mnt (it takes 'struct mount *old' as arg)
    if grep -q "mnt = alloc_vfsmnt(old->mnt_devname);" "$NAMESPACE_C"; then
        python3 - "$NAMESPACE_C" <<'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

old = 'mnt = alloc_vfsmnt(old->mnt_devname);'
new = r'''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	// We won't check it anymore if boot-completed stage is triggered.
	if (susfs_is_sdcard_android_data_decrypted) {
		goto skip_checking_for_ksu_proc;
	}
	// First we must check for ksu process because of magic mount
	if (susfs_is_current_ksu_domain()) {
		// if it is unsharing, we reuse the old->mnt_id
		if (flag & CL_COPY_MNT_NS) {
			mnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);
			goto bypass_orig_flow;
		}
		// else we just go assign fake mnt_id
		mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);
		goto bypass_orig_flow;
	}
skip_checking_for_ksu_proc:
	// Lastly for other processes of which old->mnt_id == DEFAULT_KSU_MNT_ID, go assign fake mnt_id
	if (old->mnt_id == DEFAULT_KSU_MNT_ID) {
		mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);
		goto bypass_orig_flow;
	}
#endif
	mnt = alloc_vfsmnt(old->mnt_devname);
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif'''

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, 'w') as f:
        f.write(content)
    print("[+] clone_mnt SuSFS block inserted.")
else:
    print("[!] Could not find target line in clone_mnt. Manual edit required.")
    print("    Look for: mnt = alloc_vfsmnt(old->mnt_devname);")
    print("    and insert the SuSFS block before it (see .rej file for content).")
PYEOF
    else
        warn "Could not find 'mnt = alloc_vfsmnt(old->mnt_devname);' in $NAMESPACE_C."
        warn "This line may have been renamed or refactored. Manual edit required."
    fi
fi

# =============================================================================
# 2d. fs/namespace.c — Hunk at ~1202 (blank line before lock_mount_hash)
#     This is another whitespace-only change. Safe to skip.
# =============================================================================
info "Skipping $NAMESPACE_C hunk 4 (whitespace-only, no functional impact)."

# =============================================================================
# 3. fs/proc/task_mmu.c — Hunk at ~1697 (pagemap_read SuSFS SUS_MAP block)
# =============================================================================
TASK_MMU="fs/proc/task_mmu.c"
info "Patching $TASK_MMU ..."

[ -f "$TASK_MMU" ] || error "File not found: $TASK_MMU"
backup "$TASK_MMU"

if grep -q "CONFIG_KSU_SUSFS_SUS_MAP\|BIT_SUS_MAPS" "$TASK_MMU"; then
    warn "$TASK_MMU already contains SuSFS changes, skipping."
else
    # The patch inserts after: up_read(&mm->mmap_sem);
    # inside pagemap_read(), specifically before: start_vaddr = end;
    # We use python3 to do a context-aware replacement
    python3 - "$TASK_MMU" <<'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    lines = f.readlines()

target_after  = '\t\tup_read(&mm->mmap_sem);\n'
target_before = '\t\tstart_vaddr = end;\n'

insert_block = (
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

inserted = False
new_lines = []
i = 0
while i < len(lines):
    new_lines.append(lines[i])
    # Look for the up_read line followed (eventually) by start_vaddr = end
    if lines[i] == target_after and not inserted:
        # Check the next few lines for start_vaddr = end
        j = i + 1
        while j < min(i + 10, len(lines)):
            if lines[j] == target_before:
                new_lines.append(insert_block)
                inserted = True
                break
            j += 1
    i += 1

if inserted:
    with open(filepath, 'w') as f:
        f.writelines(new_lines)
    print("[+] task_mmu.c SUS_MAP block inserted.")
else:
    print("[!] Could not find insertion point in pagemap_read().")
    print("    Look for: up_read(&mm->mmap_sem); followed by start_vaddr = end;")
    print("    and insert the SuSFS block between them (see .rej file for content).")
PYEOF
fi

# =============================================================================
# Final report
# =============================================================================
echo ""
info "==================================================="
info "Done. Summary of backups:"
for f in "$BACKUP_DIR"/*.bak; do
    echo "  $f"
done
info "==================================================="
info "Next steps:"
echo "  1. Commit this script to your repo at: patches/fix3.sh"
echo "     Make sure the workflow step runs it BEFORE the SuSFS patch step:"
echo ""
echo "     - name: Fix SuSFS reject hunks"
echo "       run: bash \$GITHUB_WORKSPACE/patches/fix3.sh"
echo ""
echo "  2. Re-run your build."
echo "  3. If errors remain, check the [!] warnings above for files needing manual edits."
echo "  4. Backups of original files are in: $BACKUP_DIR/"
info "==================================================="
