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
#   9. the audit judges against a stubbed `repo manifest -r` when one is supplied.
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

echo "-- 9. the audit judges against repo's own resolution (stubbed repo manifest -r)"
# The recipe hands the audit `repo manifest -r`, which resolves each pin the way repo
# does. Two properties matter, and NEITHER is testable without a stub:
#   a) a pin the project's own checkout can no longer resolve is still decidable,
#      because repo's resolved answer stands in for it - this is the whole reason
#      the recipe passes the witness in;
#   b) when repo's answer disagrees with HEAD, HEAD is wrong - the audit must not
#      rubber-stamp a tree just because a resolved manifest was supplied.
RESOLVED="$T/resolved.xml"
stub_resolved() { # $1 = path whose resolved revision to corrupt (optional)
  local bad="${1:-}"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<manifest>\n'
    printf '  <project name="ok" path="ok" revision="%s" />\n' "$SHA_OK"
    printf '  <project name="wrong" path="wrong" revision="%s" />\n' "$SHA_WRONG"
    printf '  <project name="gone" path="gone" revision="%s" />\n' "$SHA_GONE2"
    printf '  <project name="p_tag" path="tagged" revision="%s" />\n' "$SHA_TAG"
    printf '  <project name="p_shared_a" path="shared_a" revision="%s" />\n' "$SHA_SHARED_A"
    if [ "$bad" = "shared_b" ]; then
      printf '  <project name="p_shared_b" path="shared_b" revision="%s" />\n' "$(printf 'f%.0s' $(seq 40))"
    else
      printf '  <project name="p_shared_b" path="shared_b" revision="%s" />\n' "$SHA_SHARED_B"
    fi
    printf '</manifest>\n'
  } > "$RESOLVED"
}

# Damage the one thing only repo's resolution can still answer: shared_b's local tag.
git -C "$WORKSPACE/shared_b" tag -d "android-12.1.0_r22" >/dev/null

R9a="$T/r9a.txt"
run 3 "$R9a"
if grep -q "does not resolve it" "$R9a"; then
  echo "  [PASS] without the witness, an unresolvable local pin is undecidable"
else
  echo "  [FAIL] expected 'does not resolve it', got: $(head -1 "$R9a")"; fail=1
fi

stub_resolved
R9b="$T/r9b.txt"
run 0 "$R9b" "$RESOLVED"
case "$(head -1 "$R9b")" in
  "OK all 6 active projects"*) echo "  [PASS] with the witness, that same project is decidable";;
  *) echo "  [FAIL] witness did not rescue the audit: $(head -1 "$R9b")"; fail=1;;
esac
case "$(head -1 "$R9b")" in
  *"repo manifest -r"*) echo "  [PASS] the report names the yardstick it used";;
  *) echo "  [FAIL] report does not say it used the resolved manifest"; fail=1;;
esac

stub_resolved shared_b
R9c="$T/r9c.txt"
run 3 "$R9c" "$RESOLVED"
if grep -q "^mismatch shared_b " "$R9c"; then
  echo "  [PASS] a resolved revision that disagrees with HEAD is caught"
else
  echo "  [FAIL] the audit accepted a tree the witness disagrees with: $(head -1 "$R9c")"; fail=1
fi

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

echo
if [ "$fail" = 0 ]; then
  echo "revision audit offline test: PASS"
else
  echo "revision audit offline test: FAIL"
  exit 1
fi
