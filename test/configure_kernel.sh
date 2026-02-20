#!/usr/bin/env bash
# =============================================================================
# configure_kernel.sh
#
# Generates the defconfig then enables KSU + SUSFS in two ordered passes.
#
# Ordering matters:
#   Pass 1 — enable KSU base options, run olddefconfig to resolve their deps
#   Pass 2 — enable all SUSFS features   (Kconfig entries must already exist,
#             see add_susfs_kconfig.sh)  then run olddefconfig again to bake
#
# Without the two-pass approach, olddefconfig in pass 1 can silently reset
# SUSFS options whose parent (KSU) hadn't been confirmed yet.
#
# Usage: bash configure_kernel.sh <kernel-root> <clang-bin-dir>
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-.}"
CLANG_BIN="${2:-}"
DEFCONFIG="${3:-vendor/kona-perf_defconfig}"

export ARCH=arm64
export SUBARCH=arm64

if [[ -n "$CLANG_BIN" ]]; then
  export PATH="$CLANG_BIN:$PATH"
fi

MAKE="make O=out CC=clang CLANG_TRIPLE=aarch64-linux-gnu- LD=ld.lld LLVM=1"
CONFIG="$KERNEL_ROOT/out/.config"

cd "$KERNEL_ROOT"

# ── Step 1: generate base defconfig ─────────────────────────────────────────
echo "[1/3] Generating $DEFCONFIG"
$MAKE "$DEFCONFIG"

# ── Step 2: KSU base + required dependencies ─────────────────────────────────
echo "[2/3] Enabling KSU base options"
scripts/config --file "$CONFIG" \
  -e KSU           \
  -e KSU_MANUAL_HOOK \
  -e MODULES       \
  -e OVERLAY_FS

$MAKE olddefconfig
echo "      KSU base → done"

# ── Step 3: SUSFS feature set ────────────────────────────────────────────────
echo "[3/3] Enabling SUSFS options"
scripts/config --file "$CONFIG" \
  -e KSU_SUSFS                  \
  -e KSU_SUSFS_HAS_MAGIC_MOUNT  \
  -e KSU_SUSFS_SUS_PATH         \
  -e KSU_SUSFS_SUS_MOUNT        \
  -e KSU_SUSFS_SUS_KSTAT        \
  -e KSU_SUSFS_SUS_OVERLAYFS    \
  -e KSU_SUSFS_TRY_UMOUNT       \
  -e KSU_SUSFS_SPOOF_UNAME      \
  -e KSU_SUSFS_OPEN_REDIRECT    \
  -e KSU_SUSFS_ENABLE_LOG       \
  -e KSU_SUSFS_SUS_SU           \
  -e KSU_SUSFS_SUS_MAP

$MAKE olddefconfig
echo "      SUSFS options → done"

# ── Sanity check — fail early rather than waste a full compile ───────────────
echo ""
echo "=== CONFIG_KSU_SUSFS* in out/.config ==="
if grep "CONFIG_KSU_SUSFS" "$CONFIG"; then
  echo "[OK] All SUSFS config entries present"
else
  echo "[FATAL] No CONFIG_KSU_SUSFS entries found in out/.config"
  echo "        Did add_susfs_kconfig.sh run before this script?"
  exit 1
fi
