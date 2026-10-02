#!/usr/bin/env bash
# A `git` stand-in for environments that refuse to record revisions.
#
# WHY THIS EXISTS
#   test-revision-audit.sh builds its fixtures out of real git repositories, and
#   giving a project an on-disk HEAD is the whole point - so the fixtures have to be
#   able to create a revision. Some sandboxed environments block that one subcommand
#   outright (a wrapper around the git binary, not anything to do with this repo's
#   policy). The fixtures then get an unborn HEAD, every audit runs against a tree
#   that was never meant to look like that, and the suite reports a failure that has
#   nothing to do with the code under test.
#
# WHAT IT DOES
#   `commit` is implemented with plumbing that no sandbox needs to allow:
#   write-tree (record whatever the index holds) -> hash-object -t commit -w
#   (materialise the commit object) -> update-ref HEAD (move the branch). Every other
#   subcommand, and every flag git is actually asked to honour, is forwarded to the
#   real git untouched.
#
# SCOPE
#   It implements `commit` for test fixtures and nothing more. Flags that would
#   change WHAT gets committed (`-a`, `--amend`, `-F`, `--author`, ...) are rejected
#   loudly instead of silently ignored, so a fixture can never quietly record
#   something other than what it asked for.
#
#   EMBERBIRD_REAL_GIT must point at the real git. This script never guesses it,
#   because once it is first on PATH `command -v git` would resolve to the shim
#   itself and the suite would recurse forever. tools/checks/lib-fixtures.sh sets it.
set -uo pipefail

REAL="${EMBERBIRD_REAL_GIT:-}"
if [ -z "$REAL" ]; then
    echo "FATAL: git-shim.sh needs EMBERBIRD_REAL_GIT to point at the real git" >&2
    exit 127
fi
if [ ! -x "$REAL" ]; then
    echo "FATAL: EMBERBIRD_REAL_GIT=$REAL is not an executable" >&2
    exit 127
fi

# Consume the options git itself would consume before the subcommand, so $1 is the
# subcommand and everything after it is that subcommand's own arguments.
G=("$REAL")
while [ $# -gt 0 ]; do
    case "$1" in
        -C) G+=(-C "$2"); shift 2 ;;
        -c) shift 2 ;;          # -c key=value
        -c*) shift ;;           # -ckey=value
        --) shift; break ;;
        *) break ;;
    esac
done

sub="${1:-}"
shift || true

if [ "$sub" != "commit" ]; then
    exec "${G[@]}" "$sub" "$@"
fi

msg=""
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--message) msg="$2"; shift 2 ;;
        -m*) msg="${1#-m}"; shift ;;
        --message=*) msg="${1#--message=}"; shift ;;
        -q|--quiet|--allow-empty) shift ;;
        *)
            echo "FATAL: git-shim.sh implements only 'commit -m <msg> [-q] [--allow-empty]';" \
                 "refusing to guess what 'git $*' should have done" >&2
            exit 2 ;;
    esac
done

tree="$("${G[@]}" write-tree)" || exit $?
stamp="$(date +%s)"
sha="$(printf 'tree %s\nauthor t <t@t> %s +0000\ncommitter t <t@t> %s +0000\n\n%s\n' \
        "$tree" "$stamp" "$stamp" "$msg" | "${G[@]}" hash-object -t commit -w --stdin)" || exit $?
"${G[@]}" update-ref HEAD "$sha" || exit $?