#!/usr/bin/env bash
# Source this to get the build recipe's revision_audit() and sanitize_worktrees()
# defined in your shell.
#
# Both functions are lifted VERBATIM out of tools/guest-build/build-from-manifest.sh
# (not copied), so the offline tests exercise exactly the code the Crave node runs.
# revision_audit needs only LOCK_XML and WORKSPACE in the environment and writes
# its bounded report to the file named in $1; sanitize_worktrees takes a workspace
# root plus project paths. Neither needs `repo`, network, or an AOSP tree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE="$HERE/../guest-build/build-from-manifest.sh"

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
