#!/bin/bash
# fix_susfs_files.sh - Insert SUSFS hooks into task_mmu.c and namespace.c using sed

set -e

cd "$(dirname "$0")/../kernel_workspace/android-kernel" || exit 1

# ----------------------------------------------------------------------
# Fix fs/proc/task_mmu.c
# ----------------------------------------------------------------------
TASK_MMU="fs/proc/task_mmu.c"

echo "Patching $TASK_MMU ..."

# 1. Add includes after the last #include
sed -i '/^#include/!b;:a;n;/^#include/ba;i\
#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP)\
#include <linux/susfs_def.h>\
#endif' "$TASK_MMU"

# 2. Add extern after show_vma_header_prefix
sed -i '/^static void show_vma_header_prefix.*/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\
extern void susfs_sus_ino_for_show_map_vma(unsigned long ino, dev_t *out_dev, unsigned long *out_ino);\
#endif' "$TASK_MMU"

# 3. Modify show_map_vma: replace the file block
sed -i '/^[[:space:]]*if (file) {/,/^[[:space:]]*pgoff = /c\
	if (file) {\
		struct inode *inode = file_inode(vma->vm_file);\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
		if (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\
			seq_setwidth(m, 25 + sizeof(void *) * 6 - 1);\
			seq_put_hex_ll(m, NULL, vma->vm_start, 8);\
			seq_put_hex_ll(m, "-", vma->vm_end, 8);\
			seq_putc(m, ' ');\
			seq_putc(m, '-');\
			seq_putc(m, '-');\
			seq_putc(m, '-');\
			seq_putc(m, 'p');\
			seq_put_hex_ll(m, " ", pgoff, 8);\
			seq_put_hex_ll(m, " ", MAJOR(dev), 2);\
			seq_put_hex_ll(m, ":", MINOR(dev), 2);\
			seq_put_decimal_ull(m, " ", ino);\
			seq_putc(m, ' ');\
			goto done;\
		}\
#endif\
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\
		if (unlikely(inode->i_mapping->flags & BIT_SUS_KSTAT)) {\
			susfs_sus_ino_for_show_map_vma(inode->i_ino, &dev, &ino);\
			goto bypass_orig_flow;\
		}\
#endif\
		dev = inode->i_sb->s_dev;\
		ino = inode->i_ino;\
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\
bypass_orig_flow:\
#endif\
		pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\
	}' "$TASK_MMU"

# 4. Insert SUSFS_MAP block in show_smap after memset
sed -i '/memset(&mss, 0, sizeof(mss));/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
	if (vma->vm_file &&\
		unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&\
		susfs_is_current_proc_umounted())\
	{\
		smap_gather_stats(vma, &mss);\
\
		show_map_vma(m, vma);\
		if (vma_get_anon_name(vma)) {\
			seq_puts(m, "Name:           ");\
			seq_print_vma_name(m, vma);\
		}\
\
		SEQ_PUT_DEC("Size:           ", vma->vm_end - vma->vm_start);\
		SEQ_PUT_DEC(" kB\\nKernelPageSize: ", vma_kernel_pagesize(vma));\
		SEQ_PUT_DEC(" kB\\nMMUPageSize:    ", vma_mmu_pagesize(vma));\
		seq_puts(m, " kB\\n");\
\
		__show_smap(m, &mss);\
\
		seq_printf(m, "THPeligible:    %d\\n", transparent_hugepage_enabled(vma));\
\
		if (arch_pkeys_enabled())\
			seq_printf(m, "ProtectionKey:  %8u\\n", vma_pkey(vma));\
\
		goto bypass_orig_flow;\
	}\
#endif' "$TASK_MMU"

# 5. Add bypass label after arch_pkeys_enabled block
sed -i '/if (arch_pkeys_enabled())/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
bypass_orig_flow:\
#endif' "$TASK_MMU"

# 6. Modify show_smaps_rollup loop
sed -i '/for (vma = priv->mm->mmap; vma; vma = vma->vm_next) {/,/^[[:space:]]*}/c\
	for (vma = priv->mm->mmap; vma; vma = vma->vm_next) {\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
		if (vma->vm_file &&\
			unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&\
			susfs_is_current_proc_umounted())\
		{\
			memset(&mss, 0, sizeof(mss));\
			goto bypass_orig_flow;\
		}\
#endif\
		smap_gather_stats(vma, &mss);\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
bypass_orig_flow:\
#endif\
		last_vma_end = vma->vm_end;\
	}' "$TASK_MMU"

# 7. Add variable in pagemap_read
sed -i '/^ssize_t pagemap_read/,/^$/ {
    /^[[:space:]]*int ret = 0, copied = 0;/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
	struct vm_area_struct *vma;\
#endif
}' "$TASK_MMU"

# 8. Add the zeroing logic after up_read
sed -i '/up_read(&mm->mmap_sem);/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
		vma = find_vma(mm, start_vaddr);\
		if (vma && vma->vm_file) {\
			struct inode *inode = file_inode(vma->vm_file);\
			if (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\
				pm.buffer->pme = 0;\
			}\
		}\
#endif' "$TASK_MMU"

echo "  -> $TASK_MMU fixed"

# ----------------------------------------------------------------------
# Fix fs/namespace.c
# ----------------------------------------------------------------------
NAMESPACE_C="fs/namespace.c"

echo "Patching $NAMESPACE_C ..."

# 1. Add includes after last #include
sed -i '/^#include/!b;:a;n;/^#include/ba;i\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif' "$NAMESPACE_C"

# 2. Add definitions after includes
sed -i '/^#include.*/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern bool susfs_is_sdcard_android_data_decrypted;\
\
static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\
\
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\
#endif' "$NAMESPACE_C"

# 3. Replace mnt_free_id
sed -i '/^static void mnt_free_id/,/^}/c\
static void mnt_free_id(struct mount *mnt)\
{\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
	// First we have to check if susfs_mnt_id_backup == DEFAULT_KSU_MNT_ID,\
	// if so, no need to free.\
	if (mnt->mnt.susfs_mnt_id_backup == DEFAULT_KSU_MNT_ID) {\
		return;\
	}\
	// Second if susfs_mnt_id_backup was set after mnt_id reorder, free it if so.\
	if (likely(mnt->mnt.susfs_mnt_id_backup)) {\
		ida_free(&mnt_id_ida, mnt->mnt.susfs_mnt_id_backup);\
		return;\
	}\
#endif\
	ida_free(&mnt_id_ida, mnt->mnt_id);\
}' "$NAMESPACE_C"

# 4. Replace mnt_alloc_group_id
sed -i '/^static int mnt_alloc_group_id/,/^}/c\
static int mnt_alloc_group_id(struct mount *mnt)\
{\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
	int res;\
\
	/* - mnt_alloc_group_id will unlikely get called after screen is unlocked on reboot,\
	 *   so here we can persistently check if current is ksu domain, and assign a sus\
	 *   mnt_group_id if so.\
	 * - Also we can re-use the original mnt_group_ida so there is no need to use\
	 *   another ida nor hook the mnt_release_group_id() function.\
	 */\
	if (susfs_is_current_ksu_domain()) {\
		res = ida_alloc_min(&mnt_group_ida, DEFAULT_KSU_MNT_GROUP_ID, GFP_KERNEL);\
		goto bypass_orig_flow;\
	}\
	res = ida_alloc_min(&mnt_group_ida, 1, GFP_KERNEL);\
bypass_orig_flow:\
#else\
	int res = ida_alloc_min(&mnt_group_ida, 1, GFP_KERNEL);\
#endif\
\
	if (res < 0)\
		return res;\
	mnt->mnt_group_id = res;\
	return 0;\
}' "$NAMESPACE_C"

# 5. Insert helper functions before alloc_vfsmnt
sed -i '/^static struct mount \*alloc_vfsmnt/,/^}/i\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
/* A copy of alloc_vfsmnt() but reuse the original mnt_id to mnt */\
static struct mount *susfs_reuse_sus_vfsmnt(const char *name, int orig_mnt_id)\
{\
	struct mount *mnt = kmem_cache_zalloc(mnt_cache, GFP_KERNEL);\
	if (mnt) {\
		mnt->mnt_id = orig_mnt_id;\
\
		if (name) {\
			mnt->mnt_devname = kstrdup_const(name,\
											 GFP_KERNEL_ACCOUNT);\
			if (!mnt->mnt_devname)\
				goto out_free_cache;\
		}\
\
		#ifdef CONFIG_SMP\
		mnt->mnt_pcp = alloc_percpu(struct mnt_pcp);\
		if (!mnt->mnt_pcp)\
			goto out_free_devname;\
\
		this_cpu_add(mnt->mnt_pcp->mnt_count, 1);\
		#else\
		mnt->mnt_count = 1;\
		mnt->mnt_writers = 0;\
		#endif\
		mnt->mnt.data = NULL;\
\
		// Makes ida_free() easier to determine whether it should free the mnt_id or not\
		mnt->mnt.susfs_mnt_id_backup = DEFAULT_KSU_MNT_ID;\
\
		INIT_HLIST_NODE(&mnt->mnt_hash);\
		INIT_LIST_HEAD(&mnt->mnt_child);\
		INIT_LIST_HEAD(&mnt->mnt_mounts);\
		INIT_LIST_HEAD(&mnt->mnt_list);\
		INIT_LIST_HEAD(&mnt->mnt_expire);\
		INIT_LIST_HEAD(&mnt->mnt_share);\
		INIT_LIST_HEAD(&mnt->mnt_slave_list);\
		INIT_LIST_HEAD(&mnt->mnt_slave);\
		INIT_HLIST_NODE(&mnt->mnt_mp_list);\
		INIT_LIST_HEAD(&mnt->mnt_umounting);\
		init_fs_pin(&mnt->mnt_umount, drop_mountpoint);\
	}\
	return mnt;\
\
	#ifdef CONFIG_SMP\
	out_free_devname:\
	kfree_const(mnt->mnt_devname);\
	#endif\
	out_free_cache:\
	kmem_cache_free(mnt_cache, mnt);\
	return NULL;\
}\
\
/* A copy of alloc_vfsmnt() but allocates the fake mnt_id to mnt */\
static struct mount *susfs_alloc_sus_vfsmnt(const char *name)\
{\
	struct mount *mnt = kmem_cache_zalloc(mnt_cache, GFP_KERNEL);\
	if (mnt) {\
		mnt->mnt_id = DEFAULT_KSU_MNT_ID;\
\
		if (name) {\
			mnt->mnt_devname = kstrdup_const(name,\
											 GFP_KERNEL_ACCOUNT);\
			if (!mnt->mnt_devname)\
				goto out_free_cache;\
		}\
\
		#ifdef CONFIG_SMP\
		mnt->mnt_pcp = alloc_percpu(struct mnt_pcp);\
		if (!mnt->mnt_pcp)\
			goto out_free_devname;\
\
		this_cpu_add(mnt->mnt_pcp->mnt_count, 1);\
		#else\
		mnt->mnt_count = 1;\
		mnt->mnt_writers = 0;\
		#endif\
		mnt->mnt.data = NULL;\
		// Makes ida_free() easier to determine whether it should free the mnt_id or not\
		mnt->mnt.susfs_mnt_id_backup = DEFAULT_KSU_MNT_ID;\
\
		INIT_HLIST_NODE(&mnt->mnt_hash);\
		INIT_LIST_HEAD(&mnt->mnt_child);\
		INIT_LIST_HEAD(&mnt->mnt_mounts);\
		INIT_LIST_HEAD(&mnt->mnt_list);\
		INIT_LIST_HEAD(&mnt->mnt_expire);\
		INIT_LIST_HEAD(&mnt->mnt_share);\
		INIT_LIST_HEAD(&mnt->mnt_slave_list);\
		INIT_LIST_HEAD(&mnt->mnt_slave);\
		INIT_HLIST_NODE(&mnt->mnt_mp_list);\
		INIT_LIST_HEAD(&mnt->mnt_umounting);\
		init_fs_pin(&mnt->mnt_umount, drop_mountpoint);\
	}\
	return mnt;\
\
	#ifdef CONFIG_SMP\
	out_free_devname:\
	kfree_const(mnt->mnt_devname);\
	#endif\
	out_free_cache:\
	kmem_cache_free(mnt_cache, mnt);\
	return NULL;\
}\
#endif' "$NAMESPACE_C"

# 6. Replace clone_mnt function
sed -i '/^static struct mount \*clone_mnt/,/^}/c\
static struct mount *clone_mnt(struct mount *old, struct dentry *root,\
					int flag)\
{\
	struct super_block *sb;\
	struct mount *mnt;\
	int err;\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
	// We won'\''t check it anymore if boot-completed stage is triggered.\
	if (susfs_is_sdcard_android_data_decrypted) {\
		goto skip_checking_for_ksu_proc;\
	}\
	// First we must check for ksu process because of magic mount\
	if (susfs_is_current_ksu_domain()) {\
		// if it is unsharing, we reuse the old->mnt_id\
		if (flag & CL_COPY_MNT_NS) {\
			mnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);\
			goto bypass_orig_flow;\
		}\
		// else we just go assign fake mnt_id\
		mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\
		goto bypass_orig_flow;\
	}\
skip_checking_for_ksu_proc:\
	// Lastly for other processes of which old->mnt_id == DEFAULT_KSU_MNT_ID, go assign fake mnt_id\
	if (old->mnt_id == DEFAULT_KSU_MNT_ID) {\
		mnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\
		goto bypass_orig_flow;\
	}\
#endif\
\
	sb = old->mnt.mnt_sb;\
	mnt = alloc_vfsmnt(old->mnt_devname);\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
bypass_orig_flow:\
#endif\
	if (!mnt)\
		return ERR_PTR(-ENOMEM);\
\
	if (sb->s_op->clone_mnt_data) {\
		mnt->mnt.data = sb->s_op->clone_mnt_data(old->mnt.data);\
		if (!mnt->mnt.data) {\
			err = -ENOMEM;\
			goto out_free;\
		}\
	}\
\
	if (flag & (CL_SLAVE | CL_PRIVATE | CL_SHARED_TO_SLAVE))\
		mnt->mnt_group_id = 0; /* not a peer of original */\
	else\
		mnt->mnt_group_id = old->mnt_group_id;\
\
	if ((flag & CL_MAKE_SHARED) && !mnt->mnt_group_id) {\
		err = mnt_alloc_group_id(mnt);\
		if (err)\
			goto out_free;\
	}\
\
	mnt->mnt.mnt_flags = old->mnt.mnt_flags;\
	mnt->mnt.mnt_flags &= ~(MNT_WRITE_HOLD|MNT_MARKED|MNT_INTERNAL);\
	/* Don'\''t allow unprivileged users to change mount flags */\
	if (flag & CL_UNPRIVILEGED) {\
		mnt->mnt.mnt_flags |= MNT_LOCK_ATIME;\
\
		if (mnt->mnt.mnt_flags & MNT_READONLY)\
			mnt->mnt.mnt_flags |= MNT_LOCK_READONLY;\
\
		if (mnt->mnt.mnt_flags & MNT_NODEV)\
			mnt->mnt.mnt_flags |= MNT_LOCK_NODEV;\
\
		if (mnt->mnt.mnt_flags & MNT_NOSUID)\
			mnt->mnt.mnt_flags |= MNT_LOCK_NOSUID;\
\
		if (mnt->mnt.mnt_flags & MNT_NOEXEC)\
			mnt->mnt.mnt_flags |= MNT_LOCK_NOEXEC;\
	}\
\
	/* Don'\''t allow unprivileged users to reveal what is under a mount */\
	if ((flag & CL_UNPRIVILEGED) &&\
	    (!(flag & CL_EXPIRE) || list_empty(&old->mnt_expire)))\
		mnt->mnt.mnt_flags |= MNT_LOCKED;\
\
	atomic_inc(&sb->s_active);\
	mnt->mnt.mnt_sb = sb;\
	mnt->mnt.mnt_root = dget(root);\
	mnt->mnt_mountpoint = mnt->mnt.mnt_root;\
	mnt->mnt_parent = mnt;\
	lock_mount_hash();\
	list_add_tail(&mnt->mnt_instance, &sb->s_mounts);\
	unlock_mount_hash();\
\
	if ((flag & CL_SLAVE) ||\
	    ((flag & CL_SHARED_TO_SLAVE) && IS_MNT_SHARED(old))) {\
		list_add(&mnt->mnt_slave, &old->mnt_slave_list);\
		mnt->mnt_master = old;\
		CLEAR_MNT_SHARED(mnt);\
	} else if (!(flag & CL_PRIVATE)) {\
		if ((flag & CL_MAKE_SHARED) || IS_MNT_SHARED(old))\
			list_add(&mnt->mnt_share, &old->mnt_share);\
		if (IS_MNT_SLAVE(old))\
			list_add(&mnt->mnt_slave, &old->mnt_slave);\
		mnt->mnt_master = old->mnt_master;\
	} else {\
		CLEAR_MNT_SHARED(mnt);\
	}\
	if (flag & CL_MAKE_SHARED)\
		set_mnt_shared(mnt);\
\
	/* stick the duplicate mount on the same expiry list\
	 * as the original if that was on one */\
	if (flag & CL_EXPIRE) {\
		if (!list_empty(&old->mnt_expire))\
			list_add(&mnt->mnt_expire, &old->mnt_expire);\
	}\
\
	return mnt;\
\
 out_free:\
	mnt_free_id(mnt);\
	free_vfsmnt(mnt);\
	return ERR_PTR(err);\
}' "$NAMESPACE_C"

# 7. Add CL_COPY_MNT_NS flag to copy_mnt_ns
sed -i '/copy_flags = CL_COPY_UNBINDABLE | CL_EXPIRE;/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
	copy_flags |= CL_COPY_MNT_NS;\
#endif' "$NAMESPACE_C"

# 8. Append susfs_reorder_mnt_id at end
if ! grep -q 'void susfs_reorder_mnt_id' "$NAMESPACE_C"; then
    cat >> "$NAMESPACE_C" << 'EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
/* Reorder the mnt_id after all sus mounts are umounted during ksu_handle_setuid() */
void susfs_reorder_mnt_id(void) {
	struct mnt_namespace *mnt_ns = current->nsproxy->mnt_ns;
	struct mount *mnt;
	int first_mnt_id = 0;

	if (!mnt_ns) {
		return;
	}

	// Do not reorder the mnt_id if there is no any ksu mount at all
	if (atomic64_read(&susfs_ksu_mounts) == 0) {
		return;
	}

	get_mnt_ns(mnt_ns);
	first_mnt_id = list_first_entry(&mnt_ns->list, struct mount, mnt_list)->mnt_id;
	list_for_each_entry(mnt, &mnt_ns->list, mnt_list) {
		// It is very important that we don't reorder the sus mount if it is not umounted
		if (mnt->mnt_id == DEFAULT_KSU_MNT_ID) {
			continue;
		}
		WRITE_ONCE(mnt->mnt.susfs_mnt_id_backup, READ_ONCE(mnt->mnt_id));
		WRITE_ONCE(mnt->mnt_id, first_mnt_id++);
	}
	put_mnt_ns(mnt_ns);
}
#endif
EOF
fi

echo "  -> $NAMESPACE_C fixed"
