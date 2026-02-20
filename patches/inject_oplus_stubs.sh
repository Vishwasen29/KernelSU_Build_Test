#!/usr/bin/env bash
# =============================================================================
# inject_oplus_stubs.sh
#
# Injects weak stub implementations for OPlus/SMB symbols that are referenced
# by compiled drivers but whose defining drivers are absent (disabled configs).
#
# LLD (unlike GNU ld) treats unresolved symbols as hard errors. These stubs
# use __weak linkage so any real implementation in the tree takes precedence;
# the stubs only activate when the real driver is not compiled.
#
# Usage:
#   bash inject_oplus_stubs.sh <kernel_root>
#
# Example (from workflow):
#   bash $GITHUB_WORKSPACE/patches/inject_oplus_stubs.sh \
#     $GITHUB_WORKSPACE/kernel_workspace/android-kernel
# =============================================================================

set -euo pipefail

KERNEL_ROOT="${1:?Usage: $0 <kernel_root>}"
STUB_DIR="$KERNEL_ROOT/drivers/misc"
STUB_SRC="$STUB_DIR/oplus_stubs.c"
STUB_MK="$STUB_DIR/Makefile"

if [ ! -d "$STUB_DIR" ]; then
  echo "[ERROR] $STUB_DIR does not exist — is KERNEL_ROOT correct?" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Write the stub C file
# -----------------------------------------------------------------------------
cat > "$STUB_SRC" << 'STUB_EOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * oplus_stubs.c - Weak stub implementations for missing OPlus/SMB symbols
 *
 * These stubs satisfy linker references when the real OPlus driver subsystems
 * (oplus_project, oplus_chg, smb5-lib, etc.) are not compiled due to missing
 * Kconfig options. Each function is marked __weak so the linker will prefer
 * any real definition found elsewhere in the tree.
 *
 * Return values are chosen to be safe no-ops:
 *   - Board info functions return 0 (treated as "unknown/default" by callers)
 *   - VOOC/charging predicates return 0 (false — no fast-charge activity)
 *   - SMB I/O functions return -ENODEV (I/O failure, driver will not init)
 *   - Notifier returns NOTIFY_DONE (no handlers registered)
 *   - void functions are empty
 */

#include <linux/kernel.h>
#include <linux/errno.h>
#include <linux/types.h>
#include <linux/notifier.h>

/* --- OPlus board / project identification --------------------------------- */
int __weak is_project(int project)  { return 0; }
int __weak get_project(void)        { return 0; }
int __weak get_PCB_Version(void)    { return 0; }
int __weak get_boot_mode(void)      { return 0; }

/* --- OPlus display notifier ----------------------------------------------- */
int __weak msm_drm_notifier_call_chain(unsigned long val, void *v)
{
	return NOTIFY_DONE;
}

/* --- OPlus optical fingerprint -------------------------------------------- */
int __weak opticalfp_irq_handler_register(void *handler) { return 0; }

/* --- OPlus headset -------------------------------------------------------- */
void __weak switch_headset_state(int state) {}

/* --- OPlus charger / gauge ------------------------------------------------ */
int __weak oplus_gauge_init(void *chip) { return 0; }

/* --- OPlus VOOC fast-charge ----------------------------------------------- */
int __weak oplus_vooc_get_fastchg_started(void)          { return 0; }
int __weak oplus_vooc_get_fastchg_ing(void)               { return 0; }
int __weak oplus_vooc_adapter_update_is_rx_gpio(int gpio) { return 0; }
int __weak oplus_vooc_adapter_update_is_tx_gpio(int gpio) { return 0; }

/* --- OPlus USB / OTG / PD ------------------------------------------------- */
void __weak switch_to_otg_mode(int mode) {}
int __weak opchg_set_pd_sdp(void *dev, bool sdp) { return 0; }

/* --- QPNP power-off charging ---------------------------------------------- */
int __weak qpnp_is_power_off_charging(void) { return 0; }

/* --- SMB5 charger library ------------------------------------------------- */
/* smblib_* are defined in smb5-lib.c; stubs activate when that file is not  */
/* compiled (e.g. CONFIG_QPNP_SMB5 disabled). -ENODEV causes schgm-flash to  */
/* fail its probe cleanly rather than silently doing nothing.                  */
int __weak smblib_read(void *chg, unsigned short addr, unsigned char *val)
{
	return -ENODEV;
}
int __weak smblib_write(void *chg, unsigned short addr, unsigned char val)
{
	return -ENODEV;
}
int __weak smblib_masked_write(void *chg, unsigned short addr,
			       unsigned char mask, unsigned char val)
{
	return -ENODEV;
}
STUB_EOF

echo "[OK] Written: $STUB_SRC"

# -----------------------------------------------------------------------------
# Wire the stub into the build
# -----------------------------------------------------------------------------
if grep -q "oplus_stubs" "$STUB_MK"; then
  echo "[SKIP] oplus_stubs already present in $STUB_MK"
else
  echo "" >> "$STUB_MK"
  echo "# Weak stubs for missing OPlus/SMB symbols (injected by inject_oplus_stubs.sh)" >> "$STUB_MK"
  echo "obj-y += oplus_stubs.o" >> "$STUB_MK"
  echo "[OK] Registered oplus_stubs.o in $STUB_MK"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "Stubs registered:"
grep "^int __weak\|^void __weak" "$STUB_SRC" | sed 's/__weak //' | sed 's/{.*//' | \
  awk '{printf "  %-45s\n", $0}'
