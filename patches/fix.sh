#!/bin/bash
# fix_patches.sh – Fixes patch rejects and adds missing hide-stuff code

set -e

cd "$GITHUB_WORKSPACE/device_kernel" || exit 1

echo "🔧 Removing leftover .rej files (they are already applied or irrelevant)..."
find . -name "*.rej" -delete

TASK_MMU="fs/proc/task_mmu.c"

# 1. Add show_vma_header_prefix_fake function if missing
if ! grep -q "show_vma_header_prefix_fake" "$TASK_MMU"; then
    echo "➕ Adding show_vma_header_prefix_fake..."
    sed -i '/^static void show_vma_header_prefix/,/^}/ {
        /^}/a\
\
static void show_vma_header_prefix_fake(struct seq_file *m,\
					unsigned long start,\
					unsigned long end, vm_flags_t flags,\
					unsigned long long pgoff, dev_t dev,\
					unsigned long ino)\
{\
	seq_setwidth(m, 25 + sizeof(void *) * 6 - 1);\
	seq_printf(m, "%08lx-%08lx %c%c%c%c %08llx %02x:%02x %lu ", start,\
		   end, flags & VM_READ ? '\''r'\'' : '\''-'\'',\
		   flags & VM_WRITE ? '\''w'\'' : '\''-'\'', flags & VM_EXEC ? '\''-'\'' : '\''-'\'',\
		   flags & VM_MAYSHARE ? '\''s'\'' : '\''p'\'', pgoff, MAJOR(dev),\
		   MINOR(dev), ino);\
}\
' "$TASK_MMU"
fi

# 2. Add dentry declaration after 'const char *name = NULL;'
if ! grep -q "struct dentry \*dentry;" "$TASK_MMU"; then
    echo "➕ Adding dentry declaration..."
    sed -i '/const char \*name = NULL;/a\    struct dentry *dentry;' "$TASK_MMU"
fi

# 3. Add hide-stuff block after pgoff assignment
if ! grep -q "dentry = file->f_path.dentry;" "$TASK_MMU"; then
    echo "➕ Adding hide-stuff block..."
    sed -i '/pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;/a\
		dentry = file->f_path.dentry;\
		if (dentry) {\
			const char *path = (const char *)dentry->d_name.name;\
			if (strstr(path, "lineage")) {\
				start = vma->vm_start;\
				end = vma->vm_end;\
				show_vma_header_prefix(m, start, end, flags,\
						       pgoff, dev, ino);\
				name = "/system/framework/framework-res.apk";\
				goto done;\
			}\
			if (strstr(path, "jit-zygote-cache")) {\
				start = vma->vm_start;\
				end = vma->vm_end;\
				show_vma_header_prefix_fake(m, start, end,\
							    flags, pgoff, dev,\
							    ino);\
				goto bypass;\
			}\
		}\
' "$TASK_MMU"
fi

# 4. Add bypass label after the show_vma_header_prefix if statement
if ! grep -q "^bypass:" "$TASK_MMU"; then
    echo "➕ Adding bypass label..."
    sed -i '/if (show_vma_header_prefix(m, start, end, flags, pgoff, dev, ino))/,/return;/ {
        /return;/a\
bypass:
    }' "$TASK_MMU"
fi

echo "✅ All fixes applied successfully."
