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
#   2026-10-05 added the probe that made a status answerable at all: the client's
# human tables stopped being drawn for this account for hours (job 303483 finished,
# exit 130, with no stdout retained), and only `list --jobID <id> --json` kept
# answering. Scenario 9 drives that probe: it must carry status, exit code and
# timings on its own, it must still exit nonzero when the client's diagnostic rides
# the same stream (the state is printed anyway), and it must never cost the table
# verdict - a client that cannot answer json falls back to it, and the two
# disagreeing is reported as DISPUTED rather than resolved in favour of one.
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
#   git show HEAD~1:tools/crave/run-remote-build.sh > tools/crave/control-runner.sh
#   EMBERBIRD_CRAVE_RUNNER=tools/crave/control-runner.sh bash tools/checks/test-crave-remote-build.sh  # must FAIL
#   rm tools/crave/control-runner.sh
# Write the control INSIDE the tree, not to /tmp: the script derives REPO_ROOT from its
# own location and reads that repo's remote and HEAD before anything else, so a copy in
# /tmp dies at 128/127 on every assertion and the control proves nothing. Absolute,
# because every helper below runs the script from inside $TICKET.
SCRIPT="${EMBERBIRD_CRAVE_RUNNER:-$REPO_ROOT/tools/crave/run-remote-build.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
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
# STUB_LIST_RC, STUB_LIST_JSON_BODY, STUB_LIST_JSON_RC, STUB_LOG_BODY, STUB_LOG_RC and
# the STUB_PULL_* set. Every invocation appends its argv to STUB_ARGV so a test can
# prove which flags the script actually passed.
printf '%s\n' "$*" >> "${STUB_ARGV:?}"
sub="$1"; shift
case "$sub" in
  list)
    # The real client answers `list --jobID <id> --json` with a machine-readable job
    # record instead of the human tables (that probe is how job 303483's real outcome
    # was recovered on 2026-10-05), so the stub has to answer both shapes.
    case " $* " in
      *' --json '*)
        printf '%s' "${STUB_LIST_JSON_BODY:-}"
        exit "${STUB_LIST_JSON_RC:-0}" ;;
    esac
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

# run_watch <expected-exit> <label> [tree] - ONE poll of `watch` (WATCH_ONCE=1).
# It runs against a COPY of the tree (default $FAKE) because a `watch` that reaches
# completion writes image/out/crave-remote-log.txt and then pulls: driving that here
# must not touch this repository's own image/out. STUB_* is exported by the caller.
# The `timeout` is not decoration: against a runner that predates WATCH_ONCE (the
# negative control below does exactly that) `watch` ignores it and polls a stub
# forever, so without the bound this suite would hang instead of reporting red.
run_watch() {
  local want="$1" label="$2" tree="${3:-$FAKE}" rc=0
  WATCH_OUT="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
                  WATCH_INTERVAL=0 WATCH_ONCE=1 WATCH_MAX_MISSES=2 \
                  timeout 20 bash "$tree/tools/crave/run-remote-build.sh" watch 2>&1 )" || rc=$?
  WATCH_RC="$rc"
  if [ "$rc" = "$want" ]; then
    pass "$label (exit $rc)"
  else
    bad "$label: exit $rc, expected $want"
    printf '%s\n' "$WATCH_OUT" | sed 's/^/         /'
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
# The json shape, copied from the real client (job 303483): `list --jobID <id> --json`
# returns every job list as an array, so a finished job appears in "jobs_history" with
# its status, exit code and timings - facts the human tables never carried.
JSON_ACTIVE='{"projects":[],"jobs_active":[{"jobId":777777,"project_name":"LOS 20","status":"running"}],"jobs_history":[],"platforms":[]}'
JSON_FINISHED='{"projects":[],"jobs_active":[],"jobs_history":[{"jobId":777777,"project_name":"LOS 20","status":"done","exitCode":130,"startTime":"2026-10-04T02:29:20.179Z","endTime":"2026-10-04T04:47:38.257Z","job_url":"https://foss.crave.io/app/#/build/info/777777?team=14"}],"platforms":[]}'
JSON_ABSENT='{"projects":[],"jobs_active":[],"jobs_history":[],"platforms":[]}'
# What the client really did on 2026-10-05: its diagnostic on the data stream, exit 0,
# and a complete json document behind it.
JSON_FINISHED_WITH_ERROR="Error: could not get matching git url at: C:/Users/someone
$JSON_FINISHED"
# A job that really did build: the state word `watch` acts on when the log says so.
JSON_SUCCESS='{"projects":[],"jobs_active":[],"jobs_history":[{"jobId":777777,"project_name":"LOS 20","status":"success"}],"platforms":[]}'
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

echo "-- 9. status reads the client's json record (the probe that recovered job 303483)"
# The tables are drawn NOTHING here - exactly what the real client did for hours on
# 2026-10-05 - so every answer below has to come from `list --jobID <id> --json`.
: > "$STUB_ARGV"
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ACTIVE" \
  STUB_LOG_RC=0 run_status 0 "an active job is reported from the json probe alone"
if grep -q -- '^list --jobID 777777 --json$' "$STUB_ARGV"; then
  pass "the json probe is pinned to the job id"
else
  bad "the json probe was not pinned to the job"; sed 's/^/         /' "$STUB_ARGV"
fi
case "$STATUS_OUT" in
  *"777777 is ACTIVE - status 'running'"*) pass "the json status is reported" ;;
  *) bad "the json status was not reported"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac

# The real finished-job record: status, exit code, timings and the job url, none of
# which the human tables ever carried.
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_FINISHED" \
  STUB_LOG_RC=0 run_status 0 "a finished job is reported from the json probe alone"
case "$STATUS_OUT" in
  *"finished - 777777 status 'done', exit code 130"*) pass "the json exit code is reported" ;;
  *) bad "the json exit code was not reported"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac
case "$STATUS_OUT" in
  *"2h18m"*) pass "the json timings are turned into a duration" ;;
  *) bad "the duration was not derived from startTime/endTime"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac
case "$STATUS_OUT" in
  *"job url:   https://foss.crave.io/app/#/build/info/777777?team=14"*) pass "the job url from the json record is shown" ;;
  *) bad "the job url was not shown"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac
case "$STATUS_OUT" in
  *"no job table for this id this time"*) pass "the missing tables are named instead of driving the verdict" ;;
  *) bad "the absent tables were not accounted for"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac

# THE REGRESSION THIS FIX EXISTS FOR: the client's diagnostic rides the same stream as
# a complete json document and it exits 0. The state must still be read out of it - and
# the command must still exit nonzero, because that is not a clean answer.
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_FINISHED_WITH_ERROR" \
  STUB_LOG_RC=0 run_status 1 "error-on-the-stream plus a real json record exits nonzero"
case "$STATUS_OUT" in
  *"finished - 777777 status 'done', exit code 130"*) pass "the state is still read out of the json behind the error" ;;
  *) bad "the json behind the client error was discarded"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac
case "$STATUS_OUT" in
  *"could not get matching git url"*) pass "the client's own diagnostic is still surfaced" ;;
  *) bad "the client diagnostic was swallowed"; printf '%s\n' "$STATUS_OUT" | sed 's/^/         /' ;;
esac

# A json probe that fails outright fails closed, naming the probe.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY='' STUB_LIST_JSON_RC=4 \
        STUB_LOG_RC=0 bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then pass "a failing json probe exits nonzero (rc=$rc)"; else bad "a failing json probe still exited 0"; fi
case "$out" in
  *'crave list --jobID 777777 --json` exited 4'*) pass "the failing json probe is named with its exit code" ;;
  *) bad "the failing json probe was not named"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

# Garbage instead of json must not swallow the tables: the human verdict still stands.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY='not json at all
' STUB_LIST_JSON_RC=0 STUB_LOG_RC=0 bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '777777  LOS 20        running'; then
  pass "unparseable json falls back to the table verdict"
else
  bad "an unparseable json answer cost us the table verdict (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi

# The two probes disagreeing about whether the job exists is not resolved by picking
# one: it is reported and the command fails.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ABSENT" \
        STUB_LIST_JSON_RC=0 STUB_LOG_RC=0 bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "json saying 'no such job' against a table that has it exits nonzero (rc=$rc)"
else
  bad "the disagreement between the two probes was silently resolved"
fi
case "$out" in
  *"DISPUTED"*) pass "the disagreement is named in the report" ;;
  *) bad "the disagreement was not surfaced"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

# Both probes answering is the healthy case: the table corroborates the json.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ACTIVE" \
        STUB_LIST_JSON_RC=0 STUB_LOG_RC=0 bash "$SCRIPT" status 2>&1 )" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  pass "both probes answering agrees and exits 0 (rc=0)"
else
  bad "agreeing probes still exited nonzero (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi
case "$out" in
  *"the human table lists this job too"*) pass "the table is reported as corroboration" ;;
  *) bad "the corroborating table row was not reported"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

echo "-- 10. watch decides completion from the json record too"
# The same blind spot that made `status` unanswerable made `watch` dangerous, because
# `watch` DECIDES COMPLETION from it: with the tables undrawn, a table-only watch could
# see the job leave the queue only by concluding that it had not left, so the first
# poll after the job finished would capture the log and report a verdict - and with no
# stdout retained by the platform (303483) that verdict is whatever the log happened
# to contain. Every answer below has to come from `list --jobID <id> --json`.
: > "$STUB_ARGV"
rm -f "$FAKE/image/out/crave-remote-log.txt"
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ACTIVE" \
  STUB_LOG_BODY='compiling...
Total time: 3m
' run_watch 0 "a job the json calls active keeps being watched, tables or no tables"
case "$WATCH_OUT" in
  *"state=running [json]"*) pass "watch reads the state from the json record" ;;
  *) bad "watch did not read the state from the json"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
if grep -q -- '^list --jobID 777777 --json$' "$STUB_ARGV"; then
  pass "watch pins the json probe to the job id"
else
  bad "watch's json probe was not pinned to the job"; sed 's/^/         /' "$STUB_ARGV"
fi
if [ ! -e "$FAKE/image/out/crave-remote-log.txt" ] && ! grep -q '^pull' "$STUB_ARGV"; then
  pass "a job still running is never treated as finished (no log capture, no pull)"
else
  bad "watch treated a running job as complete while the json said otherwise"
  sed 's/^/         /' "$STUB_ARGV"
fi

# Both probes answering with the same word is the healthy case.
STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ACTIVE" \
  STUB_LOG_BODY='building...
' run_watch 0 "an active table row and the json agree - still watching"

# The real finished job: the verdict comes from the json, with the facts the tables
# never carried, and the log (not the table) still decides success from failure.
rm -f "$FAKE/image/out/crave-remote-log.txt"
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_FINISHED" \
  STUB_LOG_BODY='Build Failed: returned 130
' run_watch 1 "a job the json calls finished is reported as finished, not as a timeout"
case "$WATCH_OUT" in
  *"state=done [json]"*) pass "the terminal state comes from the json record" ;;
  *) bad "the terminal state was not read from the json"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
case "$WATCH_OUT" in
  *"exit code 130"*) pass "the json exit code reaches the failure report" ;;
  *) bad "the json exit code was dropped by watch"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
case "$WATCH_OUT" in
  *"2h18m"*) pass "the json timings reach the failure report" ;;
  *) bad "watch did not report how long the job ran"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
if [ -s "$FAKE/image/out/crave-remote-log.txt" ]; then
  pass "the terminal path still captures the remote log"
else
  bad "no log was captured for a finished job"
fi

# The client's diagnostic on the data stream must not cost the state, and must not be
# mistaken for silence either - the record behind it is complete.
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_FINISHED_WITH_ERROR" \
  STUB_LOG_BODY='Build Failed: returned 130
' run_watch 1 "error-on-the-stream plus a real json record still ends the watch correctly"
case "$WATCH_OUT" in
  *"state=done [json]"*) pass "the state is still read out of the json behind the error" ;;
  *) bad "the json behind the client error was discarded by watch"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
case "$WATCH_OUT" in
  *"could not get matching git url"*) pass "the client's own diagnostic is surfaced by watch" ;;
  *) bad "watch swallowed the client diagnostic"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac

# A json probe that cannot be read costs nothing: the table verdict stands, exactly
# as it did before this probe existed.
STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY='not json at all
' STUB_LIST_JSON_RC=0 STUB_LOG_BODY='building...
' run_watch 0 "an unparseable json answer falls back to the table verdict"
case "$WATCH_OUT" in
  *"state=running [table]"*) pass "watch says which probe it believed" ;;
  *) bad "the fallback was not taken (or not reported)"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac

# THE DIRECTION THAT MATTERS MOST: the two probes disagree, and neither may be
# resolved into a completion. json says it is done, the table still says running -
# the table-only loop would have read "running" and polled forever, but resolving the
# other way would declare a running build finished. So watch reports and waits.
: > "$STUB_ARGV"
rm -f "$FAKE/image/out/crave-remote-log.txt"
STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_FINISHED" \
  STUB_LOG_BODY='compiling...
' run_watch 1 "json says finished, the table says running -> disputed, not completed"
case "$WATCH_OUT" in
  *"DISPUTED"*) pass "the disagreement is named" ;;
  *) bad "the disagreement was not surfaced"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
if [ ! -e "$FAKE/image/out/crave-remote-log.txt" ] && ! grep -q '^pull' "$STUB_ARGV"; then
  pass "a disputed state is never acted on (no capture, no pull)"
else
  bad "watch acted on a state the probes contradict"
fi
# And the mirror image, which is the false-completion trap: json says running while
# the table has already dropped it into Job History.
STUB_LIST_BODY="$HISTORY_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ACTIVE" \
  STUB_LOG_BODY='compiling...
' run_watch 1 "json says running, the table says finished -> disputed, not completed"
if [ ! -e "$FAKE/image/out/crave-remote-log.txt" ]; then
  pass "watch kept watching a job the history table had finished"
else
  bad "watch accepted the history table's 'finished' over the json's 'running'"
fi

# json saying "no such job" against a table that still lists it is a disagreement too.
: > "$STUB_ARGV"
STUB_LIST_BODY="$ACTIVE_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ABSENT" \
  STUB_LIST_JSON_RC=0 STUB_LOG_BODY='compiling...
' run_watch 1 "json saying 'no such job' against a table that has it -> disputed"
case "$WATCH_OUT" in
  *"DISPUTED"*) pass "the missing-job disagreement is named, not silently resolved" ;;
  *) bad "the disagreement was not surfaced"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac

# "No record of this job anywhere" is neither silence nor a completion: waiting is the
# only safe answer, and it is bounded rather than endless.
: > "$STUB_ARGV"
STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_ABSENT" \
  STUB_LIST_JSON_RC=0 STUB_LOG_BODY='' run_watch 1 "a job the client has no record of is waited on, then reported"
case "$WATCH_OUT" in
  *"state=unseen"*) pass "the absent-record case is its own state, not 'finished'" ;;
  *) bad "an absent record was reported as a completion"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
case "$WATCH_OUT" in
  *"no record of job 777777"*) pass "the absent-record case names the job it is about" ;;
  *) bad "the absent-record report does not name the job"; printf '%s\n' "$WATCH_OUT" | sed 's/^/         /' ;;
esac
if ! grep -q '^pull' "$STUB_ARGV"; then
  pass "an absent record never triggers a pull"
else
  bad "watch pulled on the strength of an absent record"
fi

# Genuine silence still gives up - the guard the json probe does not replace, because
# a client that answers nothing is a different failure from one that answers wrongly.
# Driven without WATCH_ONCE (the counter needs a second poll to reach its bound),
# with WATCH_MAX_MISSES=2 and no sleep, so it costs milliseconds.
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        WATCH_INTERVAL=0 WATCH_MAX_MISSES=2 \
        STUB_LIST_BODY='' STUB_LIST_RC=0 STUB_LIST_JSON_BODY='' STUB_LIST_JSON_RC=0 \
        STUB_LOG_BODY='' timeout 20 bash "$FAKE/tools/crave/run-remote-build.sh" watch 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then pass "a client that answers nothing is still bounded (rc=$rc)"; else bad "silence was not bounded"; fi
case "$out" in
  *"answered nothing 2 times in a row"*) pass "the give-up guard still fires on real silence, naming the bound it reached" ;;
  *) bad "silence was not bounded (or the bound was not named)"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac
case "$out" in
  *"state=unknown"*) pass "an unanswered poll reports unknown, never finished" ;;
  *) bad "silence was reported as something else"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac

# And the happy path, end to end: a successful job captured and pulled, exactly as
# before - run against the pull fixture so the artifacts land in FAKE2.
: > "$STUB_ARGV"
rm -f "$FAKE2/image/out/crave-remote-log.txt"
mkdir -p "$TICKET/eb/image/out"
out="$( cd "$TICKET" && JOB=777777 TICKET_DIR="$TICKET" CRAVE_SHIM="$STUB" \
        WATCH_INTERVAL=0 WATCH_ONCE=1 WATCH_MAX_MISSES=2 \
        STUB_LIST_BODY="$NO_TABLE" STUB_LIST_RC=0 STUB_LIST_JSON_BODY="$JSON_SUCCESS" \
        STUB_LOG_BODY='[100%] Build Successful
' STUB_PULL_DIR="$TICKET/eb/image/out" STUB_PULL_RECORD=1 STUB_PULL_REVISION="$FIXREV" \
        timeout 20 bash "$FAKE2/tools/crave/run-remote-build.sh" watch 2>&1 )" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  pass "a successful job is captured and pulled (exit 0)"
else
  bad "the watch happy path failed (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/         /'
fi
case "$out" in
  *"state=success [json]"*) pass "watch saw the success in the json record, not the table" ;;
  *) bad "watch did not read the success state from the json"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac
case "$out" in
  *"Build Successful"*) pass "the log really was captured before the pull" ;;
  *) bad "the log capture step did not run"; printf '%s\n' "$out" | sed 's/^/         /' ;;
esac
if grep -q -- '--job 777777' "$STUB_ARGV" && [ -f "$FAKE2/image/out/x2-provenance.json" ]; then
  pass "the artifact and its X2 record landed in the repo, from a pinned pull"
else
  bad "watch's pull was unpinned or never ran"; sed 's/^/         /' "$STUB_ARGV"
fi

echo
if [ "$fail" = 0 ]; then
  echo "crave run-remote-build.sh offline test: PASS"
else
  echo "crave run-remote-build.sh offline test: FAIL"
  exit 1
fi