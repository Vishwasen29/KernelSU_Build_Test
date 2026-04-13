#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
PATCH_PATH="${2:-$(dirname "$0")/susfix-419-lineage-sm8250-compat.patch}"
HOOK_SCRIPT="${3:-$(dirname "$0")/kernel-4.19-kernelsu-next-legacy-hooks-v5.sh}"

cd "$ROOT"

log() { printf '%s\n' "$*"; }

if [ ! -f "$PATCH_PATH" ]; then
  echo "Patch not found: $PATCH_PATH" >&2
  exit 1
fi
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "Hook script not found: $HOOK_SCRIPT" >&2
  exit 1
fi

DRIVER_DIR=""
if [ -d common/drivers ]; then
  DRIVER_DIR="common/drivers"
elif [ -d drivers ]; then
  DRIVER_DIR="drivers"
else
  echo "Could not find drivers directory" >&2
  exit 1
fi

if [ ! -d KernelSU-Next ]; then
  git clone https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next
fi

git -C KernelSU-Next fetch --all --tags
if git -C KernelSU-Next rev-parse --verify legacy_susfs >/dev/null 2>&1; then
  git -C KernelSU-Next checkout legacy_susfs
else
  git -C KernelSU-Next checkout -B legacy_susfs origin/legacy_susfs
fi

mkdir -p "$DRIVER_DIR"
REL_TARGET="../KernelSU-Next/kernel"
[ "$DRIVER_DIR" = "common/drivers" ] && REL_TARGET="../../KernelSU-Next/kernel"
ln -snf "$REL_TARGET" "$DRIVER_DIR/kernelsu"

grep -q 'kernelsu' "$DRIVER_DIR/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_DIR/Makefile"
SOURCE_LINE="source \"$DRIVER_DIR/kernelsu/Kconfig\""
grep -Fq "$SOURCE_LINE" "$DRIVER_DIR/Kconfig" || printf '\n%s\n' "$SOURCE_LINE" >> "$DRIVER_DIR/Kconfig"

git apply --check "$PATCH_PATH"
git apply "$PATCH_PATH"

bash "$HOOK_SCRIPT" .

log '[+] KernelSU-Next legacy_susfs integrated under drivers/kernelsu'
log '[+] SUSFS compat patch applied'
log '[+] Legacy manual hooks applied'
log '[+] Added TRY_UMOUNT compatibility by routing CONFIG_KSU_SUSFS_TRY_UMOUNT to KernelSU add_try_umount()'
log '[+] Added path_umount compatibility for legacy 4.19 trees'
log '[!] For manual hook mode, set CONFIG_KSU_MANUAL_HOOK=y and disable CONFIG_KSU_KPROBES_HOOK.'
log '[!] Review with: git diff --stat'
