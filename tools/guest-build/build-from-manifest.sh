#!/usr/bin/env bash
# EmberbirdOS M2 X2 - build the Android-x86_64 guest from the pinned manifest.
#
# This is the ONE build recipe. It is runner-agnostic on purpose: the same script
# is what Crave executes remotely (see docs/M2-CRAVE-BUILD.md) and what
# .github/workflows/guest-build.yml executes on any runner that has the disk for it.
# Two copies of a build recipe drift; this file is the single source of truth.
#
# It does the provenance-critical work in the right order:
#   1. install the committed frozen lock (image/manifest/arcadia-x86.pinned.xml) as
#      repo's ACTIVE manifest and sync against it, so every project is fetched at an
#      immutable SHA/tag - never a moving upstream ref (arcadia-x86, master) that can
#      404 and leave the tree silently incomplete. The upstream manifests checkout is
#      still pinned to the exact revision recorded in image/manifest/arcadia-x86.pin.json
#      for provenance, but its moving per-project refs are no longer what repo syncs;
#   2. audit the synced tree's CONTENT against the lock - every project's on-disk HEAD
#      against the revision `repo manifest -r` resolves for it, re-syncing and
#      re-auditing whatever drifted - and then re-confirm the lock against that same
#      `repo manifest -r` witness with verify-lock.py --repo-manifest, so the claim
#      written into the provenance record below is one a check actually made;
#   3. build the image;
#   4. emit image/out/x2-provenance.json (sha256 + size + toolchain + revision), which
#      is the X2 evidence record, plus a plain artifact list.
#
# Requirements: ~300 GB free, 16 GB+ RAM, git, python3, curl, and the repo launcher.
# On Crave none of that needs installing - that is the point of building there.
#
# Usage (local or CI):
#   bash tools/guest-build/build-from-manifest.sh
# Usage (Crave, from your machine, after the project is configured):
#   crave run --no-patch -- "bash tools/guest-build/build-from-manifest.sh"
#   crave pull image/out/          # fetch the image + X2 record back
#
# Env overrides: WORKSPACE, LUNCH_TARGET, MAKE_TARGET, MANIFEST_URL, MANIFEST_BRANCH,
#                MANIFEST_REVISION, JOBS, SYNC_JOBS, SKIP_SYNC (debug only).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MANIFEST_URL="${MANIFEST_URL:-https://github.com/BlissRoms-x86/manifest.git}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-arcadia-x86}"
LUNCH_TARGET="${LUNCH_TARGET:-bliss_x86_64-userdebug}"
MAKE_TARGET="${MAKE_TARGET:-iso_img}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
SYNC_JOBS="${SYNC_JOBS:-$JOBS}"
WORKSPACE="${WORKSPACE:-${HOME}/emberbird-build/aosp}"
OUT_DIR="$REPO_ROOT/image/out"
mkdir -p "$OUT_DIR"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight ---
log "preflight"
command -v git    >/dev/null || die "git is required"
command -v python3 >/dev/null || die "python3 is required"

# Two things the old preflight got wrong:
#   1. It measured df on $REPO_ROOT (the small EmberbirdOS checkout), but the sync +
#      build land in $WORKSPACE. On Crave those share one device, so it passed by luck;
#      on a split-disk runner it would clear the gate then run out of space mid-build.
#      Measure the filesystem the build actually writes to.
#   2. It always demanded the COLD floor (~250 GB for a from-scratch checkout + build).
#      Crave (and any warm runner) PRE-SEEDS the AOSP tree: $WORKSPACE already owns a
#      .repo, so the sync is INCREMENTAL and only needs headroom for the delta + out/,
#      not a second full ~300 GB checkout. That mismatch is exactly what failed job
#      301901: the node had 204 GB free on a tree already holding 132 GB, and the cold
#      floor rejected a perfectly buildable node. Gate on incremental headroom when a
#      pre-seeded .repo exists; keep the full floor for a cold runner.
mkdir -p "$WORKSPACE"
if [ -e "$WORKSPACE/.repo" ]; then
  seeded="pre-seeded tree (incremental sync + build)"
  disk_floor_gb="${DISK_FLOOR_GB:-120}"
else
  seeded="cold runner (full sync + build)"
  disk_floor_gb="${DISK_FLOOR_GB:-250}"
fi
avail_kb="$(df -Pk "$WORKSPACE" | awk 'NR==2 {print $4}')"
avail_gb=$(( avail_kb / 1024 / 1024 ))
mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
printf 'workspace: %s\n' "$WORKSPACE"
printf 'mode: %s | disk floor: %s GB\n' "$seeded" "$disk_floor_gb"
printf 'disk free (on workspace fs): %s GB | RAM: %s GB | jobs: %s\n' "$avail_gb" "$mem_gb" "$JOBS"
if [ "$avail_gb" -lt "$disk_floor_gb" ]; then
  die "only ${avail_gb} GB free on ${WORKSPACE} (${seeded} needs ~${disk_floor_gb} GB). Use Crave (docs/M2-CRAVE-BUILD.md) or a runner with the disk."
fi
if [ "$mem_gb" -lt 15 ]; then
  die "only ${mem_gb} GB RAM; the AOSP build expects 16 GB+."
fi

# Resolve the revision to build from the committed pin, so this script never
# builds something other than what X1 locked.
MANIFEST_REVISION="${MANIFEST_REVISION:-$(python3 -c "import json;print(json.load(open('image/manifest/arcadia-x86.pin.json'))['manifest']['revision'])")}"
printf 'manifest: %s @ %s (%s)\n' "$MANIFEST_URL" "$MANIFEST_REVISION" "$MANIFEST_BRANCH"

if [ -z "${SKIP_SYNC:-}" ]; then
  log "installing the repo launcher"
  mkdir -p "$HOME/bin"
  if [ ! -x "$HOME/bin/repo" ]; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
    chmod a+x "$HOME/bin/repo"
  fi
  export PATH="$HOME/bin:$PATH"
  repo --version

  log "repo init + pin manifests to the X1 revision"
  mkdir -p "$WORKSPACE"
  cd "$WORKSPACE"
  # `repo` searches UPWARD for an existing .repo. If WORKSPACE sits under another
  # checkout's root, repo silently "reuses" that root while every relative .repo/...
  # path below resolves against WORKSPACE - which dies with
  #   fatal: cannot change to '.repo/manifests': No such file or directory
  # Crave states the rule plainly (crave/rules.md): "Do not make a folder and sync
  # inside that to avoid conflicts". On Crave the sync root IS the job workspace, so
  # WORKSPACE must be that root - not a subfolder created under it.
  if [ ! -e "$WORKSPACE/.repo" ]; then
    ancestor=""
    d="$(pwd)"
    while :; do
      d="$(dirname "$d")"
      [ "$d" != "/" ] || break
      if [ -e "$d/.repo" ]; then ancestor="$d"; break; fi
    done
    [ -z "$ancestor" ] || die "WORKSPACE=$WORKSPACE is nested under an existing repo checkout ($ancestor/.repo); repo would walk up and sync/reuse the wrong tree. Set WORKSPACE to a checkout root (on Crave: the job's own \$PWD), never a subfolder of one."
  fi
  # --git-lfs matches the recorded M1 build recipe. --depth=1 is Crave's documented
  # rule (crave/rules.md: "use --depth 1 on repo init to lessen syncing time").
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs --depth=1
  git -C .repo/manifests fetch --depth=1 origin "$MANIFEST_REVISION"
  git -C .repo/manifests checkout --detach "$MANIFEST_REVISION"

  # Pin the manifests project's own git tracking refspec to arcadia-x86.
  #
  # WHY: on a Crave pre-seeded LOS 20 tree, .repo/manifests was cloned for a project
  # whose default branch is `master`, so `branch.default.merge` is `refs/heads/master`
  # and `remote.origin.fetch` maps `refs/heads/*`. When resync.sh / `repo sync` sync the
  # `manifests` project itself, they consult that tracking ref and try to fetch
  # `refs/heads/master` from BlissRoms-x86/manifest.git - which has no `master` branch,
  # only `arcadia-x86`. That is the source of the log line
  #   error: ... revision refs/heads/master in manifests not found
  #   fatal: couldn't find remote ref refs/heads/master
  # Repointing the tracking branch AND the fetch refspec at arcadia-x86 makes that
  # lookup resolve to a ref that exists, so the manifests-project sync stops aborting.
  # (The manifests worktree stays detached at $MANIFEST_REVISION for provenance; this
  # only fixes which remote ref a background sync of the manifests repo consults.)
  git -C .repo/manifests config branch.default.merge refs/heads/arcadia-x86
  git -C .repo/manifests config remote.origin.fetch \
    "+refs/heads/arcadia-x86:refs/remotes/origin/arcadia-x86"

  pinned_manifests="$(git -C .repo/manifests rev-parse HEAD)"
  printf 'manifests checkout: %s\n' "$pinned_manifests"
  [ "$pinned_manifests" = "$MANIFEST_REVISION" ] \
    || die "manifests checkout is $pinned_manifests, expected $MANIFEST_REVISION"

  # THE ARCHITECTURAL FIX (root cause of jobs 302004 / 302127).
  #
  # The upstream arcadia-x86 manifest at $MANIFEST_REVISION pins many projects to MOVING
  # refs - bootable/aaropa at revision="arcadia-x86", and a dozen others at
  # revision="master" on repos whose default branch was since renamed to "main". Those
  # refs now 404. `repo sync`/resync.sh then log
  #   revision refs/heads/master in manifests not found
  #   error: Cannot fetch ... couldn't find remote ref refs/heads/master
  # abort those projects mid-sync, yet STILL print "All repositories synchronized
  # successfully". The tree is left incomplete (~796 of 1183 projects), and the very
  # next `repo manifest -r` dies with a raw FileNotFoundError on the first unmaterialized
  # path (observed: bootable/aaropa). Retrying is futile: the refs are gone upstream.
  #
  # We already hold every one of those projects as a FROZEN, reachable SHA/tag in the
  # committed X1 lock (image/manifest/arcadia-x86.pinned.xml - 1183 projects, all
  # immutable, verify-lock.py PASSES, aaropa=01fbf03... verified live). So we hand repo
  # the lock as its ACTIVE manifest instead of the moving upstream one: repo then fetches
  # each project by an immutable ref that cannot 404, which makes the refs/heads/master /
  # aaropa failure structurally impossible.
  #
  # This is repo's own supported mechanism: a manifest file placed inside the manifests
  # checkout and selected with `repo init -m <file>`. It does NOT touch the pre-seeded
  # source, does NOT `rm -rf` anything, and keeps --depth=1 + resync.sh below - so it
  # honours crave/rules.md (no needless full re-sync, sync at the workspace root). The
  # lock is self-contained (19 <remote>, 1 <default>, 0 <include>), so it stands alone as
  # repo's manifest. The upstream checkout stays pinned at $MANIFEST_REVISION above purely
  # for provenance; its moving per-project refs are no longer what gets synced.
  LOCK_XML="$REPO_ROOT/image/manifest/arcadia-x86.pinned.xml"
  [ -f "$LOCK_XML" ] || die "frozen lock not found: $LOCK_XML"
  log "installing the frozen X1 lock as repo's active manifest (immutable SHAs, no moving refs)"
  cp -f "$LOCK_XML" .repo/manifests/emberbird-pinned.xml
  # IMPORTANT: We write .repo/manifest.xml directly instead of calling
  #   repo init -m emberbird-pinned.xml
  # because `repo init -m` (without -b) triggers Sync_NetworkHalf which, on a
  # detached-HEAD manifests checkout (line 130 above), causes PreSync() to be a
  # no-op: CurrentBranch is None, so revisionExpr retains whatever the Crave
  # pre-seeded tree previously had (refs/heads/master from LOS 20). Repo then
  # tries to fetch refs/heads/master from BlissRoms-x86/manifest.git, which does
  # not exist, and dies with UpdateManifestError. Adding -b would fix the fetch
  # but trigger Sync_LocalHalf → checkout arcadia-x86, which resets the worktree
  # and deletes the untracked emberbird-pinned.xml we just copied above.
  #
  # Writing .repo/manifest.xml directly is exactly what repo's manifest.Link()
  # does internally (manifest_xml.py, the Link method): it removes any old
  # manifest.xml and writes a wrapper that <include>s the named file. We produce
  # the identical XML. No network fetch, no branch state mutation, and the next
  # `repo sync` / `repo manifest -r` work normally against the included lock.
  cat > .repo/manifest.xml <<'MANIFEST_XML'
<?xml version="1.0" encoding="UTF-8"?>
<!--
DO NOT EDIT THIS FILE!  It is generated by repo and changes will be discarded.
If you want to use a different manifest, use `repo init -m <file>` instead.

If you want to customize your checkout by overriding manifest settings, use
the local_manifests/ directory instead.

For more information on repo manifests, check out:
https://gerrit.googlesource.com/git-repo/+/HEAD/docs/manifest-format.md
-->
<manifest>
  <include name="emberbird-pinned.xml" />
</manifest>
MANIFEST_XML
  active_manifest="$(repo manifest 2>/dev/null | grep -c '<project' || true)"
  printf 'active manifest projects: %s (expected 1183 from the frozen lock)\n' "$active_manifest"

  # Crave ships a conflict-tolerant sync and its docs strongly prefer it over raw
  # `repo sync` (crave/getting-started/building-crave-run.md): "We strongly suggest
  # using /opt/crave/resync.sh ... since resync automatically handles conflicts".
  # It resolves paths relative to the repo root, which is why WORKSPACE must be one.
  # It is absent off-Crave (local/CI), where the plain sync below still applies.
  if [ -x /opt/crave/resync.sh ]; then
    log "repo sync via /opt/crave/resync.sh (Crave conflict-tolerant sync; multi-hundred-GB step)"
    /opt/crave/resync.sh || {
      log "resync.sh returned non-zero - falling back to a plain repo sync"
      repo sync -c -j"$SYNC_JOBS" --no-manifest-update --no-tags --force-sync
    }
  else
    log "repo sync (this is the multi-hour, multi-hundred-GB step)"
    repo sync -c -j"$SYNC_JOBS" --no-manifest-update --no-tags --force-sync
  fi

  # Defense in depth, made XML-authoritative.
  #
  # The active manifest is now the frozen lock (every ref immutable), so the moving-ref
  # abort that silently left projects unmaterialized cannot recur. But a pre-seeded Crave
  # tree was synced for the BASE project (LOS 20); when we re-point .repo at our lock,
  # resync.sh prunes/optimizes and can still report "synchronized successfully" while the
  # Bliss delta projects that LOS 20 never had (bootable/aaropa among them) are
  # absent on disk. `repo manifest -r` then dies with a raw FileNotFoundError on the first
  # missing path.
  #
  # How many are missing is a property of the node's pre-seeded tree, not a constant
  # (measured: 137 active projects absent from LOS 20's manifest on 2026-09-29). The loop
  # below computes the real set, so the count is only ever reported, never assumed.
  #
  # The OLD guard walked `repo list -p`, which is itself derived from what repo has on
  # disk / in its project list - so a project that never materialized could be absent
  # from that list too, and the guard would under-count and pass. We instead parse the
  # COMMITTED lock XML directly: it is the authoritative set of paths that MUST exist,
  # independent of repo's on-disk state. We drop only the `notdefault` group (repo's own
  # default-linux exclusion), which yields exactly the 1175 active projects that a
  # default sync on this Linux host is expected to materialize.
  log "verifying the synced tree is complete (XML-authoritative, not repo's on-disk view)"
  LOCK_XML="$REPO_ROOT/image/manifest/arcadia-x86.pinned.xml"
  # Capture via command substitution (NOT `mapfile < <(...)`): process substitution
  # discards the child's exit status, so a failing extractor would be masked. Command
  # substitution propagates it, and `set -e` then halts before any partial sync.
  required_list="$(
    LOCK_XML="$LOCK_XML" python3 - <<'PY'
import os, sys, xml.etree.ElementTree as ET

# Force LF-only output so a path never carries a trailing CR into bash (matters if
# this ever runs under a Windows python; on the Crave Linux host it is already LF).
try:
    sys.stdout.reconfigure(newline="\n")
except (AttributeError, ValueError):
    pass

root = ET.parse(os.environ["LOCK_XML"]).getroot()
required = []
for p in root.findall("project"):
    groups = {g.strip() for g in (p.get("groups", "")).split(",") if g.strip()}
    # repo's default-linux filter drops `notdefault`; it does NOT drop the bare
    # darwin-tagged prebuilts (they are not `platform-darwin`), so they stay in.
    if "notdefault" in groups:
        continue
    path = p.get("path") or p.get("name")
    if not path:
        print("ERROR: project without path/name in lock", file=sys.stderr)
        sys.exit(2)
    required.append(path)

EXPECTED = 1175  # 1183 total - 8 notdefault projects
if len(required) != EXPECTED:
    print(
        f"ERROR: lock yields {len(required)} active projects, expected {EXPECTED} "
        f"(1183 total - 8 notdefault). The committed lock changed; update EXPECTED "
        f"and re-verify.",
        file=sys.stderr,
    )
    sys.exit(3)
if len(set(required)) != len(required):
    print("ERROR: duplicate project paths in lock", file=sys.stderr)
    sys.exit(4)
print("\n".join(required))
PY
  )" || die "could not extract the authoritative project set from $LOCK_XML (see error above); refusing to sync against an unverified manifest."
  mapfile -t required_paths <<<"$required_list"

  total="${#required_paths[@]}"
  printf 'authoritative manifest project set: %s (expected 1175 active Linux projects)\n' "$total"

  # Deterministic missing-project detection. Use a real array (not a space-joined
  # string) so `repo sync` receives each path as a distinct argument and no SC2086
  # word-splitting hack is needed.
  missing_projects=()
  for p in "${required_paths[@]}"; do
    [ -d "$WORKSPACE/$p" ] || missing_projects+=("$p")
  done

  if [ "${#missing_projects[@]}" -gt 0 ]; then
    log "missing delta projects: ${#missing_projects[@]} of $total (Bliss deltas absent from the pre-seeded LOS 20 baseline, e.g. bootable/aaropa) - syncing only those"
    printf '  missing (%s): %s\n' "${#missing_projects[@]}" "${missing_projects[*]}"
    # Targeted sync of just the missing project paths - never a full re-sync (Crave rule).
    # --no-manifest-update so this never re-consults the manifests remote ref either.
    if ! repo sync -c -j"$SYNC_JOBS" --no-manifest-update --no-tags --force-sync "${missing_projects[@]}"; then
      die "targeted sync of the missing projects failed: ${missing_projects[*]}. The active manifest is the frozen lock (all immutable SHAs/tags), so this is a fetch/network fault, not a moving-ref 404 - retry, or re-cut the lock only if a pinned SHA has become unreachable upstream (tools/manifest/resolve-manifest-lock.py)."
    fi
    # Post-sync verification: 100% of the authoritative set must now exist on disk.
    still=()
    for p in "${missing_projects[@]}"; do
      [ -d "$WORKSPACE/$p" ] || still+=("$p")
    done
    [ "${#still[@]}" -eq 0 ] || die "still missing after a targeted sync: ${still[*]}. The frozen lock references project(s) the tree cannot materialize (an immutable ref went unreachable upstream); re-cut the lock."
  fi
  log "sync complete: all $total active manifest projects present on disk"

  # Ask repo what every project resolves to, and audit against that.
  #
  # The lock pins 872 of its 1175 active projects to refs/tags/android-12.1.0_r22, and
  # an AOSP release tag is a DIFFERENT commit in every repository - so a tag pin can
  # only be settled by repo's own revision resolution, not by re-deriving one in a
  # shell heredoc. `repo manifest -r` IS that resolution, and it is already the
  # artifact the provenance record names as the build-side witness. Generate it here
  # so the audit compares on-disk HEAD against repo's answer instead of guessing
  # (see revision_audit's $2).
  #
  # This is called a THIRD time after any repair - see below, and resolve_witness for
  # why a witness that has been around since before a `repo sync` is worse than none.
  resolve_witness() {
    # Regenerate the `repo manifest -r` witness into $1.
    #
    # $2 = "required" for the canonical gate, where the witness IS the provenance
    # claim and a failure is fatal. Anything else is an audit step, where a failure
    # must never stop the build.
    #
    # ON AN OPTIONAL FAILURE THE WITNESS IS REMOVED, not kept. A witness we could
    # not refresh describes a tree that no longer exists, and both ways that goes
    # wrong are worse than simply having none: the audit would judge the current
    # tree against a stale yardstick, which can either invent drift on a perfectly
    # good tree or wave through one that genuinely moved. Dropping it costs
    # precision - every project then falls back to resolving its pin in its own
    # checkout, which is the same commit repo would name - and buys certainty that
    # no comparison uses a value from the wrong moment.
    local out="$1" mode="${2:-optional}"
    rm -f "$out"
    if repo manifest -r -o "$out" && [ -s "$out" ]; then
      printf '  resolved manifest: %s\n' "$out"
      return 0
    fi
    # repo can exit 0 having written a partial file, so a failed run never leaves
    # one behind for the audit to trust.
    rm -f "$out"
    if [ "$mode" = "required" ]; then
      die "repo manifest -r failed - the synced tree is missing or cannot resolve a project the frozen lock references (see the sync-completeness step above), so the canonical X1 witness cannot be produced."
    fi
    echo "note: repo manifest -r could not resolve every project; the audit will resolve each pin in its own checkout instead (the canonical witness check below is mandatory and runs regardless)"
    return 1
  }

  log "resolving the active manifest per project (repo manifest -r)"
  resolved_manifest="$OUT_DIR/repo-manifest-r.xml"
  resolve_witness "$resolved_manifest" || true

  # Revision audit - presence is NOT content.
  #
  # Job 302572 (2026-09-29): every active path existed on disk, LOCK VERIFICATION
  # PASSED, and the tree was still LOS 20 content. This node is PRE-SEEDED with
  # LOS 20: ~1000 of the 1175 lock projects were already checked out at LOS 20's
  # revisions, resync.sh treats an existing checkout as done, and the
  # directory-existence check above cannot see the difference. verify-lock.py is
  # file-level (lock/coverage/pin agreement) and never inspects this disk. So
  # compare every synced project's on-disk HEAD against the lock itself (tag pins
  # resolved to commit SHAs), re-sync exactly what drifted, and re-audit. This is
  # the check that would have failed 302572 in seconds instead of at `lunch`.
  revision_audit() {
    # Writes a bounded report to $1 (first line: "OK ...", "MISSING n" or
    # "MISMATCH n"; one "missing <path> ..."/"mismatch <path> ..." line per
    # offender), echoes the first line to stdout for the build log, and exits
    # nonzero when anything on disk disagrees with the lock.
    #
    # $2 is optional: the `repo manifest -r` output. When it is present and a
    # project's revision is in it, that resolved commit is the yardstick - see
    # below. When it is absent (or does not cover a project) the pin is resolved
    # in the project's own git dir instead, which is the same answer for every
    # tree whose refs survived.
    LOCK_XML="$LOCK_XML" WORKSPACE="$WORKSPACE" python3 - "$1" "${2:-}" <<'PY' || return $?
import os, re, subprocess, sys, xml.etree.ElementTree as ET

try:
    sys.stdout.reconfigure(newline="\n")
except (AttributeError, ValueError):
    pass

ws = os.environ["WORKSPACE"]
root = ET.parse(os.environ["LOCK_XML"]).getroot()

# A 40-hex pin names its own commit, so it needs no resolution at all. Anything
# else (a tag) has to be resolved inside the project that pins it - see below.
SHA_RE = re.compile(r"[0-9a-f]{40}")

rows = []
for p in root.findall("project"):
    groups = {g.strip() for g in (p.get("groups") or "").split(",") if g.strip()}
    if "notdefault" in groups:
        continue
    path = p.get("path") or p.get("name")
    rev = p.get("revision") or ""
    rows.append((path, rev))


def git_in(project_path, *args):
    """Run git inside ONE project's own git dir; stripped stdout, or None."""
    try:
        out = subprocess.run(
            ["git", "-C", os.path.join(ws, project_path)] + list(args),
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


# The recipe hands us `repo manifest -r` when it could produce it. That is repo's
# OWN revision resolution, and it is strictly better than anything re-derived here:
# 872 of this lock's 1175 active projects are pinned to refs/tags/android-12.1.0_r22,
# and an AOSP release tag is a DIFFERENT commit in every repository, so a tag pin can
# only be settled by the resolution repo itself performed. Re-deriving it in a shell
# heredoc is how this audit used to compare 872 correct projects against one arbitrary
# repository's tag. Only entries repo actually resolved to a concrete commit are
# taken; a revision left as a moving ref is ignored so it can never be used as a
# yardstick (falling back is strictly better than comparing HEAD to refs/heads/*).
resolved = {}
resolved_arg = sys.argv[2] if len(sys.argv) > 2 else ""
if resolved_arg and os.path.exists(resolved_arg):
    try:
        rroot = ET.parse(resolved_arg).getroot()
    except ET.ParseError as exc:
        print("note: cannot parse %s (%s); resolving pins locally instead" % (resolved_arg, exc),
              file=sys.stderr)
        rroot = None
    if rroot is not None:
        for el in rroot.findall("project"):
            rpath = el.get("path") or el.get("name")
            rrev = el.get("revision") or ""
            if rpath and SHA_RE.fullmatch(rrev):
                resolved[rpath] = rrev


missing = []
mismatch = []
# How much of this verdict rests on repo's own resolution, and how much on the
# weaker per-project fallback. Reported on the OK line because a partial witness is
# normal on a depth-1 pre-seeded tree, and "(resolved via repo manifest -r)" on its
# own would read as "repo settled all of them" when it may have settled two.
via_witness = 0
sha_pins = 0
in_project = 0
for path, rev in rows:
    if not os.path.exists(os.path.join(ws, path, ".git")):
        missing.append(path)
        continue
    head = git_in(path, "rev-parse", "HEAD")
    if head is None:
        mismatch.append((path, "rev-parse failed"))
        continue
    if not rev:
        mismatch.append((path, "lock entry carries no revision"))
        continue
    if path in resolved:
        # repo resolved this pin; its answer is the lock's answer, by construction.
        want = resolved[path]
        via_witness += 1
    elif SHA_RE.fullmatch(rev):
        # A SHA names its own commit, so it is never in doubt and needs no witness.
        want = rev
        sha_pins += 1
    else:
        # No resolved manifest for this project: resolve the pin in the project's own
        # git dir, which is what repo would do for it too.
        want = git_in(path, "rev-parse", rev + "^{commit}")
        if not want:
            mismatch.append(
                (path, "lock pins %s but this project's own checkout does not resolve it" % rev)
            )
            continue
        in_project += 1
    if head != want:
        mismatch.append((path, "on-disk %s, locked %s (%s)" % (head[:12], want[:12], rev[:28])))

lines = []
if not missing and not mismatch:
    # Say exactly which yardstick produced this verdict, and how much of it came from
    # where. "OK" has to mean the same thing in every mode, and a reader deciding
    # whether the tree was actually proven by repo - rather than by a local fallback
    # on a shallow tree - has to be able to tell the difference from one line.
    how = []
    if via_witness:
        how.append("%d/%d resolved via repo manifest -r" % (via_witness, len(rows)))
    else:
        how.append("no repo manifest -r witness")
    if sha_pins:
        how.append("%d SHA pins" % sha_pins)
    if in_project:
        how.append("%d resolved in-project" % in_project)
    lines.append(
        "OK all %d active projects on disk at their locked revisions (%s)"
        % (len(rows), ", ".join(how))
    )
else:
    if missing:
        lines.append("MISSING %d (no checkout at all)" % len(missing))
        lines.extend("missing %s (directory has no .git)" % path for path in missing)
    if mismatch:
        lines.append("MISMATCH %d (checkout content differs from the lock)" % len(mismatch))
        lines.extend("mismatch %s %s" % (path, why) for path, why in mismatch)

report = sys.argv[1] if len(sys.argv) > 1 else "-"
text = "\n".join(lines) + "\n"
if report == "-":
    sys.stdout.write(text)
else:
    with open(report, "w", encoding="utf-8") as fh:
        fh.write(text)
    # First line to the build log as well, so the remote log is self-describing.
    print(lines[0])
sys.exit(0 if not missing and not mismatch else 3)
PY
  }

  # Force each drifted project's worktree back to a pristine state before the
  # forced re-sync. $1 = workspace root; the remaining args are project paths.
  #
  # WHY (job 302857, 2026-10-01): the targeted network re-sync of 1063 drifted
  # projects ran to 90%+ and then died on ONE project:
  #   prebuilts/clang/host/linux-x86/: error: Your local changes to the following
  #   files would be overwritten by checkout: clang-r450784d/bin/clang++.real,
  #   clang-r450784d/bin/clang-14 ... Aborting
  # The Crave base image ships that project with locally-modified tracked files;
  # `repo sync` applies a revision with `git read-tree -m -u`, which refuses to
  # overwrite local modifications - and `--force-sync` only forces the GIT DIR,
  # never the worktree. One dirty file therefore fails the whole re-sync. So we
  # `git reset --hard` (discard tracked modifications) and `git clean -fd`
  # (remove untracked files that would equally block the checkout) first. Both
  # are correct for a provenance build: the tree must equal the lock exactly, so
  # nothing outside the lock may survive into it. Missing checkouts (no .git)
  # have nothing to clean and are skipped - `repo sync` materializes those from
  # scratch.
  #
  # A checkout whose .git exists but whose HEAD never landed (the fetch died, so
  # the audit reported it as `rev-parse failed`) is the same case one step later:
  # `git reset --hard HEAD` dies on an unborn HEAD, and returning nonzero here
  # would kill the very `repo sync` that rebuilds it. So reset only when there is
  # a HEAD to reset to, and always drop untracked debris.
  sanitize_worktrees() {
    local ws="$1"; shift
    local p
    for p in "$@"; do
      [ -e "$ws/$p/.git" ] || continue
      if git -C "$ws/$p" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        git -C "$ws/$p" reset -q --hard HEAD || return 1
      fi
      git -C "$ws/$p" clean -qfd || return 1
    done
  }

  log "revision audit: every on-disk project HEAD must match the lock"
  audit_out="$OUT_DIR/revision-audit.txt"
  if revision_audit "$audit_out" "$resolved_manifest"; then
    printf '  %s\n' "$(head -1 "$audit_out")"
  else
    mapfile -t drifted_paths < <(sed -n 's/^\(missing\|mismatch\) \([^ ]*\) .*/\2/p' "$audit_out" | sort -u)
    printf '  %s\n' "$(head -1 "$audit_out")"
    # Guard against the worst possible failure mode of this parser: an empty path
    # list handed to `repo sync` is NOT a no-op - it means a FULL re-sync of all
    # 1175 projects, the multi-hundred-GB step the Crave rule forbids. If the
    # report yielded no paths, that is a bug in the audit's report format; stop.
    if [ "${#drifted_paths[@]}" -eq 0 ]; then
      die "revision audit failed but the report named no per-project paths (see $audit_out) - refusing to run an unscoped repo sync; fix the report format."
    fi
    log "re-syncing ${#drifted_paths[@]} project(s) whose checkout content differs from the lock"
    # The checkout below aborts on any local modification or untracked file that
    # collides with the locked revision (job 302857), so clear those first.
    sanitize_worktrees "$WORKSPACE" "${drifted_paths[@]}" \
      || die "could not sanitize a drifted worktree (git reset --hard / git clean failed - see the project above); refusing to run a forced sync whose checkout would abort."
    printf '  sanitized %s drifted worktree(s) (local modifications/untracked files discarded)\n' "${#drifted_paths[@]}"
    # Try local-only first (instant if the workspace happens to hold the objects),
    # then fall back to a TARGETED network sync. The fallback matters because this
    # workspace was seeded with --depth=1 at LOS 20's revisions: the lock's SHAs
    # are simply not present as local objects there, so -l cannot satisfy them.
    # Either way the sync is scoped to the drifted paths only - never full-tree.
    if ! repo sync -l --force-sync "${drifted_paths[@]}"; then
      log "local-only sync could not satisfy the locked revisions (expected on a depth-1 pre-seeded tree) - falling back to a targeted network sync of the same paths"
      repo sync -c -j"$SYNC_JOBS" --no-manifest-update --no-tags --force-sync "${drifted_paths[@]}" \
        || die "re-sync of the drifted projects failed (see above). The locked revisions must be fetchable from their remotes; if a pinned SHA is unreachable upstream, re-cut the lock (tools/manifest/resolve-manifest-lock.py)."
    fi
    # Re-resolve BEFORE the re-audit, not just before the canonical check below.
    #
    # The witness handed to this audit was generated before the repair, so it
    # describes the tree that FAILED the first audit. Judging the repaired tree
    # against it is the stale-yardstick bug in its purest form, and this is the
    # last gate before lunch/make - so a wrong answer here dies a job that already
    # paid for the full sync. Two concrete ways it goes wrong:
    #
    #   * false drift. The re-sync moved projects onto the locked revisions. If
    #     anything about the tree's resolution changed in the meantime, the old
    #     witness disagrees with a tree that is now correct, the re-audit fails,
    #     and the build dies on the tree it just repaired.
    #   * a missed drift. If a pin was unresolvable the FIRST time round (a
    #     depth-1 pre-seeded tree simply does not hold the locked objects), the
    #     audit skipped it and fell back to a local lookup - the weaker method this
    #     whole change exists to remove. The re-sync is exactly what brought those
    #     objects in, so re-resolving now can settle those projects through repo
    #     where before it could not.
    #
    # A failure here is non-fatal and leaves no witness, so the re-audit falls back
    # to per-project resolution rather than using a stale one.
    log "re-resolving the manifest after the repair, so the re-audit judges the tree it just produced"
    resolve_witness "$resolved_manifest" || true
    if ! revision_audit "$audit_out" "$resolved_manifest"; then
      printf '  %s\n' "$(head -1 "$audit_out")"
      die "on-disk revisions STILL disagree with the lock after a forced re-sync (full report: $audit_out) - refusing to build a tree that is not the locked one."
    fi
    printf '  %s\n' "$(head -1 "$audit_out")"
  fi

  log "canonical check: repo manifest -r against the committed X1 lock"
  # Regenerated here regardless, so the witness that gates the build describes the
  # tree that is about to be built. The re-audit above already refreshed it, but this
  # one is mandatory and must not inherit anything from an earlier step.
  resolve_witness "$resolved_manifest" required
  cd "$REPO_ROOT"
  # --repo-manifest makes verify-lock.py CHECK that witness rather than just assert it
  # in the provenance record: every lock path present and nothing extra, every SHA pin
  # matched exactly, and every tag pin resolved to a concrete commit. Without this the
  # claim in x2-provenance.json ("checked with tools/manifest/verify-lock.py") was
  # never actually verified by anything.
  python3 tools/manifest/verify-lock.py --repo-manifest "$resolved_manifest" \
    || die "the synced tree does not match the committed X1 lock - stopping before the build"
else
  log "SKIP_SYNC set - reusing the existing workspace (debug only)"
  cd "$WORKSPACE"
fi

# ------------------------------------------------------------------- build ---
# envsetup.sh is NOT at a fixed path. A classic AOSP/Lineage tree has it at
# build/envsetup.sh, but this lock is an Android-12-era Bliss x86 tree in which
# build/ already holds soong, blueprint, bazel and pesto as sibling projects, so
# platform_build is pinned at build/make and envsetup.sh is build/make/envsetup.sh.
# Crave job 302572 queued for 23h, synced all 1175 projects, passed the X1 lock
# check, and then died on a hardcoded `source build/envsetup.sh` for exactly this
# reason. Ask the lock we already verified, then fall back to both known layouts.
ENVSETUP=""
lock_build_path="$(sed -n 's/.*name="platform_build"[^>]*path="\([^"]*\)".*/\1/p' \
  "$REPO_ROOT/image/manifest/arcadia-x86.pinned.xml" 2>/dev/null | head -1)" || lock_build_path=""
for cand in "$lock_build_path" build build/make; do
  [ -n "$cand" ] || continue
  if [ -f "$WORKSPACE/$cand/envsetup.sh" ]; then
    ENVSETUP="$cand/envsetup.sh"
    break
  fi
done
[ -n "$ENVSETUP" ] || die "no envsetup.sh in the synced tree (lock says platform_build at '${lock_build_path:-<unresolved>}'; also tried build/ and build/make/) - the AOSP build system did not land on disk."

# The lunch combo and the goal are the recipe's last two hardcoded assumptions, so
# they get the same treatment as the envsetup path: prove the manifest-backed tree
# actually provides them BEFORE the build starts, instead of discovering it after a
# 23h queue plus a full sync. Which device trees even exist is read out of the lock,
# never guessed - `device/generic/x86_64` ships in both AOSP and BlissRoms-x86, and
# only the BlissRoms-x86 one declares bliss_x86_64 (AOSP's declares aosp_x86_64), so
# a lock that resolved that path to the wrong remote would silently break `lunch`.
log "preflight: the manifest-backed tree provides $LUNCH_TARGET"
PRODUCT="${LUNCH_TARGET%%-*}"   # bliss_x86_64-userdebug -> bliss_x86_64
lock_device_paths="$(sed -n 's/.*path="\(device\/[^"]*\)".*/\1/p' \
  "$REPO_ROOT/image/manifest/arcadia-x86.pinned.xml" 2>/dev/null)" || lock_device_paths=""
[ -n "$lock_device_paths" ] || die "no device/ projects in the lock - cannot confirm $LUNCH_TARGET exists; refusing to start a build that cannot lunch."
product_mk=""
combo_mk=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  mk="$WORKSPACE/$p/AndroidProducts.mk"
  [ -f "$mk" ] || continue
  # A product is offered iff its makefile is listed in PRODUCT_MAKEFILES.
  grep -q "$PRODUCT\.mk" "$mk" || continue
  product_mk="$mk"
  # Newer trees also gate the combo: a product can exist for `make` while the exact
  # <product>-<variant> lunch pair is not offered.
  if grep -qE "^[[:space:]]*$LUNCH_TARGET[[:space:]]*$" "$mk"; then
    combo_mk="$mk"
  fi
  break
done <<<"$lock_device_paths"
if [ -z "$product_mk" ]; then
  die "the synced tree offers no product '$PRODUCT' for LUNCH_TARGET='$LUNCH_TARGET' (scanned the $(printf '%s' "$lock_device_paths" | grep -c . ) device/ trees the lock declares, looking for '$PRODUCT.mk' in AndroidProducts.mk). The lock and LUNCH_TARGET disagree - fix one of them; do not build."
fi
if [ -z "$combo_mk" ]; then
  echo "note: '$LUNCH_TARGET' is not in COMMON_LUNCH_CHOICES in $product_mk; lunch may still resolve it by product name"
fi
# The make goal is deliberately NOT pre-checked: an unknown goal costs make a second
# to reject, and after the sync has already happened that is the cheap failure. The
# lunch combo is the expensive-to-diagnose one, because a wrong combo and a missing
# device tree look identical from the outside.
printf '  product makefile: %s\n' "$product_mk"

log "build: source $ENVSETUP && lunch $LUNCH_TARGET && make $MAKE_TARGET"
cd "$WORKSPACE"
# shellcheck disable=SC1091
source "$ENVSETUP"
lunch "$LUNCH_TARGET"
make -j"$JOBS" "$MAKE_TARGET"

log "SBOM (best effort - not every tree supports it)"
if ! ( source "$ENVSETUP" && lunch "$LUNCH_TARGET" && m sbom ) >/dev/null 2>&1; then
  echo "note: 'm sbom' unavailable in this tree; SBOM will be generated at release time (M1 section 7)"
fi

# --------------------------------------------------------------- evidence ----
log "X2 provenance record"
cd "$REPO_ROOT"
MANIFEST_REVISION="$MANIFEST_REVISION" LUNCH_TARGET="$LUNCH_TARGET" MAKE_TARGET="$MAKE_TARGET" \
PYTHONPATH="$REPO_ROOT" python3 - "$WORKSPACE" "$OUT_DIR" <<'PY'
import datetime, hashlib, json, os, pathlib, platform, shutil, sys

ws, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])


def find_artifacts(root):
    """Find the built .iso/.img artifacts without walking the whole AOSP out/ tree.

    `iso_img` writes under out/target/product/<device>/, while out/ itself holds
    hundreds of GB and millions of inodes - so a recursive `out/**` scan is minutes
    of I/O to locate a handful of files. Scan the product dirs first in a SINGLE pass
    over both extensions, and fall back to a full out/ scan only when that finds
    nothing, so a tree that writes its artifact somewhere else is still recorded.
    """
    def scan(base):
        hits = []
        for dirpath, _dirs, filenames in os.walk(base):
            for name in filenames:
                if name.endswith('.iso') or name.endswith('.img'):
                    hits.append(pathlib.Path(dirpath) / name)
        return hits

    product = root / 'out' / 'target' / 'product'
    hits = scan(product) if product.is_dir() else []
    if not hits:
        hits = scan(root / 'out')
    return sorted(hits)


imgs = find_artifacts(ws)
records = []
for p in imgs:
    h = hashlib.sha256()
    with p.open('rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    size = p.stat().st_size
    digest = h.hexdigest()
    records.append({'artifact': p.name, 'sha256': digest, 'bytes': size})
    print('  %s  %s  %d bytes' % (digest, p.name, size))
    # The image lives deep in the AOSP out/ tree. Copy it next to the provenance
    # record so a single `crave pull image/out/` retrieves the artifact and its hash
    # together - the build host is ephemeral from the operator's point of view.
    dest = out_dir / p.name
    if not dest.exists() or dest.stat().st_size != size:
        print('  copying -> %s' % dest)
        shutil.copy2(p, dest)

rec = {
    'criterion': 'M2 X2 - guest artifact provenance',
    'kind': 'built-from-pinned-manifest',
    'manifest_url': 'https://github.com/BlissRoms-x86/manifest.git',
    'manifest_revision': os.environ.get('MANIFEST_REVISION', ''),
    'lunch': os.environ.get('LUNCH_TARGET', ''),
    'make_target': os.environ.get('MAKE_TARGET', ''),
    'build_host': platform.platform(),
    'build_utc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'provenance_anchor': 'image/manifest/arcadia-x86.pinned.xml (X1 per-project lock)',
    'lock_confirmed_by': 'repo manifest -r, checked with tools/manifest/verify-lock.py',
    'artifacts': records,
}
(out_dir / 'x2-provenance.json').write_text(json.dumps(rec, indent=2) + '\n')
(out_dir / 'artifacts.txt').write_text('\n'.join(r['artifact'] for r in records) + '\n')
print(json.dumps(rec, indent=2))
if not records:
    print('note: no .iso/.img found under out/ - check MAKE_TARGET')
PY

log "done - pull these back"
echo "  $OUT_DIR/x2-provenance.json"
echo "  $OUT_DIR/artifacts.txt"
echo "  the image itself"
echo
echo "On Crave:  crave pull image/out/"
echo "Then verify the sha256 above, and run M2 X3-X5 with the frozen launcher:"
echo "  .\\tools\\qemu\\provision-host.ps1 -Check"
echo "  .\\tools\\qemu\\launch-emberbird.ps1 -Image <path> -DryRun"
echo "  .\\tools\\qemu\\launch-emberbird.ps1 -Image <path>"
