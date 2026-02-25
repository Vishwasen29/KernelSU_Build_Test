#!/usr/bin/env bash
# =============================================================================
# apply_susfs_patch.sh
#
# Adjusts susfs_patch_to_4_19.patch for the rsuntk/KernelSU workflow and
# applies it to the kernel source tree.
#
# WORKFLOW CONTEXT (what is already done before this script runs):
#   - KernelSU fork : rsuntk/KernelSU  branch: susfs-rksu-master
#   - KernelSU hooks: kernel-4.19_5.4-patch.sh  (exec/open/stat/reboot/input)
#   - SUSFS files   : copied from SUSFS/ folder (susfs.c, susfs.h, susfs_def.h)
#   - fs/Makefile   : susfs.o entry already added
#
# WHAT THIS SCRIPT DOES:
#   1. Strips sections already handled by the workflow:
#        fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h
#        fs/Makefile (susfs.o hunk)
#
#   2. Fixes the broken security/selinux/avc.c hunk:
#        The original patch reads sad.tsid from an uninitialised local struct —
#        undefined behaviour on 4.19. We keep ONLY the bool definition that
#        fixes the linker error: bool susfs_is_avc_log_spoofing_enabled = false;
#
#   3. Applies all remaining kernel-integration hunks:
#        fs/namei.c         fs/namespace.c     fs/notify/fdinfo.c
#        fs/overlayfs/      fs/proc/           fs/proc_namespace.c
#        fs/readdir.c       fs/stat.c          fs/statfs.c
#        include/linux/mount.h  kernel/kallsyms.c  kernel/sys.c
#
#   4. Adds two symbols missing from SUSFS v2.0.0 that rsuntk/KernelSU needs,
#      correctly placed INSIDE their #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT guards:
#        - CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS  (susfs_def.h)
#        - susfs_set_hide_sus_mnts_for_all_procs   (susfs.h + susfs.c)
#
# USAGE:
#   ./apply_susfs_patch.sh <KERNEL_DIR> <PATCH_FILE>
#
# EXAMPLE (GitHub Actions):
#   chmod +x patches/apply_susfs_patch.sh
#   patches/apply_susfs_patch.sh \
#       kernel_workspace/android-kernel \
#       patches/susfs_patch_to_4_19.patch
# =============================================================================

set -euo pipefail

KERNEL_DIR="${1:-}"
PATCH_FILE="${2:-}"

if [ -z "$KERNEL_DIR" ] || [ -z "$PATCH_FILE" ]; then
    echo "Usage: $0 <KERNEL_DIR> <PATCH_FILE>"
    exit 1
fi
if [ ! -d "$KERNEL_DIR" ]; then
    echo "❌ Kernel directory not found: $KERNEL_DIR"
    exit 1
fi
if [ ! -f "$PATCH_FILE" ]; then
    echo "❌ Patch file not found: $PATCH_FILE"
    exit 1
fi

PATCH_FILE="$(realpath "$PATCH_FILE")"
KERNEL_DIR="$(realpath "$KERNEL_DIR")"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  apply_susfs_patch.sh"
echo "  Kernel : $KERNEL_DIR"
echo "  Patch  : $PATCH_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# STEP 1 — Build adjusted patch
# =============================================================================

echo "── Step 1: Building adjusted patch ────────────────────────────────────────"
echo ""

ADJUSTED_PATCH="$(mktemp /tmp/susfs_adjusted_XXXXXX.patch)"
trap 'rm -f "$ADJUSTED_PATCH"' EXIT

python3 - "$PATCH_FILE" "$ADJUSTED_PATCH" << 'PYEOF'
import sys, re

src_path  = sys.argv[1]
dest_path = sys.argv[2]

# Files to drop entirely — the workflow already copies these from SUSFS/
DROP_ENTIRELY = {
    "fs/susfs.c",
    "include/linux/susfs.h",
    "include/linux/susfs_def.h",
}

with open(src_path, 'r', errors='replace') as f:
    raw = f.read()

# Split on diff headers, keeping the header in each chunk
sections = re.split(r'(?=^diff --git )', raw, flags=re.MULTILINE)

out_parts = []

for sec in sections:
    if not sec.strip():
        continue

    m = re.match(r'diff --git a/(\S+)', sec)
    if not m:
        out_parts.append(sec)
        continue

    filepath = m.group(1)

    # ── Drop sections already handled by the workflow ────────────────────────
    if filepath in DROP_ENTIRELY:
        print(f"  ⏭  SKIP (workflow handles): {filepath}")
        continue

    # ── fs/Makefile — susfs.o is already added by the workflow ───────────────
    if filepath == "fs/Makefile":
        if "obj-$(CONFIG_KSU_SUSFS) += susfs.o" in sec:
            print(f"  ⏭  SKIP (workflow handles): {filepath}  [susfs.o hunk]")
            continue

    # ── security/selinux/avc.c — safe minimal replacement ───────────────────
    # The original patch's avc_dump_query hunk reads `sad.tsid` from a local
    # `struct selinux_audit_data sad` that is declared but never initialised —
    # undefined behaviour on 4.19 that will produce garbage or an oops.
    # We emit only the one line we actually need: the bool definition.
    # The two susfs_ksu_sid / susfs_priv_app_sid externs are intentionally
    # removed here because nothing in avc.c uses them anymore.
    if filepath == "security/selinux/avc.c":
        print(f"  ✂  PARTIAL: {filepath}  [drop UB sad hunk; keep bool definition only]")
        minimal_avc = (
            "diff --git a/security/selinux/avc.c b/security/selinux/avc.c\n"
            "--- a/security/selinux/avc.c\n"
            "+++ b/security/selinux/avc.c\n"
            "@@ -164,6 +164,9 @@ static void avc_dump_av(struct audit_buffer *ab, u16 tclass, u32 av)\n"
            " \n"
            " \taudit_log_format(ab, \" }\");\n"
            " }\n"
            "+#ifdef CONFIG_KSU_SUSFS\n"
            "+bool susfs_is_avc_log_spoofing_enabled = false;\n"
            "+#endif\n"
            " \n"
            " /**\n"
            "  * avc_dump_query - Display a SID pair and a class in human-readable form.\n"
        )
        out_parts.append(minimal_avc)
        continue

    # ── All other files — apply as-is ────────────────────────────────────────
    print(f"  ✅ KEEP: {filepath}")
    out_parts.append(sec)

with open(dest_path, 'w') as f:
    f.write(''.join(out_parts))
PYEOF

echo ""

# =============================================================================
# STEP 2 — Apply the adjusted patch
# =============================================================================

echo "── Step 2: Applying adjusted patch ─────────────────────────────────────────"
echo ""

cd "$KERNEL_DIR"

# --reject writes failed hunks to .rej files instead of aborting entirely.
# The || true prevents pipefail from killing the script on partial failures.
git apply \
    --ignore-whitespace \
    --ignore-space-change \
    --reject \
    --verbose \
    "$ADJUSTED_PATCH" 2>&1 || true

echo ""

# =============================================================================
# STEP 3 — Report any rejected hunks
# =============================================================================

# BUG FIX: with set -o pipefail, `grep -v` on empty input returns exit 1,
# which would kill the script on every SUCCESSFUL run (no .rej files).
# Use || true to safely produce an empty string when nothing matches.
REJECT_FILES=$(find . -name "*.rej" 2>/dev/null | grep -v ".git" | sort || true)

if [ -n "$REJECT_FILES" ]; then
    echo "── Rejected hunks (context mismatch with this kernel tree) ─────────────────"
    echo ""
    while IFS= read -r rej; do
        target="${rej%.rej}"
        echo "  ❌ $target"
        head -30 "$rej" | sed 's/^/      /'
        echo ""
    done <<< "$REJECT_FILES"
    echo "  These need manual review — the LineageOS tree likely has slightly"
    echo "  different context lines around the insertion points."
    echo ""
fi

# =============================================================================
# STEP 4 — Fix missing SUSFS v2.0.0 symbols required by rsuntk/KernelSU
#
# rsuntk's setuid_hook.c calls susfs_set_hide_sus_mnts_for_all_procs() and
# supercalls.c references CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS.
# Neither symbol exists in upstream v2.0.0 SUSFS files.
#
# IMPORTANT: all insertions must land INSIDE the existing
# #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT ... #endif guards, not after them.
# =============================================================================

echo "── Step 4: Adding missing SUSFS v2.0.0 symbols ─────────────────────────────"
echo ""

SUSFS_DEF_H="include/linux/susfs_def.h"
SUSFS_H="include/linux/susfs.h"
SUSFS_C="fs/susfs.c"

# ── 4a. CMD define in susfs_def.h ────────────────────────────────────────────
# Inserting a new #define next to existing ones; no ifdef guard needed here,
# susfs_def.h defines are unconditional.
if ! grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" "$SUSFS_DEF_H" 2>/dev/null; then
    python3 - "$SUSFS_DEF_H" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

anchor = "#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS 0x55561"
replacement = (
    "#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS 0x55561\n"
    "#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS     0x55563"
)

if anchor in content:
    content = content.replace(anchor, replacement, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS added to {path}")
else:
    # Fallback: insert before the SUSFS_MAX_LEN_PATHNAME block
    fallback = "#define SUSFS_MAX_LEN_PATHNAME"
    if fallback in content:
        content = content.replace(
            fallback,
            "#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS     0x55563\n" + fallback,
            1,
        )
        with open(path, 'w') as f:
            f.write(content)
        print(f"  ✅ CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS added (fallback) to {path}")
    else:
        print(f"  ❌ Could not find anchor in {path}")
        sys.exit(1)
PYEOF
else
    echo "  ℹ️  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS already present"
fi

# ── 4b. Function declaration in susfs.h ──────────────────────────────────────
# BUG FIX (previous version): the declaration must land BEFORE the
# "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT" that closes the sus_mount
# block, not after it. We locate the #endif that immediately follows the
# existing declaration and insert there.
if ! grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUSFS_H" 2>/dev/null; then
    python3 - "$SUSFS_H" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

decl_anchor  = "void susfs_set_hide_sus_mnts_for_non_su_procs(void __user **user_info);"
endif_marker = "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
new_decl     = "void susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info);\n"

pos = content.find(decl_anchor)
if pos == -1:
    print(f"  ❌ Could not find declaration anchor in {path}")
    sys.exit(1)

# Find the #endif that closes this sus_mount block (first one after the decl)
after_decl = pos + len(decl_anchor)
endif_pos = content.find(endif_marker, after_decl)
if endif_pos == -1:
    print(f"  ❌ Could not find #endif marker after declaration in {path}")
    sys.exit(1)

# Insert the new declaration just before the #endif (inside the guard)
content = content[:endif_pos] + new_decl + content[endif_pos:]
with open(path, 'w') as f:
    f.write(content)
print(f"  ✅ susfs_set_hide_sus_mnts_for_all_procs declared inside #ifdef in {path}")
PYEOF
else
    echo "  ℹ️  susfs_set_hide_sus_mnts_for_all_procs already declared"
fi

# ── 4c. Function implementation in susfs.c ───────────────────────────────────
# BUG FIX (previous version): the implementation must land BEFORE the
# "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT" that closes the sus_mount
# block, not after it (where it would be outside the guard and try to
# reference susfs_spin_lock_sus_mount which is only defined inside the block).
if ! grep -q "susfs_set_hide_sus_mnts_for_all_procs" "$SUSFS_C" 2>/dev/null; then
    python3 - "$SUSFS_C" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Anchor: the unique closing log line + closing brace of
# susfs_set_hide_sus_mnts_for_non_su_procs
close_anchor = ('SUSFS_LOGI("CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS -> ret: %d\\n", info.err);\n'
                '}\n')
endif_marker = '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT'

# New function must be inside the same #ifdef guard, so insert BEFORE #endif
new_impl = (
    "\nvoid susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info) {\n"
    "\tstruct st_susfs_hide_sus_mnts_for_non_su_procs info = {0};\n"
    "\n"
    "\tif (copy_from_user(&info, (struct st_susfs_hide_sus_mnts_for_non_su_procs __user*)*user_info, sizeof(info))) {\n"
    "\t\tinfo.err = -EFAULT;\n"
    "\t\tgoto out_copy_to_user;\n"
    "\t}\n"
    "\tspin_lock(&susfs_spin_lock_sus_mount);\n"
    "\tsusfs_hide_sus_mnts_for_non_su_procs = info.enabled;\n"
    "\tspin_unlock(&susfs_spin_lock_sus_mount);\n"
    '\tSUSFS_LOGI("susfs_hide_sus_mnts_for_all_procs: %d\\n", info.enabled);\n'
    "\tinfo.err = 0;\n"
    "out_copy_to_user:\n"
    "\tif (copy_to_user(&((struct st_susfs_hide_sus_mnts_for_non_su_procs __user*)*user_info)->err, &info.err, sizeof(info.err))) {\n"
    "\t\tinfo.err = -EFAULT;\n"
    "\t}\n"
    '\tSUSFS_LOGI("CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS -> ret: %d\\n", info.err);\n'
    "}\n"
)

close_pos = content.find(close_anchor)
if close_pos == -1:
    print(f"  ❌ Could not find function close anchor in {path}")
    sys.exit(1)

after_close = close_pos + len(close_anchor)
endif_pos = content.find(endif_marker, after_close)
if endif_pos == -1:
    print(f"  ❌ Could not find #endif marker after function in {path}")
    sys.exit(1)

# Insert new function just before the #endif (inside the guard)
content = content[:endif_pos] + new_impl + content[endif_pos:]
with open(path, 'w') as f:
    f.write(content)
print(f"  ✅ susfs_set_hide_sus_mnts_for_all_procs implemented inside #ifdef in {path}")
PYEOF
else
    echo "  ℹ️  susfs_set_hide_sus_mnts_for_all_procs already implemented"
fi

echo ""

# =============================================================================
# STEP 5 — Verification
# =============================================================================

echo "── Step 5: Verification ────────────────────────────────────────────────────"
echo ""

ALL_OK=true

check() {
    local label="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        printf "  ✅ %-50s\n" "$label"
    else
        printf "  ❌ %-50s  ← MISSING in %s\n" "$label" "$file"
        ALL_OK=false
    fi
}

# Kernel integration hooks (applied by the adjusted patch)
check "namei.c      SUS_PATH hooks"          "fs/namei.c"                "CONFIG_KSU_SUSFS_SUS_PATH"
check "namespace.c  susfs_reorder_mnt_id"    "fs/namespace.c"            "susfs_reorder_mnt_id"
check "namespace.c  sus vfsmnt allocation"   "fs/namespace.c"            "susfs_alloc_sus_vfsmnt"
check "mount.h      susfs_mnt_id_backup"     "include/linux/mount.h"     "susfs_mnt_id_backup"
check "readdir.c    inode sus path hook"     "fs/readdir.c"              "susfs_is_inode_sus_path"
check "stat.c       kstat spoof hook"        "fs/stat.c"                 "susfs_sus_ino_for_generic_fillattr"
check "statfs.c     mount hiding hook"       "fs/statfs.c"               "DEFAULT_KSU_MNT_ID"
check "proc_namespace mount hiding"          "fs/proc_namespace.c"       "susfs_hide_sus_mnts_for_non_su"
check "proc/fd.c    fd mnt_id hiding"        "fs/proc/fd.c"              "DEFAULT_KSU_MNT_ID"
check "proc/cmdline cmdline spoofing"        "fs/proc/cmdline.c"         "susfs_spoof_cmdline_or_bootconfig"
check "proc/task_mmu maps hiding"            "fs/proc/task_mmu.c"        "BIT_SUS_MAPS"
check "sys.c        uname spoofing"          "kernel/sys.c"              "susfs_spoof_uname"
check "kallsyms.c   symbol hiding"           "kernel/kallsyms.c"         "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS"

# Linker error fix
check "avc.c        bool definition"         "security/selinux/avc.c"    "susfs_is_avc_log_spoofing_enabled = false"

# Missing v2.0.0 symbols (step 4) — verify they are inside the ifdef guard
check "susfs_def.h  ALL_PROCS cmd define"    "include/linux/susfs_def.h" "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"
check "susfs.h      ALL_PROCS declaration"   "include/linux/susfs.h"     "susfs_set_hide_sus_mnts_for_all_procs"
check "susfs.c      ALL_PROCS implementation" "fs/susfs.c"               "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"

# Extra: confirm the new function is inside the #ifdef guard in susfs.c
# by checking that it appears before the #endif line
python3 - "fs/susfs.c" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

fn_pos     = content.find("susfs_set_hide_sus_mnts_for_all_procs")
endif_pos  = content.find(
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT',
    content.find("susfs_set_hide_sus_mnts_for_non_su_procs")
)
if fn_pos != -1 and endif_pos != -1 and fn_pos < endif_pos:
    print("  ✅ susfs.c ALL_PROCS impl is inside #ifdef guard        ")
elif fn_pos != -1 and endif_pos != -1 and fn_pos > endif_pos:
    print("  ❌ susfs.c ALL_PROCS impl is OUTSIDE #ifdef guard ← BAD")
    sys.exit(1)
PYEOF

echo ""

if [ "$ALL_OK" = true ] && [ -z "$REJECT_FILES" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅  All SUSFS kernel hooks applied and all symbols verified."
    echo "      Ready to build."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
elif [ "$ALL_OK" = true ] && [ -n "$REJECT_FILES" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️   Symbols OK but some hunks were rejected (see .rej files above)."
    echo "      The kernel may still compile; rejected features will be inactive."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ❌  One or more checks failed — see above."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
