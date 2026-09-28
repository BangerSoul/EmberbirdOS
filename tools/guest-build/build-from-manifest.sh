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
#   2. re-confirm the committed X1 lock against the synced tree using
#      `repo manifest -r` - the canonical build-side witness that the network-only
#      resolver (tools/manifest/resolve-manifest-lock.py) is checked against;
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
  # ~379 Bliss delta projects that LOS 20 never had (bootable/aaropa among them) are
  # absent on disk. `repo manifest -r` then dies with a raw FileNotFoundError on the first
  # missing path.
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

  log "canonical check: repo manifest -r against the committed X1 lock"
  repo manifest -r -o "$OUT_DIR/repo-manifest-r.xml" \
    || die "repo manifest -r failed - the synced tree is missing or cannot resolve a project the frozen lock references (see the sync-completeness step above), so the canonical X1 witness cannot be produced."
  cd "$REPO_ROOT"
  python3 tools/manifest/verify-lock.py || die "the synced tree does not match the committed X1 lock - stopping before the build"
else
  log "SKIP_SYNC set - reusing the existing workspace (debug only)"
  cd "$WORKSPACE"
fi

# ------------------------------------------------------------------- build ---
log "build: lunch $LUNCH_TARGET && make $MAKE_TARGET"
cd "$WORKSPACE"
# shellcheck disable=SC1091
source build/envsetup.sh
lunch "$LUNCH_TARGET"
make -j"$JOBS" "$MAKE_TARGET"

log "SBOM (best effort - not every tree supports it)"
if ! ( source build/envsetup.sh && lunch "$LUNCH_TARGET" && m sbom ) >/dev/null 2>&1; then
  echo "note: 'm sbom' unavailable in this tree; SBOM will be generated at release time (M1 section 7)"
fi

# --------------------------------------------------------------- evidence ----
log "X2 provenance record"
cd "$REPO_ROOT"
MANIFEST_REVISION="$MANIFEST_REVISION" LUNCH_TARGET="$LUNCH_TARGET" MAKE_TARGET="$MAKE_TARGET" \
PYTHONPATH="$REPO_ROOT" python3 - "$WORKSPACE" "$OUT_DIR" <<'PY'
import datetime, hashlib, json, os, pathlib, platform, shutil, sys

ws, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
imgs = sorted(p for p in list(ws.glob('out/**/*.iso')) + list(ws.glob('out/**/*.img')) if p.is_file())
records = []
for p in imgs:
    h = hashlib.sha256()
    with p.open('rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    records.append({'artifact': p.name, 'sha256': h.hexdigest(), 'bytes': p.stat().st_size})
    print('  %s  %s  %d bytes' % (h.hexdigest(), p.name, p.stat().st_size))
    # The image lives deep in the AOSP out/ tree. Copy it next to the provenance
    # record so a single `crave pull image/out/` retrieves the artifact and its hash
    # together - the build host is ephemeral from the operator's point of view.
    dest = out_dir / p.name
    if not dest.exists() or dest.stat().st_size != p.stat().st_size:
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
