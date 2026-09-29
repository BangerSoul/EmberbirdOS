# Guest-base manifest pin — `arcadia-x86`

Human-readable companion to [`arcadia-x86.pin.json`](arcadia-x86.pin.json), the machine-readable pin record. This directory is the **guest-image provenance anchor** for EmberbirdOS's v1 Android guest, and satisfies exit-criterion #1 of the M1 gate (*"a specific `arcadia-x86` manifest SHA is recorded in `image/manifest/`"* — see [`../../docs/M1-RUNTIME-ARCHITECTURE.md`](../../docs/M1-RUNTIME-ARCHITECTURE.md) §12).

## What is pinned

| Field | Value |
|---|---|
| Guest base | BlissOS **`arcadia-x86`** (Bliss OS 16.x → Android 13 / API 33) |
| Manifest repo | `https://github.com/BlissRoms-x86/manifest.git` |
| Branch | `arcadia-x86` (also the repo default `HEAD`) |
| **Revision (SHA)** | **`98a0a79cfffbb2cb9eb43dbaf5575a0195162bcf`** (`98a0a79`) |
| Commit date (UTC) | `2026-04-12T16:56:54Z` |
| Commit author | `hmtheboy154` |
| Commit subject | `x86: Update media-driver to 25.4` |

## How it was resolved (2026-09-23)

Two independent read-only network queries, no clone and no build:

1. `git ls-remote https://github.com/BlissRoms-x86/manifest.git` — confirmed `refs/heads/arcadia-x86` == repo `HEAD` == `98a0a79…` (so `arcadia-x86` is both the active *and* default branch).
2. GitHub commits API `/repos/BlissRoms-x86/manifest/commits/98a0a79…` — confirmed the committer date and subject above.

## Scope — read this before trusting the pin

- **This pins the manifest-*repository* revision only.** The default manifest at `98a0a79` still references most of its ~237 component projects by **branch/tag**, not by SHA. So this anchor fixes *which manifest* we build from, not the exact commit of every component inside it.
- **The fully-resolved, per-project revision lock is the sibling artifact** — see [`arcadia-x86.pinned.xml`](arcadia-x86.pinned.xml) below.
- **No Android image was built and no VM was created** to produce this pin. It is a provenance record, nothing more.

## The per-project lock — `arcadia-x86.pinned.xml` (M2 X1)

The lock resolves the branch/tag gap above: **every one of the 1183 projects carries an immutable revision** (a 40-hex SHA, or an AOSP `refs/tags/*` release tag) — the equivalent of `repo manifest -r`.

| Field | Value |
|---|---|
| Lock | [`arcadia-x86.pinned.xml`](arcadia-x86.pinned.xml) — 1183 projects, **0 unresolved** |
| Resolution report | [`lock-coverage.json`](lock-coverage.json) — 882 locked by AOSP tag, 4 by SHA, **297 moving refs resolved to SHAs** |
| Resumable cache | [`.lock-checkpoint.json`](.lock-checkpoint.json) — the committed record of how each ref resolved; reused (and rewritten) by later runs so a re-lock repeats no network work |
| Generator | [`../../tools/manifest/resolve-manifest-lock.py`](../../tools/manifest/resolve-manifest-lock.py) |
| Verifier | [`../../tools/manifest/verify-lock.py`](../../tools/manifest/verify-lock.py) |
| Verifier regression test | [`../../tools/manifest/test-verify-lock.py`](../../tools/manifest/test-verify-lock.py) — offline, no network, run by the blocking `manifest-lock` job |
| Evidence | [`../../docs/evidence/M2/x1-lock-reproducibility.txt`](../../docs/evidence/M2/x1-lock-reproducibility.txt) |

**How it was produced — and why it isn't a `repo sync`.** The lock was resolved **over the network only** (`git ls-remote` per moving ref, cached and resumable): the 886 tag/SHA-pinned projects were already immutable, and the 297 branch-tracking forks were resolved to SHAs. This produces the same lock without the multi-GB source sync, which is exactly what the M2 host could not accommodate (~104 GB free vs ~300+ GB needed).

**It is verified, not merely claimed.** Re-running the generator against the pinned upstream reproduces the committed lock **byte-for-byte**, and `tools/manifest/verify-lock.py --live` re-derives every moving ref from scratch and requires both (a) every SHA to match the committed lock and (b) the regenerated file to be byte-identical.

CI splits the two by what the signal means ([`../../.github/workflows/verify-provenance.yml`](../../.github/workflows/verify-provenance.yml)):

| Check | Runs | Enforced | What a red result means |
|---|---|---|---|
| `manifest-lock` — captured-manifest hashes + offline structural verification + the verifier's own exit-code regression test | every push / PR | **blocking** | someone edited the captured manifests or the lock. A real integrity failure. |
| `lock-reproducibility` — `--live` re-resolution | nightly + manual dispatch | **advisory** | upstream branches moved since the lock was cut. Expected over time. |

**The advisory job reads an exit code, not a log line.** `verify-lock.py` exits `0` (all checks passed), `1` (the lock does not match — a structural failure, live drift, or a lock that does not re-derive byte-for-byte) or `2` (the live re-resolution could not finish: one or more refs came back unresolved). Anything else is reported as unclassified rather than guessed at. **`2` deliberately outranks `1`**: a partially-resolved run cannot support a drift claim, so a network flake can never be published as "your lock is stale" — and an unresolved ref is excluded from the drift list rather than falling back to its moving branch name and manufacturing a phantom entry. The full finding set is written to a findings report (`--findings-file PATH`) that CI renders whole, so nothing is cut off mid-diff. The contract is pinned by [`../../tools/manifest/test-verify-lock.py`](../../tools/manifest/test-verify-lock.py), which runs offline in the blocking job.

The live check is deliberately not a required check: the ~297 refs it re-resolves are `upstream="main"` branches that Bliss/LineageOS advance continuously, so it would otherwise go red on its own and block every contributor until the lock was re-cut. **Drift is not a build risk** — `build-from-manifest.sh` installs the frozen lock as repo's active manifest and syncs the immutable SHAs, so an upstream move changes nothing about what gets built. Re-cutting remains an owner's decision because it moves the M2 X2 provenance anchor.

**The canonical build-time confirmation remains `repo sync && repo manifest -r`**, which is run inside [`../../.github/workflows/guest-build.yml`](../../.github/workflows/guest-build.yml) and checked against this lock before the guest is built. The network-only resolver is the provenance anchor; the sync-side lock is the build-side witness.

**Known, documented variance:** 8 of the 1183 projects record `resolved_ref` in the coverage report as a bare branch name rather than `refs/heads/…` (identical SHAs), because the committed cache is mixed-history. See item 4 of the M2 execution appendix.

## Plan-B (documented, not adopted)

The AOSP `aosp_x86_64` GSI (Android 16) is the clean-license rebase target, tracked in the M6 band. It is a **bring-up build effort, not a drop-in image** — a plain GSI hits signal-6 / FirstStageMount in vanilla QEMU and needs the AGP boot layer plus `-cpu host`. See [`../../docs/M1-RUNTIME-ARCHITECTURE.md`](../../docs/M1-RUNTIME-ARCHITECTURE.md) §2.

## Related

- Machine-readable record: [`arcadia-x86.pin.json`](arcadia-x86.pin.json)
- Guest-base + kernel decisions: [`../../docs/M1-RUNTIME-ARCHITECTURE.md`](../../docs/M1-RUNTIME-ARCHITECTURE.md) §2–§3
- Guest patches (against this manifest revision) live at `../patches/`
- Delivery roadmap: [`../../PLAN.md`](../../PLAN.md)
