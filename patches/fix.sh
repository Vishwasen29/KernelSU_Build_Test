#!/bin/bash
# fix.sh – Automatically applies missing hide-stuff code to fs/proc/task_mmu.c
# Run this after applying SUSFS patches (e.g., sus2.patch) to fix common rejects.

set -e
echo "🔧 Starting fix script..."

KERNEL_DIR="$GITHUB_WORKSPACE/kernel_workspace/android-kernel"
cd "$KERNEL_DIR" || { echo "❌ Cannot enter kernel directory"; exit 1; }

TASK_MMU="fs/proc/task_mmu.c"
if [ ! -f "$TASK_MMU" ]; then
    echo "❌ $TASK_MMU not found!"
    exit 1
fi

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
else
    echo "✅ show_vma_header_prefix_fake already present"
fi

# 2. Add dentry declaration after 'const char *name = NULL;'
if ! grep -q "struct dentry \*dentry;" "$TASK_MMU"; then
    echo "➕ Adding dentry declaration..."
    sed -i '/const char \*name = NULL;/a\    struct dentry *dentry;' "$TASK_MMU"
else
    echo "✅ dentry declaration already present"
fi

# 3. Add hide-stuff block after pgoff assignment
if ! grep -q "dentry = file->f_path.dentry;" "$TASK_MMU"; then
    echo "➕ Adding hide-stuff block..."
    # Find the line with pgoff assignment – it may vary, so use a flexible pattern
    line_num=$(grep -n "pgoff =.*<<" "$TASK_MMU" | head -1 | cut -d: -f1)
    if [ -n "$line_num" ]; then
        sed -i "${line_num}a\\
		dentry = file->f_path.dentry;\\
		if (dentry) {\\
			const char *path = (const char *)dentry->d_name.name;\\
			if (strstr(path, \"lineage\")) {\\
				start = vma->vm_start;\\
				end = vma->vm_end;\\
				show_vma_header_prefix(m, start, end, flags,\\
						       pgoff, dev, ino);\\
				name = \"/system/framework/framework-res.apk\";\\
				goto done;\\
			}\\
			if (strstr(path, \"jit-zygote-cache\")) {\\
				start = vma->vm_start;\\
				end = vma->vm_end;\\
				show_vma_header_prefix_fake(m, start, end,\\
							    flags, pgoff, dev,\\
							    ino);\\
				goto bypass;\\
			}\\
		}\\
" "$TASK_MMU"
    else
        echo "⚠️  Could not locate pgoff assignment; hide-stuff block NOT added."
    fi
else
    echo "✅ hide-stuff block already present"
fi

# 4. Add bypass label after show_vma_header_prefix condition
if ! grep -q "^[[:space:]]*bypass:" "$TASK_MMU"; then
    echo "➕ Adding bypass label..."
    # Find the line with show_vma_header_prefix call
    line_num=$(grep -n "show_vma_header_prefix(" "$TASK_MMU" | tail -1 | cut -d: -f1)
    if [ -n "$line_num" ]; then
        # Insert bypass: after the closing brace of the if block that contains the call
        # This is tricky; we'll add it after the return statement of that block.
        # Look for the line with "return;" after that call.
        # Simpler: add it after the line that contains "return;" within the same context.
        # We'll search for the next occurrence of "return;" after that line.
        return_line=$(sed -n "${line_num},/^[[:space:]]*return;/p" "$TASK_MMU" | grep -n "return;" | head -1 | cut -d: -f1)
        if [ -n "$return_line" ]; then
            absolute_line=$((line_num + return_line - 1))
            sed -i "${absolute_line}a\\
bypass:\\
" "$TASK_MMU"
        else
            echo "⚠️  Could not locate return after show_vma_header_prefix; bypass label NOT added."
        fi
    else
        echo "⚠️  Could not locate show_vma_header_prefix; bypass label NOT added."
    fi
else
    echo "✅ bypass label already present"
fi

echo "✅ All fixes applied successfully."
