#!/bin/bash
# =============================================================================
# check_susfs.sh — Validates and repairs SUSFS wiring for kernel 4.19
#
# On 4.19, SUSFS is a single file: fs/susfs.c (NOT a fs/susfs/ subdirectory).
# Makefile entry : obj-$(CONFIG_KSU_SUSFS) += susfs.o
# Kconfig entry  : source "fs/susfs/Kconfig"
#
# Usage: bash check_susfs.sh [kernel_root]
#   kernel_root: path to kernel source root (default: current directory)
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pass()  { echo -e "${GREEN}  [PASS]${NC} $*"; }
fail()  { echo -e "${RED}  [FAIL]${NC} $*"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "${CYAN}  [INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $*"; }
title() { echo -e "\n${CYAN}=== $* ===${NC}"; }
fixed() { echo -e "${YELLOW}  [FIXED]${NC} $*"; }

ERRORS=0

# ── Resolve kernel root ───────────────────────────────────────────────────────
KERNEL_ROOT="${1:-$(pwd)}"
KERNEL_ROOT="$(realpath "$KERNEL_ROOT")"

FS_KCONFIG="$KERNEL_ROOT/fs/Kconfig"
FS_MAKEFILE="$KERNEL_ROOT/fs/Makefile"

# On kernel 4.19, SUSFS is a flat single file in fs/, not a subdirectory
SUSFS_C="$KERNEL_ROOT/fs/susfs.c"
SUSFS_H="$KERNEL_ROOT/include/linux/susfs.h"
SUSFS_DEF_H="$KERNEL_ROOT/include/linux/susfs_def.h"

# What we expect in each file
KCONFIG_ENTRY='source "fs/susfs/Kconfig"'
MAKEFILE_ENTRY='obj-$(CONFIG_KSU_SUSFS) += susfs.o'

# =============================================================================
# Helper: deduplicate a literal string in a file safely (no awk regex)
# Keeps only the FIRST occurrence, removes all subsequent duplicates
# =============================================================================
dedup_entry() {
    local file="$1"
    local entry="$2"
    local count
    count=$(grep -cF "$entry" "$file" 2>/dev/null || true)

    if [ "$count" -le 1 ]; then
        return 0
    fi

    warn "Found $count duplicate entries in $(basename $file) — deduplicating"

    local tmp seen line
    tmp=$(mktemp)
    seen=0
    while IFS= read -r line; do
        if [ "$line" = "$entry" ]; then
            if [ "$seen" -eq 0 ]; then
                printf '%s\n' "$line" >> "$tmp"
                seen=1
            fi
            # silently drop subsequent duplicates
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
    fixed "$(basename $file) now has exactly 1 occurrence of the entry"
}

# =============================================================================
# Helper: add a line to a file if not already present
# Inserts before the LAST occurrence of before_grep_pattern (not every one),
# or appends if the pattern is not found.
# Usage: ensure_entry <file> <literal_entry> [before_grep_pattern]
# =============================================================================
ensure_entry() {
    local file="$1"
    local entry="$2"
    local before="${3:-}"

    if grep -qF "$entry" "$file"; then
        pass "Already present: '$entry'"
        return 0
    fi

    warn "Missing: '$entry' — adding to $(basename $file)"

    if [ -n "$before" ] && grep -q "$before" "$file"; then
        # Find the line number of the LAST match of before_pattern
        local last_line
        last_line=$(grep -n "$before" "$file" | tail -1 | cut -d: -f1)
        # Insert the entry on the line before it using sed
        sed -i "${last_line}i\\
$entry" "$file"
        fixed "Inserted '$entry' before last '$before' (line $last_line) in $(basename $file)"
    else
        printf '\n%s\n' "$entry" >> "$file"
        fixed "Appended '$entry' to $(basename $file)"
    fi
}

# =============================================================================
# 0. Sanity: is this a kernel tree?
# =============================================================================
title "Checking kernel source tree at: $KERNEL_ROOT"

[ -f "$FS_KCONFIG"  ] && pass "fs/Kconfig found"  || { fail "fs/Kconfig not found — is the kernel root correct?"; exit 1; }
[ -f "$FS_MAKEFILE" ] && pass "fs/Makefile found" || { fail "fs/Makefile not found"; exit 1; }

# =============================================================================
# 1. Check the SUSFS patch was actually applied (must come before this script)
# =============================================================================
title "Checking SUSFS patch was applied"

PATCH_OK=true

if [ -f "$SUSFS_C" ]; then
    pass "fs/susfs.c exists"
else
    fail "fs/susfs.c is missing — SUSFS patch has NOT been applied or failed entirely"
    PATCH_OK=false
fi

if [ -f "$SUSFS_H" ]; then
    pass "include/linux/susfs.h exists"
else
    fail "include/linux/susfs.h is missing"
    PATCH_OK=false
fi

if [ -f "$SUSFS_DEF_H" ]; then
    pass "include/linux/susfs_def.h exists"
else
    fail "include/linux/susfs_def.h is missing"
    PATCH_OK=false
fi

if [ "$PATCH_OK" = false ]; then
    echo ""
    echo -e "${RED}SUSFS patch must be applied before running this script. Aborting.${NC}"
    exit 1
fi

# =============================================================================
# 2. Backup originals (skip if backup already exists from a prior run)
# =============================================================================
title "Backing up originals"

for f in "$FS_KCONFIG" "$FS_MAKEFILE"; do
    bak="${f}.susfs_bak"
    if [ ! -f "$bak" ]; then
        cp "$f" "$bak"
        info "Backed up $(basename $f) → $(basename $bak)"
    else
        info "$(basename $bak) already exists — skipping"
    fi
done

# =============================================================================
# 3. Remove any duplicates introduced by patch + prior script runs
# =============================================================================
title "Removing any duplicates"

dedup_entry "$FS_KCONFIG"  "$KCONFIG_ENTRY"
dedup_entry "$FS_MAKEFILE" "$MAKEFILE_ENTRY"

# =============================================================================
# 4. Ensure entries are present (adds only if missing after dedup)
# =============================================================================
title "Checking fs/Kconfig"
ensure_entry "$FS_KCONFIG" "$KCONFIG_ENTRY" "^endmenu"

title "Checking fs/Makefile"
ensure_entry "$FS_MAKEFILE" "$MAKEFILE_ENTRY"

# Second dedup pass — catches any duplicates introduced by the insert above
# (e.g. if the patch had already partially added the entry before this script ran)
title "Second dedup pass (post-insert safety check)"
dedup_entry "$FS_KCONFIG"  "$KCONFIG_ENTRY"
dedup_entry "$FS_MAKEFILE" "$MAKEFILE_ENTRY"

# =============================================================================
# 5. Final validation — confirm exactly 1 of each entry, correct content
# =============================================================================
title "Final validation"

validate_entry() {
    local file="$1"
    local entry="$2"
    local label="$3"
    local count lineno
    count=$(grep -cF "$entry" "$file" 2>/dev/null || true)

    if [ "$count" -eq 1 ]; then
        lineno=$(grep -nF "$entry" "$file" | head -1 | cut -d: -f1)
        pass "$label — found exactly once (line $lineno)"
    elif [ "$count" -eq 0 ]; then
        fail "$label — STILL MISSING after fix attempt"
    else
        fail "$label — $count duplicates remain, manual fix needed"
    fi
}

validate_entry "$FS_KCONFIG"  "$KCONFIG_ENTRY"  "fs/Kconfig  → Kconfig source line"
validate_entry "$FS_MAKEFILE" "$MAKEFILE_ENTRY" "fs/Makefile → susfs.o obj entry"

# Spot-check susfs.c for a key symbol to confirm it's a valid SUSFS file
if grep -q "susfs_init" "$SUSFS_C" 2>/dev/null; then
    pass "fs/susfs.c content looks valid (susfs_init found)"
else
    warn "fs/susfs.c may be incomplete — susfs_init symbol not found"
fi

# =============================================================================
# 6. Summary
# =============================================================================
title "Summary"
echo ""
printf "  Kernel root : %s\n" "$KERNEL_ROOT"
printf "  fs/Kconfig  : %s\n" "$(grep -nF "$KCONFIG_ENTRY"  "$FS_KCONFIG"  | head -1 | sed 's/^/line /')"
printf "  fs/Makefile : %s\n" "$(grep -nF "$MAKEFILE_ENTRY" "$FS_MAKEFILE" | head -1 | sed 's/^/line /')"
echo ""

if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}All checks passed. SUSFS is correctly wired into the fs/ build system.${NC}"
    exit 0
else
    echo -e "${RED}$ERRORS error(s) remain. See output above.${NC}"
    exit 1
fi
