#!/usr/bin/env bash
# EmberbirdOS - Crave client shim (fixes the self-update loop).
#
# WHY THIS EXISTS
#   The Crave Windows client tries to self-update on EVERY invocation, and the update
#   cannot converge on the version installed here. A plain `crave <cmd>` therefore
#   spends ~107 s and downloads 2 x 28 MB before it runs anything, then prints:
#
#     Downloading update .../0.2-7220/crave-windows-0.2-7220-Windows.zip
#     Extracting zip: C:\Users\<you>\.crave\bin\0.2-7220
#     Downloading update .../0.2-7220/crave-windows-0.2-7220-Windows.zip   <-- again
#     Error: Generic failure: [WinError 183] Cannot create a file when that file
#       already exists: '...\Temp\crave-0.2-7220.zip_unverified' -> '...\Temp\crave-0.2-7220.zip'
#     Deleting the zip file so that it is re-downloaded the next time around
#     Download failed continuing to use current crave
#
#   Two upstream defects combine: (1) release 0.2-7220 ships a binary that reports
#   itself as 0.2-7214-HEAD, so the extracted payload immediately re-downloads the
#   release it came from, and (2) that second download renames over a file that already
#   exists, which Windows rejects with WinError 183. Full evidence and the reproduction
#   are in docs/CRAVE-CLIENT-UPDATE-LOOP.md.
#
# HOW THIS FIXES IT
#   `-n` / `--noUpdate` is the client's own documented global switch for skipping the
#   update check, and it is exactly what AGENTS.md prescribes. This shim makes that the
#   default so nobody has to remember, and first removes the stale half-downloaded
#   payload in %TEMP% that makes the update step fail with WinError 183.
#
# Usage (the -n is implicit; any other crave arguments pass straight through):
#   bash tools/crave/crave.sh list
#   bash tools/crave/crave.sh run --projectID 36 --platform linux16 --no-patch --detached \
#     -- "<remote command>"
#   bash tools/crave/crave.sh pull eb/image/out/
#
# Do NOT hand-roll a `crave run` for this repository. The client resolves the project from
# the git URL of the current directory, and this repo's URL is not a Crave project, so a
# run from here fails with "could not get project information". `run-remote-build.sh` is the
# supported entry point: it launches from a ticket checkout whose origin is the base
# project's URL, merges crave.yaml into it, pins the exact commit, and enforces Crave's
# one-build-per-account rule. Platform is not a free choice either - project 36 accepts
# linux16 and rejects linux32/linux64/linux-all/linux-t2d-32 with "Invalid platform for
# project" (probe matrix: docs/M2-CRAVE-BUILD.md).
#
# Env: CRAVE_BIN overrides the client path.

set -euo pipefail

# ------------------------------------------------------------------ locate client ---
CRAVE_BIN="${CRAVE_BIN:-}"
if [ -z "$CRAVE_BIN" ]; then
  for cand in \
    "$HOME/.crave/bin/crave.exe" \
    "$HOME/.crave/bin/crave" \
    "$(command -v crave.exe 2>/dev/null || true)" \
    "$(command -v crave 2>/dev/null || true)"
  do
    if [ -n "$cand" ] && [ -x "$cand" ]; then CRAVE_BIN="$cand"; break; fi
  done
fi
if [ -z "$CRAVE_BIN" ]; then
  echo "crave-shim: FATAL: could not find the crave client; set CRAVE_BIN to its path." >&2
  exit 1
fi

# -------------------------------------------------- clear the poisoned update state ---
# The failing update leaves crave-<ver>.zip and/or crave-<ver>.zip_unverified behind;
# their presence is what turns the next run into WinError 183. Removing them costs
# nothing when the update is not being attempted (which, with -n, it never is).
CRAVE_TMP="${TEMP:-${TMPDIR:-/tmp}}"
if [ -d "$CRAVE_TMP" ]; then
  for f in "$CRAVE_TMP"/crave-*.zip "$CRAVE_TMP"/crave-*.zip_unverified; do
    if [ -e "$f" ]; then
      rm -f "$f" 2>/dev/null && echo "crave-shim: cleared stale update payload $(basename "$f")" || true
    fi
  done
fi

# --------------------------------------------------------------------- exec -n ---
exec "$CRAVE_BIN" -n "$@"
