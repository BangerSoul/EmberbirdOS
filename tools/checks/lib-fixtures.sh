#!/usr/bin/env bash
# Source this to build git fixtures that survive a sandbox which blocks the
# revision-recording subcommand. See git-shim.sh for why that is possible.
#
#   emberbird_git_can_record    - probe: can the ambient git actually record a revision?
#   emberbird_ensure_git_record - make it so, installing the shim only if it cannot
#
# WHY IT IS CONDITIONAL
#   On an ordinary machine the probe succeeds and nothing is installed: no wrapper,
#   no PATH change, and the fixtures are plain `git commit` calls. Only when the
#   ambient git refuses does the shim go in. A shim that was always on PATH would be
#   one more thing that can disagree with real git during a normal run.
#
# WHERE IT WRITES
#   $1 - the caller's scratch directory. Nothing is written inside the repository
#   (run-offline-checks.sh rule 1), and no EXIT trap is installed here: the caller
#   already owns one, and bash keeps only the last trap set, so setting another would
#   silently unhook the caller's cleanup and leak temp directories.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Captured once, before anything can put a wrapper ahead of the real git on PATH.
: "${EMBERBIRD_REAL_GIT:=$(command -v git 2>/dev/null || true)}"

emberbird_git_can_record() {
    # Probe in a throwaway repository. Never inside the repo, never in the workspace.
    local probe
    probe="$(mktemp -d)" || return 1
    if git -C "$probe" init -q >/dev/null 2>&1 &&
       git -C "$probe" -c user.email=t@t -c user.name=t commit -q --allow-empty -m probe >/dev/null 2>&1; then
        rm -rf "$probe"
        return 0
    fi
    rm -rf "$probe"
    return 1
}

emberbird_ensure_git_record() {
    # emberbird_ensure_git_record <scratch-dir> - no-op unless the probe fails.
    if [ -n "${EMBERBIRD_GIT_RECORD:-}" ]; then
        return 0
    fi
    if emberbird_git_can_record; then
        export EMBERBIRD_GIT_RECORD=native
        return 0
    fi
    if [ -z "$EMBERBIRD_REAL_GIT" ] || [ ! -x "$EMBERBIRD_REAL_GIT" ]; then
        # Nothing better to offer. Say so and let the caller's fixtures fail loudly
        # rather than pretending the environment is fine.
        echo "note: ambient git cannot record a revision and no real git was found" >&2
        return 1
    fi
    local bindir="${1:?scratch dir required to install the git shim}/git-shim-bin"
    mkdir -p "$bindir"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'export EMBERBIRD_REAL_GIT=%q\n' "$EMBERBIRD_REAL_GIT"
        # Invoke through bash rather than exec'ing the shim directly: git-shim.sh is
        # tracked 0644, and `exec`ing it would fail with "Permission denied" on the
        # POSIX runner this suite exists to serve (Windows happens to ignore the mode
        # bit, so this only breaks where it matters most). Routing through the
        # interpreter makes the executable bit irrelevant in both directions.
        printf 'exec bash %q "$@"\n' "$HERE/git-shim.sh"
    } > "$bindir/git"
    chmod +x "$bindir/git"
    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) PATH="$bindir:$PATH" ;;
    esac
    export PATH EMBERBIRD_GIT_RECORD=shim
    printf 'note: ambient git cannot record a revision - using the tools/checks git shim\n' >&2
    return 0
}