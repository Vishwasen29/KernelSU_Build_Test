#!/bin/bash
# fix_reboot_kp.sh
# Fixes: drivers/kernelsu/supercalls.c:778: unused variable 'reboot_kp'
#
# Usage: bash fix_reboot_kp.sh [kernel-root-dir]

set -euo pipefail
FILE="${1:-.}/drivers/kernelsu/supercalls.c"
[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found"; exit 1; }

OLD='static struct kprobe reboot_kp = {'
NEW='static struct kprobe reboot_kp __maybe_unused = {'

if grep -qF "$NEW" "$FILE"; then
    echo "[SKIP] reboot_kp already has __maybe_unused"
elif grep -qF "$OLD" "$FILE"; then
    sed -i "s/static struct kprobe reboot_kp = {/static struct kprobe reboot_kp __maybe_unused = {/" "$FILE"
    echo "[OK]   reboot_kp → __maybe_unused"
else
    echo "[ERR]  anchor 'static struct kprobe reboot_kp' not found"; exit 1
fi
