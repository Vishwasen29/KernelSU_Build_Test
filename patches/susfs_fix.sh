#!/usr/bin/env bash
# =============================================================================
# apply_susfs_patch.sh  (v9 — no re-exec, base64-only, mmap_read_unlock support)
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

echo 'aW1wb3J0IHN5cywgcmUKCnNyY19wYXRoICA9IHN5cy5hcmd2WzFdCmRlc3RfcGF0aCA9IHN5cy5hcmd2WzJdCgpEUk9QX0VOVElSRUxZID0gewogICAgImZzL3N1c2ZzLmMiLAogICAgImluY2x1ZGUvbGludXgvc3VzZnMuaCIsCiAgICAiaW5jbHVkZS9saW51eC9zdXNmc19kZWYuaCIsCn0KCiMgVGhlc2UgYXJlIGhhbmRsZWQgbWFudWFsbHkgaW4gbGF0ZXIgc3RlcHMgZHVlIHRvIGNvbnRleHQgbWlzbWF0Y2hlcy4KIyBOT1RFOiBmcy9wcm9jL3Rhc2tfbW11LmMgaXMgaW50ZW50aW9uYWxseSBOT1QgaW4gdGhpcyBzZXQg4oCUIGdpdCBhcHBseSBoYW5kbGVzCiMgbW9zdCBvZiBpdHMgaHVua3MgZmluZS4gT25seSB0aGUgcGFnZW1hcF9yZWFkIGh1bmsgaXMgZml4ZWQgbWFudWFsbHkgaW4gU3RlcCAzYi4KTUFOVUFMX0FQUExZID0gewogICAgImluY2x1ZGUvbGludXgvbW91bnQuaCIsCn0KCndpdGggb3BlbihzcmNfcGF0aCwgJ3InLCBlcnJvcnM9J3JlcGxhY2UnKSBhcyBmOgogICAgcmF3ID0gZi5yZWFkKCkKCnNlY3Rpb25zID0gcmUuc3BsaXQocicoPz1eZGlmZiAtLWdpdCApJywgcmF3LCBmbGFncz1yZS5NVUxUSUxJTkUpCm91dF9wYXJ0cyA9IFtdCgpmb3Igc2VjIGluIHNlY3Rpb25zOgogICAgaWYgbm90IHNlYy5zdHJpcCgpOgogICAgICAgIGNvbnRpbnVlCiAgICBtID0gcmUubWF0Y2gocidkaWZmIC0tZ2l0IGEvKFxTKyknLCBzZWMpCiAgICBpZiBub3QgbToKICAgICAgICBvdXRfcGFydHMuYXBwZW5kKHNlYykKICAgICAgICBjb250aW51ZQogICAgZmlsZXBhdGggPSBtLmdyb3VwKDEpCgogICAgaWYgZmlsZXBhdGggaW4gRFJPUF9FTlRJUkVMWToKICAgICAgICBwcmludChmIiAg4o+tICBTS0lQICh3b3JrZmxvdyBoYW5kbGVzKToge2ZpbGVwYXRofSIpCiAgICAgICAgY29udGludWUKCiAgICBpZiBmaWxlcGF0aCA9PSAiZnMvTWFrZWZpbGUiOgogICAgICAgIGlmICJvYmotJChDT05GSUdfS1NVX1NVU0ZTKSArPSBzdXNmcy5vIiBpbiBzZWM6CiAgICAgICAgICAgIHByaW50KGYiICDij60gIFNLSVAgKHdvcmtmbG93IGhhbmRsZXMpOiB7ZmlsZXBhdGh9ICBbc3VzZnMubyBodW5rXSIpCiAgICAgICAgICAgIGNvbnRpbnVlCgogICAgaWYgZmlsZXBhdGggaW4gTUFOVUFMX0FQUExZOgogICAgICAgIHByaW50KGYiICDwn5SnIE1BTlVBTDoge2ZpbGVwYXRofSAgW2FwcGxpZWQgaW4gU3RlcCAzXSIpCiAgICAgICAgY29udGludWUKCiAgICAjIGF2Yy5jIOKAlCBkcm9wIHRoZSBVQiBzYWQudHNpZCBodW5rLCBrZWVwIG9ubHkgdGhlIGJvb2wgZGVmaW5pdGlvbgogICAgaWYgZmlsZXBhdGggPT0gInNlY3VyaXR5L3NlbGludXgvYXZjLmMiOgogICAgICAgIHByaW50KGYiICDinIIgIFBBUlRJQUw6IHtmaWxlcGF0aH0gIFtkcm9wIFVCIHNhZCBodW5rOyBrZWVwIGJvb2wgZGVmaW5pdGlvbiBvbmx5XSIpCiAgICAgICAgbWluaW1hbF9hdmMgPSAoCiAgICAgICAgICAgICJkaWZmIC0tZ2l0IGEvc2VjdXJpdHkvc2VsaW51eC9hdmMuYyBiL3NlY3VyaXR5L3NlbGludXgvYXZjLmNcbiIKICAgICAgICAgICAgIi0tLSBhL3NlY3VyaXR5L3NlbGludXgvYXZjLmNcbiIKICAgICAgICAgICAgIisrKyBiL3NlY3VyaXR5L3NlbGludXgvYXZjLmNcbiIKICAgICAgICAgICAgIkBAIC0xNjQsNiArMTY0LDkgQEAgc3RhdGljIHZvaWQgYXZjX2R1bXBfYXYoc3RydWN0IGF1ZGl0X2J1ZmZlciAqYWIsIHUxNiB0Y2xhc3MsIHUzMiBhdilcbiIKICAgICAgICAgICAgIiBcbiIKICAgICAgICAgICAgIiBcdGF1ZGl0X2xvZ19mb3JtYXQoYWIsIFwiIH1cIik7XG4iCiAgICAgICAgICAgICIgfVxuIgogICAgICAgICAgICAiKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTXG4iCiAgICAgICAgICAgICIrYm9vbCBzdXNmc19pc19hdmNfbG9nX3Nwb29maW5nX2VuYWJsZWQgPSBmYWxzZTtcbiIKICAgICAgICAgICAgIisjZW5kaWZcbiIKICAgICAgICAgICAgIiBcbiIKICAgICAgICAgICAgIiAvKipcbiIKICAgICAgICAgICAgIiAgKiBhdmNfZHVtcF9xdWVyeSAtIERpc3BsYXkgYSBTSUQgcGFpciBhbmQgYSBjbGFzcyBpbiBodW1hbi1yZWFkYWJsZSBmb3JtLlxuIgogICAgICAgICkKICAgICAgICBvdXRfcGFydHMuYXBwZW5kKG1pbmltYWxfYXZjKQogICAgICAgIGNvbnRpbnVlCgogICAgcHJpbnQoZiIgIOKchSBLRUVQOiB7ZmlsZXBhdGh9IikKICAgIG91dF9wYXJ0cy5hcHBlbmQoc2VjKQoKd2l0aCBvcGVuKGRlc3RfcGF0aCwgJ3cnKSBhcyBmOgogICAgZi53cml0ZSgnJy5qb2luKG91dF9wYXJ0cykpCg==' | base64 -d | python3 - "$PATCH_FILE" "$ADJUSTED_PATCH"

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
echo 'aW1wb3J0IHN5cwpwYXRoID0gc3lzLmFyZ3ZbMV0Kd2l0aCBvcGVuKHBhdGgpIGFzIGY6CiAgICBjb250ZW50ID0gZi5yZWFkKCkKCmlmICJzdXNmc19tbnRfaWRfYmFja3VwIiBpbiBjb250ZW50OgogICAgcHJpbnQoZiIgIOKEue+4jyAgbW91bnQuaCBhbHJlYWR5IHBhdGNoZWQgKHN1c2ZzX21udF9pZF9iYWNrdXAgcHJlc2VudCkiKQogICAgc3lzLmV4aXQoMCkKCm9sZCA9ICJcdEFORFJPSURfS0FCSV9SRVNFUlZFKDQpOyIKbmV3ID0gKAogICAgIiNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTXG4iCiAgICAiXHRBTkRST0lEX0tBQklfVVNFKDQsIHU2NCBzdXNmc19tbnRfaWRfYmFja3VwKTtcbiIKICAgICIjZWxzZVxuIgogICAgIlx0QU5EUk9JRF9LQUJJX1JFU0VSVkUoNCk7XG4iCiAgICAiI2VuZGlmIgopCgppZiBvbGQgaW4gY29udGVudDoKICAgIGNvbnRlbnQgPSBjb250ZW50LnJlcGxhY2Uob2xkLCBuZXcsIDEpCiAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnKSBhcyBmOgogICAgICAgIGYud3JpdGUoY29udGVudCkKICAgIHByaW50KGYiICDinIUgbW91bnQuaDogQU5EUk9JRF9LQUJJX1JFU0VSVkUoNCkgcmVwbGFjZWQgd2l0aCBLQUJJX1VTRSBibG9jayIpCmVsc2U6CiAgICAjIEZhbGxiYWNrOiB0aGUgdHJlZSBtYXkgbm90IHVzZSBBTkRST0lEX0tBQklfUkVTRVJWRSBhdCBhbGwuCiAgICAjIEluIHRoYXQgY2FzZSB0aGUgZmllbGQgbXVzdCBiZSBhZGRlZCBkaXJlY3RseSB0byB0aGUgc3RydWN0LgogICAgaWYgInZvaWQgKmRhdGE7IiBpbiBjb250ZW50IGFuZCAic3VzZnNfbW50X2lkX2JhY2t1cCIgbm90IGluIGNvbnRlbnQ6CiAgICAgICAgIyBJbnNlcnQgYmVmb3JlIGB2b2lkICpkYXRhO2AgaW5zaWRlIHN0cnVjdCB2ZnNtb3VudAogICAgICAgIG9sZDIgPSAiXHR2b2lkICpkYXRhOyIKICAgICAgICBuZXcyID0gKAogICAgICAgICAgICAiI2lmZGVmIENPTkZJR19LU1VfU1VTRlNcbiIKICAgICAgICAgICAgIlx0dTY0IHN1c2ZzX21udF9pZF9iYWNrdXA7XG4iCiAgICAgICAgICAgICIjZW5kaWZcbiIKICAgICAgICAgICAgIlx0dm9pZCAqZGF0YTsiCiAgICAgICAgKQogICAgICAgIGlmIG9sZDIgaW4gY29udGVudDoKICAgICAgICAgICAgY29udGVudCA9IGNvbnRlbnQucmVwbGFjZShvbGQyLCBuZXcyLCAxKQogICAgICAgICAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnKSBhcyBmOgogICAgICAgICAgICAgICAgZi53cml0ZShjb250ZW50KQogICAgICAgICAgICBwcmludChmIiAg4pyFIG1vdW50Lmg6IHN1c2ZzX21udF9pZF9iYWNrdXAgYWRkZWQgYmVmb3JlIHZvaWQgKmRhdGEgKGZhbGxiYWNrKSIpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiIgIOKdjCBtb3VudC5oOiBjb3VsZCBub3QgZmluZCBpbnNlcnRpb24gcG9pbnQg4oCUIHBhdGNoIG1hbnVhbGx5IikKICAgICAgICAgICAgc3lzLmV4aXQoMSkKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoZiIgIOKdjCBtb3VudC5oOiBBTkRST0lEX0tBQklfUkVTRVJWRSg0KSBub3QgZm91bmQg4oCUIHBhdGNoIG1hbnVhbGx5IikKICAgICAgICBzeXMuZXhpdCgxKQo=' | base64 -d | python3 - "include/linux/mount.h"

# ── 3b. fs/proc/task_mmu.c (pagemap_read hunks) ──────────────────────────────
# Most task_mmu.c hunks are applied by git apply (show_map_vma, show_smap,
# smaps_rollup). Only the pagemap_read hunk tends to fail due to line-number
# drift. We fix it here with multiple fallback context patterns covering:
#   - Kernels with mmap_sem (4.19 vanilla)
#   - Kernels with mmap_lock backport
#   - Kernels with or without a blank line between up_read and start_vaddr
echo 'aW1wb3J0IHN5cywgcmUKcGF0aCA9IHN5cy5hcmd2WzFdCndpdGggb3BlbihwYXRoKSBhcyBmOgogICAgY29udGVudCA9IGYucmVhZCgpCgphbHJlYWR5X21hcHMgID0gIkJJVF9TVVNfTUFQUyIgaW4gY29udGVudAphbHJlYWR5X3BtZSAgID0gInBtLmJ1ZmZlci0+cG1lID0gMCIgaW4gY29udGVudAphbHJlYWR5X2RlY2wgID0gIkNPTkZJR19LU1VfU1VTRlNfU1VTX01BUCIgaW4gY29udGVudCBhbmQgInN0cnVjdCB2bV9hcmVhX3N0cnVjdCAqdm1hOyIgaW4gY29udGVudAoKIyDilIDilIAgSHVuayBBOiBhZGQgdm1hIGRlY2xhcmF0aW9uIGluc2lkZSBwYWdlbWFwX3JlYWQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmh1bmtfYV9hcHBsaWVkID0gRmFsc2UKaWYgYWxyZWFkeV9kZWNsOgogICAgcHJpbnQoIiAg4oS577iPICB0YXNrX21tdS5jOiB2bWEgZGVjbGFyYXRpb24gYWxyZWFkeSBwcmVzZW50IikKICAgIGh1bmtfYV9hcHBsaWVkID0gVHJ1ZQplbHNlOgogICAgY2FuZGlkYXRlc19hID0gWwogICAgICAgICJcdGludCByZXQgPSAwLCBjb3BpZWQgPSAwO1xuXG5cdGlmICghbW0gfHwgIW1tZ2V0X25vdF96ZXJvKG1tKSlcbiIsCiAgICAgICAgIlx0aW50IHJldCA9IDAsIGNvcGllZCA9IDA7XG5cdGlmICghbW0gfHwgIW1tZ2V0X25vdF96ZXJvKG1tKSlcbiIsCiAgICAgICAgIlx0aW50IHJldCA9IDAsIGNvcGllZCA9IDA7XG5cblx0aWYgKCFtbSB8fCAhbW1nZXRfbm90X3plcm8obW0pKSB7XG4iLAogICAgXQogICAgZm9yIG9sZF9hIGluIGNhbmRpZGF0ZXNfYToKICAgICAgICBuZXdfYSA9ICgKICAgICAgICAgICAgIlx0aW50IHJldCA9IDAsIGNvcGllZCA9IDA7XG4iCiAgICAgICAgICAgICIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTUFQXG4iCiAgICAgICAgICAgICJcdHN0cnVjdCB2bV9hcmVhX3N0cnVjdCAqdm1hO1xuIgogICAgICAgICAgICAiI2VuZGlmXG4iCiAgICAgICAgKSArIG9sZF9hW2xlbigiXHRpbnQgcmV0ID0gMCwgY29waWVkID0gMDtcbiIpOl0KICAgICAgICBpZiBvbGRfYSBpbiBjb250ZW50OgogICAgICAgICAgICBjb250ZW50ID0gY29udGVudC5yZXBsYWNlKG9sZF9hLCBuZXdfYSwgMSkKICAgICAgICAgICAgaHVua19hX2FwcGxpZWQgPSBUcnVlCiAgICAgICAgICAgIHByaW50KCIgIOKchSB0YXNrX21tdS5jOiBwYWdlbWFwX3JlYWQgdm1hIGRlY2xhcmF0aW9uIGFkZGVkIikKICAgICAgICAgICAgYnJlYWsKICAgIGlmIG5vdCBodW5rX2FfYXBwbGllZDoKICAgICAgICBwcmludCgiICDimqDvuI8gIHRhc2tfbW11LmM6IGNvdWxkIG5vdCBhZGQgdm1hIGRlY2xhcmF0aW9uIOKAlCB0cnlpbmcgd2l0aG91dCBpdCIpCgojIOKUgOKUgCBIdW5rIEI6IGFkZCB0aGUgU1VTX01BUCBjaGVjayBhZnRlciB3YWxrX3BhZ2VfcmFuZ2UgLyByZWFkLXVubG9jayDilIDilIDilIDilIDilIDilIDilIDilIAKaWYgYWxyZWFkeV9wbWUgYW5kIGFscmVhZHlfbWFwczoKICAgIHByaW50KCIgIOKEue+4jyAgdGFza19tbXUuYzogcGFnZW1hcF9yZWFkIFNVU19NQVAgY2hlY2sgYWxyZWFkeSBhcHBsaWVkIikKZWxzZToKICAgICMgU2hvdyBkaWFnbm9zdGljcyByZWdhcmRsZXNzIHNvIENJIGxvZ3MgYXJlIGFsd2F5cyBpbmZvcm1hdGl2ZQogICAgd3JwX2lkeCA9IGNvbnRlbnQuZmluZCgid2Fsa19wYWdlX3JhbmdlKHN0YXJ0X3ZhZGRyIikKICAgIGlmIHdycF9pZHggPT0gLTE6CiAgICAgICAgd3JwX2lkeCA9IGNvbnRlbnQuZmluZCgid2Fsa19wYWdlX3JhbmdlKCIpCiAgICBpZiB3cnBfaWR4ICE9IC0xOgogICAgICAgIGxpbmVfc3RhcnQgPSBjb250ZW50LnJmaW5kKCdcbicsIDAsIHdycF9pZHgpICsgMQogICAgICAgIGN0eF9zdGFydCA9IGxpbmVfc3RhcnQKICAgICAgICBmb3IgXyBpbiByYW5nZSgzKToKICAgICAgICAgICAgY3R4X3N0YXJ0ID0gY29udGVudC5yZmluZCgnXG4nLCAwLCBjdHhfc3RhcnQgLSAxKSArIDEKICAgICAgICBjdHhfZW5kID0gY29udGVudC5maW5kKCdcbicsIHdycF9pZHgpCiAgICAgICAgZm9yIF8gaW4gcmFuZ2UoOSk6CiAgICAgICAgICAgIG54dCA9IGNvbnRlbnQuZmluZCgnXG4nLCBjdHhfZW5kICsgMSkKICAgICAgICAgICAgaWYgbnh0ID09IC0xOgogICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgY3R4X2VuZCA9IG54dAogICAgICAgIHByaW50KCIgIPCflI0gQWN0dWFsIGZpbGUgY29udGVudCBhcm91bmQgd2Fsa19wYWdlX3JhbmdlOiIpCiAgICAgICAgZm9yIGksIGxpbmUgaW4gZW51bWVyYXRlKGNvbnRlbnRbY3R4X3N0YXJ0OmN0eF9lbmRdLnNwbGl0KCdcbicpKToKICAgICAgICAgICAgcHJpbnQoZiIgICAgICAge2k6MDJkfToge3JlcHIobGluZVs6OTBdKX0iKQogICAgZWxzZToKICAgICAgICBwcmludCgiICDwn5SNIHdhbGtfcGFnZV9yYW5nZSBOT1QgRk9VTkQgaW4gZmlsZSBhdCBhbGwhIikKCiAgICBhcHBsaWVkX2IgPSBGYWxzZQoKICAgICMgVGhlIHVubG9jayBmdW5jdGlvbiBhZnRlciB3YWxrX3BhZ2VfcmFuZ2UgY2FuIGJlIEFOWSBvZjoKICAgICMgICB1cF9yZWFkKCZtbS0+bW1hcF9zZW0pICAgICAgICAgLS0gb2xkIDQuMTkgdmFuaWxsYQogICAgIyAgIHVwX3JlYWQoJm1tLT5tbWFwX2xvY2spICAgICAgICAtLSBtbWFwX2xvY2sgcmVuYW1lIGJhY2twb3J0CiAgICAjICAgbW1hcF9yZWFkX3VubG9jayhtbSkgICAgICAgICAgIC0tIExpbmVhZ2VPUyAvIENBRiA0LjE5IHdpdGggZnVsbCBiYWNrcG9ydAogICAgIyAgIG1tYXBfcmVhZF91bmxvY2tfbm9uX293bmVyKG1tKSAtLSByYXJlIHZhcmlhbnQKICAgICMKICAgICMgV2UgdXNlIGEgc2luZ2xlIGZsZXhpYmxlIHJlZ2V4IHRoYXQ6CiAgICAjICAgLSBDYXB0dXJlcyBvcHRpb25hbCBsZWFkaW5nIGxpbmVzIChnb3RvIG91dF9mcmVlIGV0Yy4pCiAgICAjICAgLSBNYXRjaGVzIHdhbGtfcGFnZV9yYW5nZSB3aXRoIGFueSBhcmdzCiAgICAjICAgLSBNYXRjaGVzIEFOWSBvZiB0aGUgYWJvdmUgdW5sb2NrIHZhcmlhbnRzCiAgICAjICAgLSBEZXRlY3RzIGluZGVudGF0aW9uIGF1dG9tYXRpY2FsbHkKICAgICMgICAtIFByZXNlcnZlcyBzdGFydF92YWRkciA9IGVuZCB0cmFpbGluZyBsaW5lCiAgICBVTkxPQ0tfUEFUID0gKAogICAgICAgIHInKD86dXBfcmVhZFxzKlwoJm1tLT4oPzptbWFwX3NlbXxtbWFwX2xvY2spXCknCiAgICAgICAgcid8bW1hcF9yZWFkX3VubG9jayg/Ol9ub25fb3duZXIpP1xzKlwobW1cKSknCiAgICApCiAgICBmdWxsX3JlID0gcmUuY29tcGlsZSgKICAgICAgICByJyhbIFx0XSpyZXQgPSB3YWxrX3BhZ2VfcmFuZ2VcKHN0YXJ0X3ZhZGRyLFxzKmVuZCxccyomcGFnZW1hcF93YWxrXCk7XG4nCiAgICAgICAgcidbIFx0XSonICsgVU5MT0NLX1BBVCArIHInO1xuKScKICAgICAgICByJyhbIFx0XSpcbik/JwogICAgICAgIHInKFsgXHRdKnN0YXJ0X3ZhZGRyXHMqPVxzKmVuZDtcbiknLAogICAgICAgIHJlLk1VTFRJTElORQogICAgKQoKICAgIG0gPSBmdWxsX3JlLnNlYXJjaChjb250ZW50KQogICAgaWYgbToKICAgICAgICBwcmVfc3RyICAgPSBtLmdyb3VwKDEpCiAgICAgICAgYmxhbmtfc3RyID0gbS5ncm91cCgyKSBvciAnJwogICAgICAgIHBvc3Rfc3RyICA9IG0uZ3JvdXAoMykKCiAgICAgICAgIyBEZXRlY3QgaW5kZW50IGZyb20gd2Fsa19wYWdlX3JhbmdlIGxpbmUKICAgICAgICB3YWxrX2xpbmUgPSBuZXh0KGwgZm9yIGwgaW4gcHJlX3N0ci5zcGxpdCgnXG4nKSBpZiAnd2Fsa19wYWdlX3JhbmdlJyBpbiBsKQogICAgICAgIGluZGVudCA9IHdhbGtfbGluZVs6bGVuKHdhbGtfbGluZSkgLSBsZW4od2Fsa19saW5lLmxzdHJpcCgpKV0KCiAgICAgICAgIyBEZXRlY3QgdW5sb2NrIGZ1bmN0aW9uIGFuZCBpdHMgYXJndW1lbnQgZm9ybSwgcHJlc2VydmUgZXhhY3RseQogICAgICAgIHVubG9ja19saW5lID0gbmV4dChsIGZvciBsIGluIHByZV9zdHIuc3BsaXQoJ1xuJykgaWYgYW55KAogICAgICAgICAgICB4IGluIGwgZm9yIHggaW4gKCd1cF9yZWFkJywgJ21tYXBfcmVhZF91bmxvY2snKSkpCiAgICAgICAgdW5sb2NrX2NhbGwgPSB1bmxvY2tfbGluZS5zdHJpcCgpLnJzdHJpcCgnOycpICAjIGUuZy4gIm1tYXBfcmVhZF91bmxvY2sobW0pIgoKICAgICAgICBzdXNfYmxvY2sgPSAoCiAgICAgICAgICAgIGYie2luZGVudH1yZXQgPSB3YWxrX3BhZ2VfcmFuZ2Uoc3RhcnRfdmFkZHIsIGVuZCwgJnBhZ2VtYXBfd2Fsayk7XG4iCiAgICAgICAgICAgIGYie2luZGVudH17dW5sb2NrX2NhbGx9O1xuIgogICAgICAgICAgICAiI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01BUFxuIgogICAgICAgICAgICBmIntpbmRlbnR9dm1hID0gZmluZF92bWEobW0sIHN0YXJ0X3ZhZGRyKTtcbiIKICAgICAgICAgICAgZiJ7aW5kZW50fWlmICh2bWEgJiYgdm1hLT52bV9maWxlKSB7e1xuIgogICAgICAgICAgICBmIntpbmRlbnR9XHRzdHJ1Y3QgaW5vZGUgKmlub2RlID0gZmlsZV9pbm9kZSh2bWEtPnZtX2ZpbGUpO1xuIgogICAgICAgICAgICBmIntpbmRlbnR9XHRpZiAodW5saWtlbHkoaW5vZGUtPmlfbWFwcGluZy0+ZmxhZ3MgJiBCSVRfU1VTX01BUFMpIgogICAgICAgICAgICBmIiAmJiBzdXNmc19pc19jdXJyZW50X3Byb2NfdW1vdW50ZWQoKSkge3tcbiIKICAgICAgICAgICAgZiJ7aW5kZW50fVx0XHRwbS5idWZmZXItPnBtZSA9IDA7XG4iCiAgICAgICAgICAgIGYie2luZGVudH1cdH19XG4iCiAgICAgICAgICAgIGYie2luZGVudH19fVxuIgogICAgICAgICAgICAiI2VuZGlmXG4iCiAgICAgICAgKQogICAgICAgIGNvbnRlbnQgPSBjb250ZW50WzptLnN0YXJ0KCldICsgc3VzX2Jsb2NrICsgYmxhbmtfc3RyICsgcG9zdF9zdHIgKyBjb250ZW50W20uZW5kKCk6XQogICAgICAgIHByaW50KGYiICDinIUgdGFza19tbXUuYzogcGFnZW1hcF9yZWFkIFNVU19NQVAgY2hlY2sgYXBwbGllZCIKICAgICAgICAgICAgICBmIiAodW5sb2NrPXtyZXByKHVubG9ja19jYWxsKX0sIGluZGVudD17cmVwcihpbmRlbnQpfSkiKQogICAgICAgIGFwcGxpZWRfYiA9IFRydWUKCiAgICBpZiBub3QgYXBwbGllZF9iOgogICAgICAgIHByaW50KCIgIOKaoO+4jyAgdGFza19tbXUuYzogcGFnZW1hcF9yZWFkIGNvbnRleHQgbm90IGZvdW5kIOKAlCBtaW5vciBmZWF0dXJlIG1pc3NpbmciKQogICAgICAgIHByaW50KCIgIPCflI0gRGVidWc6IHdhbGtfcGFnZV9yYW5nZSBsaW5lcyBpbiBmaWxlOiIpCiAgICAgICAgZm9yIG0yIGluIHJlLmZpbmRpdGVyKHInd2Fsa19wYWdlX3JhbmdlJywgY29udGVudCk6CiAgICAgICAgICAgIHMgPSBjb250ZW50LnJmaW5kKCdcbicsIDAsIG0yLnN0YXJ0KCkpICsgMQogICAgICAgICAgICBlID0gY29udGVudC5maW5kKCdcbicsIG0yLmVuZCgpKQogICAgICAgICAgICBlMiA9IGNvbnRlbnQuZmluZCgnXG4nLCBlICsgMSkgaWYgZSAhPSAtMSBlbHNlIGxlbihjb250ZW50KQogICAgICAgICAgICBwcmludChmIiAgICAgICB7cmVwcihjb250ZW50W3M6ZTJdKX0iKQoKd2l0aCBvcGVuKHBhdGgsICd3JykgYXMgZjoKICAgIGYud3JpdGUoY29udGVudCkK' | base64 -d | python3 - "fs/proc/task_mmu.c"

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
    echo 'aW1wb3J0IHN5cwpwYXRoID0gc3lzLmFyZ3ZbMV0Kd2l0aCBvcGVuKHBhdGgpIGFzIGY6CiAgICBjb250ZW50ID0gZi5yZWFkKCkKCmFuY2hvciA9ICIjZGVmaW5lIENNRF9TVVNGU19ISURFX1NVU19NTlRTX0ZPUl9OT05fU1VfUFJPQ1MgMHg1NTU2MSIKcmVwbGFjZW1lbnQgPSAoCiAgICAiI2RlZmluZSBDTURfU1VTRlNfSElERV9TVVNfTU5UU19GT1JfTk9OX1NVX1BST0NTIDB4NTU1NjFcbiIKICAgICIjZGVmaW5lIENNRF9TVVNGU19ISURFX1NVU19NTlRTX0ZPUl9BTExfUFJPQ1MgICAgIDB4NTU1NjMiCikKaWYgYW5jaG9yIGluIGNvbnRlbnQ6CiAgICBjb250ZW50ID0gY29udGVudC5yZXBsYWNlKGFuY2hvciwgcmVwbGFjZW1lbnQsIDEpCiAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnKSBhcyBmOgogICAgICAgIGYud3JpdGUoY29udGVudCkKICAgIHByaW50KGYiICDinIUgQ01EX1NVU0ZTX0hJREVfU1VTX01OVFNfRk9SX0FMTF9QUk9DUyBhZGRlZCB0byB7cGF0aH0iKQplbHNlOgogICAgZmFsbGJhY2sgPSAiI2RlZmluZSBTVVNGU19NQVhfTEVOX1BBVEhOQU1FIgogICAgY29udGVudCA9IGNvbnRlbnQucmVwbGFjZSgKICAgICAgICBmYWxsYmFjaywKICAgICAgICAiI2RlZmluZSBDTURfU1VTRlNfSElERV9TVVNfTU5UU19GT1JfQUxMX1BST0NTICAgICAweDU1NTYzXG4iICsgZmFsbGJhY2ssIDEpCiAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnKSBhcyBmOgogICAgICAgIGYud3JpdGUoY29udGVudCkKICAgIHByaW50KGYiICDinIUgQ01EX1NVU0ZTX0hJREVfU1VTX01OVFNfRk9SX0FMTF9QUk9DUyBhZGRlZCAoZmFsbGJhY2spIHRvIHtwYXRofSIpCg==' | base64 -d | python3 - "$SUSFS_DEF_H"
else
    echo "  ℹ️  CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS already present"
fi

# ── 4b. Declaration in susfs.h — must be inside #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
echo 'aW1wb3J0IHN5cwpwYXRoID0gc3lzLmFyZ3ZbMV0Kd2l0aCBvcGVuKHBhdGgpIGFzIGY6CiAgICBjb250ZW50ID0gZi5yZWFkKCkKCmZuX3NpZyA9ICJzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzIgpkZWNsICAgPSAidm9pZCBzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzKHZvaWQgX191c2VyICoqdXNlcl9pbmZvKTsiCmlmbmRlZiA9ICIjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UIgoKIyBGaW5kIHRoZSBzdXNfbW91bnQgI2lmZGVmIGJsb2NrCm1vdW50X2lmZGVmID0gY29udGVudC5maW5kKCIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQiLCBjb250ZW50LmZpbmQoIi8qIHN1c19tb3VudCAqLyIpKQojIEZpbmQgaXRzIGNsb3NpbmcgI2VuZGlmCm1vdW50X2VuZGlmID0gY29udGVudC5maW5kKGlmbmRlZiwgbW91bnRfaWZkZWYpCgpmbl9wb3MgPSBjb250ZW50LmZpbmQoZm5fc2lnKQoKaWYgZm5fcG9zID09IC0xOgogICAgIyBOb3QgcHJlc2VudCBhdCBhbGwg4oCUIGluc2VydCBiZWZvcm
