#!/usr/bin/env python3
"""Offline unit tests for the X1 lock generator, ``tools/manifest/resolve-manifest-lock.py``.

WHY THIS EXISTS
    The resolver *produces* the M2 X1 provenance anchor, and nothing tested it.
    ``tools/manifest/test-verify-lock.py`` pins the *verifier's* exit-code contract,
    but the generator's own behaviour was unpinned: its ref classification, its
    ``ls-remote`` retry policy, its ``<include>``/``<remove-project>`` handling, and
    the determinism of the XML it emits. A regression in any of those is silent
    until CI re-derives the lock - or until an operator re-cuts it and quietly
    changes what gets built.

    Everything here is offline and deterministic: the network is replaced by a
    stub, so "that ref does not exist" and "the remote is flaky" are produced on
    demand instead of waited for. No ``repo``, no network, no QEMU, no Windows.

    It NEVER calls ``main()``. ``main()`` writes ``arcadia-x86.pinned.xml`` and
    ``lock-coverage.json`` over the committed lock, so the tools are exercised at
    function granularity instead, and ``run-offline-checks.sh`` additionally
    verifies the committed lock's hash is unchanged across the whole run.

Usage::  python tools/checks/test-manifest-resolver.py     # exits 0 on success
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RESOLVER = os.path.join(REPO, "tools", "manifest", "resolve-manifest-lock.py")

SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print("  [PASS] %s" % name)
    else:
        FAILED.append(name)
        print("  [FAIL] %s%s" % (name, ("  <- " + detail) if detail else ""))


def load_resolver():
    # Loading the resolver through importlib must not leave a __pycache__ behind:
    # this suite is supposed to be read-only.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        "resolve_manifest_lock_under_test", RESOLVER
    )
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise RuntimeError("could not load %s" % RESOLVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------- stubbing --
class _Proc:
    """Stand-in for subprocess.CompletedProcess (only what ls_remote reads)."""

    def __init__(self, returncode: int, stdout: str) -> None:
        self.returncode = returncode
        self.stdout = stdout


class _Clock:
    """Records backoff sleeps instead of performing them, so testing the retry
    policy costs no wall clock."""

    def __init__(self) -> None:
        self.slept: list[float] = []

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)


def install_stub(
    module,
    *,
    resolved_ref: str | None = None,
    sha: str = SHA_A,
    transient_failures: int = 0,
    exit_code: int = 0,
):
    """Replace the resolver's network + clock with stubs for one call.

    Mimics ``git ls-remote <url> <ref>``: the first ``transient_failures`` calls
    raise ``TimeoutExpired`` (a flaky remote); each later call returns ``exit_code``
    with a resolvable line for ``resolved_ref`` when it matches, and with empty
    output otherwise - i.e. "that ref does not exist", which is the permanent case.

    Returns ``(calls, clock)``, where ``calls`` is the ref column of every probe in
    order. The module globals are replaced rather than the real ``subprocess``
    module's attributes, so nothing leaks out of this test.
    """
    calls: list[str] = []
    clock = _Clock()

    def run(cmd, **kwargs):
        calls.append(cmd[3])
        if len(calls) <= transient_failures:
            raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout", 1))
        ref = cmd[3]
        if exit_code != 0:
            return _Proc(exit_code, "")
        if resolved_ref is not None and ref == resolved_ref:
            return _Proc(0, "%s\t%s\n" % (sha, ref))
        return _Proc(0, "")

    module.subprocess = types.SimpleNamespace(
        run=run, TimeoutExpired=subprocess.TimeoutExpired
    )
    module.time = types.SimpleNamespace(sleep=clock.sleep)
    return calls, clock


# ------------------------------------------------------------------------ cases --
def test_classify() -> None:
    print("== revision classification ==")
    m = load_resolver()
    for value, want in [
        (SHA_A, "sha"),
        ("refs/tags/android-12.1.0_r22", "tag"),
        ("refs/heads/arcadia-x86", "branch"),
        ("arcadia-next", "branch"),
        ("main", "branch"),
        (None, "none"),
        ("", "none"),
    ]:
        got = m.classify(value)
        check("classify(%r) -> %s" % (value, want), got == want, "got %r" % got)
    # A near-miss must NOT be mistaken for an immutable revision, or the lock
    # would claim reproducibility it does not have.
    check("a 39-char revision is not a sha", m.classify("a" * 39) == "branch")
    check("non-hex 40 chars is not a sha", m.classify("z" * 40) == "branch")
    check("uppercase hex is not a sha", m.classify("A" * 40) == "branch")


def test_pick_ref_line() -> None:
    print("== ls-remote line selection ==")
    m = load_resolver()
    out = "%s\trefs/heads/main\n%s\trefs/tags/v1\n%s\trefs/tags/v1^{}\n" % (
        SHA_A,
        SHA_B,
        SHA_C,
    )
    check(
        "an exact ref-column match wins over the first line",
        m._pick_ref_line(out, "refs/tags/v1") == (SHA_B, "refs/tags/v1"),
    )
    check(
        "with no exact match the first non-peeled line is used",
        m._pick_ref_line(out, "nope") == (SHA_A, "refs/heads/main"),
    )
    # If the ONLY line is the peeled tag object, there is no commit to return --
    # silently using it would lock the tag object instead of the commit.
    check(
        "a peeled ^{} line is never returned",
        m._pick_ref_line("%s\trefs/tags/v1^{}\n" % SHA_C, "refs/tags/v1") == (None, None),
    )
    check(
        "malformed lines are skipped",
        m._pick_ref_line("garbage\n%s\ta\n" % SHA_A, "a") == (SHA_A, "a"),
    )
    check("empty output yields nothing", m._pick_ref_line("", "x") == (None, None))


def test_ls_remote_policy() -> None:
    print("== ls-remote retry policy ==")

    # (1) A ref that simply does not exist is a PERMANENT answer: one probe per
    #     candidate and no retry. Retrying it only repeats a network round trip,
    #     and on a broadly-failing run it holds a pool worker in backoff.
    m = load_resolver()
    calls, clock = install_stub(m)
    got = m.ls_remote("https://example.invalid/x", "nope", 5, 3)
    check(
        "a permanent no-match is not retried",
        got == (None, None, "no matching ref") and len(calls) == 3,
        "got %r after %d probe(s)" % (got, len(calls)),
    )
    check("...and performs no backoff sleep", clock.slept == [], "slept %r" % clock.slept)

    # (2) An explicit refs/ revision is ONE candidate, not heads+tags+bare.
    m = load_resolver()
    calls, _ = install_stub(m)
    m.ls_remote("u", "refs/heads/nope", 5, 3)
    check(
        "an explicit refs/ revision probes one candidate only",
        len(calls) == 1,
        "probed %r" % calls,
    )

    # (3) The ordering contract: a bare branch name prefers refs/heads/.
    m = load_resolver()
    calls, _ = install_stub(m, resolved_ref="refs/heads/main")
    got = m.ls_remote("u", "main", 5, 3)
    check(
        "a direct hit resolves on the first probe",
        got == (SHA_A, "refs/heads/main", "") and len(calls) == 1,
        "got %r after %d probe(s)" % (got, len(calls)),
    )
    check("...and refs/heads/ is tried first", calls == ["refs/heads/main"], "probed %r" % calls)

    # (4) Transient failure, then success: retried, with the documented backoff.
    m = load_resolver()
    calls, clock = install_stub(m, resolved_ref="refs/heads/main", transient_failures=3)
    got = m.ls_remote("u", "main", 5, 3)
    check("a transient failure is retried and then resolves", got[0] == SHA_A, "got %r" % (got,))
    check(
        "the retry backoff is linear and capped",
        clock.slept == [2.0],
        "slept %r (expected [2.0])" % clock.slept,
    )

    # (5) Every attempt transient: the run ends unresolved and says why.
    m = load_resolver()
    calls, clock = install_stub(m, transient_failures=99)
    got = m.ls_remote("u", "main", 5, 2)
    check(
        "exhausted retries report the last diagnostic",
        got == (None, None, "timeout after 5s"),
        "got %r" % (got,),
    )
    check(
        "...having retried each transient candidate once",
        len(calls) == 6,
        "probed %d time(s)" % len(calls),
    )
    check("...stopping before the cap is exceeded", clock.slept == [2.0], "slept %r" % clock.slept)

    # (6) A non-zero git exit is transient (retryable), NOT a permanent no-match --
    #     a rate-limited or temporarily unreachable remote must not be locked in.
    m = load_resolver()
    calls, _ = install_stub(m, exit_code=128)
    got = m.ls_remote("u", "main", 5, 2)
    check(
        "a non-zero git exit is retried",
        got == (None, None, "git ls-remote exit 128") and len(calls) == 6,
        "got %r after %d probe(s)" % (got, len(calls)),
    )


def test_manifest_load_and_effective(tmp: str) -> None:
    print("== manifest include / remove handling ==")
    m = load_resolver()

    inc = os.path.join(tmp, "child.xml")
    with open(inc, "w", encoding="utf-8") as fh:
        fh.write(
            "<manifest>\n"
            '  <project name="child" path="c/1" revision="refs/heads/child" />\n'
            '  <remove-project name="parent" />\n'
            "</manifest>\n"
        )
    root = os.path.join(tmp, "default.xml")
    with open(root, "w", encoding="utf-8") as fh:
        fh.write(
            "<manifest>\n"
            '  <remote name="aosp" fetch="https://example.invalid/aosp" />\n'
            '  <default remote="aosp" revision="refs/heads/main" />\n'
            '  <project name="parent" path="p/1" />\n'
            '  <project name="inherit" path="i/1" />\n'
            '  <include name="child.xml" />\n'
            "</manifest>\n"
        )
    man = m.Manifest()
    man.load(root)
    paths = sorted(p.get("path") for p in man.projects)
    check("an <include> is parsed", "c/1" in paths, "paths %r" % paths)
    check(
        "a <remove-project> drops the project it names",
        "p/1" not in paths,
        "paths %r" % paths,
    )
    check("both manifests are recorded", len(man.files) == 2, "files %r" % man.files)

    child = next(p for p in man.projects if p["name"] == "child")
    remote_name, url, revision = man.effective(child)
    check("remote falls back to <default>", remote_name == "aosp", "got %r" % remote_name)
    check(
        "url is the remote fetch joined to the project name",
        url == "https://example.invalid/aosp/child",
        "got %r" % url,
    )
    check(
        "an explicit revision wins over <default>",
        revision == "refs/heads/child",
        "got %r" % revision,
    )

    # ...while a project that declares neither inherits both.
    kin = next(p for p in man.projects if p["name"] == "inherit")
    k_remote, k_url, k_rev = man.effective(kin)
    check("an omitted revision inherits <default>", k_rev == "refs/heads/main", "got %r" % k_rev)
    check(
        "an omitted remote inherits <default>",
        k_remote == "aosp" and k_url == "https://example.invalid/aosp/inherit",
        "got %r %r" % (k_remote, k_url),
    )

    # Document order is load-bearing: a <remove-project> only drops projects
    # declared BEFORE it, and a later project with the same name survives. This is
    # pinned because it is precisely why the O(n*m) removal loop in Manifest.load
    # was deliberately NOT "optimised" - doing so would change the emitted lock.
    order = os.path.join(tmp, "order.xml")
    with open(order, "w", encoding="utf-8") as fh:
        fh.write(
            "<manifest>\n"
            '  <project name="early" path="e/1" />\n'
            '  <remove-project name="early" />\n'
            '  <project name="early" path="e/2" />\n'
            "</manifest>\n"
        )
    man2 = m.Manifest()
    man2.load(order)
    check(
        "document order is preserved: a re-added project survives the removal",
        [p["path"] for p in man2.projects] == ["e/2"],
        "paths %r" % [p["path"] for p in man2.projects],
    )


def test_build_records() -> None:
    print("== record classification ==")
    m = load_resolver()
    man = m.Manifest()
    man.remotes = {"aosp": {"name": "aosp", "fetch": "https://example.invalid/aosp"}}
    man.default = {"remote": "aosp", "revision": "refs/heads/main"}
    man.projects = [
        {"name": "tagged", "path": "t", "revision": "refs/tags/v1"},
        {"name": "sha", "path": "s", "revision": SHA_A},
        {"name": "moving", "path": "m"},
    ]
    recs = {r["path"]: r for r in m.build_records(man)}
    check(
        "an immutable tag is pre-locked",
        recs["t"]["status"] == "already-locked"
        and recs["t"]["locked_revision"] == "refs/tags/v1",
    )
    check(
        "an immutable sha is pre-locked",
        recs["s"]["status"] == "already-locked"
        and recs["s"]["locked_revision"] == SHA_A,
    )
    check(
        "a moving ref is left pending for the network",
        recs["m"]["status"] == "pending" and recs["m"]["kind"] == "branch",
        "got %r" % recs["m"],
    )
    check(
        "records are ordered by path (byte-stable output depends on it)",
        [r["path"] for r in m.build_records(man)] == ["m", "s", "t"],
        "got %r" % [r["path"] for r in m.build_records(man)],
    )

    # No revision anywhere: the gap must be EXPLICIT, with a reason.
    bare = m.Manifest()
    bare.projects = [{"name": "n", "path": "n", "revision": ""}]
    rec = m.build_records(bare)[0]
    check(
        "an undefined revision is unresolved, with a reason",
        rec["status"] == "unresolved" and rec["error"] == "no revision",
        "got %r" % rec,
    )


def test_emit_xml(tmp: str) -> None:
    print("== emitted lock: determinism and escaping ==")
    m = load_resolver()
    man = m.Manifest()
    man.remotes = {"aosp": {"name": "aosp", "fetch": "https://example.invalid/aosp"}}
    man.default = {"remote": "aosp", "revision": "refs/heads/main"}
    man.projects = [
        {"name": "b&b", "path": "z/2"},
        {"name": "a<b", "path": "a/1"},
    ]
    recs = m.build_records(man)
    recs[0]["status"] = "unresolved"  # force the explicit-gap marker

    one = os.path.join(tmp, "one.xml")
    two = os.path.join(tmp, "two.xml")
    m.emit_xml(man, recs, m.PIN, one)
    m.emit_xml(man, recs, m.PIN, two)
    with open(one, "rb") as fh:
        a = fh.read()
    with open(two, "rb") as fh:
        b = fh.read()
    text = a.decode("utf-8")

    check("emit_xml is byte-deterministic", a == b, "two runs differ")
    check(
        "output uses CRLF line endings throughout",
        a.count(b"\r\n") == a.count(b"\n") and a.count(b"\r\n") > 0,
        "%d CRLF vs %d LF" % (a.count(b"\r\n"), a.count(b"\n")),
    )
    check(
        "XML metacharacters are escaped in attributes",
        "&amp;" in text and "&lt;" in text,
        "no escaping found",
    )
    check(
        "an unresolved project is flagged emberbird-unresolved",
        'emberbird-unresolved="true"' in text,
    )
    check(
        "projects are emitted in path order",
        text.index("a/1") < text.index("z/2"),
    )
    check("the pin revision is named in the header", m.PIN in text)
    check(
        "the emitted manifest declares the remote and the default",
        '<remote name="aosp"' in text and "<default" in text,
    )


def main() -> int:
    print("EmberbirdOS - resolve-manifest-lock.py unit tests")
    print()
    with tempfile.TemporaryDirectory(prefix="emberbird-resolver-test-") as tmp:
        test_classify()
        test_pick_ref_line()
        test_ls_remote_policy()
        test_manifest_load_and_effective(tmp)
        test_build_records()
        test_emit_xml(tmp)

    # Exercising the module must never have written the lock it generates.
    check(
        "the tools wrote no lock artifacts into the repository",
        not os.path.exists(os.path.join(REPO, "arcadia-x86.pinned.xml")),
        "arcadia-x86.pinned.xml appeared at the repo root",
    )

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
