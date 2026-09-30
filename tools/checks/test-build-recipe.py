#!/usr/bin/env python3
"""Offline tests for the guest-build recipe, ``tools/guest-build/build-from-manifest.sh``.

WHY THIS EXISTS
    ``build-from-manifest.sh`` is the one build recipe, executed remotely by Crave
    and by ``guest-build.yml``, and it is the only thing that produces the X2 guest
    artifact. Its expensive half - ``repo sync`` on a pre-seeded tree plus a
    multi-hundred-GB AOSP build - cannot run here. So the parts that CAN be proven
    offline were proven by nothing at all:

      * the two embedded Python heredocs had no test, and a syntax error in either
        was first discovered after a multi-hour sync on a remote node had already
        been paid for;
      * the recipe hardcodes ``EXPECTED = 1175`` and ``die``s mid-build if the lock
        stops agreeing with it, while ``verify-lock.py`` independently hardcodes
        ``EXPECTED_ACTIVE_PROJECTS = 1175``. Two constants that must move together,
        kept in step only by a comment asking a human to remember.

    This suite pins both, plus the behaviour of the two heredocs, with no network,
    no ``repo``, no AOSP tree and no QEMU: the "workspace" is a fake tree in a temp
    dir. It never invokes the recipe as a whole (that would sync the world).

Usage::  python tools/checks/test-build-recipe.py     # exits 0 on success
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RECIPE = os.path.join(REPO, "tools", "guest-build", "build-from-manifest.sh")
VERIFIER = os.path.join(REPO, "tools", "manifest", "verify-lock.py")
LOCK_XML = os.path.join(REPO, "image", "manifest", "arcadia-x86.pinned.xml")

#: The two heredocs are passed to `python3 - <args>` / `python3 -` with a single
#: `PY` terminator, so they can be lifted out of the shell text exactly as written.
HEREDOC_RE = re.compile(r"<<'PY'\n(.*?)\nPY\n", re.S)

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print("  [PASS] %s" % name)
    else:
        FAILED.append(name)
        print("  [FAIL] %s%s" % (name, ("  <- " + detail) if detail else ""))


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def extract_heredocs() -> list[str]:
    return HEREDOC_RE.findall(read(RECIPE))


def run_heredoc(body: str, argv: list[str], env_extra: dict[str, str] | None = None):
    """Run one embedded heredoc the way the recipe does, and capture the result."""
    env = dict(os.environ)
    env.pop("LOCK_XML", None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, "-c", body] + argv,
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )


def active_project_count() -> int:
    """The number of projects a default (Linux) sync materializes: the lock minus
    the `notdefault` group, which is repo's own default-linux exclusion."""
    root = ET.parse(LOCK_XML).getroot()
    total = active = 0
    for proj in root.findall("project"):
        total += 1
        groups = {g.strip() for g in (proj.get("groups") or "").split(",") if g.strip()}
        if "notdefault" not in groups:
            active += 1
    return active


def write_lock_fixture(path: str, active: int, notdefault: int = 8, duplicate: bool = False) -> None:
    paths = ["a/%d" % i for i in range(active)]
    if duplicate and paths:
        paths[-1] = paths[0]  # keeps the COUNT right so the dup check is reached
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<manifest>"]
    for p in paths:
        lines.append('  <project name="%s" path="%s" revision="%s" />' % (p.replace("/", "_"), p, "a" * 40))
    for i in range(notdefault):
        lines.append(
            '  <project name="nd%d" path="nd/%d" groups="notdefault" revision="%s" />'
            % (i, i, "a" * 40)
        )
    lines.append("</manifest>")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def fake_workspace(root: str, name: str, *, with_product: bool, deep_img: bool = True) -> str:
    """A throwaway stand-in for the synced AOSP tree. Each case gets its own
    ``name`` so one case's layout cannot leak into the next."""
    ws = os.path.join(root, name)
    if with_product:
        d = os.path.join(ws, "out", "target", "product", "bliss")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "bliss.iso"), "wb") as fh:
            fh.write(b"ISO!" * 500)
    if deep_img:
        d = os.path.join(ws, "out", "deep", "a", "b")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "system.img"), "wb") as fh:
            fh.write(b"IMG" * 300)
    return ws


# ------------------------------------------------------------------------ cases --
def test_heredocs_compile(bodies: list[str]) -> None:
    print("== embedded python heredocs ==")
    check(
        "the recipe still holds exactly two python heredocs",
        len(bodies) == 2,
        "found %d - the extraction pattern (or the recipe) changed" % len(bodies),
    )
    for i, body in enumerate(bodies):
        try:
            compile(body, "<heredoc %d>" % i, "exec")
            ok, detail = True, ""
        except SyntaxError as exc:
            ok, detail = False, "%s: %s" % (type(exc).__name__, exc)
        check("heredoc %d compiles" % i, ok, detail)


def test_evidence_heredoc(body: str, root: str) -> None:
    print("== X2 evidence heredoc: artifact discovery ==")

    # (1) The product dir is where iso_img writes, so it is the fast path: a single
    #     walk over it must find the ISO and must NOT reach into the rest of out/.
    ws = fake_workspace(root, "ws-fast", with_product=True)
    out = os.path.join(root, "out-fast")
    os.makedirs(out, exist_ok=True)
    proc = run_heredoc(body, [ws, out])
    rec_path = os.path.join(out, "x2-provenance.json")
    ok = proc.returncode == 0 and os.path.exists(rec_path)
    check("the evidence heredoc runs and writes x2-provenance.json", ok, proc.stderr[-300:])
    if ok:
        rec = json.loads(read(rec_path))
        artifacts = [a["artifact"] for a in rec["artifacts"]]
        check(
            "the product dir is used as the fast path (it is not scanned for the deep .img)",
            artifacts == ["bliss.iso"],
            "artifacts %r" % artifacts,
        )
        check(
            "the record names the provenance anchor and how the lock was confirmed",
            rec.get("provenance_anchor", "").startswith("image/manifest/arcadia-x86.pinned.xml")
            and "repo manifest -r" in rec.get("lock_confirmed_by", ""),
            "anchor=%r confirmed=%r"
            % (rec.get("provenance_anchor"), rec.get("lock_confirmed_by")),
        )
        iso = os.path.join(out, "bliss.iso")
        check("the artifact is copied next to the record", os.path.exists(iso))
        if os.path.exists(iso):
            with open(iso, "rb") as fh:
                want = hashlib.sha256(fh.read()).hexdigest()
            check(
                "the recorded sha256 matches the file",
                rec["artifacts"][0]["sha256"] == want,
                "recorded %s vs %s" % (rec["artifacts"][0]["sha256"], want),
            )
            check(
                "the recorded size matches the file",
                rec["artifacts"][0]["bytes"] == os.path.getsize(iso),
            )
        with open(os.path.join(out, "artifacts.txt"), encoding="utf-8") as fh:
            check("artifacts.txt lists the artifact", fh.read().strip() == "bliss.iso")

    # (2) With no product dir the full out/ scan must still find the artifact --
    #     the fast path is an optimisation, never a behaviour change.
    ws2 = fake_workspace(root, "ws-fallback", with_product=False)
    out2 = os.path.join(root, "out-fallback")
    os.makedirs(out2, exist_ok=True)
    proc2 = run_heredoc(body, [ws2, out2])
    rec2_path = os.path.join(out2, "x2-provenance.json")
    got = []
    if proc2.returncode == 0 and os.path.exists(rec2_path):
        got = [a["artifact"] for a in json.loads(read(rec2_path))["artifacts"]]
    check(
        "with no product dir the full out/ scan still finds the artifact",
        got == ["system.img"],
        "artifacts %r (rc=%d)" % (got, proc2.returncode),
    )

    # (3) Nothing built: an empty record plus the note, not a crash.
    ws3 = fake_workspace(root, "ws-empty", with_product=False, deep_img=False)
    out3 = os.path.join(root, "out-empty")
    os.makedirs(out3, exist_ok=True)
    proc3 = run_heredoc(body, [ws3, out3])
    rec3_path = os.path.join(out3, "x2-provenance.json")
    empty = True
    if proc3.returncode == 0 and os.path.exists(rec3_path):
        empty = json.loads(read(rec3_path))["artifacts"] == []
    check(
        "no artifacts records an empty list instead of failing",
        empty and "no .iso/.img found" in proc3.stdout,
        "rc=%d artifacts-empty=%s" % (proc3.returncode, empty),
    )


def test_lock_heredoc(body: str, root: str, active: int) -> None:
    print("== lock-extraction heredoc: the authoritative project set ==")

    # (1) The happy path: exactly the active set, `notdefault` dropped, LF only.
    good = os.path.join(root, "good.xml")
    write_lock_fixture(good, active)
    proc = run_heredoc(body, [], {"LOCK_XML": good})
    lines = proc.stdout.splitlines()
    check("a correct lock yields exactly the active project count", proc.returncode == 0, proc.stderr[-300:])
    check("...and prints one path per active project", len(lines) == active, "%d lines" % len(lines))
    check("...excluding the notdefault group", not any(p.startswith("nd/") for p in lines))
    check("...with no CR anywhere in the output", "\r" not in proc.stdout)

    # (2) A project with neither path nor name is a hard error, not a silent skip.
    broken = os.path.join(root, "broken.xml")
    with open(broken, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(
            '<manifest>\n  <project name="" path="" revision="%s" />\n</manifest>\n' % ("a" * 40)
        )
    proc2 = run_heredoc(body, [], {"LOCK_XML": broken})
    check(
        "a project without path/name exits 2",
        proc2.returncode == 2 and "without path/name" in proc2.stderr,
        "rc=%d stderr=%r" % (proc2.returncode, proc2.stderr[-160:]),
    )

    # (3) The completeness gate: a lock that no longer yields 1175 active projects
    #     must stop the build BEFORE the sync, not halfway through it.
    short = os.path.join(root, "short.xml")
    write_lock_fixture(short, active - 1)
    proc3 = run_heredoc(body, [], {"LOCK_XML": short})
    check(
        "a lock with the wrong active count exits 3",
        proc3.returncode == 3 and "expected" in proc3.stderr,
        "rc=%d stderr=%r" % (proc3.returncode, proc3.stderr[-160:]),
    )

    # (4) Duplicate paths would silently collapse two checkouts into one.
    dup = os.path.join(root, "dup.xml")
    write_lock_fixture(dup, active, duplicate=True)
    proc4 = run_heredoc(body, [], {"LOCK_XML": dup})
    check(
        "duplicate project paths exit 4",
        proc4.returncode == 4 and "duplicate" in proc4.stderr,
        "rc=%d stderr=%r" % (proc4.returncode, proc4.stderr[-160:]),
    )


def test_expected_count_agrees(root: str, active: int) -> None:
    print("== the two hardcoded completeness constants agree ==")
    recipe = read(RECIPE)
    verifier = read(VERIFIER)
    m_shell = re.search(r"EXPECTED = (\d+)", recipe)
    m_py = re.search(r"EXPECTED_ACTIVE_PROJECTS = (\d+)", verifier)
    check("the recipe declares EXPECTED", m_shell is not None, "no `EXPECTED = <n>` in the recipe")
    check(
        "verify-lock.py declares EXPECTED_ACTIVE_PROJECTS",
        m_py is not None,
        "no `EXPECTED_ACTIVE_PROJECTS = <n>` in verify-lock.py",
    )
    if m_shell and m_py:
        shell_n, py_n = int(m_shell.group(1)), int(m_py.group(1))
        check(
            "the recipe and verify-lock.py assert the same count",
            shell_n == py_n,
            "recipe=%d verifier=%d - re-cutting the lock must move BOTH" % (shell_n, py_n),
        )
        check(
            "that count matches the committed lock",
            shell_n == active,
            "constants say %d but the lock yields %d active projects" % (shell_n, active),
        )


def test_envsetup_path() -> None:
    """The recipe must not hardcode `source build/envsetup.sh`.

    Crave job 302572 queued for 23 hours, synced all 1175 projects, passed the X1
    lock check, and then died on `build/envsetup.sh: No such file or directory`.
    This lock is an Android-12-era Bliss x86 tree in which build/ already holds
    soong, blueprint, bazel and pesto as siblings, so platform_build is pinned at
    build/make and envsetup.sh is build/make/envsetup.sh. That is exactly the class
    of bug this suite exists to catch: the expensive half cannot run here, so the
    cheap source-level invariants have to.
    """
    print("== build: envsetup path is resolved, not hardcoded ==")
    text = read(RECIPE)

    hardcoded = re.findall(r"^\s*(?:source|\.)\s+build/envsetup\.sh", text, re.M)
    check(
        "the recipe never sources a literal build/envsetup.sh",
        not hardcoded,
        "found %d hardcoded source build/envsetup.sh line(s)" % len(hardcoded),
    )
    check(
        "the recipe resolves the platform_build path out of the committed lock",
        "platform_build" in text and "envsetup.sh" in text,
        "expected a lookup of platform_build's path plus a probe for envsetup.sh",
    )
    check(
        "both known AOSP layouts are probed",
        '"$lock_build_path" build build/make' in text,
        "expected the candidate list to offer the lock path, build/ and build/make/",
    )
    check(
        "a tree with no envsetup.sh dies with an explicit message",
        re.search(r"no envsetup\.sh in the synced tree", text) is not None,
        "expected the resolver to die rather than source a missing file",
    )

    # The resolver must pick the layout the committed lock actually describes, and
    # the lock really does describe build/make - so this is a live assertion about
    # the tree we are about to build, not just about the text of the recipe.
    root = ET.parse(LOCK_XML).getroot()
    build_paths = [
        (proj.get("path") or proj.get("name"))
        for proj in root.findall("project")
        if (proj.get("name") or "").replace("/", "_") == "platform_build"
    ]
    check(
        "the lock pins platform_build somewhere the resolver looks",
        len(build_paths) == 1 and build_paths[0] in ("build", "build/make"),
        "lock says platform_build -> %r" % (build_paths,),
    )


def test_lunch_target_is_manifest_backed() -> None:
    """The lunch target and the device tree that provides it must agree.

    `device/generic/x86_64` exists in AOSP *and* in BlissRoms-x86, and only the
    BlissRoms-x86 one declares bliss_x86_64 (AOSP's declares aosp_x86_64). So a lock
    that resolved that path to the wrong remote produces a tree where `lunch
    bliss_x86_64-userdebug` cannot possibly resolve - which is precisely the kind of
    mismatch that should be caught here rather than after a 23h queue and a sync.
    """
    print("== lunch target is provided by the manifest-backed tree ==")
    text = read(RECIPE)

    check(
        "the recipe reads the device/ trees out of the lock",
        'path="\\(device' in text and "lock_device_paths" in text,
        "expected the candidate device trees to come from the lock, not a literal list",
    )
    check(
        "the recipe derives the product name from LUNCH_TARGET",
        'PRODUCT="${LUNCH_TARGET%%-*}"' in text,
        "expected the product to be split off the <product>-<variant> lunch target",
    )
    check(
        "the recipe dies when the tree offers no such product",
        re.search(r"offers no product", text) is not None,
        "expected a hard failure before the build, not a fallback",
    )
    check(
        "the recipe checks the full lunch combo, not just the product",
        'grep -qE "^[[:space:]]*$LUNCH_TARGET[[:space:]]*$"' in text,
        "expected COMMON_LUNCH_CHOICES to be consulted for the exact combo",
    )

    root = ET.parse(LOCK_XML).getroot()
    x86_64 = [
        proj
        for proj in root.findall("project")
        if (proj.get("path") or "") == "device/generic/x86_64"
    ]
    check(
        "the lock pins device/generic/x86_64 exactly once",
        len(x86_64) == 1,
        "found %d entries" % len(x86_64),
    )
    if x86_64:
        remote = x86_64[0].get("remote")
        remotes = {r.get("name"): (r.get("fetch") or "") for r in root.findall("remote")}
        fetch = remotes.get(remote, "")
        check(
            "that device tree comes from BlissRoms-x86, not AOSP",
            "BlissRoms-x86" in fetch,
            "remote=%r fetch=%r - AOSP's tree has no bliss_x86_64 lunch combo" % (remote, fetch),
        )
        check(
            "the pinned device tree is an immutable revision",
            re.fullmatch(r"[0-9a-f]{40}", x86_64[0].get("revision") or "") is not None,
            "revision=%r" % (x86_64[0].get("revision"),),
        )


def main() -> int:
    print("EmberbirdOS - build-from-manifest.sh offline tests")
    print()
    bodies = extract_heredocs()
    check(
        "the recipe exists and is non-empty",
        bool(read(RECIPE).strip()),
        "could not read %s" % RECIPE,
    )
    active = active_project_count()
    print("  [info] committed lock active projects: %d" % active)
    print()

    with tempfile.TemporaryDirectory(prefix="emberbird-recipe-test-") as tmp:
        test_heredocs_compile(bodies)
        if len(bodies) == 2:
            # heredoc 0 extracts the authoritative project set; heredoc 1 emits the
            # X2 provenance record. Assert the ORDER rather than trusting the index,
            # so a future reordering does not silently test the wrong script.
            if "required" in bodies[0] and "artifacts" in bodies[1]:
                lock_body, evidence_body = bodies
            elif "artifacts" in bodies[0] and "required" in bodies[1]:
                evidence_body, lock_body = bodies
            else:
                raise SystemExit(
                    "FATAL: could not tell which heredoc is which; "
                    "the recipe's heredocs were renamed or replaced"
                )
            test_lock_heredoc(lock_body, tmp, active)
            test_evidence_heredoc(evidence_body, tmp)
        test_expected_count_agrees(tmp, active)

    test_envsetup_path()
    test_lunch_target_is_manifest_backed()

    print()
    print("== summary ==")
    print("  %d passed, %d failed" % (len(PASSED), len(FAILED)))
    if FAILED:
        for name in FAILED:
            print("  [FAIL] %s" % name, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
