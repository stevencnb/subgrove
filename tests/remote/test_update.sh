#!/usr/bin/env bash
# Remote tests for `subgrove update`.
#
# update fetches each package's origin/main in main worktree, then
# FF-propagates the new origin/main into the peer worktree's submodule
# mains via the _update_sync sentinel. Local main in the main worktree
# is NEVER moved (update is fetch-only at the parent level).
#
# user-data-rules.md: cmd_update is ref-only — no working-tree touch
# in main worktree or peer. Each case snapshots the peer worktree
# (parent + sm-a + sm-b) and the main super (parent + sm-a + sm-b)
# pre/post update and asserts byte-identical state. The submodule
# main ref MAY advance via the propagation fetch — that's a ref
# change, not a working-tree change, and snapshot_state intentionally
# excludes refs (the source of truth is the assert_branch_at calls).
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

# --- case: happy — sm-a origin ahead, sm-b unchanged ---
mkfixture_remote update_happy
cd "$FIXTURE_SUPER"
./subgrove new feat-h >out 2>&1
register_feature_branch feat/feat-h

sm_b_pre="$(git -C .worktree/feat-h/sm-b rev-parse main)"
new_sm_a="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL" "upstream sm-a")"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-h)"
state_wt_a="$(snapshot_state .worktree/feat-h/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-h/sm-b)"

./subgrove update feat-h >out 2>&1

assert_branch_at .worktree/feat-h/sm-a main "$new_sm_a"
assert_branch_at .worktree/feat-h/sm-b main "$sm_b_pre"
# Working trees untouched everywhere.
assert_state_eq .                    "$state_main_p" "[happy] main super parent"
assert_state_eq sm-a                 "$state_main_a" "[happy] main super sm-a"
assert_state_eq sm-b                 "$state_main_b" "[happy] main super sm-b"
assert_state_eq .worktree/feat-h      "$state_wt_p"  "[happy] peer parent"
assert_state_eq .worktree/feat-h/sm-a "$state_wt_a"  "[happy] peer sm-a"
assert_state_eq .worktree/feat-h/sm-b "$state_wt_b"  "[happy] peer sm-b"
# §15: status reflects the resulting state.
assert_status feat-h "feat/feat-h"
cleanup_fixture_remote

# --- case: super origin ahead — main worktree's origin/main advances; local main untouched ---
mkfixture_remote update_super_ahead
cd "$FIXTURE_SUPER"
./subgrove new feat-su >out 2>&1
register_feature_branch feat/feat-su

local_main_pre="$(git rev-parse main)"
new_super="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream super")"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-su)"
state_wt_a="$(snapshot_state .worktree/feat-su/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-su/sm-b)"

./subgrove update feat-su >out 2>&1

# update never moves local main (only fetches).
assert_eq "$local_main_pre" "$(git rev-parse main)" "local main must not move"
# refs/remotes/origin/main advanced to the upstream commit.
assert_eq "$new_super" "$(git rev-parse refs/remotes/origin/main)" "origin/main fetched"
# Working trees untouched.
assert_state_eq .                    "$state_main_p" "[super_ahead] main super parent"
assert_state_eq sm-a                 "$state_main_a" "[super_ahead] main super sm-a"
assert_state_eq sm-b                 "$state_main_b" "[super_ahead] main super sm-b"
assert_state_eq .worktree/feat-su      "$state_wt_p" "[super_ahead] peer parent"
assert_state_eq .worktree/feat-su/sm-a "$state_wt_a" "[super_ahead] peer sm-a"
assert_state_eq .worktree/feat-su/sm-b "$state_wt_b" "[super_ahead] peer sm-b"
# §15: status reflects the resulting state.
assert_status feat-su "feat/feat-su"
cleanup_fixture_remote

# --- case: all three origins ahead — submodule peers advance, super fetched only ---
mkfixture_remote update_all_ahead
cd "$FIXTURE_SUPER"
./subgrove new feat-all >out 2>&1
register_feature_branch feat/feat-all

local_main_pre="$(git rev-parse main)"
new_super="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream super")"
new_sm_a="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL"    "upstream sm-a")"
new_sm_b="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL2"   "upstream sm-b")"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-all)"
state_wt_a="$(snapshot_state .worktree/feat-all/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-all/sm-b)"

./subgrove update feat-all >out 2>&1

assert_branch_at .worktree/feat-all/sm-a main "$new_sm_a"
assert_branch_at .worktree/feat-all/sm-b main "$new_sm_b"
assert_eq "$local_main_pre" "$(git rev-parse main)" "local main must not move"
assert_eq "$new_super" "$(git rev-parse refs/remotes/origin/main)" "origin/main fetched"
assert_state_eq .                     "$state_main_p" "[all_ahead] main super parent"
assert_state_eq sm-a                  "$state_main_a" "[all_ahead] main super sm-a"
assert_state_eq sm-b                  "$state_main_b" "[all_ahead] main super sm-b"
assert_state_eq .worktree/feat-all      "$state_wt_p" "[all_ahead] peer parent"
assert_state_eq .worktree/feat-all/sm-a "$state_wt_a" "[all_ahead] peer sm-a"
assert_state_eq .worktree/feat-all/sm-b "$state_wt_b" "[all_ahead] peer sm-b"
# §15: status reflects the resulting state.
assert_status feat-all "feat/feat-all"
cleanup_fixture_remote

# --- case: peer sm-a main diverged — refused with warn, peer stays put ---
# Peer-side commit on sm-a main plus an independent origin advance. The
# resulting non-FF fetch into peer's main is rejected; the warn reports
# 'diverged' and the peer's sm-a main stays at its peer-side tip.
mkfixture_remote update_diverged
cd "$FIXTURE_SUPER"
./subgrove new feat-d >out 2>&1
register_feature_branch feat/feat-d

(
    cd .worktree/feat-d/sm-a
    git checkout --quiet main
    echo "peer-side $$" >> README
    git add README
    git commit --quiet -m "peer-side commit on sm-a main"
    git checkout --quiet feat/feat-d
)
peer_sm_a_main="$(git -C .worktree/feat-d/sm-a rev-parse main)"

new_sm_a="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL" "upstream divergent")"
assert_ne "$peer_sm_a_main" "$new_sm_a" "test setup: peer != origin"

# Snapshot AFTER our setup commits — that's the user state we want
# preserved across `subgrove update`'s refused propagation.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-d)"
state_wt_a="$(snapshot_state .worktree/feat-d/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-d/sm-b)"

./subgrove update feat-d >out 2>&1

assert_branch_at .worktree/feat-d/sm-a main "$peer_sm_a_main"
# Same-line match: 'sm-a' and 'diverged|skipped' must appear together,
# not spread across unrelated lines (which would false-positive).
assert_grep out "sm-a.*(diverged|skipped)"
# Working trees untouched anywhere — refused propagation must not
# leave half-applied edits.
assert_state_eq .                    "$state_main_p" "[diverged] main super parent"
assert_state_eq sm-a                 "$state_main_a" "[diverged] main super sm-a"
assert_state_eq sm-b                 "$state_main_b" "[diverged] main super sm-b"
assert_state_eq .worktree/feat-d      "$state_wt_p" "[diverged] peer parent"
assert_state_eq .worktree/feat-d/sm-a "$state_wt_a" "[diverged] peer sm-a"
assert_state_eq .worktree/feat-d/sm-b "$state_wt_b" "[diverged] peer sm-b"
# §15: status reflects the resulting state.
assert_status feat-d "feat/feat-d"
cleanup_fixture_remote

# --- case: no drift anywhere — true no-op ---
mkfixture_remote update_noop
cd "$FIXTURE_SUPER"
./subgrove new feat-n >out 2>&1
register_feature_branch feat/feat-n

before_sm_a="$(git -C .worktree/feat-n/sm-a rev-parse main)"
before_sm_b="$(git -C .worktree/feat-n/sm-b rev-parse main)"
before_main="$(git rev-parse main)"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-n)"
state_wt_a="$(snapshot_state .worktree/feat-n/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-n/sm-b)"

./subgrove update feat-n >out 2>&1

assert_branch_at .worktree/feat-n/sm-a main "$before_sm_a"
assert_branch_at .worktree/feat-n/sm-b main "$before_sm_b"
assert_eq "$before_main" "$(git rev-parse main)"
assert_state_eq .                    "$state_main_p" "[noop] main super parent"
assert_state_eq sm-a                 "$state_main_a" "[noop] main super sm-a"
assert_state_eq sm-b                 "$state_main_b" "[noop] main super sm-b"
assert_state_eq .worktree/feat-n      "$state_wt_p" "[noop] peer parent"
assert_state_eq .worktree/feat-n/sm-a "$state_wt_a" "[noop] peer sm-a"
assert_state_eq .worktree/feat-n/sm-b "$state_wt_b" "[noop] peer sm-b"
# §15: status reflects the resulting state.
assert_status feat-n "feat/feat-n"
cleanup_fixture_remote
