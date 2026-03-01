#!/bin/bash
set -e

echo "==== Fixing KernelSU for 4.19 CAF compatibility ===="

KSU_DIR="drivers/kernelsu"

if [ ! -d "$KSU_DIR" ]; then
    echo "KernelSU directory not found!"
    exit 1
fi

ALLOWLIST="$KSU_DIR/allowlist.c"

if [ ! -f "$ALLOWLIST" ]; then
    echo "allowlist.c not found!"
    exit 1
fi

echo "[1/4] Replacing TWA_RESUME with TWA_SIGNAL..."
sed -i 's/TWA_RESUME/TWA_SIGNAL/g' "$ALLOWLIST"

echo "[2/4] Ensuring sched headers exist..."
grep -q "linux/sched.h" "$ALLOWLIST" || \
sed -i '1i #include <linux/sched.h>' "$ALLOWLIST"

grep -q "linux/sched/task.h" "$ALLOWLIST" || \
sed -i '1i #include <linux/sched/task.h>' "$ALLOWLIST"

echo "[3/4] Commenting put_task_struct if needed..."
sed -i 's/put_task_struct(tsk);/\/\/ put_task_struct(tsk);/g' "$ALLOWLIST"

echo "[4/4] Done."

echo "KernelSU 4.19 compatibility fix applied successfully."
