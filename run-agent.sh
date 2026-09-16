#!/bin/bash
# run-agent.sh — run an agent inside the sandbox and capture what it did.
#
#   ./run-agent.sh cases/fftw-3.3.8.env --shell                       # interactive
#   ./run-agent.sh cases/fftw-3.3.8.env --agent-cmd 'module avail fftw' # scripted
#   ./run-agent.sh cases/fftw-3.3.8.env --agent-cmd "$MY_AGENT" --out results/run1
#
# --shell drops you at a prompt INSIDE the verified jail, so you can drive an agent
# by hand and steer the exercise as it goes. Same mounts, same gate, same blinding
# as a scripted run -- only the command differs.
#
# AGENT-AGNOSTIC BY DESIGN. The agent is a command string. Nothing here knows about
# Claude, a particular skill, or a particular reference layout -- so this directory
# can be lifted into its own repo and pointed at anyone's agent.
#
# For an agent that ships as a binary under $HOME (Claude does), set:
#   SANDBOX_AGENT_DIR=~/.local/share/claude   # bound read-only so it exists inside
#   SANDBOX_CAPTURE_AT=$HOME/.claude          # its state dir, redirected to $OUT/home
# Both are optional; --contain hides the real $HOME either way.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=jail.sh
. "$HERE/jail.sh"

CASE=""; AGENT_CMD=""; OUT=""; WORK=""; SHELL_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent-cmd) AGENT_CMD=$2; shift 2 ;;
    --shell)     SHELL_MODE=1; shift ;;
    --out)       OUT=$2; shift 2 ;;
    --work)      WORK=$2; shift 2 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *)           CASE=$1; shift ;;
  esac
done
[ -n "$CASE" ] && [ -f "$CASE" ] || { echo "usage: $0 <case.env> [--shell | --agent-cmd '<cmd>']" >&2; exit 2; }
if [ "$SHELL_MODE" = 0 ] && [ -z "$AGENT_CMD" ]; then
  echo "give either --shell (interactive) or --agent-cmd '<cmd>' (scripted)" >&2; exit 2
fi
# shellcheck disable=SC1090
. "$CASE"

: "${IMAGE:?case must set IMAGE}" "${PKG:?case must set PKG}" "${VER:?case must set VER}"
PKG_ROOT=${PKG_ROOT:-/share/pkg.8}
BLIND_PATHS=("${BLIND_PATHS[@]:-}")

STAMP=$(date +%Y%m%d-%H%M%S)
# Results land in the CURRENT directory, not in the clone. The harness is a mechanism,
# not a data store: cloning it somewhere shared and collecting runs next to whatever
# you are actually working on keeps the two separate, and keeps `git status` clean.
# Run from inside the clone and you get the old behaviour, results/ being .gitignored.
#
# Either location is safe. jail.sh masks its own directory, and binds $OUT back only
# when $OUT is underneath it -- so a run directory in the clone is restored, and one
# outside is never masked in the first place. The workspace is bound explicitly in
# both cases, so a cwd outside the site bind list still works.
OUT=${OUT:-$PWD/results/$(basename "$CASE" .env)-$STAMP}
WORK=${WORK:-$OUT/work}
mkdir -p "$WORK" "$OUT/workdir" "$OUT/home" "$OUT/homedir" || exit 1
# Mask source: mode 755 and OUTSIDE the harness tree -- see jail.sh for why.
EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-mask.XXXXXX") || exit 1

# SANDBOX_HOME_COPIES: files COPIED into the private home before launch, "src:dst" per
# line, dst relative to the private home. The counterpart to SANDBOX_HOME_FILES, which
# binds -- and the difference matters:
#
#   bind  a credential. It stays in the real home, nothing is left in the run
#         directory, and a refreshed token writes back through.
#   copy  a config file the agent REWRITES. Claude Code rewrites ~/.claude.json on
#         almost every action, so a read-write bind would push sandbox state into the
#         real config (78 KB of project history, in the measured case), and its atomic
#         save would fail against a mount point anyway.
#
# Why an agent needs this at all: the private home is empty, so an interactive agent
# re-runs first-time setup on every run. For Claude Code that is the theme picker, the
# login prompt, and then the folder-trust dialog -- all of it state in ~/.claude.json,
# NOT in the credential file. `claude -p` skips all three, which is why a scripted run
# can work while an interactive one still asks to authenticate. tools/claude-home.sh
# builds a minimal seed; see the README.
HOME_COPIED=()
while IFS= read -r _cf; do
  [ -n "$_cf" ] || continue
  _src=${_cf%%:*}; _dst=${_cf#*:}; _dst=${_dst#/}
  [ -f "$_src" ] || { echo "SANDBOX_HOME_COPIES: no such file: $_src" >&2; continue; }
  mkdir -p "$(dirname "$OUT/homedir/$_dst")" || exit 1
  cp -p "$_src" "$OUT/homedir/$_dst" || exit 1   # -p keeps the mode; these are secrets
  HOME_COPIED+=( "$_dst" )
done <<< "${SANDBOX_HOME_COPIES:-}"

# GATE FIRST. A run against a broken jail is worse than no run: it can write to
# production, or read the answer while the report calls it blinded.
if ! "$HERE/verify-sandbox.sh" "$CASE" >"$OUT/verify.log" 2>&1; then
  echo "REFUSING TO RUN — sandbox verification failed. See $OUT/verify.log" >&2
  tail -20 "$OUT/verify.log" >&2
  exit 1
fi
echo "sandbox verified (see $OUT/verify.log)"

build_sandbox_args "$IMAGE" "$PKG_ROOT" "$PKG" "$VER" "$WORK" "$OUT" "$EMPTY" \
                   "${BLIND_PATHS[@]}"

# A requested mask whose source does not exist is skipped, so a typo in BLIND_PATHS or
# SANDBOX_BLIND_EXTRA would otherwise leave an answer surface readable with nothing
# said. Not fatal -- an absent path is legitimate on a host that lacks it -- but never
# silent.
if [ "${#SANDBOX_BLIND_SKIPPED[@]}" -gt 0 ]; then
  printf 'WARNING: requested mask not applied (path does not exist): %s\n' \
         "${SANDBOX_BLIND_SKIPPED[@]}" >&2
fi

# The batch escape hatch is loud on purpose: it is the only setting here that lets the
# agent reach outside the jail, and a run made with it set is not a blinded run.
if [ "$SANDBOX_BATCH_BLOCKED" = 0 ]; then
  echo "WARNING: SANDBOX_ALLOW_BATCH is set — batch submission is REACHABLE." >&2
  echo "         A submitted job runs on the host as ${USER:-$(id -un)}, outside every" >&2
  echo "         mask: it can write /share and read the blinded version." >&2
fi

{
  echo "case=$(basename "$CASE")"; echo "image=$IMAGE"
  echo "pkg_root=$PKG_ROOT"; echo "pkg=$PKG"; echo "ver=$VER"
  echo "prior_ver=${PRIOR_VER:-}"; echo "blinded=$SANDBOX_BLINDED"
  echo "host=$(hostname)"; echo "nslots=${NSLOTS:-unset}"
  echo "cwd=$PWD"; echo "autobound=${SANDBOX_AUTOBOUND[*]:-none}"
  # Paths only. Never the contents -- one of these is usually a credential.
  echo "home_files=${SANDBOX_HOME_FILES_BOUND[*]:-none}"
  echo "home_copies=${HOME_COPIED[*]:-none}"
  # Extra masks, applied and requested-but-absent. The second line is the one that
  # matters when a report is doubted: it says which answer surface was NOT hidden.
  echo "blind_masked=${SANDBOX_BLIND_MASKED[*]:-none}"
  echo "blind_skipped=${SANDBOX_BLIND_SKIPPED[*]:-none}"
  # 0 means a submitted job could run on the host, outside every mask. A report from
  # such a run cannot claim the agent was confined or blinded.
  echo "batch_blocked=$SANDBOX_BATCH_BLOCKED"
  echo "started=$(date -Is)"
  echo "mode=$([ "$SHELL_MODE" = 1 ] && echo interactive || echo scripted)"
  echo "agent_cmd=${AGENT_CMD:-<interactive shell>}"
} > "$OUT/run.meta"

# The exact argv, recorded. Bind ORDER is the blinding guarantee, so a run whose
# report is ever doubted can be checked against what actually ran.
printf '%q ' "${SANDBOX_ENV[@]}" "${SANDBOX_ARGS[@]}" > "$OUT/argv.txt"; echo >> "$OUT/argv.txt"

if [ "$SHELL_MODE" = 1 ]; then
  # Interactive. Deliberately NOT redirected -- the whole point is a live terminal, so
  # the agent can be driven by hand and the exercise steered as it goes.
  cat <<BANNER

  ── sandbox shell ──────────────────────────────────────────────────────────────
   image      $(basename "$IMAGE")
   blinded    $PKG_ROOT/$PKG/$VER $([ "$SANDBOX_BLINDED" = 1 ] && echo "(masked, 0 entries)" || echo "(NOT present — nothing masked)")
   workspace  $WORK            <- the only writable path
   state      $OUT/homedir     <- \$HOME inside; anything the agent writes there survives$([ -n "${SANDBOX_CAPTURE_AT:-}" ] && printf '\n   capture    %s <- bound at %s' "$OUT/home" "$SANDBOX_CAPTURE_AT")
   batch      $([ "$SANDBOX_BATCH_BLOCKED" = 1 ] && echo "blocked (SGE_ROOT masked, spool unbound)" || echo "REACHABLE — SANDBOX_ALLOW_BATCH is set; jobs escape the jail")
   read-only  /share, /usr/local, and the rest of the site bind list$([ "${#SANDBOX_AUTOBOUND[@]}" -gt 0 ] && printf '\n   agent dirs %s <- found in %s, mounted under $HOME' "${SANDBOX_AUTOBOUND[*]}" "$PWD")

   Everything outside the workspace is read-only. Type 'exit' to leave; the workspace
   and state directories above survive.
  ───────────────────────────────────────────────────────────────────────────────

BANNER
  env "${SANDBOX_ENV[@]}" "${SANDBOX_ARGS[@]}" /bin/bash -l
  rc=$?
else
  echo "running agent in $(basename "$IMAGE") ..."
  env "${SANDBOX_ENV[@]}" "${SANDBOX_ARGS[@]}" \
      /bin/bash -lc "$AGENT_CMD" > "$OUT/agent.stdout" 2> "$OUT/agent.stderr"
  rc=$?
fi

echo "finished=$(date -Is)" >> "$OUT/run.meta"
echo "exit_rc=$rc"          >> "$OUT/run.meta"

# exit_rc reports how the COMMAND exited, not whether the install happened. Record
# the artifact question separately so a clean exit is never mistaken for a result.
if [ -n "${EXPECT_BIN:-}" ]; then
  if find "$WORK" -name "$EXPECT_BIN" -print -quit 2>/dev/null | grep -q .; then
    echo "produced_expect_bin=1" >> "$OUT/run.meta"
  else
    echo "produced_expect_bin=0" >> "$OUT/run.meta"
    echo "WARNING: $EXPECT_BIN was never produced — exit_rc=$rc is not evidence of an install."
  fi
fi

rm -rf "$EMPTY" 2>/dev/null
echo
echo "== run complete (rc=$rc)"
echo "   results: $OUT"
[ "$SHELL_MODE" = 1 ] || echo "   stdout:  $OUT/agent.stdout"
echo "   state:   $OUT/homedir  (\$HOME inside the container)"
[ -n "${SANDBOX_CAPTURE_AT:-}" ] && echo "   capture: $OUT/home  (bound at $SANDBOX_CAPTURE_AT)"
exit $rc
