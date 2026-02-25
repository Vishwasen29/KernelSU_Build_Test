#!/bin/bash
set -e

# Usage: susfs_fix.sh <kernel-source-dir> <patch-file>

KERNEL_SRC="$1"
PATCH_FILE="$2"

if [ -z "$KERNEL_SRC" ] || [ -z "$PATCH_FILE" ]; then
    echo "Usage: $0 <kernel-source-dir> <patch-file>"
    exit 1
fi

if [ ! -d "$KERNEL_SRC" ]; then
    echo "❌ Kernel source not found: $KERNEL_SRC"
    exit 1
fi

if [ ! -f "$PATCH_FILE" ]; then
    echo "❌ Patch file not found: $PATCH_FILE"
    exit 1
fi

cd "$KERNEL_SRC"

echo "--------------------------------------------------"
echo " Applying SUSFS patch (STRICT mode)"
echo "--------------------------------------------------"

# Strict patch application
git apply --reject --whitespace=fix "$PATCH_FILE"

echo "✅ Patch applied successfully."

# ------------------------------------------------------------------
# Ensure susfs.o is added to fs/Makefile (safety guard)
# ------------------------------------------------------------------

if ! grep -q "susfs.o" fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
    echo "✅ Added susfs.o to fs/Makefile"
else
    echo "ℹ️ susfs.o already present in fs/Makefile"
fi

echo "--------------------------------------------------"
echo " SUSFS patch integration completed"
echo "--------------------------------------------------"
