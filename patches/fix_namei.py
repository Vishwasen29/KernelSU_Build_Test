#!/usr/bin/env python3
"""
fix_namei.py
------------
Fixes four issues in fs/namei.c caused by failed/misapplied SUSFS patches
and a wrong injection by susfs_reject_fix.py.

Issue 1 — Missing #include <linux/susfs_def.h>
  The include hunk failed to apply (.rej). Without it, ND_STATE_* and
  BIT_OPEN_REDIRECT are undeclared even though the code using them is present.

Issue 2 — Wrong inode field in BIT_OPEN_REDIRECT check
  susfs_reject_fix.py injects:  filp->f_inode->i_state & BIT_OPEN_REDIRECT
  Correct form from the .rej:   filp->f_inode->i_mapping->flags & BIT_OPEN_REDIRECT

Issue 3 — Misplaced lookup_slow body fragment in do_mknod()
  The lookup_slow SUS_PATH hunk applied at a wrong line offset and landed inside
  do_mknod() instead of lookup_slow(). The block references is_nd_flags_lookup_last,
  found_sus_path, dir, sus_wq — all local to lookup_slow, undeclared in do_mknod.

Issue 4 — Misplaced ND_STATE_LAST_SDCARD_SUS_PATH block in vfs_unlink2()
  Another hunk landed at the wrong offset, placing an nd->state / parent / name
  block inside vfs_unlink2(), where none of those locals exist.

Usage:
    python3 fix_namei.py <kernel_root>

Example:
    python3 fix_namei.py $GITHUB_WORKSPACE/kernel_workspace/android-kernel
"""

import sys
import os
import re


def remove_ifdef_block(src, start_signature):
    """Remove a complete #ifdef...#endif block identified by its opening signature."""
    idx = src.find(start_signature)
    if idx == -1:
        return src, False

    # Walk forward counting #if/#endif depth to find the matching #endif
    search_from = idx
    depth = 0
    block_end = -1
    for m in re.finditer(r'#\s*(?:ifdef|ifndef|if\b|elif|else|endif)', src[search_from:]):
        token = m.group().replace(' ', '')
        if token in ('#ifdef', '#ifndef', '#if'):
            depth += 1
        elif token == '#endif':
            depth -= 1
            if depth == 0:
                end_pos = search_from + m.end()
                # Include trailing newline
                if end_pos < len(src) and src[end_pos] == '\n':
                    end_pos += 1
                block_end = end_pos
                break

    if block_end == -1:
        return src, False

    src = src[:idx] + src[block_end:]
    return src, True


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
    # ─────────────────────────────────────────────────────────────────────
    INCLUDE_BLOCK = (
        '#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n'
        '#include <linux/susfs_def.h>\n'
        '#endif'
    )
    if 'susfs_def.h' in src:
        changes.append('susfs_def.h already included — skipped')
    else:
        for anchor in ('#include <linux/uaccess.h>', '#include "mount.h"'):
            if anchor in src:
                if anchor == '#include "mount.h"':
                    src = src.replace(anchor, INCLUDE_BLOCK + '\n' + anchor, 1)
                else:
                    src = src.replace(anchor, anchor + '\n' + INCLUDE_BLOCK, 1)
                changes.append(f'added susfs_def.h include (anchor: {anchor})')
                break
        else:
            changes.append('WARNING: could not find anchor for susfs_def.h include')

    # ─────────────────────────────────────────────────────────────────────
    # Fix 2: Correct BIT_OPEN_REDIRECT field: i_state → i_mapping->flags
    # ─────────────────────────────────────────────────────────────────────
    WRONG   = 'filp->f_inode->i_state & BIT_OPEN_REDIRECT'
    CORRECT = 'filp->f_inode->i_mapping->flags & BIT_OPEN_REDIRECT'
    if WRONG in src:
        src = src.replace(WRONG, CORRECT)
        changes.append('fixed BIT_OPEN_REDIRECT: i_state → i_mapping->flags')
    elif CORRECT in src:
        changes.append('BIT_OPEN_REDIRECT already uses i_mapping->flags — skipped')
    else:
        changes.append('BIT_OPEN_REDIRECT check not found — skipped')

    # ─────────────────────────────────────────────────────────────────────
    # Fix 3: Remove misplaced lookup_slow fragment from do_mknod()
    # Signature: the #ifdef block opening with is_nd_flags_lookup_last check
    # ─────────────────────────────────────────────────────────────────────
    SIG3 = '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (is_nd_flags_lookup_last && !found_sus_path)'
    if SIG3 in src:
        src, ok = remove_ifdef_block(src, SIG3)
        changes.append('removed misplaced lookup_slow fragment from do_mknod()' if ok
                       else 'WARNING: found sig3 but could not remove block')
    else:
        changes.append('misplaced lookup_slow fragment not present — skipped')

    # ─────────────────────────────────────────────────────────────────────
    # Fix 4: Remove misplaced ND_STATE_LAST_SDCARD_SUS_PATH block from vfs_unlink2()
    # Signature: the #ifdef block opening with nd->state & ND_STATE_LAST_SDCARD_SUS_PATH
    # ─────────────────────────────────────────────────────────────────────
    SIG4 = '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\t\t\tif (nd->state & ND_STATE_LAST_SDCARD_SUS_PATH)'
    if SIG4 in src:
        src, ok = remove_ifdef_block(src, SIG4)
        changes.append('removed misplaced ND_STATE_LAST_SDCARD_SUS_PATH block from vfs_unlink2()' if ok
                       else 'WARNING: found sig4 but could not remove block')
    else:
        changes.append('misplaced ND_STATE_LAST_SDCARD_SUS_PATH block not present — skipped')

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
    print('[namei fix] Fixing fs/namei.c compiler errors ...')
    ok = fix_namei(sys.argv[1])
    sys.exit(0 if ok else 1)
  
