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
