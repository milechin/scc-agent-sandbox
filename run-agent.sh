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
OUT=${OUT:-$HERE/results/$(basename "$CASE" .env)-$STAMP}
WORK=${WORK:-$OUT/work}
mkdir -p "$WORK" "$OUT/workdir" "$OUT/home" "$OUT/homedir" || exit 1
EMPTY="$OUT/.empty"; mkdir -p "$EMPTY"; chmod 555 "$EMPTY"

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

{
  echo "case=$(basename "$CASE")"; echo "image=$IMAGE"
  echo "pkg_root=$PKG_ROOT"; echo "pkg=$PKG"; echo "ver=$VER"
  echo "prior_ver=${PRIOR_VER:-}"; echo "blinded=$SANDBOX_BLINDED"
  echo "host=$(hostname)"; echo "nslots=${NSLOTS:-unset}"
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
   capture    $OUT/home        <- bound at ${SANDBOX_CAPTURE_AT:-<unset>}
   read-only  /share, /usr/local, and the rest of the site bind list

   Everything outside the workspace is read-only. Type 'exit' to leave; the results
   directory and anything under capture/ survive.
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

chmod 755 "$EMPTY" 2>/dev/null; rmdir "$EMPTY" 2>/dev/null
echo
echo "== run complete (rc=$rc)"
echo "   results: $OUT"
[ "$SHELL_MODE" = 1 ] || echo "   stdout:  $OUT/agent.stdout"
echo "   capture: $OUT/home  (whatever the agent wrote to \$SANDBOX_CAPTURE_AT)"
exit $rc
