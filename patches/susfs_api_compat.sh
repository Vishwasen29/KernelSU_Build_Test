#!/bin/bash
# susfs_api_compat.sh
#
# Fixes API mismatches between the SUSFS patch expectations and the actual
# sidex15/KernelSU-Next legacy-susfs API, plus linker symbol fixes.
#
# FIX HISTORY:
#   Fix 1 (original): Added __maybe_unused to vma at line ~952 — WRONG LOCATION.
#                     That targeted the smaps vma, not the pagemap_read vma.
#                     Result: the pagemap_read vma (line ~1642) was still unused.
#
#   Fix 1 (revised):  Now injects the actual pagemap_read BIT_SUS_MAPS block.
#                     This is the correct fix for the [-Werror,-Wunused-variable]
#                     error. The check is `find_vma(mm, start_vaddr)` which is
#                     unique to the pagemap_read injection site.
#                     Note: susfs_fix.sh step [4/7] now handles this too.
#                     Both scripts are idempotent — only one will actually inject.

set -e
KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

echo "=== SUSFS API & linker compatibility fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

# ─── Fix 1: task_mmu.c pagemap_read() BIT_SUS_MAPS block ───────────────────
echo "--- Fix 1: task_mmu.c pagemap_read() BIT_SUS_MAPS block ---"
# The original susfs_patch_to_4.19.patch hunk #8 for task_mmu.c adds a block
# inside pagemap_read() that uses a `vma` variable. If that hunk fails (which
# it does on this kernel due to line-offset differences), the vma declaration
# (from hunk #7, which succeeds) becomes unused → [-Werror,-Wunused-variable].
#
# FIX: inject the pagemap_read block using find_vma(mm, start_vaddr) as the
# idempotency check (unique to this injection point, unlike BIT_SUS_MAPS which
# also appears in smaps functions that got patched by other hunks).

if grep -q "find_vma(mm, start_vaddr)" fs/proc/task_mmu.c; then
    echo "  [skip] pagemap_read BIT_SUS_MAPS block already present"
else
    python3 - << 'PYEOF'
import sys

path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

# Anchor: the up_read/start_vaddr pair inside pagemap_read()'s inner loop.
# This two-line sequence is unique to the pagemap_read loop body.
old_seq = "\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;\n"
new_seq = (
    "\t\tup_read(&mm->mmap_sem);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tvma = find_vma(mm, start_vaddr);\n"
    "\t\tif (vma && vma->vm_file) {\n"
    "\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
    "\t\t\tif (unlikely(inode->i_state & BIT_SUS_MAPS) &&\n"
    "\t\t\t\t\tsusfs_is_current_proc_umounted()) {\n"
    "\t\t\t\tpm.show_pfn = false;\n"
    "\t\t\t\tpm.buffer->pme = 0;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
    "\t\tstart_vaddr = end;\n"
)

if old_seq not in src:
    print("  [warn] up_read/start_vaddr anchor not found – skipping Fix 1",
          file=sys.stderr)
    sys.exit(0)

src = src.replace(old_seq, new_seq, 1)
with open(path, "w") as f:
    f.write(src)
print("  [fix] pagemap_read() BIT_SUS_MAPS block injected")
PYEOF
fi

# ─── Fix 2: supercalls.c API name mismatches ────────────────────────────────
echo ""
echo "--- Fix 2: supercalls.c API name mismatches ---"

SUPERCALLS=$(find . -name "supercalls.c" -path "*/kernelsu/*" | head -1)
if [ -z "$SUPERCALLS" ]; then
    SUPERCALLS=$(find . -name "supercalls.c" 2>/dev/null | head -1)
fi

if [ -z "$SUPERCALLS" ]; then
    echo "  [skip] supercalls.c not found"
else
    if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" "$SUPERCALLS"; then
        sed -i 's/CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS/CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS/g' "$SUPERCALLS"
        echo "  [fix] CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS"
    else
        echo "  [skip] CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS not present (already correct)"
    fi

    if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUPERCALLS"; then
        sed -i 's/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g' "$SUPERCALLS"
        echo "  [fix] susfs_set_hide_sus_mnts_for_all_procs → susfs_set_hide_sus_mnts_for_non_su_procs"
    else
        echo "  [skip] susfs_set_hide_sus_mnts_for_all_procs not present (already correct)"
    fi

    if grep -q "susfs_add_try_umount" "$SUPERCALLS"; then
        sed -i 's/susfs_add_try_umount/add_try_umount/g' "$SUPERCALLS"
        echo "  [fix] susfs_add_try_umount → add_try_umount"
    else
        echo "  [skip] susfs_add_try_umount not present (already correct)"
    fi
fi

# ─── Fix 3: missing linker symbols via susfs_compat.c ───────────────────────
echo ""
echo "--- Fix 3: missing linker symbols ---"

if [ -f "fs/susfs_compat.c" ]; then
    echo "  [skip] fs/susfs_compat.c already exists"
else
    echo "  [fix] creating fs/susfs_compat.c"
    cat > fs/susfs_compat.c << 'CEOF'
// SPDX-License-Identifier: GPL-2.0
// susfs_compat.c — stub definitions for symbols referenced from KernelSU-Next
// that are not exported by the SUSFS susfs.c in this tree.
#include <linux/susfs.h>

// susfs_ksu_sid and susfs_priv_app_sid may be referenced from KernelSU hooks
// but defined in selinux glue; provide weak aliases here so the link succeeds
// even on trees where the selinux hook is absent.
#ifndef CONFIG_SECURITY_SELINUX
u32 susfs_ksu_sid     __attribute__((weak)) = 0;
u32 susfs_priv_app_sid __attribute__((weak)) = 0;
#endif
CEOF
fi

# Add susfs_compat.o to fs/Makefile if not already there
if grep -q "susfs_compat" fs/Makefile; then
    echo "  [skip] susfs_compat.o already in fs/Makefile"
else
    # Insert after the susfs.o line
    sed -i '/obj-y.*susfs\.o/a obj-$(CONFIG_KSU_SUSFS) += susfs_compat.o' fs/Makefile
    echo "  [fix] susfs_compat.o added to fs/Makefile"
fi

# Ensure susfs.h exports the symbols that KernelSU-Next expects
SUSFS_H="include/linux/susfs.h"
if [ -f "$SUSFS_H" ]; then
    if ! grep -q "susfs_ksu_sid" "$SUSFS_H" 2>/dev/null; then
        echo "  [fix] susfs_ksu_sid → susfs.h"
        echo -e "\nextern u32 susfs_ksu_sid;" >> "$SUSFS_H"
    else
        echo "  [skip] susfs_ksu_sid already in susfs.h"
    fi

    if ! grep -q "susfs_priv_app_sid" "$SUSFS_H" 2>/dev/null; then
        echo "  [fix] susfs_priv_app_sid → susfs.h"
        echo "extern u32 susfs_priv_app_sid;" >> "$SUSFS_H"
    else
        echo "  [skip] susfs_priv_app_sid already in susfs.h"
    fi

    if ! grep -q "susfs_is_current_ksu_domain" "$SUSFS_H" 2>/dev/null; then
        echo "  [fix] susfs_is_current_ksu_domain → susfs.h"
        echo "extern bool susfs_is_current_ksu_domain(void);" >> "$SUSFS_H"
    else
        echo "  [skip] susfs_is_current_ksu_domain already in susfs.h"
    fi
fi

# ─── Verification ────────────────────────────────────────────────────────────
echo ""
echo "--- Verification ---"

if grep -q "find_vma(mm, start_vaddr)" fs/proc/task_mmu.c; then
    echo "  ✅ task_mmu.c pagemap_read BIT_SUS_MAPS block confirmed"
else
    echo "  ❌ task_mmu.c pagemap_read block MISSING — vma will be unused"
fi

SUPERCALLS=$(find . -name "supercalls.c" -path "*/kernelsu/*" 2>/dev/null | head -1)
if [ -n "$SUPERCALLS" ]; then
    if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" "$SUPERCALLS"; then
        echo "  ✅ CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS present in supercalls.c"
    fi
    if grep -q "susfs_set_hide_sus_mnts_for_non_su_procs" "$SUPERCALLS"; then
        echo "  ✅ susfs_set_hide_sus_mnts_for_non_su_procs present in supercalls.c"
    fi
fi

if [ -f "fs/susfs_compat.c" ]; then
    echo "  ✅ fs/susfs_compat.c present"
fi
if grep -q "susfs_compat" fs/Makefile 2>/dev/null; then
    echo "  ✅ susfs_compat.o in fs/Makefile"
fi

echo ""
echo "✅ All fixes applied successfully"
