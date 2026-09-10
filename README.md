# agent-sandbox

A Singularity jail for evaluating **software-install agents** on the BU SCC: run an
agent against a real package tree with one version hidden, and see what it does.

Agent-agnostic — the agent is just a command string — so this directory can be lifted
into its own repository and pointed at anyone's agent.

---

## Install

Nothing to build. Clone it and run it — the only requirements are what the SCC already
provides (`bash`, `git`, `singularity`).

```bash
cd /projectnb/<your-project>          # or anywhere on a shared filesystem
git clone git@github.com:milechin/scc-agent-sandbox.git
```

Use `https://github.com/milechin/scc-agent-sandbox.git` if you have no SSH key on the
SCC.

**Where to clone it.** Any shared filesystem — a project disk or your home directory.
Not `/scratch` or `/tmp`: those are node-local, so a clone made on a login node is not
there when the job lands on a compute node.

**The clone is a mechanism, not a data directory.** Results go to `results/<case>-<stamp>/`
in the directory you *run from*, so run it from the agent you are testing and both the
results and the agent's instructions are found without any further configuration:

```bash
S=/projectnb/<your-project>/scc-agent-sandbox   # the clone, once
cd /projectnb/<your-project>/my-agent           # the agent under test
"$S/run-agent.sh" "$S/cases/fftw-3.3.8.env" --shell
```

`--out <dir>` overrides the location outright. Running from inside the clone still
works and puts results in `results/`, which is `.gitignored`.

**Do not put the scripts on `PATH`.** Absolute paths already work from anywhere, but a
**symlink** into `~/bin` breaks the harness outright: each script resolves its location
with `dirname "$BASH_SOURCE"`, which yields the symlink's directory, so the
`. "$HERE/jail.sh"` both scripts depend on finds nothing. A `PATH` entry pointing at
the clone itself is harmless, and saves little — the case file is still a path you have
to type.

---

## Quick start

Needs a compute node (`$NSLOTS` set) and nothing else installed.

```bash
cd scc-agent-sandbox
./verify-sandbox.sh cases/fftw-3.3.8.env     # prove the jail before trusting a run
./run-agent.sh      cases/fftw-3.3.8.env --shell
```

`run-agent.sh` runs the gate itself and **refuses to start** if it fails. You land at
a prompt inside the container, with a banner naming the paths:

```
  ── sandbox shell ─────────────────────────────────────────────
   image      scc-centos7-2023-06-01.simg
   blinded    /share/pkg.7/fftw/3.3.8 (masked, 0 entries)
   workspace  .../results/<stamp>/work   <- the only writable path
   state      .../results/<stamp>/homedir <- $HOME inside; survives exit
```

Everything under `results/<stamp>/` survives. Type `exit` to leave.

### Try it by hand

```bash
cat /etc/redhat-release          # CentOS Linux release 7.9.2009 — you are inside
module avail fftw                # 3.3.8 is ABSENT
module load fftw/3.3.8           # "The following module(s) are unknown"
ls -A /share/pkg.7/fftw/3.3.8    # empty — the mask
ls /share/pkg.7/fftw/2.1.5*      # prior versions still readable
touch /share/pkg.7/probe         # Read-only file system
cd <the workspace from the banner>   # the only place you can write
```

### Run an agent instead of a shell

```bash
export SANDBOX_AGENT_DIR=$HOME/.local      # binds the agent in; its bin/ goes on PATH
./run-agent.sh cases/fftw-3.3.8.env --shell            # then run it by hand
./run-agent.sh cases/fftw-3.3.8.env --agent-cmd '...'  # or scripted, captured
```

Scripted output lands in `$OUT/agent.stdout` / `agent.stderr`, with `run.meta` and
`argv.txt` recording exactly what ran.

---

## Writing a case

```bash
IMAGE=/share/singularity/images/files/scc-centos7-2023-06-01.simg
PKG_ROOT=/share/pkg.7      # a parameter: /share/pkg.8 with an alma8 image
PKG=fftw
VER=3.3.8                  # blinded
PRIOR_VER=2.1.5_intel-2018_openmpi-3.1.1
EXPECT_BIN=fftw-wisdom      # optional; recorded as produced_expect_bin in run.meta
BLIND_PATHS=(               # anything else to hide
  /path/to/another/answer/key
)
```

Run `./verify-sandbox.sh <case>` after writing one. It catches mistakes — a
`PRIOR_VER` that does not exist under `PKG_ROOT` fails as unreadable.

## Configuration

All optional, all environment variables.

| variable | effect |
|---|---|
| `SANDBOX_AGENT_DIR` | bound read-only so the agent exists inside; its `bin/` goes on `PATH` |
| `SANDBOX_RO_BINDS` | extra read-only binds, **one `src:dst` per line** |
| `SANDBOX_CAPTURE_AT` | only for an agent whose state dir is *not* under `$HOME` |
| `SANDBOX_VERBOSE=1` | restore Singularity's INFO/WARNING output when diagnosing |
| `SANDBOX_AUTOBIND_DIRS` | instruction directory names to look for in the launch directory; default `.claude`, empty to disable |
| `SANDBOX_AUTOBIND_FROM` | look there instead of the current directory |

`SANDBOX_RO_BINDS` is a **string, not an array** — bash arrays cannot be exported, so
an array set in your shell silently never arrives and the binds vanish without error.

**Where an agent finds its instructions — the automatic version.** Run from a directory
containing a `.claude/`, and each populated subdirectory of it is mounted read-only at
the matching place under the private `$HOME`:

```
./.claude/skills  ->  $HOME/.claude/skills   (read-only)
./.claude/agents  ->  $HOME/.claude/agents   (read-only)
```

So `cd <agent repo>; run-agent.sh <case> --shell` needs no configuration: the agent
finds its instructions at user scope from any working directory. The banner lists what
was picked up, and `run.meta` records it as `autobound=`.

Note what is deliberately *not* bound. **Subdirectories, never `.claude` itself** —
binding the parent read-only would leave the agent unable to write its own state, and
Claude Code writes settings, todos and transcripts into `~/.claude`, so it would fail
to start and the transcript you were collecting would never exist. **Loose files** such
as `settings.json` or `CLAUDE.md` are skipped too: they are project-scope, and binding
them at user scope changes their meaning. **Empty subdirectories** are skipped, as the
bind would provide nothing.

Set `SANDBOX_AUTOBIND_DIRS` to another name for a non-Claude agent, or to the empty
string to switch the mechanism off.

**The manual version.** The shell starts in `$HOME`, not your repo,
so a project-scope agent finds nothing until you `cd` — and every repo path is
read-only inside, so it would then be working somewhere it cannot write. Mounting the
instructions into the private home avoids both:

```bash
R=/path/to/your/repo
export SANDBOX_RO_BINDS="$R/.claude/skills:$HOME/.claude/skills
$R/.claude/agents:$HOME/.claude/agents
$R/.claude/references:$HOME/.claude/references"
```

They are then found from any cwd, leaving the writable workspace free to work in.
`$HOME/.claude` itself stays writable, so the agent can still write its own state.

## What the jail guarantees

| | |
|---|---|
| `/share` and the package tree | read-only — writes return `EROFS` |
| the target `<pkg>/<ver>` | contents masked; absent from `module avail` |
| sibling versions | readable, so prior art works |
| `$HOME` | private per-run directory, writable, isolated from the real one |
| this harness (`cases/`, `results/`) | masked — the answer key is not readable |
| the workspace | the only writable path |

### Inspecting mounts from inside

```bash
findmnt -O ro -rno TARGET                              # the read-only mounts
findmnt --target /share/pkg.7 -no TARGET,VFS-OPTIONS   # what governs ONE path
awk '$5 == "/share" {print $5, $6}' /proc/self/mountinfo   # no-tooling fallback
```

A plain listing shows **shadowed** mounts — `/usr1` is `ro` while `/usr1/scv/<you>` is
`rw` on top of it — so reading the first match reports the opposite of the truth;
`--target` resolves which mount governs a path. And `rw` does not promise you can
write: permissions are a separate gate. The ground truth is a write attempt, which is
why the gate probes with `touch`.

---

## How it works

Everything below is measured on `singularity-ce 4.5.0-1.el8`, and each point is why
some part of `jail.sh` looks the way it does.

**Bind order is the whole mechanism, and getting it wrong fails silently.** There is
no `--exclude`/`--unbind` flag, so hiding a child of a bound parent means *masking* —
binding an empty directory over it — and the mask must come **after** the parent.
Reversed, the parent overlays the mask and the target is fully readable, with no
error, warning or exit code. `verify-sandbox.sh` builds a deliberately mis-ordered
argv and asserts it **fails** to blind; a check that only ever sees the correct order
cannot tell a working mask from an unnecessary one.

**A bind is read-write by default.** `:ro` is what makes it read-only. The site
wrapper `scc-singularity` generates every bind read-write — right for interactive
work, wrong for a jail — so this borrows its bind list and `SINGULARITYENV_*`
handling and composes its own argv. (`--scc-preview` prints what the site expects.)

**Each mask needs its own directory, mode 755, outside the masked tree.** Singularity
materialises nested mount points *inside* the mask source before mounting. So a 555
source fails outright (`mkdirat: permission denied`), a source inside its own target
is a mount loop, and — the quiet one — a single shared source stops being empty once
anything is bound back inside a masked path, making every *other* mask show the stray
entry.

**`--contain` is not enough for `$HOME`.** It gives `$HOME` and `/tmp` fresh tmpfs
capped at 64 MB, but the site bind list includes `/usr1`…`/usr4` and home lives under
one of them, so that read-only bind lands on top and the real home reappears —
measured at 209 entries, readable, and not writable. A per-run directory bound over
`$HOME` *after* the site dirs fixes both isolation and writability, and `--workdir`
keeps the session directories off the 64 MB tmpfs.

**Masking the package dir also hides the module — if the Lmod cache is off.**
Modulefiles are symlinks into the package directory
(`module.7/libraries/fftw/3.3.8.lua -> pkg.7/fftw/3.3.8/modulefile.lua`), so masking
dangles the symlink and Lmod skips it on a live scan: the version reports as
*unknown* rather than existing-but-broken. A cached scan still lists it, so
`LMOD_IGNORE_CACHE=yes` is injected and the gate asserts *absent*, not merely broken.

**Your repo is swept in whether you bind it or not.** The site list includes
`/projectnb`, so a repo living there arrives read-only — which is how an agent finds
its skill files, and also how an answer key leaks. `jail.sh` masks its own directory
automatically (with this run's output bound back, so the agent sees its own run and
nothing else); anything else — a second harness, a notes archive, `.git` — is the
case author's job via `BLIND_PATHS`.

**The version directory entry stays visible**, only its contents are masked. Hiding
the entry as well is possible — mask `<pkg>/` and bind each sibling back — and was
built, then reverted: one extra bind per sibling (47 vs 26 for the worst package in
the corpus) and a second code path, to save an agent glancing at an empty directory.
The module system already reports the version as non-existent, so the normal question
gets a clean answer.

## What an image must provide

- Lmod, and a `MODULEPATH` matching its own OS generation. The `scc-centos7` image
  resolves to `/share/module.7`, which is why a `pkg.7` target makes the pilot a real
  test rather than a mock.
- A toolchain, if the agent is expected to build anything.

## Known limits

- **Container-in-container is unresolved.** Nested Singularity fails in the pilot with
  `libsubid.so.3: cannot open shared object file` — an alma8 binary against CentOS 7
  libraries, *not* the setuid restriction that blocks containers under `bwrap`. The
  host `starter-suid` is setuid, so retest on the alma8 image before concluding.
- **The pilot image is CentOS 7.** Good for exercising the jail and `pkg.7` installs;
  alma8 work needs the alma8 image. An agent whose references describe alma8 and
  `/share/pkg.8` will disagree with what it sees inside.
