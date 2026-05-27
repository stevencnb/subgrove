#!/usr/bin/env bash
# Remote tests for `subgrove merge ... push=true` on a no-sm super.
#
# Companion to tests/remote/test_merge_push.sh. The wire-only paths:
# happy push against a real remote (local-no-sm only reaches the
# `'origin' does not appear` error) and FF-only refusal when origin/main
# has advanced. Per-submodule push order and partial-failure half-states
# are N/A on a no-sm super (only one package).
#
# user-data-rules.md: cmd_merge Phase 2 only mutates main super; the
# source (feat) worktree must survive byte-identically across every
# invocation, success or failure.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

# Helper: read URL's current main SHA off the wire. `--` terminates
# git's option parsing so a URL beginning with `-` can't sneak in.
_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

# --- case: golden — parent commit; super origin advances ---
mkfixture_remote_no_sm merge_push_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-g >out 2>&1
register_feature_branch_no_sm feat/feat-g

( cd .worktree/feat-g && echo "parent change $$" >> README \
    && git add README && git commit --quiet -m "parent commit" )

state_wt="$(snapshot_state .worktree/feat-g)"

./subgrove merge feat-g push=true >out 2>&1

# Phase 2 only touches main super; feat worktree must be byte-identical.
assert_state_eq .worktree/feat-g "$state_wt" "[golden] feat worktree"

feat_super="$(git -C .worktree/feat-g rev-parse feat/feat-g)"
assert_eq "$feat_super" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin = feat tip"
# §15: status reflects the resulting state (merge retains the worktree).
assert_status feat-g "feat/feat-g"
cleanup_fixture_remote_no_sm

# --- case: nothing to push — no edits anywhere; narration narrates skip ---
mkfixture_remote_no_sm merge_push_nothing
cd "$FIXTURE_SUPER"
./subgrove new feat-n >out 2>&1
register_feature_branch_no_sm feat/feat-n

state_wt="$(snapshot_state .worktree/feat-n)"
# Nothing-to-push also implies main super shouldn't move — capture it.
state_main="$(snapshot_state .)"

super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

./subgrove merge feat-n push=true >out 2>&1
assert_grep out "Nothing to merge|Push skipped"

assert_state_eq .worktree/feat-n "$state_wt"  "[nothing] feat worktree"
# Main super untouched too (no Phase 2 work).
assert_state_eq .                "$state_main" "[nothing] main super"

assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" "super unchanged"
# §15: status reflects the resulting state (worktree retained on no-op).
assert_status feat-n "feat/feat-n"
cleanup_fixture_remote_no_sm

# --- case: non-FF super — origin advanced; super push rejected ---
# The parent push fails: origin/super is at upstream, local feat is one
# commit beyond stale baseline → non-FF. Subgrove never --forces, so the
# push is rejected. Feat worktree must survive byte-identical even on
# the rejected-push path.
mkfixture_remote_no_sm merge_push_non_ff
cd "$FIXTURE_SUPER"
./subgrove new feat-nff >out 2>&1
register_feature_branch_no_sm feat/feat-nff
( cd .worktree/feat-nff && echo "feat parent $$" >> README \
    && git add README && git commit --quiet -m "feat parent" )

upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream parent")"

state_wt="$(snapshot_state .worktree/feat-nff)"

set +e
./subgrove merge feat-nff push=true >out 2>&1
rc=$?
set -e

assert_ne "0" "$rc" "merge push=true should fail (non-FF super)"
assert_eq "$upstream_sha" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin stays at upstream"
# Feat worktree untouched even though Phase 2 + push happened. User's
# work-in-progress is preserved regardless of push outcome.
assert_state_eq .worktree/feat-nff "$state_wt" "[non_ff] feat worktree"
# §15: status reflects the resulting state (worktree retained on push reject).
assert_status feat-nff "feat/feat-nff"
cleanup_fixture_remote_no_sm

# --- case: dirty parent dst refused (push never attempted) ---
# The Phase-1 dirty-refuse path on a no-sm super doesn't reach the push
# phase. Pins that the dirty edit + the origin ref are both preserved.
mkfixture_remote_no_sm merge_push_dirty
cd "$FIXTURE_SUPER"
./subgrove new feat-d >out 2>&1
register_feature_branch_no_sm feat/feat-d
( cd .worktree/feat-d && echo "feat" >> README && git add README \
    && git commit --quiet -m "feat" )

echo "dirty in main super" >> README
assert_pending_file . README unstaged

state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-d)"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

set +e
./subgrove merge feat-d push=true >out 2>&1
rc=$?
set -e

assert_ne "0" "$rc" "merge should refuse on dirty parent"
assert_grep out "main worktree \(parent, dst\) has uncommitted"
# State preserved on refuse — dirty edit + origin frozen.
assert_state_eq . "$state_main" "[dirty] main super"
assert_pending_file . README unstaged
# Source feat worktree byte-identical too (rule: every case, incl. refuse).
assert_state_eq .worktree/feat-d "$state_wt" "[dirty] feat worktree"
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin frozen on refuse"
# Phase 2 didn't run, push didn't run.
assert_grep_v out "Fast-forwarding parent main"
# §15: status reflects the resulting state (worktree retained on refuse).
assert_status feat-d "feat/feat-d"
cleanup_fixture_remote_no_sm

# --- case: multi-commit feat — history correctness on push ---
# Pin that EVERY feat commit lands in main's history after merge, not
# just that the tip matches. Catches a future regression where
# `git merge --ff-only` is replaced with `--squash` (tip equality still
# holds; history doesn't).
mkfixture_remote_no_sm merge_push_multi_commit
cd "$FIXTURE_SUPER"
./subgrove new feat-mc >out 2>&1
register_feature_branch_no_sm feat/feat-mc

for i in 1 2 3; do
    ( cd .worktree/feat-mc && echo "commit $i $$" >> README \
        && git add README && git commit --quiet -m "commit $i" )
done
feat_commits="$(git -C .worktree/feat-mc rev-list main..feat/feat-mc)"
[[ -n "$feat_commits" ]] || fail "test setup: no commits ahead of main on feat-mc"

state_wt="$(snapshot_state .worktree/feat-mc)"

./subgrove merge feat-mc push=true >out 2>&1

# Every feat commit is in main's history.
for sha in $feat_commits; do
    assert_ancestor . "$sha" main "feat commit $sha not in main's history"
done
# Super origin = feat tip.
feat_super="$(git -C .worktree/feat-mc rev-parse feat/feat-mc)"
assert_eq "$feat_super" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin = feat tip after multi-commit push"
# Feat worktree preserved.
assert_state_eq .worktree/feat-mc "$state_wt" "[multi_commit] feat worktree"
# §15: status reflects the resulting state (merge retains the worktree).
assert_status feat-mc "feat/feat-mc"
cleanup_fixture_remote_no_sm

# --- case: feat branch NOT pushed to remote ---
# merge push=true only moves main; the feat/<name> branch must NOT
# appear on the remote (no `git push origin feat/...` anywhere in the
# code path). Catches a regression where a future change pushes feat
# refs alongside main.
mkfixture_remote_no_sm merge_push_feat_not_pushed
cd "$FIXTURE_SUPER"
./subgrove new feat-fnp >out 2>&1
register_feature_branch_no_sm feat/feat-fnp

( cd .worktree/feat-fnp && echo "feat $$" >> README && git add README \
    && git commit --quiet -m "feat" )

state_wt="$(snapshot_state .worktree/feat-fnp)"

./subgrove merge feat-fnp push=true >out 2>&1

# main advanced.
feat_sha="$(git -C .worktree/feat-fnp rev-parse feat/feat-fnp)"
assert_eq "$feat_sha" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "main advanced to feat tip"

# feat/feat-fnp must NOT be on the remote.
remote_refs="$(git ls-remote -- "$SUBGROVE_TEST_SUPER_NO_SM_URL")"
if echo "$remote_refs" | grep -qE "refs/heads/feat/feat-fnp"; then
    echo "--- remote refs ---" >&2
    echo "$remote_refs" >&2
    fail "feat/feat-fnp should NOT be on the remote; merge push=true only moves main"
fi
# Phase 2 only touches main super; feat worktree byte-identical.
assert_state_eq .worktree/feat-fnp "$state_wt" "[feat_not_pushed] feat worktree"
# §15: status reflects the resulting state (merge retains the worktree).
assert_status feat-fnp "feat/feat-fnp"
cleanup_fixture_remote_no_sm
