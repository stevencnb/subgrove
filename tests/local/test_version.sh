#!/usr/bin/env bash
# `subgrove --version` and `subgrove version` report the version and work
# anywhere — no git repo required. They must NOT trigger repo discovery, so
# the test runs them from a dir outside any git repo.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
SUBGROVE_REPO_ROOT="${SUBGROVE_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
sg="$SUBGROVE_REPO_ROOT/subgrove"

outside="$(mktemp -d "${TMPDIR:-/tmp}/subgrove-ver.XXXXXX")"
trap 'rm -rf "$outside"' EXIT
cd "$outside"

if ! "$sg" --version >out 2>&1; then
    echo "--- out ---"; cat out
    fail "--version exited non-zero"
fi
assert_grep out "subgrove [0-9]+\.[0-9]+\.[0-9]+"

if ! "$sg" version >out 2>&1; then
    echo "--- out ---"; cat out
    fail "version subcommand exited non-zero"
fi
assert_grep out "subgrove [0-9]+\.[0-9]+\.[0-9]+"

echo "PASS"
