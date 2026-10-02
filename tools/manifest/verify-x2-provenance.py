#!/usr/bin/env python3
"""Verify a pulled M2 X2 provenance record against the artifacts actually on disk.

The build recipe writes ``image/out/x2-provenance.json`` on the Crave node, next to
the image it just hashed, and ``crave pull image/out/`` brings both back. The runbook
has always said to "verify the sha256 above" after the pull -- by hand, by eye, in
one terminal, against a number printed on a machine that no longer exists. Nothing
checked it, so a truncated download, a stale record left beside a newer image, or a
record from a different build all looked like success.

This is that check, made mechanical. It answers three questions, in the order a
mistake there is cheapest to catch:

  1. does the record describe what is actually here?  Every recorded artifact must
     exist, and its SHA-256 and byte size must match the file byte-for-byte.
  2. is the record complete?  Every ``.iso``/``.img`` sitting in the directory must
     be named in the record. Without this a record for an *older* build would
     happily validate against artifacts it never described, which is the exact
     failure a provenance record exists to prevent.
  3. was it the build we intended?  ``manifest_revision`` must equal the revision
     the committed X1 pin record names, and the record's own provenance anchor
     must name the committed lock.

An empty ``artifacts`` list is a FAILURE, never a pass: it is what a build that
compiled nothing leaves behind, and treating it as vacuously correct would hand the
X2 criterion to an empty directory.

EXIT CODES
    0  the record and the artifacts on disk agree.
    1  they do not. Something in the record is wrong, or the artifacts are not the
       ones it describes. Do not cite this record as evidence.
    2  there is nothing to check: no record has been pulled yet. This is NOT a
       pass and NOT a failure -- it means M2 X2 has not been produced, which is the
       repo's actual current state. Distinguishing it from 0 matters, because a
       caller that cannot tell "verified" from "nothing happened" will report an
       unbuilt image as a verified one.

Usage::

    python3 tools/manifest/verify-x2-provenance.py
    python3 tools/manifest/verify-x2-provenance.py --record PATH --artifacts DIR

COST
    A guest image is multiple gigabytes, so the digest is streamed in 1 MiB chunks
    rather than read whole -- which is minutes of CPU for the largest ones. That is
    the point: re-hashing is the only step here that could ever catch a corrupted
    transfer, and it is cheap next to the queue time that produced the artifact.
"""

import argparse
import hashlib
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(newline="\n")
except (AttributeError, ValueError):
    pass

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The recipe hashes exactly these two extensions (see find_artifacts() in
# build-from-manifest.sh). Anything else in image/out/ is a side file -- the record,
# artifacts.txt, crave-job.txt -- and must not be mistaken for an unrecorded build
# product, so the "complete?" check is scoped to them too.
ARTIFACT_SUFFIXES = (".iso", ".img")

SHA_RE = re.compile(r"[0-9a-f]{64}")

# Findings, in report order. Kept as a list rather than a counter so a failed run
# prints every disagreement, not just the first one -- an operator fixing a pulled
# directory does not want to re-run five times to discover five problems.
problems: list[str] = []


def problem(msg: str) -> None:
    problems.append(msg)


def ok(msg: str) -> None:
    print("[OK]   %s" % msg)


def sha256_of(path: str) -> str:
    """Stream the digest so a multi-gigabyte image never has to fit in memory."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: str) -> object:
    with open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def check_record_shape(rec: object, path: str) -> bool:
    if not isinstance(rec, dict):
        problem("%s is not a JSON object" % path)
        return False
    artifacts = rec.get("artifacts")
    if artifacts is None:
        problem("%s has no 'artifacts' key" % path)
        return False
    if not isinstance(artifacts, list):
        problem("'artifacts' is a %s, expected a list" % type(artifacts).__name__)
        return False
    if not artifacts:
        # The single most important line in this file. An empty list must never be
        # read as "nothing to disagree about".
        problem(
            "the record lists no artifacts - this build produced nothing to prove "
            "(check MAKE_TARGET; the recipe also warns 'no .iso/.img found under out/')"
        )
        return False
    return True


def check_artifacts(rec: dict, art_dir: str) -> None:
    """Every recorded artifact must be present and must hash and size as claimed."""
    entries = rec["artifacts"]
    seen: set[str] = set()

    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            problem("artifacts[%d] is a %s, expected an object" % (i, type(entry).__name__))
            continue

        name = entry.get("artifact")
        if not name or not isinstance(name, str):
            problem("artifacts[%d] has no 'artifact' name" % i)
            continue

        # A record is data, not a path to follow. Refuse separators and parent refs
        # so a corrupt or tampered record cannot steer this checker at some other
        # file on the machine and report a "match" for it.
        if os.path.basename(name) != name or name in (".", ".."):
            problem(
                "artifacts[%d] names %r, which is not a plain file name - refusing "
                "to follow it" % (i, name)
            )
            continue

        if name in seen:
            problem("'%s' is listed more than once in the record" % name)
        seen.add(name)

        claimed_sha = entry.get("sha256") or ""
        if not SHA_RE.fullmatch(claimed_sha):
            problem("'%s' has no valid 64-hex sha256 (got %r)" % (name, claimed_sha))
            continue

        claimed_bytes = entry.get("bytes")
        if not isinstance(claimed_bytes, int) or claimed_bytes < 0:
            problem("'%s' has no valid byte count (got %r)" % (name, claimed_bytes))
            continue

        path = os.path.join(art_dir, name)
        if not os.path.isfile(path):
            problem("'%s' is in the record but not in %s" % (name, art_dir))
            continue

        actual_bytes = os.path.getsize(path)
        if actual_bytes != claimed_bytes:
            problem(
                "'%s' is %d bytes on disk but the record says %d"
                % (name, actual_bytes, claimed_bytes)
            )
            # A size disagreement means the bytes differ, so re-hashing a
            # known-wrong file only costs minutes to learn nothing.
            continue

        actual_sha = sha256_of(path)
        if actual_sha != claimed_sha:
            problem(
                "'%s' hashes to %s but the record says %s"
                % (name, actual_sha[:16], claimed_sha[:16])
            )
            continue

        ok("'%s' matches the record (%d bytes, sha256 %s...)" % (name, claimed_bytes, actual_sha[:16]))

    check_no_unrecorded(art_dir, seen)


def check_no_unrecorded(art_dir: str, recorded: set[str]) -> None:
    """Reject a build product nobody recorded.

    Without this the natural failure -- an old record sitting next to a newly pulled
    image -- validates cleanly, because the checker only ever looks at what the
    record names. The record is supposed to be the complete account of the pull.
    """
    if not os.path.isdir(art_dir):
        return
    for name in sorted(os.listdir(art_dir)):
        if not name.endswith(ARTIFACT_SUFFIXES):
            continue
        if name not in recorded:
            problem(
                "'%s' is in %s but not in the record - this is not the build the "
                "record describes" % (name, art_dir)
            )


def check_revision(rec: dict, pin_path: str) -> None:
    """The build must have come from the manifest revision the X1 pin names."""
    claimed = rec.get("manifest_revision") or ""
    if not claimed:
        problem("the record has no 'manifest_revision'")
        return
    if not os.path.isfile(pin_path):
        problem("the X1 pin record is missing: %s" % pin_path)
        return
    try:
        pin = load_json(pin_path)
    except (OSError, ValueError) as exc:
        problem("cannot read the X1 pin record %s (%s)" % (pin_path, exc))
        return
    want = ""
    if isinstance(pin, dict):
        manifest = pin.get("manifest")
        if isinstance(manifest, dict):
            want = manifest.get("revision") or ""
    if not want:
        problem("the X1 pin record %s names no manifest.revision" % pin_path)
        return
    if claimed != want:
        problem(
            "manifest_revision %s does not match the pinned %s (%s)"
            % (claimed[:12] or "<empty>", want[:12], pin_path)
        )
        return
    ok("manifest_revision %s matches the committed X1 pin" % want[:12])


def check_anchor(rec: dict, lock_path: str) -> None:
    """The record's own provenance anchor must be the committed lock, and exist."""
    anchor = rec.get("provenance_anchor") or ""
    if not anchor:
        problem("the record has no 'provenance_anchor'")
        return
    named = anchor.split()[0]
    if os.path.basename(named) != os.path.basename(lock_path):
        problem(
            "provenance_anchor names %r, not the committed lock %s"
            % (named, lock_path)
        )
        return
    # The anchor is recorded repo-relative, so resolve it against the repository
    # root rather than the caller's cwd -- otherwise the answer would depend on
    # where the operator happened to run the check from.
    resolved = named if os.path.isabs(named) else os.path.join(REPO, named)
    if not os.path.isfile(resolved):
        problem("provenance_anchor names %s, which does not exist" % named)
        return
    ok("provenance_anchor is the committed X1 lock")
    confirmed = rec.get("lock_confirmed_by") or ""
    if "verify-lock.py" not in confirmed:
        problem(
            "lock_confirmed_by does not say the lock was checked with verify-lock.py "
            "(got %r)" % confirmed
        )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Verify a pulled X2 provenance record against the artifacts on disk."
    )
    ap.add_argument(
        "--record",
        default=os.path.join(REPO, "image", "out", "x2-provenance.json"),
        help="path to x2-provenance.json (default: image/out/x2-provenance.json)",
    )
    ap.add_argument(
        "--artifacts",
        default=None,
        help="directory holding the pulled artifacts (default: the record's directory)",
    )
    ap.add_argument(
        "--pin",
        default=os.path.join(REPO, "image", "manifest", "arcadia-x86.pin.json"),
        help="the committed X1 pin record to compare manifest_revision against",
    )
    ap.add_argument(
        "--lock",
        default=os.path.join(REPO, "image", "manifest", "arcadia-x86.pinned.xml"),
        help="the committed X1 lock the provenance anchor must name",
    )
    args = ap.parse_args()

    if not os.path.isfile(args.record):
        print(
            "no provenance record at %s - nothing has been pulled yet, so there is "
            "nothing to verify (M2 X2 is still OPEN)" % args.record
        )
        return 2

    art_dir = args.artifacts or (os.path.dirname(args.record) or ".")
    print("verifying %s" % args.record)
    print("against artifacts in %s" % art_dir)

    try:
        rec = load_json(args.record)
    except (OSError, ValueError) as exc:
        print("FATAL: cannot read %s (%s)" % (args.record, exc))
        return 1

    if not check_record_shape(rec, args.record):
        print("")
        print("PROVENANCE RECORD REJECTED - %d problem(s):" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1

    assert isinstance(rec, dict)
    check_artifacts(rec, art_dir)
    check_revision(rec, args.pin)
    check_anchor(rec, args.lock)

    print("")
    if problems:
        print("PROVENANCE RECORD REJECTED - %d problem(s):" % len(problems))
        for p in problems:
            print("  - %s" % p)
        print("")
        print("This record does not describe the artifacts on disk. Do not cite it as")
        print("M2 X2 evidence: re-pull, or re-run the build.")
        return 1

    print("X2 PROVENANCE VERIFIED - %d artifact(s) match the record." % len(rec["artifacts"]))
    print("Commit it as docs/evidence/M2/x2-artifact-provenance.json.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
