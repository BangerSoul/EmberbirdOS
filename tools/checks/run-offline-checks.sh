#!/usr/bin/env bash
# EmberbirdOS - the offline check suite: everything provable with bash + python3.
#
# WHY THIS EXISTS
#   EmberbirdOS's checks run in three environments that can see very different
#   things, and only one of them was ever scripted:
#
#     * a POSIX sandbox / Linux runner (THIS script) - bash and python3 only.
#       No PowerShell, no QEMU, no `repo`, no AOSP tree, and no guarantee of network.
#     * a windows-latest runner (.github/workflows/launcher-tests.yml) - the only
#       place the PowerShell is parsed and actually executed.
#     * a big-disk build node (guest-build.yml / Crave) - the only place the
#       recipe's expensive half (repo sync + a multi-hundred-GB AOSP build) runs.
#
#   The first environment had nothing to run. Verification there was a series of
#   ad-hoc commands, so the parts of the tooling that CAN be proven locally were
#   proven only by whoever remembered to type them. This is that one command.
#
# WHAT IT COVERS (offline: no network, no VM, no AOSP tree, no PowerShell)
#   * `bash -n` over every tracked *.sh
#   * every tracked *.py compiles (compiled in memory - writes no .pyc)
#   * the captured upstream manifests still match
#     image/manifest/upstream/SHA256SUMS.txt - the anti-tampering half of the
#     BLOCKING verify-provenance job
#   * tools/manifest/verify-lock.py      - the offline structural gate on the X1 lock
#   * tools/manifest/test-verify-lock.py - the verifier's exit-code contract
#   * tools/checks/test-manifest-resolver.py  - the X1 lock generator itself
#   * tools/checks/test-build-recipe.py       - the build recipe's embedded Python,
#     its artifact discovery, and the completeness constants it shares with the lock
#   * tools/checks/test-revision-audit.sh - the recipe's on-disk revision audit
#     (HEAD vs the lock) on synthetic git repos: clean, drifted, missing, moved tag
#   * tools/manifest/test-verify-x2-provenance.py - the post-pull X2 evidence
#     check's own contract: a stale, truncated, unrecorded or wrong-build record
#     must FAIL, and "nothing pulled yet" must be distinguishable from a pass
#   * tools/manifest/verify-x2-provenance.py - image/out/x2-provenance.json against
#     the artifacts actually on disk (a SKIP until something has been pulled)
#   * tools/checks/check-powershell-static.py - ASCII purity, delimiter pairing, and
#     the two shipped scripts' deliberate performance properties
#   * shellcheck over the shell scripts, when it is installed (informational only)
#
# WHAT IT CANNOT COVER - printed at the end so a green run is never mistaken for
# full coverage:
#   * parsing/running the PowerShell  -> launcher-tests.yml (windows-latest)
#   * repo sync + the AOSP build      -> guest-build.yml / Crave (big-disk node)
#   * QEMU boot + X3-X5 evidence      -> a WHPX-provisioned Windows host
#
# SAFETY
#   Every check here is read-only. The one thing no check may touch is the committed
#   X1 lock, so the manifest artifacts' hashes are taken before and after and the run
#   FAILS if any of them changed. (resolve-manifest-lock.py's main() rewrites the lock
#   in place, which is exactly why nothing here calls it: the suites exercise it at
#   function granularity, and the lock-immutability check is the backstop.)
#
# Usage:  bash tools/checks/run-offline-checks.sh
# Exit:   0 = every check passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# These checks must leave the tree exactly as they found it, and loading a module
# through importlib (verify-lock.py loads the resolver that way) would otherwise
# drop __pycache__ directories next to the sources.
export PYTHONDONTWRITEBYTECODE=1

PASSED=0
FAILED=0
FAILED_NAMES=()

# The artifacts that are the M2 provenance anchor. Their hashes bracket the run.
LOCK_ARTIFACTS=(
    "image/manifest/arcadia-x86.pinned.xml"
    "image/manifest/lock-coverage.json"
    "image/manifest/arcadia-x86.pin.json"
    "image/manifest/.lock-checkpoint.json"
)

# ------------------------------------------------------------------- harness ---
run() {
    # run <name> <command...> - never aborts the suite: one red check should not
    # hide the state of the others.
    local name="$1"; shift
    printf '\n\033[1;36m== %s\033[0m\n' "$name"
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '   \033[1;32m-> PASS\033[0m\n'
        PASSED=$(( PASSED + 1 ))
    else
        printf '   \033[1;31m-> FAIL (exit %s)\033[0m\n' "$rc"
        FAILED=$(( FAILED + 1 ))
        FAILED_NAMES+=( "$name" )
    fi
}

tracked() {
    # tracked <glob> - every path matching the glob, relative to the root.
    #   --cached          the committed files
    #   --others --exclude-standard
    #                     the ones you have not committed yet. A check suite must
    #                     cover the files you are working on, which is exactly when
    #                     you run it; --exclude-standard keeps .gitignore honoured.
    # Falls back to `find` so the suite still works from an exported tarball.
    local pattern="$1"
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard "$pattern"
    else
        ( cd "$REPO_ROOT" && find . -name "$pattern" -not -path './.git/*' | sed 's|^\./||' )
    fi
}

hash_artifacts() {
    python3 - "${LOCK_ARTIFACTS[@]}" <<'PY'
import hashlib, os, sys
for path in sys.argv[1:]:
    if os.path.exists(path):
        with open(path, "rb") as fh:
            print("%s  %s" % (hashlib.sha256(fh.read()).hexdigest(), path))
    else:
        print("%s  %s" % ("(absent)", path))
PY
}

# -------------------------------------------------------------------- checks ---
check_shell_syntax() {
    local -a files=() failed=()
    local f out
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(tracked '*.sh')
    if [ "${#files[@]}" -eq 0 ]; then
        printf '  no tracked shell scripts found\n' >&2
        return 1
    fi
    for f in "${files[@]}"; do
        if out="$(bash -n "$REPO_ROOT/$f" 2>&1)"; then
            printf '  [ok]   %s\n' "$f"
        else
            printf '  [FAIL] %s\n' "$f" >&2
            printf '%s\n' "$out" | sed 's/^/         /' >&2
            failed+=( "$f" )
        fi
    done
    [ "${#failed[@]}" -eq 0 ]
}

check_python_syntax() {
    local -a files=()
    local f
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(tracked '*.py')
    if [ "${#files[@]}" -eq 0 ]; then
        printf '  no tracked python files found\n' >&2
        return 1
    fi
    # compile() in memory, never py_compile: this must not litter the tree with
    # __pycache__ directories just to answer "does it parse".
    python3 - "${files[@]}" <<'PY'
import sys
bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as fh:
            compile(fh.read(), path, "exec")
        print("  [ok]   %s" % path)
    except SyntaxError as exc:
        bad += 1
        print("  [FAIL] %s: %s" % (path, exc), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

check_upstream_hashes() {
    # The same anti-tampering check the blocking CI job runs: the captured upstream
    # manifests under image/manifest/upstream/ are the input the X1 lock was cut
    # from, so a change to one of them means the lock is no longer anchored.
    python3 - <<'PY'
import hashlib, os, sys

os.chdir("image/manifest/upstream")
sums = "SHA256SUMS.txt"
if not os.path.exists(sums):
    print("  [FAIL] %s is missing" % sums, file=sys.stderr)
    sys.exit(1)

ok = bad = 0
with open(sums, encoding="utf-8") as fh:
    for raw in fh:
        # The capture was produced on Windows, so strip CR before parsing -- a
        # trailing \r would otherwise join the filename.
        line = raw.replace("\r", "").strip()
        if not line:
            continue
        want, sep, name = line.partition("  ")
        if not sep:                                # tolerate single-space output
            want, _, name = line.partition(" ")
            name = name.lstrip(" *")
        if not os.path.exists(name):
            print("  [FAIL] captured manifest missing: %s" % name, file=sys.stderr)
            bad += 1
            continue
        with open(name, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != want:
            print("  [FAIL] %s\n           expected %s\n           got      %s" % (name, want, got), file=sys.stderr)
            bad += 1
        else:
            ok += 1

print("  [ok]   %d captured manifest(s) match SHA256SUMS.txt" % ok)
sys.exit(1 if bad else 0)
PY
}

check_x2_provenance() {
    # The post-pull half of the X2 chain: re-hash what came back from Crave and
    # compare it to image/out/x2-provenance.json. Until this existed the "verify the
    # sha256 above" step in the runbook was a manual eyeball of a number printed on
    # a node that no longer exists.
    #
    # Exit 2 means "no record has been pulled yet", which is the repo's actual
    # current state -- M2 X2 is OPEN. That is neither a pass nor a failure, and the
    # distinction matters: a suite that counted it as PASS would let "the pulled
    # image verified" be read out of a run where nothing was ever pulled. So it is
    # reported as a skip and the wording says it is not a verification.
    local rc=0
    python3 tools/manifest/verify-x2-provenance.py || rc=$?
    case "$rc" in
        0) printf '  [ok]   the pulled X2 record matches the artifacts on disk\n' ;;
        2) printf '  [skip] no X2 record pulled yet - M2 X2 is OPEN, and this is NOT a verification\n' ;;
        *)
            printf '  [FAIL] the pulled X2 record does not match the artifacts on disk\n' >&2
            return 1
            ;;
    esac
    return 0
}

check_shellcheck() {
    # Informational on purpose. shellcheck is not installed project-wide and is not
    # pinned, so it must not be able to red a run on findings that predate it.
    if ! command -v shellcheck >/dev/null 2>&1; then
        printf '  [skip] shellcheck is not installed (informational check)\n'
        return 0
    fi
    local -a files=()
    local f found=0
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(tracked '*.sh')
    for f in "${files[@]}"; do
        if ! out="$(shellcheck -S error "$REPO_ROOT/$f" 2>&1)"; then
            found=1
            printf '  [note] %s\n' "$f"
            printf '%s\n' "$out" | sed 's/^/         /'
        fi
    done
    [ "$found" -eq 0 ] && printf '  [ok]   shellcheck found no errors\n'
    printf '  [info] shellcheck findings do not fail this suite\n'
    return 0
}

verify_lock_unchanged() {
    if cmp -s "$1" "$2"; then
        printf '  [ok]   lock / coverage / pin / checkpoint hashes are identical before and after\n'
        return 0
    fi
    printf '  [FAIL] a check modified a committed manifest artifact:\n' >&2
    diff -u --label before --label after "$1" "$2" | sed 's/^/         /' >&2
    return 1
}

# ---------------------------------------------------------------------- main ---
printf '\n\033[1;36m== EmberbirdOS offline checks ==\033[0m\n'
printf 'repo:    %s\n' "$REPO_ROOT"
printf 'python3: %s\n' "$(python3 --version 2>&1)"
printf 'bash:    %s\n' "${BASH_VERSION:-unknown}"
if git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    printf 'commit:  %s\n' "$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi

BEFORE="$(mktemp)"; AFTER="$(mktemp)"
trap 'rm -f "$BEFORE" "$AFTER"' EXIT
hash_artifacts > "$BEFORE"

run "shell syntax (bash -n, every tracked *.sh)"  check_shell_syntax
run "python syntax (every tracked *.py)"         check_python_syntax
run "captured upstream manifests (SHA256SUMS)"   check_upstream_hashes
run "X1 lock: offline structural verification"   python3 tools/manifest/verify-lock.py
run "X1 lock: verifier exit-code contract"       python3 tools/manifest/test-verify-lock.py
run "X1 lock: generator unit tests"              python3 tools/checks/test-manifest-resolver.py
run "build recipe: offline tests"                python3 tools/checks/test-build-recipe.py
run "build recipe: revision audit behaviour"     bash tools/checks/test-revision-audit.sh
run "PowerShell: static checks"                  python3 tools/checks/check-powershell-static.py
run "X2 evidence: pulled record vs artifacts"     check_x2_provenance
run "shellcheck (informational)"                 check_shellcheck

hash_artifacts > "$AFTER"
run "committed lock artifacts unchanged by this run" verify_lock_unchanged "$BEFORE" "$AFTER"

printf '\n\033[1;36m== summary ==\033[0m\n'
printf '  %d passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    for n in "${FAILED_NAMES[@]}"; do printf '  [FAIL] %s\n' "$n"; done >&2
fi

cat <<'NOTES'

  Not covered here - by design. A green run is not full coverage:
    * parsing/running the PowerShell   -> .github/workflows/launcher-tests.yml
                                          (windows-latest is the only place it runs)
    * repo sync + the AOSP build       -> guest-build.yml / Crave (big-disk node)
    * QEMU boot + the X3-X5 evidence   -> a WHPX-provisioned Windows host
    * verifying a REAL pulled image    -> only happens once a job has succeeded and
                                          `crave pull image/out/` has been run; until
                                          then the X2 record check is a no-op SKIP
NOTES

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
printf '\n  All offline checks passed.\n'
exit 0
