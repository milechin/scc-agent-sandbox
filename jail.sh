# shellcheck shell=bash
#
# jail.sh — build the `singularity exec` argv for an agent sandbox run.
#
# Sourced by verify-sandbox.sh and run-agent.sh so both use the SAME jail. If they
# ever diverge, verification stops proving anything about the run.
#
# SELF-CONTAINED ON PURPOSE. This directory is meant to be liftable into its own
# repository for evaluating agents other people wrote, so nothing here may reference
# a particular agent, skill, or reference layout. The agent is a command string.
#
# ---------------------------------------------------------------------------------
# WHY THE ORDER OF BINDS IS LOAD-BEARING
#
# Singularity applies binds in the order given, and a later bind over a path shadows
# an earlier one. There is NO --exclude/--unbind flag (checked: singularity-ce 4.5.0
# has nothing matching either), so hiding a child of a bound parent is done by
# MASKING -- binding an empty directory over the child.
#
# That means the mask must come AFTER the parent. Reversed, the parent overlays the
# mask and the child is fully readable again -- measured, with the target's notes.txt
# readable and no error, warning or exit code to notice. verify-sandbox.sh tests the
# reversed order explicitly for exactly this reason.
#
# THREE MORE THINGS THAT SURPRISE PEOPLE, all measured on singularity-ce 4.5.0:
#
#   * A bind is READ-WRITE by default. `-B /share` gives the container write access
#     to /share. The `:ro` suffix is what makes it read-only. The site wrapper
#     /share/singularity/utils/scc-singularity generates every bind read-write, which
#     is right for ordinary interactive work and wrong for a test jail -- so this
#     borrows its bind LIST and its env handling but composes its own argv.
#   * --mount supports only type=bind (type=tmpfs is rejected), so the mask needs a
#     real empty directory on the host.
#   * --contain replaces $HOME and /tmp with fresh tmpfs CAPPED AT 64 MB. Anything
#     writing caches or shell state to $HOME hits ENOSPC and it surfaces as an
#     unrelated-looking failure, so --workdir puts the session dirs on real disk.
# ---------------------------------------------------------------------------------

# The site's bind list, from `scc-singularity --scc-preview`. Only ones that exist
# are bound; the wrapper does the same test.
SANDBOX_RO_DIRS=(
  /share /usr1 /usr2 /usr3 /usr4 /var/spool/sge
  /project /projectnb /projectnb2 /restricted
  /rproject /rprojectnb /rprojectnb2
  /net /ad /usr/local
)

# build_sandbox_args <image> <pkg_root> <pkg> <ver> <work> <out> <emptydir> [blind...]
#
# Sets: SANDBOX_ARGS (array)  SANDBOX_BLINDED (0|1)  SANDBOX_ENV (array of VAR=VAL)
build_sandbox_args() {
  local image=$1 pkg_root=$2 pkg=$3 ver=$4 work=$5 out=$6 emptydir=$7
  shift 7
  local extra_blind=("$@")

  SANDBOX_BLINDED=0

  # ---- 1. isolate -------------------------------------------------------------
  # -e      clean environment (the wrapper does this too)
  # --contain  empty $HOME and /tmp instead of the host's
  # --workdir  put those session dirs on real disk rather than a 64 MB tmpfs
  SANDBOX_ARGS=( singularity exec -e --contain --workdir "$out/workdir" )

  # Re-inject only what a build genuinely needs, the way scc-singularity does.
  # LMOD_IGNORE_CACHE matters here beyond performance: a cached Lmod scan still
  # contains the masked version, so without it `module avail` lists a module that
  # cannot be loaded -- which sends an agent off troubleshooting a phantom.
  SANDBOX_ENV=(
    "SINGULARITYENV_LMOD_IGNORE_CACHE=yes"
    "SINGULARITYENV_USER=${USER:-$(id -un)}"
  )
  [ -n "${NSLOTS:-}" ] && SANDBOX_ENV+=( "SINGULARITYENV_NSLOTS=$NSLOTS" )
  [ -n "${TMPDIR:-}" ] && SANDBOX_ENV+=( "SINGULARITYENV_TMPDIR=$TMPDIR" )

  # ---- 2. read-only data ------------------------------------------------------
  local d
  for d in "${SANDBOX_RO_DIRS[@]}"; do
    [ -d "$d" ] && SANDBOX_ARGS+=( --bind "$d:$d:ro" )
  done
  [ -f /var/lib/dbus/machine-id ] && \
    SANDBOX_ARGS+=( --bind /var/lib/dbus/machine-id:/var/lib/dbus/machine-id:ro )

  # ---- 3. a private HOME, bound back OVER the read-only site dirs -------------
  # --contain alone is not enough. Home lives under /usr1 (or /usr2../usr4), which is
  # in the site bind list above, so that read-only bind lands on top of the contained
  # tmpfs and the REAL home reappears: measured at 209 entries with ~/.claude readable
  # and $HOME not writable. That defeats the isolation entirely -- an agent under test
  # could read every other project's transcripts -- and breaks agents that write
  # dotfiles.
  #
  # Binding a per-run directory over $HOME after the site dirs fixes both, because
  # later binds win. It also means the agent's own state (~/.claude and friends)
  # lands in $out/homedir and survives the container with no extra plumbing.
  SANDBOX_ARGS+=( --bind "$out/homedir:$HOME" )

  # ---- 4. writable workspace --------------------------------------------------
  # The one place the agent may write. Bound AFTER the read-only dirs so it wins if
  # it happens to live under one of them (a workspace under /projectnb is normal).
  SANDBOX_ARGS+=( --bind "$work:$work" )

  # ---- 5. scratch -------------------------------------------------------------
  [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && SANDBOX_ARGS+=( --bind "$TMPDIR:$TMPDIR" )

  # ---- 6. agent runtime + capture --------------------------------------------
  # Set by the caller: what to bind so the agent binary exists inside, and where its
  # state should land so it survives the container. Both optional -- an agent that
  # needs neither still works.
  if [ -n "${SANDBOX_AGENT_DIR:-}" ] && [ -d "$SANDBOX_AGENT_DIR" ]; then
    SANDBOX_ARGS+=( --bind "$SANDBOX_AGENT_DIR:$SANDBOX_AGENT_DIR:ro" )
    # Binding the agent in is not enough to make it runnable: `-e` gives the container
    # its own PATH, so a binary under $HOME/.local/bin is present but "command not
    # found". Prepend its bin/ if there is one.
    [ -d "$SANDBOX_AGENT_DIR/bin" ] && \
      SANDBOX_ENV+=( "SINGULARITYENV_PREPEND_PATH=$SANDBOX_AGENT_DIR/bin" )
  fi
  # Optional: only needed when an agent's state dir is NOT under $HOME. State that
  # does live under $HOME already persists, because $HOME is now $out/homedir.
  [ -n "${SANDBOX_CAPTURE_AT:-}" ] && [ -d "$out/home" ] && \
    SANDBOX_ARGS+=( --bind "$out/home:$SANDBOX_CAPTURE_AT" )

  # ---- 7. MASKS, LAST ---------------------------------------------------------
  # Everything above this line is visible; everything here is hidden. Appending in
  # this order is the entire blinding guarantee -- see the header.
  if [ -d "$pkg_root/$pkg/$ver" ]; then
    SANDBOX_ARGS+=( --bind "$emptydir:$pkg_root/$pkg/$ver:ro" )
    SANDBOX_BLINDED=1
  fi
  local b
  for b in "${extra_blind[@]}"; do
    # Masking a nonexistent path is a hard error, not a no-op.
    [ -e "$b" ] && SANDBOX_ARGS+=( --bind "$emptydir:$b:ro" )
  done

  SANDBOX_ARGS+=( "$image" )
}

# build_sandbox_args_MISORDERED — the same mounts with the mask moved BEFORE the
# read-only parent. Used only by verify-sandbox.sh, which asserts that this variant
# FAILS to blind. A blinding check that only ever sees the correct order cannot
# distinguish a working mask from an unnecessary one.
build_sandbox_args_misordered() {
  local image=$1 pkg_root=$2 pkg=$3 ver=$4 work=$5 out=$6 emptydir=$7
  MISORDERED_ARGS=( singularity exec -e --contain --workdir "$out/workdir"
                    --bind "$emptydir:$pkg_root/$pkg/$ver:ro" )
  local d
  for d in "${SANDBOX_RO_DIRS[@]}"; do
    [ -d "$d" ] && MISORDERED_ARGS+=( --bind "$d:$d:ro" )
  done
  # Same private home as the real argv, so this variant differs ONLY in mask order.
  MISORDERED_ARGS+=( --bind "$out/homedir:$HOME" "$image" )
}
