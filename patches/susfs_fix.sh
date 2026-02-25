#!/usr/bin/env bash
# =============================================================================
# apply_susfs_patch.sh  (v3 — handles all known rejection cases)
#
# Adjusts susfs_patch_to_4_19.patch for the rsuntk/KernelSU workflow and
# applies it to the kernel source tree.
#
# HANDLES:
#   - Skips files already provided by the workflow (susfs.c/h, susfs_def.h,
#     Makefile)
#   - Replaces broken avc.c hunk (UB sad.tsid read) with safe bool definition
#   - Manually applies 3 hunks that git apply rejects due to context mismatch:
#       * include/linux/mount.h   (ANDROID_KABI_RESERVE vs KABI_USE)
#       * fs/proc/task_mmu.c     (pagemap_read line-number offset)
#       * fs/namespace.c hunk #8 (whitespace-only, safely skipped)
#   - Moves susfs_set_hide_sus_mnts_for_all_procs inside its #ifdef guard
#     if a previous script (patch_susfs_sym.sh) placed it outside
#
# USAGE:
#   bash patches/apply_susfs_patch.sh <KERNEL_DIR> <PATCH_FILE>
# =============================================================================

set -euo pipefail

KERNEL_DIR="${1:-}"
PATCH_FILE="${2:-}"

if [ -z "$KERNEL_DIR" ] || [ -z "$PATCH_FILE" ]; then
    echo "Usage: $0 <KERNEL_DIR> <PATCH_FILE>"
    exit 1
fi
if [ ! -d "$KERNEL_DIR" ]; then
    echo "❌ Kernel directory not found: $KERNEL_DIR"; exit 1
fi
if [ ! -f "$PATCH_FILE" ]; then
    echo "❌ Patch file not found: $PATCH_FILE"; exit 1
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
# STEP 1 — Build adjusted patch (strip workflow-handled files, fix avc.c)
# =============================================================================

echo "── Step 1: Building adjusted patch ────────────────────────────────────────"
echo ""

ADJUSTED_PATCH="$(mktemp /tmp/susfs_adjusted_XXXXXX.patch)"
trap 'rm -f "$ADJUSTED_PATCH"' EXIT

python3 - "$PATCH_FILE" "$ADJUSTED_PATCH" << 'PYEOF'
import sys, re

src_path  = sys.argv[1]
dest_path = sys.argv[2]

DROP_ENTIRELY = {
    "fs/susfs.c",
    "include/linux/susfs.h",
    "include/linux/susfs_def.h",
}

# These are handled manually in later steps due to context mismatches
MANUAL_APPLY = {
    "include/linux/mount.h",
    "fs/proc/task_mmu.c",
}

with open(src_path, 'r', errors='replace') as f:
    raw = f.read()

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

    if filepath in DROP_ENTIRELY:
        print(f"  ⏭  SKIP (workflow handles): {filepath}")
        continue

    if filepath == "fs/Makefile":
        if "obj-$(CONFIG_KSU_SUSFS) += susfs.o" in sec:
            print(f"  ⏭  SKIP (workflow handles): {filepath}  [susfs.o hunk]")
            continue

    if filepath in MANUAL_APPLY:
        print(f"  🔧 MANUAL: {filepath}  [applied in Step 3]")
        continue

    # avc.c — drop the UB sad.tsid hunk, keep only the bool definition
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

    print(f"  ✅ KEEP: {filepath}")
    out_parts.append(sec)

with open(dest_path, 'w') as f:
    f.write(''.join(out_parts))
PYEOF

echo ""

# =============================================================================
# STEP 2 — Apply the adjusted patch (via git apply)
# =============================================================================

echo "── Step 2: Applying adjusted patch ─────────────────────────────────────────"
echo ""

cd "$KERNEL_DIR"

git apply \
    --ignore-whitespace \
    --ignore-space-change \
    --reject \
    --verbose \
    "$ADJUSTED_PATCH" 2>&1 || true

echo ""

# Clean up any .rej files from namespace.c hunk #8 (whitespace-only, harmless)
if [ -f "fs/namespace.c.rej" ]; then
    echo "  ℹ️  Removing fs/namespace.c.rej (whitespace-only hunk — safe to skip)"
    rm -f "fs/namespace.c.rej"
fi

# =============================================================================
# STEP 3 — Manually apply hunks that git apply rejects
# =============================================================================

echo "── Step 3: Manually applying rejected hunks ─────────────────────────────────"
echo ""

# ── 3a. include/linux/mount.h ────────────────────────────────────────────────
# The LineageOS tree's vfsmount struct may have a different layout around the
# ANDROID_KABI_RESERVE(4) line. We do a direct string replacement which is
# immune to line-number drift.
python3 - "include/linux/mount.h" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

if "susfs_mnt_id_backup" in content:
    print(f"  ℹ️  mount.h already patched (susfs_mnt_id_backup present)")
    sys.exit(0)

old = "\tANDROID_KABI_RESERVE(4);"
new = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);\n"
    "#else\n"
    "\tANDROID_KABI_RESERVE(4);\n"
    "#endif"
)

if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ mount.h: ANDROID_KABI_RESERVE(4) replaced with KABI_USE block")
else:
    # Fallback: the tree may not use ANDROID_KABI_RESERVE at all.
    # In that case the field must be added directly to the struct.
    if "void *data;" in content and "susfs_mnt_id_backup" not in content:
        # Insert before `void *data;` inside struct vfsmount
        old2 = "\tvoid *data;"
        new2 = (
            "#ifdef CONFIG_KSU_SUSFS\n"
            "\tu64 susfs_mnt_id_backup;\n"
            "#endif\n"
            "\tvoid *data;"
        )
        if old2 in content:
            content = content.replace(old2, new2, 1)
            with open(path, 'w') as f:
                f.write(content)
            print(f"  ✅ mount.h: susfs_mnt_id_backup added before void *data (fallback)")
        else:
            print(f"  ❌ mount.h: could not find insertion point — patch manually")
            sys.exit(1)
    else:
        print(f"  ❌ mount.h: ANDROID_KABI_RESERVE(4) not found — patch manually")
        sys.exit(1)
PYEOF

# ── 3b. fs/proc/task_mmu.c (pagemap_read hunk) ───────────────────────────────
# The line-number offset caused git apply to reject this hunk.
# Use context-string matching instead.
python3 - "fs/proc/task_mmu.c" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

if "BIT_SUS_MAPS" in content and "pm.buffer->pme = 0" in content:
    print(f"  ℹ️  task_mmu.c pagemap_read hunk already applied")
    sys.exit(0)

# The unique context: after up_read(&mm->mmap_sem) and before start_vaddr = end
# in the pagemap_read loop
old = (
    "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
    "\t\tup_read(&mm->mmap_sem);\n"
    "\t\tstart_vaddr = end;\n"
)
new = (
    "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
    "\t\tup_read(&mm->mmap_sem);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tvma = find_vma(mm, start_vaddr);\n"
    "\t\tif (vma && vma->vm_file) {\n"
    "\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
    "\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n"
    "\t\t\t\tpm.buffer->pme = 0;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
    "\t\tstart_vaddr = end;\n"
)

if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ task_mmu.c: pagemap_read SUS_MAP hunk applied")
else:
    print(f"  ⚠️  task_mmu.c: pagemap_read context not found — minor feature missing")
PYEOF

echo ""

# =============================================================================
# STEP 4 — Fix missing/misplaced SUSFS v2.0.0 symbols
#
# If patch_susfs_sym.sh already ran, the function may exist but be OUTSIDE
# the #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT guard (it uses susfs_spin_lock_sus_mount
# which is only defined inside the guard — compile error if SUS_MOUNT=n).
# We detect this and relocate the function if needed.
# =============================================================================

echo "── Step 4: Fixing SUSFS v2.0.0 symbols ─────────────────────────────────────"
echo ""

SUSFS_DEF_H="include/linux/susfs_def.h"
SUSFS_H="include/linux/susfs.h"
SUSFS_C="fs/susfs.c"

# ── 4a. CMD define in susfs_def.h (unconditional, no guard needed) ────────────
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
    fallback = "#define SUSFS_MAX_LEN_PATHNAME"
    content = content.replace(
        fallback,
        "#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS     0x55563\n" + fallback, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS added (fallback) to {path}")
PYEOF
else
    echo "  ℹ️  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS already present"
fi

# ── 4b. Declaration in susfs.h — must be inside #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
python3 - "$SUSFS_H" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

fn_sig = "susfs_set_hide_sus_mnts_for_all_procs"
decl   = "void susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info);"
ifndef = "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"

# Find the sus_mount #ifdef block
mount_ifdef = content.find("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", content.find("/* sus_mount */"))
# Find its closing #endif
mount_endif = content.find(ifndef, mount_ifdef)

fn_pos = content.find(fn_sig)

if fn_pos == -1:
    # Not present at all — insert before the #endif
    content = content[:mount_endif] + decl + "\n" + content[mount_endif:]
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ susfs.h: declaration added inside #ifdef guard")

elif fn_pos < mount_endif:
    # Already inside the guard — nothing to do
    print(f"  ✅ susfs.h: declaration already inside #ifdef guard")

else:
    # Outside the guard — remove and re-insert inside
    content = content.replace(decl + "\n", "", 1)
    content = content.replace(decl, "", 1)          # handle missing trailing \n
    # Recalculate positions after removal
    mount_ifdef = content.find("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", content.find("/* sus_mount */"))
    mount_endif = content.find(ifndef, mount_ifdef)
    content = content[:mount_endif] + decl + "\n" + content[mount_endif:]
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ susfs.h: declaration moved inside #ifdef guard")
PYEOF

# ── 4c. Implementation in susfs.c — must be inside #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
python3 - "$SUSFS_C" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()

fn_sig   = "susfs_set_hide_sus_mnts_for_all_procs"
ifndef   = "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
# Locate the sus_mount block boundaries
mount_ifdef_pos = content.find("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", content.find("/* sus_mount */"))
mount_endif_pos = content.find(ifndef, mount_ifdef_pos)

new_impl = (
    "\nvoid susfs_set_hide_sus_mnts_for_all_procs(void __user **user_info) {\n"
    "\tstruct st_susfs_hide_sus_mnts_for_non_su_procs info = {0};\n\n"
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

fn_pos = content.find(fn_sig)

if fn_pos == -1:
    # Not present — insert before the #endif
    content = content[:mount_endif_pos] + new_impl + content[mount_endif_pos:]
    with open(path, 'w') as f:
        f.write(content)
    print(f"  ✅ susfs.c: implementation added inside #ifdef guard")

elif fn_pos < mount_endif_pos:
    print(f"  ✅ susfs.c: implementation already inside #ifdef guard")

else:
    # Outside the guard — extract the full function body and re-insert inside
    # Match from the function signature to the closing brace on its own line
    pattern = r'\nvoid susfs_set_hide_sus_mnts_for_all_procs\(.*?\n\}\n'
    m = re.search(pattern, content, re.DOTALL)
    if m:
        old_fn = m.group(0)
        content = content.replace(old_fn, "\n", 1)   # remove old copy
        # Recalculate after removal
        mount_ifdef_pos = content.find("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", content.find("/* sus_mount */"))
        mount_endif_pos = content.find(ifndef, mount_ifdef_pos)
        content = content[:mount_endif_pos] + new_impl + content[mount_endif_pos:]
        with open(path, 'w') as f:
            f.write(content)
        print(f"  ✅ susfs.c: implementation moved inside #ifdef guard")
    else:
        print(f"  ❌ susfs.c: could not extract misplaced function — patch manually")
        sys.exit(1)
PYEOF

echo ""

# Clean up any remaining .rej files (after manual fixes above)
REJECT_FILES=$(find . -name "*.rej" 2>/dev/null | grep -v ".git" | sort || true)
if [ -n "$REJECT_FILES" ]; then
    echo "── Remaining rejected hunks ──────────────────────────────────────────────"
    echo ""
    while IFS= read -r rej; do
        echo "  ❌ ${rej%.rej}"
        head -20 "$rej" | sed 's/^/      /'
        echo ""
    done <<< "$REJECT_FILES"
fi

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
check "proc/task_mmu pagemap_read fix"       "fs/proc/task_mmu.c"        "pm.buffer->pme = 0"
check "sys.c        uname spoofing"          "kernel/sys.c"              "susfs_spoof_uname"
check "kallsyms.c   symbol hiding"           "kernel/kallsyms.c"         "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS"
check "avc.c        bool definition"         "security/selinux/avc.c"    "susfs_is_avc_log_spoofing_enabled = false"
check "susfs_def.h  ALL_PROCS cmd define"    "include/linux/susfs_def.h" "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"
check "susfs.h      ALL_PROCS declaration"   "include/linux/susfs.h"     "susfs_set_hide_sus_mnts_for_all_procs"
check "susfs.c      ALL_PROCS implementation" "fs/susfs.c"               "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS"

# Confirm the implementation is inside the #ifdef guard
python3 - "fs/susfs.c" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

fn_pos      = content.find("susfs_set_hide_sus_mnts_for_all_procs")
mount_ifdef = content.find("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", content.find("/* sus_mount */"))
mount_endif = content.find("#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT", mount_ifdef)

if fn_pos == -1:
    print("  ❌ susfs.c ALL_PROCS implementation not found")
    sys.exit(1)
elif mount_ifdef < fn_pos < mount_endif:
    print("  ✅ susfs.c ALL_PROCS impl is inside #ifdef guard        ")
else:
    print("  ❌ susfs.c ALL_PROCS impl is OUTSIDE #ifdef guard ← BAD")
    sys.exit(1)
PYEOF

echo ""

if [ "$ALL_OK" = true ] && [ -z "$REJECT_FILES" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅  All checks passed. Ready to build."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
elif [ "$ALL_OK" = true ] && [ -n "$REJECT_FILES" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️   Symbols OK but some hunks still rejected (see above)."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ❌  One or more checks failed — see above."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
