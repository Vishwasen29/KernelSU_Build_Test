#!/usr/bin/env python3
# relax_ksu_kconfig.sh — invoked as: python3 relax_ksu_kconfig.sh <path/to/Kconfig>
#
# Removes two kinds of Kconfig constructs that cause syncconfig to silently
# strip CONFIG_KSU_* and CONFIG_KSU_SUSFS_* entries from .config at build time:
#
#   1. `depends on KSU*` lines inside config KSU_* blocks
#   2. `if KSU` / `if KSU_SUSFS` block wrappers and their matching `endif` lines
#
# WHY BOTH ARE NEEDED:
#
#   KernelSU-Next Kconfig (before SUSFS patch):
#
#     config KSU_MANUAL_HOOK
#         bool "..."
#         depends on KSU      <-- type 1: stripped by removing depends line
#
#   SUSFS Kconfig (added by sus4.patch inside drivers/kernelsu/Kconfig):
#
#     if KSU                  <-- type 2: block wrapper
#
#     config KSU_SUSFS
#         bool "..."
#         depends on KSU      <-- type 1
#
#     if KSU_SUSFS            <-- type 2: nested block wrapper
#
#     config KSU_SUSFS_SUS_PATH
#         bool "..."          <-- no explicit depends, but implicitly gated by
#                             --  the enclosing `if KSU_SUSFS` block
#     ...
#
#     endif # KSU_SUSFS       <-- type 2: removed to match its `if`
#     endif # KSU             <-- type 2: removed to match its `if`
#
#   The `if KSU` / `if KSU_SUSFS` wrappers are Kconfig MENU STRUCTURES, not
#   `depends on` lines. Syncconfig evaluates them as implicit dependencies for
#   every config inside the block. Removing only the `depends on` lines (as the
#   previous version did) left the `if` wrappers intact, so syncconfig still
#   stripped the SUSFS configs when KSU_SUSFS wasn't yet resolved.
#
# SAFETY:
#   - All KSU/SUSFS source files use #ifdef CONFIG_KSU_SUSFS guards anyway,
#     so the compiler enforces correct inclusion regardless of Kconfig.
#   - This kernel is non-GKI (4.19), so there is no ABI enforcement.
#   - The dependency lines exist for interactive menuconfig UX only.

import sys
import re

if len(sys.argv) != 2:
    print("Usage: python3 relax_ksu_kconfig.sh <Kconfig file>")
    sys.exit(1)

path = sys.argv[1]

print("  Reading: " + path)

with open(path) as f:
    src = f.readlines()

print("  Total lines: " + str(len(src)))

ksu_configs = [l.rstrip() for l in src if re.match(r'^config KSU', l)]
print("  KSU configs found: " + str(ksu_configs))

out = []
in_ksu_block = False
removed_depends = 0
removed_if = 0
ksu_if_depth = 0  # tracks how many `if KSU*` levels deep we are

for line in src:

    # --- Type 2: `if KSU*` block openers ---
    # Remove the opener and track nesting depth so we can remove the
    # matching `endif` later.
    if re.match(r'^if\s+KSU', line):
        ksu_if_depth += 1
        print('  REMOVED if:     ' + line.rstrip())
        removed_if += 1
        in_ksu_block = False  # `if` resets config-block tracking
        continue

    # --- Type 2: `endif` matching a removed `if KSU*` ---
    if re.match(r'^endif', line) and ksu_if_depth > 0:
        ksu_if_depth -= 1
        print('  REMOVED endif:  ' + line.rstrip())
        removed_if += 1
        continue

    # --- Track entry into config KSU_* blocks ---
    if re.match(r'^config KSU', line):
        in_ksu_block = True
    elif re.match(r'^(config|menuconfig|choice|endchoice|menu|endmenu|source|if|endif)\b', line):
        in_ksu_block = False

    # --- Type 1: `depends on KSU*` inside a config KSU_* block ---
    if in_ksu_block and re.match(r'^\s+depends on KSU', line):
        print('  REMOVED depends: ' + line.rstrip())
        removed_depends += 1
        continue

    out.append(line)

with open(path, 'w') as f:
    f.writelines(out)

print('  Done: removed ' + str(removed_depends) + ' depends line(s), ' +
      str(removed_if) + ' if/endif line(s) from ' + path)
