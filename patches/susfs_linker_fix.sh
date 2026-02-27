#!/bin/bash
# susfs_linker_fix.sh
#
# Fixes linker errors:
#   ld.lld: error: undefined symbol: susfs_ksu_sid
#   ld.lld: error: undefined symbol: susfs_priv_app_sid
#   ld.lld: error: undefined symbol: susfs_is_current_ksu_domain
#
# Strategy: creates fs/susfs_compat.c with the missing definitions and adds
# it to fs/Makefile. This is unconditional — no detection logic that can
# silently fail. If a symbol is already defined elsewhere the compiler will
# error with "duplicate definition" rather than silently doing nothing.
#
# Usage:
#   bash susfs_linker_fix.sh [path/to/android-kernel]

set -e

KERNEL_ROOT="${1:-.}"
COMPAT_C="${KERNEL_ROOT}/fs/susfs_compat.c"
MAKEFILE="${KERNEL_ROOT}/fs/Makefile"
SUSFS_H="${KERNEL_ROOT}/include/linux/susfs.h"

echo "=== SUSFS linker symbol fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

if [ ! -f "$MAKEFILE" ]; then
    echo "ERROR: $MAKEFILE not found. Is KERNEL_ROOT correct?"
    exit 1
fi

if [ ! -f "$SUSFS_H" ]; then
    echo "ERROR: $SUSFS_H not found — SUSFS patch not applied yet."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Create fs/susfs_compat.c
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Creating fs/susfs_compat.c ---"

if [ -f "$COMPAT_C" ]; then
    echo "  [skip] susfs_compat.c already exists"
else
    cat > "$COMPAT_C" << 'CEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_compat.c — stub definitions for SUSFS symbols that are referenced
 * by patched kernel files (security/selinux/avc.c, fs/proc_namespace.c)
 * but absent from the installed fs/susfs.c due to a version mismatch.
 *
 * susfs_ksu_sid / susfs_priv_app_sid:
 *   SELinux SIDs used by avc_audit_post_callback() to suppress audit noise
 *   for KernelSU and privileged app processes. Initialised to 0 (no SID),
 *   which makes the suppression a safe no-op until KSU sets them at runtime.
 *
 * susfs_is_current_ksu_domain:
 *   Called unconditionally (no #ifdef guard) from show_vfsmnt(),
 *   show_mountinfo() and show_vfsstat() in fs/proc_namespace.c to decide
 *   whether to hide mount table entries from the current process.
 *   Returns false — mount entries are visible to all processes. This is
 *   safe: it only means the KSU domain hiding feature is inactive.
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
    echo "  [ok]  fs/susfs_compat.c created"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Add susfs_compat.o to fs/Makefile
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Wiring into fs/Makefile ---"

if grep -q "susfs_compat" "$MAKEFILE"; then
    echo "  [skip] susfs_compat.o already in Makefile"
else
    # Add it on the same line as susfs.o so it is always compiled in
    sed -i 's/obj-y.*+=.*susfs\.o/& susfs_compat.o/' "$MAKEFILE"

    # If that pattern didn't match (susfs.o might be on its own line), append
    if ! grep -q "susfs_compat" "$MAKEFILE"; then
        # Find the susfs.o line and append after it
        sed -i '/susfs\.o/a obj-y += susfs_compat.o' "$MAKEFILE"
    fi

    # Last resort: just append to end of file
    if ! grep -q "susfs_compat" "$MAKEFILE"; then
        echo "obj-y += susfs_compat.o" >> "$MAKEFILE"
    fi

    echo "  [ok]  susfs_compat.o added to fs/Makefile"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Ensure symbols are declared in susfs.h so all callers compile clean
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Checking susfs.h declarations ---"

add_decl() {
    local sym="$1" decl="$2"
    if grep -q "\b${sym}\b" "$SUSFS_H"; then
        echo "  [skip] ${sym} — already in susfs.h"
    else
        echo "  [fix]  ${sym} — adding to susfs.h"
        python3 - "$SUSFS_H" "$decl" << 'PYEOF'
import sys
path, decl = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()
idx = src.rfind('#endif')
src = (src[:idx] + decl + '\n\n' + src[idx:]) if idx != -1 else (src + '\n' + decl + '\n')
with open(path, 'w') as f:
    f.write(src)
PYEOF
    fi
}

add_decl "susfs_ksu_sid"               "extern u32 susfs_ksu_sid;"
add_decl "susfs_priv_app_sid"          "extern u32 susfs_priv_app_sid;"
add_decl "susfs_is_current_ksu_domain" "extern bool susfs_is_current_ksu_domain(void);"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Verify
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Verification ---"
FAIL=0

if [ -f "$COMPAT_C" ]; then
    echo "  ✅ fs/susfs_compat.c exists"
else
    echo "  ❌ fs/susfs_compat.c missing"
    FAIL=$((FAIL+1))
fi

if grep -q "susfs_compat" "$MAKEFILE"; then
    echo "  ✅ susfs_compat.o in fs/Makefile"
else
    echo "  ❌ susfs_compat.o NOT in fs/Makefile"
    FAIL=$((FAIL+1))
fi

for sym in susfs_ksu_sid susfs_priv_app_sid susfs_is_current_ksu_domain; do
    if grep -q "\b${sym}\b" "$COMPAT_C"; then
        echo "  ✅ ${sym} defined in susfs_compat.c"
    else
        echo "  ❌ ${sym} missing from susfs_compat.c"
        FAIL=$((FAIL+1))
    fi
done

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL check(s) failed"
    exit 1
fi
echo "✅ All fixes applied — linker errors should be resolved"
