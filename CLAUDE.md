# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# scc-agent-sandbox

A Singularity jail for evaluating **software-install agents** on the BU SCC. Run an
agent against a real package tree with one version hidden and see what it does.

`README.md` documents the behaviour and every gotcha, all measured rather than
assumed. This file carries what the README does not: how to work on it, what is
still open, and what was tried and rejected.

## Origin

Prototyped inside <https://github.com/bu-rcs/scc-agents> (branch
`install_software_v2`, directory `agent-sandbox/`) and extracted with
`git filter-branch --subdirectory-filter`, so the first 11 commits predate this repo
and reference that context. That repo keeps its own **bwrap**-based harness under
`tests/`, which is specific to one skill and its references; this one is deliberately
agent-agnostic and was never meant to replace it.

## Architecture

Three bash files and a case file. No build, no dependency install, no test framework —
everything runs from a compute node with `$NSLOTS` set.

- **`jail.sh`** — the only place that composes an argv. Sourced (not executed) by both
  other scripts, so verification and running use literally the same mounts; if they
  diverge, the gate stops proving anything about the run. `build_sandbox_args` fills
  three globals: `SANDBOX_ARGS` (the `singularity exec …` argv, image last),
  `SANDBOX_ENV` (`SINGULARITYENV_*` pairs passed via `env`), `SANDBOX_BLINDED`.
  Its second function, `build_sandbox_args_misordered`, exists solely as the gate's
  negative control.
- **`verify-sandbox.sh`** — the gate. Runs every probe inside *one* container instance
  so it tests the real composed mount set, then re-runs the mis-ordered argv and
  asserts the target **leaks**. Exit non-zero means do not run an agent.
- **`run-agent.sh`** — invokes the gate first and refuses to start if it fails, then
  execs the same jail with either `/bin/bash -l` (`--shell`) or `-lc "$AGENT_CMD"`.
- **`cases/*.env`** — sourced shell: `IMAGE`, `PKG_ROOT`, `PKG`, `VER`, `PRIOR_VER`,
  optional `EXPECT_BIN` and `BLIND_PATHS=()`.

**Bind order is the entire security model.** Singularity has no `--exclude`; hiding a
child of a bound parent means binding an empty directory over it, and the mask must be
appended *after* the parent or it silently does nothing. Hence the section numbering in
`build_sandbox_args`: 1 isolate → 2 read-only site dirs → 3 private `$HOME` over them →
4 workspace → 5 scratch → 6 agent runtime and `SANDBOX_RO_BINDS` → **7 masks, last**.
Any new bind must be placed by asking whether it should shadow or be shadowed.

Two consequences that are easy to break:

- Each mask gets its **own** directory under `$emptydir` (`_mask` numbers them). A
  shared source stops being empty as soon as anything is bound back inside a masked
  path, and the stray entry then appears in every other mask.
- The harness masks **itself** (`SANDBOX_SELF_DIR`) because the site bind list sweeps
  in `/projectnb`, `/usr1`, `/project`; the current run's `$OUT` is bound back on top
  so the agent sees its own run and no other. `$emptydir` must therefore be mode 755
  and live outside the harness tree.

Section 6 also **auto-discovers** an agent's instruction directory in the launch
directory (`SANDBOX_AUTOBIND_DIRS`, default `.claude`) and binds each populated
subdirectory under the private `$HOME`. Subdirectories only: binding the config parent
read-only would stop the agent writing its own state, which is the transcript you were
trying to collect. Keeping the mechanism generic and the agent name in a default value
is what keeps it inside the agent-agnostic rule — do not grow agent-specific logic
around it.

`SANDBOX_HOME_FILES` binds individual files into the private home, opt-in with no
default because the case it exists for is a credential. Bound rather than copied so no
live token lands in a run directory; read-write so token refresh works, which is also
the only write path from the jail back into the real home. Measured: an in-place write
to a bind-mounted file reaches the host, an atomic rename over it does not.

`$OUT` defaults to `$PWD/results/<case>-<stamp>/`, not the clone: the harness is a
mechanism, not a data store. The gate still verifies with `$OUT` under the harness
directory on purpose — that is the nested layout where the run directory is restored
inside the harness mask, strictly harder than the un-nested default and still live
whenever anyone runs from the clone. Do not "align" it to `$PWD`.

The run directory holds `work/` (the only writable path), `homedir/` (`$HOME`
inside), `run.meta`, `argv.txt` (the exact argv, for auditing a disputed run),
`verify.log`, and `agent.stdout`/`.stderr` for scripted runs.

## Commands

```bash
./verify-sandbox.sh cases/fftw-3.3.8.env                  # the gate — after ANY jail.sh change
./run-agent.sh      cases/fftw-3.3.8.env --shell          # interactive, inside the jail
./run-agent.sh      cases/fftw-3.3.8.env --agent-cmd '…'  # scripted; output captured to $OUT
SANDBOX_VERBOSE=1 ./verify-sandbox.sh cases/…             # restore Singularity INFO/WARNING
shellcheck jail.sh run-agent.sh verify-sandbox.sh         # sources carry shellcheck directives; not installed by default
```

There is no single-test runner: the gate is one script and prints per-check `ok`/`FAIL`
lines. To iterate on one check, edit the probe block in `verify-sandbox.sh` — all probes
share one container invocation on purpose.

## Working agreements

These came out of building it, usually the hard way.

- **Measure, then write.** Every claim in the README was verified by running it. The
  ones that were "obvious" are exactly the ones that turned out wrong: `--contain`
  looked like it isolated `$HOME` (it did not, `/usr1` was bound over it); nested
  Singularity looked like a setuid problem (it was a missing library); a shared
  "empty" mask directory looked empty (it was not, once a nested mount point was
  materialised in it).
- **A gate that cannot fail proves nothing.** `verify-sandbox.sh` builds a
  deliberately mis-ordered argv and asserts it *fails* to blind. Any new check should
  be able to answer "would this fire if the thing it guards broke?" — twice a check
  passed while the failure it existed to catch was live.
- **Test the default configuration.** Two bugs shipped because testing always passed
  `--out` somewhere convenient, so the default path — the one everyone actually uses —
  was the single configuration never exercised. The gate now runs in the same layout
  as a real run for this reason.
- **Stay agent-agnostic.** The agent is a command string. No knowledge of a particular
  skill, prompt, or reference layout belongs here, or the repo stops being liftable
  to someone else's agent. Anything installation-specific goes in a case file.
- **Corrections belong in the file, not just the fix.** Where an earlier claim was
  wrong, the file says so (see the correction note in `cases/fftw-3.3.8.env`), so
  nobody re-derives a conclusion that was already tested and discarded.

## Open items

1. **The alma8 image.** The pilot is CentOS 7, which exercises the jail machinery
   honestly but cannot test an agent whose references describe alma8 and
   `/share/pkg.8`. When that image exists, a case only needs `IMAGE=` and
   `PKG_ROOT=/share/pkg.8` changed.
2. **Container-in-container is unresolved, not disproven.** Nested Singularity failed
   in the pilot with `libsubid.so.3: cannot open shared object file` — an alma8 binary
   against CentOS 7 libraries, *not* the setuid restriction that blocks containers
   under bwrap. `starter-suid` is setuid on the host. Retest on the alma8 image before
   concluding either way; it is the main capability this backend might add.
3. **`SANDBOX_RO_BINDS` is unchecked.** Optional and per-agent, so a typo in a source
   path fails silently. An assertion that each `src` exists would be cheap.
4. **BU-specific by construction.** The site bind list, `/share/pkg.N`, and the image
   path are baked into `jail.sh`. Fine for RCS; if outside contributors are wanted,
   those want to become configuration — easier before people fork it.

## Decided and reverted — do not relitigate without new information

- **Hiding the version directory *entry*** (not just its contents) was built, worked,
  and was reverted deliberately. It costs one bind per sibling version — 47 versus 26
  for the worst package in the corpus — and adds a second code path, to stop an agent
  glancing at an empty directory. The module system already reports the version as
  non-existent, so the normal question gets a clean answer. `jail.sh` keeps a comment
  where the code would go.
- **Calling `scc-singularity` directly** was rejected: every bind it generates is
  read-write, which is right for interactive work and wrong for a jail. Its bind list
  and `SINGULARITYENV_*` handling are borrowed; the argv is composed here.

## Verification

```bash
./verify-sandbox.sh cases/fftw-3.3.8.env    # the gate — must pass before any run
./run-agent.sh      cases/fftw-3.3.8.env --shell
```

Run the gate after any change to `jail.sh`. It needs a compute node (`$NSLOTS` set)
and the pilot image; it is read-only with respect to `/share`.
