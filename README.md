# agent-sandbox

A Singularity jail for evaluating **software-install agents** on the BU SCC: run an
agent against a real package tree with one version hidden, and see what it does.

Self-contained on purpose — the agent is a command string, so this directory can be
lifted into its own repository and pointed at anyone's agent. Nothing here knows
about a particular skill, prompt or reference layout.

```bash
./verify-sandbox.sh cases/fftw-3.3.8.env          # gate: prove the jail first
./run-agent.sh      cases/fftw-3.3.8.env --agent-cmd '<your agent>'
```

`run-agent.sh` runs the gate itself and **refuses to start** if it fails.

## What the jail guarantees

| | |
|---|---|
| `/share` and the package tree | **read-only** — writes return `EROFS` |
| the target `<pkg>/<ver>` | **masked** — 0 entries, and absent from `module avail` |
| sibling versions | readable, so prior art still works |
| `$HOME`, `/tmp` | empty, isolated from the host's |
| the workspace | the only writable path |

## The four things that will bite you

Measured on `singularity-ce 4.5.0-1.el8`. Each is why the code looks the way it does.

**1. There is no `--exclude` flag, and bind order is the whole mechanism.**
Hiding a child of a bound parent is done by *masking* — binding an empty directory
over it — and the mask must come **after** the parent. Reversed, the parent overlays
the mask and the target is fully readable, with no error, no warning and no exit
code to notice. `verify-sandbox.sh` builds a deliberately mis-ordered argv and
asserts it **fails** to blind; a blinding check that only ever sees the correct order
cannot tell a working mask from an unnecessary one.

**2. A bind is read-write by default.** `-B /share` gives write access to `/share`.
The `:ro` suffix is what makes it read-only. The site wrapper
`/share/singularity/utils/scc-singularity` generates every bind read-write — correct
for interactive work, wrong for a test jail. This borrows its bind list and its
`SINGULARITYENV_*` handling and composes its own argv. Use `--scc-preview` to see
what the site expects.

**3. `--mount` supports only `type=bind`.** `type=tmpfs` is rejected outright, so the
mask needs a real empty directory on the host.

**4. `--contain` gives `$HOME` and `/tmp` a fresh tmpfs capped at 64 MB.** The image
itself stays read-only (container root is an `overlay`), so dotfiles written inside
live in RAM and vanish at exit. Two consequences: anything an agent writes to `$HOME`
— caches, shell state — hits `ENOSPC` at 64 MB and surfaces as an unrelated-looking
failure, so `--workdir` puts the session directories on real disk; and an agent
binary living under `$HOME` disappears, so it must be bound back in.

## Masking hides the module too — if the Lmod cache is off

Published modulefiles are **symlinks into the package directory**
(`/share/module.7/libraries/fftw/3.3.8.lua -> /share/pkg.7/fftw/3.3.8/modulefile.lua`).
Masking the package directory dangles that symlink, and Lmod skips dangling symlinks
on a live scan, so the version disappears cleanly:

```
module avail fftw        ->  fftw/2.1.5_intel-2018_openmpi-3.1.1
module load  fftw/3.3.8  ->  Lmod ... The following module(s) are unknown
```

That is the state you want: the version does not exist, so there is no phantom for
the agent to troubleshoot.

**But a cached scan still lists it.** With `~/.cache/lmod` present, `module avail`
shows the masked version and loading it fails with `Unable to load module because of
error` — the confusing case. `--contain` avoids it by giving the container no home
cache, and `LMOD_IGNORE_CACHE=yes` is injected as a belt-and-braces second guard.
`verify-sandbox.sh` asserts *absent*, not merely *broken*.

## Interactive: drive an agent by hand

`--shell` drops you at a prompt **inside the verified jail** — same mounts, same
blinding, same gate as a scripted run. Use it to run an exercise step by step, steer
as you go, or try a new agent before writing a case for it.

```bash
cd agent-sandbox
export SANDBOX_AGENT_DIR=$HOME/.local          # bound read-only; its bin/ goes on PATH
./run-agent.sh cases/fftw-3.3.8.env --shell
```

You get a banner naming the workspace, the capture directory and what is masked, then
a normal shell:

```
  ── sandbox shell ─────────────────────────────────────────────
   image      scc-centos7-2023-06-01.simg
   blinded    /share/pkg.7/fftw/3.3.8 (masked, 0 entries)
   workspace  .../work            <- the only writable path
```

A worked exercise, all verified to run in the pilot image:

```bash
cat /etc/redhat-release          # CentOS Linux release 7.9.2009 — you are inside
claude --version                 # 2.1.233 (Claude Code)

module avail fftw                # 2.1.5_intel-2018_openmpi-3.1.1 — 3.3.8 is ABSENT
module load fftw/3.3.8           # "The following module(s) are unknown"
ls -A /share/pkg.7/fftw/3.3.8    # empty: the mask
ls /share/pkg.7/fftw/2.1.5*      # prior art still readable

touch /share/pkg.7/probe         # Read-only file system
cd "$WORKSPACE_OR_YOUR_WORK_DIR" # the only writable path (printed in the banner)

claude                           # drive it interactively from here
exit                             # results and captured state survive
```

**What persists.** `$HOME` is a private per-run directory (`$OUT/homedir`) bound over
the real one, so anything the agent writes to `~/.claude`, `~/.config` or a dotfile is
there afterwards — no extra plumbing. The workspace and `$OUT` survive too. Nothing
you do inside can touch the real home or `/share`.

**Why a private `$HOME` and not just `--contain`:** the site bind list includes
`/usr1`…`/usr4`, and home lives under one of them, so that read-only bind lands *on
top of* `--contain`'s tmpfs and the real home reappears — measured at 209 entries with
`~/.claude` readable and `$HOME` not writable. Binding a per-run home after the site
dirs fixes both. `verify-sandbox.sh` checks for this explicitly (`$HOME is writable`,
`$HOME is NOT the real home`), because it is a silent regression otherwise.

**Getting the agent on `PATH`:** binding it in is not enough — `-e` gives the container
its own `PATH`, so a binary under `~/.local/bin` is present but "command not found".
Setting `SANDBOX_AGENT_DIR` handles it: if it has a `bin/`, that goes on `PATH` via
`SINGULARITYENV_PREPEND_PATH`. Otherwise just call the binary by absolute path.

## Scripted: one command, captured

```bash
export SANDBOX_AGENT_DIR=$HOME/.local
./run-agent.sh cases/fftw-3.3.8.env --agent-cmd 'claude -p "install fftw 3.3.8"'
```

Output lands in `$OUT/agent.stdout` / `agent.stderr`, with `run.meta` and `argv.txt`
recording exactly what ran. `SANDBOX_CAPTURE_AT` is only needed for an agent whose
state directory is *not* under `$HOME`; state under `$HOME` already persists.

## Case files

```bash
IMAGE=/share/singularity/images/files/scc-centos7-2023-06-01.simg
PKG_ROOT=/share/pkg.7      # the tree is a parameter: /share/pkg.8 with an alma8 image
PKG=fftw
VER=3.3.8                  # masked
PRIOR_VER=2.1.5_intel-2018_openmpi-3.1.1
BLIND_PATHS=()             # anything else to hide
```

`PKG_ROOT` is what lets the same code pilot on CentOS 7 today and target alma8 later
without a rewrite.

## What an image must provide

- Lmod, and a `MODULEPATH` matching its own OS generation. The `scc-centos7` image
  resolves to `/share/module.7`, which is why a `pkg.7` target makes it a real test
  rather than a mock.
- A toolchain, if the agent is expected to build anything.

## Known limits

- **Container-in-container is unresolved.** Running Singularity inside the pilot
  image fails with `libsubid.so.3: cannot open shared object file` — an alma8 binary
  against CentOS 7 libraries, i.e. an OS mismatch, *not* the setuid restriction that
  blocks containers under `bwrap`. The host `starter-suid` is setuid, so retest on
  the alma8 image before concluding either way.
- The pilot image is CentOS 7. Use it to exercise the jail machinery and `pkg.7`
  installs; alma8 work needs the alma8 image.
