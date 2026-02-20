#!/usr/bin/env bash
# =============================================================================
# verify_susfs.sh
#
# Post-build verification — confirms SUSFS was actually compiled in.
# Exits 1 (failing the CI job) only if susfs.o is missing AND no SUSFS
# symbols appear in System.map, which is conclusive proof of no integration.
#
# Usage: bash verify_susfs.sh <kernel-root>
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-.}"
OUT="$KERNEL_ROOT/out"
PASS=0
FAIL=0

separator() { printf '%0.s─' {1..60}; echo; }

separator
echo "SUSFS post-build verification"
separator

# ── Check 1: susfs.o object file ────────────────────────────────────────────
echo ""
echo "[CHECK 1] susfs.o object file"
SUSFS_OBJ=$(find "$OUT" -name "susfs.o" 2>/dev/null || true)
if [[ -n "$SUSFS_OBJ" ]]; then
  echo "  [PASS] susfs.o found:"
  echo "$SUSFS_OBJ" | sed 's/^/         /'
  PASS=$((PASS + 1))
else
  echo "  [FAIL] susfs.o not found under $OUT"
  FAIL=$((FAIL + 1))
fi

# ── Check 2: System.map symbols ─────────────────────────────────────────────
echo ""
echo "[CHECK 2] SUSFS symbols in System.map"
SYSMAP="$OUT/System.map"
if [[ ! -f "$SYSMAP" ]]; then
  echo "  [SKIP] System.map not present (build may not be complete)"
else
  SYMS=$(grep "susfs_" "$SYSMAP" 2>/dev/null || true)
  if [[ -n "$SYMS" ]]; then
    echo "  [PASS] SUSFS symbols found in System.map:"
    echo "$SYMS" | head -10 | sed 's/^/         /'
    REMAINING=$(echo "$SYMS" | wc -l)
    [[ $REMAINING -gt 10 ]] && echo "         ... and $((REMAINING - 10)) more"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] No susfs_* symbols in System.map"
    FAIL=$((FAIL + 1))
  fi
fi

# ── Check 3: vmlinux strings (belt-and-suspenders) ──────────────────────────
echo ""
echo "[CHECK 3] SUSFS strings in vmlinux"
VMLINUX="$OUT/vmlinux"
if [[ ! -f "$VMLINUX" ]]; then
  echo "  [SKIP] vmlinux not found"
else
  if strings "$VMLINUX" 2>/dev/null | grep -q "SUSFS"; then
    echo "  [PASS] SUSFS strings present in vmlinux"
    PASS=$((PASS + 1))
  else
    echo "  [WARN] No SUSFS strings in vmlinux (may still be compiled; strings check is advisory)"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
separator
echo "Results: $PASS passed, $FAIL failed"
separator

if [[ $FAIL -gt 0 ]] && [[ $PASS -eq 0 ]]; then
  echo ""
  echo "[FATAL] SUSFS was NOT compiled into the kernel."
  echo "        Check that add_susfs_kconfig.sh ran before configure_kernel.sh"
  echo "        and that sus4.patch / fix3.sh applied without critical errors."
  exit 1
fi

echo "[OK] SUSFS integration verified"
