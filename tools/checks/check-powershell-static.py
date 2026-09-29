#!/usr/bin/env python3
"""Static checks for the PowerShell tooling -- what can be proven WITHOUT a PowerShell runtime.

WHY THIS EXISTS
    Neither this sandbox nor a Linux CI runner has ``pwsh``/``powershell``, so
    nothing about ``tools/qemu/launch-emberbird.ps1`` or ``provision-host.ps1``
    could be verified locally: the only feedback was a ``windows-latest`` job
    minutes later. That is a bad loop to make a small edit in, and it is how a
    mangled brace or a stray locale byte reaches CI at all.

    These are the checks that are decidable from the source text alone:

      * pure ASCII. The launcher suite asserts this on Windows; catching it here
        means a locale-dependent byte never leaves the machine (and
        provision-host.ps1's report is committed as evidence text).
      * balanced ``()``/``{}``/``[]``, with PowerShell's string and comment forms
        excluded from the count: single- and double-quoted strings (including the
        doubled-quote and backtick escapes), ``#`` line comments, ``<# #>`` block
        comments, and ``@' '@`` / ``@" "@`` here-strings. This is not a parser - it
        is a delimiter-pairing check that catches what a bad text edit actually
        produces, and it self-tests against a real file with one brace deleted so
        that a green run means something.
      * no dangling references to symbols removed during refactoring (the launcher
        suite's own static assertion, checked here too).
      * the launcher's WHPX probe stays behind the ``-DryRun`` guard, so the
        fast path cannot silently regress into a multi-second component-store
        query again.

    What this CANNOT do is parse or execute the scripts. A green run here means
    "obviously not broken", not "runs" - that stays the Windows job's purpose.

Usage::  python tools/checks/check-powershell-static.py     # exits 0 on success
"""

from __future__ import annotations

import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

LAUNCHER = os.path.join(REPO, "tools", "qemu", "launch-emberbird.ps1")
PROVISIONER = os.path.join(REPO, "tools", "qemu", "provision-host.ps1")
LAUNCHER_SUITE = os.path.join(REPO, "tools", "qemu", "tests", "Test-Launcher.ps1")

PS_FILES = (
    ("launch-emberbird.ps1", LAUNCHER),
    ("provision-host.ps1", PROVISIONER),
    ("Test-Launcher.ps1", LAUNCHER_SUITE),
)

#: Symbols deleted during earlier refactoring of the launcher. The Windows suite
#: greps for these; a stale reference survives a delimiter check, so it is checked
#: here rather than waiting for a second CI round trip.
DANGLING_SYMBOLS = ("Resolve-OvmfFile", "__OVMF_RESOLVE_PAIR__")

CLOSER = {")": "(", "]": "[", "}": "{"}

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


def scan_delimiters(src: str) -> list[str]:
    """Return a message for every unbalanced or mismatched delimiter in ``src``.

    Scans once, atomically skipping the regions where PowerShell does not treat
    these characters structurally. Skipping strings whole is what makes this
    usable at all: ``"${DataDiskSizeGB}G"`` and ``'[\\s,=]'`` are full of
    delimiters that are not delimiters.
    """
    problems: list[str] = []
    stack: list[tuple[str, int]] = []
    i, line, n = 0, 1, len(src)

    while i < n:
        ch = src[i]

        if ch == "\n":
            line += 1
            i += 1
            continue

        # <# ... #> and # to end-of-line must be handled BEFORE quotes: a comment
        # may contain an apostrophe ("doesn't"), and quotes are consumed whole, so
        # a '#' inside a string is never reached anyway.
        if src.startswith("<#", i):
            end = src.find("#>", i + 2)
            if end == -1:
                problems.append("line %d: unclosed <# block comment" % line)
                break
            line += src.count("\n", i, end + 2)
            i = end + 2
            continue

        if ch == "#":
            end = src.find("\n", i)
            i = n if end == -1 else end
            continue

        # @' ... '@ and @" ... "@ -- the terminator is the REVERSED delimiter
        # (not a doubled one), and it must start a line.
        if ch == "@" and i + 1 < n and src[i + 1] in "\"'":
            terminator = src[i + 1] + "@"
            start_line = line
            end = src.find("\n", i)
            if end == -1:
                problems.append("line %d: here-string opener with no body" % start_line)
                break
            line += src.count("\n", i, end + 1)
            i = end + 1
            closed = False
            while i < n:
                if src.startswith(terminator, i) and (i == 0 or src[i - 1] == "\n"):
                    i += 2
                    closed = True
                    break
                end = src.find("\n", i)
                if end == -1:
                    i = n
                    break
                line += src.count("\n", i, end + 1)
                i = end + 1
            if not closed:
                problems.append("line %d: unterminated here-string %s" % (start_line, terminator))
            continue

        if ch in "\"'":
            quote = ch
            start_line = line
            i += 1
            closed = False
            while i < n:
                c = src[i]
                if c == "`":  # backtick escape (also escapes newlines)
                    i += 2
                    continue
                if c == "\n":
                    line += 1
                    i += 1
                    continue
                if c == quote:
                    if i + 1 < n and src[i + 1] == quote:  # doubled-quote escape
                        i += 2
                        continue
                    i += 1
                    closed = True
                    break
                i += 1
            if not closed:
                problems.append(
                    "line %d: unterminated %s string"
                    % (start_line, "single-quoted" if quote == "'" else "double-quoted")
                )
            continue

        if ch in "([{":
            stack.append((ch, line))
            i += 1
            continue

        if ch in ")]}":
            if not stack:
                problems.append("line %d: closing '%s' with nothing open" % (line, ch))
            else:
                opener, opener_line = stack.pop()
                if opener != CLOSER[ch]:
                    problems.append(
                        "line %d: '%s' closes '%s' opened on line %d"
                        % (line, ch, opener, opener_line)
                    )
            i += 1
            continue

        i += 1

    for opener, opener_line in stack:
        problems.append("line %d: '%s' is never closed" % (opener_line, opener))
    return problems


# ------------------------------------------------------------------------ cases --
SCANNER_CASES = (
    ("balanced delimiters", "$a = @{ x = 1 }\n", 0),
    ("unclosed block", "if ($x) {\n  $y = 1\n", 1),
    ("stray closer", "}\n", 1),
    ("mismatched pair", "foo( ]\n", 1),
    ("brace inside a single-quoted string", "$a = '}('\n", 0),
    ("brace inside a line comment", "# }} )\n", 0),
    ("brace inside a block comment", "<# ( }} ) #>\n", 0),
    ("apostrophe inside a block comment", "<# doesn't break } #>\n", 0),
    ("here-string content", "$x = @'\n{{ )\n'@\n", 0),
    ("double-quoted subexpression", '"${a}G"\n', 0),
    ("doubled-quote escape", "$a = 'it''s }'\n", 0),
    ("backtick-escaped quote", '$a = "a `" }"\n', 0),
    ("regex character class in a string", "$p -match '[\\s,=]'\n", 0),
)


def test_scanner_self_test() -> None:
    print("== delimiter scanner (self-test) ==")
    for name, src, want in SCANNER_CASES:
        got = scan_delimiters(src)
        check(
            "scanner: %s" % name,
            len(got) == want,
            "wanted %d problem(s), got %r" % (want, got),
        )

    # Tie the synthetic cases to the real thing: a real file with ONE closing brace
    # deleted must be flagged, or a green run on the real files proves nothing.
    real = read(LAUNCHER)
    idx = real.rfind("}")
    if idx == -1:
        check("scanner: the launcher has a closing brace to delete", False)
        return
    broken = real[:idx] + real[idx + 1:]
    check(
        "scanner flags a real file with one '}' deleted",
        len(scan_delimiters(broken)) >= 1,
        "a deleted brace went unnoticed",
    )
    check(
        "scanner flags a stray '(' appended to a real file",
        len(scan_delimiters(real + "\nfunction Broken {\n")) >= 1,
        "an unclosed function block went unnoticed",
    )


def test_files() -> None:
    print("== source-level checks ==")
    for name, path in PS_FILES:
        if not os.path.exists(path):
            check("%s exists" % name, False, "missing %s" % path)
            continue
        src = read(path)
        problems = scan_delimiters(src)
        check("%s: delimiters balance" % name, not problems, "; ".join(problems[:3]))

        non_ascii = [b for b in open(path, "rb").read() if b > 0x7F]
        check(
            "%s: pure ASCII" % name,
            not non_ascii,
            "%d non-ASCII byte(s)" % len(non_ascii),
        )


def test_dangling_symbols() -> None:
    print("== no dangling references to removed symbols ==")
    src = read(LAUNCHER)
    for symbol in DANGLING_SYMBOLS:
        check(
            "the launcher does not reference '%s'" % symbol,
            symbol not in src,
            "stale reference to a symbol that was removed",
        )


def test_launcher_dryrun_fast_path() -> None:
    print("== launcher: the -DryRun fast path ==")
    src = read(LAUNCHER)
    marker = "# === main ="
    check("the boot-path marker is still present", marker in src, "cannot locate the boot path")
    if marker not in src:
        return
    head, _, main = src.partition(marker)

    check(
        "the boot path probes WHPX only behind the -DryRun guard",
        re.search(
            r"if\s*\(-not\s+\$DryRun\)\s*\{\s*\n\s*\$whpx\s*=\s*Get-WhpxStatus", main
        )
        is not None,
        "the guard around Get-WhpxStatus was moved or removed, so -DryRun would "
        "again pay a component-store query just to print a command line",
    )
    check(
        "the boot path references Get-WhpxStatus exactly once",
        main.count("Get-WhpxStatus") == 1,
        "found %d reference(s) in the boot path" % main.count("Get-WhpxStatus"),
    )
    check(
        "the readiness report (-Check) still reports WHPX state",
        "$whpx = Get-WhpxStatus" in head,
        "Invoke-ReadinessReport no longer probes WHPX",
    )
    # -DryRun must stay side-effect-free; the suite asserts the observable half of
    # this on Windows, this pins the ordering that makes it true.
    check(
        "-DryRun is decided before the disk/NVRAM are materialized",
        "if ($DryRun) {" in src
        and src.index("if ($DryRun) {")
        < src.index("$dataPath = Initialize-DataDisk"),
        "the DryRun branch no longer precedes Initialize-DataDisk",
    )


def test_provisioner_extraction() -> None:
    print("== provisioner: platform-tools extraction ==")
    src = read(PROVISIONER)
    check(
        "the fast extractor is used",
        "[System.IO.Compression.ZipFile]::ExtractToDirectory" in src,
        "the ZipFile extraction path was removed",
    )
    check(
        "the Expand-Archive fallback is retained",
        "Expand-Archive -LiteralPath $zip" in src,
        "the fallback for a host without the compression assembly was removed",
    )
    check(
        "the destination is cleared before extraction",
        src.index("Remove-Item -LiteralPath $Destination -Recurse -Force")
        < src.index("[System.IO.Compression.ZipFile]::ExtractToDirectory"),
        "extraction no longer follows the destination cleanup",
    )


def main() -> int:
    print("EmberbirdOS - PowerShell static checks (no PowerShell runtime required)")
    print()
    with tempfile.TemporaryDirectory(prefix="emberbird-ps-static-"):
        test_scanner_self_test()
    test_files()
    test_dangling_symbols()
    test_launcher_dryrun_fast_path()
    test_provisioner_extraction()

    print()
    print("== summary ==")
    print("  %d passed, %d failed" % (len(PASSED), len(FAILED)))
    print(
        "  NOTE: these are source-level checks only. Parsing and running the scripts"
        " still requires the windows-latest job."
    )
    if FAILED:
        for name in FAILED:
            print("  [FAIL] %s" % name, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
