#!/bin/bash
# claude-home.sh — build a minimal ~/.claude.json for a sandbox run.
#
#   tools/claude-home.sh <out.json> [trusted-dir ...]
#
# CLAUDE-SPECIFIC, AND DELIBERATELY OUTSIDE THE CORE. jail.sh, run-agent.sh and
# verify-sandbox.sh know nothing about any agent; this is a convenience for the agent
# this harness is mostly pointed at. Nothing here is required to run the sandbox.
#
# THE PROBLEM IT SOLVES. The sandbox gives the agent an empty $HOME, so Claude Code
# re-runs first-time setup on every run: the theme picker, then the login prompt, then
# the folder-trust dialog. None of that is the credential -- all three are state in
# ~/.claude.json, which is why binding .credentials.json alone still lands you at a
# login screen. (`claude -p` skips all three, so scripted runs never showed it.)
#
# WHY NOT JUST COPY ~/.claude.json. It is large and personal -- 78 KB and 17 project
# paths on the machine this was written for -- and it would put your whole project
# history, and every directory you have ever trusted, into a run directory that gets
# copied around. This copies four keys and the trust flags you ask for, nothing else.
set -uo pipefail

OUT=${1:-}
[ -n "$OUT" ] || { sed -n '2,4p' "$0" >&2; exit 2; }
shift
SRC=${CLAUDE_CONFIG_JSON:-$HOME/.claude.json}
[ -f "$SRC" ] || { echo "no $SRC -- run claude once on the host first" >&2; exit 1; }

# Trust the container's $HOME by default: that is where the sandbox shell starts, so
# it is where claude is launched from unless you cd. Pass the workspace too if you
# intend to work there -- with `run-agent.sh --work <dir>` you know it in advance.
DIRS=( "$@" ); [ "${#DIRS[@]}" -gt 0 ] || DIRS=( "$HOME" )

python3 - "$SRC" "$OUT" "${DIRS[@]}" <<'PY'
import json, os, sys
src, out, dirs = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(src))
# The four keys that mark setup as done. Without hasCompletedOnboarding the theme
# picker runs; without oauthAccount/userID the login prompt runs even with a valid
# credential file present.
keys = ["userID", "hasCompletedOnboarding", "lastOnboardingVersion", "oauthAccount"]
seed = {k: d[k] for k in keys if k in d}
missing = [k for k in keys if k not in d]
seed["projects"] = {p: {"hasTrustDialogAccepted": True} for p in dirs}
os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
with open(out, "w") as f:
    json.dump(seed, f, indent=2)
os.chmod(out, 0o600)
print(f"wrote {out} ({os.path.getsize(out)} bytes), trusting: {' '.join(dirs)}")
if missing:
    print(f"WARNING: absent from {src}: {', '.join(missing)} — "
          "the agent may still prompt. Run claude once on the host.", file=sys.stderr)
PY
