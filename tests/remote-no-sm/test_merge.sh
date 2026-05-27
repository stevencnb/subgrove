#!/usr/bin/env bash
# Remote tests for `subgrove merge` (push=false default) on a no-sm
# super. Companion to test_merge_push.sh (which focuses on push=true).
#
# Pins that when push=false (the default), the merge does NOT contact
# origin even though origin is reachable. The local tier already proves
# this with a missing origin; here we prove it positively with a real
# remote present.
#
# user-data-rules.md: Phase 1 mutates only the local main branch (FF);
# Phase 2 / push must not run.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

# --- case: golden (parent-only commit; push=false default) ---
mkfixture_remote_no_sm merge_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-g >out 2>&1
register_feature_branch_no_sm feat/feat-g

( cd .worktree/feat-g && echo "parent change $$" >> README \
    && git add README && git commit --quiet -m "parent commit" )
feat_commits="$(git rev-list main..feat/feat-g)"
[[ -n "$feat_commits" ]] || fail "test setup: no commits ahead of main on feat-g"

super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"
state_wt="$(snapshot_state .worktree/feat-g)"

./subgrove merge feat-g >out 2>&1

# Parent main caught up to feat tip LOCALLY.
assert_branch_at . main "feat/feat-g"
# History correctness: every feat commit is now an ancestor of main —
# not just tip-equality (catches a future --ff-only → --squash regression).
for sha in $feat_commits; do
    assert_ancestor . "$sha" main "feat commit $sha not in main's history"
done
# Super origin UNCHANGED — default is push=false; subgrove must not
# silently push when origin is reachable.
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin must not move on push=false"
# Narration: parent FF fired; push was skipped with the push=false variant.
assert_grep out "Fast-forwarding parent main"
assert_grep out "Push skipped \(push=true to enable\)"
# Worktree retained + byte-identical (Phase 2 only mutates main super).
assert_file_exists .worktree/feat-g
assert_state_eq .worktree/feat-g "$state_wt" "[golden] feat worktree"
# §15: status reflects the resulting state (merge retains the worktree).
assert_status feat-g "feat/feat-g"
cleanup_fixture_remote_no_sm

# --- case: multi-commit feat — history correctness without push ---
# Same shape as merge_push_multi_commit but without push=true. Pins
# that FF preserves every commit (not squash) even on a no-sm super
# with a reachable origin.
mkfixture_remote_no_sm merge_multi_commit
cd "$FIXTURE_SUPER"
./subgrove new feat-mc >out 2>&1
register_feature_branch_no_sm feat/feat-mc

for i in 1 2 3; do
    ( cd .worktree/feat-mc && echo "commit $i $$" >> README \
        && git add README && git commit --quiet -m "commit $i" )
done
feat_commits="$(git rev-list main..feat/feat-mc)"
[[ -n "$feat_commits" ]] || fail "test setup: no commits ahead of main on feat-mc"

super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"
# Phase 2 only touches main super (dst); the merged-FROM feat worktree
# must be byte-identical after.
state_wt="$(snapshot_state .worktree/feat-mc)"

./subgrove merge feat-mc >out 2>&1

assert_branch_at . main "feat/feat-mc"
for sha in $feat_commits; do
    assert_ancestor . "$sha" main "feat commit $sha not in main's history"
done
# Origin still untouched (push=false default).
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin must not move on push=false (multi-commit)"
assert_state_eq .worktree/feat-mc "$state_wt" "[multi_commit] feat worktree"
# §15: status reflects the resulting state (merge retains the worktree).
assert_status feat-mc "feat/feat-mc"
cleanup_fixture_remote_no_sm

# --- case: nothing to merge (feat tip == main tip) ---
mkfixture_remote_no_sm merge_nothing
cd "$FIXTURE_SUPER"
./subgrove new feat-n >out 2>&1
register_feature_branch_no_sm feat/feat-n

main_sha_pre="$(git rev-parse main)"
feat_sha_pre="$(git rev-parse feat/feat-n)"
main_state="$(snapshot_state .)"
wt_state="$(snapshot_state .worktree/feat-n)"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

./subgrove merge feat-n >out 2>&1

assert_grep out "Nothing to merge"
assert_eq "$main_sha_pre" "$(git rev-parse main)"         "main moved on nothing-to-merge"
assert_eq "$feat_sha_pre" "$(git rev-parse feat/feat-n)"  "feat moved on nothing-to-merge"
assert_state_eq .                "$main_state"
assert_state_eq .worktree/feat-n "$wt_state"
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin unchanged on nothing-to-merge"
# Phase 1 didn't run.
assert_grep_v out "Fast-forwarding parent main"
# Push-skipped variant for push=false default.
assert_grep out "Push skipped \(push=true to enable\)"
# §15: status reflects the resulting state (worktree retained on no-op).
assert_status feat-n "feat/feat-n"
cleanup_fixture_remote_no_sm

# --- case: non-FF parent refused ---
# Commit on feat, then commit directly on main super (diverges from
# feat). Parent FF check must refuse; no half-state.
mkfixture_remote_no_sm merge_non_ff_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x

( cd .worktree/feat-x && echo "feat" >> README && git add README \
    && git commit --quiet -m "feat" )

echo "main divergent" >> README
git add README
git commit --quiet -m "main divergent"
main_sha_pre="$(git rev-parse main)"
main_state="$(snapshot_state .)"
wt_state="$(snapshot_state .worktree/feat-x)"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on non-FF parent"
fi
assert_grep out "parent main is not ancestor of feat/feat-x \(non-FF\)"
assert_eq "$main_sha_pre" "$(git rev-parse main)" "main moved on non-FF refuse"
assert_state_eq . "$main_state"
# Source feat worktree byte-identical too — refuse touches neither side.
assert_state_eq .worktree/feat-x "$wt_state" "[non_ff] feat worktree"
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin unchanged on non-FF refuse"
assert_grep_v out "Fast-forwarding parent main"
# §15: status reflects the resulting state (worktree retained on refuse).
assert_status feat-x "feat/feat-x"
cleanup_fixture_remote_no_sm

# --- case: nonexistent branch errs ---
mkfixture_remote_no_sm merge_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove merge never-existed >out 2>&1; then
    fail "expected merge to err on nonexistent branch name"
fi
assert_grep out "does not exist"
# §15: status reflects the resulting state (no worktree was created).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: dirty parent (dst) refused (push=false) ---
# Same as merge_push_dirty but without push=true to pin the dirty
# refusal fires identically on the default path.
mkfixture_remote_no_sm merge_dirty_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
( cd .worktree/feat-x && echo "feat work" >> README && git add README \
    && git commit --quiet -m "feat-x commit" )

echo "dirty in main super" >> README
assert_pending_file . README unstaged
main_state="$(snapshot_state .)"
wt_state="$(snapshot_state .worktree/feat-x)"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty parent dst"
fi
assert_grep out "main worktree \(parent, dst\) has uncommitted"
assert_state_eq . "$main_state"
assert_pending_file . README unstaged
# Source feat worktree byte-identical too.
assert_state_eq .worktree/feat-x "$wt_state" "[dirty] feat worktree"
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin unchanged on dirty refuse"
assert_grep_v out "Fast-forwarding parent main"
# §15: status reflects the resulting state (worktree retained on refuse).
assert_status feat-x "feat/feat-x"
cleanup_fixture_remote_no_sm

# --- case: two peer worktrees — merging one doesn't touch the other ---
# The peer-propagation phase exists to push the new submodule mains to
# OTHER worktrees. With zero submodules nothing to propagate, so the
# propagation info line must not fire and peer worktrees must be
# byte-identical.
mkfixture_remote_no_sm merge_two_peer
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
./subgrove new feat-y >out 2>&1
register_feature_branch_no_sm feat/feat-y
( cd .worktree/feat-x && echo "feat work" >> README && git add README \
    && git commit --quiet -m "feat-x commit" )

# Snapshot BOTH the bystander peer (feat-y) and the merged-FROM source
# (feat-x). Phase 2 only touches main super; neither worktree may move.
state_x="$(snapshot_state .worktree/feat-x)"
state_y="$(snapshot_state .worktree/feat-y)"

./subgrove merge feat-x >out 2>&1

# Negative-assert: no peer propagation on a no-sm super.
assert_grep_v out "Propagating new main to peer worktrees"
assert_grep_v out "Moving main forward in main worktree's submodules"
# Positive-assert: Phase 1 ran (parent merge isn't being silently
# skipped by an over-eager early-return).
assert_grep out "Fast-forwarding parent main"
# Source worktree (merged from) AND bystander peer both byte-identical.
assert_state_eq .worktree/feat-x "$state_x" "[two_peer] feat-x (source) untouched"
assert_state_eq .worktree/feat-y "$state_y" "[two_peer] feat-y (bystander) untouched"
# §15: status reflects the resulting state (both worktrees retained).
assert_status feat-x feat-y "feat/feat-x" "feat/feat-y"
cleanup_fixture_remote_no_sm
