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

# Where this harness lives, so it can mask itself -- see "Mask THIS HARNESS" below.
SANDBOX_SELF_DIR="${SANDBOX_SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

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
  # -s is a GLOBAL flag and must precede the subcommand. "only print errors": it drops
  # the INFO lines about nested bind targets AND the WARNING that the private home bind
  # overrides --workdir's home. Both fire on every single run by construction -- we
  # deliberately override that home -- so they are noise that trains a reader to ignore
  # output. -q was not enough; it suppresses INFO but keeps WARNING.
  #
  # Verified that a genuine failure still prints under -s: a bad image path gives the
  # same FATAL as without it. SANDBOX_VERBOSE=1 restores everything for diagnosis.
  local quiet=( -s ); [ -n "${SANDBOX_VERBOSE:-}" ] && quiet=()
  SANDBOX_ARGS=( singularity "${quiet[@]}" exec -e --contain --workdir "$out/workdir" )

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

  # Extra read-only binds, "src:dst" per entry, applied AFTER the private home so they
  # can land inside it. The reason this exists: an agent's instructions usually live in
  # a project directory, and discovering them means starting the agent with that
  # directory as cwd -- but every repo path here is read-only, so the agent would be
  # working somewhere it cannot write. Mounting the instructions into the private home
  # instead makes them available from ANY cwd, leaving the writable workspace free to
  # be the working directory. For a Claude Code-style agent:
  #
  #   SANDBOX_RO_BINDS="$REPO/.claude/skills:$HOME/.claude/skills
  # $REPO/.claude/agents:$HOME/.claude/agents
  # $REPO/.claude/references:$HOME/.claude/references"
  #
  # $HOME/.claude itself stays writable, so the agent can still write its own state.
  # A STRING, one "src:dst" per line -- not an array. Bash arrays cannot be exported,
  # so an array set in the caller's shell silently never reaches this script and the
  # binds vanish with no error. Measured the hard way.
  local rb
  while IFS= read -r rb; do
    [ -n "$rb" ] || continue
    [ -e "${rb%%:*}" ] && SANDBOX_ARGS+=( --bind "$rb:ro" )
  done <<< "${SANDBOX_RO_BINDS:-}"

  # ---- 7. MASKS, LAST ---------------------------------------------------------
  # Everything above this line is visible; everything here is hidden. Appending in
  # this order is the entire blinding guarantee -- see the header.
  #
  # EACH MASK GETS ITS OWN DIRECTORY. Sharing one "empty" source across masks leaks:
  # when a later bind lands inside a masked path (the run directory restored over the
  # masked harness, below), Singularity materialises that mount point INSIDE the mask
  # source -- so the shared directory stops being empty and every other mask shows the
  # stray entry. Observed exactly that: `ls -A /share/pkg.7/fftw/3.3.8` inside the
  # container returned "results".
  local _mask_n=0
  _mask() {                       # _mask <path-to-hide>
    _mask_n=$((_mask_n+1))
    local d="$emptydir/m$_mask_n"
    mkdir -p "$d" || return 1
    SANDBOX_ARGS+=( --bind "$d:$1:ro" )
  }

  if [ -d "$pkg_root/$pkg/$ver" ]; then
    _mask "$pkg_root/$pkg/$ver"
    SANDBOX_BLINDED=1
  fi
  # Mask THIS HARNESS. The site bind list contains /projectnb, /usr1, /project and
  # friends, so if the harness lives under any of them -- it does, in the repo it was
  # written in -- the whole directory is swept into the container read-only. That
  # includes cases/*.env, which names the blinded version and the prior version, and
  # results/, which holds earlier transcripts for the same package. Blinding the
  # package tree while leaving the answer key readable blinds nothing.
  #
  # Self-protecting rather than per-case: the harness always knows where it is, and a
  # BLIND_PATHS entry someone forgets to add is exactly the failure this prevents.
  if [ -n "${SANDBOX_SELF_DIR:-}" ] && [ -d "$SANDBOX_SELF_DIR" ]; then
    _mask "$SANDBOX_SELF_DIR"
    # ...but the run's own output usually lives UNDER the harness (results/<stamp>/),
    # and the workspace lives under that. Masking the harness would therefore hide the
    # one writable path the agent has. Bind this run's directory back afterwards --
    # later wins -- so the agent sees its own run and nothing else: no cases/*.env, no
    # earlier results.
    #
    # This is also why $emptydir must be mode 755 and must NOT live under the masked
    # tree: Singularity materialises the nested mount point inside the mask source
    # before mounting, so a 555 directory fails with
    #   FATAL: ... failed to create .../.empty/results directory: mkdirat: permission denied
    # and a mask source inside its own target is a mount loop.
    case "$out" in
      "$SANDBOX_SELF_DIR"/*) SANDBOX_ARGS+=( --bind "$out:$out" ) ;;
    esac
  fi

  local b
  for b in "${extra_blind[@]}"; do
    # Masking a nonexistent path is a hard error, not a no-op.
    [ -e "$b" ] && _mask "$b"
  done

  SANDBOX_ARGS+=( "$image" )
}

# build_sandbox_args_MISORDERED — the same mounts with the mask moved BEFORE the
# read-only parent. Used only by verify-sandbox.sh, which asserts that this variant
# FAILS to blind. A blinding check that only ever sees the correct order cannot
# distinguish a working mask from an unnecessary one.
build_sandbox_args_misordered() {
  local image=$1 pkg_root=$2 pkg=$3 ver=$4 work=$5 out=$6 emptydir=$7
  MISORDERED_ARGS=( singularity -s exec -e --contain --workdir "$out/workdir"
                    --bind "$emptydir:$pkg_root/$pkg/$ver:ro" )
  local d
  for d in "${SANDBOX_RO_DIRS[@]}"; do
    [ -d "$d" ] && MISORDERED_ARGS+=( --bind "$d:$d:ro" )
  done
  # Same private home as the real argv, so this variant differs ONLY in mask order.
  MISORDERED_ARGS+=( --bind "$out/homedir:$HOME" "$image" )
}
