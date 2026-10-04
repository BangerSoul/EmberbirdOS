# M2 X2 — building the guest on Crave (remote), then pulling it locally

> **Why this exists.** M2's X2 artifact (the Android-x86_64 guest image) must be built
> from the pinned manifest, and a from-source build of BlissOS `arcadia-x86` needs
> ~300 GB of disk. The M2 host has ~104 GB, and there is no provenance-usable prebuilt
> to fall back on ([`evidence/M2/x2-artifact-availability.txt`](evidence/M2/x2-artifact-availability.txt)):
> BlissOS's public images are paused. So the build runs **remotely** — on [Crave](https://foss.crave.io),
> the platform the Android ROM community uses for exactly this — and only the small
> results come back: the image plus its X2 provenance record.
>
> **This is a runbook, and it has been executed — but it is still not a result.** On
> 2026-09-24 the remote build was launched against the owner's Crave account
> (first job **301689** on `LOS 20` id 36, cancelled while still queued; relaunched as job
> **301767** on project `LOS 22.1` id 93, platform `linux16`
> <https://foss.crave.io/app/#/build/info/301767?team=14>). It is recorded as **queued**, and
> as of this writing it has not run: it sits in the **free build queue** waiting for a
> node. The launcher submits with `--platform linux16`, whose listed token rate is **0** —
> the free tier — so this is a queue-position wait, **not** a token/compute gate. The
> launch path is therefore proven end to end up to the queue, and X2 stays OPEN until an
> artifact comes back, is re-hashed locally and is recorded under `docs/evidence/M2/`. See
> [Executed 2026-09-24](#executed-2026-09-24-what-the-run-actually-required) for the exact
> findings, including the client defect that blocked the first attempt.

## What runs where

| Step | Where | Artifact |
|---|---|---|
| `repo init` + pin manifests to the X1 revision | Crave machine | pinned checkout |
| `repo sync -c` (~300 GB, the expensive part) | Crave machine | synced tree |
| `repo manifest -r`, checked against the committed X1 lock via `verify-lock.py --repo-manifest` | Crave machine | [`image/out/repo-manifest-r.xml`](../image/out) (git-ignored) |
| `lunch` + `make iso_img` | Crave machine | the guest image |
| SHA-256 + size + revision + toolchain → X2 record | Crave machine | `image/out/x2-provenance.json` |
| `crave pull image/out/` | your machine | the image + the X2 record |
| Boot it with the frozen launcher (X3–X5) | your Windows host | [`evidence/M2/`](evidence/M2/) |

One recipe drives all of it: [`../tools/guest-build/build-from-manifest.sh`](../tools/guest-build/build-from-manifest.sh).
The same script is what [`.github/workflows/guest-build.yml`](../.github/workflows/guest-build.yml)
runs on any runner with the disk, so the Crave path and the CI path cannot drift.

## One-time setup

1. **Crave account + client.** Sign in at <https://foss.crave.io>, then from the
   *Downloads* tab take the client for your platform, and from *API Keys* take your
   `crave.conf`.
2. **Keep the credential out of the repo.** `crave.conf` is an API key. Crave looks for
   it in the working directory or any parent, then in `$HOME`, or you can point at it
   with `-c`. Store it as `~/crave.conf` — **never** commit it (`.gitignore` does not
   need to cover it if it lives in `$HOME`; do not copy it into the tree).
3. **No Crave project is needed for this repository — do not create one.** Crave resolves
   the project from the **git URL of the current directory**, so running `crave run` from a
   checkout of this repo fails with `could not get project information for <this repo>`
   (passing `--projectID` does not help; the client still wants a local project identity).
   `crave.yaml` alone does not lift that either.

   The job is therefore launched from a throwaway **ticket checkout** whose origin *is* the
   base project's source URL — `tools/crave/run-remote-build.sh` creates it under
   `$TEMP/crave-ticket-<project-slug>` (e.g. `crave-ticket-los20`, keyed to the project
   *name* so it is stable per project and a switch cannot silently reset the build cache)
   and the job bootstraps this repository inside the remote workspace at the exact commit
   you are standing on. A Crave project is never created, and none is needed: the base
   project is a **container**, and M2's provenance anchor remains the X1 lock.

   Which container, and why: the pinned manifest is Bliss's `arcadia-x86` on an Android 13
   base, so the base project is `LOS 20` (id **36**, <https://github.com/accupara/los20.git>),
   Crave's Android 13 AOSP project. `crave.yaml` in this repo pins that choice plus two
   overrides (`ignoreClientHostname`, `no-patch`). The launcher does **not** overwrite the
   ticket's own `crave.yaml`: it *merges* our per-project block into whatever the base
   project ships (writing to `.repo/manifests/crave.yaml` when the tree is repo-based, else
   the top), and it **fails loudly** if our overrides are not keyed to the project name
   being launched — because Crave matches the block by dashboard project name, so a
   name/id mismatch would silently drop `ignoreClientHostname`/`no-patch` (exactly what the
   301767 relaunch under `LOS 22.1` did).

   This match is **required, not a preference**. Crave's own rule
   (`~/.crave/docs/crave/getting-started/unsupported-roms.md`): *"Sync android 14 ROMs on
   Android 14 base project only."* An Android 13 tree is therefore synced on the Android 13
   base project. Relaunching this job under `LOS 22.1` (id 93, **Android 15**) broke that
   rule and was one of the two faults in the first real run — see
   [`evidence/M2/x2-job-301767-failure.txt`](evidence/M2/x2-job-301767-failure.txt).

   **Platform:** project 36 accepts `linux16` (`t2d-standard-16`) and refuses `linux32`,
   `linux64`, `linux-all` and `linux-t2d-32` with `Invalid platform for project`.
   `aosp-silver` fails differently (`Cannot read properties of null (reading 'details')`).
   So the platform is not a free choice — see the probe matrix below.

## The build

From a checkout of this repository:

```sh
# launch (detached) - creates/refreshes the ticket, pins this exact commit, prints the job
bash tools/crave/run-remote-build.sh run

# watch it / read the whole remote log
# `status` EXITS NONZERO when the client could not answer, so it is safe in a script.
# JOB=<id> pins the lookup; without it the id recorded by `run` is used.
bash tools/crave/run-remote-build.sh status
bash tools/crave/run-remote-build.sh log

# leave a watcher running: it polls until the job reports success, then pulls the
# artifact and the X2 record by itself (a queued job plus a multi-hour build makes
# "check back later" the normal case, not the exception)
bash tools/crave/run-remote-build.sh watch

# pull back only the small results, into image/out/
bash tools/crave/run-remote-build.sh pull
```

The launcher does three things that are not optional, and explains why in its header:

1. it runs the job from a **ticket checkout** whose origin is the base project's URL (the
   only way `crave run` resolves a project for this repo), and **merges** this repo's
   `crave.yaml` overrides into it (see below — it does not clobber the base project's own
   `crave.yaml`);
2. it pins the job to the **exact commit** you are on, so a later push cannot silently
   change what was built;
3. it goes through `tools/crave/crave.sh`, which always passes the client's `-n` flag and
   clears the poisoned update state — otherwise every Crave call costs 107 s and 2 x 28 MB
   before it does anything ([CRAVE-CLIENT-UPDATE-LOOP.md](CRAVE-CLIENT-UPDATE-LOOP.md)).

Before submitting, `run` also **refuses to launch while this account already has a job
queued or running** — Crave's Queue Rule (`crave/rules.md`) is one build at a time per
account, and breaking it is what produced the 301689→301767 pile-up. It reads the client's
"Your active jobs" table; if it is non-empty the launch aborts with the active job listed.
Stop the active job first (`bash tools/crave/run-remote-build.sh stop`), or set `FORCE=1`
if you have just stopped it and the table has not refreshed yet.

`--no-patch` is implicit in the launcher: it builds the committed revision as-is instead of
uploading your local diff, which is what we want, because X2 must describe **the pinned
manifest**, not a working tree. The first run pays for the full `repo sync`; Crave caches
build trees and compiler output, so later runs are much cheaper.

Inside the remote job, `WORKSPACE` is set to the job's **workspace root** — `$PWD` captured
*before* the source checkout is entered, i.e. the directory Crave provisions that already
owns `.repo`. It is deliberately **not** a folder created under that root.

That is a hard Crave rule, not a preference. `~/.crave/docs/crave/rules.md`:
*"Do not make a folder and sync inside that to avoid conflicts (like `cd folder; repo
sync`)"*, and `unsupported-roms.md` repeats it as *"Do not use `rm -rf *` or `cd` into
another folder in crave run before syncing, no matter who tells you to."* The reason is
mechanical: `repo` searches **upward** for an existing `.repo`, and the Crave workspace
root is itself a repo checkout. Syncing from a nested folder makes `repo` reuse the root
(`repo: reusing existing repo client checkout in /tmp/src/android`) while every relative
`.repo/…` path resolves against the nested cwd — which dies with
`fatal: cannot change to '.repo/manifests': No such file or directory` (exit 128).
`build-from-manifest.sh` now **refuses to start** if `WORKSPACE` is nested under another
checkout's `.repo`.

The EmberbirdOS source is checked out beside the sync root (`<root>/eb`), and the X2 record
plus the image land in `eb/image/out/` for a single `pull`.

Prefer a persistent environment? Enter a devspace and run the same script inside it:

```sh
crave -c ~/crave.conf devspace
# inside the devspace:
crave clone create --projectID <your project id> emberbird && cd emberbird
crave run --no-patch -- "bash tools/guest-build/build-from-manifest.sh"
```

Overridable environment variables (set them inside the `crave run` command string):

| Var | Default |
|---|---|
| `LUNCH_TARGET` | `bliss_x86_64-userdebug` |
| `MAKE_TARGET` | `iso_img` |
| `MANIFEST_URL` / `MANIFEST_BRANCH` | `https://github.com/BlissRoms-x86/manifest.git` / `arcadia-x86` |
| `MANIFEST_REVISION` | read from [`image/manifest/arcadia-x86.pin.json`](../image/manifest/arcadia-x86.pin.json) |
| `WORKSPACE` | `$HOME/emberbird-build/aosp` (the Crave launcher overrides it to `<workspace>/emberbird-aosp`) |
| `JOBS` / `SYNC_JOBS` | `nproc` |

## What you should see, and what to check before trusting it

The script refuses to build if the runner lacks the disk or RAM, and — importantly —
**refuses to build if the synced tree does not match the committed X1 lock**, because a
build from an unlocked tree would be an X2 claim we could not substantiate. So a
successful run is itself evidence that the lock and the tree agree.

On pull-back:

1. Check `image/out/x2-provenance.json` exists and lists at least one artifact with a
   `sha256` and `bytes` — that record *is* X2.
2. **Verify the pulled artifacts against that record**, which is now a command rather
   than a promise:
   ```bash
   python3 tools/manifest/verify-x2-provenance.py
   ```
   It re-hashes every recorded artifact, checks the byte sizes, refuses any `.iso`/
   `.img` in `image/out/` that the record does *not* describe (a stale record beside a
   newer image), confirms `manifest_revision` equals the committed X1 pin, and confirms
   the record's own provenance anchor names the committed lock. Exit `0` verified,
   `1` rejected, `2` nothing pulled yet — and `2` is deliberately **not** a pass, so a
   green suite can never be read as "the image was verified" when no image exists.
   `tools/checks/run-offline-checks.sh` runs it as a check, so it is part of every run.
3. `Get-FileHash` is still worth doing by hand once, as an independent second opinion
   on a different machine:
   ```powershell
   Get-FileHash .\bliss_arcadia-x86.iso -Algorithm SHA256
   ```
4. Commit the record as `docs/evidence/M2/x2-artifact-provenance.json` and fill in the
   X2 row of the [execution appendix](M2-GUEST-BOOT-PROOF.md#8-execution-appendix-2026-09-24)
   with the observed values. Until that happens, **X2 stays OPEN** — the artifact is not
   the evidence; the recorded hash and provenance is.
5. Then execute X3–X5 on the Windows host:
   ```powershell
   .\tools\qemu\provision-host.ps1 -Check
   .\tools\qemu\launch-emberbird.ps1 -Image <path> -DryRun   # X3: resolved argv
   .\tools\qemu\launch-emberbird.ps1 -Image <path>           # X4: usable UI
   adb connect 127.0.0.1:58526                               # X5: liveness
   ```

## Executed 2026-09-24: what the run actually required

Everything here was learned by executing it, not by reading the docs.

**1. The client was unusable until patched around.** Every invocation of the bundled
Windows client re-downloaded a 28 MB update it could never apply, failed with `WinError
183`, and fell back after ~107 s — so `crave run` looked like a hang with no output. Root
cause, reproduction and fix: [CRAVE-CLIENT-UPDATE-LOOP.md](CRAVE-CLIENT-UPDATE-LOOP.md)
(`tools/crave/crave.sh`).

**2. `crave run` needs a local checkout of the project's source, not just a project id.**
`--projectID 36` from this repo still failed on `could not get project information`; the
same command from a `los20` checkout resolved project 36 immediately. Hence the ticket
checkout in the launcher.

**3. Platform availability is per project, and narrow.** Probe results for project 36:

| Platform | Instance | Result |
|---|---|---|
| `linux16` | `t2d-standard-16` | **accepted** — job queued |
| `linux32` | `e2-standard-32` | `Invalid platform for project` |
| `linux64` | `n1-standard-96` | `Invalid platform for project` |
| `linux-all` | `e2-standard-8` | `Invalid platform for project` |
| `linux-t2d-32` | `t2d-standard-32` | `Invalid platform for project` |
| `aosp-silver` | `t2d-standard-16` | `Cannot read properties of null (reading 'details')` |

**4. The build runs on the free queue; the wait is queue position, not a token gate.**
`crave list`'s `Tokens Per Second` column is each platform's **cost** (`build_tokens_per_second`),
not a balance — `aosp-silver` shows 16 because it *costs* 16 tokens/sec, and the `0`s are
the free tier. The launcher submits on `--platform linux16`, whose rate is 0, so it is on
that free queue and an empty wallet does not block it: `crave wallet transactions` returns
*No transactions found for this user*, and that is expected. Two free-queue jobs on
`linux16` — the probe (301688, since
stopped) and the build (301689) — both sat `queued`, with the log repeating `Waiting for build
job <id> to run`; that is a wait for a free build node, not a compute allocation. (Update:
301689 was cancelled — one account runs one job at a time — and the build relaunched on
project **LOS 22.1** as job **301767**, still queued on `linux16` in the free queue.) What the
repo cannot change: (a) free-queue position clears when a node frees up (the intended path, and
what the watcher waits on); (b) *paying* to skip the queue via `--platform aosp-silver` is
separately blocked here — submission returns `Cannot read properties of null (reading 'details')`
on projects 36 **and** 93, a wallet-not-linked precondition (wallet creation/linking is an admin
operation — contact Crave support). So the honest state is: **queued on free compute, waiting for
a node**, not "denied compute". Machine-level analysis: `~/.crave/CRAVE-COMPUTE-NOTES.md`.

**5. Nothing was built, so nothing is claimed.** No artifact, no hash, no boot. X2 remains
OPEN; when a job does run, `pull` brings back `x2-provenance.json` plus the image, the local
re-hash is compared against the record, and only then is the M2 appendix row filled in.

## Closed 2026-10-03: the audit now asks `repo` how to resolve, and the X2 claim is a checked claim

Three defects closed offline; **no job was submitted**, so this section changes no
record above and X2 stays OPEN.

**1. The audit was resolving tags in the wrong repository.** 872 of the lock's 1175
active projects pin `refs/tags/android-12.1.0_r22`, and an AOSP release tag is a
*different commit in every repository*. The audit resolved each distinct tag **once**,
in whichever project came first in lock order, and compared every other project sharing
that tag against that one SHA — so a tree that was entirely correct reported ~872
phantom drifts, and the audit could never pass its own post-re-sync re-audit. Every
project's pin is now resolved in **its own** checkout, with an explicit guard for a
lock entry that carries no `revision` at all.

**2. Now it corroborates against `repo`, but the LOCK is still the only yardstick.**
The witness `repo manifest -r` is generated before the audit and handed in — and it is
used to *corroborate*, never to decide. An earlier version of this section said the
opposite ("a tag pin can only be settled by the resolution `repo` itself performed", so
compare `HEAD` against repo's resolved commit). That was wrong, and job 303324 is what
proved it: see §2c. The `OK` line now reports the lock's own breakdown plus how much the
witness corroborated — `OK all 6 active projects on disk at their locked revisions (3 SHA
pins compared directly against the lock, 3 tag pins resolved in-project, repo manifest -r
corroborates 6/6)`. A disagreement between witness and lock is printed as a `note` line
(and to stderr, so it lands in the remote build log) that names both commits and ends
"the lock governs".

**2c. `repo manifest -r` can never be the reference answer — job 303324 (2026-10-03).**
Job **303324** (`6e09b54`) FAILED in **7m58s**, before compiling anything. The Crave node
was pre-seeded with **LOS 20**: `.repo/manifests` pointed at
`https://github.com/accupara/los20.git` instead of `https://github.com/BlissRoms-x86/manifest.git`,
and `resync.sh` failed to re-point it (`remote origin does not have refs/heads/master`)
yet still reported `All repositories synchronized successfully.`, so only the 137 genuinely
absent projects were synced and **1038 of 1175** lock paths were left at LOS 20 revisions.

The mandatory canonical gate caught it, which is the point of that gate existing:

```
[FAIL] 8 locked project(s) are absent from the synced tree: external/adt-infra, tools/adt/idea,
       tools/base, tools/build, tools/idea, tools/motodev, tools/studio/cloud, tools/swt
[FAIL] 190 SHA-pinned project(s) are not at their locked revision: art (lock d898a1fed5f5,
       tree aeeafbd45929), bionic (lock 145acec53cc3, tree e0aac7df6f58), ... cts
LOCK VERIFICATION FAILED (2 problem(s), verdict=witness-mismatch, exit=1)
FATAL: the synced tree does not match the committed X1 lock - stopping before the build
```

One screen **above** that, the revision audit on the *same witness file* printed:

```
OK all 1175 active projects on disk at their locked revisions (1175/1175 resolved via repo manifest -r)
```

It was agreeing with itself. `repo manifest -r` reports the revision each project is
**checked out at** — it is a reading of the tree, not of the lock — so comparing on-disk
`HEAD` against it compares disk with disk. The code even asserted the reason in a comment:
*"repo resolved this pin; its answer is the lock's answer, by construction."* That is
false, and it could not have failed on any tree. (`art` is the proof: the lock pins SHA
`d898a1fed5f5`, and the witness reported `aeeafbd45929` — a SHA pin echoed back as
anything other than itself would mean `-r` were printing the manifest rather than the tree.)

The audit now takes `want` from the lock and only from the lock: a 40-hex pin is compared
directly, a tag pin is resolved in the project that pins it, and a pin that resolves
nowhere is an unproven pin and fails closed. The witness is consulted only afterwards, to
count agreements, count disagreements, and report which lock paths the tree never
mentioned — a disagreement is surfaced, never allowed to rescue a project, because letting
it do that would just move the tautology one level down. Scenario 9 of
`test-revision-audit.sh` is the regression test, and against the pre-fix recipe it
reproduces 303324 in miniature: a drifted tree plus a witness that faithfully reports the
drift yields `OK all 6 active projects ... (6/6 resolved via repo manifest -r)`.

Lesson worth keeping separate from the code: **two checks that disagree are a bug in one
of them, and the one that is *structurally incapable* of failing is the suspect.** The
gate and the audit read the same witness and reached opposite verdicts, and the tie was
broken not by which was more thorough but by which could have been wrong.

**2b. The witness is re-resolved after the repair, not just before the first audit.**
The post-re-sync re-audit is the last gate before `lunch`/`make`, and it was still being
handed the witness generated *before* the repair — a yardstick describing the tree that
had just failed. Two ways that goes wrong, both on a job that already paid for the full
sync: a **false drift**, where the freshly-repaired tree disagrees with a stale value and
the build dies on the tree it just fixed; and a **missed drift**, where a pin that was
unresolvable the first time (a depth-1 tree simply does not hold the locked objects) fell
back to the weaker local lookup — even though the re-sync is exactly what brought those
objects in. `resolve_witness` now runs three times: before the first audit, after the
repair and before the re-audit, and again for the mandatory canonical check. On an
*optional* failure it **deletes** the witness rather than keeping it, because a witness
that could not be refreshed is worse than no witness — it costs precision to drop (every
project falls back to its own checkout, which names the same commit) and buys certainty
that no comparison uses a value from the wrong moment.

**3. The recipe now refuses, or names loudly, a workspace it cannot trust — before the
multi-hour sync rather than after it.** Job 302748 was a LOS 20 pre-seeded node: ~1000
of the 1175 lock paths already existed, at the *base project's* revisions, and the only
thing that noticed was a lunch preflight after the full sync. Two new preflight guards:

- **`inspect_seed`** runs before any sync and dies on a `.repo` that cannot be reused
  — no `.repo/manifests` git worktree, or a `.repo/manifest.xml` that is missing or does
  not parse. `repo init` over such a state builds a hybrid (our manifest URL driving
  someone else's project list) that nothing downstream could interpret. A **foreign
  base** — a `.repo` tracking a different manifest — is *reported*, not refused, because
  re-pointing a pre-seeded node is the supported path and is what 302748 relied on. It
  also counts how many lock paths already have a checkout (~1183 stat calls, seconds),
  so "this node is holding someone else's content" is a preflight line rather than a
  post-mortem. Set `REQUIRE_CLEAN_SEED=1` to refuse a foreign base instead.
- **`manifests_clean`** closes a *silent* provenance hole. `git checkout --detach` carries
  local modifications across when they don't conflict, so an already-dirty
  `.repo/manifests` reaches the pinned revision with the wrong content — and the
  recipe's existing guard is a `rev-parse HEAD` comparison, which **passes** in exactly
  that case, while the provenance record goes on to print
  `manifests checkout: 98a0a79…`. The worktree is now checked, not just HEAD. The
  recipe's own `emberbird-pinned.xml` is the one untracked file allowed.

**4. The provenance claim is now backed by a check.** `x2-provenance.json` records
`lock_confirmed_by: repo manifest -r, checked with tools/manifest/verify-lock.py`, and
until now *nothing checked it*: `verify-lock.py` only compared the committed lock against
the coverage and pin files, and the witness it was credited with was never read. It now
takes `--repo-manifest PATH` and actually verifies that witness — every lock path present
and nothing extra, every SHA pin matched exactly, and every tag pin resolved to a concrete
commit. It deliberately does **not** compare a resolved tag SHA against the lock's tag
string: the two come from different projects and are not comparable. The canonical step
regenerates the witness after any repair, so the gate describes the tree about to be built.

Offline coverage: 49 checks in `tools/manifest/test-verify-lock.py` (9 new ones for the
witness, including all four failure modes), and 14 scenarios in
`tools/checks/test-revision-audit.sh`. Notable ones: scenario 9 is the 303324 regression
(witness corroborates, never decides — proven to fail against the pre-fix recipe);
scenario 10 pins the *order* of the
refresh relative to the re-audit in the recipe source (that control flow needs `repo` to
run, and a future edit that moved the refresh back after the re-audit would still pass
`bash -n`); scenarios 12–13 drive `inspect_seed` and `manifests_clean` against synthetic
`.repo` trees, including the case that matters most — a *modified tracked file at the
correct HEAD*, which the recipe's previous `rev-parse HEAD` guard demonstrably would not
have caught. Every new scenario was confirmed to **fail** against the pre-fix recipe
(`EMBERBIRD_RECIPE=<old> bash tools/checks/test-revision-audit.sh`), so they are not
checks that merely pass on the thing they were written for. The suite runs green on a
real 1183-project lock with a synthetic witness, and **auto-detects** a sandbox that
refuses the revision-recording subcommand, falling back to the plumbing-backed
`tools/checks/git-shim.sh` — see `tools/checks/lib-fixtures.sh`. On an ordinary machine
the probe succeeds and nothing is installed, so a normal run has no wrapper on `PATH`
at all.

## Executed 2026-10-01: job 302857 ran and FAILED (the audit worked; a dirty worktree broke the repair)

Job **302857** (`4ea22c2`, project 36 / `linux16`) was submitted 2026-09-30 ~18:53Z, last
confirmed `queued` at 19:53Z, and found finished (FAILED) on 2026-10-01T10:47Z — so it
queued overnight in the same ~11–23h free-tier band as the prior jobs. It ran **7m14s**,
and the failure is a different, much more specific one: the **revision audit from the 302748 fix fired and scoped the repair
correctly**, and the forced re-sync then tripped over the Crave base image's own local
modifications. In order, the remote log shows:

- `resync.sh` again reported success without updating anything — the audit afterwards
  printed `MISMATCH 1063 (checkout content differs from the lock)`, i.e. 1063 of the 1175
  active projects were still on disk at LOS 20 revisions. The pre-seeded-tree trap is
  exactly as diagnosed after 302748; what changed is that one line turns it from a silent
  mixed tree into an explicit, scoped repair.
- The scoped repair tried `repo sync -l --force-sync <1063 paths>` (failed — expected on a
  depth-1 pre-seeded tree: the locked objects are not local) and then the targeted network
  sync of the **same 1063 paths** — never a full-tree sync.
- The network sync fetched for ~4m45s and then died on **one** project:

  ```
  error: Your local changes to the following files would be overwritten by checkout:
          clang-r450784d/bin/clang++.real
          clang-r450784d/bin/clang-14
  Please commit your changes or stash them before you switch branches.
  Aborting
  error: prebuilts/clang/host/linux-x86/: platform/prebuilts/clang/host/linux-x86 checkout 78f0ef650b213157b62c0cbf57034808eae3dca9
  FATAL: re-sync of the drifted projects failed (see above). ...
  ```

Root cause: `repo sync` applies a revision with `git read-tree -m -u`, which **refuses to
overwrite locally-modified tracked files**, and `--force-sync` forces the *git dir*, never
the *worktree*. The Crave base image ships `prebuilts/clang/host/linux-x86` with those two
clang binaries modified in place, so one dirty file failed an otherwise-working
1063-project re-sync.

Fix (this commit): before the forced sync the recipe now runs `sanitize_worktrees()` over
**every drifted path** — `git reset --hard` (discard tracked modifications) plus
`git clean -fd` (drop untracked files that would equally block the checkout). That is the
correct direction for a provenance build: the tree must equal the lock exactly, so nothing
outside the lock may survive into it. Paths without `.git` (missing checkouts — `repo sync`
materializes those from scratch) are skipped, not errors. Pinned offline by scenario 6 of
`tools/checks/test-revision-audit.sh` (dirty tracked file + untracked file + a no-`.git`
path, asserting the worktree is left pristine).

Confirmed while diagnosing (and worth not re-litigating): the committed lock's revisions
are **882 `refs/tags/*` + 301 40-hex SHAs, zero branch names**, so the audit's tag
resolution covers every pin kind that exists; and the audit's MISMATCH count agreeing with
repo's 1063-project sync list says the comparison is measuring exactly what the sync acts
on. Nothing was pulled (pull only runs on success), so there is still no image and no
`x2-provenance.json`, and **X2 stays OPEN**.

Resubmitted 2026-10-01 as job **303004**, pinned to `ded56c9` — this fix. Verified the
queued payload from `list --json` (`jobs_active[0].workspace.cmd` names the commit): the
plain-text `crave list` table can show a stale payload, so JSON is the check that counts.

### `status` was three lines that could not fail (fixed 2026-10-03)

Diagnosing 303324 meant asking the client what it thought, and the command meant to do
that had never worked:

```bash
( cd "$TICKET_DIR" && bash "$CRAVE_SHIM" list | sed -n '/Your jobs/,$p' | head -8
  bash "$CRAVE_SHIM" getlog 2>&1 | tail -25 )
```

Every part was wrong against the real client:

- **The table was always empty.** The client prints `Your active jobs:` and
  `Job History:` — never `Your jobs`. So the `sed` range matched nothing, and an empty
  table is indistinguishable from "nothing to report". When the client cannot resolve
  the account at all it prints *no* job table whatsoever, which is the state this
  machine is in right now.
- **`getlog` was not pinned.** `log`, `watch` and `pull` all pass `--jobID`; `status`
  did not, so the client resolved against the current directory's workspace and
  answered *"No running job found on this workspace"* — which reads exactly like a
  dead job.
- **It exited 0 no matter what.** Observed directly: three client errors on the wire,
  `echo $?` = 0. A status command that cannot fail converts *"I could not look"* into
  *"there is nothing wrong"*, which is the one confusion this runbook cannot afford.

It now pins `--projectID`/`--jobID` (refusing to run at all without a job id rather
than issuing an unpinned call), reads both real section headers, and judges each probe
on **both** its exit status and its text — necessary because the client prints
`Error: could not get matching git url at: C:/Users/<you>` on the same stream as its
data while still exiting 0. It distinguishes three things that used to look alike: the
job is in the active table, the job has left the queue, and *the client drew no table
at all*, in which case it says the state is **UNKNOWN** rather than guessing.

Verified live against job 303324 — it now fetches that job's pinned log and **exits 1**
with `client error: could not get matching git url` and the `UNKNOWN` state, where the
old version printed an empty table and exited 0. Pinned offline by
`tools/checks/test-crave-remote-build.sh` (15 assertions against a stub client that
records the argv it was called with), which is red against the previous version.

`run` is now the only subcommand that requires `origin/$branch` to be reachable, since
it is the only one that launches anything; refusing to report the status of a job that
already ran, because this checkout's origin is unreachable, is the wrong trade — and
scoping it is also what lets the offline suite drive the read-only commands without a
network.

## Executed 2026-10-03: job 303324 ran and FAILED (foreign-base seed, and an audit that could not fail)

Job **303324** (`6e09b54`, the merge of PR #6) FAILED in **7m58s**, before compiling.
The fail-closed behaviour worked: the canonical gate refused a tree that is not the lock,
so no wrong artifact was produced and no build time was wasted. What it exposed is
documented in **§2c** above — a foreign-base `.repo` that left 1038 of 1175 projects at
LOS 20 revisions, and a revision audit that compared the tree against a reading of itself
and so reported `OK all 1175 active projects ...` on the same file the gate rejected.
The audit now judges from the lock; scenario 9 in `test-revision-audit.sh` fails against
the pre-fix recipe. Still outstanding for the next submission: `inspect_seed` reports a
foreign base but does not refuse it by default, so this class of node is still discovered
by a ~8-minute job rather than by preflight.

## Executed 2026-09-30: job 302748 ran and FAILED (the pre-seeded-tree trap, now closed)

Job **302748** (`0fc8173`, the fix for the failure below) queued ~11h and FAILED in
**3m56s** — and this time the recipe caught it, in the preflight this repo added after
302572:

```
== preflight: the manifest-backed tree provides bliss_x86_64-userdebug
FATAL: the synced tree offers no product 'bliss_x86_64' for LUNCH_TARGET='bliss_x86_64-userdebug'
```

The failure is deeper than a wrong lunch target, and the runbook's own "sync is the
canonical provenance step" claim did not hold on this node:

- The Crave node's workspace is **pre-seeded with LOS 20**. Most of the 1175 active lock
  paths already existed on disk — but at **LOS 20's revisions**, not the lock's.
- `resync.sh` treats an existing checkout as done, so only genuinely-missing paths were
  fetched. The completeness check tested **directory existence only**, and `repo manifest
  -r` + `LOCK VERIFICATION PASSED` verified manifest-level agreement, not content. The
  recipe's log even showed the tell: `Syncing: 0% (0/137)` for the delta set.
- `verify-lock.py` was **file-level** (lock ↔ coverage ↔ pin agreement); it never inspected
  the node's disk. Net: roughly a thousand shared projects were on disk at the wrong
  revisions, and only the new lunch preflight noticed the tree was not ours. (It now also
  takes `--repo-manifest` and checks the build-side witness; see the 2026-10-03 entry.)

A third job (**302852**) was briefly submitted before the audit fix was committed. It
pinned `0fc8173` — the already-failed revision — because the fix existed only in the
local working tree, and the remote `git fetch`es its recipe commit from GitHub. It was
stopped within minutes; the lesson is a runbook rule: **commit and push the recipe fix
BEFORE `run`** — `run` pins `git HEAD`, and nothing uncommitted reaches the node.

Closed in the same session as this note: the recipe now runs a **revision audit** after
sync — every project's on-disk `HEAD` is compared against the lock (tag pins resolved to
commit SHAs via `^{commit}`), anything drifted or missing is re-synced with
`repo sync -l --force-sync <paths>`, and a second failing audit stops the build. The
audit's behaviour is pinned offline by `tools/checks/test-revision-audit.sh`
(clean / wrong-SHA / no-checkout / moved-tag / repair, against synthetic git repos).

Nothing was pulled (pull only runs on success), so there is still no image and no
`x2-provenance.json`, and **X2 stays OPEN**. A third submission is needed; the audit plus
the two prior failures mean the next run either builds or names a real, external fault.

## Executed 2026-09-30: job 302572 ran and FAILED (fixed, not resubmitted)

Job **302572** (`eade8aa`, project 36 / `linux16`) was submitted 2026-09-29T07:16Z and
**FAILED**. It is the first job that got past the queue, so the numbers below are real:

| stage | result |
| --- | --- |
| queue | ~23h (free tier, 0 tokens/sec) |
| node execution | 8m44s total |
| `repo sync` | all 1175 active manifest projects on disk; `repo sync has finished successfully` |
| X1 lock check | `LOCK VERIFICATION PASSED` (all structural + coverage cross-checks OK) |
| `lunch`/`make` | **died before compiling anything** |

The failure was one line of the recipe, and it was the recipe's fault, not the lock's:

```
tools/guest-build/build-from-manifest.sh: line 347: build/envsetup.sh: No such file or directory
Build Failed: returned 1
```

This lock is an Android-12-era Bliss x86 tree, so `build/` already holds `soong`,
`blueprint`, `bazel` and `pesto` as sibling projects; `platform_build` is pinned at
**`build/make`**, and that is where `envsetup.sh` lives. The recipe hardcoded the classic
`source build/envsetup.sh`. It now resolves the path from the committed lock first, then
probes `build/` and `build/make/`, and dies with an explicit message if none exists;
`tools/checks/test-build-recipe.py` pins that so the class of bug cannot come back.

Nothing was pulled: `pull` only runs on success, so there is no image and no
`x2-provenance.json`, and **X2 stays OPEN**. A resubmitted job is needed to actually
compile the guest — expect another ~23h queue before any build time at all.

Two things the job proved that are worth keeping: `bliss_x86_64-userdebug` really is
provided by the manifest-backed tree (`device/generic/x86_64` from BlissRoms-x86, pinned
at `e763b4e`, lists it in `COMMON_LUNCH_CHOICES` alongside `bliss_x86_64.mk` in
`PRODUCT_MAKEFILES`), and the manifest graph itself is trustworthy — the sync and the X1
lock check both passed on a real node. What failed was only the recipe's hardcoded
assumption about where that tree puts things.

So the recipe no longer keeps such assumptions private. Before it builds it now asserts,
against the committed lock, that the tree provides what it is about to ask for:

- the `envsetup.sh` path comes from the lock's `platform_build` path;
- the `device/` trees it scans for the product come from the lock, never a literal list;
- `LUNCH_TARGET`'s product must appear in some `AndroidProducts.mk`'s
  `PRODUCT_MAKEFILES`, and the exact `<product>-<variant>` pair is checked against
  `COMMON_LUNCH_CHOICES` — a mismatch dies in seconds with the paths it scanned,
  instead of after a queue and a full sync.

The `make` goal is deliberately not pre-checked: an unknown goal costs `make` about a
second to reject, which after the sync has already happened is the cheap failure.

A benign warning to ignore: repo prints `remote origin does not have refs/heads/master`
during sync (the `eb/` source checkout is fetched by SHA, not by branch). The sync
completes and the completeness check passes regardless.

## Honest limitations

- **Launched, not completed.** A Crave run needs your account, an API key and compute; the
  job is queued on the owner's account (see the execution section above) and X2 is recorded
  as OPEN rather than pretending otherwise.
- **Crave is a third-party service.** It sees the source it builds. Nothing secret lives
  in this repo; the proprietary ARM translators and GApps are explicitly never committed
  (see [../docs/LICENSING.md](LICENSING.md)), so there is nothing in the tree that
  should not be on a build host.
- **The frozen launcher is untouched** by this path. If a launcher change turns out to
  be needed to boot what we build, that is an M0-reopen decision for the owner, not an
  inline edit — record it as a finding and stop (M2 §4.3).
- **`repo sync` is the canonical provenance step**, and it now runs in both places: here
  on Crave, and in `guest-build.yml` on a big-disk runner. Both compare the synced tree
  against `image/manifest/arcadia-x86.pinned.xml` with `tools/manifest/verify-lock.py`,
  including `--repo-manifest` on the `repo manifest -r` witness.
- **The recipe's live path is still unrun.** `repo` and an AOSP tree are unavailable
  here, so `repo manifest -r` itself, the real `repo sync`, and the repair loop are
  exercised only through the functions extracted into `tools/checks/lib-audit.sh` and
  a stubbed resolved manifest. What is proven offline is the audit's decision logic, not
  that a real `repo` produces the XML the recipe expects of it.

## Related

- M2 execution spec + appendix: [`M2-GUEST-BOOT-PROOF.md`](M2-GUEST-BOOT-PROOF.md)
- X1 lock and its reproducibility proof: [`../image/manifest/README.md`](../image/manifest/README.md),
  [`evidence/M2/x1-lock-reproducibility.txt`](evidence/M2/x1-lock-reproducibility.txt)
- Why no prebuilt: [`evidence/M2/x2-artifact-availability.txt`](evidence/M2/x2-artifact-availability.txt)
- Alternative runner: [`.github/workflows/guest-build.yml`](../.github/workflows/guest-build.yml)
