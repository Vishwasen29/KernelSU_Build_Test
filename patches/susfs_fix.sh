#!/usr/bin/env bash
# =============================================================================
# apply_susfs_patch.sh  (v4 — handles all known rejection cases)
#
# Adjusts susfs_patch_to_4_19.patch for the rsuntk/KernelSU workflow and
# applies it to the kernel source tree.
#
# HANDLES:
#   - Skips files already provided by the workflow (susfs.c/h, susfs_def.h,
#     Makefile)
#   - Replaces broken avc.c hunk (UB sad.tsid read) with safe bool definition
#   - Manually applies hunks that git apply rejects due to context mismatch:
#       * include/linux/mount.h   (ANDROID_KABI_RESERVE vs KABI_USE)
#       * fs/proc/task_mmu.c     (pagemap_read hunk — applied manually with
#                                 multiple fallback context patterns; all other
#                                 task_mmu.c hunks applied via git apply)
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

# These are handled manually in later steps due to context mismatches.
# NOTE: fs/proc/task_mmu.c is intentionally NOT in this set — git apply handles
# most of its hunks fine. Only the pagemap_read hunk is fixed manually in Step 3b.
MANUAL_APPLY = {
    "include/linux/mount.h",
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

# Clean up task_mmu.c.rej if any — the pagemap_read hunk is handled manually in Step 3b
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    echo "  ℹ️  Removing fs/proc/task_mmu.c.rej (pagemap_read hunk applied manually in Step 3b)"
    rm -f "fs/proc/task_mmu.c.rej"
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

# ── 3b. fs/proc/task_mmu.c (pagemap_read hunks) ──────────────────────────────
# Most task_mmu.c hunks are applied by git apply (show_map_vma, show_smap,
# smaps_rollup). Only the pagemap_read hunk tends to fail due to line-number
# drift. We fix it here with multiple fallback context patterns covering:
#   - Kernels with mmap_sem (4.19 vanilla)
#   - Kernels with mmap_lock backport
#   - Kernels with or without a blank line between up_read and start_vaddr
python3 - "fs/proc/task_mmu.c" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()

already_maps  = "BIT_SUS_MAPS" in content
already_pme   = "pm.buffer->pme = 0" in content
already_decl  = "CONFIG_KSU_SUSFS_SUS_MAP" in content and "struct vm_area_struct *vma;" in content

# ── Hunk A: add vma declaration inside pagemap_read ────────────────────────
# Look for the local-variable block at the top of pagemap_read.
# Try several anchor lines in order of specificity.
hunk_a_applied = False
if already_decl:
    print("  ℹ️  task_mmu.c: vma declaration already present")
    hunk_a_applied = True
else:
    # Candidates: lines that appear right before the `if (!mm || !mmget_not_zero` guard
    candidates_a = [
        # Original patch context
        (
            "\tint ret = 0, copied = 0;\n"
            "\n"
            "\tif (!mm || !mmget_not_zero(mm))\n"
        ),
        # Variant without blank line
        (
            "\tint ret = 0, copied = 0;\n"
            "\tif (!mm || !mmget_not_zero(mm))\n"
        ),
        # Some kernels spell it slightly differently
        (
            "\tint ret = 0, copied = 0;\n"
            "\n"
            "\tif (!mm || !mmget_not_zero(mm)) {\n"
        ),
    ]
    for old_a in candidates_a:
        # Build the replacement preserving the exact original ending
        # We insert the guard before the blank+if block
        new_a = (
            "\tint ret = 0, copied = 0;\n"
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
            "\tstruct vm_area_struct *vma;\n"
            "#endif\n"
        ) + old_a[len("\tint ret = 0, copied = 0;\n"):]
        if old_a in content:
            content = content.replace(old_a, new_a, 1)
            hunk_a_applied = True
            print("  ✅ task_mmu.c: pagemap_read vma declaration added")
            break
    if not hunk_a_applied:
        print("  ⚠️  task_mmu.c: could not add vma declaration — trying without it")

# ── Hunk B: add the SUS_MAP check after walk_page_range/up_read ────────────
if already_pme and already_maps:
    print("  ℹ️  task_mmu.c: pagemap_read SUS_MAP check already applied")
else:
    # Multiple candidate patterns — some kernels have a blank line between
    # up_read and start_vaddr = end; some don't.
    candidates_b = [
        # With no blank line (most common 4.19 layout)
        (
            "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
            "\t\tup_read(&mm->mmap_sem);\n"
            "\t\tstart_vaddr = end;\n"
        ),
        # With blank line
        (
            "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
            "\t\tup_read(&mm->mmap_sem);\n"
            "\n"
            "\t\tstart_vaddr = end;\n"
        ),
        # With mmap_lock (newer 4.19 trees backport mmap_lock naming)
        (
            "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
            "\t\tup_read(&mm->mmap_lock);\n"
            "\t\tstart_vaddr = end;\n"
        ),
        (
            "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
            "\t\tup_read(&mm->mmap_lock);\n"
            "\n"
            "\t\tstart_vaddr = end;\n"
        ),
    ]

    # The replacement inserts the SUS_MAP block between up_read and start_vaddr
    def make_replacement_b(old_b, lock_name):
        """Build new content preserving the trailing start_vaddr line."""
        # Determine where 'start_vaddr = end' begins within old_b
        trailing = old_b[old_b.rfind("\t\tstart_vaddr"):]
        return (
            "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
            f"\t\tup_read(&mm->{lock_name});\n"
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
            "\t\tvma = find_vma(mm, start_vaddr);\n"
            "\t\tif (vma && vma->vm_file) {\n"
            "\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
            "\t\t\tif (unlikely(inode->i_mapping->flags & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n"
            "\t\t\t\tpm.buffer->pme = 0;\n"
            "\t\t\t}\n"
            "\t\t}\n"
            "#endif\n"
        ) + trailing

    applied_b = False
    for old_b in candidates_b:
        if old_b in content:
            lock = "mmap_lock" if "mmap_lock" in old_b else "mmap_sem"
            new_b = make_replacement_b(old_b, lock)
            content = content.replace(old_b, new_b, 1)
            applied_b = True
            print("  ✅ task_mmu.c: pagemap_read SUS_MAP check applied")
            break

    if not applied_b:
        # Last-resort: use regex to find walk_page_range in pagemap_read context
        m = re.search(
            r'(\t\tret = walk_page_range\(start_vaddr, end, &pagemap_walk\);\n'
            r'\t\tup_read\(&mm->mmap_(?:sem|lock)\);\n)'
            r'(\n?)'
            r'(\t\tstart_vaddr = end;\n)',
            content
        )
        if m:
            lock = "mmap_lock" if "mmap_lock" in m.group(1) else "mmap_sem"
            new_b = (
                f"\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
                f"\t\tup_read(&mm->{lock});\n"
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
            content = content[:m.start()] + new_b + content[m.end():]
            print("  ✅ task_mmu.c: pagemap_read SUS_MAP check applied (regex fallback)")
            applied_b = True

    if not applied_b:
        print("  ⚠️  task_mmu.c: pagemap_read context not found — minor feature missing")

with open(path, 'w') as f:
    f.write(content)
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
        mount_ifdef_pos = content.find("#ifdef CONFIG_K
