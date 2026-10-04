#!/usr/bin/env bash
# Offline exercise of tools/crave/run-remote-build.sh against a STUB client.
#
# WHY THIS EXISTS
#   The `status` subcommand shipped as three lines that could not fail:
#
#       ( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" list | sed -n '/Your jobs/,$p' | head -8
#         bash "$CRAVE_SHIM" getlog 2>&1 | tail -25 )
#
#   and every part of that was wrong against the real client, observed 2026-10-03:
#     * the client prints "Your active jobs:" and "Job History:" - never "Your jobs" -
#       so the table was ALWAYS empty, and an empty table is indistinguishable from
#       "nothing to report";
#     * `getlog` carried no --jobID, while `log`/`watch`/`pull` all pin one. Unpinned,
#       the client resolves against the current directory's workspace and answers
#       "No running job found on this workspace", which makes a healthy job look dead;
#     * it exited 0 even when the client printed
#         Error: could not get matching git url at: C:/Users/<you>
#       - the client's own diagnostics arrive on the same stream as its data, and it
#       does not reliably set a nonzero status.
#
#   A status command that cannot fail is worse than no status command: it converts
#   "I could not look" into "there is nothing wrong". These tests drive the real
#   script (not a copy of its logic) with a stub on CRAVE_SHIM, so a future edit that
#   drops the --jobID pin or swallows a client error goes red here.
#
#   `log` and `pull` shipped with the same unpinned fallbacks and got the same
#   treatment (2026-10-04): both refuse to run without a job id, both judge the
#   client on exit status and text, and `pull` clears the ticket's staging directory
#   first, so a failed pull can no longer leave the PREVIOUS job's artifacts in
#   place for the copy + verify steps to bless as this job's record.
#
# WHAT IS AND IS NOT TESTED
#   The stub speaks for the client's OUTPUT contract only: which section headers it
#   prints and what its exit status is. It cannot prove how the real client behaves
#   under an API outage. Both are recorded in docs/M2-CRAVE-BUILD.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# Which revision of the script is under test. Same convention as EMBERBIRD_RECIPE in
# lib-audit.sh: a test written alongside a fix passes trivially against that fix, so
# point it at the previous revision and require it to go red -
#   git show HEAD~1:tools/crave/run-remote-build.sh > /tmp/old.sh
#   EMBERBIRD_CRAVE_RUNNER=/tmp/old.sh bash tools/checks/test-crave-remote-build.sh  # must FAIL
SCRIPT="${EMBERBIRD_CRAVE_RUNNER:-$REPO_ROOT/tools/crave/run-remote-build.sh}"
# Some sandboxes refuse `git commit`, and ensure_ticket resolves the ticket's branch
# with `rev-parse --abbrev-ref HEAD` - on a repo with no commit that prints a fatal
# error to stderr and pollutes every assertion. lib-fixtures.sh probes for a git that
# records revisions and installs a plumbing-backed shim only if it must.
# shellcheck source=lib-fixtures.sh
source "$HERE/lib-fixtures.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
emberbird_ensure_git_record "$T" || {
  echo "FATAL: cannot obtain a git that records revisions; the ticket fixture would be broken" >&2
  exit 1
}

fail=0
pass() { echo "  [PASS] $1"; }
bad()  { echo "  [FAIL] $1"; fail=1; }

# ---------------------------------------------------------------- the stub client --
# One stub for every subcommand. It records the argv it was called with, so a test
# can assert THAT the --jobID pin was passed, not merely that the output looks right.
STUB="$T/crave-stub"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
# A stand-in for tools/crave/crave.sh. Behaviour is driven by STUB_LIST_BODY,
# STUB_LIST_RC, STUB_LOG_BODY, STUB_LOG_RC and the STUB_PULL_* set. Every
# invocation appends its argv to STUB_ARGV so a test can prove which flags the
# script actually passed.
printf '%s\n' "$*" >> "${STUB_ARGV:?}"
sub="$1"; shift
case "$sub" in
  list)
    printf '%s' "${STUB_LIST_BODY:-}"
    exit "${STUB_LIST_RC:-0}" ;;
  getlog)
    printf '%s' "${STUB_LOG_BODY:-}"
    exit "${STUB_LOG_RC:-0}" ;;
  pull)
    # The real client materialises the pulled path under the ticket. When
    # STUB_PULL_DIR says where, a small artifact set is written there; with
    # STUB_PULL_RECORD=1 a matching x2 provenance record is written next to it,
    # so the script's copy + verify steps have something true to chew on.
    if [ -n "${STUB_PULL_DIR:-}" ]; then
      mkdir -p "$STUB_PULL_DIR"
      printf 'artifact-bytes-for-the-fixture\n' > "$STUB_PULL_DIR/emulator-image.img"
      if [ -n "${STUB_PULL_RECORD:-}" ]; then
        sha="$(sha256sum "$STUB_PULL_DIR/emulator-image.img" | cut -d' ' -f1)"
        bytes="$(wc -c < "$STUB_PULL_DIR/emulator-image.img" | tr -d '[:space:]')"
        printf '{"artifacts":[{"artifact":"emulator-image.img","sha256":"%s","bytes":%s}],"manifest_revision":"%s","provenance_anchor":"image/manifest/arcadia-x86.pinned.xml","lock_confirmed_by":"verify-lock.py (offline fixture)"}' \
          "$sha" "$bytes" "${STUB_PULL_REVISION:-}" > "$STUB_PULL_DIR/x2-provenance.json"
      fi
    fi
    printf '%s' "${STUB_PULL_BODY:-}"
    exit "${STUB_PULL_RC:-0}" ;;
  *)
    echo "stub: unexpected subcommand '$sub'" >&2; exit 97 ;;
esac
STUB
chmod +x "$STUB"

# A ticket checkout with a .git and one real commit, so ensure_ticket takes the
# refresh path (never a clone), resolves its branch cleanly, and the refresh is a
# local no-op against itself - the suite needs no network.
TICKET="$T/ticket"
mkdir -p "$TICKET"
git init -q "$TICKET"
git -C "$TICKET" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ticket
git -C "$TICKET" remote add origin "$TICKET" 2>/dev/null || true

# run_status <expected-exit> <label>; STUB_* is exported by the caller.
run_status() {
  local want="$1" label="$2" rc=0
  STATUS_OUT="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
                   bash "$SCRIPT" status 2>&1 )" || rc=$?
  STATUS_RC="$rc"
  if [ "$rc" = "$want" ]; then
    pass "$label (exit $rc)"
  else
    bad "$label: exit $rc, expected $want"
    printf '%s\n' "$STATUS_OUT" | sed 's/^/         /'
  fi
}

# run_status_for <jobid> - same, against a job id the tables do not contain.
run_status_for() {
  local job="$1" rc=0
  STATUS_OUT="$( cd "$TICKET" && JOB="$job" TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
                   bash "$SCRIPT" status 2>&1 )" || rc=$?
  STATUS_RC="$rc"
}

# run_log <expected-exit> <label> - the `log` subcommand, pinned to job 777777.
run_log() {
  local want="$1" label="$2" rc=0
  LOG_OUT="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
                  bash "$SCRIPT" log 2>&1 )" || rc=$?
  LOG_RC="$rc"
  if [ "$rc" = "$want" ]; then
    pass "$label (exit $rc)"
  else
    bad "$label: exit $rc, expected $want"
    printf '%s\n' "$LOG_OUT" | sed 's/^/         /'
  fi
}

ACTIVE_TABLE='Your active jobs:

Job Id  Project Name  Job Status  Local Workspace  Job Url
------- ------------- ----------- --------------- --------
777777  LOS 20        running     workspace-1     https://foss.crave.io/x
'
HISTORY_TABLE='Job History:

Job Id  Project Name  Job Status  Finished
------- ------------- ----------- -------
777777  LOS 20        failed      2026-10-01
'
NO_TABLE='Configured Projects:

79  CipherOS  https://github.com/CipherOS/android_manifest.git  Complete
'
export STUB_ARGV="$T/argv.txt"
export STUB_LOG_BODY='Build Failed: returned 1
Total time: 7m58s
'

echo "== crave run-remote-build.sh: status (stub client) =="

echo "-- 1. getlog is PINNED with --jobID"
: > "$STUB_ARGV"
STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LOG_RC=0 run_status 0 "a clean, active job reports status"
if grep -q -- '--jobID 777777' "$STUB_ARGV"; then
  pass "getlog was called with --jobID 777777"
else
  bad "getlog was NOT pinned to the job"; sed 's/^/         /' "$STUB_ARGV"
fi
if grep -q -- '--projectID' "$STUB_ARGV"; then
  pass "getlog was called with --projectID"
else
  bad "getlog was NOT pinned to the project"
fi
case "$STATUS_OUT" in
  *"queue:    777777  LOS 20        running"*) pass "the active-jobs row for our job is shown";;
  *) bad "active row not shown"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /';;
esac

echo "-- 2. the Job History row is read too"
: > "$STUB_ARGV"
STUB_LIST_BODY="$HISTORY_TABLE" STUB_LIST_RC=0 STUB_LOG_RC=0 run_status 0 "a finished job reports status"
case "$STATUS_OUT" in
  *"queue:    finished - 777777"*) pass "the history row is reported as finished";;
  *) bad "history row not reported"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /';;
esac

echo "-- 3. 'left the queue' is not the same as 'the client drew no table'"
# The tables are real and present, but neither contains our job.
STUB_LIST_BODY="$ACTIVE_TABLE$HISTORY_TABLE" STUB_LIST_RC=0 STUB_LOG_RC=0 run_status_for 123456
case "$STATUS_OUT" in
  *"has left the queue"*) pass "a real table without our job -> 'left the queue'";;
  *) bad "did not distinguish 'left the queue'"; printf '%s
' "$STATUS_OUT" | sed 's/^/         /';;
esac
# No table was drawn at all - a different fact, and saying UNKNOWN is the point.
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LOG_RC=0 run_status_for 123456
case "$STATUS_OUT" in
  *"NO job table at all"*) pass "no table at all -> 'state is UNKNOWN', not 'left the queue'";;
  *) bad "conflated 'no table' with 'left the queue'"; printf '%s
' "$STATUS_OUT" | sed 's/^/         /';;
esac
# A project row must never be mistaken for a job row: 'Configured Projects:' has to
# end the section, or project id 79 would read as a job.
STUB_LIST_BODY="$ACTIVE_TABLE
Configured Projects:

79  CipherOS  https://github.com/CipherOS/android_manifest.git  Complete
" STUB_LIST_RC=0 STUB_LOG_RC=0 run_status_for 79
case "$STATUS_OUT" in
  *"has left the queue"*) pass "a project row is not read as a job row";;
  *) bad "a project row leaked into the job table"; printf '%s
' "$STATUS_OUT" | sed 's/^/         /';;
esac

echo "-- 4. a client ERROR makes status exit nonzero"
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LIST_BODY='Error: could not get matching git url at: C:/Users/someone
' STUB_LIST_RC=0 STUB_LOG_RC=0 bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "an 'Error:' line from the client exits nonzero even though the client exited 0 (rc=$rc)"
else
  bad "the client's error text was ignored because its exit status was 0"
fi
case "$out" in
  *"could not get matching git url"*) pass "the client's own error text is surfaced";;
  *) bad "the client error was swallowed"; printf '%s\n' "$out" | sed 's/^/         /';;
esac

echo "-- 5. a nonzero client exit also fails, and names which probe"
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LIST_BODY='' STUB_LIST_RC=0 STUB_LOG_RC=7 bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then pass "a failing getlog exits nonzero (rc=$rc)"; else bad "a failing getlog still exited 0"; fi
case "$out" in
  *"getlog --jobID 777777\` exited 7"*) pass "the failing probe is named with its exit code";;
  *) bad "the failing probe was not named"; printf '%s\n' "$out" | sed 's/^/         /';;
esac

echo "-- 6. the job id comes from \$JOB, else the run record; never guessed"
# JOB wins over the recorded id.
: > "$STUB_ARGV"
STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LOG_RC=0 run_status 0 "\$JOB is honoured"
grep -q -- '--jobID 777777' "$STUB_ARGV" \
  && pass "the explicit \$JOB is the one pinned" \
  || { bad "\$JOB was not pinned"; sed 's/^/         /' "$STUB_ARGV"; }

# With no \$JOB, the id recorded by `run` is used - and the row looked up is THAT job's.
: > "$STUB_ARGV"
out="$( cd "$TICKET" && env -u JOB TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
recorded="$(sed -n 's/.*"jobid"[^0-9]*\([0-9][0-9]*\).*/\1/p' \
            "$REPO_ROOT/image/out/crave-job.txt" 2>/dev/null | head -1)"
if [ -z "$recorded" ]; then
  echo "  [info] no image/out/crave-job.txt in this checkout - the fallback is not exercised here"
elif grep -q -- "--jobID $recorded" "$STUB_ARGV"; then
  # The argv log, not the report: what getlog was CALLED with is the whole claim.
  pass "with no \$JOB, the recorded jobid $recorded is pinned"
else
  bad "the recorded job id was not used"; sed 's/^/         /' "$STUB_ARGV"
fi

# And with neither, it must refuse rather than issue an unpinned getlog. That needs a
# REPO_ROOT with no image/out/crave-job.txt, so the script is invoked via a copy of
# the tree rather than by mutating this repository.
FAKE="$T/fakerepo"
mkdir -p "$FAKE/tools/crave" "$FAKE/image/out"
cp "$SCRIPT" "$FAKE/tools/crave/run-remote-build.sh"
# REPO_ROOT is derived from the script's own location, so the copy has to be a real
# git repo with an origin and a HEAD: the script reads both long before it looks for
# a job id, and would otherwise die on THAT instead of on the behaviour under test.
git init -q "$FAKE"
git -C "$FAKE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fake
git -C "$FAKE" remote add origin "$FAKE" 2>/dev/null || true
out="$( cd "$TICKET" && env -u JOB TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        bash "$FAKE/tools/crave/run-remote-build.sh" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no job id'; then
  pass "with neither \$JOB nor a record, status refuses instead of guessing"
else
  bad "status guessed a job id (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi

echo "-- 7. log: pinned, and it fails closed"
# A healthy getlog streams the log and exits 0 - with the pin visible in argv.
: > "$STUB_ARGV"
STUB_LOG_RC=0 run_log 0 "a healthy getlog streams the log"
if grep -q -- '--jobID 777777' "$STUB_ARGV" && grep -q -- '--projectID' "$STUB_ARGV"; then
  pass "log's getlog is pinned with --projectID/--jobID"
else
  bad "log issued an unpinned or mis-pinned getlog"; sed 's/^/         /' "$STUB_ARGV"
fi
case "$LOG_OUT" in
  *"Build Failed: returned 1"*) pass "the log body is streamed" ;;
  *) bad "the log body was not streamed"; printf '%s\n' "$LOG_OUT" | sed 's/^/         /' ;;
esac

# The client's error-on-the-data-stream trick (exit 0, Error: in the text) must
# fail `log` too - it must never present a client error as a build log.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LOG_BODY='Error: could not get matching git url at: C:/Users/someone
' STUB_LOG_RC=0 bash "$SCRIPT" log 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "an 'Error:' line from the client makes log exit nonzero even at exit 0 (rc=$rc)"
else
  bad "log presented a client error as a build log (exit 0)"
fi
case "$out" in
  *"could not get matching git url"*) pass "the client's error text is surfaced" ;;
  *) bad "the client error was swallowed"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

# A nonzero client exit fails too, and names the probe.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LOG_BODY='' STUB_LOG_RC=7 bash "$SCRIPT" log 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then pass "a failing getlog makes log exit nonzero (rc=$rc)"; else bad "log swallowed a getlog exit 7"; fi
case "$out" in
  *"--jobID 777777\` exited 7"*) pass "the failing probe is named with its exit code" ;;
  *) bad "the failing probe was not named"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

# With neither \$JOB nor a record, log refuses before any client call at all.
: > "$STUB_ARGV"
out="$( cd "$TICKET" && env -u JOB TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        bash "$FAKE/tools/crave/run-remote-build.sh" log 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no job id'; then
  pass "with neither \$JOB nor a record, log refuses instead of guessing"
else
  bad "log guessed a job id (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi
if grep -q '^getlog' "$STUB_ARGV"; then
  bad "a getlog was issued despite no job id"; sed 's/^/         /' "$STUB_ARGV"
else
  pass "no client call was made at all"
fi

echo "-- 8. pull: pinned, fails closed, and never blesses the previous job's artifacts"
# Refusal first: with neither \$JOB nor a record, no pull is issued at all.
: > "$STUB_ARGV"
out="$( cd "$TICKET" && env -u JOB TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        bash "$FAKE/tools/crave/run-remote-build.sh" pull 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no job id'; then
  pass "with neither \$JOB nor a record, pull refuses instead of guessing"
else
  bad "pull guessed a job id (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi
if grep -q '^pull' "$STUB_ARGV"; then
  bad "an unpinned pull was issued"; sed 's/^/         /' "$STUB_ARGV"
else
  pass "no client call was made at all"
fi

# A client error on the data stream (exit 0) must fail the pull - and the stale
# leftovers simulating a PREVIOUS job's pull must have been cleared from the
# staging dir, so nothing from it can reach the copy + verify steps.
mkdir -p "$TICKET/eb/image/out"
echo stale > "$TICKET/eb/image/out/old-build.iso"
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_PULL_BODY='Error: no running job found on this workspace
' STUB_PULL_RC=0 bash "$SCRIPT" pull 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "a client error on the data stream fails the pull even at client exit 0 (rc=$rc)"
else
  bad "pull blessed a failed transfer (exit 0)"
fi
case "$out" in
  *"client exited 0 but reported an error"*) pass "the exit-0-but-error case is named" ;;
  *) bad "the error was not named"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac
if [ ! -e "$TICKET/eb/image/out/old-build.iso" ]; then
  pass "the previous job's leftovers were cleared from the staging dir"
else
  bad "stale artifacts survived a failed pull, ready to be 'verified'"
fi

# A nonzero client exit fails too, naming the pinned probe.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_PULL_BODY='' STUB_PULL_RC=5 bash "$SCRIPT" pull 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then pass "a failing pull exits nonzero (rc=$rc)"; else bad "pull swallowed a client exit 5"; fi
case "$out" in
  *"--job 777777\` exited 5"*) pass "the failing pull is named with its exit code" ;;
  *) bad "the failing pull was not named"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

# Happy path, end to end: pinned argv, fresh artifacts copied into the repo, the
# x2 record actually verified - and the stale leftover still nowhere to be seen.
# This runs against a second copy of the tree (FAKE2) so the copy step cannot
# touch THIS repo's image/out; the fixture's pin/lock pair makes
# verify-x2-provenance.py accept the record the stub wrote.
FAKE2="$T/fakerepo-pull"
mkdir -p "$FAKE2/tools/crave" "$FAKE2/tools/manifest" "$FAKE2/image/out" "$FAKE2/image/manifest"
cp "$SCRIPT" "$FAKE2/tools/crave/run-remote-build.sh"
cp "$REPO_ROOT/tools/manifest/verify-x2-provenance.py" "$FAKE2/tools/manifest/"
# Same requirement as FAKE above: REPO_ROOT is read with git before anything else,
# so the copy has to be a real repo with an origin and a recorded HEAD.
git init -q "$FAKE2"
git -C "$FAKE2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fake-pull
git -C "$FAKE2" remote add origin "$FAKE2" 2>/dev/null || true
FIXREV="98a0a79cfffbb2cb9eb43dbaf5575a0195162bcf"
printf '{"manifest":{"revision":"%s"}}\n' "$FIXREV" > "$FAKE2/image/manifest/arcadia-x86.pin.json"
printf '<manifest><!-- fixture lock for the pull test --></manifest>\n' > "$FAKE2/image/manifest/arcadia-x86.pinned.xml"
mkdir -p "$TICKET/eb/image/out"
echo stale > "$TICKET/eb/image/out/old-build.iso"
: > "$STUB_ARGV"
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_PULL_DIR="$TICKET/eb/image/out" STUB_PULL_RECORD=1 STUB_PULL_REVISION="$FIXREV" \
        bash "$FAKE2/tools/crave/run-remote-build.sh" pull 2>&1 )" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  pass "a consistent pull runs through copy + provenance verification (exit 0)"
else
  bad "the happy path failed (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi
grep -q -- '--job 777777' "$STUB_ARGV" \
  && pass "pull was pinned with --projectID/--job" \
  || { bad "pull was NOT pinned to the job"; sed 's/^/         /' "$STUB_ARGV"; }
if [ -f "$FAKE2/image/out/emulator-image.img" ] && [ -f "$FAKE2/image/out/x2-provenance.json" ]; then
  pass "the pulled artifact and record landed in the repo's image/out"
else
  bad "the copy step did not run"; ls "$FAKE2/image/out" 2>/dev/null | sed 's/^/         /'
fi
case "$out" in
  *"X2 PROVENANCE VERIFIED"*) pass "the record was verified, not just copied" ;;
  *) bad "the verification step did not run"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac
if [ ! -e "$FAKE2/image/out/old-build.iso" ]; then
  pass "the stale leftover never reached image/out"
else
  bad "a stale .iso was copied into image/out"
fi

echo
if [ "$fail" = 0 ]; then
  echo "crave run-remote-build.sh offline test: PASS"
else
  echo "crave run-remote-build.sh offline test: FAIL"
  exit 1
fi