#!/bin/bash
set -e

FILE="fs/proc/task_mmu.c"

echo "[*] Fixing unused vma variable..."

# Remove standalone declaration
sed -i '/struct vm_area_struct \*vma;/d' $FILE

# Ensure declaration exists only inside SUS_MAP block
sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_MAP/a \
        struct vm_area_struct *vma;' $FILE

echo "[✓] task_mmu.c fixed."
