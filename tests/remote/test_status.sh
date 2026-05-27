#!/usr/bin/env bash
# Remote tests for `subgrove status`.
#
# The remote fixture clones from a real origin, so unlike the local tier the
# parent (and each submodule) HAS refs/remotes/origin/main — this is where
# the REMOTE column's numeric ahead/behind and the `--fetch` refresh get
# exercised over the wire. See docs/design/status.md.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

# --- case: basic table + read-only ---
mkfixture_remote status_basic
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
register_feature_branch feat/feat-a
# Default status must not perturb main super (parent or submodules).
state_p="$(snapshot_state .)"
state_a="$(snapshot_state sm-a)"
state_b="$(snapshot_state sm-b)"
./subgrove status >out 2>&1
assert_grep out "feat/feat-a"
assert_grep out "sm-a"
assert_grep out "sm-b"
assert_grep out "\(main\)"
assert_grep out "clean"
assert_state_eq .    "$state_p" "[basic] main super parent read-only"
assert_state_eq sm-a "$state_a" "[basic] main super sm-a read-only"
assert_state_eq sm-b "$state_b" "[basic] main super sm-b read-only"
cleanup_fixture_remote

# --- case: --fetch surfaces parent + submodule trailing origin/main ---
# Advance super's origin AND sm-a's origin after the worktree was created.
# A *default* status (offline) wouldn't see them; --fetch refreshes each
# git dir's origin/main and then: the parent feat branch trails origin/main
# (REMOTE ↓1) and sm-a is flagged behind with an `update` hint. --fetch
# moves only remote-tracking refs — the feat branch must not move.
mkfixture_remote status_fetch_behind
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
register_feature_branch feat/feat-a
push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream super" >/dev/null
push_to_origin_main "$SUBGROVE_TEST_SM_URL"    "upstream sm-a"  >/dev/null
feat_before="$(git -C .worktree/feat-a/sm-a rev-parse refs/heads/feat/feat-a)"
./subgrove status --fetch >out 2>&1
assert_grep out "↓1"                      # parent feat-a trails origin/main
assert_grep out "behind origin/main"      # sm-a flagged
assert_grep out "sm-a"
assert_eq "$feat_before" "$(git -C .worktree/feat-a/sm-a rev-parse refs/heads/feat/feat-a)" \
    "feat branch must not move on --fetch"
cleanup_fixture_remote
