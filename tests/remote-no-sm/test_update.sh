#!/usr/bin/env bash
# Remote tests for `subgrove update` on a no-submodule super.
#
# Companion to tests/remote/test_update.sh. The wire-only paths: super
# origin/main fetch actually succeeds (the local-no-sm tier always
# emits warn: parent fetch failed because it has no origin) and
# refs/remotes/origin/main advances. Per-submodule peer propagation is
# N/A — zero submodules.
#
# user-data-rules.md: cmd_update is ref-only — no working-tree touch
# in main worktree or peer.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

# --- case: super origin ahead — refs/remotes/origin/main advances; local main untouched ---
mkfixture_remote_no_sm update_super_ahead
cd "$FIXTURE_SUPER"
./subgrove new feat-su >out 2>&1
register_feature_branch_no_sm feat/feat-su

local_main_pre="$(git rev-parse main)"
new_super="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream super")"

state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-su)"

./subgrove update feat-su >out 2>&1

# update never moves local main (only fetches).
assert_eq "$local_main_pre" "$(git rev-parse main)" "local main must not move"
# refs/remotes/origin/main advanced to the upstream commit.
assert_eq "$new_super" "$(git rev-parse refs/remotes/origin/main)" "origin/main fetched"
# Distinguishes this tier from local-no-sm — fetch succeeded.
assert_grep_v out "warn: parent fetch failed"
# Submodule loop summary still truthful: zero submodules.
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
# Working trees untouched.
assert_state_eq .                "$state_main" "[super_ahead] main super"
assert_state_eq .worktree/feat-su "$state_wt"   "[super_ahead] peer"
# §15: status reflects the resulting state (update retains the worktree).
assert_status feat-su "feat/feat-su"
cleanup_fixture_remote_no_sm

# --- case: no drift anywhere — true no-op ---
mkfixture_remote_no_sm update_noop
cd "$FIXTURE_SUPER"
./subgrove new feat-n >out 2>&1
register_feature_branch_no_sm feat/feat-n

before_main="$(git rev-parse main)"
before_origin="$(git rev-parse refs/remotes/origin/main)"

state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-n)"

./subgrove update feat-n >out 2>&1

assert_eq "$before_main"   "$(git rev-parse main)"                     "local main unmoved"
assert_eq "$before_origin" "$(git rev-parse refs/remotes/origin/main)" "origin/main unmoved"
assert_grep_v out "warn: parent fetch failed"
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
assert_state_eq .               "$state_main" "[noop] main super"
assert_state_eq .worktree/feat-n "$state_wt"   "[noop] peer"
# §15: status reflects the resulting state (update retains the worktree).
assert_status feat-n "feat/feat-n"
cleanup_fixture_remote_no_sm

# --- case: nonexistent name errs ---
mkfixture_remote_no_sm update_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove update never-existed >out 2>&1; then
    fail "expected update to err on nonexistent worktree name"
fi
assert_grep out "does not exist"
# §15: status reflects the resulting state (no worktree was created).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: sentinel ref never created in main super ---
# The sentinel `refs/heads/_update_sync` lives in per-submodule git dirs.
# With zero submodules, no sentinel should be created in main super's
# refs. Mirrors local-no-sm/test_update.sh::update_no_sentinel; pins
# that the same invariant holds when origin is reachable.
mkfixture_remote_no_sm update_no_sentinel
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
register_feature_branch_no_sm feat/feat-y
# user-data-rules.md: update is ref-only — main super + peer worktree
# byte-identical across the operation (snapshot_state excludes refs, so
# the absence-of-sentinel checks below are the ref-level assertion).
state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-y)"
./subgrove update feat-y >out 2>&1
assert_grep out "FF-updating peer worktree 'feat-y'"
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
for ref in refs/heads/_update_sync refs/_update_sync refs/remotes/origin/_update_sync; do
    if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
        fail "main super has $ref after update on no-sm fixture"
    fi
done
assert_state_eq .                "$state_main" "[no_sentinel] main super"
assert_state_eq .worktree/feat-y "$state_wt"   "[no_sentinel] peer"
# §15: status reflects the resulting state (update retains the worktree).
assert_status feat-y "feat/feat-y"
cleanup_fixture_remote_no_sm

# --- case: pre-existing _update_sync ref in parent is untouched ---
# Subgrove's sentinel manipulation is scoped to per-submodule git dirs.
# If a user happens to have a parent-level ref with the same name (from
# a different tool or workflow), subgrove must not clobber it. Mirror
# update_no_sentinel's three-namespace symmetry over the wire.
mkfixture_remote_no_sm update_parent_sentinel_preserved
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
register_feature_branch_no_sm feat/feat-y
git update-ref refs/heads/_update_sync HEAD
git update-ref refs/_update_sync HEAD
git update-ref refs/remotes/origin/_update_sync HEAD
pre_heads="$(git rev-parse refs/heads/_update_sync)"
pre_root="$(git rev-parse refs/_update_sync)"
pre_remote="$(git rev-parse refs/remotes/origin/_update_sync)"
# Working trees byte-identical too (update is ref-only).
state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-y)"
./subgrove update feat-y >out 2>&1
post_heads="$(git rev-parse --verify --quiet refs/heads/_update_sync 2>/dev/null || echo MISSING)"
post_root="$(git rev-parse --verify --quiet refs/_update_sync 2>/dev/null || echo MISSING)"
post_remote="$(git rev-parse --verify --quiet refs/remotes/origin/_update_sync 2>/dev/null || echo MISSING)"
assert_eq "$pre_heads"  "$post_heads"  "refs/heads/_update_sync changed during update"
assert_eq "$pre_root"   "$post_root"   "refs/_update_sync changed during update"
assert_eq "$pre_remote" "$post_remote" "refs/remotes/origin/_update_sync changed during update"
assert_state_eq .                "$state_main" "[parent_sentinel] main super"
assert_state_eq .worktree/feat-y "$state_wt"   "[parent_sentinel] peer"
# §15: status reflects the resulting state (update retains the worktree).
assert_status feat-y "feat/feat-y"
cleanup_fixture_remote_no_sm

# --- case: doesn't require clean state ---
# cmd_update is ref-only (no working-tree mutation), so a dirty peer
# worktree must not block it. Same invariant as the other tiers.
mkfixture_remote_no_sm update_dirty_ok
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
register_feature_branch_no_sm feat/feat-y
echo "dirty" >> .worktree/feat-y/README
assert_pending_file .worktree/feat-y README unstaged
# Snapshot AFTER the dirty edit — the peer (incl. the dirty edit) and
# main super must be byte-identical across the ref-only update.
state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-y)"
./subgrove update feat-y >out 2>&1
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
# Dirty edit preserved (specific-file assertion + full snapshot).
assert_pending_file .worktree/feat-y README unstaged
assert_state_eq .                "$state_main" "[dirty_ok] main super"
assert_state_eq .worktree/feat-y "$state_wt"   "[dirty_ok] peer"
# §15: status reflects the resulting state (update retains the worktree).
assert_status feat-y "feat/feat-y"
cleanup_fixture_remote_no_sm

# --- case: rebase=ff on a no-sm super — degenerate, nothing to rebase ---
# Companion to local-no-sm's update_rebase_ff_degenerate, over the wire.
# Zero submodules → the FF phase reports everything caught up and prints
# no submodule foreach hint. update stays ref-only on the parent.
mkfixture_remote_no_sm update_rebase_ff_degenerate
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
register_feature_branch_no_sm feat/feat-y
state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-y)"
./subgrove update feat-y rebase=ff >out 2>&1
assert_grep out "Fast-forwarding feature branches onto new main"
assert_grep out "All feature branches caught up"
assert_grep_v out "git submodule foreach 'git rebase main'"
# Nothing outstanding → no tagged notice section.
assert_grep_v out "NEXT STEPS"
assert_grep_v out "ATTENTION"
# Parent stays untouched (update is ref-only; no submodules to fast-forward).
assert_state_eq .                "$state_main" "[rebase_ff_degenerate] main super"
assert_state_eq .worktree/feat-y "$state_wt"   "[rebase_ff_degenerate] peer"
# §15: status reflects the resulting state (update retains the worktree).
assert_status feat-y "feat/feat-y"
cleanup_fixture_remote_no_sm
