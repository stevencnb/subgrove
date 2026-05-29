#!/usr/bin/env bash
# Tests for `subgrove merge`.
#
# Note: `merge push=true` paths are NOT exercised here. The local fixture's
# super has no `origin` configured (since it's never cloned from anywhere),
# so push has nothing to target. push=true is covered by the remote tests.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# --- case: golden ---
mkfixture_local merge_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
commit_one .worktree/feat-x/sm-b "sm-b change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump sm SHAs" )

# --- PRE-merge state ---
# Main super is clean, no commits ahead (subgrove plumbing is the baseline).
assert_clean .
assert_clean sm-a
assert_clean sm-b
assert_commits_ahead . main feat/feat-x 1 "feat parent has the bump commit"
# Worktree side has commits but is clean (we committed everything).
assert_clean .worktree/feat-x
assert_clean .worktree/feat-x/sm-a
assert_clean .worktree/feat-x/sm-b
assert_commits_ahead .worktree/feat-x/sm-a main feat/feat-x 1 "sm-a feat has 1 commit"
assert_commits_ahead .worktree/feat-x/sm-b main feat/feat-x 1 "sm-b feat has 1 commit"

feat_super="$(git -C .worktree/feat-x rev-parse feat/feat-x)"
feat_a="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
feat_b="$(git -C .worktree/feat-x/sm-b rev-parse feat/feat-x)"

# Capture commits that should land in main after FF (verify history, not just tip)
feat_p_commits="$(git -C .worktree/feat-x rev-list main..feat/feat-x)"
feat_a_commits="$(git -C .worktree/feat-x/sm-a rev-list main..feat/feat-x)"
feat_b_commits="$(git -C .worktree/feat-x/sm-b rev-list main..feat/feat-x)"

# Capture worktree state — the worktree should be retained EXACTLY as-is
wt_state_p="$(snapshot_state .worktree/feat-x)"
wt_state_a="$(snapshot_state .worktree/feat-x/sm-a)"
wt_state_b="$(snapshot_state .worktree/feat-x/sm-b)"

# Before merge, status should report feat-x one commit ahead of main
# (and read-only — it must not disturb the state snapshotted just above).
./subgrove status >out 2>&1
assert_grep out "↑1"

./subgrove merge feat-x >out 2>&1

# --- POST-merge state ---
# Main super is now at feat tips, still clean (working tree updated to feat).
assert_clean .
assert_clean sm-a
assert_clean sm-b
# Feat is no longer ahead of main — main caught up.
assert_commits_ahead . main feat/feat-x 0 "main caught up to feat"
assert_commits_ahead . feat/feat-x main 0 "and vice versa (tip equality)"

# Tip equality
assert_branch_at . main "$feat_super"
assert_branch_at sm-a main "$feat_a"
assert_branch_at sm-b main "$feat_b"

# Merged submodules are re-attached to main, not left detached at the right
# SHA — the property `checkout -B main` exists to guarantee (merge.md step 6).
# The SHA-only assert_branch_at above passes even on a detached HEAD.
assert_head_on sm-a main
assert_head_on sm-b main

# History: every commit between old main and feat tip is now in main's history
for sha in $feat_p_commits; do assert_ancestor . "$sha" main; done
for sha in $feat_a_commits; do assert_ancestor sm-a "$sha" main; done
for sha in $feat_b_commits; do assert_ancestor sm-b "$sha" main; done

# Parent's tree records the new submodule SHAs (verifies the parent commit
# captured the bumps, not just that the parent's main moved)
[[ "$(git ls-tree main sm-a | awk '{print $3}')" == "$feat_a" ]] \
    || fail "parent's tree should record sm-a at feat tip"
[[ "$(git ls-tree main sm-b | awk '{print $3}')" == "$feat_b" ]] \
    || fail "parent's tree should record sm-b at feat tip"

# Worktree retained — full state unchanged
assert_file_exists .worktree/feat-x
assert_state_eq .worktree/feat-x       "$wt_state_p"
assert_state_eq .worktree/feat-x/sm-a  "$wt_state_a"
assert_state_eq .worktree/feat-x/sm-b  "$wt_state_b"
# User-visible summary block names every merged submodule and the parent.
assert_grep out "Submodules merged: *sm-a sm-b"
assert_grep out "Parent merged: *true"
assert_grep out "Pushed: *false"
# Info lines reflect the actual phases that ran.
assert_grep out "Moving main forward in main worktree's submodules"
assert_grep out "Fast-forwarding parent main"
# After merge, main caught up to feat — status no longer reports feat-x ahead.
./subgrove status >out 2>&1
assert_grep out "feat-x"
assert_grep_v out "↑1"
cleanup_fixture

# --- case: nothing to merge — every location's state preserved ---
mkfixture_local merge_nothing
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
# Snapshot all six locations BEFORE merge.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-y)"
state_wt_a="$(snapshot_state .worktree/feat-y/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-y/sm-b)"
./subgrove merge feat-y >out 2>&1
assert_grep out "Nothing to merge"
# Nothing should have moved anywhere.
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-y      "$state_wt_p"
assert_state_eq .worktree/feat-y/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-y/sm-b "$state_wt_b"
# Summary block still printed even when nothing merged. With the default
# touch=all, sm-a and sm-b were discovered as "touched" (they have feat
# branches from `subgrove new`) but filtered into `skipped` because their
# feat tip already equals main tip. So skipped lists both submodules.
assert_grep out "Submodules merged: *\(none\)"
assert_grep out "Submodules skipped: *sm-a sm-b"
assert_grep out "Parent merged: *false"
# §15: status reflects the resulting state. Nothing-to-merge retains the
# worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: partial — only one submodule has changes ---
mkfixture_local merge_partial
cd "$FIXTURE_SUPER"
./subgrove new feat-p >out 2>&1
commit_one .worktree/feat-p/sm-a "sm-a change"
( cd .worktree/feat-p && git add -A && git commit --quiet -m "bump sm-a" )

feat_p="$(git -C .worktree/feat-p rev-parse feat/feat-p)"
feat_a="$(git -C .worktree/feat-p/sm-a rev-parse feat/feat-p)"
feat_a_commits="$(git -C .worktree/feat-p/sm-a rev-list main..feat/feat-p)"
sm_b_state_before="$(snapshot_state sm-b)"
wt_state_p="$(snapshot_state .worktree/feat-p)"
wt_state_a="$(snapshot_state .worktree/feat-p/sm-a)"
wt_state_b="$(snapshot_state .worktree/feat-p/sm-b)"

./subgrove merge feat-p >out 2>&1
# Parent main caught up (the bump commit landed).
assert_branch_at . main "$feat_p"
# sm-a advanced; every feat commit is now in main's history.
assert_branch_at sm-a main "$feat_a"
for sha in $feat_a_commits; do assert_ancestor sm-a "$sha" main; done
# sm-b in the skipped list — state totally unchanged.
assert_state_eq sm-b "$sm_b_state_before"
# Worktree retained as-is across all three locations.
assert_state_eq .worktree/feat-p      "$wt_state_p"
assert_state_eq .worktree/feat-p/sm-a "$wt_state_a"
assert_state_eq .worktree/feat-p/sm-b "$wt_state_b"
# Specific skip line names sm-b (not just any word containing "skip").
assert_grep out "skip \(no commits\):.*sm-b"
# §15: status reflects the resulting state. The worktree is retained after a
# successful merge.
assert_status feat-p "feat/feat-p"
cleanup_fixture

# --- case: dirty parent (dst) — no submodule mains advance (two-phase) ---
mkfixture_local merge_dirty_dst_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
commit_one .worktree/feat-x/sm-b "sm-b change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )
echo "dirty" >> README

# --- PRE-merge state: main super README dirty, everything else clean.
#     Feat branch is +1 commit on parent + each submodule. ---
assert_pending_file . README unstaged "README is unstaged-modified in main super"
assert_clean sm-a
assert_clean sm-b
assert_clean .worktree/feat-x
assert_clean .worktree/feat-x/sm-a
assert_clean .worktree/feat-x/sm-b
assert_commits_ahead . main feat/feat-x 1 "feat parent has the bump commit"
assert_commits_ahead .worktree/feat-x/sm-a main feat/feat-x 1
assert_commits_ahead .worktree/feat-x/sm-b main feat/feat-x 1
# Snapshot full state of all 6 locations BEFORE merge
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty parent (dst)"
fi
# Err names the specific affected location (catches label-swap regressions).
assert_grep out "main worktree \(parent, dst\) has uncommitted"

# --- POST-merge state: identical to pre. README is STILL unstaged-modified;
#     no commit landed in main; no submodule moved; worktree untouched.
assert_pending_file . README unstaged "README still unstaged after refuse"
assert_clean sm-a
assert_clean sm-b
assert_clean .worktree/feat-x
assert_clean .worktree/feat-x/sm-a
assert_clean .worktree/feat-x/sm-b
assert_commits_ahead . main feat/feat-x 1 "feat still has 1 commit (not merged)"
# Everything unchanged — refs AND working tree AND index AND the dirty edit.
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-x      "$state_wt_p"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: dirty submodule (dst, sm-a) refused — full state preservation ---
mkfixture_local merge_dirty_dst_sm
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )
echo "dirty" >> sm-a/README
# Full 6-location snapshot before merge.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty submodule (dst)"
fi
assert_grep out "main submodule 'sm-a' \(dst\) has uncommitted"
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-x      "$state_wt_p"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"
# Phase 1 didn't run on the dirty refusal — main super's submodules
# don't have a feat-x branch (Phase 1 would have fetched it).
assert_no_branch sm-a feat/feat-x
assert_no_branch sm-b feat/feat-x
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: dirty submodule (dst, sm-b) refused — symmetry with sm-a ---
mkfixture_local merge_dirty_dst_sm_b
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-b "sm-b change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )
echo "dirty" >> sm-b/README
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty submodule (dst, sm-b)"
fi
assert_grep out "main submodule 'sm-b' \(dst\) has uncommitted"
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-x      "$state_wt_p"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"
assert_no_branch sm-a feat/feat-x
assert_no_branch sm-b feat/feat-x
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: non-FF parent ---
mkfixture_local merge_nonff_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x "feat parent commit"
echo "main-side parent change" >> README
git add README
git commit --quiet -m "main-side parent"
# Full state snapshot — main's SHA alone isn't enough; verify ALL refs +
# working trees + indices stay put across the refuse.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on non-FF parent"
fi
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-x      "$state_wt_p"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: non-FF submodule (two-phase invariant) ---
# sm-b's main is divergent. The merge MUST refuse without having moved
# sm-a's main first. The divergence is staged via a detached-HEAD trick so
# the parent stays clean (otherwise the Phase 0 dirty check would fire
# before the Phase 1 FF check we're trying to exercise).
mkfixture_local merge_two_phase
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a feat change"
commit_one .worktree/feat-x/sm-b "sm-b feat change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )
(
    cd sm-b
    git checkout --quiet --detach
    new_sha="$(git commit-tree -m diverge -p main "$(git rev-parse main^{tree})")"
    git update-ref refs/heads/main "$new_sha"
)

# --- PRE-merge state ---
# Main super parent + sm-a clean. sm-b has a forged-divergent main (its
# refs/heads/main is now 1 commit ahead of its earlier baseline) but the
# working tree is at the detached baseline SHA → no pending changes there.
sm_a_main_before="$(git -C sm-a rev-parse main)"
sm_b_main_before="$(git -C sm-b rev-parse main)"
assert_clean .
assert_clean sm-a
assert_clean sm-b
# Worktree side has commits and is clean.
assert_clean .worktree/feat-x
assert_clean .worktree/feat-x/sm-a
assert_clean .worktree/feat-x/sm-b
assert_commits_ahead .worktree/feat-x/sm-a main feat/feat-x 1
assert_commits_ahead .worktree/feat-x/sm-b main feat/feat-x 1
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on non-FF sm-b"
fi

# --- POST-merge state: THE two-phase invariant ---
# sm-a's main UNCHANGED (Phase 2 never ran for any module).
# sm-b's main UNCHANGED (forged-divergent SHA still there).
# Both still clean.
assert_branch_at sm-a main "$sm_a_main_before"
assert_branch_at sm-b main "$sm_b_main_before"
assert_clean sm-a
assert_clean sm-b
assert_state_eq sm-a "$state_main_a"
assert_state_eq sm-b "$state_main_b"
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: peer propagation (clean peer) ---
mkfixture_local merge_peer_clean
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
./subgrove new feat-y >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )

# Peer feat-y has no changes — sm-b in particular should be untouched
# because only sm-a is in needs_merge for the propagation loop.
feat_y_sm_b_state="$(snapshot_state .worktree/feat-y/sm-b)"

./subgrove merge feat-x >out 2>&1

feat_a="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
assert_branch_at .worktree/feat-y/sm-a main "$feat_a"
# Clean propagation (no peer refused) → no tagged notice section.
assert_grep_v out "ATTENTION"
assert_grep_v out "NEXT STEPS"
# Peer's sm-b not in needs_merge — totally unchanged.
assert_state_eq .worktree/feat-y/sm-b "$feat_y_sm_b_state"
# §15: status reflects the resulting state. Both the merged and peer
# worktrees are retained.
assert_status feat-x "feat/feat-x"
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: peer with main checked out → propagation skipped ---
mkfixture_local merge_peer_main_co
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
./subgrove new feat-y >out 2>&1
( cd .worktree/feat-y/sm-a && git checkout --quiet main )
peer_main_before="$(git -C .worktree/feat-y/sm-a rev-parse main)"
peer_state_before="$(snapshot_state .worktree/feat-y/sm-a)"

commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )

./subgrove merge feat-x >out 2>&1
assert_grep out "main checked out"
# The refused propagation is surfaced under the tagged ATTENTION section.
assert_grep out "ATTENTION"
peer_main_after="$(git -C .worktree/feat-y/sm-a rev-parse main)"
assert_eq "$peer_main_before" "$peer_main_after"
# Full state preserved — HEAD still on main, working tree at original SHA.
assert_state_eq .worktree/feat-y/sm-a "$peer_state_before"
# §15: status reflects the resulting state. Both worktrees are retained; the
# feat-y parent is still on its feat branch (only its sm-a was on main).
assert_status feat-x "feat/feat-x"
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: peer's main diverged → propagation skipped; forged SHA preserved ---
mkfixture_local merge_peer_diverged
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
./subgrove new feat-y >out 2>&1
forged_sha=$(
    cd .worktree/feat-y/sm-a
    new_sha="$(git commit-tree -m diverge -p main "$(git rev-parse main^{tree})")"
    git update-ref refs/heads/main "$new_sha"
    echo "$new_sha"
)
peer_state_before="$(snapshot_state .worktree/feat-y/sm-a)"

commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )

./subgrove merge feat-x >out 2>&1
assert_grep out "diverged"
# The refused propagation is surfaced under the tagged ATTENTION section.
assert_grep out "ATTENTION"
# Peer's main is STILL at the forged SHA — propagation didn't clobber it.
assert_branch_at .worktree/feat-y/sm-a main "$forged_sha"
# Full state preserved (HEAD on feat/feat-y, working tree at feat tip).
assert_state_eq .worktree/feat-y/sm-a "$peer_state_before"
# §15: status reflects the resulting state. Both worktrees are retained.
assert_status feat-x "feat/feat-x"
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: nonexistent branch refused ---
mkfixture_local merge_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove merge never-existed >out 2>&1; then
    fail "expected merge to fail on nonexistent name"
fi
# §15: status reflects the resulting state. No worktree was ever created.
assert_status "no feature worktrees yet"
cleanup_fixture

# --- case: parent-only commit (touch=none) ---
# Exercises the code path where parent_needs_merge=true but needs_merge is
# empty. Phase 1's submodule loop doesn't iterate; Phase 1's parent FF
# check runs alone; Phase 2's submodule loop is empty; parent FF-merge
# advances main.
mkfixture_local merge_parent_only
cd "$FIXTURE_SUPER"
./subgrove new feat-x touch=none >out 2>&1
# touch=none leaves submodules detached without feat branches.
assert_no_branch .worktree/feat-x/sm-a feat/feat-x
assert_no_branch .worktree/feat-x/sm-b feat/feat-x

commit_one .worktree/feat-x "parent-only change"
feat_parent="$(git -C .worktree/feat-x rev-parse feat/feat-x)"
feat_commits="$(git -C .worktree/feat-x rev-list main..feat/feat-x)"
sm_a_main_before="$(git -C sm-a rev-parse main)"
sm_b_main_before="$(git -C sm-b rev-parse main)"

./subgrove merge feat-x >out 2>&1

# Parent main caught up; every feat commit reachable from new main.
assert_branch_at . main "$feat_parent"
for sha in $feat_commits; do assert_ancestor . "$sha" main; done
# No submodule mains moved — none were in needs_merge.
assert_branch_at sm-a main "$sm_a_main_before"
assert_branch_at sm-b main "$sm_b_main_before"
# Summary reflects the parent-only merge accurately.
assert_grep out "Submodules merged: *\(none\)"
assert_grep out "Parent merged: *true"
# §15: status reflects the resulting state. The worktree is retained after a
# successful merge.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: dirty source parent (feature worktree) refused ---
mkfixture_local merge_dirty_src_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )
echo "dirty src" >> .worktree/feat-x/README
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty src parent"
fi
assert_grep out "feature worktree \(parent, src\) has uncommitted"
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-x      "$state_wt_p"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"
assert_no_branch sm-a feat/feat-x
assert_no_branch sm-b feat/feat-x
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: dirty source submodule (feature worktree) refused ---
mkfixture_local merge_dirty_src_sm
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )
echo "dirty src" >> .worktree/feat-x/sm-a/README
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"
if ./subgrove merge feat-x >out 2>&1; then
    fail "expected merge to refuse on dirty src submodule"
fi
assert_grep out "feature submodule 'sm-a' \(src\) has uncommitted"
assert_state_eq .                     "$state_main_p"
assert_state_eq sm-a                  "$state_main_a"
assert_state_eq sm-b                  "$state_main_b"
assert_state_eq .worktree/feat-x      "$state_wt_p"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"
assert_no_branch sm-a feat/feat-x
assert_no_branch sm-b feat/feat-x
# §15: status reflects the resulting state. A refused merge retains the
# worktree.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: peer propagation reaches multiple peer worktrees ---
mkfixture_local merge_multi_peer
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
./subgrove new feat-y >out 2>&1
./subgrove new feat-z >out 2>&1
commit_one .worktree/feat-x/sm-a "sm-a change"
( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump" )

# Both peers' sm-b should be untouched — only sm-a is in needs_merge.
feat_y_sm_b_state="$(snapshot_state .worktree/feat-y/sm-b)"
feat_z_sm_b_state="$(snapshot_state .worktree/feat-z/sm-b)"
sm_b_main_before="$(git -C sm-b rev-parse main)"

./subgrove merge feat-x >out 2>&1

feat_a="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
feat_parent="$(git -C .worktree/feat-x rev-parse feat/feat-x)"
# Main super advanced for parent + sm-a; sm-b stays put (no commits there).
assert_branch_at . main "$feat_parent"
assert_branch_at sm-a main "$feat_a"
assert_branch_at sm-b main "$sm_b_main_before"
# Both peers' sm-a advanced; both peers' sm-b unchanged.
assert_branch_at .worktree/feat-y/sm-a main "$feat_a"
assert_branch_at .worktree/feat-z/sm-a main "$feat_a"
assert_state_eq .worktree/feat-y/sm-b "$feat_y_sm_b_state"
assert_state_eq .worktree/feat-z/sm-b "$feat_z_sm_b_state"
# §15: status reflects the resulting state. All three worktrees are retained.
assert_status feat-x "feat/feat-x"
assert_status feat-y "feat/feat-y"
assert_status feat-z "feat/feat-z"
cleanup_fixture

# --- case: custom WORKTREES_DIR — new + merge + peer propagation honor it ---
# The worktree dir is a config knob (WORKTREES_DIR), not a hardcoded .worktree/.
# This exercises the most knob-sensitive path: merge's peer scan iterates
# $ROOT/$WORKTREES_DIR/*, so a peer worktree under the custom folder must
# still receive the propagated submodule main. Also pins that .worktree/ is
# never touched when the knob points elsewhere.
mkfixture_local merge_custom_wtdir
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
WORKTREES_DIR="wt"
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
printf 'wt/\n' >> .gitignore       # the configured folder must be gitignored too
mkdir wt                           # exist-on-disk so `git check-ignore wt` matches wt/
git add .subgroverc .gitignore
git commit --quiet -m "custom WORKTREES_DIR=wt"
./subgrove new feat-x >out 2>&1
./subgrove new feat-y >out 2>&1
# Worktrees landed under wt/, never the default .worktree/.
assert_file_exists wt/feat-x
assert_file_exists wt/feat-y
assert_file_absent .worktree/feat-x
assert_file_absent .worktree/feat-y
commit_one wt/feat-x/sm-a "sm-a change"
( cd wt/feat-x && git add -A && git commit --quiet -m "bump" )
./subgrove merge feat-x >out 2>&1
feat_a="$(git -C wt/feat-x/sm-a rev-parse feat/feat-x)"
# Main worktree's sm-a advanced...
assert_branch_at sm-a main "$feat_a"
# ...and the peer under the custom folder received propagation.
assert_branch_at wt/feat-y/sm-a main "$feat_a"
# §15: status reflects the resulting state (status reads WORKTREES_DIR, so it
# finds both worktrees under the configured folder).
assert_status feat-x "feat/feat-x"
assert_status feat-y "feat/feat-y"
cleanup_fixture
