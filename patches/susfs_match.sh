#!/bin/bash
set -e

echo "[*] Fixing KernelSU ↔ SUSFS mismatch..."

SUSFS_HEADER="include/linux/susfs.h"

if [ ! -f "$SUSFS_HEADER" ]; then
    echo "[!] susfs.h not found!"
    exit 1
fi

if grep -q "CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS" "$SUSFS_HEADER"; then
    echo "[✓] Symbols already exist. No fix needed."
    exit 0
fi

echo "[*] Injecting compatibility layer..."

cat << 'EOF' >> $SUSFS_HEADER

/* ===== KernelSU-Next compatibility layer (auto-injected) ===== */
#ifdef CONFIG_KSU_SUSFS

#ifndef CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS
#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS 0x1009
#endif

static inline void
susfs_set_hide_sus_mnts_for_all_procs(void __user *arg)
{
#ifdef susfs_set_hide_sus_mnts_for_non_su_procs
    susfs_set_hide_sus_mnts_for_non_su_procs((void __user **)arg);
#endif
}

static inline void
susfs_add_try_umount(void __user *arg)
{
    /* fallback stub */
    return;
}

#endif
/* ===== End compatibility layer ===== */

EOF

echo "[✓] Compatibility layer injected."
