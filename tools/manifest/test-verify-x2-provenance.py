#!/usr/bin/env python3
"""Regression tests for verify-x2-provenance.py -- the post-pull X2 evidence check.

WHY THIS EXISTS
    ``x2-provenance.json`` is the M2 X2 record. It is written on a Crave node that
    is gone by the time anyone reads it, and the only thing standing between "a job
    printed a sha256" and "we shipped a verified image" is that somebody re-hashes
    the pulled artifact and compares. That comparison was manual, so it was the one
    step in the X2 chain nobody could prove had happened.

    The failure this test exists to prevent is not a crash -- it is a verifier that
    passes a record it should reject. Three shapes of that are pinned here:

    * an **empty** artifacts list passing vacuously (a build that compiled nothing
      would satisfy a checker that never looks);
    * a **stale** record passing against artifacts it never described (an unrecorded
      ``.img`` sitting next to a valid-looking record);
    * a **wrong build** passing because nobody compared ``manifest_revision``
      against the committed pin.

    All fixtures are built in temp directories; nothing here touches the repo, the
    real lock, or a real image.

Usage::  python3 tools/manifest/test-verify-x2-provenance.py   # exits 0 on success
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFY = os.path.join(HERE, "verify-x2-provenance.py")

# The real committed pin's revision, so the "matches" case is the real value
# rather than a placeholder that could drift away from it unnoticed.
PINNED_REVISION = "98a0a79cfffbb2cb9eb43dbaf5575a0195162bcf"

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print("  [PASS] %s" % name)
    else:
        FAILED.append(name)
        print("  [FAIL] %s%s" % (name, ("  <- " + detail) if detail else ""))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_fixture(
    tmp: str,
    *,
    record=None,
    artifacts: dict[str, bytes] | None = None,
    pin_revision: str = PINNED_REVISION,
    write_record: bool = True,
) -> dict:
    """Materialize a record + artifacts + pin in a temp dir; return the argv parts."""
    art_dir = os.path.join(tmp, "out")
    pin_dir = os.path.join(tmp, "manifest")
    os.makedirs(art_dir, exist_ok=True)
    os.makedirs(pin_dir, exist_ok=True)

    if artifacts:
        for name, data in artifacts.items():
            with open(os.path.join(art_dir, name), "wb") as fh:
                fh.write(data)

    pin_path = os.path.join(pin_dir, "arcadia-x86.pin.json")
    with open(pin_path, "w", encoding="utf-8") as fh:
        json.dump({"manifest": {"revision": pin_revision}}, fh)

    lock_path = os.path.join(tmp, "arcadia-x86.pinned.xml")
    with open(lock_path, "w", encoding="utf-8") as fh:
        fh.write("<manifest/>\n")

    record_path = os.path.join(art_dir, "x2-provenance.json")
    if record is not None and write_record:
        with open(record_path, "w", encoding="utf-8") as fh:
            json.dump(record, fh, indent=2)

    return {
        "record": record_path,
        "artifacts": art_dir,
        "pin": pin_path,
        "lock": lock_path,
    }


def good_record(
    payload: bytes,
    *,
    name: str = "guest-x86_64.iso",
    revision: str = PINNED_REVISION,
    anchor: str = "image/manifest/arcadia-x86.pinned.xml (X1 per-project lock)",
    confirmed: str = "repo manifest -r, checked with tools/manifest/verify-lock.py",
):
    """A record that describes `payload` sitting at `name`, entirely correctly."""
    return {
        "criterion": "M2 X2 - guest artifact provenance",
        "kind": "built-from-pinned-manifest",
        "manifest_revision": revision,
        "lunch": "bliss_x86_64-userdebug",
        "make_target": "iso_img",
        "build_utc": "2026-10-03T00:00:00Z",
        "provenance_anchor": anchor,
        "lock_confirmed_by": confirmed,
        "artifacts": [
            {"artifact": name, "sha256": sha256_bytes(payload), "bytes": len(payload)}
        ],
    }


def run(paths: dict, extra: list[str] | None = None):
    argv = [
        sys.executable,
        VERIFY,
        "--record", paths["record"],
        "--artifacts", paths["artifacts"],
        "--pin", paths["pin"],
        "--lock", paths["lock"],
    ]
    if extra:
        argv += extra
    proc = subprocess.run(argv, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def test_happy_path() -> None:
    print("== a correctly pulled record verifies ==")
    payload = b"aosp guest image bytes" * 64
    with tempfile.TemporaryDirectory(prefix="x2-happy-") as tmp:
        paths = build_fixture(tmp, record=good_record(payload),
                              artifacts={"guest-x86_64.iso": payload})
        rc, out = run(paths)
        check("a matching record exits 0", rc == 0, out[-300:])
        check("it says so", "X2 PROVENANCE VERIFIED" in out, out[-300:])
        check("it names the artifact", "guest-x86_64.iso" in out, out[-300:])

    # Two artifacts, because a multi-artifact record is the normal case and a
    # checker that only ever looks at artifacts[0] would pass a broken second one.
    a, b = b"first image", b"second image, a different length"
    with tempfile.TemporaryDirectory(prefix="x2-multi-") as tmp:
        rec = good_record(a)
        rec["artifacts"].append(
            {"artifact": "boot.img", "sha256": sha256_bytes(b), "bytes": len(b)}
        )
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": a, "boot.img": b})
        rc, out = run(paths)
        check("a two-artifact record verifies", rc == 0, out[-300:])


def test_missing_record_is_not_a_pass() -> None:
    print("== nothing pulled yet is exit 2, never 0 ==")
    with tempfile.TemporaryDirectory(prefix="x2-empty-") as tmp:
        paths = build_fixture(tmp, record=None, write_record=False)
        rc, out = run(paths)
        check("a missing record exits 2, not 0", rc == 2, "got %d" % rc)
        check("it says X2 is still open", "nothing has been pulled" in out, out[-300:])
        check("it does not claim verification", "VERIFIED" not in out, out[-300:])


def test_empty_artifact_list_fails() -> None:
    print("== a record with no artifacts fails (never vacuously passes) ==")
    with tempfile.TemporaryDirectory(prefix="x2-vacuous-") as tmp:
        rec = good_record(b"anything")
        rec["artifacts"] = []
        paths = build_fixture(tmp, record=rec, artifacts={})
        rc, out = run(paths)
        check("an empty artifacts list exits 1", rc == 1, "got %d" % rc)
        check("it names the cause", "lists no artifacts" in out, out[-300:])


def test_hash_and_size() -> None:
    print("== hash and size must both match the file ==")
    payload = b"guest image"
    with tempfile.TemporaryDirectory(prefix="x2-hash-") as tmp:
        paths = build_fixture(tmp, record=good_record(payload),
                              artifacts={"guest-x86_64.iso": payload})
        # Same length, different bytes: only the digest can catch this.
        corrupt = b"GUEST IMAGE"
        assert len(corrupt) == len(payload)
        with open(os.path.join(paths["artifacts"], "guest-x86_64.iso"), "wb") as fh:
            fh.write(corrupt)
        rc, out = run(paths)
        check("a same-length corrupt artifact exits 1", rc == 1, "got %d" % rc)
        check("it reports the digest disagreement", "hashes to" in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-size-") as tmp:
        rec = good_record(payload)
        truncated = payload[:-1]
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": truncated})
        rc, out = run(paths)
        check("a truncated artifact exits 1", rc == 1, "got %d" % rc)
        check("it reports the size disagreement", "bytes on disk but the record says" in out,
              out[-300:])
        check("it does not bother re-hashing a known-wrong size",
              "hashes to" not in out, out[-300:])


def test_missing_and_extra() -> None:
    print("== missing, unrecorded and traversing artifacts ==")
    payload = b"guest image"
    with tempfile.TemporaryDirectory(prefix="x2-missing-") as tmp:
        paths = build_fixture(tmp, record=good_record(payload), artifacts={})
        rc, out = run(paths)
        check("a recorded artifact that is absent exits 1", rc == 1, "got %d" % rc)
        check("it says the file is not there", "but not in" in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-extra-") as tmp:
        # The stale-record case: a valid record plus an image it never described.
        paths = build_fixture(
            tmp,
            record=good_record(payload),
            artifacts={"guest-x86_64.iso": payload, "stray.img": b"unrecorded"},
        )
        rc, out = run(paths)
        check("an unrecorded artifact exits 1", rc == 1, "got %d" % rc)
        check("it names the stray file", "stray.img" in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-trav-") as tmp:
        # A record is data, not a path to follow.
        rec = good_record(payload)
        rec["artifacts"][0]["artifact"] = "../pin.json"
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": payload})
        rc, out = run(paths)
        check("a traversing artifact name exits 1", rc == 1, "got %d" % rc)
        check("it refuses to follow it", "refusing to follow" in out, out[-300:])


def test_revision_and_anchor() -> None:
    print("== the record must be the build we intended ==")
    payload = b"guest image"
    with tempfile.TemporaryDirectory(prefix="x2-rev-") as tmp:
        rec = good_record(payload, revision="0" * 40)
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": payload})
        rc, out = run(paths)
        check("a manifest_revision off the pin exits 1", rc == 1, "got %d" % rc)
        check("it names the pinned revision", PINNED_REVISION[:12] in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-norev-") as tmp:
        rec = good_record(payload)
        rec["manifest_revision"] = ""
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": payload})
        rc, out = run(paths)
        check("a record with no manifest_revision exits 1", rc == 1, "got %d" % rc)

    with tempfile.TemporaryDirectory(prefix="x2-anchor-") as tmp:
        rec = good_record(payload)
        rec["provenance_anchor"] = "somewhere/else/lock.xml"
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": payload})
        rc, out = run(paths)
        check("an anchor off the committed lock exits 1", rc == 1, "got %d" % rc)
        check("it says which lock was required", "committed lock" in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-nolock-") as tmp:
        # Right file name, wrong place: the basename check passes, so this is
        # specifically the "the anchor does not resolve" branch.
        paths = build_fixture(
            tmp,
            record=good_record(
                payload, anchor="no/such/dir/arcadia-x86.pinned.xml (X1 per-project lock)"
            ),
            artifacts={"guest-x86_64.iso": payload},
        )
        rc, out = run(paths)
        check("an anchor that does not resolve exits 1", rc == 1, "got %d" % rc)
        check("it says the file is missing", "does not exist" in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-unconfirmed-") as tmp:
        # The provenance record's whole purpose is the claim; a record that quietly
        # dropped it must not pass just because the bytes happen to line up.
        paths = build_fixture(
            tmp,
            record=good_record(payload, confirmed="trusted, probably"),
            artifacts={"guest-x86_64.iso": payload},
        )
        rc, out = run(paths)
        check("a record not crediting verify-lock.py exits 1", rc == 1, "got %d" % rc)


def test_malformed() -> None:
    print("== malformed records fail loudly ==")
    with tempfile.TemporaryDirectory(prefix="x2-bad-") as tmp:
        paths = build_fixture(tmp, record=None, write_record=False)
        with open(paths["record"], "w", encoding="utf-8") as fh:
            fh.write("{ this is not json")
        rc, out = run(paths)
        check("unparseable JSON exits 1", rc == 1, "got %d" % rc)
        check("it does not crash with a traceback", "Traceback" not in out, out[-300:])

    with tempfile.TemporaryDirectory(prefix="x2-noart-") as tmp:
        rec = good_record(b"x")
        del rec["artifacts"]
        paths = build_fixture(tmp, record=rec, artifacts={})
        rc, out = run(paths)
        check("a record with no artifacts key exits 1", rc == 1, "got %d" % rc)

    with tempfile.TemporaryDirectory(prefix="x2-badsha-") as tmp:
        payload = b"guest image"
        rec = good_record(payload)
        rec["artifacts"][0]["sha256"] = "not-a-hash"
        paths = build_fixture(tmp, record=rec,
                              artifacts={"guest-x86_64.iso": payload})
        rc, out = run(paths)
        check("a non-hex recorded sha256 exits 1", rc == 1, "got %d" % rc)


def test_real_committed_pin_agrees() -> None:
    """The default paths must find the repo's real pin -- a checker pointed at
    fixtures that also works against the repository it ships with."""
    print("== the committed X1 pin is what the default revision check uses ==")
    pin = os.path.join(os.path.dirname(HERE), "..", "image", "manifest",
                       "arcadia-x86.pin.json")
    check("the committed pin exists", os.path.isfile(pin), pin)
    if not os.path.isfile(pin):
        return
    with open(pin, "r", encoding="utf-8") as fh:
        revision = json.load(fh).get("manifest", {}).get("revision", "")
    check("it pins a revision", bool(revision))
    check("this test's constant still matches it", revision == PINNED_REVISION,
          "pin says %r" % revision)


def main() -> int:
    for fn in (
        test_happy_path,
        test_missing_record_is_not_a_pass,
        test_empty_artifact_list_fails,
        test_hash_and_size,
        test_missing_and_extra,
        test_revision_and_anchor,
        test_malformed,
        test_real_committed_pin_agrees,
    ):
        fn()

    print("")
    print("== summary ==")
    print("  %d passed, %d failed" % (len(PASSED), len(FAILED)))
    if FAILED:
        for name in FAILED:
            print("  FAILED: %s" % name)
        return 1
    print("x2 provenance verifier tests: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
