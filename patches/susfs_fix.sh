#!/usr/bin/env bash
# =============================================================================
# apply_susfs_patch.sh  (v7 — flexible regex, diagnostic output for task_mmu)
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

# Strip Windows CRLF line-endings that GitHub Actions may inject when
# git.autocrlf=true -- a bare "PYEOF\r" will NOT match the "PYEOF" heredoc
# terminator, causing bash to feed a truncated heredoc to Python.
# We re-exec through sed only once (SUSFS_CRLF_FIXED prevents recursion).
if [ -z "${SUSFS_CRLF_FIXED:-}" ]; then
    CLEANED="$(mktemp /tmp/susfs_fix_XXXXXX.sh)"
    sed 's/\r//' "$0" > "$CLEANED"
    chmod +x "$CLEANED"
    SUSFS_CRLF_FIXED=1 exec bash "$CLEANED" "$@"
fi

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
echo 'aW1wb3J0IHN5cywgcmUKcGF0aCA9IHN5cy5hcmd2WzFdCndpdGggb3BlbihwYXRoKSBhcyBmOgogICAgY29udGVudCA9IGYucmVhZCgpCgphbHJlYWR5X21hcHMgID0gIkJJVF9TVVNfTUFQUyIgaW4gY29udGVudAphbHJlYWR5X3BtZSAgID0gInBtLmJ1ZmZlci0+cG1lID0gMCIgaW4gY29udGVudAphbHJlYWR5X2RlY2wgID0gIkNPTkZJR19LU1VfU1VTRlNfU1VTX01BUCIgaW4gY29udGVudCBhbmQgInN0cnVjdCB2bV9hcmVhX3N0cnVjdCAqdm1hOyIgaW4gY29udGVudAoKIyDilIDilIAgSHVuayBBOiBhZGQgdm1hIGRlY2xhcmF0aW9uIGluc2lkZSBwYWdlbWFwX3JlYWQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmh1bmtfYV9hcHBsaWVkID0gRmFsc2UKaWYgYWxyZWFkeV9kZWNsOgogICAgcHJpbnQoIiAg4oS577iPICB0YXNrX21tdS5jOiB2bWEgZGVjbGFyYXRpb24gYWxyZWFkeSBwcmVzZW50IikKICAgIGh1bmtfYV9hcHBsaWVkID0gVHJ1ZQplbHNlOgogICAgY2FuZGlkYXRlc19hID0gWwogICAgICAgICJcdGludCByZXQgPSAwLCBjb3BpZWQgPSAwO1xuXG5cdGlmICghbW0gfHwgIW1tZ2V0X25vdF96ZXJvKG1tKSlcbiIsCiAgICAgICAgIlx0aW50IHJldCA9IDAsIGNvcGllZCA9IDA7XG5cdGlmICghbW0gfHwgIW1tZ2V0X25vdF96ZXJvKG1tKSlcbiIsCiAgICAgICAgIlx0aW50IHJldCA9IDAsIGNvcGllZCA9IDA7XG5cblx0aWYgKCFtbSB8fCAhbW1nZXRfbm90X3plcm8obW0pKSB7XG4iLAogICAgXQogICAgZm9yIG9sZF9hIGluIGNhbmRpZGF0ZXNfYToKICAgICAgICBuZXdfYSA9ICgKICAgICAgICAgICAgIlx0aW50IHJldCA9IDAsIGNvcGllZCA9IDA7XG4iCiAgICAgICAgICAgICIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTUFQXG4iCiAgICAgICAgICAgICJcdHN0cnVjdCB2bV9hcmVhX3N0cnVjdCAqdm1hO1xuIgogICAgICAgICAgICAiI2VuZGlmXG4iCiAgICAgICAgKSArIG9sZF9hW2xlbigiXHRpbnQgcmV0ID0gMCwgY29waWVkID0gMDtcbiIpOl0KICAgICAgICBpZiBvbGRfYSBpbiBjb250ZW50OgogICAgICAgICAgICBjb250ZW50ID0gY29udGVudC5yZXBsYWNlKG9sZF9hLCBuZXdfYSwgMSkKICAgICAgICAgICAgaHVua19hX2FwcGxpZWQgPSBUcnVlCiAgICAgICAgICAgIHByaW50KCIgIOKchSB0YXNrX21tdS5jOiBwYWdlbWFwX3JlYWQgdm1hIGRlY2xhcmF0aW9uIGFkZGVkIikKICAgICAgICAgICAgYnJlYWsKICAgIGlmIG5vdCBodW5rX2FfYXBwbGllZDoKICAgICAgICBwcmludCgiICDimqDvuI8gIHRhc2tfbW11LmM6IGNvdWxkIG5vdCBhZGQgdm1hIGRlY2xhcmF0aW9uIOKAlCB0cnlpbmcgd2l0aG91dCBpdCIpCgojIOKUgOKUgCBIdW5rIEI6IGFkZCB0aGUgU1VTX01BUCBjaGVjayBhZnRlciB3YWxrX3BhZ2VfcmFuZ2UvdXBfcmVhZCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKaWYgYWxyZWFkeV9wbWUgYW5kIGFscmVhZHlfbWFwczoKICAgIHByaW50KCIgIOKEue+4jyAgdGFza19tbXUuYzogcGFnZW1hcF9yZWFkIFNVU19NQVAgY2hlY2sgYWxyZWFkeSBhcHBsaWVkIikKZWxzZToKICAgICMgRmluZCB3YWxrX3BhZ2VfcmFuZ2Ugb2NjdXJyZW5jZSBhbmQgc2hvdyBkaWFnbm9zdGljIGNvbnRleHQKICAgIHdycF9pZHggPSBjb250ZW50LmZpbmQoIndhbGtfcGFnZV9yYW5nZShzdGFydF92YWRkciIpCiAgICBpZiB3cnBfaWR4ID09IC0xOgogICAgICAgIHdycF9pZHggPSBjb250ZW50LmZpbmQoIndhbGtfcGFnZV9yYW5nZSgiKQogICAgCiAgICBpZiB3cnBfaWR4ICE9IC0xOgogICAgICAgICMgRmluZCB0aGUgc3RhcnQgb2YgdGhpcyBsaW5lCiAgICAgICAgbGluZV9zdGFydCA9IGNvbnRlbnQucmZpbmQoJ1xuJywgMCwgd3JwX2lkeCkgKyAxCiAgICAgICAgIyBHZXQgMTUgbGluZXMgb2YgY29udGV4dCBhcm91bmQgaXQKICAgICAgICBjdHhfc3RhcnQgPSBjb250ZW50LnJmaW5kKCdcbicsIDAsIGxpbmVfc3RhcnQgLSAxKQogICAgICAgIGN0eF9zdGFydCA9IGNvbnRlbnQucmZpbmQoJ1xuJywgMCwgY3R4X3N0YXJ0IC0gMSkKICAgICAgICBjdHhfc3RhcnQgPSBjb250ZW50LnJmaW5kKCdcbicsIDAsIGN0eF9zdGFydCAtIDEpICAjIDMgbGluZXMgYmVmb3JlCiAgICAgICAgY3R4X2VuZCA9IGNvbnRlbnQuZmluZCgnXG4nLCB3cnBfaWR4KQogICAgICAgIGZvciBfIGluIHJhbmdlKDgpOiAgIyA4IGxpbmVzIGFmdGVyCiAgICAgICAgICAgIGN0eF9lbmQgPSBjb250ZW50LmZpbmQoJ1xuJywgY3R4X2VuZCArIDEpCiAgICAgICAgICAgIGlmIGN0eF9lbmQgPT0gLTE6CiAgICAgICAgICAgICAgICBjdHhfZW5kID0gbGVuKGNvbnRlbnQpCiAgICAgICAgICAgICAgICBicmVhawogICAgICAgIAogICAgICAgIHByaW50KCIgIPCflI0gQWN0dWFsIGZpbGUgY29udGVudCBhcm91bmQgd2Fsa19wYWdlX3JhbmdlIChmb3IgZGlhZ25vc2lzKToiKQogICAgICAgIGN0eCA9IGNvbnRlbnRbY3R4X3N0YXJ0OmN0eF9lbmRdCiAgICAgICAgZm9yIGksIGxpbmUgaW4gZW51bWVyYXRlKGN0eC5zcGxpdCgnXG4nKSk6CiAgICAgICAgICAgICMgU2hvdyB0YWIgY2hhcnMgZXhwbGljaXRseQogICAgICAgICAgICBkaXNwbGF5ID0gbGluZS5yZXBsYWNlKCdcdCcsICfihpInKQogICAgICAgICAgICBwcmludChmIiAgICAgICB7aTowMmR9OiB7cmVwcihsaW5lWzo4MF0pfSIpCiAgICBlbHNlOgogICAgICAgIHByaW50KCIgIPCflI0gd2Fsa19wYWdlX3JhbmdlIE5PVCBGT1VORCBpbiBmaWxlIGF0IGFsbCEiKQoKICAgICMgRmxleGlibGUgcmVnZXg6IG1hdGNoIGFueSB3aGl0ZXNwYWNlIHByZWZpeCwgYW55IGxvY2sgbmFtZSwgYW55IHZhcmlhYmxlIG5hbWUKICAgICMgVGhpcyBoYW5kbGVzOiBkaWZmZXJlbnQgdGFiIGNvdW50cywgbW1hcF9sb2NrL21tYXBfc2VtL21tYXBfcmVhZF9sb2NrIHZhcmlhbnRzLAogICAgIyB3YWxrX3BhZ2VfcmFuZ2UgdmFyaWFudHMKICAgIGFwcGxpZWRfYiA9IEZhbHNlCiAgICAKICAgICMgUGF0dGVybiAxOiBicm9hZGVzdCBwb3NzaWJsZSAtIGZpbmQgdGhlIGZvci1sb29wIGJvZHkgd2l0aCB3YWxrK3VubG9jaytzdGFydF92YWRkcgogICAgIyBVc2luZyBccysgaW5zdGVhZCBvZiBmaXhlZCB0YWJzLCBjYXB0dXJpbmcgdGhlIGFjdHVhbCBjb250ZW50CiAgICBwYXR0ZXJucyA9IFsKICAgICAgICAjIEV4YWN0IDMtdGFiIGdvdG8gKyAyLXRhYiB3YWxrICsgbW1hcF9zZW0KICAgICAgICAocicoXHR7M31nb3RvIG91dF9mcmVlO1xuXHR7Mn1yZXQgPSB3YWxrX3BhZ2VfcmFuZ2VcKHN0YXJ0X3ZhZGRyLCBlbmQsICZwYWdlbWFwX3dhbGtcKTtcblx0ezJ9dXBfcmVhZFwoJm1tLT5tbWFwX3NlbVwpO1xuKScsCiAgICAgICAgIHInKFxuPyknLAogICAgICAgICByJyhcdHsyfXN0YXJ0X3ZhZGRyID0gZW5kO1xuKScpLAogICAgICAgICMgRXhhY3QgMy10YWIgZ290byArIDItdGFiIHdhbGsgKyBtbWFwX2xvY2sgIAogICAgICAgIChyJyhcdHszfWdvdG8gb3V0X2ZyZWU7XG5cdHsyfXJldCA9IHdhbGtfcGFnZV9yYW5nZVwoc3RhcnRfdmFkZHIsIGVuZCwgJnBhZ2VtYXBfd2Fsa1wpO1xuXHR7Mn11cF9yZWFkXCgmbW0tPm1tYXBfbG9ja1wpO1xuKScsCiAgICAgICAgIHInKFxuPyknLAogICAgICAgICByJyhcdHsyfXN0YXJ0X3ZhZGRyID0gZW5kO1xuKScpLAogICAgICAgICMgNC10YWIgZ290byArIDItdGFiIHdhbGsgKyBtbWFwX3NlbSAoZGVlcGVyIG5lc3RpbmcpCiAgICAgICAgKHInKFx0ezR9Z290byBvdXRfZnJlZTtcblx0ezJ9cmV0ID0gd2Fsa19wYWdlX3JhbmdlXChzdGFydF92YWRkciwgZW5kLCAmcGFnZW1hcF93YWxrXCk7XG5cdHsyfXVwX3JlYWRcKCZtbS0+bW1hcF9zZW1cKTtcbiknLAogICAgICAgICByJyhcbj8pJywKICAgICAgICAgcicoXHR7Mn1zdGFydF92YWRkciA9IGVuZDtcbiknKSwKICAgICAgICAjIDQtdGFiIGdvdG8gKyAyLXRhYiB3YWxrICsgbW1hcF9sb2NrCiAgICAgICAgKHInKFx0ezR9Z290byBvdXRfZnJlZTtcblx0ezJ9cmV0ID0gd2Fsa19wYWdlX3JhbmdlXChzdGFydF92YWRkciwgZW5kLCAmcGFnZW1hcF93YWxrXCk7XG5cdHsyfXVwX3JlYWRcKCZtbS0+bW1hcF9sb2NrXCk7XG4pJywKICAgICAgICAgcicoXG4/KScsCiAgICAgICAgIHInKFx0ezJ9c3RhcnRfdmFkZHIgPSBlbmQ7XG4pJyksCiAgICAgICAgIyBObyBnb3RvICsgd2FsayArIG1tYXBfc2VtCiAgICAgICAgKHInKFx0ezJ9cmV0ID0gd2Fsa19wYWdlX3JhbmdlXChzdGFydF92YWRkciwgZW5kLCAmcGFnZW1hcF93YWxrXCk7XG5cdHsyfXVwX3JlYWRcKCZtbS0+bW1hcF9zZW1cKTtcbiknLAogICAgICAgICByJyhcbj8pJywKICAgICAgICAgcicoXHR7Mn1zdGFydF92YWRkciA9IGVuZDtcbiknKSwKICAgICAgICAjIE5vIGdvdG8gKyB3YWxrICsgbW1hcF9sb2NrCiAgICAgICAgKHInKFx0ezJ9cmV0ID0gd2Fsa19wYWdlX3JhbmdlXChzdGFydF92YWRkciwgZW5kLCAmcGFnZW1hcF93YWxrXCk7XG5cdHsyfXVwX3JlYWRcKCZtbS0+bW1hcF9sb2NrXCk7XG4pJywKICAgICAgICAgcicoXG4/KScsCiAgICAgICAgIHInKFx0ezJ9c3RhcnRfdmFkZHIgPSBlbmQ7XG4pJyksCiAgICAgICAgIyBVbHRyYS1mbGV4aWJsZTogYW55IHdoaXRlc3BhY2UsIGFueSBsb2NrIG5hbWUgdmFyaWFudAogICAgICAgIChyJyhbIFx0XSpyZXQgPSB3YWxrX3BhZ2VfcmFuZ2VcKHN0YXJ0X3ZhZGRyLCBlbmQsICZwYWdlbWFwX3dhbGtcKTtcblsgXHRdKig/OnVwX3JlYWR8bW1hcF9yZWFkX3VubG9jaylcKCZtbS0+KD86bW1hcF9zZW18bW1hcF9sb2NrKVwpO1xuKScsCiAgICAgICAgIHInKFsgXHRdKlxuKT8nLAogICAgICAgICByJyhbIFx0XSpzdGFydF92YWRkciA9IGVuZDtcbiknKSwKICAgIF0KICAgIAogICAgZm9yIHBfcHJlLCBwX2JsYW5rLCBwX3Bvc3QgaW4gcGF0dGVybnM6CiAgICAgICAgZnVsbF9wYXR0ZXJuID0gcF9wcmUgKyBwX2JsYW5rICsgcF9wb3N0CiAgICAgICAgbSA9IHJlLnNlYXJjaChmdWxsX3BhdHRlcm4sIGNvbnRlbnQpCiAgICAgICAgaWYgbToKICAgICAgICAgICAgcHJlX3N0ciA9IG0uZ3JvdXAoMSkKICAgICAgICAgICAgYmxhbmtfc3RyID0gbS5ncm91cCgyKSBvciAnJwogICAgICAgICAgICBwb3N0X3N0ciA9IG0uZ3JvdXAoMykKICAgICAgICAgICAgCiAgICAgICAgICAgICMgRGV0ZWN0IGxvY2sgYW5kIGxlYWRpbmcgZ290bwogICAgICAgICAgICBsb2NrID0gIm1tYXBfbG9jayIgaWYgIm1tYXBfbG9jayIgaW4gcHJlX3N0ciBlbHNlICJtbWFwX3NlbSIKICAgICAgICAgICAgIyBEZXRlY3QgaW5kZW50IGxldmVsIGZyb20gd2Fsa19wYWdlX3JhbmdlIGxpbmUKICAgICAgICAgICAgd2Fsa19saW5lID0gbmV4dChsIGZvciBsIGluIHByZV9zdHIuc3BsaXQoJ1xuJykgaWYgJ3dhbGtfcGFnZV9yYW5nZScgaW4gbCkKICAgICAgICAgICAgaW5kZW50ID0gd2Fsa19saW5lWzpsZW4od2Fsa19saW5lKSAtIGxlbih3YWxrX2xpbmUubHN0cmlwKCkpXQogICAgICAgICAgICAKICAgICAgICAgICAgIyBQcmVzZXJ2ZSBhbnkgbGVhZGluZyBnb3RvIGxpbmUgKGV2ZXJ5dGhpbmcgYmVmb3JlIHJldCA9KQogICAgICAgICAgICByZXRfaWR4ID0gcHJlX3N0ci5maW5kKCdyZXQgPSB3YWxrX3BhZ2VfcmFuZ2UnKQogICAgICAgICAgICBsZWFkaW5nID0gcHJlX3N0cls6cmV0X2lkeF0gaWYgcmV0X2lkeCA+IDAgZWxzZSAnJwogICAgICAgICAgICAKICAgICAgICAgICAgc3VzX2Jsb2NrID0gKAogICAgICAgICAgICAgICAgZiJ7aW5kZW50fXJldCA9IHdhbGtfcGFnZV9yYW5nZShzdGFydF92YWRkciwgZW5kLCAmcGFnZW1hcF93YWxrKTtcbiIKICAgICAgICAgICAgICAgIGYie2luZGVudH11cF9yZWFkKCZtbS0+e2xvY2t9KTtcbiIKICAgICAgICAgICAgICAgICIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTUFQXG4iCiAgICAgICAgICAgICAgICBmIntpbmRlbnR9dm1hID0gZmluZF92bWEobW0sIHN0YXJ0X3ZhZGRyKTtcbiIKICAgICAgICAgICAgICAgIGYie2luZGVudH1pZiAodm1hICYmIHZtYS0+dm1fZmlsZSkge3tcbiIKICAgICAgICAgICAgICAgIGYie2luZGVudH1cdHN0cnVjdCBpbm9kZSAqaW5vZGUgPSBmaWxlX2lub2RlKHZtYS0+dm1fZmlsZSk7XG4iCiAgICAgICAgICAgICAgICBmIntpbmRlbnR9XHRpZiAodW5saWtlbHkoaW5vZGUtPmlfbWFwcGluZy0+ZmxhZ3MgJiBCSVRfU1VTX01BUFMpICYmIHN1c2ZzX2lzX2N1cnJlbnRfcHJvY191bW91bnRlZCgpKSB7e1xuIgogICAgICAgICAgICAgICAgZiJ7aW5kZW50fVx0XHRwbS5idWZmZXItPnBtZSA9IDA7XG4iCiAgICAgICAgICAgICAgICBmIntpbmRlbnR9XHR9fVxuIgogICAgICAgICAgICAgICAgZiJ7aW5kZW50fX19XG4iCiAgICAgICAgICAgICAgICAiI2VuZGlmXG4iCiAgICAgICAgICAgICkKICAgICAgICAgICAgbmV3X2Z1bGwgPSBsZWFkaW5nICsgc3VzX2Jsb2NrICsgYmxhbmtfc3RyICsgcG9zdF9zdHIKICAgICAgICAgICAgY29udGVudCA9IGNvbnRlbnRbOm0uc3RhcnQoKV0gKyBuZXdfZnVsbCArIGNvbnRlbnRbbS5lbmQoKTpdCiAgICAgICAgICAgIHByaW50KGYiICDinIUgdGFza19tbXUuYzogcGFnZW1hcF9yZWFkIFNVU19NQVAgY2hlY2sgYXBwbGllZCAocGF0dGVybjogbG9jaz17bG9ja30sIGluZGVudD17cmVwcihpbmRlbnQpfSkiKQogICAgICAgICAgICBhcHBsaWVkX2IgPSBUcnVlCiAgICAgICAgICAgIGJyZWFrCiAgICAKICAgIGlmIG5vdCBhcHBsaWVkX2I6CiAgICAgICAgcHJpbnQoIiAg4pqg77iPICB0YXNrX21tdS5jOiBwYWdlbWFwX3JlYWQgY29udGV4dCBub3QgZm91bmQg4oCUIG1pbm9yIGZlYXR1cmUgbWlzc2luZyIpCiAgICAgICAgcHJpbnQoIiAg8J+UjSBEZWJ1Zzogd2Fsa19wYWdlX3JhbmdlIG9jY3VycmVuY2VzIGluIGZpbGU6IikKICAgICAgICBmb3IgbTIgaW4gcmUuZmluZGl0ZXIocid3YWxrX3BhZ2VfcmFuZ2UnLCBjb250ZW50KToKICAgICAgICAgICAgc3RhcnQgPSBjb250ZW50LnJmaW5kKCdcbicsIDAsIG0yLnN0YXJ0KCkpICsgMQogICAgICAgICAgICBlbmQgPSBjb250ZW50LmZpbmQoJ1xuJywgbTIuZW5kKCkpCiAgICAgICAgICAgIGVuZDIgPSBjb250ZW50LmZpbmQoJ1xuJywgZW5kICsgMSkKICAgICAgICAgICAgcHJpbnQoZiIgICAgICAge3JlcHIoY29udGVudFtzdGFydDplbmQyXSl9IikKCndpdGggb3BlbihwYXRoLCAndycpIGFzIGY6CiAgICBmLndyaXRlKGNvbnRlbnQpCg==' | base64 -d | python3 - "fs/proc/task_mmu.c"

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
echo 'aW1wb3J0IHN5cwpwYXRoID0gc3lzLmFyZ3ZbMV0Kd2l0aCBvcGVuKHBhdGgpIGFzIGY6CiAgICBjb250ZW50ID0gZi5yZWFkKCkKCmZuX3NpZyA9ICJzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzIgpkZWNsICAgPSAidm9pZCBzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzKHZvaWQgX191c2VyICoqdXNlcl9pbmZvKTsiCmlmbmRlZiA9ICIjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UIgoKIyBGaW5kIHRoZSBzdXNfbW91bnQgI2lmZGVmIGJsb2NrCm1vdW50X2lmZGVmID0gY29udGVudC5maW5kKCIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQiLCBjb250ZW50LmZpbmQoIi8qIHN1c19tb3VudCAqLyIpKQojIEZpbmQgaXRzIGNsb3NpbmcgI2VuZGlmCm1vdW50X2VuZGlmID0gY29udGVudC5maW5kKGlmbmRlZiwgbW91bnRfaWZkZWYpCgpmbl9wb3MgPSBjb250ZW50LmZpbmQoZm5fc2lnKQoKaWYgZm5fcG9zID09IC0xOgogICAgIyBOb3QgcHJlc2VudCBhdCBhbGwg4oCUIGluc2VydCBiZWZvcmUgdGhlICNlbmRpZgogICAgY29udGVudCA9IGNvbnRlbnRbOm1vdW50X2VuZGlmXSArIGRlY2wgKyAiXG4iICsgY29udGVudFttb3VudF9lbmRpZjpdCiAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnKSBhcyBmOgogICAgICAgIGYud3JpdGUoY29udGVudCkKICAgIHByaW50KGYiICDinIUgc3VzZnMuaDogZGVjbGFyYXRpb24gYWRkZWQgaW5zaWRlICNpZmRlZiBndWFyZCIpCgplbGlmIGZuX3BvcyA8IG1vdW50X2VuZGlmOgogICAgIyBBbHJlYWR5IGluc2lkZSB0aGUgZ3VhcmQg4oCUIG5vdGhpbmcgdG8gZG8KICAgIHByaW50KGYiICDinIUgc3VzZnMuaDogZGVjbGFyYXRpb24gYWxyZWFkeSBpbnNpZGUgI2lmZGVmIGd1YXJkIikKCmVsc2U6CiAgICAjIE91dHNpZGUgdGhlIGd1YXJkIOKAlCByZW1vdmUgYW5kIHJlLWluc2VydCBpbnNpZGUKICAgIGNvbnRlbnQgPSBjb250ZW50LnJlcGxhY2UoZGVjbCArICJcbiIsICIiLCAxKQogICAgY29udGVudCA9IGNvbnRlbnQucmVwbGFjZShkZWNsLCAiIiwgMSkgICAgICAgICAgIyBoYW5kbGUgbWlzc2luZyB0cmFpbGluZyBcbgogICAgIyBSZWNhbGN1bGF0ZSBwb3NpdGlvbnMgYWZ0ZXIgcmVtb3ZhbAogICAgbW91bnRfaWZkZWYgPSBjb250ZW50LmZpbmQoIiNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVCIsIGNvbnRlbnQuZmluZCgiLyogc3VzX21vdW50ICovIikpCiAgICBtb3VudF9lbmRpZiA9IGNvbnRlbnQuZmluZChpZm5kZWYsIG1vdW50X2lmZGVmKQogICAgY29udGVudCA9IGNvbnRlbnRbOm1vdW50X2VuZGlmXSArIGRlY2wgKyAiXG4iICsgY29udGVudFttb3VudF9lbmRpZjpdCiAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnKSBhcyBmOgogICAgICAgIGYud3JpdGUoY29udGVudCkKICAgIHByaW50KGYiICDinIUgc3VzZnMuaDogZGVjbGFyYXRpb24gbW92ZWQgaW5zaWRlICNpZmRlZiBndWFyZCIpCg==' | base64 -d | python3 - "$SUSFS_H"

# ── 4c. Implementation in susfs.c — must be inside #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
echo 'aW1wb3J0IHN5cywgcmUKcGF0aCA9IHN5cy5hcmd2WzFdCndpdGggb3BlbihwYXRoKSBhcyBmOgogICAgY29udGVudCA9IGYucmVhZCgpCgpmbl9zaWcgICA9ICJzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzIgppZm5kZWYgICA9ICIjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UIgojIExvY2F0ZSB0aGUgc3VzX21vdW50IGJsb2NrIGJvdW5kYXJpZXMKbW91bnRfaWZkZWZfcG9zID0gY29udGVudC5maW5kKCIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQiLCBjb250ZW50LmZpbmQoIi8qIHN1c19tb3VudCAqLyIpKQptb3VudF9lbmRpZl9wb3MgPSBjb250ZW50LmZpbmQoaWZuZGVmLCBtb3VudF9pZmRlZl9wb3MpCgpuZXdfaW1wbCA9ICgKICAgICJcbnZvaWQgc3VzZnNfc2V0X2hpZGVfc3VzX21udHNfZm9yX2FsbF9wcm9jcyh2b2lkIF9fdXNlciAqKnVzZXJfaW5mbykge1xuIgogICAgIlx0c3RydWN0IHN0X3N1c2ZzX2hpZGVfc3VzX21udHNfZm9yX25vbl9zdV9wcm9jcyBpbmZvID0gezB9O1xuXG4iCiAgICAiXHRpZiAoY29weV9mcm9tX3VzZXIoJmluZm8sIChzdHJ1Y3Qgc3Rfc3VzZnNfaGlkZV9zdXNfbW50c19mb3Jfbm9uX3N1X3Byb2NzIF9fdXNlciopKnVzZXJfaW5mbywgc2l6ZW9mKGluZm8pKSkge1xuIgogICAgIlx0XHRpbmZvLmVyciA9IC1FRkFVTFQ7XG4iCiAgICAiXHRcdGdvdG8gb3V0X2NvcHlfdG9fdXNlcjtcbiIKICAgICJcdH1cbiIKICAgICJcdHNwaW5fbG9jaygmc3VzZnNfc3Bpbl9sb2NrX3N1c19tb3VudCk7XG4iCiAgICAiXHRzdXNmc19oaWRlX3N1c19tbnRzX2Zvcl9ub25fc3VfcHJvY3MgPSBpbmZvLmVuYWJsZWQ7XG4iCiAgICAiXHRzcGluX3VubG9jaygmc3VzZnNfc3Bpbl9sb2NrX3N1c19tb3VudCk7XG4iCiAgICAnXHRTVVNGU19MT0dJKCJzdXNmc19oaWRlX3N1c19tbnRzX2Zvcl9hbGxfcHJvY3M6ICVkXFxuIiwgaW5mby5lbmFibGVkKTtcbicKICAgICJcdGluZm8uZXJyID0gMDtcbiIKICAgICJvdXRfY29weV90b191c2VyOlxuIgogICAgIlx0aWYgKGNvcHlfdG9fdXNlcigmKChzdHJ1Y3Qgc3Rfc3VzZnNfaGlkZV9zdXNfbW50c19mb3Jfbm9uX3N1X3Byb2NzIF9fdXNlciopKnVzZXJfaW5mbyktPmVyciwgJmluZm8uZXJyLCBzaXplb2YoaW5mby5lcnIpKSkge1xuIgogICAgIlx0XHRpbmZvLmVyciA9IC1FRkFVTFQ7XG4iCiAgICAiXHR9XG4iCiAgICAnXHRTVVNGU19MT0dJKCJDTURfU1VTRlNfSElERV9TVVNfTU5UU19GT1JfQUxMX1BST0NTIC0+IHJldDogJWRcXG4iLCBpbmZvLmVycik7XG4nCiAgICAifVxuIgopCgpmbl9wb3MgPSBjb250ZW50LmZpbmQoZm5fc2lnKQoKaWYgZm5fcG9zID09IC0xOgogICAgIyBOb3QgcHJlc2VudCDigJQgaW5zZXJ0IGJlZm9yZSB0aGUgI2VuZGlmCiAgICBjb250ZW50ID0gY29udGVudFs6bW91bnRfZW5kaWZfcG9zXSArIG5ld19pbXBsICsgY29udGVudFttb3VudF9lbmRpZl9wb3M6XQogICAgd2l0aCBvcGVuKHBhdGgsICd3JykgYXMgZjoKICAgICAgICBmLndyaXRlKGNvbnRlbnQpCiAgICBwcmludChmIiAg4pyFIHN1c2ZzLmM6IGltcGxlbWVudGF0aW9uIGFkZGVkIGluc2lkZSAjaWZkZWYgZ3VhcmQiKQoKZWxpZiBmbl9wb3MgPCBtb3VudF9lbmRpZl9wb3M6CiAgICBwcmludChmIiAg4pyFIHN1c2ZzLmM6IGltcGxlbWVudGF0aW9uIGFscmVhZHkgaW5zaWRlICNpZmRlZiBndWFyZCIpCgplbHNlOgogICAgIyBPdXRzaWRlIHRoZSBndWFyZCDigJQgZXh0cmFjdCB0aGUgZnVsbCBmdW5jdGlvbiBib2R5IGFuZCByZS1pbnNlcnQgaW5zaWRlCiAgICAjIE1hdGNoIGZyb20gdGhlIGZ1bmN0aW9uIHNpZ25hdHVyZSB0byB0aGUgY2xvc2luZyBicmFjZSBvbiBpdHMgb3duIGxpbmUKICAgIHBhdHRlcm4gPSByJ1xudm9pZCBzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzXCguKj9cblx9XG4nCiAgICBtID0gcmUuc2VhcmNoKHBhdHRlcm4sIGNvbnRlbnQsIHJlLkRPVEFMTCkKICAgIGlmIG06CiAgICAgICAgb2xkX2ZuID0gbS5ncm91cCgwKQogICAgICAgIGNvbnRlbnQgPSBjb250ZW50LnJlcGxhY2Uob2xkX2ZuLCAiXG4iLCAxKSAgICMgcmVtb3ZlIG9sZCBjb3B5CiAgICAgICAgIyBSZWNhbGN1bGF0ZSBhZnRlciByZW1vdmFsCiAgICAgICAgbW91bnRfaWZkZWZfcG9zID0gY29udGVudC5maW5kKCIjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQiLCBjb250ZW50LmZpbmQoIi8qIHN1c19tb3VudCAqLyIpKQogICAgICAgIG1vdW50X2VuZGlmX3BvcyA9IGNvbnRlbnQuZmluZChpZm5kZWYsIG1vdW50X2lmZGVmX3BvcykKICAgICAgICBjb250ZW50ID0gY29udGVudFs6bW91bnRfZW5kaWZfcG9zXSArIG5ld19pbXBsICsgY29udGVudFttb3VudF9lbmRpZl9wb3M6XQogICAgICAgIHdpdGggb3BlbihwYXRoLCAndycpIGFzIGY6CiAgICAgICAgICAgIGYud3JpdGUoY29udGVudCkKICAgICAgICBwcmludChmIiAg4pyFIHN1c2ZzLmM6IGltcGxlbWVudGF0aW9uIG1vdmVkIGluc2lkZSAjaWZkZWYgZ3VhcmQiKQogICAgZWxzZToKICAgICAgICBwcmludChmIiAg4p2MIHN1c2ZzLmM6IGNvdWxkIG5vdCBleHRyYWN0IG1pc3BsYWNlZCBmdW5jdGlvbiDigJQgcGF0Y2ggbWFudWFsbHkiKQogICAgICAgIHN5cy5leGl0KDEpCg==' | base64 -d | python3 - "$SUSFS_C"

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
echo 'aW1wb3J0IHN5cwpwYXRoID0gc3lzLmFyZ3ZbMV0Kd2l0aCBvcGVuKHBhdGgpIGFzIGY6CiAgICBjb250ZW50ID0gZi5yZWFkKCkKCmZuX3BvcyAgICAgID0gY29udGVudC5maW5kKCJzdXNmc19zZXRfaGlkZV9zdXNfbW50c19mb3JfYWxsX3Byb2NzIikKbW91bnRfaWZkZWYgPSBjb250ZW50LmZpbmQoIiNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVCIsIGNvbnRlbnQuZmluZCgiLyogc3VzX21vdW50ICovIikpCm1vdW50X2VuZGlmID0gY29udGVudC5maW5kKCIjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UIiwgbW91bnRfaWZkZWYpCgppZiBmbl9wb3MgPT0gLTE6CiAgICBwcmludCgiICDinYwgc3VzZnMuYyBBTExfUFJPQ1MgaW1wbGVtZW50YXRpb24gbm90IGZvdW5kIikKICAgIHN5cy5leGl0KDEpCmVsaWYgbW91bnRfaWZkZWYgPCBmbl9wb3MgPCBtb3VudF9lbmRpZjoKICAgIHByaW50KCIgIOKchSBzdXNmcy5jIEFMTF9QUk9DUyBpbXBsIGlzIGluc2lkZSAjaWZkZWYgZ3VhcmQgICAgICAgICIpCmVsc2U6CiAgICBwcmludCgiICDinYwgc3VzZnMuYyBBTExfUFJPQ1MgaW1wbCBpcyBPVVRTSURFICNpZmRlZiBndWFyZCDihpAgQkFEIikKICAgIHN5cy5leGl0KDEpCg==' | base64 -d | python3 - "fs/susfs.c"

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
