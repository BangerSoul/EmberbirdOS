#!/usr/bin/env bash
# Offline exercise of the recipe's revision_audit() against a synthetic lock and a
# synthetic synced tree. Each scenario changes exactly one thing from the clean
# baseline, so a failure points at one behaviour:
#   1. clean tree audits OK (exit 0), notdefault projects excluded;
#   2. a checkout at the wrong SHA is a MISMATCH (exit 3), naming the path;
#   3. a directory with no .git is MISSING (exit 3);
#   4. a tag-pinned project whose tag has moved past HEAD is a MISMATCH;
#   5. repairing every drift audits clean again;
#   6. two projects sharing ONE tag, each on its own target, are BOTH clean;
#   7. sanitize_worktrees() clears local modifications/untracked files that would
#      make the forced re-sync's checkout abort;
#   8. sanitize_worktrees() survives a checkout whose HEAD never landed;
#   9. a stubbed `repo manifest -r` CORROBORATES the audit and never decides it -
#      in particular, a witness that faithfully reports a drifted tree still yields
#      MISMATCH (the job 303324 regression, and the reason the lock is the only
#      yardstick).
# WHY: job 302748 (2026-09-30) died at `lunch` because the Crave node's pre-seeded
# tree held ~1000 lock paths at LOS 20 revisions while every other check in the
# recipe reasoned about existence and files only. Job 302857 (2026-10-01) then died
# mid-re-sync: the pre-seeded image ships prebuilts/clang/host/linux-x86 with
# locally-modified tracked files, and a forced checkout refuses to overwrite them
# ("Your local changes ... would be overwritten by checkout"), so one dirty
# worktree failed a 1063-project re-sync.
# Scenario 6 covers the trap behind that count: AOSP release tags are per-
# repository commits and 872 of this lock's 1175 active projects pin
# refs/tags/android-12.1.0_r22, so an audit that resolves a tag inside one project
# and then compares every project sharing it against that single commit reports
# hundreds of phantom drifts - and, because no sync can make one repository's tag
# resolve to another's commit, it can then never pass its own re-audit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib-audit.sh
source "$HERE/lib-audit.sh"
# Fixtures below create revisions. Most environments can; a sandboxed one may refuse
# that subcommand, in which case lib-fixtures.sh installs a plumbing-backed shim so
# the suite still audits a real tree instead of a field of unborn HEADs.
# shellcheck source=lib-fixtures.sh
source "$HERE/lib-fixtures.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
emberbird_ensure_git_record "$T" || {
  echo "FATAL: cannot obtain a git that records revisions; fixtures would be meaningless" >&2
  exit 1
}
printf '== fixtures (git that records revisions: %s) ==\n' "$EMBERBIRD_GIT_RECORD"
export WORKSPACE="$T/ws" LOCK_XML="$T/lock.xml"

fail=0
run() { # $1 = expected exit, $2 = report file, $3.. = extra args to revision_audit
  local want="$1" rep="$2" rc
  shift 2
  set +e
  revision_audit "$rep" "$@"
  rc=$?
  set -e
  if [ "$rc" = "$want" ]; then
    echo "  [PASS] audit exits $rc as expected"
  else
    echo "  [FAIL] audit exit $rc, expected $want (report head: $(head -1 "$rep" 2>/dev/null))"
    fail=1
  fi
}

gitrepo() { # $1 = path under ws, $2 = optional message; prints the resulting HEAD sha
  mkdir -p "$WORKSPACE/$1"
  git -C "$WORKSPACE/$1" init -q
  git -C "$WORKSPACE/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "${2:-init}"
  git -C "$WORKSPACE/$1" rev-parse HEAD
}

echo "-- 0. the fixture git records a real, resolvable HEAD"
# The rest of this file is only meaningful if the fixtures ended up with actual
# revisions on disk. Under a shim (or a broken ambient git) every repo would be left
# with an unborn HEAD, the audit would report each one as `rev-parse failed`, and the
# scenarios below would "fail" for a reason that has nothing to do with the audit.
mkdir -p "$WORKSPACE"
probe="$(gitrepo probe_selfcheck)"
if [ "$(git -C "$WORKSPACE/probe_selfcheck" rev-parse HEAD 2>/dev/null)" = "$probe" ] \
   && [ "${#probe}" -eq 40 ]; then
  echo "  [PASS] fixture HEAD resolves to a full sha ($probe)"
else
  echo "  [FAIL] fixture git did not record a resolvable revision (got '$probe')"
  exit 1
fi
# Every active project exists at its locked revision from the start, so scenario 1
# is genuinely clean; later scenarios damage exactly one project each.
SHA_OK="$(gitrepo ok)"
SHA_WRONG="$(gitrepo wrong)"
SHA_GONE="$(gitrepo gone)"
SHA_TAG="$(gitrepo tagged)"
git -C "$WORKSPACE/tagged" tag "android-13.0.0_r30" HEAD
# Two projects pinned to the SAME tag, each checked out at the commit its OWN
# repository tags - which is what one shared AOSP release tag actually means.
# Distinct messages give them distinct commits; identical ones collapse into a
# single object and the scenario would pass for the wrong reason.
SHA_SHARED_A="$(gitrepo shared_a "release in shared_a")"
SHA_SHARED_B="$(gitrepo shared_b "release in shared_b")"
if [ "$SHA_SHARED_A" = "$SHA_SHARED_B" ]; then
  echo "FATAL: shared-tag fixtures collapsed into one commit - scenario 6 is meaningless" >&2
  exit 1
fi
git -C "$WORKSPACE/shared_a" tag "android-12.1.0_r22" "$SHA_SHARED_A"
git -C "$WORKSPACE/shared_b" tag "android-12.1.0_r22" "$SHA_SHARED_B"

cat > "$LOCK_XML" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="p_ok" path="ok" revision="$SHA_OK" />
  <project name="p_wrong" path="wrong" revision="$SHA_WRONG" />
  <project name="p_gone" path="gone" revision="$SHA_GONE" />
  <project name="p_tag" path="tagged" revision="refs/tags/android-13.0.0_r30" />
  <project name="p_shared_a" path="shared_a" revision="refs/tags/android-12.1.0_r22" />
  <project name="p_shared_b" path="shared_b" revision="refs/tags/android-12.1.0_r22" />
  <project name="p_skip" path="skipped" revision="refs/tags/android-12.1.0_r22" groups="notdefault" />
</manifest>
XML

echo "== revision audit offline behaviour =="

echo "-- 1. clean tree"
R1="$T/r1.txt"
run 0 "$R1"
case "$(head -1 "$R1")" in
  "OK all 6 active projects"*) echo "  [PASS] OK over the 6 active (notdefault skipped)";;
  *) echo "  [FAIL] first line: $(head -1 "$R1")"; fail=1;;
esac
grep -q '^skipped' "$R1" && { echo "  [FAIL] notdefault project leaked into the report"; fail=1; } \
  || echo "  [PASS] notdefault project excluded from the audit"

echo "-- 2. checkout at the wrong revision"
git -C "$WORKSPACE/wrong" -c user.email=t@t -c user.name=t commit -q --allow-empty -m drift
R2="$T/r2.txt"
run 3 "$R2"
case "$(head -1 "$R2")" in
  "MISMATCH 1 "*) echo "  [PASS] drifted checkout reported as MISMATCH 1";;
  *) echo "  [FAIL] expected MISMATCH 1, got: $(head -1 "$R2")"; fail=1;;
esac
grep -q "^mismatch wrong " "$R2" \
  && echo "  [PASS] mismatch names the drifted path" \
  || { echo "  [FAIL] no mismatch line for wrong"; fail=1; }
# restore for later scenarios
git -C "$WORKSPACE/wrong" update-ref HEAD "$SHA_WRONG"

echo "-- 3. directory with no checkout"
rm -rf "$WORKSPACE/gone/.git"   # directory remains, .git is gone
R3="$T/r3.txt"
run 3 "$R3"
case "$(head -1 "$R3")" in
  "MISSING 1 "*) echo "  [PASS] directory without .git reported as MISSING 1";;
  *) echo "  [FAIL] expected MISSING 1, got: $(head -1 "$R3")"; fail=1;;
esac
# repair before the next single-damage scenario (re-create the repo; the lock's
# recorded sha no longer exists, so p_gone's lock entry follows the new checkout -
# a git sha cannot be fabricated, same as a re-cut lock would)
rm -rf "$WORKSPACE/gone"
SHA_GONE2="$(gitrepo gone)"
python3 - "$LOCK_XML" "$SHA_GONE2" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'(name="p_gone" path="gone" revision=")[0-9a-f]{40}"', r'\g<1>%s"' % sys.argv[2], s, count=1)
open(sys.argv[1], "w").write(s)
PY

echo "-- 4. tag pinned, tag has moved past the checked-out commit"
# Model the real drift: HEAD stays at the commit the tree was synced to, while the
# tag ref upstream (and here, locally) has moved on. The audit resolves the tag
# through ^{commit}, so it must notice HEAD is now behind the tag's target.
git -C "$WORKSPACE/tagged" -c user.email=t@t -c user.name=t commit -q --allow-empty -m newer
git -C "$WORKSPACE/tagged" tag -f "android-13.0.0_r30" HEAD >/dev/null
git -C "$WORKSPACE/tagged" update-ref HEAD "$SHA_TAG"   # checkout stays at the old commit
R4="$T/r4.txt"
run 3 "$R4"
case "$(head -1 "$R4")" in
  "MISMATCH 1 "*) echo "  [PASS] tag-pinned project flagged when the tag moved past HEAD";;
  *) echo "  [FAIL] expected tag MISMATCH 1, got: $(head -1 "$R4")"; fail=1;;
esac
grep -q "^mismatch tagged " "$R4" \
  && echo "  [PASS] mismatch names the tag-pinned path" \
  || { echo "  [FAIL] no mismatch line for tagged"; fail=1; }

echo "-- 5. repair the tag and re-audit"
# Repair = re-sync: put the tag back on the commit the tree is checked out at
# (what `repo sync --force-sync` of the drifted path would achieve).
git -C "$WORKSPACE/tagged" tag -f "android-13.0.0_r30" "$SHA_TAG" >/dev/null
R5="$T/r5.txt"
run 0 "$R5"
case "$(head -1 "$R5")" in
  "OK all 6"*) echo "  [PASS] repaired tree audits clean again";;
  *) echo "  [FAIL] repaired tree: $(head -1 "$R5")"; fail=1;;
esac

echo "-- 6. one tag shared by two repositories"
# shared_a and shared_b are each checked out at the commit their OWN repo tags,
# which is exactly what `refs/tags/android-12.1.0_r22` means in a lock. A tag
# resolved once in shared_a and reused for shared_b would flag shared_b as drifted
# no matter what any sync does.
R6="$T/r6.txt"
run 0 "$R6"
case "$(head -1 "$R6")" in
  "OK all 6"*) echo "  [PASS] both projects sharing one tag audit clean";;
  *) echo "  [FAIL] shared tag: $(head -1 "$R6")"; fail=1;;
esac
if grep -q '^mismatch shared_' "$R6"; then
  echo "  [FAIL] a project was judged against another repository's tag commit:"
  sed 's/^/         /' "$R6"
  fail=1
else
  echo "  [PASS] neither project compared against the other's tag commit"
fi

echo "-- 7. sanitize the local state a forced checkout would abort on"
# Model job 302857: the pre-seeded image ships prebuilts/clang/host/linux-x86 with
# tracked files modified in place, and `repo sync --force-sync` applies the locked
# revision with a checkout that refuses to overwrite them ("Your local changes ...
# would be overwritten by checkout") - one dirty worktree failed a 1063-project
# re-sync. sanitize_worktrees must reset tracked modifications and drop untracked
# files; a path with no .git (a missing checkout repo materializes from scratch)
# is skipped, not an error.
gitrepo dirty >/dev/null
printf 'locked\n' > "$WORKSPACE/dirty/locked.txt"
git -C "$WORKSPACE/dirty" add locked.txt
git -C "$WORKSPACE/dirty" -c user.email=t@t -c user.name=t commit -q -m locked
printf 'local modification\n' > "$WORKSPACE/dirty/locked.txt"   # damage: tracked file modified
printf 'untracked\n'           > "$WORKSPACE/dirty/stray.txt"   # damage: untracked file
mkdir -p "$WORKSPACE/nogit"                                     # no .git at all
if sanitize_worktrees "$WORKSPACE" dirty nogit; then
  echo "  [PASS] sanitize_worktrees exits 0"
else
  echo "  [FAIL] sanitize_worktrees returned nonzero"
  fail=1
fi
[ -z "$(git -C "$WORKSPACE/dirty" status --porcelain)" ] \
  && echo "  [PASS] worktree is pristine afterwards" \
  || { echo "  [FAIL] worktree still dirty:"; git -C "$WORKSPACE/dirty" status --porcelain | sed 's/^/         /'; fail=1; }
[ "$(cat "$WORKSPACE/dirty/locked.txt")" = "locked" ] \
  && echo "  [PASS] tracked modification discarded (locked content restored)" \
  || { echo "  [FAIL] tracked file still holds the local modification"; fail=1; }
[ -e "$WORKSPACE/dirty/stray.txt" ] \
  && { echo "  [FAIL] untracked file survived sanitize"; fail=1; } \
  || echo "  [PASS] untracked file removed"
[ -d "$WORKSPACE/nogit" ] \
  && echo "  [PASS] checkout without .git skipped, left alone" \
  || { echo "  [FAIL] nogit directory disappeared"; fail=1; }

echo "-- 8. sanitize a checkout whose HEAD never landed"
# A project whose .git exists but holds no commit is reported by the audit as
# `rev-parse failed`, and the recipe routes it straight into sanitize_worktrees.
# `git reset --hard HEAD` dies on an unborn HEAD, and failing there would kill the
# very `repo sync` that rebuilds the checkout - so the sanitizer has to let it
# through while still clearing whatever debris the half-finished fetch left.
mkdir -p "$WORKSPACE/halfinit"
git -C "$WORKSPACE/halfinit" init -q            # .git present, HEAD unborn
printf 'untracked\n' > "$WORKSPACE/halfinit/stray.txt"
if sanitize_worktrees "$WORKSPACE" halfinit; then
  echo "  [PASS] sanitize_worktrees exits 0 on an unborn HEAD"
else
  echo "  [FAIL] sanitize_worktrees returned nonzero on an unborn HEAD"
  fail=1
fi
[ -e "$WORKSPACE/halfinit/.git" ] \
  && echo "  [PASS] the half-initialized checkout was left in place" \
  || { echo "  [FAIL] half-initialized checkout disappeared"; fail=1; }
[ -e "$WORKSPACE/halfinit/stray.txt" ] \
  && { echo "  [FAIL] untracked debris survived an unborn-HEAD sanitize"; fail=1; } \
  || echo "  [PASS] untracked debris removed even with no HEAD to reset to"

echo "-- 9. the repo manifest -r witness CORROBORATES; it never decides"
# The recipe hands the audit a `repo manifest -r` witness, and this scenario is the
# whole correction from job 303324. That audit used a witness entry as the answer to
# compare on-disk HEAD against, under the comment "repo resolved this pin; its
# answer is the lock's answer, by construction" - which is false. `repo manifest -r`
# reports the revision each project is CHECKED OUT at, so it echoes the disk; the
# comparison agreed with itself and could not fail. It printed "OK all 1175 active
# projects ... (1175/1175 resolved via repo manifest -r)" over a tree holding 190
# wrong commits and 8 absent projects, one screen above verify-lock.py refusing the
# same tree on the same witness file.
#
# So the witness is a corroborating second reading, never the yardstick, and all
# four properties below are about that distinction:
#   a) a pin the checkout can no longer resolve is still undecidable WITH a witness
#      - the witness must not rescue it;
#   b) a clean tree plus a witness that agrees with the lock is clean, and the
#      report must say how much the witness actually corroborated;
#   c) THE REGRESSION (303324): a tree drifted away from the lock, with a witness
#      that faithfully reports the drift, is a MISMATCH - not OK;
#   d) a witness that contradicts a clean tree cannot fail it either - it is
#      reported, and the lock still governs.
RESOLVED="$T/resolved.xml"
stub_witness() { # args: "<path> <revision>" pairs; a path may be repeated to override
  rm -f "$RESOLVED"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<manifest>\n'
    for pair in "$@"; do
      printf '  <project path="%s" revision="%s" />\n' "${pair%% *}" "${pair##* }"
    done
    printf '</manifest>\n'
  } > "$RESOLVED"
}
FULL_WITNESS=( "ok $SHA_OK" "wrong $SHA_WRONG" "gone $SHA_GONE2" "tagged $SHA_TAG" \
               "shared_a $SHA_SHARED_A" "shared_b $SHA_SHARED_B" )

# Damage shared_b's local tag, so the lock's refs/tags/android-12.1.0_r22 no longer
# resolves inside the project that pins it. The lock itself is undamaged.
git -C "$WORKSPACE/shared_b" tag -d "android-12.1.0_r22" >/dev/null

R9a="$T/r9a.txt"
run 3 "$R9a"
if grep -q "does not resolve it" "$R9a"; then
  echo "  [PASS] (a1) without a witness, an unresolvable local pin is undecidable"
else
  echo "  [FAIL] expected 'does not resolve it', got: $(head -1 "$R9a")"; fail=1
fi

# The witness names a concrete commit for exactly that project. It must NOT become
# the yardstick: a pin the checkout cannot resolve is still unproven, and letting
# the witness vouch for it would reintroduce the tautology one level down.
stub_witness "${FULL_WITNESS[@]}"
R9b="$T/r9b.txt"
run 3 "$R9b" "$RESOLVED"
if grep -q "^mismatch shared_b .*does not resolve it" "$R9b"; then
  echo "  [PASS] (a2) a witness entry does NOT rescue a pin the checkout cannot resolve"
else
  echo "  [FAIL] the witness overrode the lock: $(head -1 "$R9b")"; fail=1
fi

# Repair the tag; now the tree is clean and the witness agrees with the lock.
git -C "$WORKSPACE/shared_b" tag "android-12.1.0_r22" "$SHA_SHARED_B"
R9c="$T/r9c.txt"
run 0 "$R9c" "$RESOLVED"
case "$(head -1 "$R9c")" in
  "OK all 6 active projects"*) echo "  [PASS] (b) a clean tree the witness corroborates is OK";;
  *) echo "  [FAIL] clean corroborated tree: $(head -1 "$R9c")"; fail=1;;
esac
case "$(head -1 "$R9c")" in
  *"repo manifest -r corroborates 6/6"*)
    echo "  [PASS] (b) the report says how much the witness corroborated";;
  *)
    echo "  [FAIL] report does not report corroboration: $(head -1 "$R9c")"; fail=1;;
esac

# (c) THE REGRESSION. Drift `wrong` off its locked SHA, and let the witness report
# the drift - which is what repo genuinely sees. Pre-fix, `want` came from the
# witness, so want == head and the audit said OK. This is 303324 in miniature.
git -C "$WORKSPACE/wrong" -c user.email=t@t -c user.name=t commit -q --allow-empty -m drift2
DRIFTED="$(git -C "$WORKSPACE/wrong" rev-parse HEAD)"
stub_witness "${FULL_WITNESS[@]}" "wrong $DRIFTED"
R9d="$T/r9d.txt"
run 3 "$R9d" "$RESOLVED"
case "$(head -1 "$R9d")" in
  "MISMATCH 1 "*) echo "  [PASS] (c) a tree drifted from the lock is MISMATCH even when the witness agrees with disk";;
  *) echo "  [FAIL] the audit trusted the witness over the lock: $(head -1 "$R9d")"; fail=1;;
esac
# The report abbreviates commits to 12 chars, so match on that prefix, not the
# full sha - an assertion that never matches would read as a code failure.
DRIFT12="${DRIFTED%${DRIFTED#????????????}}"
LOCK12="${SHA_WRONG%${SHA_WRONG#????????????}}"
grep -q "^mismatch wrong on-disk $DRIFT12, locked $LOCK12" "$R9d" \
  && echo "  [PASS] (c) the mismatch names the drifted commit and the locked one" \
  || { echo "  [FAIL] wrong mismatch line: $(grep '^mismatch ' "$R9d")"; fail=1; }
grep -q "^note wrong repo manifest -r says $DRIFT12 but the lock says $LOCK12" "$R9d" \
  && echo "  [PASS] (c) the witness disagreeing with the lock is reported, as a note" \
  || { echo "  [FAIL] the witness disagreement was swallowed: $(cat "$R9d")"; fail=1; }
git -C "$WORKSPACE/wrong" update-ref HEAD "$SHA_WRONG"   # restore for later scenarios

# (d) A witness that contradicts an otherwise clean tree must not fail it - the
# lock still governs - but the disagreement has to be visible in the report.
BADREV="$(printf 'f%.0s' $(seq 40))"
stub_witness "${FULL_WITNESS[@]}" "wrong $BADREV"
R9e="$T/r9e.txt"
run 0 "$R9e" "$RESOLVED"
case "$(head -1 "$R9e")" in
  "OK all 6 active projects"*) echo "  [PASS] (d) a contradicting witness cannot fail a clean tree";;
  *) echo "  [FAIL] a witness vetoed the lock: $(head -1 "$R9e")"; fail=1;;
esac
case "$(head -1 "$R9e")" in
  *"repo manifest -r corroborates 5/6"*)
    echo "  [PASS] (d) and the report counts the disagreement instead of hiding it";;
  *)
    echo "  [FAIL] corroboration count hides the conflict: $(head -1 "$R9e")"; fail=1;;
esac

echo "-- 10. the recipe re-resolves the witness BEFORE the post-re-sync re-audit"
# The control flow in the repair branch is not exercisable offline - it needs `repo`
# and a real `repo sync` - so this pins the ORDER in the recipe source instead, which
# is the entire content of the fix. Line numbers are the test: a future edit that
# moves the refresh back after the re-audit (where it already also runs, for the
# canonical check) would still look correct to `bash -n` and to every other scenario.
# Each lookup is `|| true`: under `set -e` a grep that matches nothing fails the
# assignment and would abort the suite outright, which is exactly how one red check
# hides the state of the ones after it. An absent call site is this check's SUBJECT,
# so it must be reported below, not kill the run before it gets there.
FIRST_AUDIT=$(grep -n 'if revision_audit "$audit_out" "$resolved_manifest"' "$RECIPE" | cut -d: -f1 || true)
REFRESH=$(grep -n 'resolve_witness "$resolved_manifest" || true' "$RECIPE" | tail -1 | cut -d: -f1 || true)
RE_AUDIT=$(grep -n 'if ! revision_audit "$audit_out" "$resolved_manifest"' "$RECIPE" | cut -d: -f1 || true)
REQUIRED=$(grep -n 'resolve_witness "$resolved_manifest" required' "$RECIPE" | cut -d: -f1 || true)
if [ -n "$FIRST_AUDIT" ] && [ -n "$REFRESH" ] && [ -n "$RE_AUDIT" ] && [ -n "$REQUIRED" ]; then
  echo "  [info] first audit L$FIRST_AUDIT, refresh L$REFRESH, re-audit L$RE_AUDIT, canonical L$REQUIRED"
  if [ "$FIRST_AUDIT" -lt "$REFRESH" ] && [ "$REFRESH" -lt "$RE_AUDIT" ] && [ "$RE_AUDIT" -lt "$REQUIRED" ]; then
    echo "  [PASS] the refresh sits between the failing audit and the re-audit"
  else
    echo "  [FAIL] expected first audit < refresh < re-audit < canonical"; fail=1
  fi
else
  echo "  [FAIL] could not locate the audit/refresh call sites in the recipe"; fail=1
fi

echo "-- 11. resolve_witness: a stale witness is replaced, and a failure leaves none"
if [ "${EMBERBIRD_HAS_RESOLVE_WITNESS:-0}" != "1" ]; then
  echo "  [FAIL] the recipe no longer defines resolve_witness()"; fail=1
else
  STUBBIN="$T/repo-stub-bin"
  mkdir -p "$STUBBIN"
  W="$T/witness.xml"
  printf 'STALE\n' > "$W"

  # repo succeeds and rewrites the file -> the new contents must be what survives.
  cat > "$STUBBIN/repo" <<'STUB'
#!/usr/bin/env bash
# stub repo manifest -r: writes $STUB_REPO_BODY to the -o path, exits $STUB_REPO_RC.
# An EMPTY STUB_REPO_BODY writes NOTHING at all (repo can exit 0 having produced no
# file), which is the case resolve_witness must not accept as a resolution.
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
if [ -z "${STUB_REPO_BODY+set}" ]; then body="RESOLVED"; else body="$STUB_REPO_BODY"; fi
[ -n "$out" ] && [ -n "$body" ] && printf '%s\n' "$body" > "$out"
exit "${STUB_REPO_RC:-0}"
STUB
  chmod +x "$STUBBIN/repo"
  PATH="$STUBBIN:$PATH"

  STUB_REPO_BODY=FRESH STUB_REPO_RC=0 resolve_witness "$W" >/dev/null
  if [ "$(cat "$W")" = "FRESH" ]; then
    echo "  [PASS] a successful re-resolve replaces the old witness"
  else
    echo "  [FAIL] witness still says '$(cat "$W")' after a successful re-resolve"; fail=1
  fi

  # repo fails -> the file must be GONE, not left stale for the audit to trust.
  printf 'STALE\n' > "$W"
  set +e
  STUB_REPO_BODY=NEVER STUB_REPO_RC=1 resolve_witness "$W" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ ! -e "$W" ]; then
    echo "  [PASS] a failed re-resolve returns nonzero and leaves NO witness behind"
  else
    echo "  [FAIL] rc=$rc, witness exists=$([ -e "$W" ] && echo yes || echo no)"; fail=1
  fi

  # repo exits 0 but writes nothing -> also treated as a failure, not a success.
  STUB_REPO_BODY="" STUB_REPO_RC=0 resolve_witness "$W" >/dev/null 2>&1 \
    && echo "  [FAIL] an empty witness file was accepted as a resolution" && fail=1 \
    || echo "  [PASS] repo exiting 0 without writing anything is not a resolution"
fi

echo "-- 12. preflight: a .repo we cannot reuse, and a foreign base, are caught EARLY"
# inspect_seed runs before the multi-hour sync. The states it refuses are the ones where
# `repo init` would build a hybrid nobody downstream can verify; the foreign-base case
# is reported rather than refused, because re-pointing a pre-seeded Crave node is the
# supported path (and is what 302748 actually relied on).
OUR_URL="https://github.com/BlissRoms-x86/manifest.git"
SEED_LOCK="$REPO_ROOT/image/manifest/arcadia-x86.pinned.xml"

mkseed() { # $1 = name -> prints a workspace path with a .repo/manifests git checkout
  local ws="$T/$1"
  mkdir -p "$ws"
  printf '%s\n' "$ws"
}

expect_die() { # $1 = label, rest = command
  local label="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q FATAL; then
    echo "  [PASS] $label"
  else
    echo "  [FAIL] $label (rc=$rc, out: $(printf '%s' "$out" | head -1))"; fail=1
  fi
}

if ! type -t inspect_seed >/dev/null; then
  echo "  [FAIL] the recipe no longer defines inspect_seed()"; fail=1
else
  # Cold runner: nothing there, must not complain.
  cold="$(mkseed cold)"
  if out="$(inspect_seed "$cold" "$OUR_URL" "$SEED_LOCK" 2>&1)" && printf '%s' "$out" | grep -q 'seed: none'; then
    echo "  [PASS] a cold runner is not treated as a problem"
  else
    echo "  [FAIL] cold runner: $out"; fail=1
  fi

  # A .repo with no manifests worktree cannot be reused by repo.
  broken="$(mkseed broken)"
  mkdir -p "$broken/.repo"
  expect_die "a .repo with no .repo/manifests is refused" inspect_seed "$broken" "$OUR_URL" "$SEED_LOCK"

  # manifest.xml that is not XML: repo would sync against something unreadable.
  badxml="$(mkseed badxml)"
  mkdir -p "$badxml/.repo/manifests"
  git -C "$badxml/.repo/manifests" init -q
  printf 'this is not xml\n' > "$badxml/.repo/manifest.xml"
  expect_die "an unparseable .repo/manifest.xml is refused" inspect_seed "$badxml" "$OUR_URL" "$SEED_LOCK"

  # Foreign base: reported, not fatal, unless REQUIRE_CLEAN_SEED is set.
  foreign="$(mkseed foreign)"
  mkdir -p "$foreign/.repo/manifests"
  git -C "$foreign/.repo/manifests" init -q
  git -C "$foreign/.repo/manifests" remote add origin https://github.com/accupara/los20.git
  git -C "$foreign/.repo/manifests" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '<manifest/>\n' > "$foreign/.repo/manifest.xml"
  out="$(inspect_seed "$foreign" "$OUR_URL" "$SEED_LOCK" 2>&1)" || {
    echo "  [FAIL] a foreign base should be reported, not fatal: $out"; fail=1; }
  if printf '%s' "$out" | grep -q 'FOREIGN BASE'; then
    echo "  [PASS] a foreign base is reported before the sync"
  else
    echo "  [FAIL] foreign base not reported: $out"; fail=1
  fi
  if out="$(REQUIRE_CLEAN_SEED=1 inspect_seed "$foreign" "$OUR_URL" "$SEED_LOCK" 2>&1)" ; then
    echo "  [FAIL] REQUIRE_CLEAN_SEED=1 did not refuse a foreign base"; fail=1
  else
    echo "  [PASS] REQUIRE_CLEAN_SEED=1 refuses a foreign base"
  fi

  # Normalisation: a trailing .git / slash / different case is still OUR base.
  ours="$(mkseed ours)"
  mkdir -p "$ours/.repo/manifests"
  git -C "$ours/.repo/manifests" init -q
  git -C "$ours/.repo/manifests" remote add origin https://github.com/BlissRoms-X86/Manifest.git/
  git -C "$ours/.repo/manifests" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '<manifest/>\n' > "$ours/.repo/manifest.xml"
  out="$(inspect_seed "$ours" "$OUR_URL" "$SEED_LOCK" 2>&1)"
  if printf '%s' "$out" | grep -q 'FOREIGN BASE'; then
    echo "  [FAIL] our own base was misreported as foreign (url normalisation is broken)"; fail=1
  else
    echo "  [PASS] our own base is not misreported as foreign"
  fi
fi

echo "-- 13. preflight: a dirty manifests worktree is caught even when HEAD matches"
# THE hole this closes: `git checkout --detach <sha>` carries local modifications
# across when they do not conflict, so HEAD reaches the pinned revision while the
# manifest in use does not. The recipe's existing guard is a rev-parse HEAD
# comparison, which PASSES in exactly that case.
if ! type -t manifests_clean >/dev/null; then
  echo "  [FAIL] the recipe no longer defines manifests_clean()"; fail=1
else
  MC="$T/manifests-clean"
  mkdir -p "$MC"
  git -C "$MC" init -q
  printf 'original\n' > "$MC/default.xml"
  git -C "$MC" add default.xml
  git -C "$MC" -c user.email=t@t -c user.name=t commit -q -m init

  # Clean tree, and the one untracked file the recipe drops in on purpose.
  # NOTE the subshells: the recipe's `die` calls `exit`, so invoking these guards
  # directly would terminate this test script on the first failure instead of
  # recording it. Same contract as the recipe, isolated to one command.
  if ( manifests_clean "$MC" emberbird-pinned.xml ) >/dev/null 2>&1; then
    echo "  [PASS] a clean manifests worktree passes"
  else
    echo "  [FAIL] a clean worktree was rejected"; fail=1
  fi
  printf 'pinned\n' > "$MC/emberbird-pinned.xml"
  if ( manifests_clean "$MC" emberbird-pinned.xml ) >/dev/null 2>&1; then
    echo "  [PASS] the recipe's own emberbird-pinned.xml is allowed"
  else
    echo "  [FAIL] our own emberbird-pinned.xml was rejected"; fail=1
  fi
  rm -f "$MC/emberbird-pinned.xml"

  # A MODIFIED tracked file at the right HEAD - the silent provenance hole.
  printf 'locally edited\n' > "$MC/default.xml"
  head_now="$(git -C "$MC" rev-parse HEAD)"
  out="$(manifests_clean "$MC" emberbird-pinned.xml 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'default.xml'; then
    echo "  [PASS] a modified tracked file is refused, and named"
  else
    echo "  [FAIL] dirty manifests accepted (rc=$rc): $(printf '%s' "$out" | head -2)"; fail=1
  fi
  # Prove the existing HEAD guard would NOT have caught it.
  if [ "$head_now" = "$(git -C "$MC" rev-parse HEAD)" ]; then
    echo "  [PASS] HEAD is unchanged - so rev-parse HEAD alone would NOT have caught this"
  else
    echo "  [FAIL] test setup wrong: HEAD moved"; fail=1
  fi
  git -C "$MC" checkout -q -- default.xml

  # An untracked file that is NOT ours is debris and must not survive.
  printf 'debris\n' > "$MC/random-junk.txt"
  if ( manifests_clean "$MC" emberbird-pinned.xml ) >/dev/null 2>&1; then
    echo "  [FAIL] unrelated untracked debris was accepted"; fail=1
  else
    echo "  [PASS] unrelated untracked debris is refused"
  fi
  rm -f "$MC/random-junk.txt"
fi

echo
if [ "$fail" = 0 ]; then
  echo "revision audit offline test: PASS"
else
  echo "revision audit offline test: FAIL"
  exit 1
fi
