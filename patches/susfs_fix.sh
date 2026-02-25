#!/usr/bin/env bash
# ============================================================================
# SUSFS CI Auto-Fix Script for Lineage 23.2 (Kernel 4.19 SM8250)
# Production safe, idempotent, validation aware
# ============================================================================

set -euo pipefail

KERNEL_DIR="$1"
PATCH_FILE="$2"

if [[ -z "${KERNEL_DIR:-}" || -z "${PATCH_FILE:-}" ]]; then
    echo "Usage: $0 <kernel_dir> <susfs_patch>"
    exit 1
fi

NS_FILE="$KERNEL_DIR/fs/namespace.c"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SUSFS CI Integration Fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ----------------------------------------------------------------------------
# STEP 1: Sanity Checks
# ----------------------------------------------------------------------------

if [[ ! -d "$KERNEL_DIR" ]]; then
    echo "❌ Kernel directory not found"
    exit 1
fi

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "❌ Patch file not found"
    exit 1
fi

if [[ ! -f "$NS_FILE" ]]; then
    echo "❌ namespace.c not found"
    exit 1
fi

# ----------------------------------------------------------------------------
# STEP 2: Remove namespace.c hunks from patch
# ----------------------------------------------------------------------------

echo "➜ Cleaning namespace.c hunks from patch..."

CLEAN_PATCH="/tmp/susfs_clean.patch"

awk '
BEGIN { skip=0 }
/^diff --git a\/fs\/namespace.c/ { skip=1 }
skip==1 && /^diff --git/ { skip=0 }
skip==0 { print }
' "$PATCH_FILE" > "$CLEAN_PATCH"

# ----------------------------------------------------------------------------
# STEP 3: Apply clean patch
# ----------------------------------------------------------------------------

echo "➜ Applying cleaned SUSFS patch..."

cd "$KERNEL_DIR"

if ! git apply --check "$CLEAN_PATCH"; then
    echo "❌ Patch still does not apply cleanly"
    exit 1
fi

git apply "$CLEAN_PATCH"

# ----------------------------------------------------------------------------
# STEP 4: Inject Lineage-safe namespace changes
# ----------------------------------------------------------------------------

echo "➜ Injecting Lineage-safe namespace modifications..."

# 4.1 Include injection
if ! grep -q "susfs_def.h" "$NS_FILE"; then
    sed -i '/#include <linux\/sched\/task.h>/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif
' "$NS_FILE"
fi

# 4.2 CL_COPY_MNT_NS define
if ! grep -q "CL_COPY_MNT_NS" "$NS_FILE"; then
    sed -i '/#define CL_COPY_UNBINDABLE/a \
#define CL_COPY_MNT_NS BIT(25)
' "$NS_FILE"
fi

# 4.3 copy_mnt_ns flag injection
if ! grep -q "copy_flags |= CL_COPY_MNT_NS" "$NS_FILE"; then
    sed -i '/copy_flags = CL_COPY_UNBINDABLE/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
    copy_flags |= CL_COPY_MNT_NS;\
#endif
' "$NS_FILE"
fi

# 4.4 mnt_id backup init
if ! grep -q "susfs_mnt_id_backup" "$NS_FILE"; then
    sed -i '/mnt->mnt.data = NULL;/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
    mnt->mnt.susfs_mnt_id_backup = 0;\
#endif
' "$NS_FILE"
fi

# ----------------------------------------------------------------------------
# STEP 5: Validation Phase
# ----------------------------------------------------------------------------

echo "➜ Validating integration..."

# 5.1 Check for reject files
if find . -name "*.rej" | grep -q .; then
    echo "❌ Reject files detected"
    find . -name "*.rej"
    exit 1
fi

# 5.2 Validate header exists
if ! grep -R "susfs_def.h" include 2>/dev/null | grep -q .; then
    echo "❌ susfs_def.h not found in include/"
    exit 1
fi

# 5.3 Validate symbol injection
if ! grep -q "CL_COPY_MNT_NS" "$NS_FILE"; then
    echo "❌ CL_COPY_MNT_NS not injected"
    exit 1
fi

# 5.4 Validate config exists
if ! grep -R "CONFIG_KSU_SUSFS" "$KERNEL_DIR" | grep -q Kconfig; then
    echo "❌ SUSFS Kconfig not found"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ SUSFS integration complete & validated"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
