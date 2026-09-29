# EmberbirdOS — M2: Guest Boot Proof (execution spec)

> **Status: AUTHORIZED — IN EXECUTION (`2026-09-24`).** The owner accepted M1 ([`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md) §12), which unblocked §4 below. **X1 is complete and verified. X2's remote build is launched but queued on compute (job `301689`); X3–X5 are open** and additionally depend on a QEMU+OVMF-provisioned Windows host. **No guest has been built and no VM has booted yet.** Observed values, blockers and mitigations are recorded in the **[execution appendix (§8)](#8-execution-appendix-2026-09-24)** — this document still claims no result it has not captured as evidence.

Companion to [`../PLAN.md`](../PLAN.md) §8/§13, the M1 gate ([`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md)), and the guest pin ([`../image/manifest/README.md`](../image/manifest/README.md)). The independent M1 architectural review (`2026-09-23`) recommended that the milestone after owner acceptance be exactly this — a tightly-scoped boot proof, **not** another research/architecture exercise.

## 0. Gate posture — what this document is and is not

- **IS:** the tightly-scoped, evidence-first execution plan that the M1 gate unblocks. Every step below produces a durable, reproducible artifact.
- **IS NOT:** more research; a graphics or performance milestone (that is M3, `GRFX-GATE-01`); a runtime feature milestone (networking/windows/ARM come later).
- **Authorization to execute:** the owner's explicit acceptance of M1 — **given `2026-09-24`.** ("Reviewed PASS" was a *recommendation*, not the gate.)
- **What that authorization permits:** exactly the steps in §4, in order, each producing durable evidence. It does **not** authorize `host/`/`guest/` runtime code, which stays behind the later spine gates.

## 1. Objective (single, falsifiable claim)

Prove that the **pinned** BlissOS `arcadia-x86` guest (manifest repo revision `98a0a79cfffbb2cb9eb43dbaf5575a0195162bcf` / `98a0a79`) boots under the **frozen M0 launcher** on WHPX to a **usable Android 13 (API 33) UI**, with ADB reachable — capturing exact, reproducible evidence. **Software-rendering baseline only**; no acceleration and no performance claims.

## 2. Preconditions (all must hold before §4.1 runs)

- **P1 — M1 owner acceptance recorded** (the gate). ✅ **SATISFIED `2026-09-24`.** Without it, stop here — with it, §4 runs.
- **P2 — Frozen M0 launcher** ([`../tools/qemu/launch-emberbird.ps1`](../tools/qemu/launch-emberbird.ps1)); its 17-assertion suite (`../tools/qemu/tests/Test-Launcher.ps1`) green. The launcher is **not** modified during M2 (see §4.3).
- **P3 — Host:** Windows 11 + Windows Hypervisor Platform; QEMU-for-Windows; OVMF; adequate disk/RAM for a full `repo sync` + build (tens of GB) if building from source.
- **P4 — WSL2 coexistence** confirmed via `launch-emberbird.ps1 -Check` (no Hyper-V conflict).
- **P5 — Isolated/expendable host** acknowledged for `HYPERV-SEC-01` (anti-cheat interaction; [`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md) §10). WHPX is never toggled silently.

## 3. Exit criteria (the evidence that closes M2)

| # | Criterion | Evidence artifact |
|---|---|---|
| **X1** | Per-project manifest lock resolved and recorded | `image/manifest/arcadia-x86.pinned.xml` (from `repo manifest -r`), committed at execution time |
| **X2** | Guest artifact provenance | artifact path + **SHA-256** + size + build host/toolchain (or, prebuilt path: download URL + SHA-256 + build provenance) |
| **X3** | Exact boot recipe | launcher invocation **and** the resolved QEMU argv (captured via `-DryRun`) |
| **X4** | Usable UI reached | screenshot/console at the Android launcher/home; `adb shell getprop sys.boot_completed` == `1` |
| **X5** | ADB liveness | `adb connect 127.0.0.1:58526` → `adb devices` shows the guest; `ro.build.version.release` == `13`, `ro.build.version.sdk` == `33` |
| **X6** | Failure/recovery honesty | every non-fatal error encountered + the mitigation applied, re-tested and reproducible |
| **X7** | No overclaim | graphics is software `virtio-gpu-pci` / SwiftShader baseline — GPU acceleration (gfxstream/rutabaga) is **explicitly deferred to M3 under `GRFX-GATE-01`**; no fps/perf numbers asserted |

Each criterion lands as a file under `docs/evidence/M2/` plus an execution-time appendix appended to this doc recording the **observed** values.

## 4. Execution plan (ordered — P1 satisfied `2026-09-24`; statuses in §8)

### 4.1 Resolve & record the per-project manifest lock

The M1 pin fixed the manifest **repository** revision (`98a0a79`); the per-component SHA lock was, by design, deferred to build time ([`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md) §12, criterion #1 scope note). This step produces it:

```
repo init -u https://github.com/BlissRoms-x86/manifest.git -b arcadia-x86   # resolves to 98a0a79cfffbb2cb9eb43dbaf5575a0195162bcf
repo sync -c -j<N>
repo manifest -r -o arcadia-x86.pinned.xml                                  # full per-project revision lock
```

Commit `arcadia-x86.pinned.xml` under `image/manifest/` alongside the existing pin. Record the `repo` tool version and the resolution date. **Alternative (usability path):** if instead acquiring a signed prebuilt derived from the same manifest, record its exact download URL + SHA-256 + build provenance; the from-manifest lock remains the provenance anchor.

### 4.2 Acquire or build the guest artifact

Build the `arcadia-x86` target from the locked manifest, **or** acquire the pinned prebuilt. Record artifact path, **SHA-256**, size, and build host/toolchain (or download provenance) → **X2**.

### 4.3 Boot via the frozen M0 launcher

```powershell
.\tools\qemu\launch-emberbird.ps1 -Check                 # host preflight, no VM started
.\tools\qemu\launch-emberbird.ps1 -Image <path> -DryRun  # capture resolved QEMU argv, no VM started  → X3
.\tools\qemu\launch-emberbird.ps1 -Image <path>          # boot
```

**Do not modify the launcher.** If a launcher change proves necessary to boot, that is an **M0-reopen decision for the owner**, not an inline edit — record the needed change as a finding and stop.

### 4.4 Capture usable-UI + ADB evidence

- Screenshot/console at the Android launcher/home → **X4**.
- `adb connect 127.0.0.1:58526; adb devices; adb shell getprop sys.boot_completed; adb shell getprop ro.build.version.release; adb shell getprop ro.build.version.sdk` → **X4/X5**.

### 4.5 Failure & recovery evidence

- **Expected pinned-BlissOS path:** boots under `-accel whpx` with `-cpu host`/`max`.
- **If the Plan-B AOSP GSI is used instead:** document the signal-6 / FirstStageMount symptom and the AGP boot-layer + `-cpu host` mitigation ([`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md) §2).
- Log each error → mitigation → re-test, reproducibly → **X6**.

## 5. Evidence artifacts (where they land at execution time)

- `image/manifest/arcadia-x86.pinned.xml` — the per-project revision lock (**X1**) — complete, plus [`evidence/M2/x1-lock-reproducibility.txt`](evidence/M2/x1-lock-reproducibility.txt).
- `docs/evidence/M2/x2-artifact-provenance.json` — the **X2** record emitted by the remote build ([`M2-CRAVE-BUILD.md`](M2-CRAVE-BUILD.md) §"What you should see").
- `docs/evidence/M2/` — boot command + resolved argv, screenshots, `adb`/`getprop` transcripts, failure/recovery log, artifact hashes (**X2–X6**).
- An execution-time appendix appended to **this** file summarizing X1–X7 with observed values.

## 6. Explicit non-goals (deferred by design — not weakened)

- **GPU acceleration / gfxstream / rutabaga → M3** (`GRFX-GATE-01`); M2 is the software baseline only.
- **Per-app native Windows windows (RDP-RAIL) → M5** (the G3 WSA-parity deliverable).
- **Networking / ADB control plane (`emberbirdctl`)** beyond a bare `adb devices` liveness check → feature-M1.
- **ARM app support → M7** (optional layer, OPEN RISK — [`REPO-MAP.md`](REPO-MAP.md)).
- **GMS / Play certification** → structurally gapped in a VM ([`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md) §6); out of M2 scope.
- **No performance/fps numbers** are claimed by M2.

## 7. Boundaries honored while authoring this spec

*(Historical: this section records the state in which the spec was written, before sign-off. Execution began `2026-09-24` — see §8.)*

- No `repo sync`, no guest build, and no VM boot were performed to write this document.
- No commit or push was performed.
- Execution of §4 was gated on the owner's **explicit** M1 acceptance; this spec did not itself authorize it.

<a id="8-execution-appendix-2026-09-24"></a>

## 8. Execution appendix (`2026-09-24`)

Observed values for X1–X7 at the close of this execution pass. Host: `DESKTOP-C993H9Q`, Windows 11 Pro 10.0.26300, 237 GB drive with **~104 GB free**, Python 3.14.7, git 2.55.0.windows.5.

| # | Criterion | Status | Observed |
|---|---|---|---|
| **X1** | Per-project manifest lock resolved and recorded | ✅ **COMPLETE** | [`../image/manifest/arcadia-x86.pinned.xml`](../image/manifest/arcadia-x86.pinned.xml) — **1183 projects, 0 unresolved** (882 locked by AOSP tag, 4 by SHA, 297 moving refs resolved to SHAs). Coverage: [`../image/manifest/lock-coverage.json`](../image/manifest/lock-coverage.json). **Re-derivation is byte-identical** to the committed lock — [`evidence/M2/x1-lock-reproducibility.txt`](evidence/M2/x1-lock-reproducibility.txt). |
| **X2** | Guest artifact provenance (path + SHA-256 + size + build host, or URL + SHA-256 + provenance) | ⏳ **LAUNCHED — QUEUED (compute-gated)** | The remote build now exists as a real job: **301689**, project `LOS 20` (id 36), platform `linux16`, <https://foss.crave.io/app/#/build/info/301689?team=14>, launched pinned to commit `609ad8b`. It has not run — 14 minutes of sampling show `queued` and `getlog` repeating `Waiting for build job 301689 to run`. Cause, from the account itself: `crave list` reports **`Tokens Per Second` = 0 on `linux16`** (0 on every platform except `aosp-silver`, which shows 16 and whose submission fails with `Cannot read properties of null`), and `crave wallet transactions` returns *No transactions found for this user*. **So the blocker moved from "no runner exists" to "the runner is allocated no compute"** — an owner-side action, and still not a result: no artifact, no SHA-256, no pull. Full transcript: [`evidence/M2/x2-remote-build-launch.txt`](evidence/M2/x2-remote-build-launch.txt). The prebuilt alternative remains *unavailable* (official channel paused, only mirror Android-11-era), so X2 still converges on a build from the lock — remote via [`M2-CRAVE-BUILD.md`](M2-CRAVE-BUILD.md) / [`../tools/crave/run-remote-build.sh`](../tools/crave/run-remote-build.sh), or on a big-disk runner via [`.github/workflows/guest-build.yml`](../.github/workflows/guest-build.yml). Both execute the one recipe [`../tools/guest-build/build-from-manifest.sh`](../tools/guest-build/build-from-manifest.sh), which re-confirms the X1 lock before building. |
| **X3** | Exact boot recipe (launcher invocation + resolved QEMU argv via `-DryRun`) | ⛔ **BLOCKED** | The frozen launcher resolves no argv on this host: `qemu-system-x86_64.exe not found` ([`evidence/M2/launcher-dryrun.txt`](evidence/M2/launcher-dryrun.txt)). QEMU/OVMF are absent ([`evidence/M2/env-probe.txt`](evidence/M2/env-probe.txt)). Unblocked by [`../tools/qemu/provision-host.ps1`](../tools/qemu/provision-host.ps1) `-InstallQemu`; **the launcher itself stays unmodified** (§4.3). |
| **X4** | Usable UI reached (screenshot/console + `sys.boot_completed==1`) | ⬜ **OPEN** | Requires X2 + X3. No VM was booted. |
| **X5** | ADB liveness (`adb devices`; `ro.build.version.release==13`, `sdk==33`) | ⬜ **OPEN** | Requires X4. Host prerequisite improved since the original probe: `adb` is now present at `C:\Users\BangerSoul\bin\adb.exe`. |
| **X6** | Failure/recovery honesty | ✅ **RECORDED (open-ended)** | See the log below. |
| **X7** | No overclaim | ✅ **HONORED** | Software `virtio-gpu-pci` / SwiftShader baseline only; no fps or performance number is asserted anywhere. GPU acceleration remains M3 / `GRFX-GATE-01`. |

### Observation the lock surfaced — what fixes the platform version (bears on X5)

Reading the lock explains where the "Android 13 / API 33" expectation actually comes from, and it is worth recording because X5 asserts it rather than assumes it:

| What | Count | Evidence |
|---|---|---|
| Projects locked to the manifest's **inherited default** `refs/tags/android-12.1.0_r22` (**Android 12L / API 32**) | **881** | [`../image/manifest/arcadia-x86.pinned.xml`](../image/manifest/arcadia-x86.pinned.xml) |
| Projects locked to other AOSP tags (`android-13.0.0_r30`, `android-11.0.0_r45`) | 2 | same |
| Projects resolved to a SHA from a moving Bliss/x86/Lineage branch | 297 | [`../image/manifest/lock-coverage.json`](../image/manifest/lock-coverage.json) |

So the AOSP half of this manifest is pinned at **12L**, not Android 13 — and the captured [`version_defaults.mk`](evidence/M2/version_defaults.mk) corroborates it: `DEFAULT_PLATFORM_VERSION := SP2A`, `PLATFORM_VERSION_LAST_STABLE := 12`. The Android 13 / API 33 claim in §1 therefore rests on the **Bliss `arcadia-x86` forks**, which is where the platform core actually comes from:

    frameworks/base  -> BR-x86 (Bliss fork)  e0a62bf398242975cb53a60a9547d39cee755d99
    frameworks/native-> BR-x86 (Bliss fork)  ddcaaaf69a6e86e1c18346ee966b73b60bdb76e3
    system/core      -> BR-x86 (Bliss fork)  e50022c6676a0252555b6cd885130569eeda3bf6
    build/make       -> BR-x86 (Bliss fork)  bfd317008f76fe16d0ca53804e42cd5710ced7e6

**Consequence for M2:** this is consistent with the M1 decision (the value of Bliss `arcadia-x86` is precisely its forked platform core plus its PC boot layer, not a stock GSI), and it is *why* a plain AOSP GSI is Plan-B rather than the default. It also means X5's `ro.build.version.release`/`sdk` values must be **measured, not assumed** — the version is determined by Bliss's `build/make`, not by the 881 12L-tagged upstream projects. No claim is made here about which value will be observed; X5 remains open until it is captured.

### X6 — failures encountered, mitigations applied

1. **`tools/manifest/resolve-manifest-lock.py` source was missing** while its outputs (`arcadia-x86.pinned.xml`, `lock-coverage.json`, `.lock-checkpoint.json`) were committed and the lock's own header named the script. *Mitigation:* the tool was restored from its recovered bytecode interface (function/constant structure recovered from `tools/manifest/__pycache__/resolve-manifest-lock.cpython-314.pyc`) and then **proved faithful** — a fresh re-resolution reproduces the committed lock byte-for-byte. *Re-test:* `python tools/manifest/verify-lock.py --live` → PASS (exit 0). The exit code is the result: `0` pass, `1` the lock does not match (structural failure or drift), `2` the re-resolution could not finish (unresolved refs). `2` outranks `1` deliberately, so a partially-resolved run is never published as a stale lock. The contract is pinned by `python tools/manifest/test-verify-lock.py`, which runs offline in the blocking `manifest-lock` job.
2. **`tools/qemu/provision-host.ps1` was referenced by `evidence/M2/env-probe.txt` but absent.** *Mitigation:* authored as the single host-provisioning/readiness entry point (`-Check` default, `-InstallQemu`, `-FetchPlatformTools`, `-EvidencePath`), and exercised in CI so it cannot rot.
3. **Lock-vs-coverage cross-check initially reported 24 false disagreements.** Cause: it keyed on project *name*, which is **not unique** in this manifest (the same component name appears for several paths/remotes). *Mitigation:* keyed on the unique `path`; 1183/1183 now agree. This is recorded because the same trap applies to any future tooling over this manifest.
4. **Coverage `resolved_ref` differs cosmetically for 8 of 1183 projects** (bare branch name vs `refs/heads/…`; identical SHAs). Cause: the committed `.lock-checkpoint.json` is **mixed-history** — 14 of its 297 entries hold bare refs, 283 hold full refs — and the report inherited whichever it held. *Mitigation:* documented rather than "fixed", because rewriting committed evidence to match a re-run would obscure the real history; the SHAs, revisions and the lock itself are unaffected.
5. **Disk.** ~104 GB free against a ~300+ GB requirement. *Mitigation:* the build path is CI-side; the local machine is used for provenance/verification work only.
6. **The Crave Windows client was unusable: a self-update loop that never converges.** Every invocation re-downloaded a 28 MB update it could not apply, failed with `[WinError 183] Cannot create a file when that file already exists` on `%TEMP%\crave-0.2-7220.zip_unverified` -> `crave-0.2-7220.zip`, then fell back — **107 s and 2 x 28 MB per call, with no output while it did it**, which presented as a hang. Cause (two upstream defects): release `0.2-7220` ships a payload that reports itself as `0.2-7214-HEAD`, so the extracted payload re-downloads the release it came from; and that second download renames over a file that already exists. *Mitigation:* [`../tools/crave/crave.sh`](../tools/crave/crave.sh) always passes the client's documented global `-n`/`--noUpdate` and clears the stale staging payload first; the client is now instant. Analysis: [`CRAVE-CLIENT-UPDATE-LOOP.md`](CRAVE-CLIENT-UPDATE-LOOP.md).
7. **`crave run` cannot resolve a project from this repository.** `Error: could not get project information for <this repo>` — with or without `--projectID 36`, and with `crave.yaml` present. Crave resolves the project from the **git URL of the current directory**, and this repo is not (and need not be) a Crave project. *Mitigation:* the job is launched from a throwaway *ticket* checkout whose origin is the base project's URL (`tools/crave/run-remote-build.sh`), which bootstraps this repo inside the remote workspace at the pinned commit. The base project is a container only; provenance stays anchored to the X1 lock.
8. **Platform choice is per project and narrow.** Project 36 accepts `linux16`, `linux4` and `bain-debug`, and rejects `linux32`, `linux64`, `linux-all`, `linux-t2d-32` and `devspace` with `Invalid platform for project`; `aosp-silver` fails client-side. Recorded so nobody re-probes it: [`evidence/M2/x2-remote-build-launch.txt`](evidence/M2/x2-remote-build-launch.txt) §3.

### Blocking item for the next pass

**X2 → X3 → X4 → X5 cannot complete without two host/runner actions that are the owner's to make:**

1. **Get the queued build compute (was: execute the remote build).** This is now a narrower ask than it was: the remote build *is* launched — job **301689** on `linux16`, pinned to `609ad8b` — and the client, project resolution and platform selection are all solved and committed. What it is waiting for is an allocation: this account shows **0 tokens/sec on `linux16`** and an empty wallet, so the job sits in `queued` (`evidence/M2/x2-remote-build-launch.txt` §§4-5). Granting compute — accruing/adding tokens, or funding a different accepted platform — is the owner's call and cannot be done from the repository. Once the job runs: `bash tools/crave/run-remote-build.sh status` → `... pull`. The prebuilt shortcut remains unavailable ([`evidence/M2/x2-artifact-availability.txt`](evidence/M2/x2-artifact-availability.txt)), and a possibly cheaper alternative exists in [`.github/workflows/guest-build.yml`](../.github/workflows/guest-build.yml) `mode=build-from-manifest` if a 300+ GB runner is available instead of Crave compute.
2. **QEMU + OVMF on this Windows host**, to execute X3–X5 (`provision-host.ps1 -InstallQemu`; UAC prompt is the operator's call). Until then, X3 is blocked exactly as `evidence/M2/launcher-dryrun.txt` records, and no boot claim is made.

## Related

- Plan: [`../PLAN.md`](../PLAN.md) §8 (roadmap) / §13 (next actions).
- M1 gate: [`M1-RUNTIME-ARCHITECTURE.md`](M1-RUNTIME-ARCHITECTURE.md) — §2 (guest/kernel), §4 (`GRFX-GATE-01`), §12 (exit criteria).
- Guest pin: [`../image/manifest/arcadia-x86.pin.json`](../image/manifest/arcadia-x86.pin.json) + [`../image/manifest/README.md`](../image/manifest/README.md).
- Evidence base: [`RESEARCH-SYNTHESIS.md`](RESEARCH-SYNTHESIS.md); input verdicts: [`REPO-MAP.md`](REPO-MAP.md).

---

*M2 Guest Boot Proof — execution spec, now executing. M1 was accepted by the owner on `2026-09-24`; §4 is running in the order given, and every claim above is backed by an artifact under [`evidence/M2/`](evidence/M2/) or is explicitly marked OPEN/BLOCKED. No guest has been built and no VM has booted.*
