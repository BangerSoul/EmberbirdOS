#!/usr/bin/env bash
# Offline exercise of the recipe's revision_audit() against a synthetic lock and a
# synthetic synced tree. Each scenario changes exactly one thing from the clean
# baseline, so a failure points at one behaviour:
#   1. clean tree audits OK (exit 0), notdefault projects excluded;
#   2. a checkout at the wrong SHA is a MISMATCH (exit 3), naming the path;
#   3. a directory with no .git is MISSING (exit 3);
#   4. a tag-pinned project whose tag has moved past HEAD is a MISMATCH;
#   5. repairing every drift audits clean again.
# WHY: job 302748 (2026-09-30) died at `lunch` because the Crave node's pre-seeded
# tree held ~1000 lock paths at LOS 20 revisions while every other check in the
# recipe reasoned about existence and files only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-audit.sh
source "$HERE/lib-audit.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export WORKSPACE="$T/ws" LOCK_XML="$T/lock.xml"
mkdir -p "$WORKSPACE"

fail=0
run() { # $1 = expected exit, $2 = report file
  local want="$1" rep="$2" rc
  set +e
  revision_audit "$rep"
  rc=$?
  set -e
  if [ "$rc" = "$want" ]; then
    echo "  [PASS] audit exits $rc as expected"
  else
    echo "  [FAIL] audit exit $rc, expected $want (report head: $(head -1 "$rep" 2>/dev/null))"
    fail=1
  fi
}

gitrepo() { # $1 = path under ws; prints the resulting HEAD sha
  mkdir -p "$WORKSPACE/$1"
  git -C "$WORKSPACE/$1" init -q
  git -C "$WORKSPACE/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$WORKSPACE/$1" rev-parse HEAD
}

echo "== fixtures =="
# Every active project exists at its locked revision from the start, so scenario 1
# is genuinely clean; later scenarios damage exactly one project each.
SHA_OK="$(gitrepo ok)"
SHA_WRONG="$(gitrepo wrong)"
SHA_GONE="$(gitrepo gone)"
SHA_TAG="$(gitrepo tagged)"
git -C "$WORKSPACE/tagged" tag "android-13.0.0_r30" HEAD

cat > "$LOCK_XML" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="p_ok" path="ok" revision="$SHA_OK" />
  <project name="p_wrong" path="wrong" revision="$SHA_WRONG" />
  <project name="p_gone" path="gone" revision="$SHA_GONE" />
  <project name="p_tag" path="tagged" revision="refs/tags/android-13.0.0_r30" />
  <project name="p_skip" path="skipped" revision="refs/tags/android-12.1.0_r22" groups="notdefault" />
</manifest>
XML

echo "== revision audit offline behaviour =="

echo "-- 1. clean tree"
R1="$T/r1.txt"
run 0 "$R1"
case "$(head -1 "$R1")" in
  "OK all 4 active projects"*) echo "  [PASS] OK over the 4 active (notdefault skipped)";;
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
  "OK all 4"*) echo "  [PASS] repaired tree audits clean again";;
  *) echo "  [FAIL] repaired tree: $(head -1 "$R5")"; fail=1;;
esac

echo
if [ "$fail" = 0 ]; then
  echo "revision audit offline test: PASS"
else
  echo "revision audit offline test: FAIL"
  exit 1
fi
