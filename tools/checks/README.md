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
| X1 lock, verifier contract | `../manifest/test-verify-lock.py` | the `0/1/2` exit-code contract the advisory CI step branches on |
| X1 lock, **generator** | `test-manifest-resolver.py` | ref classification, the `ls-remote` retry policy, `<include>`/`<remove-project>` handling, and byte-determinism of the emitted lock |
| build recipe | `test-build-recipe.py` | the recipe's two embedded Python heredocs, artifact discovery, and the completeness constants it shares with the lock |
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
