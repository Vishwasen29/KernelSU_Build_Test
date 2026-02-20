#!/usr/bin/env bash
# =============================================================================
# create_oplus_stubs.sh
#
# Generates drivers/misc/oplus_stubs.c — __weak fallbacks for every OPlus
# platform symbol that is referenced across the Lineage SM8250 tree but
# defined only in the closed OPlus BSP (not available in a plain Lineage
# build).
#
# Affected call sites (from linker error log):
#   techpack/display  → msm_drm_notifier_call_chain, is_project,
#                       get_boot_mode, opticalfp_irq_handler_register
#   drivers/gpio      → oplus_vooc_adapter_update_is_rx/tx_gpio
#   drivers/soc/qcom  → get_project, get_PCB_Version
#   drivers/i2c       → oplus_vooc_get_fastchg_started/ing
#   drivers/usb/pd    → switch_to_otg_mode, opchg_set_pd_sdp
#   drivers/power     → oplus_gauge_init, qpnp_is_power_off_charging,
#                       smblib_read/write/masked_write
#   sound/soc         → switch_headset_state
#   drivers/net       → qpnp_is_power_off_charging
#
# __weak means: if a real implementation is ever linked in (e.g. from a
# proper OPlus BSP drop), it silently overrides these stubs — no conflict.
#
# Usage: bash create_oplus_stubs.sh <kernel-root>
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-.}"
STUB_DIR="$KERNEL_ROOT/drivers/misc"
STUB_FILE="$STUB_DIR/oplus_stubs.c"
MAKEFILE="$STUB_DIR/Makefile"

if [[ ! -d "$STUB_DIR" ]]; then
  echo "[FATAL] drivers/misc not found under $KERNEL_ROOT"
  exit 1
fi

# ── Write the stub source ────────────────────────────────────────────────────
cat > "$STUB_FILE" << 'C_EOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * oplus_stubs.c
 *
 * Weak-symbol fallbacks for OPlus BSP platform APIs that are referenced in
 * the Lineage android_kernel_oneplus_sm8250 tree but not defined without the
 * full OPlus platform SDK.
 *
 * All symbols are marked __weak so a real BSP implementation will silently
 * override these at link time without any conflict.
 *
 * DO NOT add device-specific logic here.  This file exists only to satisfy
 * the linker; behaviour is intentionally inert (return 0 / no-op).
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/export.h>

/* ── OPlus project / hardware detection ─────────────────────────────────── */

/**
 * get_project() - return OPlus project ID
 * Returns 0 (unknown) when OPlus BSP is not present.
 */
int __weak get_project(void) { return 0; }
EXPORT_SYMBOL_GPL(get_project);

/**
 * is_project() - test whether the device matches a project ID
 * Always returns 0 (false) without OPlus BSP.
 */
int __weak is_project(int project) { (void)project; return 0; }
EXPORT_SYMBOL_GPL(is_project);

/**
 * get_PCB_Version() - return PCB hardware revision
 */
int __weak get_PCB_Version(void) { return 0; }
EXPORT_SYMBOL_GPL(get_PCB_Version);

/**
 * get_boot_mode() - return OPlus boot mode (normal / factory / recovery …)
 */
int __weak get_boot_mode(void) { return 0; }
EXPORT_SYMBOL_GPL(get_boot_mode);

/* ── OPlus VOOC fast-charge ─────────────────────────────────────────────── */

int __weak oplus_vooc_get_fastchg_started(void) { return 0; }
EXPORT_SYMBOL_GPL(oplus_vooc_get_fastchg_started);

int __weak oplus_vooc_get_fastchg_ing(void) { return 0; }
EXPORT_SYMBOL_GPL(oplus_vooc_get_fastchg_ing);

/**
 * oplus_vooc_adapter_update_is_rx_gpio() / _tx_gpio()
 * Called from gpiolib to check whether a GPIO toggle is part of VOOC
 * adapter negotiation.  Return 0 (false) to let the normal GPIO path run.
 */
int __weak oplus_vooc_adapter_update_is_rx_gpio(void) { return 0; }
EXPORT_SYMBOL_GPL(oplus_vooc_adapter_update_is_rx_gpio);

int __weak oplus_vooc_adapter_update_is_tx_gpio(void) { return 0; }
EXPORT_SYMBOL_GPL(oplus_vooc_adapter_update_is_tx_gpio);

/* ── OPlus gauge / charger ──────────────────────────────────────────────── */

/**
 * oplus_gauge_init() - register an OPlus gauge IC driver
 * @gauge: opaque pointer to gauge struct
 * Returns 0 (success stub).
 */
int __weak oplus_gauge_init(void *gauge) { (void)gauge; return 0; }
EXPORT_SYMBOL_GPL(oplus_gauge_init);

/**
 * qpnp_is_power_off_charging() - true if in power-off charging mode
 */
int __weak qpnp_is_power_off_charging(void) { return 0; }
EXPORT_SYMBOL_GPL(qpnp_is_power_off_charging);

/**
 * opchg_set_pd_sdp() - tell OPlus charger driver about PD/SDP state
 */
void __weak opchg_set_pd_sdp(int enable) { (void)enable; }
EXPORT_SYMBOL_GPL(opchg_set_pd_sdp);

/**
 * switch_to_otg_mode() - enable/disable OTG power path
 */
void __weak switch_to_otg_mode(int enable) { (void)enable; }
EXPORT_SYMBOL_GPL(switch_to_otg_mode);

/* ── QCOM SMB5 charger library ──────────────────────────────────────────── */
/*
 * smblib_read/write/masked_write are defined in smb5-lib.c.  That file may
 * not be compiled when the SMB5 charger Kconfig is off, yet schgm-flash.c
 * (flash LED driver) calls them unconditionally.  These stubs prevent the
 * link error; schgm-flash will simply be a no-op LED driver in that case.
 */

int __weak smblib_read(void *chg, u16 addr, u8 *val)
{
	(void)chg; (void)addr;
	if (val)
		*val = 0;
	return 0;
}
EXPORT_SYMBOL_GPL(smblib_read);

int __weak smblib_write(void *chg, u16 addr, u8 val)
{
	(void)chg; (void)addr; (void)val;
	return 0;
}
EXPORT_SYMBOL_GPL(smblib_write);

int __weak smblib_masked_write(void *chg, u16 addr, u8 mask, u8 val)
{
	(void)chg; (void)addr; (void)mask; (void)val;
	return 0;
}
EXPORT_SYMBOL_GPL(smblib_masked_write);

/* ── MSM DRM notifier ───────────────────────────────────────────────────── */

/**
 * msm_drm_notifier_call_chain() - fire display-event notifier chain
 * Stub returns 0 (NOTIFY_OK) so callers see a successful notification.
 */
int __weak msm_drm_notifier_call_chain(unsigned long val, void *v)
{
	(void)val; (void)v;
	return 0;
}
EXPORT_SYMBOL_GPL(msm_drm_notifier_call_chain);

/* ── Fingerprint / headset ──────────────────────────────────────────────── */

/**
 * opticalfp_irq_handler_register() - register an optical FP IRQ handler
 */
int __weak opticalfp_irq_handler_register(void *handler)
{
	(void)handler;
	return 0;
}
EXPORT_SYMBOL_GPL(opticalfp_irq_handler_register);

/**
 * switch_headset_state() - notify OPlus platform of headset insertion/removal
 */
void __weak switch_headset_state(int state) { (void)state; }
EXPORT_SYMBOL_GPL(switch_headset_state);
C_EOF

echo "[OK] oplus_stubs.c written to $STUB_FILE"

# ── Hook into the Makefile ───────────────────────────────────────────────────
if grep -q "oplus_stubs" "$MAKEFILE" 2>/dev/null; then
  echo "[SKIP] oplus_stubs.o already present in $MAKEFILE"
else
  # Append unconditionally — obj-y ensures it's always built-in
  echo "" >> "$MAKEFILE"
  echo "# OPlus BSP weak-symbol stubs (auto-generated by create_oplus_stubs.sh)" >> "$MAKEFILE"
  echo "obj-y += oplus_stubs.o" >> "$MAKEFILE"
  echo "[OK] oplus_stubs.o added to $MAKEFILE"
fi

echo "[DONE] OPlus stubs ready — 18 symbols covered"
