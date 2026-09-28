#!/usr/bin/env python3
"""Verify the EmberbirdOS M2 X1 manifest lock -- structurally, and optionally
against a fresh live re-resolution of the pinned upstream.

The lock (``image/manifest/arcadia-x86.pinned.xml``) is only worth something if it
can be shown to say what it claims, so this checker asserts the properties the M2
exit criterion depends on:

structural (default, offline, no network)
    * every ``<project>`` carries an immutable revision -- a 40-hex SHA or a
      ``refs/tags/*`` tag -- and none is flagged ``emberbird-unresolved``;
    * the project count equals the count recorded in ``lock-coverage.json``;
    * the coverage report contains no unresolved project and no project whose
      revision disagrees with the lock;
    * the pin record (``arcadia-x86.pin.json``) revision matches the revision
      named in the lock's own header comment;
    * the pinned ``path`` values are unique (a duplicated path would silently
      collapse two components into one checkout).

``--live`` additionally re-resolves every moving ref over the network with
``resolve-manifest-lock.py``'s own machinery -- on a fresh, empty cache -- and
compares (a) each project's SHA and (b) the regenerated lock byte-for-byte
against the committed one. Any difference is reported as drift and fails the run,
because it means either the lock was corrupted or the upstream branches moved and
the lock must be re-cut.

Usage::

    python tools/manifest/verify-lock.py                 # offline structural check
    python tools/manifest/verify-lock.py --live           # + live re-resolution (CI)
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import importlib.util  # noqa: E402

_SPEC = importlib.util.spec_from_file_location(
    "resolve_manifest_lock",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "resolve-manifest-lock.py"),
)
if _SPEC is None or _SPEC.loader is None:  # pragma: no cover - defensive
    print("FATAL: could not load resolve-manifest-lock.py", file=sys.stderr)
    sys.exit(2)
resolver = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(resolver)

SHA_RE = re.compile(r"^[0-9a-f]{40}$")

# The build recipe (tools/guest-build/build-from-manifest.sh) syncs the active
# project set on a Linux host and hardcodes this count as its completeness target.
# repo's default-linux filter drops exactly the `notdefault` group, so the active
# set is (total projects - notdefault projects). If the committed lock is re-cut
# and this count changes, the recipe's 1175-guard would fail mid-build on Crave;
# we catch that drift here, at author time, instead. Keep this in lockstep with
# the EXPECTED constant in build-from-manifest.sh.
EXPECTED_ACTIVE_PROJECTS = 1175


def groups_of(project: dict[str, str]) -> set[str]:
    return {g.strip() for g in (project.get("groups") or "").split(",") if g.strip()}

PROBLEMS: list[str] = []
NOTES: list[str] = []


def problem(msg: str) -> None:
    PROBLEMS.append(msg)


def ok(msg: str) -> None:
    print("  [OK]   %s" % msg)


def note(msg: str) -> None:
    NOTES.append(msg)
    print("  [note] %s" % msg)


def immutable(revision: str | None) -> bool:
    if not revision:
        return False
    return bool(SHA_RE.fullmatch(revision)) or revision.startswith("refs/tags/")


def load_lock(path: str) -> list[dict[str, str]]:
    root = ET.parse(path).getroot()
    projects = []
    for el in root.findall("project"):
        projects.append(dict(el.attrib))
    return projects


def main(argv: list[str] | None = None) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(here, "..", ".."))
    manifest_dir = os.path.join(repo_root, "image", "manifest")

    ap = argparse.ArgumentParser(prog="verify-lock.py", description=__doc__)
    ap.add_argument("--lock", default=os.path.join(manifest_dir, "arcadia-x86.pinned.xml"))
    ap.add_argument("--coverage", default=os.path.join(manifest_dir, "lock-coverage.json"))
    ap.add_argument("--pin-json", default=os.path.join(manifest_dir, "arcadia-x86.pin.json"))
    ap.add_argument("--upstream-dir", default=os.path.join(manifest_dir, "upstream"))
    ap.add_argument(
        "--live",
        action="store_true",
        help="re-resolve every moving ref over the network and compare (fresh cache)",
    )
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--timeout", type=int, default=45)
    ap.add_argument("--retries", type=int, default=4)
    args = ap.parse_args(argv)

    print("== structural checks ==")
    if not os.path.exists(args.lock):
        problem("lock not found: %s" % args.lock)
        return 1
    projects = load_lock(args.lock)
    if not projects:
        problem("lock contains no <project> elements")

    bad_immutable = [p.get("name") for p in projects if not immutable(p.get("revision"))]
    if bad_immutable:
        problem(
            "%d project(s) do not carry an immutable revision: %s"
            % (len(bad_immutable), ", ".join(bad_immutable[:8]))
        )
    else:
        ok("all %d projects carry an immutable revision (SHA or refs/tags/*)" % len(projects))

    unresolved_flagged = [p.get("name") for p in projects if p.get("emberbird-unresolved")]
    if unresolved_flagged:
        problem("lock is PARTIAL: %d project(s) flagged emberbird-unresolved" % len(unresolved_flagged))
    else:
        ok("no project is flagged emberbird-unresolved")

    paths = [p.get("path") for p in projects]
    dupes = sorted({x for x in paths if paths.count(x) > 1})
    if dupes:
        problem("duplicate project paths in the lock: %s" % ", ".join(dupes[:8]))
    else:
        ok("project paths are unique")

    # Active-project count invariant (drift guard for the build recipe).
    # A default sync on a Linux host materializes every project EXCEPT those in the
    # `notdefault` group. build-from-manifest.sh asserts exactly this count on disk
    # before it will build, so pin it here to fail at author time if the lock is
    # re-cut in a way that changes it.
    active = [p for p in projects if "notdefault" not in groups_of(p)]
    notdefault_count = len(projects) - len(active)
    if len(active) != EXPECTED_ACTIVE_PROJECTS:
        problem(
            "active (non-notdefault) project count is %d, expected %d "
            "(%d total - %d notdefault). The lock was re-cut; update "
            "EXPECTED_ACTIVE_PROJECTS here AND the EXPECTED constant in "
            "tools/guest-build/build-from-manifest.sh together."
            % (len(active), EXPECTED_ACTIVE_PROJECTS, len(projects), notdefault_count)
        )
    else:
        ok(
            "active project count is %d (%d total - %d notdefault), matching the "
            "build recipe's completeness target"
            % (len(active), len(projects), notdefault_count)
        )

    lock_pin = None
    with open(args.lock, encoding="utf-8") as fh:
        head = fh.read(2000)
    m = re.search(r"BlissRoms-x86/manifest @ ([0-9a-f]{40})", head)
    if m:
        lock_pin = m.group(1)
    else:
        problem("lock header does not name the manifest revision it was cut from")

    pin_json = None
    if os.path.exists(args.pin_json):
        with open(args.pin_json, encoding="utf-8") as fh:
            pin_json = json.load(fh).get("manifest", {}).get("revision")
        if lock_pin and pin_json != lock_pin:
            problem("pin record revision %s != lock header revision %s" % (pin_json, lock_pin))
        else:
            ok("pin record agrees with the lock header (%s)" % (pin_json or lock_pin))
    else:
        note("no pin record at %s; header revision only" % args.pin_json)

    print("== coverage cross-check ==")
    if not os.path.exists(args.coverage):
        problem("coverage report not found: %s" % args.coverage)
    else:
        with open(args.coverage, encoding="utf-8") as fh:
            cov = json.load(fh)
        totals = cov.get("totals", {})
        if totals.get("projects") != len(projects):
            problem(
                "coverage totals.projects=%s but the lock has %d projects"
                % (totals.get("projects"), len(projects))
            )
        else:
            ok("coverage totals match the lock (%d projects)" % len(projects))
        if totals.get("unresolved"):
            problem("coverage reports %s unresolved project(s)" % totals.get("unresolved"))
        else:
            ok("coverage reports 0 unresolved")
        if cov.get("unresolved"):
            problem("coverage 'unresolved' array is not empty")
        # NB: project *names* repeat in this manifest (the same component name is
        # checked out for several branches/remotes), so the join key must be the
        # unique `path`, never the name.
        cov_by_path = {p.get("path"): p for p in cov.get("projects", [])}
        mismatched = []
        for p in projects:
            rec = cov_by_path.get(p.get("path"))
            if rec is None:
                mismatched.append("%s (absent from coverage)" % p.get("path"))
            elif rec.get("locked_revision") != p.get("revision"):
                mismatched.append(
                    "%s (%s vs %s)"
                    % (p.get("path"), rec.get("locked_revision"), p.get("revision"))
                )
        if mismatched:
            problem(
                "%d project(s) disagree between lock and coverage: %s"
                % (len(mismatched), ", ".join(mismatched[:6]))
            )
        else:
            ok("every project revision agrees between lock and coverage")

    if args.live:
        print("== live re-resolution (fresh cache, no repo sync) ==")
        man = resolver.Manifest()
        man.load(os.path.join(args.upstream_dir, "default.xml"))
        records = resolver.build_records(man)
        with tempfile.TemporaryDirectory(prefix="emberbird-verify-lock-") as tmp:
            ckpt = os.path.join(tmp, "ckpt.json")
            resolver.resolve_all(records, args.workers, args.timeout, args.retries, ckpt)
            unresolved = [r["name"] for r in records if r["status"] == "unresolved"]
            if unresolved:
                problem(
                    "live re-resolution left %d project(s) unresolved: %s"
                    % (len(unresolved), ", ".join(unresolved[:8]))
                )
            committed = {p.get("path"): p.get("revision") for p in projects}
            drift = []
            for r in records:
                want = committed.get(r["path"])
                got = r["locked_revision"] or r["orig_revision"]
                if want != got:
                    drift.append("%s: committed %s, upstream now %s" % (r["path"], want, got))
            if drift:
                problem(
                    "%d project revision(s) drifted from the committed lock:\n      %s\n"
                    "    Upstream branches moved, or the lock was edited by hand. Re-cut the lock:\n"
                    "      python tools/manifest/resolve-manifest-lock.py"
                    % (len(drift), "\n      ".join(drift[:12]))
                )
            else:
                ok("every resolved revision matches the committed lock")

            out_xml = os.path.join(tmp, "rerun.xml")
            resolver.emit_xml(man, records, lock_pin or resolver.PIN, out_xml)
            with open(out_xml, "rb") as fh:
                fresh = fh.read()
            with open(args.lock, "rb") as fh:
                committed_bytes = fh.read()
            if fresh == committed_bytes:
                ok("regenerated lock is byte-identical to the committed lock")
            else:
                a = committed_bytes.decode("utf-8", "replace").splitlines()
                b = fresh.decode("utf-8", "replace").splitlines()
                diff = list(difflib.unified_diff(a, b, "committed", "regenerated", lineterm="", n=1))
                problem(
                    "regenerated lock differs from the committed lock:\n      %s"
                    % "\n      ".join(diff[:20])
                )

    print("== result ==")
    for n in NOTES:
        print("  [note] %s" % n)
    if PROBLEMS:
        for p in PROBLEMS:
            print("  [FAIL] %s" % p, file=sys.stderr)
        print("\nLOCK VERIFICATION FAILED (%d problem(s))" % len(PROBLEMS), file=sys.stderr)
        return 1
    print("LOCK VERIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
