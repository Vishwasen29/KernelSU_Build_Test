#!/usr/bin/env bash
# patches/ksun-susfs-backport.sh
#
# Runs inside the Atest workflow, AFTER Singularity has been overlaid onto the
# LineageOS tree (kernel-side SUSFS, hooks, defconfig) and AFTER
#   curl .../next/kernel/setup.sh | bash -s legacy
# has put the latest KernelSU-Next legacy into <kernel>/KernelSU-Next.
#
# What it does:
#   1. Moves KernelSU-Next to the tip of upstream `legacy` (full history).
#   2. Fetches anomalist's KernelSU-Next fork at the pinned commit.
#   3. Picks the upstream ref that is the fork's closest ancestor (fewest
#      fork-only commits) and diffs base..fork for kernel/ and uapi/.
#   4. Keeps only SUSFS hunks (whole file if it is new), applies them onto
#      legacy with a 3-way merge. Any conflict fails the job right away.
#   5. Verifies the kernel-side call sites and defconfig still resolve
#      against the resulting KernelSU-Next, so breakage shows up here and
#      not 40 minutes into the compile.
#
# Usage:  ksun-susfs-backport.sh [kernel_dir]        (default: $PWD)
# Env:    KSUN_URL / KSUN_SHA   fork + pinned commit (from anomalist's submodule)
#         FORK_BRANCH           fallback if KSUN_SHA unset (default selinux-hide-4.19)
#         UPSTREAM_BRANCH       default legacy
#         KEEP_ALL=1            apply the WHOLE fork delta, not just susfs hunks
#         KEEP_REGEX            extra hunk-keep regex (ORed with susfs)
#         DEFCONFIG             default arch/arm64/configs/vendor/kona-perf_defconfig
#         STRICT=0              downgrade symbol/Kconfig failures to warnings
set -euo pipefail

KERNEL_DIR="$(realpath "${1:-$PWD}")"
KSUN_DIR="$KERNEL_DIR/KernelSU-Next"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/KernelSU-Next/KernelSU-Next.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-legacy}"
FORK_URL="${KSUN_URL:-https://github.com/The-Anomalist/KernelSU-Next.git}"
FORK_SHA="${KSUN_SHA:-}"
FORK_BRANCH="${FORK_BRANCH:-selinux-hide-4.19}"
KEEP_ALL="${KEEP_ALL:-0}"
KEEP_REGEX="${KEEP_REGEX:-}"
DEFCONFIG="${DEFCONFIG:-arch/arm64/configs/vendor/kona-perf_defconfig}"
STRICT="${STRICT:-1}"
WORK="$KERNEL_DIR/.ksun-susfs-work"

log()  { printf '[ksun-susfs] %s\n' "$*"; }
warn() { printf '[ksun-susfs] WARNING: %s\n' "$*" >&2; }
die()  { printf '[ksun-susfs] ERROR: %s\n' "$*" >&2; exit 1; }
soft() { if [ "$STRICT" = 1 ]; then die "$*"; else warn "$*"; fi; }
ksg()  { git -C "$KSUN_DIR" "$@"; }

[ -d "$KSUN_DIR/.git" ] || die "$KSUN_DIR is not a git checkout; run setup.sh (legacy) first"
[ -e "$KERNEL_DIR/drivers/kernelsu" ] || die "drivers/kernelsu missing; setup.sh did not wire the driver"
rm -rf "$WORK"; mkdir -p "$WORK"

# ---- 1. latest upstream legacy, full history -------------------------------
log "Updating KernelSU-Next to latest $UPSTREAM_BRANCH"
git -C "$KSUN_DIR" remote get-url origin >/dev/null 2>&1 || ksg remote add origin "$UPSTREAM_URL"
if [ "$(ksg rev-parse --is-shallow-repository)" = true ]; then
  ksg fetch --quiet --unshallow origin
fi
ksg fetch --quiet origin "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/origin/$UPSTREAM_BRANCH"
for b in next dev; do   # extra base candidates, optional
  ksg fetch --quiet origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
done
ksg checkout --quiet -f -B ksun-susfs "origin/$UPSTREAM_BRANCH"
UP_HEAD="$(ksg rev-parse HEAD)"
log "legacy tip: $UP_HEAD"

# ---- 2. anomalist fork ------------------------------------------------------
log "Fetching fork $FORK_URL @ ${FORK_SHA:-branch $FORK_BRANCH}"
ksg remote remove fork 2>/dev/null || true
ksg remote add fork "$FORK_URL"
if [ -n "$FORK_SHA" ]; then
  ksg fetch --quiet fork "+$FORK_SHA:refs/ksun/fork" \
    || die "cannot fetch fork commit $FORK_SHA"
else
  ksg fetch --quiet fork "+refs/heads/$FORK_BRANCH:refs/ksun/fork" \
    || die "cannot fetch fork branch $FORK_BRANCH"
fi
FORK_TIP="$(ksg rev-parse refs/ksun/fork)"

# ---- 3. pick base -----------------------------------------------------------
BEST_BASE=""; BEST_N=999999999; BEST_REF=""
for ref in "origin/$UPSTREAM_BRANCH" origin/next origin/dev; do
  ksg rev-parse --verify --quiet "refs/remotes/$ref" >/dev/null || continue
  mb="$(ksg merge-base refs/ksun/fork "refs/remotes/$ref" 2>/dev/null || true)"
  [ -n "$mb" ] || continue
  n="$(ksg rev-list --count "$mb..refs/ksun/fork")"
  log "  base candidate $ref: merge-base ${mb:0:10}, $n fork-only commits"
  if [ "$n" -lt "$BEST_N" ]; then BEST_N="$n"; BEST_BASE="$mb"; BEST_REF="$ref"; fi
done
[ -n "$BEST_BASE" ] || die "fork shares no history with upstream; cannot diff"
log "Using base ${BEST_BASE:0:10} (from $BEST_REF), fork tip ${FORK_TIP:0:10}"

# ---- 4. build filtered delta ------------------------------------------------
ksg diff --no-color --no-renames --no-ext-diff "$BEST_BASE" refs/ksun/fork -- kernel uapi \
  > "$WORK/fork-full.diff"
[ -s "$WORK/fork-full.diff" ] || die "empty fork delta; wrong base or pinned commit?"

python3 - "$WORK/fork-full.diff" "$WORK/fork-susfs.diff" "$KEEP_ALL" "$KEEP_REGEX" <<'PY'
import re, sys
src, dst, keep_all, extra = sys.argv[1:5]
pat = re.compile(r'susfs' + (('|' + extra) if extra else ''), re.I)
text = open(src, errors='surrogateescape').read()
blocks = re.split(r'(?m)^(?=diff --git )', text)
out, names = [], []
for b in blocks:
    if not b.startswith('diff --git'):
        continue
    if 'GIT binary patch' in b or re.search(r'(?m)^Binary files ', b):
        continue
    parts = re.split(r'(?m)^(?=@@ )', b)
    head, hunks = parts[0], parts[1:]
    fname = re.match(r'diff --git a/(\S+)', head).group(1)
    is_new = re.search(r'(?m)^new file mode', head) is not None
    is_del = re.search(r'(?m)^deleted file mode', head) is not None
    if keep_all == '1':
        keep = hunks
    elif is_new and (pat.search(fname) or pat.search(b)):
        keep = hunks
    elif is_del:
        keep = []
    else:
        keep = [h for h in hunks if pat.search(h)]
    if keep:
        out.append(head + ''.join(keep))
        names.append(f"{fname} ({len(keep)}/{len(hunks)} hunks)")
open(dst, 'w', errors='surrogateescape').write(''.join(out))
print('kept:'); [print('  ' + n) for n in names]
PY
[ -s "$WORK/fork-susfs.diff" ] || die "no SUSFS hunks found in fork delta"

# ---- 5. apply onto latest legacy -------------------------------------------
log "Applying delta onto legacy (3-way)"
if ! ksg apply --3way --whitespace=nowarn "$WORK/fork-susfs.diff" 2> "$WORK/apply.err"; then
  cat "$WORK/apply.err" >&2
  mapfile -t CONFLICTS < <(ksg diff --name-only --diff-filter=U)
  [ "${#CONFLICTS[@]}" -gt 0 ] || die "git apply failed without conflicts; see above"
  # Kconfig/Makefile conflicts are almost always two adjacent additions
  # (upstream and fork both appended). Keep both sides for those only.
  for f in "${CONFLICTS[@]}"; do
    case "$f" in
      */Kconfig|*/Makefile|*/Kbuild|Kconfig|Makefile)
        warn "union-merging adjacent additions in $f"
        ksg show ":1:$f" > "$WORK/m.base" 2>/dev/null || : > "$WORK/m.base"
        ksg show ":2:$f" > "$WORK/m.ours"
        ksg show ":3:$f" > "$WORK/m.theirs"
        git merge-file --union -p "$WORK/m.ours" "$WORK/m.base" "$WORK/m.theirs" > "$KSUN_DIR/$f" || true
        ksg add -- "$f";;
      *) echo "unresolvable conflict in $f" >&2; STUCK=1;;
    esac
  done
  [ -z "${STUCK:-}" ] || die "SUSFS delta does not apply cleanly on legacy@${UP_HEAD:0:10}. Inspect $WORK/fork-susfs.diff"
fi
cat "$WORK/apply.err" || true
if ksg grep -nE '^(<<<<<<<|>>>>>>>) ' -- kernel uapi >/dev/null 2>&1; then
  die "conflict markers left in KernelSU-Next"
fi

# ---- 6. sanity checks -------------------------------------------------------
KS="$KSUN_DIR/kernel"
cd "$KERNEL_DIR"

# 6a. every ksu_*/susfs_* function called from the kernel must exist somewhere
CALLERS=(fs kernel drivers/input security include/linux arch/arm64/kernel)
SUSFS_SRC=()
for f in fs/susfs.c include/linux/susfs*.h; do [ -e "$f" ] && SUSFS_SRC+=("$f"); done

mapfile -t CALLS < <(grep -rhoE --include='*.c' --include='*.h' '\b(ksu|susfs)_[a-z0-9_]+[[:space:]]*\(' \
    "${CALLERS[@]}" 2>/dev/null | sed -E 's/[[:space:]]*\($//' | sort -u)
missing=0
for s in "${CALLS[@]}"; do
  if grep -rqwE "$s" "$KS" "${SUSFS_SRC[@]}" 2>/dev/null; then continue; fi
  # defined elsewhere in the tree? (return-type + name + '(' at line start)
  if grep -rEq --include='*.c' --include='*.h' "^[a-zA-Z_][a-zA-Z0-9_ \*]*[[:space:]\*]$s[[:space:]]*\(" \
       "${CALLERS[@]}" 2>/dev/null; then continue; fi
  warn "unresolved symbol referenced by kernel: $s"; missing=$((missing+1))
done
[ "$missing" -eq 0 ] || soft "$missing kernel-side KSU/SUSFS symbols have no definition (hook API mismatch with legacy)"

# 6b. defconfig CONFIG_KSU* must be real symbols in the merged Kconfig
if [ -f "$DEFCONFIG" ]; then
  mapfile -t CFGS < <(grep -oE '^CONFIG_KSU[A-Z0-9_]*' "$DEFCONFIG" | sed 's/^CONFIG_//' | sort -u)
  for c in "${CFGS[@]}"; do
    if ! grep -rqE --include=Kconfig "^[[:space:]]*config $c[[:space:]]*$" "$KS"; then
      case "$c" in
        KSU_SUSFS*) soft "defconfig sets CONFIG_$c but merged KernelSU-Next Kconfig has no such symbol (SUSFS would silently be off)";;
        *)          warn "defconfig sets CONFIG_$c which is not defined by KernelSU-Next Kconfig";;
      esac
    fi
  done
  grep -q '^CONFIG_KSU_SUSFS=y' "$DEFCONFIG" || warn "CONFIG_KSU_SUSFS=y not in $DEFCONFIG"
  # SUSFS symbols defined by Kconfig but never set in defconfig (info only)
  grep -rhoE --include=Kconfig '^[[:space:]]*config KSU_SUSFS[A-Z0-9_]*' "$KS" | awk '{print $2}' | sort -u |
    while read -r c; do grep -q "^CONFIG_$c=" "$DEFCONFIG" || log "info: $c defined but not set in defconfig"; done
else
  warn "$DEFCONFIG not found; skipped Kconfig check"
fi

log "OK. KernelSU-Next = legacy@${UP_HEAD:0:10} + susfs delta from ${FORK_TIP:0:10} (uncommitted, so version count stays upstream's)"
log "Artifacts for debugging: $WORK/fork-full.diff  $WORK/fork-susfs.diff"
