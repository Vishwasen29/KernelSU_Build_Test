#!/usr/bin/env python3
"""
fix_namei.py
------------
Fixes two compiler errors in fs/namei.c introduced by susfs_reject_fix.py:

Problem 1 — Missing #include <linux/susfs_def.h>
  The SUSFS patch hunk that adds this include failed to apply (it's in the .rej).
  Without it, ND_STATE_LOOKUP_LAST, ND_STATE_OPEN_LAST, ND_STATE_LAST_SDCARD_SUS_PATH,
  BIT_OPEN_REDIRECT and other susfs_def.h symbols are undeclared — even though the
  code using them (from earlier successful patch hunks) is already in namei.c.

Problem 2 — Wrong inode field in BIT_OPEN_REDIRECT check
  susfs_reject_fix.py injects the OPEN_REDIRECT guard using:
      filp->f_inode->i_state & BIT_OPEN_REDIRECT         <- wrong
  The original SUSFS patch rej uses:
      filp->f_inode->i_mapping->flags & BIT_OPEN_REDIRECT <- correct

Usage:
    python3 fix_namei.py <kernel_root>

Example:
    python3 fix_namei.py $GITHUB_WORKSPACE/kernel_workspace/android-kernel
"""

import sys
import os

def fix_namei(kernel_root):
    filepath = os.path.join(kernel_root, 'fs', 'namei.c')

    if not os.path.exists(filepath):
        print(f'  [SKIP] {filepath} not found')
        return True

    with open(filepath) as f:
        src = f.read()

    original = src
    changes = []

    # ─────────────────────────────────────────────────────────────────────
    # Fix 1: Add #include <linux/susfs_def.h>
    #
    # The include hunk in the SUSFS patch failed to apply, so susfs_def.h
    # is never included. All ND_STATE_* and BIT_OPEN_REDIRECT references
    # produce "undeclared identifier" errors at compile time even though
    # the code using them was already added by earlier successful hunks.
    # ─────────────────────────────────────────────────────────────────────
    INCLUDE_BLOCK = (
        '#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n'
        '#include <linux/susfs_def.h>\n'
        '#endif'
    )

    if 'susfs_def.h' in src:
        changes.append('susfs_def.h already included — skipped')
    else:
        # Insert after #include <linux/uaccess.h> (last system header in this file)
        ANCHOR = '#include <linux/uaccess.h>'
        if ANCHOR in src:
            src = src.replace(ANCHOR, ANCHOR + '\n' + INCLUDE_BLOCK, 1)
            changes.append('added susfs_def.h include after <linux/uaccess.h>')
        else:
            # Fallback: insert before #include "mount.h"
            ANCHOR2 = '#include "mount.h"'
            if ANCHOR2 in src:
                src = src.replace(ANCHOR2, INCLUDE_BLOCK + '\n' + ANCHOR2, 1)
                changes.append('added susfs_def.h include before "mount.h" (fallback anchor)')
            else:
                changes.append('WARNING: could not find anchor for susfs_def.h include')

    # ─────────────────────────────────────────────────────────────────────
    # Fix 2: Correct the BIT_OPEN_REDIRECT field from i_state to i_mapping->flags
    #
    # susfs_reject_fix.py uses the wrong inode field. The original SUSFS patch
    # uses address_space flags (i_mapping->flags), not inode->i_state.
    # ─────────────────────────────────────────────────────────────────────
    WRONG   = 'filp->f_inode->i_state & BIT_OPEN_REDIRECT'
    CORRECT = 'filp->f_inode->i_mapping->flags & BIT_OPEN_REDIRECT'

    if WRONG in src:
        src = src.replace(WRONG, CORRECT)
        changes.append('fixed BIT_OPEN_REDIRECT: i_state -> i_mapping->flags')
    elif CORRECT in src:
        changes.append('BIT_OPEN_REDIRECT already uses i_mapping->flags — skipped')
    else:
        changes.append('BIT_OPEN_REDIRECT check not found — skipped')

    # ─────────────────────────────────────────────────────────────────────
    # Write result
    # ─────────────────────────────────────────────────────────────────────
    if src == original:
        print('  [INFO] fs/namei.c: no changes needed')
        return True

    with open(filepath, 'w') as f:
        f.write(src)

    applied = [c for c in changes if 'skipped' not in c and not c.startswith('WARNING')]
    print(f'  [OK]   fs/namei.c: applied {len(applied)} fix(es):')
    for c in changes:
        prefix = '  [WARN]    ' if c.startswith('WARNING') else '           '
        print(f'{prefix} • {c}')
    return True


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <kernel_root>')
        sys.exit(1)

    kernel_root = sys.argv[1]
    print('[namei fix] Fixing fs/namei.c compiler errors ...')
    ok = fix_namei(kernel_root)
    sys.exit(0 if ok else 1)
