#!/usr/bin/env bash
# Remote tests for `subgrove status` on a no-submodule superproject.
#
# Companion to tests/local-no-sm/test_status.sh. The remote no-sm fixture
# clones from a real origin, so this is where the parent REMOTE column's
# numeric ahead/behind gets exercised over the wire without any submodules
# in the picture. See docs/design/status.md.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

# --- case: basic — branch, clean, no submodules ---
mkfixture_remote_no_sm status_basic
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
register_feature_branch_no_sm feat/feat-a
./subgrove status >out 2>&1
assert_grep out "WORKTREE"
assert_grep out "feat/feat-a"
assert_grep out "clean"
cleanup_fixture_remote_no_sm

# --- case: --fetch surfaces the parent trailing origin/main ---
mkfixture_remote_no_sm status_fetch_behind
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
register_feature_branch_no_sm feat/feat-a
push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream super" >/dev/null
./subgrove status --fetch >out 2>&1
assert_grep out "↓1"                      # feat-a trails the refreshed origin/main
cleanup_fixture_remote_no_sm

# --- case: empty worktrees dir → friendly message ---
mkfixture_remote_no_sm status_empty
cd "$FIXTURE_SUPER"
./subgrove status >out 2>&1
assert_grep out "no feature worktrees yet"
cleanup_fixture_remote_no_sm
