#!/usr/bin/env python3
# relax_ksu_kconfig.sh — invoked as: python3 relax_ksu_kconfig.sh <path/to/Kconfig>
#
# Removes all "depends on KSU..." lines from inside config KSU_* blocks.
#
# WHY THIS IS NEEDED:
#   KernelSU-Next's Kconfig defines sub-configs with dependency chains like:
#
#     config KSU_MANUAL_HOOK
#         bool "Enable manual hook"
#         depends on KSU            <-- stripped by this script
#
#     config KSU_SUSFS_SUS_MOUNT
#         bool "..."
#         depends on KSU_SUSFS      <-- stripped by this script
#
#   When 'make' starts a build it runs 'syncconfig' internally before compiling.
#   syncconfig re-evaluates every config's dependency chain. If a dependency
#   isn't already resolved in the .config at that moment, the dependent config
#   gets silently reset to NOT_SET — even if we wrote it directly to .config
#   in an earlier step.
#
#   Removing these depends lines makes the KSU configs unconditionally visible
#   to Kconfig. This is safe because:
#     - The kernel source files guard all SUSFS/KSU code with #ifdef at compile
#       time, so the compiler still enforces correct inclusion.
#     - This kernel is non-GKI (4.19), so there is no ABI enforcement.
#     - The dependency lines were added for interactive menuconfig UX (to
#       hide irrelevant sub-options), not for build correctness.

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

# Print all KSU config entries found for diagnostics
ksu_configs = [l.rstrip() for l in src if re.match(r'^config KSU', l)]
print("  KSU configs found: " + str(ksu_configs))

out = []
in_ksu_block = False
removed = 0

for line in src:
    # Detect entry into a config KSU_* block
    if re.match(r'^config KSU', line):
        in_ksu_block = True

    # Detect entry into any other top-level Kconfig directive -- reset context
    elif re.match(r'^(config|menuconfig|choice|endchoice|menu|endmenu|source)\b', line):
        in_ksu_block = False

    elif re.match(r'^(if|endif)\b', line):
        in_ksu_block = False

    # Inside a KSU_* block: drop any line that says 'depends on KSU...'
    if in_ksu_block and re.match(r'^\s+depends on KSU', line):
        print('  REMOVED: ' + line.rstrip())
        removed += 1
        continue

    out.append(line)

with open(path, 'w') as f:
    f.writelines(out)

print('  Done: removed ' + str(removed) + ' dependency line(s) from ' + path)
