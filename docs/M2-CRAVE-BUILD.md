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
| `repo manifest -r`, checked against the committed X1 lock | Crave machine | [`image/out/repo-manifest-r.xml`](../image/out) (git-ignored) |
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
2. Re-hash the downloaded image locally and confirm it matches:
   ```powershell
   Get-FileHash .\bliss_arcadia-x86.iso -Algorithm SHA256
   ```
3. Commit the record as `docs/evidence/M2/x2-artifact-provenance.json` and fill in the
   X2 row of the [execution appendix](M2-GUEST-BOOT-PROOF.md#8-execution-appendix-2026-09-24)
   with the observed values. Until that happens, **X2 stays OPEN** — the artifact is not
   the evidence; the recorded hash and provenance is.
4. Then execute X3–X5 on the Windows host:
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
  against `image/manifest/arcadia-x86.pinned.xml` with `tools/manifest/verify-lock.py`.

## Related

- M2 execution spec + appendix: [`M2-GUEST-BOOT-PROOF.md`](M2-GUEST-BOOT-PROOF.md)
- X1 lock and its reproducibility proof: [`../image/manifest/README.md`](../image/manifest/README.md),
  [`evidence/M2/x1-lock-reproducibility.txt`](evidence/M2/x1-lock-reproducibility.txt)
- Why no prebuilt: [`evidence/M2/x2-artifact-availability.txt`](evidence/M2/x2-artifact-availability.txt)
- Alternative runner: [`.github/workflows/guest-build.yml`](../.github/workflows/guest-build.yml)
