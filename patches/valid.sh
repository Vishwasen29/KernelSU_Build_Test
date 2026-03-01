#!/bin/bash
# =============================================================================
# check_susfs.sh
# Checks if SUSFS entries are present in fs/Kconfig and fs/Makefile.
# If missing, adds them. Then validates everything is correct.
# Usage: bash check_susfs.sh [kernel_root]
#   kernel_root: path to the kernel source root (default: current directory)
# =============================================================================

set -e

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

pass()  { echo -e "${GREEN}  [PASS]${NC} $*"; }
fail()  { echo -e "${RED}  [FAIL]${NC} $*"; }
info()  { echo -e "${CYAN}  [INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $*"; }
title() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── Resolve kernel root ───────────────────────────────────────────────────────
KERNEL_ROOT="${1:-$(pwd)}"
KERNEL_ROOT="$(realpath "$KERNEL_ROOT")"

FS_KCONFIG="$KERNEL_ROOT/fs/Kconfig"
FS_MAKEFILE="$KERNEL_ROOT/fs/Makefile"
SUSFS_DIR="$KERNEL_ROOT/fs/susfs"

ERRORS=0

# ── Sanity check: is this actually a kernel tree? ────────────────────────────
title "Checking kernel source tree"

if [ ! -f "$FS_KCONFIG" ]; then
    fail "fs/Kconfig not found at: $FS_KCONFIG"
    fail "Are you pointing at the right kernel root? (given: $KERNEL_ROOT)"
    exit 1
fi
pass "fs/Kconfig found"

if [ ! -f "$FS_MAKEFILE" ]; then
    fail "fs/Makefile not found at: $FS_MAKEFILE"
    exit 1
fi
pass "fs/Makefile found"

# ── Backup originals before touching anything ────────────────────────────────
title "Backing up originals"

backup() {
    local file="$1"
    local bak="${file}.susfs_bak"
    if [ ! -f "$bak" ]; then
        cp "$file" "$bak"
        info "Backed up $(basename $file) → $(basename $bak)"
    else
        info "Backup already exists for $(basename $file), skipping"
    fi
}

backup "$FS_KCONFIG"
backup "$FS_MAKEFILE"

# =============================================================================
# 1. fs/Kconfig
# =============================================================================
title "Checking fs/Kconfig"

# The source line we expect to find
KCONFIG_SOURCE='source "fs/susfs/Kconfig"'

if grep -qF "$KCONFIG_SOURCE" "$FS_KCONFIG"; then
    pass "SUSFS Kconfig source entry already present"
else
    warn "SUSFS Kconfig source entry missing — adding it"

    # Insert before endmenu at the end of fs/Kconfig
    if grep -q "^endmenu" "$FS_KCONFIG"; then
        sed -i "/^endmenu/i\\
\\
$KCONFIG_SOURCE" "$FS_KCONFIG"
        info "Inserted '$KCONFIG_SOURCE' before endmenu"
    else
        # No endmenu — just append
        printf '\n%s\n' "$KCONFIG_SOURCE" >> "$FS_KCONFIG"
        info "Appended '$KCONFIG_SOURCE' to end of fs/Kconfig (no endmenu found)"
    fi
fi

# =============================================================================
# 2. fs/Makefile — susfs.o
# =============================================================================
title "Checking fs/Makefile"

MAKEFILE_OBJ='obj-$(CONFIG_KSU_SUSFS) += susfs/'

if grep -qF "$MAKEFILE_OBJ" "$FS_MAKEFILE"; then
    pass "SUSFS Makefile obj entry already present"
else
    warn "SUSFS Makefile obj entry missing — adding it"

    # Try to insert after the last obj- line for a clean grouping
    if grep -q "^obj-" "$FS_MAKEFILE"; then
        # Append after the last obj- line
        LAST_OBJ_LINE=$(grep -n "^obj-" "$FS_MAKEFILE" | tail -1 | cut -d: -f1)
        sed -i "${LAST_OBJ_LINE}a\\
$MAKEFILE_OBJ" "$FS_MAKEFILE"
        info "Inserted obj entry after line $LAST_OBJ_LINE in fs/Makefile"
    else
        printf '\n%s\n' "$MAKEFILE_OBJ" >> "$FS_MAKEFILE"
        info "Appended obj entry to fs/Makefile"
    fi
fi

# =============================================================================
# 3. Check fs/susfs/ directory and its own Kconfig/Makefile exist
# =============================================================================
title "Checking fs/susfs/ directory"

if [ -d "$SUSFS_DIR" ]; then
    pass "fs/susfs/ directory exists"
else
    fail "fs/susfs/ directory does NOT exist — the SUSFS patch may not have been applied"
    warn "Apply your susfs patch first, then re-run this script"
    ERRORS=$((ERRORS + 1))
fi

# fs/susfs/Kconfig
if [ -f "$SUSFS_DIR/Kconfig" ]; then
    pass "fs/susfs/Kconfig exists"
else
    fail "fs/susfs/Kconfig is missing"
    ERRORS=$((ERRORS + 1))
fi

# fs/susfs/Makefile
if [ -f "$SUSFS_DIR/Makefile" ]; then
    pass "fs/susfs/Makefile exists"
else
    fail "fs/susfs/Makefile is missing"
    ERRORS=$((ERRORS + 1))
fi

# susfs.c source file
if [ -f "$SUSFS_DIR/susfs.c" ]; then
    pass "fs/susfs/susfs.c exists"
else
    fail "fs/susfs/susfs.c is missing"
    ERRORS=$((ERRORS + 1))
fi

# susfs.h header
SUSFS_HEADER="$KERNEL_ROOT/include/linux/susfs.h"
if [ -f "$SUSFS_HEADER" ]; then
    pass "include/linux/susfs.h exists"
else
    fail "include/linux/susfs.h is missing"
    ERRORS=$((ERRORS + 1))
fi

# =============================================================================
# 4. Validate — re-read the files and confirm entries are present
# =============================================================================
title "Validating final state"

VALIDATION_ERRORS=0

if grep -qF "$KCONFIG_SOURCE" "$FS_KCONFIG"; then
    pass "fs/Kconfig  → '$KCONFIG_SOURCE'"
else
    fail "fs/Kconfig  → entry still missing after attempted fix!"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

if grep -qF "$MAKEFILE_OBJ" "$FS_MAKEFILE"; then
    pass "fs/Makefile → '$MAKEFILE_OBJ'"
else
    fail "fs/Makefile → entry still missing after attempted fix!"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

# Check no duplicate entries were accidentally added
KCONFIG_COUNT=$(grep -cF "$KCONFIG_SOURCE" "$FS_KCONFIG" || true)
MAKEFILE_COUNT=$(grep -cF "$MAKEFILE_OBJ" "$FS_MAKEFILE" || true)

if [ "$KCONFIG_COUNT" -gt 1 ]; then
    warn "fs/Kconfig has $KCONFIG_COUNT duplicate SUSFS entries — deduplicating"
    # Keep only first occurrence
    awk '!seen[/'"$KCONFIG_SOURCE"'/]++' "$FS_KCONFIG" > "$FS_KCONFIG.tmp" && mv "$FS_KCONFIG.tmp" "$FS_KCONFIG"
    pass "Deduplicated fs/Kconfig"
else
    pass "fs/Kconfig has exactly 1 SUSFS entry (no duplicates)"
fi

if [ "$MAKEFILE_COUNT" -gt 1 ]; then
    warn "fs/Makefile has $MAKEFILE_COUNT duplicate SUSFS entries — deduplicating"
    awk '!seen[/'"$MAKEFILE_OBJ"'/]++' "$FS_MAKEFILE" > "$FS_MAKEFILE.tmp" && mv "$FS_MAKEFILE.tmp" "$FS_MAKEFILE"
    pass "Deduplicated fs/Makefile"
else
    pass "fs/Makefile has exactly 1 SUSFS entry (no duplicates)"
fi

# =============================================================================
# 5. Summary
# =============================================================================
title "Summary"

TOTAL_ERRORS=$((ERRORS + VALIDATION_ERRORS))

echo ""
echo -e "  fs/Kconfig  : $(grep -n "$KCONFIG_SOURCE" "$FS_KCONFIG" | head -1 | sed 's/^/line /' || echo 'NOT FOUND')"
echo -e "  fs/Makefile : $(grep -n "$MAKEFILE_OBJ" "$FS_MAKEFILE" | head -1 | sed 's/^/line /' || echo 'NOT FOUND')"
echo ""

if [ "$TOTAL_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}All checks passed. SUSFS is correctly wired into the fs/ build system.${NC}"
    exit 0
else
    echo -e "${RED}$TOTAL_ERRORS error(s) found. Check the output above.${NC}"
    echo -e "${YELLOW}Most likely cause: the SUSFS patch was not applied before running this script.${NC}"
    exit 1
fi
