# Offline checks

Everything about EmberbirdOS that can be proven with **bash + python3 only** -- no
PowerShell, no QEMU, no `repo`, no AOSP tree, no network, no VM.

```bash
bash tools/checks/run-offline-checks.sh
```

Exit code `0` means every check passed. The suite never stops at the first failure:
one red check should not hide the state of the others, so all of them run and the
summary names every failure at the end.

## Why this exists

The project's checks run in three environments, and only one of them was scripted:

| Environment | Can verify | Where |
|---|---|---|
| POSIX sandbox / Linux runner | shell + python + the captured manifests | **this directory** |
| `windows-latest` runner | parses and *executes* the PowerShell | `.github/workflows/launcher-tests.yml` |
| big-disk build node | `repo sync` + the AOSP build | `guest-build.yml` / Crave |

The first environment previously had nothing to run. Verification there was a
series of ad-hoc commands, so the parts of the tooling that *can* be proven
locally were proven only by whoever remembered to type them. This is that one
command.

## What each check pins

| Check | File | Pins |
|---|---|---|
| shell syntax | `run-offline-checks.sh` | `bash -n` over every tracked `*.sh` |
| python syntax | `run-offline-checks.sh` | every tracked `*.py` compiles (in memory; writes no `.pyc`) |
| captured upstream manifests | `run-offline-checks.sh` | every file still matches `image/manifest/upstream/SHA256SUMS.txt` -- the anti-tampering half of the blocking `verify-provenance` job |
| X1 lock, structural | `../manifest/verify-lock.py` | every project immutable, none unresolved, paths unique, the 1175 active-project invariant, lock/coverage/pin agreement |
| X1 lock, verifier contract | `../manifest/test-verify-lock.py` | the `0/1/2` exit-code contract the advisory CI step branches on, plus `--repo-manifest`: that every locked path is in the `repo manifest -r` witness, that nothing extra is, that SHA pins match exactly, and that every tag pin resolved to a concrete commit |
| X1 lock, **generator** | `test-manifest-resolver.py` | ref classification, the `ls-remote` retry policy, `<include>`/`<remove-project>` handling, and byte-determinism of the emitted lock |
| X2 evidence, pulled record | `../manifest/verify-x2-provenance.py` | that `image/out/x2-provenance.json` describes the artifacts actually on disk: every recorded hash and byte count matches, no unrecorded `.iso`/`.img` is sitting beside it, and `manifest_revision` equals the committed X1 pin |
| X2 evidence, verifier contract | `../manifest/test-verify-x2-provenance.py` | that the check above *fails* on a stale, truncated, unrecorded, traversing or wrong-build record, and that an empty artifact list is a failure rather than a vacuous pass |
| build recipe | `test-build-recipe.py` | the recipe's two embedded Python heredocs, artifact discovery, and the completeness constants it shares with the lock |
| revision audit | `test-revision-audit.sh` | the recipe's verification guards extracted *verbatim* by `lib-audit.sh`: `revision_audit()` (per-project tag resolution, a tag one repository has and another does not, and the 303324 regression — a `repo manifest -r` witness corroborates the verdict and can never produce it), `sanitize_worktrees()`, `resolve_witness()` (refresh ordering + a stubbed `repo`), and the preflight pair `inspect_seed()` / `manifests_clean()` against synthetic `.repo` trees |
| crave wrapper | `test-crave-remote-build.sh` | `run-remote-build.sh`'s `status`, `log` and `pull`, driven end-to-end against a **stub** client on `CRAVE_SHIM` that records the argv it was called with: that every client call is pinned (`getlog --projectID/--jobID`, `pull --projectID/--job`), that the real section headers (`Your active jobs:` / `Job History:`) are parsed and other tables are not, that "left the queue" is distinguished from "the client drew no table", that a client `Error:` line or nonzero exit makes the command exit nonzero, that all three refuse to run without a job id (and make no client call at all), that `pull` clears the ticket's staging dir first so a previous job's artifacts can never be copied and verified as this job's, and that the machine-readable `list --jobID <id> --json` record is read as the primary answer (status, exit code, start/end and the duration between them, job url) with the human tables kept as fallback and as corroboration — a json document arriving behind the client's `Error:` line is still read out *and* still fails closed, unparseable json costs nothing, and the two probes disagreeing about whether the job exists is reported as DISPUTED rather than resolved in favour of one |
| fixture git | `lib-fixtures.sh` + `git-shim.sh` | whether this environment's git can record a revision at all; when it cannot, the shim stands in so the audit still runs against real revisions instead of a field of unborn HEADs |
| PowerShell, static | `check-powershell-static.py` | ASCII purity, delimiter pairing, no dangling refs to removed symbols, and the launcher's deliberate `-DryRun` fast path |
| shellcheck | `run-offline-checks.sh` | every shell script, when shellcheck is installed (informational: it is neither pinned nor installed project-wide, so it never reds a run) |
| lock immutability | `run-offline-checks.sh` | the committed lock/coverage/pin/checkpoint hashes are identical before and after the run |

## What this cannot cover

A green run here is **not** full coverage. The suite prints this at the end so it
cannot be mistaken for one:

* **Parsing and running the PowerShell** stays the `windows-latest` job's purpose.
  The static checks in `check-powershell-static.py` mean "obviously not broken",
  not "runs".
* **`repo sync` and the AOSP build** need a multi-hundred-GB node. The recipe's
  expensive half is untestable here; its deterministic half is not.
* **QEMU boot and the X3-X5 evidence** need a WHPX-provisioned Windows host.
* **`repo` itself** is not available here. The revision audit is exercised with a
  *stubbed* `repo manifest -r` (and its absence), so what is pinned is the audit's
  decision logic -- not that a real `repo` emits the XML the recipe expects. Note that
  the stub can only tell you how the audit *treats* a witness: the finding behind job
  303324 was that `repo manifest -r` reports what the tree already holds, so it is a
  corroborating reading and never the yardstick. The stub is faithful to that contract.
* **A real pulled image.** Until a Crave job has actually succeeded and
  `image/out/x2-provenance.json` exists, `verify-x2-provenance.py` exits **2** and the
  suite reports a `skip`. That is not a pass: it is how "there is no image yet" stays
  distinguishable from "the image was verified".

## When a sandbox blocks `git commit`

Some sandboxed environments refuse the revision-recording subcommand outright. That
makes fixture-driven tests fail for a reason that has nothing to do with what they test:
every fixture repo is left with an unborn `HEAD`, and the assertions fail on the
fixtures instead of the code.

`lib-fixtures.sh` handles this without hardcoding the problem:

- `emberbird_git_can_record` **probes** the ambient git in a throwaway `mktemp` repo.
- `emberbird_ensure_git_record <scratch>` is a no-op when the probe succeeds, and only
  then installs `git-shim.sh` ahead of the real git on `PATH`.
- `EMBERBIRD_GIT_RECORD` is exported as `native` or `shim`, and the test prints which
  one it got, so a green run says *how* it went green.

`git-shim.sh` implements the blocked subcommand with git **plumbing**
(`write-tree` → `hash-object -t commit -w` → `update-ref`) and `exec`s everything else
to `$EMBERBIRD_REAL_GIT`, which it never guesses -- guessing risks `PATH` recursion.
Unrecognised flags are rejected with exit 2 rather than silently ignored, so the shim
cannot quietly do less than real git.

Two rules keep this honest. It is **conditional**, so an ordinary machine gets no
wrapper on `PATH` at all. And any test using it asserts first that its fixture `HEAD`
resolves to a full sha (scenario 0 in `test-revision-audit.sh`), so a broken fixture git
fails immediately and loudly instead of turning every later scenario red for an unrelated
reason.

## Proving a check is load-bearing

A source-level check that reads the recipe's own text -- its call order, its constants,
its embedded heredocs -- passes trivially against the recipe it was written for, and a
typo in the pattern silently turns it into a check that passes against anything.
`lib-audit.sh` therefore honours `EMBERBIRD_RECIPE`, which points the whole suite at a
different recipe revision:

```bash
git show HEAD~1:tools/guest-build/build-from-manifest.sh > /tmp/old.sh
EMBERBIRD_RECIPE=/tmp/old.sh bash tools/checks/test-revision-audit.sh   # must FAIL
```

The Crave wrapper's test honours the same idea under a different name,
`EMBERBIRD_CRAVE_RUNNER`, because it drives the script itself rather than extracted
fragments of it:

```bash
git show HEAD~1:tools/crave/run-remote-build.sh > /tmp/old-crave.sh
EMBERBIRD_CRAVE_RUNNER=/tmp/old-crave.sh bash tools/checks/test-crave-remote-build.sh  # must FAIL
```

One honest limit on that control: which previous revision you point at decides what it
can prove. The revision before the `status` fix (`6e09b54`) had no `CRAVE_SHIM`
override, so pointing the test at it makes the script call the **real** client — it
goes red on the substantive assertions, but its exit code is then that of a real API
round-trip rather than of the stub, so treat that control as evidence about
*behaviour*, not exit codes. The revision after it (`51177d8`: status fixed, `log` and
`pull` still soft) has the override, so the same control drives the stub end to end
and goes red on the `log`/`pull` assertions for exactly the right reasons: unpinned
fallbacks, swallowed client errors, and a stale `.iso` from a previous pull copied
into `image/out/`. The revision before the json probe (`540c549`) is stub-drivable the
same way and goes red on exactly the 14 assertions that scenario 9 adds: the probe is
never issued, so its state is neither reported nor judged, and the failure is silent.

Anything the previous commit was missing must go red, for the right reason, *without
aborting the run* -- a check that crashes the suite instead of reporting a failure hides
the state of every scenario after it, which is the one thing this suite exists to prevent.

This is how the 303324 regression test was validated rather than merely written. The
pre-fix recipe, pointed at by `EMBERBIRD_RECIPE`, reports
`OK all 6 active projects ... (6/6 resolved via repo manifest -r)` over a tree with a
deliberately drifted project -- the same shape as the `OK all 1175 active projects ...
(1175/1175 resolved via repo manifest -r)` that job 303324 printed over a tree with 190
drifted projects. A regression test that passes against the code it was written to fix is
decorative; this one was confirmed to fail against that code first.

## Rules for adding a check here

1. **Read-only.** Nothing in this directory may write inside the repository. Temp
   directories only. The committed X1 lock is the artifact that must never move, so
   `run-offline-checks.sh` brackets the whole run with its hash and fails if it
   changed.
2. **Never call `resolve-manifest-lock.py`'s `main()`.** It rewrites the lock in
   place. Exercise it at function granularity instead (`test-manifest-resolver.py`
   is the model). The immutability check above is the backstop, not the licence.
3. **Offline and deterministic.** Stub the network rather than reaching it, so a
   check cannot go red because someone's remote was slow.
4. **Add it to `run-offline-checks.sh`.** A check nobody runs is documentation.
