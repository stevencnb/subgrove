#!/usr/bin/env bash
# Tests for `subgrove merge` on a no-submodule fixture.
#
# Companion to tests/local/test_merge.sh. The two-phase merge must reduce
# to a single parent FF when there are no submodules; the submodule-loop
# info lines and the peer-propagation phase must not emit anything.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

# --- case: golden (parent-only commits) ---
mkfixture_local_no_sm merge_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
# Commit only in the feature worktree's parent (no submodules to commit in).
( cd .worktree/feat-x && echo "feat work" >> README && git add README \
    && git commit --quiet -m "feat-x commit" )
assert_commits_ahead . main feat/feat-x 1
# Capture commits that should land in main after FF (verify history, not
# just tip equality — per user-data-rules.md, this catches a future
# regression where someone replaces `git merge --ff-only` with
# `git merge --squash`: the tip would still match, but history would
# differ).
feat_commits="$(git rev-list main..feat/feat-x)"
# Snapshot the worktree's parent state before merge — Phase 2 only touches
# main super, so the worktree's repo state must be byte-identical after.
wt_state=$(snapshot_state .worktree/feat-x)
./subgrove merge feat-x >out 2>&1
# Parent main caught up to feat tip.
assert_branch_at . main "feat/feat-x"
# Every feat-branch commit is now an ancestor of main (history correctness).
for sha in $feat_commits; do
    assert_ancestor . "$sha" main "feat commit not in main's history"
done
# Discovery phase fires but resolves to empty.
assert_grep out "touched: \(none\)"
assert_grep out "will merge submodules: \(none\)"
assert_grep out "will merge parent: +true"
assert_grep out "Fast-forwarding parent main"
# Default (push=false) skips push.
assert_grep out "Push skipped \(push=true to enable\)"
# Summary block reflects the truth.
assert_grep out "Submodules merged: +\(none\)"
assert_grep out "Submodules skipped: +\(none\)"
assert_grep out "Parent merged: +true"
assert_grep out "Pushed: +false"
# Worktree retained.
assert_file_exists .worktree/feat-x
assert_state_eq .worktree/feat-x "$wt_state"
# Submodule-phase info lines: with no submodules, the "Moving main
# forward in main worktree's submodules" line MUST NOT fire (Phase 2's
# submodule loop iterates the empty list).
assert_grep_v out "Moving main forward in main worktree's submodules"
cleanup_fixture

# --- case: nothing to merge (feat tip == main tip) ---
mkfixture_local_no_sm merge_nothing
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
main_sha_pre="$(git rev-parse main)"
feat_sha_pre="$(git rev-parse feat/feat-x)"
# Snapshot main super + worktree before the no-op merge — neither location
# should be modified by Phase 0's filter short-circuiting (Principle 4:
# state preservation on no-op paths, not just refuse paths).
main_state=$(snapshot_state .)
wt_state=$(snapshot_state .worktree/feat-x)
./subgrove merge feat-x >out 2>&1
assert_grep out "Nothing to merge"
# Refs unchanged.
assert_eq "$main_sha_pre" "$(git rev-parse main)" "main moved on nothing-to-merge"
assert_eq "$feat_sha_pre" "$(git rev-parse feat/feat-x)" "feat moved on nothing-to-merge"
# Working tree + index unchanged in BOTH locations.
assert_state_eq . "$main_state"
assert_state_eq .worktree/feat-x "$wt_state"
# Phase 1 (parent FF) did NOT run — symmetry with the refuse-path tests.
assert_grep_v out "Fast-forwarding parent main"
# Subgrove has TWO different "Push skipped" strings: "(push=true to
# enable)" when push=false (default), and "(nothing was merged)" when
# push=true but nothing changed. Default + nothing-to-merge takes the
# first branch. Pinning the variant catches a dispatcher-ordering
# regression where the wrong branch fires.
assert_grep out "Push skipped \(push=true to enable\)"
# Summary still prints; parent merged: false.
assert_grep out "Parent merged: +false"
cleanup_fixture

# --- case: dirty parent (dst) refused ---
mkfixture_local_no_sm merge_dirty_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
( cd .worktree/feat-x && echo "feat work" >> README && git add README \
    && git commit --quiet -m "feat-x commit" )
echo "dirty in main super" >> README
assert_pending_file . README unstaged
main_state=$(snapshot_state .)
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty parent dst"
fi
assert_grep out "main worktree \(parent, dst\) has uncommitted"
# State preserved — dirty edit still on disk; parent main not advanced.
assert_state_eq . "$main_state"
assert_pending_file . README unstaged
# Phase 2 didn't run (the "Fast-forwarding parent main" info line must
# not appear when the dirty-check refused).
assert_grep_v out "Fast-forwarding parent main"
cleanup_fixture

# --- case: non-FF parent refused ---
mkfixture_local_no_sm merge_non_ff
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
# Commit on feat first.
( cd .worktree/feat-x && echo "feat" >> README && git add README \
    && git commit --quiet -m "feat" )
# Then commit directly on main super (diverges from feat).
echo "main divergent" >> README
git add README
git commit --quiet -m "main divergent"
main_sha_pre="$(git rev-parse main)"
# Snapshot main super state so a regression that mutates working tree or
# index en route to the FF refusal is caught (not just SHA equality).
main_state=$(snapshot_state .)
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on non-FF parent"
fi
assert_grep out "parent main is not ancestor of feat/feat-x \(non-FF\)"
assert_eq "$main_sha_pre" "$(git rev-parse main)" "main moved on non-FF refuse"
assert_state_eq . "$main_state"
# Phase 2 didn't run.
assert_grep_v out "Fast-forwarding parent main"
cleanup_fixture

# --- case: merge push=true on no-origin super ---
# The half-state to pin: (a) parent main is advanced LOCALLY in Phase 1,
# (b) push fails because no `origin` is configured, (c) the local advance
# is PRESERVED on disk after the failed push. push is a separate phase
# that doesn't roll back the local merge. Each of (a)/(b)/(c) is asserted
# distinctly below so a regression in any of them is visible.
mkfixture_local_no_sm merge_push_no_origin
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
( cd .worktree/feat-x && echo "feat work" >> README && git add README \
    && git commit --quiet -m "feat-x commit" )
feat_sha="$(git rev-parse feat/feat-x)"
if ./subgrove merge feat-x push=true >out 2>&1; then
    fail "expected merge push=true to fail with no origin"
fi
# (a) Phase 1 ran (local FF info line appears).
assert_grep out "Fast-forwarding parent main"
# (b) Phase 3 ran and failed with git's "origin does not appear" message.
assert_grep out "Pushing updated main branches to origin"
assert_grep out "'origin' does not appear"
# (c) AFTER the failed push, parent main is still at feat_sha. Explicitly
# re-read the SHA post-call so the "preserved across push failure"
# semantic is visible to a reader (not just implied by call ordering).
main_sha_after_push="$(git rev-parse main)"
assert_eq "$feat_sha" "$main_sha_after_push" \
    "parent main should remain advanced after push failure (push-after-merge does not roll back)"
cleanup_fixture

# Note: an explicit `push=false` scenario is intentionally NOT here.
# push=false IS the default, so the golden case above already exercises
# the explicit-false code path. A separate test would only duplicate
# assertions without exercising a new branch.

# --- case: nonexistent branch errs ---
mkfixture_local_no_sm merge_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove merge never-existed >out 2>&1; then
    fail "expected merge to err on nonexistent branch name"
fi
# Pin the specific err-text (don't just check exit code).
assert_grep out "does not exist"
cleanup_fixture

# --- case: submodule-phase info lines absent (two-peer scenario) ---
# Create two peer worktrees; commit on the feature in one; merge it. The
# peer-propagation phase exists to push the new submodule mains to other
# worktrees — with zero submodules, nothing to propagate, so the
# "Propagating new main to peer worktrees" info line must not fire.
mkfixture_local_no_sm merge_no_peer_prop
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
./subgrove new feat-y >/dev/null 2>&1
( cd .worktree/feat-x && echo "feat work" >> README && git add README \
    && git commit --quiet -m "feat-x commit" )
./subgrove merge feat-x >out 2>&1
# Negative-assert: the peer-propagation info line and the submodule-move
# line must NOT fire.
assert_grep_v out "Propagating new main to peer worktrees"
assert_grep_v out "Moving main forward in main worktree's submodules"
# Positive-assert: Phase 1 DID run (symmetry with merge_golden) — parent
# merge isn't being silently skipped by an over-eager early-return.
assert_grep out "Fast-forwarding parent main"
# Parent merge still succeeded.
assert_grep out "Parent merged: +true"
cleanup_fixture
