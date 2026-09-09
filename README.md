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

## Running an agent that lives under `$HOME`

```bash
export SANDBOX_AGENT_DIR=$HOME/.local/share/claude   # bound read-only so it exists inside
export SANDBOX_CAPTURE_AT=$HOME/.claude              # redirected to $OUT/home so state survives
./run-agent.sh cases/fftw-3.3.8.env --agent-cmd 'claude -p "..."'
```

Both are optional. An agent that needs neither still runs.

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
