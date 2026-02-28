#!/usr/bin/env python3
"""
fix_task_mmu_pagemap.py
-----------------------
Injects the CONFIG_KSU_SUSFS_SUS_MAP guard block into pagemap_read() in
fs/proc/task_mmu.c for kernels that use mmap_read_lock_killable / mmap_read_unlock
instead of the older down_read / up_read(&mm->mmap_sem) API.

The standard SUSFS patch targets the old API anchor and silently skips on
modern kernels (5.10+), leaving BIT_SUS_MAPS unguarded and failing the
patch-coverage verification check.

Usage:
    python3 fix_task_mmu_pagemap.py <kernel_root>

Example:
    python3 fix_task_mmu_pagemap.py $GITHUB_WORKSPACE/kernel_workspace/android-kernel
"""

import sys
import os

GUARD_BLOCK = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\t\tvma = find_vma(mm, start_vaddr);\n'
    '\t\tif (vma && vma->vm_file) {\n'
    '\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n'
    '\t\t\tif (unlikely(inode->i_state & BIT_SUS_MAPS) && susfs_is_current_proc_umounted()) {\n'
    '\t\t\t\tpm.show_pfn = false;\n'
    '\t\t\t\tpm.buffer->pme = 0;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '#endif\n'
)

def fix_task_mmu(kernel_root):
    filepath = os.path.join(kernel_root, 'fs', 'proc', 'task_mmu.c')

    if not os.path.exists(filepath):
        print(f'  [SKIP] {filepath} not found')
        return False

    with open(filepath) as f:
        src = f.read()

    # Already patched?
    if 'find_vma(mm, start_vaddr)' in src and 'BIT_SUS_MAPS' in src[src.index('pagemap_read'):]:
        # Check it's actually in pagemap_read, not just elsewhere in the file
        pr_start = src.index('pagemap_read')
        # Find the while loop's mmap_read_unlock + BIT_SUS_MAPS
        segment = src[pr_start:pr_start + 4000]
        if 'BIT_SUS_MAPS' in segment and 'find_vma(mm, start_vaddr)' in segment:
            print('  [SKIP] fs/proc/task_mmu.c: BIT_SUS_MAPS block already present in pagemap_read()')
            return True

    # Anchor: the unique two-line sequence inside pagemap_read()'s walk loop
    # for kernels using the modern mmap_read_lock_killable / mmap_read_unlock API
    ANCHOR_MODERN = '\t\tmmap_read_unlock(mm);\n\t\tstart_vaddr = end;'
    # Fallback anchor for older kernels using up_read / mmap_sem
    ANCHOR_LEGACY = '\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;'

    anchor = None
    if src.count(ANCHOR_MODERN) == 1:
        anchor = ANCHOR_MODERN
    elif src.count(ANCHOR_LEGACY) == 1:
        anchor = ANCHOR_LEGACY
    else:
        # Last resort: find pagemap_read and search within it
        pr_idx = src.find('static ssize_t pagemap_read(')
        if pr_idx == -1:
            print('  [FAIL] fs/proc/task_mmu.c: pagemap_read() not found — manual fix needed')
            return False
        # Find the closing brace of pagemap_read (next top-level function)
        segment_end = src.find('\nstatic ', pr_idx + 1)
        segment = src[pr_idx:segment_end] if segment_end != -1 else src[pr_idx:]
        for candidate in [
            '\t\tmmap_read_unlock(mm);\n\t\tstart_vaddr = end;',
            '\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;',
        ]:
            if candidate in segment:
                # Make sure it's unique in the full file context
                anchor = candidate
                break
        if anchor is None:
            print('  [FAIL] fs/proc/task_mmu.c: no known anchor found in pagemap_read() — manual fix needed')
            return False

    # Build replacement: insert guard block between unlock and start_vaddr = end
    unlock_line, startvaddr_line = anchor.split('\n', 1)
    replacement = unlock_line + '\n' + GUARD_BLOCK + startvaddr_line

    patched = src.replace(anchor, replacement, 1)

    with open(filepath, 'w') as f:
        f.write(patched)

    print('  [OK]   fs/proc/task_mmu.c: BIT_SUS_MAPS guard block injected into pagemap_read()')
    return True


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <kernel_root>')
        sys.exit(1)

    kernel_root = sys.argv[1]
    print('[task_mmu fix] Injecting BIT_SUS_MAPS block into fs/proc/task_mmu.c ...')
    ok = fix_task_mmu(kernel_root)
    sys.exit(0 if ok else 1)
    
