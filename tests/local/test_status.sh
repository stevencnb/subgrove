#!/usr/bin/env bash
# Tests for `subgrove status`.
#
# status is read-only and offline by default; `--fetch` is the opt-in
# refresh. The local fixture's super has NO origin (so the parent REMOTE
# column is always "—"), but each submodule has a file:// origin pointing
# at its sibling sm-X repo — so the submodule "behind origin/main" path and
# `--fetch` are driveable locally by committing into the sibling. See
# docs/design/status.md.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# --- case: basic table — branch, touched submodules, (main) row, clean ---
mkfixture_local status_basic
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
./subgrove status >out 2>&1
assert_grep out "WORKTREE"
assert_grep out "SUBMODULES"
assert_grep out "feat/feat-a"        # the worktree's feature branch
assert_grep out "sm-a"               # both submodules were touched (touch=all default)
assert_grep out "sm-b"
assert_grep out "\(main\)"           # the main-worktree row
assert_grep out "clean"
cleanup_fixture

# --- case: dirty submodule gets the * marker and the row reads dirty ---
mkfixture_local status_dirty
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
echo "uncommitted" >> .worktree/feat-a/sm-a/README
./subgrove status >out 2>&1
assert_grep out "sm-a\*"             # sm-a flagged with * (uncommitted changes)
assert_grep out "dirty"
cleanup_fixture

# --- case: LOCAL shows ahead count vs local main ---
mkfixture_local status_ahead
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
commit_one .worktree/feat-a "feature work on parent"   # advance feat/feat-a by 1
./subgrove status >out 2>&1
assert_grep out "↑1"
cleanup_fixture

# --- case: default status is read-only AND offline (no fetch) ---
# Advance the sibling sm-a (sm-a's origin). A *default* status must neither
# mutate any working tree/HEAD/index nor fetch (the peer's origin/main ref
# must stay where `new` left it).
mkfixture_local status_readonly_offline
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
super_state="$(snapshot_state .)"
peer_state="$(snapshot_state .worktree/feat-a)"
peer_sm_a_state="$(snapshot_state .worktree/feat-a/sm-a)"
o_before="$(git -C .worktree/feat-a/sm-a rev-parse --verify --quiet refs/remotes/origin/main || echo none)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream change after new"
./subgrove status >out 2>&1
# Nothing in any working tree / HEAD / index moved.
assert_state_eq .                    "$super_state"
assert_state_eq .worktree/feat-a     "$peer_state"
assert_state_eq .worktree/feat-a/sm-a "$peer_sm_a_state"
# And the peer's origin/main remote-tracking ref did NOT advance (no fetch).
o_after="$(git -C .worktree/feat-a/sm-a rev-parse --verify --quiet refs/remotes/origin/main || echo none)"
assert_eq "$o_before" "$o_after" "default status must not fetch"
cleanup_fixture

# --- case: touch=none → no submodules listed as touched ---
mkfixture_local status_touch_none
cd "$FIXTURE_SUPER"
./subgrove new feat-b touch=none >out 2>&1
./subgrove status >out 2>&1
assert_grep out "feat-b"
# No submodule carries feat/feat-b, and the (main) row never lists touched
# submodules — so neither sm name appears anywhere.
assert_grep_v out "sm-a"
assert_grep_v out "sm-b"
cleanup_fixture

# --- case: empty worktrees dir → friendly message, no crash ---
mkfixture_local status_empty
cd "$FIXTURE_SUPER"
./subgrove status >out 2>&1
assert_grep out "no feature worktrees yet"
cleanup_fixture

# --- case: --fetch flags a submodule that is behind origin/main ---
# Advance the sibling sm-a; the peer's feat branch is then behind the
# refreshed origin/main. --fetch must surface that, point at `update`, and
# move ONLY remote-tracking refs (feat + local main branches untouched).
mkfixture_local status_fetch_behind
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
feat_before="$(git -C .worktree/feat-a/sm-a rev-parse refs/heads/feat/feat-a)"
main_before="$(git -C .worktree/feat-a/sm-a rev-parse refs/heads/main)"
new_sm_a="$(commit_one "$FIXTURE_ROOT/sm-a" "upstream change" >/dev/null; git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
./subgrove status --fetch >out 2>&1
assert_grep out "behind origin/main"
assert_grep out "sm-a"
# Only origin/main moved; the peer's branches did not.
assert_eq "$feat_before" "$(git -C .worktree/feat-a/sm-a rev-parse refs/heads/feat/feat-a)" "feat branch must not move on --fetch"
assert_eq "$main_before" "$(git -C .worktree/feat-a/sm-a rev-parse refs/heads/main)" "local main must not move on --fetch"
assert_eq "$new_sm_a"    "$(git -C .worktree/feat-a/sm-a rev-parse refs/remotes/origin/main)" "origin/main should be refreshed by --fetch"
cleanup_fixture
