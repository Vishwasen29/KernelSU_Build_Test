#!/bin/bash
# susfs_linker_fix.sh
#
# Fixes linker errors caused by a SUSFS version mismatch:
#
#   ld.lld: error: undefined symbol: susfs_ksu_sid
#   ld.lld: error: undefined symbol: susfs_priv_app_sid
#   ld.lld: error: undefined symbol: susfs_is_current_ksu_domain
#
# Root cause:
#   The SUSFS patch applied to security/selinux/avc.c and fs/proc_namespace.c
#   references symbols from a NEWER SUSFS version than the fs/susfs.c that was
#   installed by the patch. The call sites exist but the definitions do not.
#
#   - susfs_ksu_sid / susfs_priv_app_sid:
#       u32 variables used in avc.c to suppress SELinux audit noise for KSU
#       processes. Defined in susfs.c from SUSFS >= ~v1.5.2.
#
#   - susfs_is_current_ksu_domain():
#       bool function used in proc_namespace.c to hide mounts from KSU domain.
#       May be defined in susfs.c but missing if the installed version predates
#       the proc_namespace.c patch.
#
# Fix strategy:
#   For each missing symbol, check if it is already defined in fs/susfs.c.
#   If not, append the definition. All definitions are safe no-ops if SUSFS
#   is otherwise working — they just provide the missing link targets.
#
# Usage:
#   bash susfs_linker_fix.sh [path/to/android-kernel]

set -e

KERNEL_ROOT="${1:-.}"
SUSFS_C="${KERNEL_ROOT}/fs/susfs.c"
SUSFS_H="${KERNEL_ROOT}/include/linux/susfs.h"

echo "=== SUSFS linker symbol fix ==="
echo "    Kernel root: $KERNEL_ROOT"
echo ""

if [ ! -f "$SUSFS_C" ]; then
    echo "ERROR: $SUSFS_C not found — SUSFS patch not applied yet."
    exit 1
fi

FIXED=0

# ─────────────────────────────────────────────────────────────────────────────
# Helper: append a C definition to susfs.c if the symbol is not yet defined
# ─────────────────────────────────────────────────────────────────────────────
add_definition() {
    local symbol="$1"
    local code="$2"

    # Check both plain definition and EXPORT_SYMBOL variants
    if grep -q "\b${symbol}\b" "$SUSFS_C" 2>/dev/null; then
        echo "  [skip] ${symbol} — already defined in susfs.c"
    else
        echo "  [fix]  ${symbol} — appending definition to susfs.c"
        printf '\n%s\n' "$code" >> "$SUSFS_C"
        FIXED=$((FIXED + 1))
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: susfs_ksu_sid
#
# u32 variable holding the SELinux SID of the KernelSU process.
# avc.c uses it to suppress audit denials for KSU.
# Initialised to 0 (no SID) — safe default that makes the avc check a no-op
# until KSU properly sets the SID at runtime.
# ─────────────────────────────────────────────────────────────────────────────
add_definition "susfs_ksu_sid" \
"/* SUSFS: SELinux SID for KernelSU process — set at runtime by KSU */
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL_GPL(susfs_ksu_sid);"

# ─────────────────────────────────────────────────────────────────────────────
# Fix 2: susfs_priv_app_sid
#
# u32 variable holding the SELinux SID of privileged app processes.
# avc.c uses it alongside susfs_ksu_sid to decide whether to suppress
# a denial audit entry.
# ─────────────────────────────────────────────────────────────────────────────
add_definition "susfs_priv_app_sid" \
"/* SUSFS: SELinux SID for privileged app processes — set at runtime by KSU */
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL_GPL(susfs_priv_app_sid);"

# ─────────────────────────────────────────────────────────────────────────────
# Fix 3: susfs_is_current_ksu_domain
#
# bool function that returns true if the current process is running in the
# KernelSU domain. Used by proc_namespace.c to hide mounts from KSU processes.
#
# If already declared extern in susfs.h but not defined in susfs.c, the linker
# fails. We define it here returning false (safe default — means no mounts are
# hidden for KSU domain, which is harmless if this function was never intended
# to be compiled in from this patch version).
#
# NOTE: namespace.c already has this call guarded by CONFIG_KSU_SUSFS_SUS_MOUNT.
# proc_namespace.c has it unguarded in this patch version, so the linker always
# needs the symbol resolved.
# ─────────────────────────────────────────────────────────────────────────────
add_definition "susfs_is_current_ksu_domain" \
"/* SUSFS: returns true if current process is in KernelSU domain */
bool susfs_is_current_ksu_domain(void)
{
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	/* Delegate to the actual implementation if SUS_MOUNT is compiled in.
	 * The real body lives in the SUS_MOUNT section above; if this stub is
	 * being compiled it means the real one is absent — return false. */
#endif
	return false;
}
EXPORT_SYMBOL_GPL(susfs_is_current_ksu_domain);"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Ensure the symbols are declared in susfs.h so all callers see the prototype
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Checking susfs.h declarations ---"

if [ -f "$SUSFS_H" ]; then
    add_decl() {
        local sym="$1" decl="$2"
        if grep -q "\b${sym}\b" "$SUSFS_H"; then
            echo "  [skip] ${sym} — already declared in susfs.h"
        else
            echo "  [fix]  ${sym} — adding declaration to susfs.h"
            # Insert before the final #endif of the header guard
            python3 -c "
import sys
path, decl = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()
# Insert before last #endif
idx = src.rfind('#endif')
if idx == -1:
    src += '\n' + decl + '\n'
else:
    src = src[:idx] + decl + '\n\n' + src[idx:]
with open(path, 'w') as f:
    f.write(src)
" "$SUSFS_H" "$decl"
        fi
    }

    add_decl "susfs_ksu_sid"             "extern u32 susfs_ksu_sid;"
    add_decl "susfs_priv_app_sid"        "extern u32 susfs_priv_app_sid;"
    add_decl "susfs_is_current_ksu_domain" "extern bool susfs_is_current_ksu_domain(void);"
else
    echo "  [warn] susfs.h not found — skipping header declarations"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verify all three symbols are now present in susfs.c
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Verification ---"
FAIL=0
for sym in susfs_ksu_sid susfs_priv_app_sid susfs_is_current_ksu_domain; do
    if grep -q "\b${sym}\b" "$SUSFS_C"; then
        echo "  ✅ ${sym} defined in susfs.c"
    else
        echo "  ❌ ${sym} still missing from susfs.c"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL symbol(s) still missing"
    exit 1
fi

if [ "$FIXED" -eq 0 ]; then
    echo "✅ All symbols were already present — no changes needed"
else
    echo "✅ $FIXED symbol(s) added — linker errors should be resolved"
fi
