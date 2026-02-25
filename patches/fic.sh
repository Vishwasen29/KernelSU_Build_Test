#!/bin/bash
set -e

KERNEL_DIR="${1:-.}"
PATCHES_DIR="${2:-$GITHUB_WORKSPACE/patches}"

cd "$KERNEL_DIR" || { echo "❌ Cannot enter kernel directory: $KERNEL_DIR"; exit 1; }

ORIG_PATCH="$PATCHES_DIR/susfs_patch_to_4.19.patch"
FIX_PATCH="$PATCHES_DIR/fix_susfs_generated.patch"

echo "=== Applying original SUSFS patch ==="
patch -Np1 < "$ORIG_PATCH" 2>&1 | tee patch_orig.log || true

echo "=== Generating fix patch ==="
cat > "$FIX_PATCH" << 'EOF'
--- a/include/linux/mount.h
+++ b/include/linux/mount.h
@@ -72,7 +72,11 @@ struct vfsmount {
 	ANDROID_KABI_RESERVE(1);
 	ANDROID_KABI_RESERVE(2);
 	ANDROID_KABI_RESERVE(3);
+#ifdef CONFIG_KSU_SUSFS
+	ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);
+#else
 	ANDROID_KABI_RESERVE(4);
+#endif
 	void *data;
 } __randomize_layout;

--- a/fs/namespace.c
+++ b/fs/namespace.c
@@ -29,6 +29,16 @@
 #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
 #include <linux/susfs_def.h>
 #endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+extern bool susfs_is_current_ksu_domain(void);
+extern bool susfs_is_sdcard_android_data_decrypted;
+
+static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);
+
+#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+
 #include "pnode.h"
 #include "internal.h"
 
@@ -1090,11 +1100,12 @@ static struct mount *clone_mnt(struct mount *old, struct dentry *root,
 	struct mount *mnt;
 	int err;
 
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+	// We won't check it anymore if boot-completed stage is triggered.
+	if (susfs_is_sdcard_android_data_decrypted) {
+		goto skip_checking_for_ksu_proc;
+	}
+	// First we must check for ksu process because of magic mount
+	if (susfs_is_current_ksu_domain()) {
+		// if it is unsharing, we reuse the old->mnt_id
+		if (flag & CL_COPY_MNT_NS) {
+			mnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);
+			goto bypass_orig_flow;
+		}
+		// else we just go assign fake mnt_id
+		mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);
+		goto bypass_orig_flow;
+	}
+skip_checking_for_ksu_proc:
+	// Lastly for other processes of which old->mnt_id == DEFAULT_KSU_MNT_ID, go assign fake mnt_id
+	if (old->mnt_id == DEFAULT_KSU_MNT_ID) {
+		mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);
+		goto bypass_orig_flow;
+	}
+#endif
 	mnt = alloc_vfsmnt(old->mnt_devname);
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+bypass_orig_flow:
+#endif
 	if (!mnt)
 		return ERR_PTR(-ENOMEM);
 
--- a/fs/proc/task_mmu.c
+++ b/fs/proc/task_mmu.c
@@ -1697,6 +1697,15 @@ static ssize_t pagemap_read(struct file *file, char __user *buf,
 			goto out_free;
 		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
 		mmap_read_unlock(mm);
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+		vma = find_vma(mm, start_vaddr);
+		if (vma && vma->vm_file) {
+			struct inode *inode = file_inode(vma->vm_file);
+			if (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {
+				pm.buffer->pme = 0;
+			}
+		}
+#endif
 		start_vaddr = end;
 
 		len = min(count, PM_ENTRY_BYTES * pm.pos);
EOF

echo "=== Applying fix patch ==="
patch -Np1 < "$FIX_PATCH" 2>&1 | tee patch_fix.log || true

echo "=== Checking for remaining rejects ==="
REJECTS=$(find . -name "*.rej" -type f)
if [ -n "$REJECTS" ]; then
    echo "❌ Some hunks still failed. Reject files:"
    ls -l $REJECTS
    exit 1
else
    echo "✅ All patches applied successfully."
fi

echo "=== Patch logs ==="
cat patch_orig.log patch_fix.log
