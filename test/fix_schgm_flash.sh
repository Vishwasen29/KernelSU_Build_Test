#!/usr/bin/env bash
# =============================================================================
# fix_schgm_flash.sh
#
# schgm-flash.c calls smblib_read/write/masked_write, which are declared in
# smb5-lib.h via struct smb_charger.  Without smb5-lib.h being included
# BEFORE schgm-flash.h, clang sees an incomplete type and errors out.
#
# This script:
#   1. Inserts `#include "smb5-lib.h"` before `#include "schgm-flash.h"` in
#      schgm-flash.c (idempotent — won't double-insert).
#   2. Adds a `struct smb_charger;` forward declaration to schgm-flash.h so
#      files that include the header without smb5-lib.h don't break.
#
# Must be run from the kernel root directory.
# Usage: bash fix_schgm_flash.sh   (run from kernel root)
# =============================================================================
set -euo pipefail

DIR="drivers/power/supply/qcom"
HDR="$DIR/schgm-flash.h"
SRC="$DIR/schgm-flash.c"

for f in "$HDR" "$SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "[FATAL] Expected file not found: $f"
    exit 1
  fi
done

# ── SRC: ensure smb5-lib.h comes before schgm-flash.h ──────────────────────
# Remove any previous attempts first (idempotency)
sed -i '/#include "smb-lib.h"/d'  "$SRC"
sed -i '/#include "smb5-lib.h"/d' "$SRC"

# Insert smb5-lib.h on the line immediately before schgm-flash.h
if grep -q '#include "schgm-flash.h"' "$SRC"; then
  sed -i '/#include "schgm-flash.h"/i #include "smb5-lib.h"' "$SRC"
  echo "[OK] smb5-lib.h inserted before schgm-flash.h in $SRC"
else
  echo "[WARN] Could not find '#include \"schgm-flash.h\"' in $SRC — skipping"
fi

# ── HDR: add forward declaration for struct smb_charger ─────────────────────
if grep -q "^struct smb_charger;" "$HDR"; then
  echo "[SKIP] 'struct smb_charger;' forward decl already in $HDR"
else
  # Insert before the first function prototype that uses smb_charger
  sed -i '/schgm_flash_get_vreg_ok/i struct smb_charger;' "$HDR"
  echo "[OK] 'struct smb_charger;' forward decl added to $HDR"
fi

# ── Diagnostic dump ──────────────────────────────────────────────────────────
echo ""
echo "Include order in $SRC (smb5-lib.h must appear before schgm-flash.h):"
grep -n '^#include' "$SRC" | head -12
echo ""
echo "Forward decls in $HDR:"
grep -n "^struct smb_charger" "$HDR" || echo "  (none found)"
