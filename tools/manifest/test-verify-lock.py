#!/usr/bin/env python3
"""Regression tests for verify-lock.py's exit-code contract and the CI step that reads it.

WHY THIS EXISTS
    The advisory job in ``.github/workflows/verify-provenance.yml`` decides what to
    tell a human purely from verify-lock.py's exit code. That contract is invisible
    until it is wrong, and the failure mode is bad: a *failed* re-resolution used to
    be reported as "upstream moved, consider re-cutting the lock", which is a false
    statement written into a provenance record. Nobody reads a nightly run until it
    matters, so nothing else would have caught it.

    These tests are deterministic and need no network: the resolver is replaced with
    a stub, so "upstream drifted" and "upstream could not be reached" are produced on
    demand instead of waited for.

WHAT IS PINNED
    * exit 0 when the lock re-derives cleanly;
    * exit 1 for drift, and for a structurally invalid lock;
    * exit 2 when the re-resolution leaves refs unresolved -- INCLUDING when drift
      and unresolved happen together, because a run that could not finish must not
      be reported as a stale lock;
    * an unresolved ref is never counted as drift in the output;
    * the findings report is written, self-describing, and never silently truncated;
    * the ``--repo-manifest`` build-side witness is load-bearing: a tree that
      disagrees with the lock fails, a tag pin that repo resolved to a per-repo
      commit passes, and omitting the option changes nothing;
    * the CI step maps 0/1/2 to pass/drift/incomplete, maps anything else to
      ``error``, and refuses to publish a verdict when no report was produced.

Usage::  python tools/manifest/test-verify-lock.py      # exits 0 on success
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
VERIFY = os.path.join(HERE, "verify-lock.py")
WORKFLOW = os.path.join(REPO, ".github", "workflows", "verify-provenance.yml")

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print("  [PASS] %s" % name)
    else:
        FAILED.append(name)
        print("  [FAIL] %s%s" % (name, ("  <- " + detail) if detail else ""))


def load_verifier():
    spec = importlib.util.spec_from_file_location("verify_lock_under_test", VERIFY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------- unit --
def test_verdict_precedence() -> None:
    """The exit code must not be derivable from "was anything reported?"."""
    print("== verdict precedence ==")
    m = load_verifier()

    def v(problems):
        m.PROBLEMS.clear()
        m.CATEGORIES.clear()
        for msg, cat in problems:
            m.problem(msg, cat)
        return m.verdict()

    cases = [
        ("clean", [], (0, "pass")),
        ("drift only", [("d", m.CAT_DRIFT), ("b", m.CAT_BYTE_DIFF)], (1, "drift")),
        ("unresolved only", [("u", m.CAT_UNRESOLVED)], (2, "incomplete")),
        # The regression: a partial run that ALSO shows real drift must still be
        # reported as incomplete. Reporting "drift" here is what told an operator
        # to re-cut a perfectly good lock.
        ("unresolved + real drift", [("u", m.CAT_UNRESOLVED), ("d", m.CAT_DRIFT)], (2, "incomplete")),
        ("structural failure", [("s", m.CAT_STRUCTURE)], (1, "lock-invalid")),
        # Integrity failures outrank the network, so a flaky run can never mask
        # tampering.
        ("unresolved + structural", [("u", m.CAT_UNRESOLVED), ("s", m.CAT_STRUCTURE)], (1, "lock-invalid")),
    ]
    for name, problems, want in cases:
        got = v(problems)
        check("%s -> %s" % (name, want), got == want, "got %s" % (got,))


# ---------------------------------------------------------------------------- e2e --
def run_with_stub(records, extra_args=()):
    """Run verify-lock.py --live with the resolver stubbed out.

    ``records`` is the list the stubbed resolver will "resolve" to. No network.
    The lock/coverage/pin fixtures are structurally VALID, so a failure reported
    here is genuinely about the live comparison and not about the fixture.
    """
    with tempfile.TemporaryDirectory(prefix="emberbird-vl-test-") as tmp:
        paths = _write_fixtures(tmp)
        driver = os.path.join(tmp, "driver.py")
        with open(driver, "w", encoding="utf-8") as fh:
            fh.write(_DRIVER % (VERIFY, _records_json(records), paths["lock"], PIN_SHA))
        proc = subprocess.run(
            [
                sys.executable,
                driver,
                "--live",
                "--lock",
                paths["lock"],
                "--coverage",
                paths["coverage"],
                "--pin-json",
                paths["pin"],
                "--upstream-dir",
                os.path.join(tmp, "upstream"),
                "--findings-file",
                paths["findings"],
                *extra_args,
            ],
            capture_output=True,
            text=True,
            cwd=REPO,
            timeout=120,
        )
        report = ""
        if os.path.exists(paths["findings"]):
            with open(paths["findings"], encoding="utf-8") as fh:
                report = fh.read()
        return proc, report


def _records_json(records) -> str:
    import json

    return json.dumps(records)


# The stub is injected by REPLACING the tool's `resolver` global from a generated
# driver process, not by a hook inside verify-lock.py. Two reasons it works this
# way: a provenance checker should carry no test-only branches, and the driver is
# a real process, so the exit code under test is the one a caller actually
# observes (sys.exit(main())), not a return value read out of a function.
_DRIVER = '''\
"""Generated by test-verify-lock.py: run verify-lock.py's main() with the network
resolver replaced by a stub, so "upstream drifted" and "upstream could not be
reached" can be produced on demand instead of waited for."""
import importlib.util, json, shutil, sys, types

_spec = importlib.util.spec_from_file_location("verify_lock_under_test", %r)
vl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vl)

_RECORDS = json.loads(r"""%s""")
_LOCK_PATH = %r
_PIN = %r


class _Manifest:
    def load(self, path):
        self.projects = []


def _build_records(man):
    return [dict(r) for r in _RECORDS]


def _resolve_all(records, workers, timeout, retries, checkpoint_path, log=print):
    return None  # the records already carry their outcome; nothing to fetch


def _emit_xml(man, records, pin, out_path):
    # Byte-identical to the committed lock unless a test asks otherwise, so the
    # byte-diff check cannot drown out the signal the test is asserting on.
    shutil.copyfile(_LOCK_PATH, out_path)


vl.resolver = types.SimpleNamespace(
    Manifest=_Manifest,
    build_records=_build_records,
    resolve_all=_resolve_all,
    emit_xml=_emit_xml,
    PIN=_PIN,
)
sys.exit(vl.main(sys.argv[1:]))
'''



PIN_SHA = "9" * 40
LOCKED_SHA = "a" * 40
MOVED_SHA = "b" * 40
# The build recipe's completeness target. The fixture must satisfy the same
# invariant the real lock does, or a structural problem would (correctly)
# outrank the live signal and every exit-code assertion below would be vacuous.
ACTIVE_TARGET = 1175
NOTDEFAULT_COUNT = 8


def _write_fixtures(tmp: str) -> dict:
    """A structurally valid lock + coverage + pin triple, so only the live
    comparison is under test."""
    import json

    lock = os.path.join(tmp, "lock.xml")
    coverage = os.path.join(tmp, "coverage.json")
    pin = os.path.join(tmp, "pin.json")
    findings = os.path.join(tmp, "findings.txt")

    projects = [("x", LOCKED_SHA, None)]
    for i in range(ACTIVE_TARGET - 1):
        projects.append(("filler/%d" % i, LOCKED_SHA, None))
    for i in range(NOTDEFAULT_COUNT):
        projects.append(("notdefault/%d" % i, LOCKED_SHA, "notdefault"))

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!-- EmberbirdOS test lock. Generated from BlissRoms-x86/manifest @ %s -->" % PIN_SHA,
        "<manifest>",
    ]
    for path, rev, groups in projects:
        attrs = 'name="n_%s" path="%s" remote="r" revision="%s"' % (
            path.replace("/", "_"),
            path,
            rev,
        )
        if groups:
            attrs += ' groups="%s"' % groups
        lines.append("  <project %s />" % attrs)
    lines.append("</manifest>")

    with open(lock, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    with open(coverage, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(
            {
                "totals": {"projects": len(projects), "unresolved": 0},
                "unresolved": [],
                "projects": [
                    {"path": p, "locked_revision": r} for p, r, _ in projects
                ],
            },
            fh,
        )

    with open(pin, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"manifest": {"revision": PIN_SHA, "branch": "test"}}, fh)

    return {"lock": lock, "coverage": coverage, "pin": pin, "findings": findings}


def _write_manifest(path: str, projects) -> None:
    """Write a ``repo manifest -r``-shaped manifest: name + path + resolved revision."""
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<manifest>"]
    for entry in projects:
        p, rev = entry[0], entry[1]
        lines.append(
            '  <project name="n_%s" path="%s" revision="%s" />'
            % (p.replace("/", "_"), p, rev)
        )
    lines.append("</manifest>")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def _write_witness_fixtures(tmp: str, projects) -> dict:
    """A valid lock/coverage/pin triple that also carries tag pins.

    The lock here mixes SHA pins and ``refs/tags/*`` pins on purpose: the witness
    check is only interesting if the lock exercises both kinds, because they are
    compared by different (and equally strict) rules.
    """
    import json

    lock = os.path.join(tmp, "lock.xml")
    coverage = os.path.join(tmp, "coverage.json")
    pin = os.path.join(tmp, "pin.json")

    _write_manifest(lock, [(p, r) for p, r, _ in projects])
    # _write_manifest emits no groups and no header comment, and the structural
    # checks need both: the notdefault group for the active-project invariant, and
    # the header naming the pinned manifest revision. So the lock is re-emitted here.
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!-- EmberbirdOS test lock. Generated from BlissRoms-x86/manifest @ %s -->" % PIN_SHA,
        "<manifest>",
    ]
    for p, r, groups in projects:
        attrs = 'name="n_%s" path="%s" revision="%s"' % (p.replace("/", "_"), p, r)
        if groups:
            attrs += ' groups="%s"' % groups
        lines.append("  <project %s />" % attrs)
    lines.append("</manifest>")
    with open(lock, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    with open(coverage, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(
            {
                "totals": {"projects": len(projects), "unresolved": 0},
                "unresolved": [],
                "projects": [{"path": p, "locked_revision": r} for p, r, _ in projects],
            },
            fh,
        )
    with open(pin, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"manifest": {"revision": PIN_SHA, "branch": "test"}}, fh)
    return {"lock": lock, "coverage": coverage, "pin": pin}


def test_exit_codes() -> None:
    print("== exit codes (stubbed resolver, no network) ==")

    def rec(path, rev, status, locked=None):
        return {
            "name": path,
            "path": path,
            "remote": "r",
            "url": "https://example.invalid/%s" % path,
            "groups": None,
            "orig_revision": rev,
            "kind": "branch",
            "locked_revision": locked,
            "resolved_ref": None,
            "status": status,
            "error": None,
            "_declared": {"path": path, "name": path, "remote": "r"},
        }

    # Sanity: the fixture itself must be clean, or every assertion below would
    # pass for the wrong reason (a structural problem outranks the live signal).
    proc, report = run_with_stub([rec("x", LOCKED_SHA, "resolved", LOCKED_SHA)])
    check("a clean fixture re-derives exactly -> exit 0", proc.returncode == 0, report[:300] or proc.stderr[:300])
    check("...and reports verdict: pass", "verdict: pass" in report)

    # --- drift: resolved, but to a different SHA than the lock holds
    proc, report = run_with_stub([rec("x", "refs/heads/main", "resolved", MOVED_SHA)])
    check("drift exits 1", proc.returncode == 1, "got %d" % proc.returncode)
    check("drift report says verdict: drift", "verdict: drift" in report, report[:300])
    check("drift report names the project", "x: committed" in report)

    # --- unresolved: the ref could not be fetched at all
    proc, report = run_with_stub([rec("x", "refs/heads/main", "unresolved")])
    check("unresolved exits 2", proc.returncode == 2, "got %d" % proc.returncode)
    check("unresolved report says verdict: incomplete", "verdict: incomplete" in report, report[:300])
    check(
        "an unresolved ref is NOT listed as drift",
        "[drift]" not in report,
        "drift block present in an incomplete run",
    )

    # --- the regression case: unresolved AND a genuinely drifted sibling
    proc, report = run_with_stub(
        [
            rec("x", "refs/heads/main", "resolved", MOVED_SHA),
            rec("y", "refs/heads/main", "unresolved"),
        ]
    )
    check("unresolved outranks drift -> exit 2", proc.returncode == 2, "got %d" % proc.returncode)
    check(
        "mixed run reports incomplete, not drift",
        "verdict: incomplete" in report and "verdict: drift" not in report,
        report[:300],
    )
    check("mixed run still surfaces the real drift finding", "[drift]" in report)

    # --- unresolved with no orig revision at all (a "no revision" project)
    proc, report = run_with_stub([rec("x", None, "unresolved")])
    check("unresolved with no revision still exits 2", proc.returncode == 2, "got %d" % proc.returncode)


def test_findings_report() -> None:
    print("== findings report ==")

    many = [
        {
            "name": "p%d" % i,
            "path": "p%d" % i,
            "remote": "r",
            "url": "https://example.invalid/p%d" % i,
            "groups": None,
            "orig_revision": "refs/heads/main",
            "kind": "branch",
            "locked_revision": MOVED_SHA,
            "resolved_ref": None,
            "status": "resolved",
            "error": None,
            "_declared": {"path": "p%d" % i},
        }
        for i in range(30)
    ]
    # None of these 30 paths are in the lock, so all 30 read as drift.
    proc, report = run_with_stub(many)
    check("30 drifted projects still exit 1", proc.returncode == 1, "got %d" % proc.returncode)
    check("verdict is drift", "verdict: drift" in report, report[:200])
    check(
        "a bounded finding states how many entries it omitted",
        "not shown here" in report,
        "no omission marker -> a truncated finding would read as complete",
    )
    check("report carries the exit code", "exit-code: 1" in report)
    check("report carries its categories", "categories:" in report)


# ----------------------------------------------------------------------- workflow --
def _dedent(lines) -> str:
    indents = [len(ln) - len(ln.lstrip()) for ln in lines if ln.strip()]
    pad = min(indents) if indents else 0
    return "\n".join(ln[pad:] if len(ln) >= pad else ln for ln in lines).rstrip() + "\n"


def extract_step() -> str:
    """Pull the advisory step's shell out of the workflow, exactly as Actions runs it.

    Done structurally rather than with a YAML parser on purpose: PyYAML is not
    installed on a stock GitHub runner, and a test that quietly degrades to "no
    assertions" in CI is worse than no test. The block scalar is read the way the
    spec defines it -- the lines after ``run: |`` that are indented deeper than
    the key, dedented by their common margin -- and test_workflow_classification
    cross-checks the result against a real parser whenever one happens to be
    available.
    """
    with open(WORKFLOW, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith("- name: Re-resolve"):
            start = i
            break
    if start is None:
        return ""

    run_at = None
    for i in range(start, len(lines)):
        stripped = lines[i].strip()
        if stripped == "run: |" or stripped.startswith("run: |-"):
            run_at = i
            break
        if i > start and stripped.startswith("- name:"):
            break
    if run_at is None:
        return ""

    key_indent = len(lines[run_at]) - len(lines[run_at].lstrip())
    body: list[str] = []
    for line in lines[run_at + 1:]:
        if not line.strip():
            body.append("")
            continue
        if len(line) - len(line.lstrip()) <= key_indent:
            break
        body.append(line)
    return _dedent(body)


def step_via_yaml() -> str:
    """The same step, read through a real YAML parser. Empty if PyYAML is absent."""
    try:
        import yaml
    except ImportError:
        return ""
    with open(WORKFLOW, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    for step in doc["jobs"]["lock-reproducibility"]["steps"]:
        if str(step.get("name", "")).startswith("Re-resolve"):
            return textwrap.dedent(step["run"])
    return ""


def test_workflow_classification() -> None:
    print("== CI step classification ==")
    script = extract_step()
    if not script:
        check("advisory step found in the workflow", False, "could not extract")
        return

    parsed = step_via_yaml()
    if parsed:
        check(
            "the hand-extracted step matches the YAML parser's view",
            parsed.strip() == script.strip(),
            "extraction and parser disagree; assertions below may be reading the wrong text",
        )
    else:
        print("  [SKIP] PyYAML absent; the extraction is not cross-checked against a parser")

    for label, needle in [
        ("classification is by exit code", '2) verdict="incomplete"'),
        ("an unknown code is an error, not a guess", '*) verdict="error"'),
    ]:
        check(label, needle in script)
    # The old implementation decided the verdict with
    # `grep -q 'drifted from the committed lock'`, i.e. by pattern-matching the
    # tool's human-facing prose. If that string comes back, the coupling is back
    # and a rewording can silently mislabel a run.
    check(
        "no string-grep classification",
        "drifted from the committed lock" not in script,
        "the step still pattern-matches verify-lock.py's output",
    )
    check("findings are not truncated with head", "| head -" not in script)

    with tempfile.TemporaryDirectory() as tmp:
        step_path = os.path.join(tmp, "step.sh")
        with open(step_path, "w", encoding="utf-8") as fh:
            fh.write(script)
        syntax = subprocess.run(["bash", "-n", step_path], capture_output=True, text=True)
        check("the extracted step is valid bash", syntax.returncode == 0, syntax.stderr[:200])

        stub_dir = os.path.join(tmp, "stub")
        os.makedirs(stub_dir)
        report = os.path.join(tmp, "report.txt")

        def make_stub(body: str) -> None:
            with open(os.path.join(stub_dir, "python3"), "w", encoding="utf-8") as fh:
                fh.write(body)
            os.chmod(os.path.join(stub_dir, "python3"), 0o755)

        for rc, want in [("0", "pass"), ("1", "drift"), ("2", "incomplete"), ("7", "error")]:
            make_stub(
                "#!/usr/bin/env bash\n"
                'ff=""; prev=""\n'
                'for a in "$@"; do [ "$prev" = "--findings-file" ] && ff="$a"; prev="$a"; done\n'
                'printf "X1 lock verification findings\\nverdict: x\\nexit-code: %s\\n'
                'problems: 1\\n\\n[drift] first line\\n      continuation line\\n" "%s" > "$ff"\n'
                "exit %s\n" % (rc, rc, rc)
            )
            summary = os.path.join(tmp, "summary-%s.md" % rc)
            open(summary, "w").close()
            env = dict(os.environ)
            env["PATH"] = stub_dir + os.pathsep + env["PATH"]
            env["RUNNER_TEMP"] = tmp
            env["GITHUB_STEP_SUMMARY"] = summary
            # Deliberately NOT setting WORKERS: an unset/empty input must not be
            # able to kill the check and leave a stale exit code to be read as drift.
            out = subprocess.run(
                ["bash", step_path], capture_output=True, text=True, env=env, timeout=120
            )
            with open(summary, encoding="utf-8") as fh:
                body = fh.read()
            got = ""
            for line in out.stdout.splitlines():
                if line.startswith("verdict:"):
                    got = line.split()[1]
            check("exit %s -> verdict %s" % (rc, want), got == want, "got %r" % got)
            check("exit %s -> step still exits 0" % rc, out.returncode == 0)
            if want == "drift":
                check(
                    "findings are rendered verbatim, not truncated",
                    "continuation line" in body,
                    "the report was cut short",
                )

        # A check that dies without writing a report must not be reported as drift.
        make_stub('#!/usr/bin/env bash\necho "crashed" >&2\nexit 1\n')
        summary = os.path.join(tmp, "summary-crash.md")
        open(summary, "w").close()
        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env["PATH"]
        env["RUNNER_TEMP"] = tmp
        env["GITHUB_STEP_SUMMARY"] = summary
        subprocess.run(["bash", step_path], capture_output=True, text=True, env=env, timeout=120)
        with open(summary, encoding="utf-8") as fh:
            body = fh.read()
        check(
            "a run that produced no report is never reported as drift",
            "**DRIFT**" not in body,
            "published a drift claim for a check that never completed",
        )
        check("...and says the report was missing", "findings report was not produced" in body)


def test_repo_manifest_witness() -> None:
    """The build-side witness: does ``--repo-manifest`` actually catch a bad tree?

    Until this option existed the build recipe wrote "checked with
    tools/manifest/verify-lock.py" into its provenance record while verify-lock.py
    never opened the ``repo manifest -r`` file the recipe produced next to it. These
    cases pin that the option is load-bearing: a witness that disagrees with the lock
    must fail the build, and -- just as importantly -- a witness whose *tag* pins
    resolve to per-repo commits must PASS, because an AOSP release tag names a
    different commit in every repository. Comparing a resolved tag SHA against the
    lock's tag string is the trap that made an earlier revision audit report 872 of
    1175 correct projects as drifted; it must never be reintroduced here.
    """
    print("== build-side witness (--repo-manifest) ==")

    tag_a = "refs/tags/android-12.1.0_r22"
    # Per-repo resolution: the SAME tag, two DIFFERENT commits, exactly as
    # `repo manifest -r` reports it.
    resolved_a, resolved_b = "b" * 40, "c" * 40

    projects = [
        ("x", LOCKED_SHA, None),
        ("tagged_a", tag_a, None),
        ("tagged_b", tag_a, None),
    ]
    for i in range(ACTIVE_TARGET - len(projects)):
        projects.append(("filler/%d" % i, LOCKED_SHA, None))
    for i in range(NOTDEFAULT_COUNT):
        projects.append(("notdefault/%d" % i, LOCKED_SHA, "notdefault"))

    def run(witness_projects=None, *, omit_witness=False, expect_missing=False):
        with tempfile.TemporaryDirectory(prefix="emberbird-witness-") as tmp:
            paths = _write_witness_fixtures(tmp, projects)
            witness = None
            if witness_projects is not None or expect_missing:
                witness = os.path.join(tmp, "repo-manifest-r.xml")
                if witness_projects is not None:
                    _write_manifest(witness, witness_projects)
            argv = [
                sys.executable,
                VERIFY,
                "--lock",
                paths["lock"],
                "--coverage",
                paths["coverage"],
                "--pin-json",
                paths["pin"],
            ]
            if witness is not None:
                argv += ["--repo-manifest", witness]
            return subprocess.run(argv, capture_output=True, text=True, cwd=REPO, timeout=120)

    # The witness repo writes lists EVERY project in the manifest, not just the active
    # ones, so the fixture witness must too - otherwise the coverage check is really
    # testing a missing notdefault project rather than anything about tags.
    tag_resolution = {"tagged_a": resolved_a, "tagged_b": resolved_b}
    good = [
        (p, tag_resolution.get(p, r) if r.startswith("refs/tags/") else r)
        for p, r, _ in projects
    ]

    proc = run(good)
    check(
        "a witness whose tags resolve to per-repo commits PASSES",
        proc.returncode == 0,
        "exit %d: %s" % (proc.returncode, proc.stderr[-400:]),
    )
    check(
        "...and says so, rather than silently accepting any 40-hex",
        "resolved to a concrete commit" in proc.stdout,
        proc.stdout[-300:],
    )

    proc = run(expect_missing=True)
    check("a witness that does not exist FAILS", proc.returncode == 1, "got %d" % proc.returncode)

    drifted = [("x", "0" * 40)] + good[1:]
    proc = run(drifted)
    check(
        "a SHA pin that moved is caught",
        proc.returncode == 1 and "are not at their locked revision" in proc.stderr,
        proc.stderr[-300:],
    )

    proc = run(good[:-1])
    check(
        "a project dropped from the tree is caught",
        proc.returncode == 1 and "absent from the synced tree" in proc.stderr,
        proc.stderr[-300:],
    )

    proc = run(good + [("rogue/project", "1" * 40)])
    check(
        "a project nobody pinned is caught",
        proc.returncode == 1 and "the lock does not pin" in proc.stderr,
        proc.stderr[-300:],
    )

    unresolved = [(p, tag_a if p == "tagged_a" else r) for p, r in good]
    proc = run(unresolved)
    check(
        "a moving ref that reached the build unresolved is caught",
        proc.returncode == 1 and "were not resolved to a commit" in proc.stderr,
        proc.stderr[-300:],
    )
    check(
        "the witness verdict is distinguishable from upstream drift",
        "witness-mismatch" in proc.stderr,
        proc.stderr[-300:],
    )

    # No --repo-manifest at all: the offline CI path must be completely unaffected.
    proc = run()
    check("omitting --repo-manifest leaves the offline check untouched", proc.returncode == 0)


def main() -> int:
    print("EmberbirdOS - verify-lock.py exit-code contract\n")
    test_verdict_precedence()
    print()
    test_exit_codes()
    print()
    test_repo_manifest_witness()
    print()
    test_findings_report()
    print()
    test_workflow_classification()
    print("\n== summary ==")
    print("  %d passed, %d failed" % (len(PASSED), len(FAILED)))
    if FAILED:
        for name in FAILED:
            print("  FAILED: %s" % name)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
