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

## What blinding looks like from inside

```
ls /share/pkg.7/fftw/          ->  2.1.5_intel-2018_openmpi-3.1.1  3.3.8
ls -A /share/pkg.7/fftw/3.3.8  ->  (empty)
cat .../3.3.8/notes.txt        ->  No such file or directory
module avail fftw              ->  3.3.8 absent
module load fftw/3.3.8         ->  "The following module(s) are unknown"
```

The version **directory entry stays visible** while its contents are gone. Hiding the
entry as well is possible — mask `<pkg>/` and bind each sibling version back — and it
was built and working, then reverted on purpose: it costs one bind per sibling (47
instead of 26 for the worst package in the corpus) and adds a second code path, to
save an agent from glancing at an empty directory. An empty directory is
self-explanatory; the extra machinery was not worth it.

Note the asymmetry that makes this work: the module system says the version does
**not exist** (the modulefile is a symlink into the masked directory, so Lmod skips
it), while the filesystem shows an empty directory. An agent asking "is it installed?"
through the normal route — `module avail` — gets a clean no.

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

### Where do the skills come from? (cwd matters)

The shell starts in `$HOME` — the private per-run home — **not** in your repo. So an
agent that discovers instructions from its working directory will find none until you
`cd`. Two ways to handle it, and the second is usually better:

**Project scope — `cd` to the repo.** Works, and needs no setup:

```bash
cd /path/to/your/repo      # .claude/skills is readable here
claude
```

The catch: **every repo path is read-only inside the jail**, so the agent is working
in a directory it cannot write to. Fine for a read-only exercise, awkward for a real
install.

**User scope — mount the instructions into the private home.** Then they are found
from *any* cwd, and the agent can work in the writable workspace:

```bash
R=/path/to/your/repo
export SANDBOX_RO_BINDS="$R/.claude/skills:$HOME/.claude/skills
$R/.claude/agents:$HOME/.claude/agents
$R/.claude/references:$HOME/.claude/references"
./run-agent.sh cases/fftw-3.3.8.env --shell
```

Verified inside: `~/.claude/skills` → the skill, `~/.claude/agents` → the sub-agent,
`~/.claude/references` → 9 files, all read-only — while `~/.claude` itself stays
**writable**, so the agent can still write its own state alongside them.

**Output noise.** Singularity is run with `-s` (errors only). Two messages otherwise
fire on *every* run by construction — `INFO: Creating empty target directory for
nested bind` and `WARNING: path ... is already overridden`, the latter because the
private home deliberately overrides `--workdir`'s home. Suppressing them keeps a real
failure visible instead of buried; a genuine `FATAL` still prints under `-s`, verified.
Set `SANDBOX_VERBOSE=1` to get everything back when diagnosing.

`SANDBOX_RO_BINDS` is a **string**, one `src:dst` per line, not an array — bash arrays
cannot be exported, so an array set in your shell silently never reaches the script and
the binds vanish with no error.

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

## What the agent can see of your repo — and what it must not

The site bind list includes `/projectnb`, `/usr1`, `/project` and friends, so **any
repository living under one of them is swept into the container read-only**, whether
or not you bind it. That is usually what you want: it is how an agent finds its own
skill files and references.

It is also how an answer key leaks. Measured before the fix, from inside the jail:

```
.claude/skills:  scc-install-from-source        <- wanted
.claude/references: 9 files                     <- wanted
agent-sandbox/cases/fftw-3.3.8.env              <- THE ANSWER KEY, readable
tests/cases/*.env                               <- another harness's answer keys
```

Two layers handle it:

1. **The harness masks itself automatically.** `jail.sh` masks `SANDBOX_SELF_DIR`
   (the directory it lives in), so `cases/` and `results/` are always empty inside.
   Self-protecting on purpose — a `BLIND_PATHS` entry someone forgets to add is
   exactly the failure this prevents. `verify-sandbox.sh` asserts it.
   The run's own output directory is bound back afterwards when it lives under the
   harness (the default, `results/<case>-<stamp>/`), so the agent sees its own run and
   nothing else — no `cases/*.env`, no earlier results. Two constraints follow, and
   getting any of them wrong is a failure, and only the first is loud: the mask source
   must be **mode 755**, because Singularity materialises the nested mount point
   inside it before mounting (`mkdirat: permission denied` otherwise); it must live
   **outside** the masked tree, or it is a mount loop; and **each mask needs its own
   directory**. That last one is the quiet failure: with a single shared "empty"
   source, materialising the run directory's mount point inside it leaves `results/`
   there, and every *other* mask using the same source then shows that entry — so
   `ls -A /share/pkg.7/fftw/3.3.8` returned `results` while the gate reported the
   target blinded.

2. **Anything else is the case author's job**, via `BLIND_PATHS`. The prototype
   cannot know about a second harness, a notes archive or a scratch copy of the
   answer and still be liftable into another repo. The pilot case masks
   `install_agent/tests` for this reason.

After both: `tests/` and `agent-sandbox/` read as 0 entries, while `.claude/skills`
and the references stay visible.

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
