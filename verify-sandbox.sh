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

# Verify with $OUT under the harness directory -- the NESTED layout, where the run
# directory has to be bound back inside the harness mask. run-agent.sh now defaults
# $OUT to $PWD instead, which is the un-nested case and strictly easier: nothing is
# restored inside a mask, so nothing can leak out of one. Verifying the harder layout
# covers both, and it is still the live layout whenever anyone runs from the clone.
# Do not "align" this to $PWD -- that would stop exercising the mask-restore path.
#
# With $OUT in $TMPDIR instead, the harness
# mask never has the run directory bound back inside it, so the nested-mount-point
# behaviour that leaked into the target mask is never exercised and the gate passes
# while real runs leak. Checking a configuration nobody runs is how that got missed.
ROOT=${SANDBOX_ROOT:-$HERE/.verify.$$}
# WORK lives INSIDE OUT, exactly as run-agent.sh defaults it. As a sibling it sits
# under the masked harness with only OUT restored, so the workspace comes back
# read-only -- which the gate correctly failed on when the layout was first aligned.
OUT="$ROOT/out"; WORK="$OUT/work"
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

# If an instruction directory was auto-discovered in the launch directory, probe the
# FIRST one: it must be readable inside, and its parent must still be WRITABLE. The
# parent is the point -- binding the whole config directory read-only would stop an
# agent writing its own state, which is the mistake this design exists to avoid, and
# it would pass a check that only looked at readability.
AB0=${SANDBOX_AUTOBOUND[0]:-}
AB_PROBE=""
if [ -n "$AB0" ]; then
  AB_PROBE='
  t abread "$(ls -A "$HOME/'"$AB0"'" 2>/dev/null | wc -l)"
  touch "$HOME/'"${AB0%%/*}"'/.probe" 2>/dev/null && { t abparent rw; rm -f "$HOME/'"${AB0%%/*}"'/.probe"; } || t abparent ro'
fi

# The extra masks -- BLIND_PATHS from the case, SANDBOX_BLIND_EXTRA from the launcher --
# verified the same way as the target, by counting entries from inside. Without this
# they were the one part of the blinding that was asserted only by construction: a mask
# in the wrong section, or a path that resolves elsewhere inside the container, would
# read as configured while leaking. Sums the counts because any nonzero total is a leak
# and the per-path detail is one `ls` away under --shell.
EXTRA_PROBE=""
if [ "${#SANDBOX_BLIND_MASKED[@]}" -gt 0 ]; then
  EXTRA_PROBE='
  _xn=0
  for _xp in '"$(printf '%q ' "${SANDBOX_BLIND_MASKED[@]}")"'; do
    _xn=$((_xn + $(ls -A "$_xp" 2>/dev/null | wc -l)))
  done
  t extras "$_xn"'
fi

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
  t sgeroot "$(ls -A /usr/local/sge 2>/dev/null | wc -l)"
  t sgespool "$(ls -A /var/spool/sge 2>/dev/null | wc -l)"
  t qsubpath "$(command -v qsub >/dev/null 2>&1 && echo present || echo absent)"
  # Informational only, and deliberately a no-op submission: -verify makes qsub check
  # and print rather than queue anything. On the pilot this cannot even load its
  # libraries, which is why the CHECKS below assert the mask, not the outcome.
  t qsubrun "$(qsub -verify -b y /bin/true 2>&1 | tr "\n" " " | cut -c1-60)"'"$AB_PROBE$EXTRA_PROBE"'
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
if [ "${#SANDBOX_BLIND_MASKED[@]}" -gt 0 ]; then
  check "extra masks show 0 entries (${#SANDBOX_BLIND_MASKED[@]} paths)" 0 "$(g extras)"
fi
# Not a failure -- an absent path is legitimate on a host that lacks it -- but printed,
# because the alternative is a typo in BLIND_PATHS or SANDBOX_BLIND_EXTRA leaving an
# answer surface readable with nothing said anywhere.
if [ "${#SANDBOX_BLIND_SKIPPED[@]}" -gt 0 ]; then
  printf '  note  %-46s %s path(s)\n' "requested mask absent, NOT applied" "${#SANDBOX_BLIND_SKIPPED[@]}"
  for _s in "${SANDBOX_BLIND_SKIPPED[@]}"; do printf '          %s\n' "$_s"; done
fi
if [ -n "$PRIOR_VER" ]; then
  if [ "$(g prior)" -gt 0 ] 2>/dev/null; then
    printf '  ok    %-46s %s entries\n' "prior version $PRIOR_VER readable" "$(g prior)"; pass=$((pass+1))
  else
    printf '  FAIL  %-46s unreadable\n' "prior version $PRIOR_VER readable"; fail=$((fail+1))
  fi
fi

echo "  --- batch system (host escape) ---"
# A batch job runs on the HOST as the real user, outside every bind and every mask, so
# it is the one path that defeats both the write scope and the blinding at once. These
# checks assert the MASK is in place; they deliberately do not assert that submission
# fails, because on the CentOS 7 pilot the SGE clients cannot load their libraries
# either way and a check whose subject is already broken proves nothing. What they do
# catch is the mask going missing -- which is the thing that will matter on alma8.
if [ "$SANDBOX_BATCH_BLOCKED" = 1 ]; then
  check "SGE_ROOT masked (0 entries)"       0        "$(g sgeroot)"
  check "SGE spool masked (0 entries)"      0        "$(g sgespool)"
  # Recorded, not asserted. /usr/local/bin/qsub is a SYMLINK into the SGE root
  # (-> /usr/local/ogs-ge2011.11.p1/bin/qsub), so masking the root dangles every client
  # and they leave PATH as well -- "absent" here, and "command not found" below. That is
  # a consequence of the mask, not a second mechanism, which is why it is a note: on an
  # image where the clients are real files it would read "present" and the mask would
  # still be the thing doing the work.
  printf '  note  %-46s %s\n' "qsub on PATH" "$(g qsubpath)"
  printf '  note  %-46s %s\n' "qsub -verify says" "$(g qsubrun)"
else
  printf '  WARN  %-46s %s\n' "BATCH SUBMISSION ALLOWED" "SANDBOX_ALLOW_BATCH is set"
  printf '        %s\n' "This run is NOT contained and NOT blinded: a submitted job runs on" \
                         "the host as $USER, can write /share, and sees the unmasked target."
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

if [ -n "$AB0" ]; then
  echo "  --- agent instructions (auto-bound from $PWD) ---"
  if [ "$(g abread)" -gt 0 ] 2>/dev/null; then
    printf '  ok    %-46s %s entries\n' "\$HOME/$AB0 readable" "$(g abread)"; pass=$((pass+1))
  else
    printf '  FAIL  %-46s empty or missing\n' "\$HOME/$AB0 readable"; fail=$((fail+1))
  fi
  check "\$HOME/${AB0%%/*} still writable"   rw       "$(g abparent)"
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
