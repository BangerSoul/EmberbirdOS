#!/usr/bin/env python3
"""Resolve the BlissRoms-x86 ``arcadia-x86`` repo manifest into a per-project
revision lock -- EmberbirdOS M2 exit criterion **X1**.

The pinned manifest (manifest-repo revision ``98a0a79...``, branch
``arcadia-x86``) inherits, for the great majority of its projects, an
*immutable* AOSP release tag (``refs/tags/android-12.1.0_r22``). Those projects
are therefore already reproducibly locked by the tag alone. The projects that
actually *move* are the BlissRoms / android-x86 / LineageOS forks that track
*mutable* branches (e.g. ``arcadia-next``, ``arcadia``, a lineage branch). This
tool re-resolves exactly those moving refs to commit SHAs and emits a manifest
in which **every** project carries an immutable revision -- the same lock
``repo manifest -r`` produces.

Canonical confirmation at build time remains ``repo sync && repo manifest -r``;
this network-only resolver produces the same lock without the multi-GB source
sync that is infeasible on the Windows host used for M2 authoring (no ``repo``,
no Linux/WSL build environment). See ``docs/M2-GUEST-BOOT-PROOF.md``.

Inputs
    image/manifest/upstream/   default.xml + all includes, captured at the pin.
Outputs
    image/manifest/arcadia-x86.pinned.xml   the lock (every project immutable).
    image/manifest/lock-coverage.json       per-project resolution report.
    image/manifest/.lock-checkpoint.json     resumable ls-remote result cache.

Exit status is 0 when every project resolved to an immutable revision, else 1
(with the unresolved projects enumerated in lock-coverage.json). The lock is
still emitted on partial resolution -- unresolved projects retain their branch
revision, flagged with an ``emberbird-unresolved`` attribute so the gap is
never silent.

Usage (from the repository root)::

    python tools/manifest/resolve-manifest-lock.py
    python tools/manifest/resolve-manifest-lock.py --offline      # classify only
    python tools/manifest/resolve-manifest-lock.py --workers 24 --timeout 60

Determinism: ``pinned.xml`` is byte-stable (CRLF, projects sorted by ``path``,
remotes sorted by ``name``), so re-running the resolver against an unchanged
upstream produces an identical file and a re-lock is a meaningful diff. The one
deliberately non-reproducible field is ``lock-coverage.json``'s
``generated_from``, which records the absolute path of the input manifest on the
machine that ran the resolution; every other field is machine-independent.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

SHA_RE = re.compile(r"^[0-9a-f]{40}$")

#: Manifest-repository revision this lock is anchored to (see
#: ``image/manifest/arcadia-x86.pin.json``). Overridden by the pin record when
#: that file is present.
PIN = "98a0a79cfffbb2cb9eb43dbaf5575a0195162bcf"

#: Line ending used for every emitted artifact. All three outputs (lock XML,
#: coverage report, checkpoint) are written with CRLF so a re-run on Linux CI is
#: byte-identical to one on Windows.
NEWLINE = "\r\n"

PIN_FILENAME = "arcadia-x86.pin.json"


class Manifest:
    """Flattened repo-manifest model built from default.xml + its includes."""

    def __init__(self) -> None:
        self.remotes: dict[str, dict[str, str]] = {}
        self.default: dict[str, str] = {}
        self.projects: list[dict[str, str]] = []
        self.files: list[str] = []

    def load(self, path: str, seen: set[str] | None = None) -> None:
        """Recursively parse ``path`` and every file it ``<include>``s."""
        seen = set() if seen is None else seen
        path = os.path.abspath(path)
        if path in seen:
            return
        seen.add(path)
        self.files.append(path)

        root = ET.parse(path).getroot()
        for el in root:
            tag = el.tag
            if tag == "remote":
                self.remotes[el.get("name", "")] = dict(el.attrib)
            elif tag == "default":
                self.default.update(el.attrib)
            elif tag == "project":
                self.projects.append(dict(el.attrib))
            elif tag == "remove-project":
                name = el.get("name")
                self.projects = [p for p in self.projects if p.get("name") != name]
            elif tag == "include":
                inc = el.get("name")
                if inc:
                    self.load(os.path.join(os.path.dirname(path), inc), seen)

    def effective(self, proj: dict[str, str]) -> tuple[str | None, str | None, str | None]:
        """Return (remote_name, git_url, revision) for a project after applying
        remote and default fallbacks. Any component may be None if undefined."""
        remote_name = proj.get("remote") or self.default.get("remote")
        remote = self.remotes.get(remote_name or "", {})

        revision = proj.get("revision") or remote.get("revision") or self.default.get("revision")

        fetch = remote.get("fetch")
        name = proj.get("name")
        url = None
        if fetch:
            url = fetch.rstrip("/") + "/" + (name or "").lstrip("/")
        return (remote_name, url, revision)


def classify(revision: str | None) -> str:
    """Bucket a revision string: 'sha' and 'tag' are already immutable; a bare
    branch/ref name is 'branch' (must be resolved); 'none' means undefined."""
    if not revision:
        return "none"
    if SHA_RE.fullmatch(revision):
        return "sha"
    if revision.startswith("refs/tags/"):
        return "tag"
    return "branch"


def _pick_ref_line(stdout: str, ref: str) -> tuple[str | None, str | None]:
    """Choose the authoritative ls-remote line for ``ref``: an exact,
    non-peeled ref-column match first, then the first non-peeled line."""
    best: tuple[str | None, str | None] = (None, None)
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        sha, name = parts[0].strip(), parts[1].strip()
        if name.endswith("^{}"):
            continue  # peeled tag object -- never the commit we want
        if name == ref:
            return (sha, name)
        if best[0] is None:
            best = (sha, name)
    return best


def ls_remote(
    url: str, revision: str, timeout: int, retries: int
) -> tuple[str | None, str | None, str]:
    """Resolve a mutable ``revision`` on ``url`` to a 40-hex commit SHA.

    Returns ``(sha, resolved_ref, error)``; ``sha`` is None on failure and
    ``error`` then carries the last diagnostic. Tries the most specific ref
    first (an explicit ``refs/...``, else heads/tags/bare) and retries with
    linear backoff -- but only the candidates that failed for a TRANSIENT
    reason. A candidate whose ``git ls-remote`` exited 0 and simply matched no
    ref is a definitive answer for that ref, so retrying it would only repeat a
    network round trip -- and hold this pool worker in backoff while it does."""
    if revision.startswith("refs/"):
        pending = [revision]
    else:
        pending = ["refs/heads/" + revision, "refs/tags/" + revision, revision]

    error = "no matching ref"
    for attempt in range(max(1, retries)):
        if attempt:
            time.sleep(min(2.0 * attempt, 5.0))  # linear backoff, capped
        retry_next: list[str] = []
        for ref in pending:
            try:
                proc = subprocess.run(
                    ["git", "ls-remote", url, ref],
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
            except subprocess.TimeoutExpired:
                error = "timeout after %ss" % timeout
                retry_next.append(ref)
                continue
            except OSError as exc:
                error = "git exec failed: %s" % exc
                retry_next.append(ref)
                continue
            if proc.returncode != 0:
                error = "git ls-remote exit %d" % proc.returncode
                retry_next.append(ref)
                continue
            sha, matched = _pick_ref_line(proc.stdout, ref)
            if sha and SHA_RE.fullmatch(sha):
                return (sha, matched, "")
            # exit 0 with no match is permanent for this ref: never retried.
            error = "no matching ref"
        pending = retry_next
        if not pending:
            break
    return (None, None, error)


def build_records(man: Manifest) -> list[dict[str, str]]:
    """One record per project, classified and (for already-immutable revisions)
    pre-locked. Branch/none revisions are left for network resolution."""
    records: list[dict[str, str]] = []
    for proj in sorted(man.projects, key=lambda p: p.get("path") or p.get("name") or ""):
        remote_name, url, revision = man.effective(proj)
        kind = classify(revision)
        status = "pending"
        locked = None
        error = None
        if kind in ("sha", "tag"):
            locked, status = revision, "already-locked"
        elif kind == "none":
            status, error = "unresolved", "no revision"
        rec = {
            "name": proj.get("name"),
            "path": proj.get("path") or proj.get("name"),
            "remote": remote_name,
            "url": url,
            "groups": proj.get("groups"),
            "orig_revision": revision,
            "kind": kind,
            "locked_revision": locked,
            "resolved_ref": None,
            "status": status,
            "error": error,
            # internal: attributes as *declared* in the manifest, so the emitted
            # lock mirrors the upstream element shape instead of fabricating one.
            "_declared": dict(proj),
        }
        records.append(rec)
    return records


def _ckey(url: str, revision: str) -> str:
    return "%s\x00%s" % (url, revision)


def resolve_all(
    records: list[dict[str, str]],
    workers: int,
    timeout: int,
    retries: int,
    checkpoint_path: str,
    log=print,
) -> None:
    """Resolve every branch-revision record to a SHA, concurrently, mutating
    records in place. Results are cached by (url, revision) in a JSON checkpoint
    that is loaded up front and rewritten after each completion, so an
    interrupted run resumes without repeating network work."""
    cache: dict[str, dict[str, str]] = {}
    if checkpoint_path and os.path.exists(checkpoint_path):
        try:
            with open(checkpoint_path, encoding="utf-8") as fh:
                cache = json.load(fh)
        except (OSError, ValueError):
            cache = {}

    def save() -> None:
        if not checkpoint_path:
            return
        tmp = checkpoint_path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline=NEWLINE) as fh:
            json.dump(cache, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, checkpoint_path)

    todo: dict[str, tuple[str, str]] = {}
    for rec in records:
        if rec["kind"] != "branch":
            continue
        url, revision = rec["url"], rec["orig_revision"]
        if not url or not revision:
            continue
        key = _ckey(url, revision)
        hit = cache.get(key)
        if hit and hit.get("sha"):
            continue
        todo[key] = (url, revision)

    if todo:
        log(
            "resolving %d unique moving refs via git ls-remote (workers=%d) ..."
            % (len(todo), max(1, workers))
        )
        done = 0
        total = len(todo)
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
            futures = {
                pool.submit(ls_remote, url, revision, timeout, retries): key
                for key, (url, revision) in todo.items()
            }
            for fut in concurrent.futures.as_completed(futures):
                key = futures[fut]
                url, revision = todo[key]
                try:
                    sha, ref, error = fut.result()
                except Exception as exc:  # pragma: no cover - defensive
                    sha, ref, error = None, None, "resolver exception: %s" % exc
                cache[key] = {"error": error or "", "ref": ref or "", "sha": sha or ""}
                done += 1
                if done % 25 == 0 or done == total:
                    log("  ... %d/%d refs resolved" % (done, total))
                    save()
        save()

    for rec in records:
        if rec["kind"] != "branch":
            continue
        url, revision = rec["url"], rec["orig_revision"]
        if not url:
            rec["status"], rec["error"] = "unresolved", "no fetch url"
            continue
        if not revision:
            rec["status"], rec["error"] = "unresolved", "no revision"
            continue
        hit = cache.get(_ckey(url, revision))
        if hit and hit.get("sha"):
            rec["locked_revision"] = hit["sha"]
            rec["resolved_ref"] = hit.get("ref") or None
            rec["status"], rec["error"] = "resolved", None
        else:
            rec["status"] = "unresolved"
            rec["error"] = (hit or {}).get("error") or "unresolved"


def _xml_escape(v: str) -> str:
    return (
        str(v)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def emit_xml(man: Manifest, records: list[dict[str, str]], pin: str, out_path: str) -> None:
    """Write a repo-manifest whose every project carries an immutable revision
    (a 40-hex SHA or a ``refs/tags/*`` tag) -- equivalent in effect to
    ``repo manifest -r``. Deterministic ordering makes it byte-stable/diffable.
    Any project that failed resolution keeps its branch revision and is flagged
    ``emberbird-unresolved`` so the gap is explicit, never silent."""
    out: list[str] = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append(
        "<!-- EmberbirdOS M2 X1 per-project lock. Generated by tools/manifest/resolve-manifest-lock.py from the pinned"
    )
    out.append(
        "     BlissRoms-x86/manifest @ %s (branch arcadia-x86). Canonical equivalent: repo manifest -r. -->"
        % _xml_escape(pin)
    )
    out.append("<manifest>")

    for name in sorted(man.remotes):
        attrs = man.remotes[name]
        parts = ['name="%s"' % _xml_escape(name)]
        if attrs.get("fetch"):
            parts.append('fetch="%s"' % _xml_escape(attrs["fetch"]))
        if attrs.get("review"):
            parts.append('review="%s"' % _xml_escape(attrs["review"]))
        if attrs.get("revision"):
            parts.append('revision="%s"' % _xml_escape(attrs["revision"]))
        out.append("  <remote " + " ".join(parts) + " />")

    if man.default:
        parts = []
        if man.default.get("remote"):
            parts.append('remote="%s"' % _xml_escape(man.default["remote"]))
        if man.default.get("revision"):
            parts.append('revision="%s"' % _xml_escape(man.default["revision"]))
        if man.default.get("sync-j"):
            parts.append('sync-j="%s"' % _xml_escape(man.default["sync-j"]))
        out.append("  <default " + " ".join(parts) + " />")

    default_remote = man.default.get("remote")
    for rec in records:
        declared = rec.get("_declared") or {}
        parts = ['name="%s"' % _xml_escape(rec["name"] or "")]
        if rec.get("path"):
            parts.append('path="%s"' % _xml_escape(rec["path"]))
        # only projects deviating from the manifest default carry a remote attr
        if rec.get("remote") and rec["remote"] != default_remote:
            parts.append('remote="%s"' % _xml_escape(rec["remote"]))
        revision = rec.get("locked_revision") or rec.get("orig_revision")
        if revision:
            parts.append('revision="%s"' % _xml_escape(revision))
        if rec.get("status") == "resolved" and rec.get("orig_revision"):
            parts.append('upstream="%s"' % _xml_escape(rec["orig_revision"]))
        if rec.get("status") == "unresolved":
            parts.append('emberbird-unresolved="true"')
        if declared.get("groups"):
            parts.append('groups="%s"' % _xml_escape(declared["groups"]))
        out.append("  <project " + " ".join(parts) + " />")

    out.append("</manifest>")

    # internal joins use \n; the file's newline= translates them to CRLF
    with open(out_path, "w", encoding="utf-8", newline=NEWLINE) as fh:
        fh.write("\n".join(out) + "\n")


def write_coverage(
    records: list[dict[str, str]],
    man: Manifest,
    pin: str,
    upstream_dir: str,
    out_path: str,
) -> dict[str, int]:
    """Emit the per-project resolution report and return its totals block."""
    totals = {
        "projects": len(records),
        "already_locked_tag": sum(1 for r in records if r["kind"] == "tag"),
        "already_locked_sha": sum(1 for r in records if r["kind"] == "sha"),
        "resolved": sum(1 for r in records if r["status"] == "resolved"),
        "unresolved": sum(1 for r in records if r["status"] == "unresolved"),
    }

    def public(rec: dict[str, str]) -> dict[str, str | None]:
        return {
            "name": rec.get("name"),
            "path": rec.get("path"),
            "remote": rec.get("remote"),
            "url": rec.get("url"),
            "groups": rec.get("groups"),
            "orig_revision": rec.get("orig_revision"),
            "kind": rec.get("kind"),
            "locked_revision": rec.get("locked_revision"),
            "resolved_ref": rec.get("resolved_ref"),
            "status": rec.get("status"),
            "error": rec.get("error"),
        }

    # canonical attribute order so the report is diff-stable regardless of the
    # order in which includes contributed to <default>
    default_keys = ["remote", "revision", "sync-j"]
    default = {k: man.default[k] for k in default_keys if k in man.default}
    default.update({k: v for k, v in sorted(man.default.items()) if k not in default})

    doc = {
        "generated_from": (Path(upstream_dir) / "default.xml").resolve().as_posix(),
        "manifest_repo_revision": pin,
        "manifest_branch": "arcadia-x86",
        "default": default,
        "remotes": {name: man.remotes[name].get("fetch") for name in sorted(man.remotes)},
        "totals": totals,
        "unresolved": [public(r) for r in records if r["status"] == "unresolved"],
        "projects": [public(r) for r in records],
    }

    with open(out_path, "w", encoding="utf-8", newline=NEWLINE) as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    return totals


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="resolve-manifest-lock.py",
        description=(
            "Resolve the pinned BlissRoms-x86 arcadia-x86 repo manifest into a "
            "per-project revision lock (EmberbirdOS M2 X1). Network-only: no repo sync."
        ),
    )
    parser.add_argument(
        "--image",
        default="image",
        help="image/ tree root, relative to the repository root (default: image)",
    )
    parser.add_argument(
        "--manifest",
        default="manifest",
        help="manifest directory inside --image, holding upstream/ (default: manifest)",
    )
    parser.add_argument(
        "--upstream-dir",
        default="upstream",
        help="directory holding the captured default.xml + includes (default: upstream)",
    )
    parser.add_argument(
        "--out-xml", default="arcadia-x86.pinned.xml", help="path of the emitted lock"
    )
    parser.add_argument(
        "--out-coverage",
        default="lock-coverage.json",
        help="path of the per-project resolution report",
    )
    parser.add_argument(
        "--checkpoint",
        default=".lock-checkpoint.json",
        help="resumable ls-remote cache (reused and rewritten in place)",
    )
    parser.add_argument("--workers", type=int, default=16, help="parallel ls-remote workers")
    parser.add_argument("--timeout", type=int, default=45, help="per ls-remote timeout, seconds")
    parser.add_argument("--retries", type=int, default=3, help="ls-remote retries per ref")
    parser.add_argument(
        "--offline",
        action="store_true",
        help="classify only; do not run git ls-remote (partial lock)",
    )
    args = parser.parse_args(argv)

    manifest_dir = os.path.join(args.image, args.manifest)
    upstream_dir = os.path.join(manifest_dir, args.upstream_dir)
    entry = os.path.join(upstream_dir, "default.xml")
    if not os.path.exists(entry):
        print("FATAL: manifest entry not found: %s" % entry, file=sys.stderr)
        return 2

    pin = PIN
    pin_path = os.path.join(manifest_dir, PIN_FILENAME)
    if os.path.exists(pin_path):
        try:
            with open(pin_path, encoding="utf-8") as fh:
                pin = json.load(fh).get("manifest", {}).get("revision", PIN)
        except (OSError, ValueError):
            pin = PIN

    man = Manifest()
    man.load(entry)
    records = build_records(man)
    print("parsed %d projects (%d remotes) from %s" % (len(man.projects), len(man.remotes), entry))
    moving = sum(1 for r in records if r["kind"] == "branch")
    print("  already immutable: %d ; moving refs to resolve: %d" % (len(records) - moving, moving))

    if args.offline:
        for rec in records:
            if rec["status"] == "pending":
                rec["status"], rec["error"] = "unresolved", "offline: not resolved"
    else:
        resolve_all(records, args.workers, args.timeout, args.retries, args.checkpoint)

    emit_xml(man, records, pin, args.out_xml)
    totals = write_coverage(records, man, pin, upstream_dir, args.out_coverage)

    print("\n== lock coverage ==")
    for k in (
        "projects",
        "already_locked_tag",
        "already_locked_sha",
        "resolved",
        "unresolved",
    ):
        print("  %-20s %d" % (k, totals[k]))
    print("wrote %s" % args.out_xml)
    print("wrote %s" % args.out_coverage)

    if totals["unresolved"]:
        print(
            "\nLOCK PARTIAL -- %d unresolved (see lock-coverage.json)" % totals["unresolved"],
            file=sys.stderr,
        )
        return 1
    print("\nLOCK COMPLETE (every project immutable)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
