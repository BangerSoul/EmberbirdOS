#!/usr/bin/env bash
# EmberbirdOS - launch the M2 X2 guest build on Crave, then pull the results back.
#
# WHY THERE IS A SCRIPT FOR THIS
#   Crave resolves the project *from the git URL of the current directory*. This
#   repository's URL is not a Crave project, so running `crave run` from a plain checkout
#   fails with:
#
#     Error: could not get project information for <this repo>
#
#   (A project is not needed and is deliberately not created: M2's provenance anchor is
#   the X1 lock, not a Crave project. The base project is only a container.)
#
#   So the job is launched from a throwaway checkout - a "ticket" - whose origin IS the
#   base project's source URL, and the job bootstraps this repository inside the remote
#   workspace at the exact commit you are standing on. That keeps the build reproducible
#   from any machine with the client and an API key.
#
# USAGE
#   bash tools/crave/run-remote-build.sh run      # launch (default), detached
#   bash tools/crave/run-remote-build.sh status   # queue state + tail of the log
#   bash tools/crave/run-remote-build.sh log      # full remote log
#   bash tools/crave/run-remote-build.sh watch    # poll until the job runs, then pull
#   bash tools/crave/run-remote-build.sh pull     # fetch image/out/* back into this repo
#   bash tools/crave/run-remote-build.sh stop     # stop the job on this workspace
#
# `status`, `log` and `pull` are all PINNED to a job id ($JOB, else the record `run`
# wrote to image/out/crave-job.txt) and all EXIT NONZERO when the client cannot answer
# or answers with an error on its data stream: "I could not look" must never print as
# "nothing is wrong". See the status block below and docs/M2-CRAVE-BUILD.md for the
# failure history that forced each of these.
#
# `watch` exists because a free-queue job can sit `queued` for a long time waiting for a
# build node (observed 2026-09-24 on linux16 - the free queue costs no tokens, it is just
# a wait for capacity), and a multi-hour sync+build follows even once it starts. It polls,
# records the state, and pulls the artifact the moment the job reports success - see WATCH_INTERVAL.
#
# TUNABLES (env)
#   CRAVE_PROJECT_ID     default 36 (LOS 20 - Crave's Android 13 AOSP base)
#   CRAVE_PROJECT_NAME   default "LOS 20"
#   CRAVE_PROJECT_URL    default https://github.com/accupara/los20.git
#   CRAVE_PLATFORM       default linux16  (the only capable platform project 36 accepts;
#                                          see docs/M2-CRAVE-BUILD.md for the probe matrix)
#   COMMIT               default: current HEAD of this checkout (pinned into the job)
#   TICKET_DIR           default $TEMP/crave-ticket-<project name slug>  (e.g. "LOS 20"
#                        -> crave-ticket-los20). Keyed to the PROJECT, not a bare id, and
#                        stable per project so the client's Workspace-Dir-derived build
#                        cache is not silently reset between runs (more-info.md lists
#                        Workspace Dir as one of the 4 things that reset build storage).
#   ATTACH=1             stream the build in the foreground instead of detaching
#   JOB                  job id to watch (default: read from image/out/crave-job.txt)
#   WATCH_INTERVAL       seconds between polls in `watch` mode (default 300)
#
# WORKSPACE SCOPING (observed 2026-09-24): the client resolves getlog/pull against the
# CURRENT DIRECTORY's workspace, and that resolution returned "No running job found on
# this workspace" even when run from the job's own registered ticket dir while `list`
# still showed the job queued. So every log/artifact access in `watch`/`pull`/`log` is
# PINNED with an explicit --jobID/--job (resolved from $JOB or image/out/crave-job.txt),
# which the client honors regardless of cwd. TICKET_DIR still matters for `pull` (it is
# the local staging root the remote eb/image/out/ lands in before the copy into the repo).
#
# Everything goes through tools/crave/crave.sh, so the client's broken self-update path
# (docs/CRAVE-CLIENT-UPDATE-LOOP.md) is never entered.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Overridable so the offline suite can drive every subcommand against a stub client
# (tools/checks/test-crave-remote-build.sh). Same convention as crave.sh's CRAVE_BIN.
CRAVE_SHIM="${CRAVE_SHIM:-$REPO_ROOT/tools/crave/crave.sh}"

CRAVE_PROJECT_ID="${CRAVE_PROJECT_ID:-36}"
CRAVE_PROJECT_NAME="${CRAVE_PROJECT_NAME:-LOS 20}"
CRAVE_PROJECT_URL="${CRAVE_PROJECT_URL:-https://github.com/accupara/los20.git}"
CRAVE_PLATFORM="${CRAVE_PLATFORM:-linux16}"
# Ticket dir keyed to the project NAME (slug), not the bare id: prior real runs used
# crave-ticket-los20 while the id-based default was crave-ticket-36, and that drift alone
# resets the build cache. A slug is stable per project and moves WITH a project switch
# (a different project has a different Project UUID, so its cache is separate anyway).
project_slug() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }
TICKET_SLUG="$(project_slug "$CRAVE_PROJECT_NAME")"
[ -n "$TICKET_SLUG" ] || TICKET_SLUG="id${CRAVE_PROJECT_ID}"
TICKET_DIR="${TICKET_DIR:-${TEMP:-${TMPDIR:-/tmp}}/crave-ticket-${TICKET_SLUG}}"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# The job id every getlog/pull is pinned with: explicit $JOB wins, else the record the
# `run` command wrote (image/out/crave-job.txt). Empty output means "unknown".
job_record() {
  if [ -n "${JOB:-}" ]; then printf '%s' "$JOB"; return; fi
  [ -f "$REPO_ROOT/image/out/crave-job.txt" ] || return 0
  python3 - "$REPO_ROOT/image/out/crave-job.txt" <<'PY' 2>/dev/null || true
import json, re, sys
raw = open(sys.argv[1]).read()
m = re.search(r'"jobid"\s*:\s*(\d+)', raw) or re.search(r'(\d{4,})', raw)
print(m.group(1) if m else '', end='')
PY
}

[ -f "$CRAVE_SHIM" ] || die "missing $CRAVE_SHIM"

# Crave rule (crave/rules.md, Queue Rules): "Do not Queue multiple builds at once: one
# account can only trigger one build at once." Breaking it is how 301689->301767 and the
# zombie-watcher pile-ups happened. `crave list` prints a clean "Your active jobs:" table
# (Job Id | Project Name | Job Status | Local Workspace | Job Url) that lists ONLY jobs
# that are still queued/running - finished jobs drop to "Job History:". So the guard is
# simply: is that table non-empty? Return the active rows (id + status), empty if none.
# Total (never aborts the caller under set -e): a flaky client reads as "no answer", which
# we treat conservatively as "cannot confirm" rather than "clear to launch".
active_jobs() {
  ( cd "$TICKET_DIR" 2>/dev/null && bash "$CRAVE_SHIM" list 2>/dev/null | tr -d '\r' \
      | awk '
          /^Your active jobs:/ { insec=1; next }
          insec && /^[A-Za-z].*:[[:space:]]*$/ { insec=0 }        # next section header ends it
          insec && $1 ~ /^[0-9]+$/ {
            # Project Name can contain spaces ("LOS 20"), so a fixed column index is
            # wrong (it reads "20"). Scan the row for a known status word instead.
            st="active"
            for (i=2; i<=NF; i++)
              if ($i ~ /^(queued|pending|starting|running|building|syncing)$/) { st=$i; break }
            print $1 "  " st
          }
        ' ) || true
}

repo_url="$(git -C "$REPO_ROOT" remote get-url origin)"
branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
COMMIT="${COMMIT:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
cmd="${1:-run}"
# A window into a private repo would fail remotely; fail loudly here instead.
# Scoped to `run`, because that is the only command that launches anything: refusing
# to show the status of a job that already ran, just because this checkout's origin
# is unreachable, is the wrong trade. It also keeps every read-only subcommand
# offline, which is what lets the test suite drive them against a stub.
if [ "$cmd" = "run" ]; then
  git -C "$REPO_ROOT" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1 \
    || die "origin/$branch is not reachable - push before launching a build from it"
fi

# ------------------------------------------------------------------ the ticket ----
# A checkout whose origin is the base project's URL: that is what makes `crave run`
# resolve project $CRAVE_PROJECT_ID. Deliberately outside this repository, so the client
# cannot walk up into it and resolve *our* (unregistered) remote instead.
ensure_ticket() {
  if [ -d "$TICKET_DIR/.git" ]; then
    log "refreshing the ticket checkout ($TICKET_DIR)"
    git -C "$TICKET_DIR" fetch --depth=1 -q origin "refs/heads/$(git -C "$TICKET_DIR" rev-parse --abbrev-ref HEAD)" 2>/dev/null || true
    git -C "$TICKET_DIR" pull --ff-only -q 2>/dev/null || true
  else
    log "creating the ticket checkout ($TICKET_DIR)"
    rm -rf "$TICKET_DIR"
    git clone --depth=1 -q "$CRAVE_PROJECT_URL" "$TICKET_DIR"
  fi
  install_project_yaml
  printf 'ticket origin: %s\n' "$(git -C "$TICKET_DIR" remote get-url origin)"
}

# crave.yaml install - do NOT blindly clobber the base project's own file.
#
# Three problems the old `cp -f crave.yaml` had:
#   1. It overwrote whatever crave.yaml the base project ships (a real risk: its config
#      keys env:/image:/push: for the *build node*, which we must not silently discard).
#   2. Our file is keyed by project NAME ("LOS 20"). Crave matches the block by the
#      dashboard project name, so on a project switch (e.g. --projectID 93 = LOS 22.1)
#      the "LOS 20" block never applies and the ignoreClientHostname/no-patch overrides
#      vanish with no warning - exactly what happened on the 301767 run.
#   3. more-info.md: for repo-based trees the file's real home is
#      [Workspace Dir]/.repo/manifests/crave.yaml, not the checkout top.
#
# So: (a) fail loudly if our overrides are not keyed to the project we are launching, and
# (b) MERGE our keys into the base project's file (preserving its own top-level keys and
# any per-project block) rather than overwriting it, writing to whichever location the
# tree actually uses (.repo/manifests if present, else the top).
install_project_yaml() {
  local ours="$REPO_ROOT/crave.yaml"
  [ -f "$ours" ] || { printf 'note: no repo crave.yaml to install (skipping)\n'; return 0; }

  # Guard: our overrides must be keyed to the project name we are actually launching.
  # A silent name/id mismatch is what drops the overrides on a project switch.
  if ! python3 - "$ours" "$CRAVE_PROJECT_NAME" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[0+1], encoding='utf-8')) or {}
name = sys.argv[2]
sys.exit(0 if isinstance(doc, dict) and name in doc else 1)
PY
  then
    die "crave.yaml has no '$CRAVE_PROJECT_NAME' block - its overrides would silently not apply to project $CRAVE_PROJECT_ID. Set CRAVE_PROJECT_NAME to match a keyed block, or add one to $ours."
  fi

  # Destination: repo-based trees keep it under .repo/manifests (more-info.md); a plain
  # manifest/source checkout keeps it at the top.
  local dest="$TICKET_DIR/crave.yaml"
  [ -d "$TICKET_DIR/.repo/manifests" ] && dest="$TICKET_DIR/.repo/manifests/crave.yaml"

  # Merge (never clobber): base file's keys are the floor; ours win only on the keys we
  # actually set (settings.projects + our per-project block). Anything the base project
  # defines that we don't touch is preserved verbatim.
  python3 - "$ours" "$dest" "$CRAVE_PROJECT_NAME" <<'PY'
import sys, os, yaml

ours_path, dest_path, project = sys.argv[1], sys.argv[2], sys.argv[3]
ours = yaml.safe_load(open(ours_path, encoding='utf-8')) or {}
base = {}
if os.path.exists(dest_path):
    base = yaml.safe_load(open(dest_path, encoding='utf-8')) or {}
if not isinstance(base, dict):
    base = {}

merged = dict(base)

# settings.projects: union, preserving base order then appending ours.
ours_settings = (ours.get('settings') or {}) if isinstance(ours.get('settings'), dict) else {}
base_settings = (merged.get('settings') or {}) if isinstance(merged.get('settings'), dict) else {}
our_projects = ours_settings.get('projects') or []
base_projects = base_settings.get('projects') or []
seen, projects = set(), []
for p in list(base_projects) + list(our_projects):
    if p not in seen:
        seen.add(p); projects.append(p)
if projects:
    merged_settings = dict(base_settings)
    merged_settings['projects'] = projects
    merged['settings'] = merged_settings

# Our per-project override block wins for the keys we set, but merges over any block the
# base project already defines for the same name (so base's own keys survive).
if project in ours and isinstance(ours[project], dict):
    block = dict(merged.get(project) or {}) if isinstance(merged.get(project), dict) else {}
    block.update(ours[project])
    merged[project] = block

os.makedirs(os.path.dirname(dest_path) or '.', exist_ok=True)
with open(dest_path, 'w', encoding='utf-8', newline='\n') as f:
    if base:
        f.write('# MERGED by tools/crave/run-remote-build.sh: base project keys preserved,\n')
        f.write('# EmberbirdOS overrides layered on top (do not hand-edit - regenerated per run).\n')
    yaml.safe_dump(merged, f, default_flow_style=False, sort_keys=False)
print('crave.yaml -> %s (%s)' % (dest_path, 'merged over base' if base else 'installed'))
PY
}

# --------------------------------------------------------- the remote command ----
# Checkout this exact commit, then hand over to the one build recipe.
remote_cmd() {
  cat <<EOF
bash -lc '
set -x
echo "--- host probe (recorded for the X2 record) ---"
nproc; free -g | head -3; df -h .; df -h \$HOME
command -v git python3 curl
echo "--- bootstrap EmberbirdOS @ $COMMIT ---"
# Crave rule (crave/rules.md): do not make a folder and sync inside that to avoid
# conflicts (i.e. never cd into a subfolder before syncing). repo searches UPWARD for
# an existing .repo, and the Crave workspace root IS itself a repo checkout - so the
# sync must run AT that root, never from a folder created beneath it. Capture the root
# here, before cd-ing into the source checkout, and hand it to the recipe as WORKSPACE.
# (No backticks below: this heredoc is unquoted, so backticks would be executed.)
ROOT="\$PWD"
rm -rf eb
git init -q eb && cd eb
git remote add origin $repo_url
if ! git fetch --depth=1 -q origin $COMMIT; then
  echo "note: fetch-by-sha refused by the remote; falling back to the branch tip"
  git fetch --depth=1 -q origin refs/heads/$branch
fi
git checkout -q FETCH_HEAD
echo "building commit: \$(git rev-parse HEAD)  branch: $branch"
echo "sync root (owns .repo): \$ROOT"
WORKSPACE="\$ROOT" bash tools/guest-build/build-from-manifest.sh
'
EOF
}

case "$cmd" in
  run)
    ensure_ticket
    # One build at a time (Crave Queue Rule). Refuse if this account already has a job
    # queued or running. FORCE=1 overrides (e.g. you have just stopped the old job and
    # the table has not refreshed yet), and it is loud about doing so.
    active="$(active_jobs)"
    if [ -n "$active" ]; then
      if [ -n "${FORCE:-}" ]; then
        log "FORCE=1: launching despite an already-active job:"
        printf '%s\n' "$active" | sed 's/^/  active: /'
      else
        printf '%s\n' "$active" | sed 's/^/  active: /' >&2
        die "an account can only run one build at a time (crave/rules.md). Stop the active job first (bash tools/crave/run-remote-build.sh stop) or re-run with FORCE=1 if you know it is already stopping."
      fi
    fi
    log "launching: project $CRAVE_PROJECT_NAME (id $CRAVE_PROJECT_ID), platform $CRAVE_PLATFORM"
    printf 'recipe commit: %s (%s)\n' "$COMMIT" "$branch"
    if [ -n "${ATTACH:-}" ]; then
      cd "$TICKET_DIR"
      exec bash "$CRAVE_SHIM" run --projectID "$CRAVE_PROJECT_ID" --platform "$CRAVE_PLATFORM" \
        --no-patch --no-artifacts \
        --message "M2 X2: EmberbirdOS guest from pinned X1 lock @ $COMMIT" \
        -- "$(remote_cmd)"
    else
      mkdir -p "$REPO_ROOT/image/out"
      ( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" run --projectID "$CRAVE_PROJECT_ID" \
          --platform "$CRAVE_PLATFORM" --detached --json --no-patch --no-artifacts \
          --message "M2 X2: EmberbirdOS guest from pinned X1 lock @ $COMMIT" \
          -- "$(remote_cmd)" ) | tee "$REPO_ROOT/image/out/crave-job.txt"
      echo
      echo "watch:  bash tools/crave/run-remote-build.sh status"
      echo "log:    bash tools/crave/run-remote-build.sh log"
      echo "pull:   bash tools/crave/run-remote-build.sh pull"
    fi
    ;;

  status)
    # WHY THIS WAS REWRITTEN (it used to be three lines and told you nothing)
    #   1. `sed -n '/Your jobs/,$p'` matched no header the client has ever printed.
    #      The real ones are "Your active jobs:" and "Job History:" - so the queue
    #      state was always empty, and an empty table looks exactly like "nothing to
    #      report" rather than "the parse found nothing".
    #   2. `getlog` carried no --jobID. Everywhere else in this script every log and
    #      pull access is pinned (see WORKSPACE SCOPING at the top); unpinned, the
    #      client resolves against the current directory's workspace and answers
    #      "No running job found on this workspace" - which is how a healthy job
    #      comes to look dead.
    #   3. It exited 0 even when every client call failed. A `status` that cannot
    #      reach the API must not report success: that is the difference between
    #      "the job is gone" and "I could not look".
    #
    # The client's diagnostics arrive on the SAME stream as its data and it does not
    # always set a nonzero status - observed `list` printing
    #   Error: could not get matching git url at: C:/Users/<you>
    # and still exiting 0. So each probe is judged on BOTH its exit status and its
    # text, and any failure makes this command exit nonzero with the reason named.
    ensure_ticket >/dev/null
    j="$(job_record)"
    [ -n "$j" ] || die "no job id: set JOB=<id>, or run 'run' first so image/out/crave-job.txt exists"
    log "status for job $j ($CRAVE_PROJECT_NAME, project $CRAVE_PROJECT_ID)"
    rc=0

    # ---- queue state, from the table, for OUR job id only ----
    if list_out="$( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" list 2>&1 | tr -d '\r' )"; then
      list_rc=0
    else
      list_rc=$?; rc=1
    fi
    if printf '%s\n' "$list_out" | grep -qE '^(Error|FATAL):'; then
      printf '  client error: %s\n' "$(printf '%s\n' "$list_out" | grep -m1 -E '^(Error|FATAL):')"
      rc=1
    fi
    if [ "$list_rc" -ne 0 ]; then
      printf '  client error: `crave list` exited %s\n' "$list_rc"
    fi
    # Section-aware: both real headers, and any other "Word:" heading ends the
    # current table so a project/platform table can never be read as a job row.
    row="$(printf '%s\n' "$list_out" | awk -v j="$j" '
        /^Your active jobs:/ { sec = "active";  next }
        /^Job History:/     { sec = "history"; next }
        /^[A-Za-z][A-Za-z ]*:[[:space:]]*$/ { sec = "" }
        sec && $1 == j { print sec "\t" $0; exit }
    ')"
    # Split section from row BEFORE formatting: piping the formatted line through
    # `cut -f2-` drops the field the prefix belongs to, silently deleting "queue:".
    row_sec="${row%%$'\t'*}"
    row_txt="${row#*$'\t'}"
    case "$row_sec" in
      active)
        printf '  queue:    %s\n' "$row_txt" ;;
      history)
        printf '  queue:    finished - %s\n' "$row_txt" ;;
      '')
        # "not in either table" and "the client never drew one" are different facts
        # and must not be reported the same way.
        if printf '%s\n' "$list_out" | grep -qE '^(Your active jobs:|Job History:)'; then
          printf '  queue:    job %s is in neither table - it has left the queue\n' "$j"
        else
          printf '  queue:    the client returned NO job table at all (it answered with projects/platforms only) - the state of job %s is UNKNOWN\n' "$j"
        fi ;;
    esac

    # ---- log tail, PINNED to the job ----
    if log_out="$( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" getlog --projectID "$CRAVE_PROJECT_ID" --jobID "$j" 2>&1 | tr -d '\r' )"; then
      log_rc=0
    else
      log_rc=$?; rc=1
    fi
    if [ "$log_rc" -ne 0 ]; then
      printf '  client error: `crave getlog --jobID %s` exited %s\n' "$j" "$log_rc"
      rc=1
    fi
    printf '  log tail:\n'
    printf '%s\n' "$log_out" | tail -25 | sed 's/^/    /'
    [ "$rc" -eq 0 ] || printf '  (status could not be fully determined - see the client errors above)\n'
    exit "$rc"
    ;;

  log)
    # The same two defects `status` had (see the status block for the full story):
    # an unpinned `getlog` fallback when no job id was found, and no judgement of
    # what the client printed. `log` is what you reach for when `status` says the
    # job failed - it must never answer with whichever job the current directory
    # happens to resolve to, and it must never present a client error as a build
    # log. It streams whatever it got either way: a client error message IS the
    # most useful thing to show an operator who asked for a log.
    ensure_ticket >/dev/null
    j="$(job_record)"
    [ -n "$j" ] || die "no job id: set JOB=<id>, or run 'run' first so image/out/crave-job.txt exists"
    log "log for job $j ($CRAVE_PROJECT_NAME, project $CRAVE_PROJECT_ID)"
    rc=0
    if out="$( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" getlog --projectID "$CRAVE_PROJECT_ID" --jobID "$j" 2>&1 | tr -d '\r' )"; then
      :
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'client error: `crave getlog --projectID %s --jobID %s` exited %s\n' "$CRAVE_PROJECT_ID" "$j" "$rc" >&2
      rc=1
    fi
    # The client's diagnostics ride the same stream as its data and it does not
    # reliably set a nonzero status (observed: "Error: could not get matching git
    # url ..." with exit 0). A column-0 Error:/FATAL: line is therefore treated as
    # a client diagnostic - the same heuristic `status` applies to the tables. The
    # worst case is a false alarm on build output that opens a line that way; the
    # log is printed either way, and erring toward "do not trust this output" is
    # the direction that has been right every time so far.
    if printf '%s\n' "$out" | grep -qE '^(Error|FATAL):'; then
      printf 'client error: %s\n' "$(printf '%s\n' "$out" | grep -m1 -E '^(Error|FATAL):')" >&2
      rc=1
    fi
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
      printf '(exit nonzero: the client could not fully answer - see the client errors above)\n' >&2
    fi
    exit "$rc"
    ;;

  pull)
    # Same treatment as status/log (see the status block): pin the job, refuse
    # without one, and judge the client on its exit status AND its text. A pull
    # that failed must also never fall through into the copy + verify steps below:
    # those would hash whatever the PREVIOUS pull left in the ticket and present
    # it as this job's record - the artifact-level version of the self-witnessing
    # the revision audit used to do.
    ensure_ticket >/dev/null
    j="$(job_record)"
    [ -n "$j" ] || die "no job id: set JOB=<id>, or run 'run' first so image/out/crave-job.txt exists"
    log "pulling eb/image/out/ (job $j) from the remote workspace into $REPO_ROOT/image/out"
    # Start from nothing: if the pull fails or brings nothing back, the directory
    # check below must report that, not find the last job's leftovers.
    rm -rf "$TICKET_DIR/eb/image/out"
    rc=0
    if out="$( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" pull --projectID "$CRAVE_PROJECT_ID" --job "$j" eb/image/out/ 2>&1 | tr -d '\r' )"; then
      :
    else
      rc=$?
    fi
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
      die "client error: \`crave pull --projectID $CRAVE_PROJECT_ID --job $j\` exited $rc - nothing was pulled; check 'status' before retrying"
    fi
    if printf '%s\n' "$out" | grep -qE '^(Error|FATAL):'; then
      die "client error: $(printf '%s\n' "$out" | grep -m1 -E '^(Error|FATAL):') - the client exited 0 but reported an error; nothing was pulled"
    fi
    src="$TICKET_DIR/eb/image/out"
    if [ -d "$src" ]; then
      mkdir -p "$REPO_ROOT/image/out"
      cp -f "$src"/* "$REPO_ROOT/image/out/" 2>/dev/null || true
      ls -l "$REPO_ROOT/image/out"
      echo
      echo "X2 record: $REPO_ROOT/image/out/x2-provenance.json"
      # Verify the pulled bytes against the record here, while the operator is
      # looking at this output. It used to be a printed instruction to re-hash by
      # hand, which is precisely the step that silently did not happen.
      if python3 "$REPO_ROOT/tools/manifest/verify-x2-provenance.py"; then
        echo
        echo "verified against the record - commit it as"
        echo "docs/evidence/M2/x2-artifact-provenance.json and fill in the M2 appendix row."
      else
        die "the pulled artifacts do NOT match x2-provenance.json - do not cite this record as X2 evidence (see above)"
      fi
    else
      die "remote pull produced no $src - has the build finished? (bash tools/crave/run-remote-build.sh status)"
    fi
    ;;

  stop)
    ensure_ticket >/dev/null
    ( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" stop --force )
    ;;

  watch)
    # Crave reports the outcome only in the job log, so completion is "the job is no
    # longer queued or running": then the log decides between success and failure, and a
    # success is followed straight through to the pull.
    ensure_ticket >/dev/null
    JOB="$(job_record)"
    [ -n "$JOB" ] || die "no job id: set JOB=<id>, or run 'run' first so image/out/crave-job.txt exists"
    interval="${WATCH_INTERVAL:-300}"
    # A long wait must not be ended by one flaky poll: under `set -e` a non-zero result
    # from either probe would abort the whole watch silently, which is exactly how an
    # artifact gets missed. Both readers are therefore total - they swallow failure and
    # report "unknown" instead, and the loop keeps its own count of consecutive failures.
    # The active-jobs table is "Id  Workspace  Commands...  Status". The Commands
    # column holds the multi-line `bash -lc '...'` payload, so a fixed column index
    # reads the command text (observed: state="-lc") and never the status - the job
    # then looks permanently in-flight and completion is missed. Take the last field,
    # and accept it only if it is a known status word.
    read_state() {
      ( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" list 2>/dev/null | tr -d '\r' | awk -v j="$JOB" '
          $1==j {
            for (i=NF; i>=1; i--)
              if ($i ~ /^(queued|pending|starting|running|failed|success|succeeded|successful|complete|completed|cancelled|canceled|stopped|error|timeout|timedout)$/) { print $i; exit }
            print "unknown"; exit
          }' ) || true
    }
    read_last() {
      ( cd "$TICKET_DIR" && timeout 90 bash "$CRAVE_SHIM" getlog --projectID "$CRAVE_PROJECT_ID" --jobID "$JOB" 2>/dev/null | tr -d '\r' | tail -1 ) || true
    }
    misses=0
    log "watching job $JOB every ${interval}s"
    while :; do
      state="$(read_state)"
      last="$(read_last)"
      if [ -z "$state" ] && [ -z "$last" ]; then
        misses=$(( misses + 1 ))
        printf '%s  job=%s  state=unknown  (no answer from the client; miss %s)\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB" "$misses"
        [ "$misses" -lt 10 ] || die "the client answered nothing 10 times in a row - giving up rather than reporting a false completion"
        sleep "$interval"
        continue
      fi
      misses=0
      printf '%s  job=%s  state=%s  | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB" "${state:-<left queue>}" "$last"
      # Still active -> keep polling. Anything else is terminal: a named end state, or
      # the job having left the active-jobs table entirely (state empty while the
      # client DID answer, so this is not the "no answer" case handled above).
      case "$state" in
        queued|pending|starting|running) sleep "$interval"; continue ;;
      esac
      log "job $JOB is no longer active (state=${state:-<left queue>}) - capturing the remote log"
      ( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" getlog --projectID "$CRAVE_PROJECT_ID" --jobID "$JOB" ) > "$REPO_ROOT/image/out/crave-remote-log.txt" 2>&1 || true
      if grep -qi 'build successful' "$REPO_ROOT/image/out/crave-remote-log.txt"; then
        log "remote build reported success - pulling the artifact and the X2 record"
        bash "$REPO_ROOT/tools/crave/run-remote-build.sh" pull
      else
        die "job $JOB ended in state '${state:-unknown}' without 'Build Successful'; see image/out/crave-remote-log.txt"
      fi
      break
    done
    ;;

  *) die "unknown command '$cmd' (run|status|log|watch|pull|stop)" ;;
esac
