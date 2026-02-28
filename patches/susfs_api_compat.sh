#!/bin/bash
# susfs_api_compat.sh
#
# Combined SUSFS compatibility fix. Four classes of build errors:
#
# Fix 1: fs/proc/task_mmu.c — "unused variable 'vma'"
# Fix 2: drivers/kernelsu/supercalls.c — 3 renamed API symbols (rsuntk only)
# Fix 3: fs/susfs_compat.c — 3 missing linker symbols
# Fix 4: fs/susfs.c — fsnotify API mismatch (2 errors):
#   a) susfs_handle_sdcard_inode_event has extra fsnotify_mark* params
#      that this 4.19 kernel's fsnotify_ops.handle_event doesn't include
#   b) fsnotify_add_mark() called with wrong args (inode* instead of
#      fsnotify_connp_t*, missing FSNOTIFY_OBJ_TYPE_INODE)
#
# Usage:
#   bash susfs_api_compat.sh [path/to/android-kernel]

set -e
KERNEL_ROOT="${1:-.}"
TASK_MMU="${KERNEL_ROOT}/fs/proc/task_mmu.c"
SUPERCALLS="${KERNEL_ROOT}/drivers/kernelsu/supercalls.c"
SUSFS_H="${KERNEL_ROOT}/include/linux/susfs.h"
SUSFS_C="${KERNEL_ROOT}/fs/susfs.c"
FS_MAKEFILE="${KERNEL_ROOT}/fs/Makefile"
COMPAT_C="${KERNEL_ROOT}/fs/susfs_compat.c"

echo "=== SUSFS API & linker compatibility fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

for f in "$SUSFS_H" "$FS_MAKEFILE"; do
    [ -f "$f" ] || { echo "ERROR: required file not found: $f"; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: task_mmu.c — __maybe_unused on the SUSFS-added vma declaration
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 1: task_mmu.c unused 'vma' variable ---"
if [ -f "$TASK_MMU" ]; then
    python3 << PYEOF
import sys
path = "$TASK_MMU"
with open(path, "r") as f:
    lines = f.readlines()

LOOKAHEAD = 30
target_idx = None
guard_line = None

for i, line in enumerate(lines):
    stripped = line.strip()
    if ("vm_area_struct" in stripped and
            ("*vma;" in stripped or "* vma;" in stripped) and
            "__maybe_unused" not in stripped):
        for j in range(i + 1, min(len(lines), i + LOOKAHEAD)):
            if "CONFIG_KSU_SUSFS_SUS_MAP" in lines[j]:
                target_idx = i
                guard_line = j
                break
    if target_idx is not None:
        break

if target_idx is None:
    print("  [skip] vma declaration not found or already fixed")
    sys.exit(0)

old = lines[target_idx]
new = old.replace("*vma;", "*vma __maybe_unused;", 1)
if new == old:
    new = old.replace("* vma;", "* vma __maybe_unused;", 1)
lines[target_idx] = new
with open(path, "w") as f:
    f.writelines(lines)
print(f"  [fix]  Added __maybe_unused at line {target_idx + 1} (guard at line {guard_line + 1})")
PYEOF
else
    echo "  [skip] task_mmu.c not found"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 2: supercalls.c — renamed API symbols (rsuntk fork only)
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 2: supercalls.c API name mismatches ---"
FIX2_REPLACED_HIDE=0
FIX2_REPLACED_FUNC=0

if [ -f "$SUPERCALLS" ]; then
    if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" "$SUPERCALLS"; then
        sed -i "s/CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS/CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS/g" "$SUPERCALLS"
        echo "  [fix]  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS → CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS"
        FIX2_REPLACED_HIDE=1
    else
        echo "  [skip] CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS not found (KernelSU-Next or already fixed)"
    fi

    if grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUPERCALLS"; then
        sed -i "s/susfs_set_hide_sus_mnts_for_all_procs/susfs_set_hide_sus_mnts_for_non_su_procs/g" "$SUPERCALLS"
        echo "  [fix]  susfs_set_hide_sus_mnts_for_all_procs → susfs_set_hide_sus_mnts_for_non_su_procs"
        FIX2_REPLACED_FUNC=1
    else
        echo "  [skip] susfs_set_hide_sus_mnts_for_all_procs not found (KernelSU-Next or already fixed)"
    fi

    if grep -q "susfs_add_try_umount" "$SUPERCALLS"; then
        sed -i "s/susfs_add_try_umount/add_try_umount/g" "$SUPERCALLS"
        echo "  [fix]  susfs_add_try_umount → add_try_umount"
    else
        echo "  [skip] susfs_add_try_umount not found (KernelSU-Next or already fixed)"
    fi
else
    echo "  [skip] supercalls.c not found"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 3: Missing linker symbols — creates fs/susfs_compat.c
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 3: missing linker symbols ---"

ALREADY_HAVE=0
{ [ -f "$SUSFS_C" ] && grep -q "^u32 susfs_ksu_sid" "$SUSFS_C"; } && ALREADY_HAVE=1
{ [ -f "$COMPAT_C" ] && grep -q "susfs_ksu_sid" "$COMPAT_C"; } && ALREADY_HAVE=1

if [ "$ALREADY_HAVE" -eq 1 ]; then
    echo "  [skip] symbols already defined"
else
    echo "  [fix]  creating fs/susfs_compat.c"
    cat > "$COMPAT_C" << 'CEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_compat.c — stub definitions for SUSFS symbols absent from the
 * installed fs/susfs.c due to a version mismatch.
 */
#include <linux/types.h>
#include <linux/export.h>

u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL_GPL(susfs_ksu_sid);

u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL_GPL(susfs_priv_app_sid);

bool susfs_is_current_ksu_domain(void)
{
	return false;
}
EXPORT_SYMBOL_GPL(susfs_is_current_ksu_domain);
CEOF

    if ! grep -q "susfs_compat" "$FS_MAKEFILE"; then
        if grep -q "susfs\.o" "$FS_MAKEFILE"; then
            sed -i '/susfs\.o/a obj-y += susfs_compat.o' "$FS_MAKEFILE"
        else
            echo "obj-y += susfs_compat.o" >> "$FS_MAKEFILE"
        fi
        echo "  [fix]  susfs_compat.o added to fs/Makefile"
    else
        echo "  [skip] susfs_compat.o already in fs/Makefile"
    fi
fi

# Ensure header declarations
add_decl() {
    local sym="$1" decl="$2"
    if grep -q "\b${sym}\b" "$SUSFS_H"; then
        echo "  [skip] ${sym} already in susfs.h"
    else
        echo "  [fix]  ${sym} → susfs.h"
        python3 - "$SUSFS_H" "$decl" << 'PYEOF'
import sys
path, decl = sys.argv[1], sys.argv[2]
with open(path) as f: src = f.read()
idx = src.rfind('#endif')
src = (src[:idx] + decl + '\n\n' + src[idx:]) if idx != -1 else (src + '\n' + decl + '\n')
with open(path, 'w') as f: f.write(src)
PYEOF
    fi
}
add_decl "susfs_ksu_sid"               "extern u32 susfs_ksu_sid;"
add_decl "susfs_priv_app_sid"          "extern u32 susfs_priv_app_sid;"
add_decl "susfs_is_current_ksu_domain" "extern bool susfs_is_current_ksu_domain(void);"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Fix 4: fs/susfs.c — fsnotify API mismatch
#
# SUSFS was written for a newer fsnotify API. This 4.19 kernel has:
#
# a) fsnotify_ops.handle_event signature WITHOUT the two fsnotify_mark* params:
#      int (*)(group, inode, mask, data, data_type, name, cookie, iter_info)
#    But susfs_handle_sdcard_inode_event has them:
#      int fn(group, inode, inode_mark*, vfsmount_mark*, mask, ...)
#    Fix: remove the two mark parameters from the function signature.
#
# b) fsnotify_add_mark(m, inode, NULL, 0) passes inode* as the connp arg.
#    The 4.19 API is: fsnotify_add_mark(mark, connp, type, allow_dups, fsid)
#    where connp = &inode->i_fsnotify_marks, type = FSNOTIFY_OBJ_TYPE_INODE.
#    Fix: replace with correct call.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Fix 4: fs/susfs.c fsnotify API mismatch ---"

if [ ! -f "$SUSFS_C" ]; then
    echo "  [skip] fs/susfs.c not found"
else
    # Write the fix script to a temp file to avoid heredoc quoting issues
    TMPPY=$(mktemp /tmp/susfs_fix4_XXXXXX.py)
    cat > "$TMPPY" << 'ENDPY'
import re, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print("  [skip] fs/susfs.c not found")
    sys.exit(0)
with open(path) as f:
    src = f.read()
original = src

# Fix 4a: remove the two fsnotify_mark* params from susfs_handle_sdcard_inode_event.
# The 4.19 fsnotify_ops.handle_event does NOT include inode_mark/vfsmount_mark params.
# SUSFS was written for a newer kernel that does. We strip those two lines.
pat_a = re.compile(
    r'(susfs_handle_sdcard_inode_event\s*\([^{]*?'
    r'struct\s+inode\s*\*\s*\w+\s*,[ \t]*)\n'
    r'[ \t]*struct\s+fsnotify_mark\s*\*\s*\w+\s*,[ \t]*\n'
    r'[ \t]*struct\s+fsnotify_mark\s*\*\s*\w+\s*,[ \t]*\n',
    re.DOTALL
)
src2, n = pat_a.subn(r'\1\n', src)
if n > 0:
    src = src2
    print(f"  [fix]  removed fsnotify_mark* params ({n} occurrence(s))")
elif 'susfs_handle_sdcard_inode_event' not in src:
    print("  [skip] susfs_handle_sdcard_inode_event not in susfs.c")
else:
    print("  [skip] fsnotify_mark params already removed or pattern not matched")

# Fix 4b: fix fsnotify_add_mark(mark, inode, NULL, allow_dups)
# 4.19 API: fsnotify_add_mark(mark, connp, type, allow_dups, fsid)
# connp = &inode->i_fsnotify_marks, type = FSNOTIFY_OBJ_TYPE_INODE
pat_b = re.compile(
    r'fsnotify_add_mark\s*\(\s*'
    r'(\w+)\s*,\s*'   # mark var
    r'(\w+)\s*,\s*'   # inode var (wrong)
    r'NULL\s*,\s*'    # NULL as type (wrong)
    r'(\d+)\s*\)'     # allow_dups
)
def fix_b(m):
    return ('fsnotify_add_mark(%s, &%s->i_fsnotify_marks, '
            'FSNOTIFY_OBJ_TYPE_INODE, %s, NULL)' % (m.group(1), m.group(2), m.group(3)))
src2, n = pat_b.subn(fix_b, src)
if n > 0:
    src = src2
    print(f"  [fix]  fsnotify_add_mark corrected ({n} call(s))")
elif 'fsnotify_add_mark' not in src:
    print("  [skip] fsnotify_add_mark not in susfs.c")
else:
    print("  [skip] fsnotify_add_mark already correct or not matched")

if src != original:
    with open(path, 'w') as f:
        f.write(src)
    print("  [ok]   fs/susfs.c written")
ENDPY
    python3 "$TMPPY" "$SUSFS_C"
    rm -f "$TMPPY"
fi
echo ""

echo "--- Verification ---"
FAIL=0

# Fix 1
if [ -f "$TASK_MMU" ]; then
    python3 -c "
lines = open('$TASK_MMU').readlines()
found = any(
    'vm_area_struct' in lines[i] and '__maybe_unused' in lines[i] and
    any('CONFIG_KSU_SUSFS_SUS_MAP' in lines[j]
        for j in range(i+1, min(len(lines), i+30)))
    for i in range(len(lines))
)
print('  ✅ task_mmu.c vma fix confirmed' if found else '  ⚠️  task_mmu.c: vma near SUS_MAP guard not found (may be pre-patched)')
"
fi

# Fix 2
if [ "$FIX2_REPLACED_HIDE" -eq 1 ]; then
    grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS" "$SUPERCALLS" \
        && echo "  ✅ supercalls.c HIDE rename confirmed" \
        || { echo "  ❌ supercalls.c HIDE rename failed"; FAIL=$((FAIL+1)); }
fi
if [ "$FIX2_REPLACED_FUNC" -eq 1 ]; then
    grep -q "susfs_set_hide_sus_mnts_for_non_su_procs" "$SUPERCALLS" \
        && echo "  ✅ supercalls.c func rename confirmed" \
        || { echo "  ❌ supercalls.c func rename failed"; FAIL=$((FAIL+1)); }
fi

# Fix 3
if [ -f "$COMPAT_C" ] && grep -q "susfs_ksu_sid" "$COMPAT_C"; then
    echo "  ✅ fs/susfs_compat.c present with definitions"
elif [ -f "$SUSFS_C" ] && grep -q "^u32 susfs_ksu_sid" "$SUSFS_C"; then
    echo "  ✅ susfs_ksu_sid defined in susfs.c"
else
    echo "  ❌ linker symbols not defined anywhere"
    FAIL=$((FAIL+1))
fi
grep -q "susfs_compat" "$FS_MAKEFILE" && echo "  ✅ susfs_compat.o in fs/Makefile"

# Fix 4
if [ -f "$SUSFS_C" ]; then
    # Check that the wrong fsnotify_add_mark call is gone
    if grep -q "fsnotify_add_mark" "$SUSFS_C"; then
        if grep -qP "fsnotify_add_mark\s*\(\s*\w+\s*,\s*\w+\s*,\s*NULL\s*," "$SUSFS_C" 2>/dev/null || \
           grep -q "fsnotify_add_mark([^,]*, [^&][^,]*, NULL," "$SUSFS_C" 2>/dev/null; then
            echo "  ❌ fsnotify_add_mark still has wrong args in susfs.c"
            FAIL=$((FAIL+1))
        else
            echo "  ✅ fsnotify_add_mark call corrected in susfs.c"
        fi
    else
        echo "  ⚠️  fsnotify_add_mark not present in susfs.c (may not apply)"
    fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL check(s) failed"
    exit 1
fi
echo "✅ All fixes applied successfully"
