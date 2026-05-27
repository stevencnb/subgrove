#!/usr/bin/env bash
# Tests for `subgrove status` on a superproject with NO submodules.
# Locks in that status degrades gracefully: it still reports the parent
# worktree/branch and never trips over the absent .gitmodules.
# See docs/design/testing-local-no-sm.md and docs/design/status.md.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

# --- case: status works with no submodules ---
mkfixture_local_no_sm status_no_sm
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
./subgrove status >out 2>&1
assert_grep out "WORKTREE"
assert_grep out "feat/feat-a"
assert_grep out "clean"
cleanup_fixture

# --- case: empty worktrees dir → friendly message ---
mkfixture_local_no_sm status_no_sm_empty
cd "$FIXTURE_SUPER"
./subgrove status >out 2>&1
assert_grep out "no feature worktrees yet"
cleanup_fixture
