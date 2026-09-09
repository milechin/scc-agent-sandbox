#!/bin/bash
# verify-sandbox.sh — prove the sandbox before trusting any run.
#
#   ./verify-sandbox.sh cases/fftw-3.3.8.env
#
# This gates everything. A jail whose mounts are wrong does not merely produce bad
# numbers -- it lets an agent write to production while reporting success, or leaves
# the answer readable while the report calls the run blinded.
#
# Read-only with respect to /share. Writes only inside the work/out directories it
# creates under the scratch root, and one probe file, which it removes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=jail.sh
. "$HERE/jail.sh"

CASE=${1:-}
[ -n "$CASE" ] || { echo "usage: $0 <case.env>" >&2; exit 2; }
[ -f "$CASE" ] || { echo "no such case file: $CASE" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CASE"

: "${IMAGE:?case must set IMAGE}" "${PKG:?case must set PKG}" "${VER:?case must set VER}"
PKG_ROOT=${PKG_ROOT:-/share/pkg.8}
PRIOR_VER=${PRIOR_VER:-}
BLIND_PATHS=("${BLIND_PATHS[@]:-}")

[ -f "$IMAGE" ] || { echo "image not found: $IMAGE" >&2; exit 2; }

ROOT=${SANDBOX_ROOT:-${TMPDIR:-/tmp}/agent-sandbox-verify.$$}
WORK="$ROOT/work"; OUT="$ROOT/out"
mkdir -p "$WORK" "$OUT/workdir" "$OUT/home" "$OUT/homedir" || exit 1
EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-mask.XXXXXX") || exit 1
trap 'rm -rf "$EMPTY" "$ROOT"' EXIT

pass=0 fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %-46s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %-46s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

echo "== sandbox verification: $PKG/$VER in $(basename "$IMAGE")"
echo "   tree=$PKG_ROOT  case=$(basename "$CASE")"

build_sandbox_args "$IMAGE" "$PKG_ROOT" "$PKG" "$VER" "$WORK" "$OUT" "$EMPTY" \
                   "${BLIND_PATHS[@]}"
[ "$SANDBOX_BLINDED" = 1 ] || echo "  note  $PKG/$VER not present under $PKG_ROOT; nothing to blind"

# Every probe in ONE container instance, so this tests the real composed mount set
# rather than several different partial ones.
out=$(env "${SANDBOX_ENV[@]}" "${SANDBOX_ARGS[@]}" /bin/bash -lc '
  t() { printf "%s=%s\n" "$1" "$2"; }
  t os "$( (cat /etc/redhat-release 2>/dev/null || echo unknown) | tr -d "\n" | cut -c1-24)"
  mkdir -p '"$PKG_ROOT"'/.probe 2>/dev/null && { t pkgroot rw; rmdir '"$PKG_ROOT"'/.probe; } || t pkgroot ro
  touch "'"$WORK"'/.probe" 2>/dev/null && { t work rw; rm -f "'"$WORK"'/.probe"; } || t work ro
  t blinded "$(ls -A "'"$PKG_ROOT"'/'"$PKG"'/'"$VER"'" 2>/dev/null | wc -l)"
  t prior "$(ls -A "'"$PKG_ROOT"'/'"$PKG"'/'"$PRIOR_VER"'" 2>/dev/null | wc -l)"
  t modulecmd "$(type -t module || echo none)"
  t listed "$(module avail '"$PKG"' 2>&1 | grep -c "'"$PKG"'/'"$VER"'\b")"
  t loaderr "$(module load '"$PKG"'/'"$VER"' 2>&1 | grep -qi "unknown" && echo unknown || echo other)"
  t homefs "$(findmnt -no FSTYPE "$HOME" 2>/dev/null || echo unknown)"
  touch "$HOME/.probe" 2>/dev/null && { t homerw rw; rm -f "$HOME/.probe"; } || t homerw ro
  t homecount "$(ls -A "$HOME" 2>/dev/null | wc -l)"
  t harness "$(ls -A "'"$HERE"'/cases" 2>/dev/null | wc -l)"
  getent hosts github.com >/dev/null 2>&1 && t dns ok || t dns down
' 2>&1)

g() { sed -n "s/^$1=//p" <<<"$out"; }

echo "  --- environment ---"
printf '  ok    %-46s %s\n' "container OS" "$(g os)"; pass=$((pass+1))
check "module command available"          function "$(g modulecmd)"
check "network reachable"                 ok       "$(g dns)"

echo "  --- write scope ---"
check "$PKG_ROOT is read-only"            ro       "$(g pkgroot)"
check "workspace is writable"             rw       "$(g work)"

echo "  --- blinding ---"
if [ "$SANDBOX_BLINDED" = 1 ]; then
  check "target $PKG/$VER shows 0 entries" 0       "$(g blinded)"
  # Absent, not merely broken. A cached Lmod scan still lists the masked version and
  # fails with "Unable to load module because of error" -- which is the state that
  # sends an agent troubleshooting a module that was never supposed to exist.
  check "target not listed by module avail" 0      "$(g listed)"
  check "loading it reports 'unknown'"      unknown "$(g loaderr)"
fi
if [ -n "$PRIOR_VER" ]; then
  if [ "$(g prior)" -gt 0 ] 2>/dev/null; then
    printf '  ok    %-46s %s entries\n' "prior version $PRIOR_VER readable" "$(g prior)"; pass=$((pass+1))
  else
    printf '  FAIL  %-46s unreadable\n' "prior version $PRIOR_VER readable"; fail=$((fail+1))
  fi
fi

echo "  --- home isolation ---"
# The site bind list contains /usr1../usr4, and $HOME lives under one of them, so a
# read-only site bind lands ON TOP of --contain's tmpfs and the real home reappears --
# measured at 209 entries, ~/.claude readable, $HOME not writable. A private home bound
# after the site dirs fixes it. These two checks are what catch a regression.
check "\$HOME is writable"                 rw       "$(g homerw)"
if [ "$(g homecount)" -le 4 ] 2>/dev/null; then
  printf '  ok    %-46s %s entries (isolated)\n' "\$HOME is NOT the real home" "$(g homecount)"; pass=$((pass+1))
else
  printf '  FAIL  %-46s %s entries — the real home is exposed\n' "\$HOME is NOT the real home" "$(g homecount)"; fail=$((fail+1))
fi

# The site binds sweep in whatever filesystem the harness lives on, so cases/*.env --
# the answer key -- is readable unless the harness masks itself.
# cases/*.env is the answer key. Checked specifically rather than the whole harness
# dir, because a run whose output lives under results/ has that one subdirectory bound
# back -- the agent sees its own run and nothing else.
check "answer keys masked (cases/ empty)" 0        "$(g harness)"

echo "  --- session storage ---"
# --contain alone gives a 64 MB tmpfs here; --workdir should move it to real disk.
if [ "$(g homefs)" = "tmpfs" ]; then
  printf '  FAIL  %-46s %s (--workdir not applied; 64 MB cap)\n' "\$HOME is on real disk" "$(g homefs)"
  fail=$((fail+1))
else
  printf '  ok    %-46s %s\n' "\$HOME is on real disk" "$(g homefs)"; pass=$((pass+1))
fi

# ---- the ordering check ---------------------------------------------------------
# The mask only works because it is bound AFTER the parent. Reversed, the parent
# overlays it and the target is fully readable -- silently. Assert that the wrong
# order really does fail, so a passing blinding check above means the ORDER is doing
# the work, not that the target happened to be empty.
if [ "$SANDBOX_BLINDED" = 1 ]; then
  echo "  --- ordering (negative control) ---"
  build_sandbox_args_misordered "$IMAGE" "$PKG_ROOT" "$PKG" "$VER" "$WORK" "$OUT" "$EMPTY"
  mis=$(env "${SANDBOX_ENV[@]}" "${MISORDERED_ARGS[@]}" /bin/bash -lc \
        "ls -A $PKG_ROOT/$PKG/$VER 2>/dev/null | wc -l" 2>/dev/null)
  if [ "${mis:-0}" -gt 0 ] 2>/dev/null; then
    printf '  ok    %-46s %s entries leak, as expected\n' "mis-ordered binds DO fail to blind" "$mis"
    pass=$((pass+1))
  else
    printf '  FAIL  %-46s %s\n' "mis-ordered binds DO fail to blind" \
      "got 0 entries — the mask is not what is hiding the target; this check proves nothing"
    fail=$((fail+1))
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "sandbox OK — $pass checks passed. Safe to run an agent."
else
  echo "SANDBOX BROKEN — $fail of $((pass+fail)) checks failed. Do NOT run an agent."
fi
exit $(( fail > 0 ))
