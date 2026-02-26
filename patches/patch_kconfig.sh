#!/bin/bash
# patch_kconfig.sh
#
# Appends missing CONFIG_KSU_SUSFS_* entries into KernelSU/kernel/Kconfig.
# Safe to run multiple times — each entry is only added if not already present.
#
# Usage:
#   bash patch_kconfig.sh [path/to/android-kernel]
#   (defaults to current directory if no argument given)

set -e

KERNEL_ROOT="${1:-.}"
KCONFIG="${KERNEL_ROOT}/KernelSU/kernel/Kconfig"

if [ ! -f "$KCONFIG" ]; then
    echo "ERROR: Kconfig not found at: $KCONFIG"
    echo "       Make sure KernelSU setup has run first."
    exit 1
fi

echo "=== Patching missing SUSFS entries into KernelSU Kconfig ==="
echo "    File: $KCONFIG"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# add_entry <symbol>
# Appends the Kconfig block only if the symbol is not already present.
# Each block is written by Python using a raw string so indentation is always
# exactly one real tab — no bash heredoc / YAML indentation corruption.
# ─────────────────────────────────────────────────────────────────────────────
add_entry() {
    local symbol="$1"

    if grep -q "config ${symbol}" "$KCONFIG"; then
        echo "  [skip]  config ${symbol}  (already present)"
        return
    fi

    echo "  [add]   config ${symbol}"

    python3 << PYEOF
kconfig_path = "$KCONFIG"
symbol = "$symbol"

# Each block uses real tab characters (chr(9)) — not \t escape sequences
blocks = {
    "KSU_SUSFS_SUS_SU": (
        "config KSU_SUSFS_SUS_SU\n"
        "\tbool \"Enable sus_su support\"\n"
        "\tdepends on KSU_SUSFS\n"
        "\tdefault y\n"
        "\thelp\n"
        "\t  Allow KernelSU to use sus_su as an alternative way to grant a\n"
        "\t  root shell. Disable if you are using kprobe-based hooks instead.\n"
    ),
    "KSU_SUSFS_HAS_MAGIC_MOUNT": (
        "config KSU_SUSFS_HAS_MAGIC_MOUNT\n"
        "\tbool \"Enable magic mount support for SUSFS\"\n"
        "\tdepends on KSU_SUSFS\n"
        "\tdefault y\n"
        "\thelp\n"
        "\t  Enable magic mount support. Required for module overlay mounts\n"
        "\t  to be hidden correctly from userspace processes.\n"
    ),
    "KSU_SUSFS_SUS_OVERLAYFS": (
        "config KSU_SUSFS_SUS_OVERLAYFS\n"
        "\tbool \"Enable sus overlayfs support\"\n"
        "\tdepends on KSU_SUSFS\n"
        "\tdefault y\n"
        "\thelp\n"
        "\t  Hide KernelSU overlayfs mounts from userspace processes.\n"
    ),
}

block = blocks.get(symbol)
if block is None:
    print(f"ERROR: no block defined for {symbol}")
    raise SystemExit(1)

with open(kconfig_path, "a") as f:
    f.write("\n")
    f.write(block)
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Add each missing entry
# ─────────────────────────────────────────────────────────────────────────────
add_entry "KSU_SUSFS_SUS_SU"
add_entry "KSU_SUSFS_HAS_MAGIC_MOUNT"
add_entry "KSU_SUSFS_SUS_OVERLAYFS"

# ─────────────────────────────────────────────────────────────────────────────
# Show final state
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== All config KSU_SUSFS entries now in Kconfig ==="
grep "config KSU_SUSFS" "$KCONFIG"
echo "===================================================="
echo ""
echo "Done."
