#!/bin/bash
# fix_rejects.sh
# Applies rejected SUSFS patch hunks to mount.h and fs/namespace.c
# with validation steps to confirm each fix is correctly applied.
#
# Usage:
#   ./fix_rejects.sh <path/to/mount.h> <path/to/namespace.c>

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pass()  { echo -e "${GREEN}[PASS]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

ERRORS=0
MOUNT_H="${1:-include/linux/mount.h}"
NAMESPACE_C="${2:-fs/namespace.c}"

echo ""
echo "======================================================"
echo "  SUSFS Reject Fixer"
echo "======================================================"
echo "  mount.h     : $MOUNT_H"
echo "  namespace.c : $NAMESPACE_C"
echo "======================================================"
echo ""

for f in "$MOUNT_H" "$NAMESPACE_C"; do
    if [[ ! -f "$f" ]]; then
        fail "File not found: $f"
        echo "Usage: $0 <path/to/mount.h> <path/to/namespace.c>"
        exit 1
    fi
done

BACKED_UP_NS=0
backup_ns() {
    if [[ $BACKED_UP_NS -eq 0 ]]; then
        local bak="${NAMESPACE_C}.bak.$(date +%s)"
        cp "$NAMESPACE_C" "$bak"
        info "Backup saved: $bak"
        BACKED_UP_NS=1
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# FIX 1 – mount.h: wrap ANDROID_KABI_RESERVE(4) with CONFIG_KSU_SUSFS guard
# ════════════════════════════════════════════════════════════════════════════
echo "------------------------------------------------------"
echo "FIX 1: mount.h – ANDROID_KABI_RESERVE(4) → SUSFS guard"
echo "------------------------------------------------------"

if grep -q "ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup)" "$MOUNT_H"; then
    warn "Fix 1 already applied. Skipping."
elif ! grep -qP '^\tANDROID_KABI_RESERVE\(4\);' "$MOUNT_H"; then
    fail "Expected 'ANDROID_KABI_RESERVE(4);' not found in $MOUNT_H"
else
    cp "$MOUNT_H" "${MOUNT_H}.bak.$(date +%s)"
    info "Backup saved: ${MOUNT_H}.bak.*"
    python3 - "$MOUNT_H" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as fh: text = fh.read()
old = '\tANDROID_KABI_RESERVE(4);'
new = ('#ifdef CONFIG_KSU_SUSFS\n'
       '\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n'
       '#else\n'
       '\tANDROID_KABI_RESERVE(4);\n'
       '#endif')
if text.count(old) != 1:
    print(f"ERROR: found {text.count(old)} occurrences; expected 1", file=sys.stderr); sys.exit(1)
with open(path, 'w') as fh: fh.write(text.replace(old, new, 1))
print("  Substitution applied.")
PYEOF
fi

echo ""; info "Validating Fix 1…"
grep -q "#ifdef CONFIG_KSU_SUSFS"                         "$MOUNT_H" && pass "#ifdef CONFIG_KSU_SUSFS present"           || fail "#ifdef CONFIG_KSU_SUSFS MISSING"
grep -q "ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup)"   "$MOUNT_H" && pass "ANDROID_KABI_USE(4,...) present"            || fail "ANDROID_KABI_USE(4,...) MISSING"
python3 - "$MOUNT_H" <<'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
if re.search(r'#ifdef CONFIG_KSU_SUSFS\s+ANDROID_KABI_USE\(4, u64 susfs_mnt_id_backup\);\s+#else\s+\tANDROID_KABI_RESERVE\(4\);\s+#endif', text):
    print("\033[0;32m[PASS]\033[0m Full #ifdef…#else…#endif block structurally correct")
else:
    print("\033[0;31m[FAIL]\033[0m Structural check FAILED", file=sys.stderr); sys.exit(1)
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# FIX 2 – namespace.c: add susfs_def.h include + extern declarations
# ════════════════════════════════════════════════════════════════════════════
echo ""; echo "------------------------------------------------------"
echo "FIX 2: namespace.c – susfs_def.h include & declarations"
echo "------------------------------------------------------"

NEED_INC=1; NEED_DECL=1
grep -q '#include <linux/susfs_def.h>'          "$NAMESPACE_C" && NEED_INC=0
grep -q 'susfs_is_sdcard_android_data_decrypted' "$NAMESPACE_C" && NEED_DECL=0

if [[ $NEED_INC -eq 0 && $NEED_DECL -eq 0 ]]; then
    warn "Fix 2 already fully applied. Skipping."
else
    backup_ns
    python3 - "$NAMESPACE_C" "$NEED_INC" "$NEED_DECL" <<'PYEOF'
import sys
path, need_inc, need_decl = sys.argv[1], sys.argv[2]=='1', sys.argv[3]=='1'
with open(path) as fh: text = fh.read()

if need_inc:
    anchor = '#include "pnode.h"'
    if anchor not in text:
        print("ERROR: pnode.h anchor not found", file=sys.stderr); sys.exit(1)
    block = ('#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
             '#include <linux/susfs_def.h>\n'
             '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n')
    text = text.replace(anchor, block + anchor, 1)
    print("  Inserted susfs_def.h include block.")

if need_decl:
    anchor2 = '/* Maximum number of mounts in a mount namespace */'
    if anchor2 not in text:
        print("ERROR: sysctl_mount_max anchor not found", file=sys.stderr); sys.exit(1)
    block2 = ('#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
              'extern bool susfs_is_current_ksu_domain(void);\n'
              'extern bool susfs_is_sdcard_android_data_decrypted;\n\n'
              'static atomic64_t susfs_ksu_mounts = ATOMIC64_INIT(0);\n\n'
              '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n'
              '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n')
    text = text.replace(anchor2, block2 + anchor2, 1)
    print("  Inserted extern declarations block.")

with open(path, 'w') as fh: fh.write(text)
PYEOF
fi

echo ""; info "Validating Fix 2…"
for pattern in "CONFIG_KSU_SUSFS_SUS_MOUNT" "#include <linux/susfs_def.h>" \
    "susfs_is_current_ksu_domain" "susfs_is_sdcard_android_data_decrypted" \
    "susfs_ksu_mounts = ATOMIC64_INIT" "CL_COPY_MNT_NS BIT(25)"; do
    grep -q "$pattern" "$NAMESPACE_C" && pass "'$pattern' present" || fail "'$pattern' MISSING"
done

# ════════════════════════════════════════════════════════════════════════════
# FIX 3 – namespace.c: add susfs logic to clone_mnt()
# ════════════════════════════════════════════════════════════════════════════
echo ""; echo "------------------------------------------------------"
echo "FIX 3: namespace.c – susfs logic in clone_mnt()"
echo "------------------------------------------------------"

if grep -q "skip_checking_for_ksu_proc" "$NAMESPACE_C"; then
    warn "Fix 3 already applied. Skipping."
elif ! grep -q "mnt = alloc_vfsmnt(old->mnt_devname);" "$NAMESPACE_C"; then
    fail "Anchor 'mnt = alloc_vfsmnt(old->mnt_devname);' not found"
else
    backup_ns
    python3 - "$NAMESPACE_C" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as fh: text = fh.read()

anchor = '\tmnt = alloc_vfsmnt(old->mnt_devname);'
pre = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '\t// We won\'t check it anymore if boot-completed stage is triggered.\n'
    '\tif (susfs_is_sdcard_android_data_decrypted) {\n'
    '\t\tgoto skip_checking_for_ksu_proc;\n'
    '\t}\n'
    '\t// First we must check for ksu process because of magic mount\n'
    '\tif (susfs_is_current_ksu_domain()) {\n'
    '\t\t// if it is unsharing, we reuse the old->mnt_id\n'
    '\t\tif (flag & CL_COPY_MNT_NS) {\n'
    '\t\t\tmnt = susfs_reuse_sus_vfsmnt(old->mnt_devname, old->mnt_id);\n'
    '\t\t\tgoto bypass_orig_flow;\n'
    '\t\t}\n'
    '\t\t// else we just go assign fake mnt_id\n'
    '\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n'
    '\t\tgoto bypass_orig_flow;\n'
    '\t}\n'
    'skip_checking_for_ksu_proc:\n'
    '\t// Lastly for other processes of which old->mnt_id == DEFAULT_KSU_MNT_ID, go assign fake mnt_id\n'
    '\tif (old->mnt_id == DEFAULT_KSU_MNT_ID) {\n'
    '\t\tmnt = susfs_alloc_sus_vfsmnt(old->mnt_devname);\n'
    '\t\tgoto bypass_orig_flow;\n'
    '\t}\n'
    '#endif\n'
)
post = ('\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
        'bypass_orig_flow:\n'
        '#endif')
if anchor not in text:
    print("ERROR: anchor not found", file=sys.stderr); sys.exit(1)
with open(path, 'w') as fh: fh.write(text.replace(anchor, pre + anchor + post, 1))
print("  clone_mnt susfs block inserted.")
PYEOF
fi

echo ""; info "Validating Fix 3…"
for pattern in "susfs_reuse_sus_vfsmnt" "susfs_alloc_sus_vfsmnt" \
    "bypass_orig_flow" "skip_checking_for_ksu_proc" "DEFAULT_KSU_MNT_ID"; do
    grep -q "$pattern" "$NAMESPACE_C" && pass "'$pattern' present" || fail "'$pattern' MISSING"
done
python3 - "$NAMESPACE_C" <<'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
if re.search(r'skip_checking_for_ksu_proc:.*?mnt = alloc_vfsmnt\(old->mnt_devname\);.*?bypass_orig_flow:', text, re.DOTALL):
    print("\033[0;32m[PASS]\033[0m clone_mnt block order: skip_checking → alloc_vfsmnt → bypass_orig_flow ✓")
else:
    print("\033[0;31m[FAIL]\033[0m clone_mnt structural order check FAILED", file=sys.stderr); sys.exit(1)
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# FIX 4 – namespace.c: blank line before lock_mount_hash() in clone_mnt
# ════════════════════════════════════════════════════════════════════════════
echo ""; echo "------------------------------------------------------"
echo "FIX 4: namespace.c – blank line before lock_mount_hash() in clone_mnt"
echo "------------------------------------------------------"

python3 - "$NAMESPACE_C" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as fh: text = fh.read()
if re.search(r'mnt_parent = mnt;\n\n\tlock_mount_hash\(\);', text):
    print("\033[1;33m[WARN]\033[0m Fix 4 already applied – blank line exists.")
    sys.exit(0)
m = re.search(r'mnt_parent = mnt;\n\tlock_mount_hash\(\);', text)
if m:
    text2 = re.sub(r'(mnt_parent = mnt;)\n(\tlock_mount_hash\(\);)', r'\1\n\n\2', text, count=1)
    with open(path,'w') as fh: fh.write(text2)
    print("  Blank line inserted before lock_mount_hash().")
else:
    print("\033[0;31m[FAIL]\033[0m Pattern not found – cannot apply Fix 4.", file=sys.stderr); sys.exit(1)
PYEOF

echo ""; info "Validating Fix 4…"
python3 - "$NAMESPACE_C" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
if re.search(r'mnt_parent = mnt;\n\n\tlock_mount_hash\(\);', text):
    print("\033[0;32m[PASS]\033[0m Blank line confirmed before lock_mount_hash()")
else:
    print("\033[0;31m[FAIL]\033[0m Blank line NOT present before lock_mount_hash()", file=sys.stderr); sys.exit(1)
PYEOF

# ════════════════════════════════════════════════════════════════════════════
echo ""; echo "======================================================"
if [[ "$ERRORS" -eq 0 ]]; then
    echo -e "${GREEN}  All fixes applied and validated successfully.${NC}"
    echo -e "${GREEN}  Files are ready for compilation.${NC}"
else
    echo -e "${RED}  Completed with $ERRORS error(s). Review output above.${NC}"
fi
echo "======================================================"; echo ""
exit "$ERRORS"
