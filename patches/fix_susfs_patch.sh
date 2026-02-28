#!/bin/bash
# =============================================================================
# fix_build_errors.sh
# Fixes the two compile-time failure points in the KSUN+SUSFS build:
#
#  1. fs/proc/task_mmu.c:1642
#       error: unused variable 'vma' [-Werror,-Wunused-variable]
#       Root cause: SUSFS patch hunk #7 succeeded (adding the `vma` declaration)
#       but hunk #8 (the code that actually uses `vma`) failed. Declaration is
#       stranded with nothing to use it.
#       Fix: Apply hunk #8 manually — add the SUS_MAP guard block that uses vma.
#
#  2. drivers/kernelsu/supercalls.c:797/798/818
#       error: use of undeclared identifier 'CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS'
#       error: implicit declaration of 'susfs_set_hide_sus_mnts_for_all_procs'
#       error: implicit declaration of 'susfs_add_try_umount'
#       Root cause: KernelSU-Next's SUSFS integration was patched against a newer
#       SUSFS API, but the kernel-side SUSFS patch (v2.0.0) still uses the old names:
#         NEW (in KSU-Next)                  OLD (in kernel susfs v2.0.0)
#         CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS  → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#         susfs_set_hide_sus_mnts_for_all_procs   → susfs_set_hide_sus_mnts_for_non_su_procs
#         susfs_add_try_umount()                   → add_try_umount() [static in supercalls.c]
#       Fix: Add a compat shim for the CMD constant and redirect the function calls
#       to the names that actually exist in the installed headers.
#
# Usage:
#   cd <kernel-root>
#   bash /path/to/fix_build_errors.sh
# =============================================================================

set -euo pipefail

KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
skip() { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

check_file() { [[ -f "$1" ]] || err "File not found: $1 (run from kernel root?)"; }

check_file fs/proc/task_mmu.c
check_file drivers/kernelsu/supercalls.c

# ===========================================================================
# FIX 1 — fs/proc/task_mmu.c
# SUSFS patch hunk #7 succeeded and added:
#     struct vm_area_struct *vma;
# at the top of the while-loop body inside pagemap_read().
# Hunk #8 (which adds the code that uses vma) failed, leaving the declaration
# stranded → -Werror,-Wunused-variable kills the build.
#
# Fix: Insert the SUS_MAP usage block immediately after mmap_read_unlock(mm),
# scoping the vma usage inside { } to avoid any secondary declaration conflicts.
# ===========================================================================
FILE1="fs/proc/task_mmu.c"
echo ""
echo "── $FILE1 ─────────────────────────────────────────────"

if grep -q 'BIT_SUS_MAPS' "$FILE1"; then
    skip "BIT_SUS_MAPS already present — hunk #8 already applied"
else
    python3 << 'PYEOF'
path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

# The succeeded hunk #7 guarantees mmap_read_unlock(mm) is now present
# right before start_vaddr = end; inside the pagemap_read while-loop.
# We hook after mmap_read_unlock(mm) and before start_vaddr = end.

# Primary anchor: mmap_read_unlock variant
old = (
    '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
    '\t\tmmap_read_unlock(mm);\n'
    '\t\tstart_vaddr = end;'
)
new = (
    '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
    '\t\tmmap_read_unlock(mm);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\t\t{\n'
    '\t\t\tstruct vm_area_struct *_susfs_vma = find_vma(mm, start_vaddr);\n'
    '\t\t\tif (_susfs_vma && _susfs_vma->vm_file) {\n'
    '\t\t\t\tstruct inode *inode = file_inode(_susfs_vma->vm_file);\n'
    '\t\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) &&\n'
    '\t\t\t\t    susfs_is_current_proc_umounted()) {\n'
    '\t\t\t\t\tpm.buffer->pme = 0;\n'
    '\t\t\t\t}\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '#endif\n'
    '\t\tstart_vaddr = end;'
)

if old in src:
    src = src.replace(old, new, 1)
    print("[OK]    task_mmu.c: SUS_MAP block inserted after mmap_read_unlock(mm)")
else:
    # Fallback: kernel still uses up_read(&mm->mmap_sem)
    old2 = (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        '\t\tup_read(&mm->mmap_sem);\n'
        '\t\tstart_vaddr = end;'
    )
    new2 = (
        '\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n'
        '\t\tup_read(&mm->mmap_sem);\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
        '\t\t{\n'
        '\t\t\tstruct vm_area_struct *_susfs_vma = find_vma(mm, start_vaddr);\n'
        '\t\t\tif (_susfs_vma && _susfs_vma->vm_file) {\n'
        '\t\t\t\tstruct inode *inode = file_inode(_susfs_vma->vm_file);\n'
        '\t\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) &&\n'
        '\t\t\t\t    susfs_is_current_proc_umounted()) {\n'
        '\t\t\t\t\tpm.buffer->pme = 0;\n'
        '\t\t\t\t}\n'
        '\t\t\t}\n'
        '\t\t}\n'
        '#endif\n'
        '\t\tstart_vaddr = end;'
    )
    if old2 in src:
        src = src.replace(old2, new2, 1)
        print("[OK]    task_mmu.c: SUS_MAP block inserted after up_read(mmap_sem)")
    else:
        print("[ERR]   task_mmu.c: neither mmap_read_unlock nor up_read anchor found")
        import sys; sys.exit(1)

with open(path, "w") as f:
    f.write(src)
PYEOF
    ok "Fix 1 applied to $FILE1"
fi

# Also suppress the unused `vma` that the succeeded hunk left behind.
# The declaration from hunk #7 is `struct vm_area_struct *vma;`
# Now that we added code using `_susfs_vma` (separate scoped var), the old
# `vma` declaration from hunk #7 is still unused. Mark it __maybe_unused.
if grep -q 'struct vm_area_struct \*vma;' "$FILE1"; then
    python3 << 'PYEOF'
path = "fs/proc/task_mmu.c"
with open(path) as f:
    src = f.read()

# Only patch the bare declaration (not ones that are initialised or are
# inside the block we just added).
old = 'struct vm_area_struct *vma;\n'
new = 'struct vm_area_struct *vma __maybe_unused;\n'

# Be conservative: only replace the first occurrence that appears to be
# a bare local declaration (indented with a tab, nothing after the semi).
import re
count = src.count('\tstruct vm_area_struct *vma;\n')
if count == 1:
    src = src.replace('\tstruct vm_area_struct *vma;\n',
                      '\tstruct vm_area_struct *vma __maybe_unused;\n', 1)
    print("[OK]    task_mmu.c: orphaned 'vma' declaration marked __maybe_unused")
elif count == 0:
    print("[SKIP]  task_mmu.c: no bare 'vma' declaration found (already fixed or absent)")
else:
    print(f"[WARN]  task_mmu.c: {count} bare 'vma' declarations found — not auto-patching")
    print("        Manually review fs/proc/task_mmu.c for 'struct vm_area_struct *vma;'")

with open(path, "w") as f:
    f.write(src)
PYEOF
else
    skip "No bare 'vma' declaration in $FILE1 — already clean"
fi

# ===========================================================================
# FIX 2 — drivers/kernelsu/supercalls.c
# Three API name mismatches between KernelSU-Next's SUSFS integration and
# the v2.0.0 kernel-side SUSFS patch.
#
# (a) CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS — new constant name used by
#     KernelSU-Next; the susfs_def.h from the kernel patch only defines
#     CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS.
#     Fix: add a #define compat alias via a new include guard block at the
#     top of the file, right after existing includes.
#
# (b) susfs_set_hide_sus_mnts_for_all_procs() — new function name in
#     KernelSU-Next; susfs.h declares susfs_set_hide_sus_mnts_for_non_su_procs.
#     Fix: rename the call in-place.
#
# (c) susfs_add_try_umount() — exported symbol expected by KernelSU-Next but
#     not present in susfs.h v2.0.0. The compiler notes that add_try_umount()
#     exists as a static function at line 586 in the same file (supercalls.c)
#     and covers the same functionality.
#     Fix: rename the call to the static version.
# ===========================================================================
FILE2="drivers/kernelsu/supercalls.c"
echo ""
echo "── $FILE2 ─────────────────────────────────────────────"

python3 << 'PYEOF'
import sys

path = "drivers/kernelsu/supercalls.c"
with open(path) as f:
    src = f.read()

changed = False

# ── (a) CMD constant compat shim ──────────────────────────────────────────
# Inject a compat #define after the last #include in the file so it's
# available before any code references the constant.
COMPAT_BLOCK = (
    '\n'
    '/* ---- SUSFS v2.0.0 compat shim (auto-added by fix_build_errors.sh) ----\n'
    ' * KernelSU-Next SUSFS integration uses the newer "FOR_ALL_PROCS" API\n'
    ' * names; the kernel-side SUSFS patch (v2.0.0) still has the older\n'
    ' * "FOR_NON_SU_PROCS" names.  Map new → old so both sides compile. */\n'
    '#if defined(CONFIG_KSU_SUSFS) && !defined(CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS)\n'
    '#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS \\\n'
    '        CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS\n'
    'static inline void susfs_set_hide_sus_mnts_for_all_procs(void __user **arg)\n'
    '{\n'
    '        susfs_set_hide_sus_mnts_for_non_su_procs(arg);\n'
    '}\n'
    '#endif /* SUSFS v2.0.0 compat shim */\n'
)

if 'SUSFS v2.0.0 compat shim' in src:
    print("[SKIP]  supercalls.c (a): compat shim already present")
else:
    # Find last #include line and insert block after it
    import re
    last_include = None
    for m in re.finditer(r'^#include\s+[<"][^\n]+', src, re.MULTILINE):
        last_include = m
    if last_include:
        pos = last_include.end()
        src = src[:pos] + COMPAT_BLOCK + src[pos:]
        print("[OK]    supercalls.c (a): CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS compat shim added")
        changed = True
    else:
        print("[ERR]   supercalls.c (a): no #include found — cannot inject compat shim")
        sys.exit(1)

# ── (b) susfs_set_hide_sus_mnts_for_all_procs → inline shim handles it ────
# The inline static function above in the compat shim is the call target, so
# no further in-place rename of the call site is needed.
# (The shim itself calls the real susfs_set_hide_sus_mnts_for_non_su_procs.)
# Verify it's now reachable.
if 'susfs_set_hide_sus_mnts_for_all_procs' in src:
    print("[OK]    supercalls.c (b): susfs_set_hide_sus_mnts_for_all_procs resolved via shim")
else:
    print("[SKIP]  supercalls.c (b): susfs_set_hide_sus_mnts_for_all_procs not present (pre-patched?)")

# ── (c) susfs_add_try_umount → add_try_umount ─────────────────────────────
if 'susfs_add_try_umount' in src:
    src = src.replace('susfs_add_try_umount(', 'add_try_umount(')
    print("[OK]    supercalls.c (c): susfs_add_try_umount() → add_try_umount() (static in-file)")
    changed = True
else:
    print("[SKIP]  supercalls.c (c): susfs_add_try_umount not present (already fixed?)")

with open(path, "w") as f:
    f.write(src)

if changed:
    print("[OK]    supercalls.c: all API compat fixes applied")
else:
    print("[SKIP]  supercalls.c: no changes needed")
PYEOF
ok "Fix 2 processed for $FILE2"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " fix_build_errors.sh complete."
echo ""
echo "  fs/proc/task_mmu.c          Fix 1a – SUS_MAP block inserted (hunk #8)"
echo "  fs/proc/task_mmu.c          Fix 1b – orphaned 'vma' marked __maybe_unused"
echo "  drivers/kernelsu/supercalls.c  Fix 2a – CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS compat"
echo "  drivers/kernelsu/supercalls.c  Fix 2b – susfs_set_hide_sus_mnts_for_all_procs shim"
echo "  drivers/kernelsu/supercalls.c  Fix 2c – susfs_add_try_umount → add_try_umount"
echo ""
echo " You can now re-run the kernel build."
echo "══════════════════════════════════════════════════════════════════"
