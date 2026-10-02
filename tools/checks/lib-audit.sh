#!/usr/bin/env bash
# Source this to get the build recipe's revision_audit() and sanitize_worktrees()
# defined in your shell.
#
# Both functions are lifted VERBATIM out of tools/guest-build/build-from-manifest.sh
# (not copied), so the offline tests exercise exactly the code the Crave node runs.
# revision_audit needs only LOCK_XML and WORKSPACE in the environment and writes
# its bounded report to the file named in $1; sanitize_worktrees takes a workspace
# root plus project paths. Neither needs `repo`, network, or an AOSP tree.
#
# resolve_witness DOES shell out to `repo`, so it is exported separately: the tests
# put a stub `repo` on PATH before sourcing this, which is how the audit's
# post-repair re-resolution can be exercised offline.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the suite can be pointed at an OLDER recipe revision as a negative
# control - the only way to show a source-ordering check is load-bearing rather than
# a check that passes because it is looking at the thing it was written for.
RECIPE="${EMBERBIRD_RECIPE:-$HERE/../guest-build/build-from-manifest.sh}"

# resolve_witness calls the recipe's `die` on its required-mode failure path. The
# recipe defines that globally; a test shell sourcing this file does not, so give it
# the same contract here rather than letting a stub-repo failure die with
# "die: command not found" - which would look like a broken recipe, not a stub.
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

_witness_fn="$(sed -n '/^[[:space:]]*resolve_witness()[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/p' "$RECIPE")"
# Not fatal when absent: an older recipe revision without the helper still has an
# auditable revision_audit, and the test reports the helper's absence as a failure of
# THIS feature rather than taking the whole suite down with it.
if [ -n "$_witness_fn" ]; then
  eval "$_witness_fn"
  unset _witness_fn
  EMBERBIRD_HAS_RESOLVE_WITNESS=1
else
  unset _witness_fn
  EMBERBIRD_HAS_RESOLVE_WITNESS=0
fi

_audit_fn="$(sed -n '/^[[:space:]]*revision_audit()[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/p' "$RECIPE")"
# The closing-brace end pattern also matches inside the function only if a line
# holds nothing but a brace; the embedded python heredoc has none, so the range
# ends at the function's own closing brace.
[ -n "$_audit_fn" ] || {
  echo "FATAL: revision_audit() not found in $RECIPE (was it renamed or un-indented differently?)" >&2
  exit 1
}
eval "$_audit_fn"
unset _audit_fn

_sanitize_fn="$(sed -n '/^[[:space:]]*sanitize_worktrees()[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/p' "$RECIPE")"
[ -n "$_sanitize_fn" ] || {
  echo "FATAL: sanitize_worktrees() not found in $RECIPE (was it renamed or un-indented differently?)" >&2
  exit 1
}
eval "$_sanitize_fn"
unset _sanitize_fn
