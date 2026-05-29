#!/usr/bin/env bash
# Tests for `subgrove update`.
#
# Note: super has no `origin` configured in the local fixture. cmd_update's
# parent-level fetch falls through with a warn, but each main-worktree
# submodule HAS its own file:// origin (pointing at the sibling sm-X repo
# under $FIXTURE_ROOT). Simulating "someone pushed upstream" is just a
# direct commit in the sibling — subgrove's fetch picks it up via file://.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# --- case: happy path — peer catches up to new origin/main ---
mkfixture_local update_happy
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
# Capture feat-y/sm-b's main BEFORE — sibling sm-b doesn't move, so this
# should be unchanged after update.
sm_b_main_before="$(git -C .worktree/feat-y/sm-b rev-parse main)"
# Capture the feature branch tip too — without rebase=ff, update is ref-only
# and must NOT advance the checked-out feature branch (only main).
feat_a_before="$(git -C .worktree/feat-y/sm-a rev-parse feat/feat-y)"
# Move sibling sm-a's main forward; subgrove will fetch this into main
# super's sm-a, then propagate via the _update_sync sentinel.
commit_one "$FIXTURE_ROOT/sm-a" "upstream change"
new_main="$(git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
./subgrove update feat-y >out 2>&1
assert_branch_at .worktree/feat-y/sm-a main "$new_main"
# sm-b in the peer is untouched — sibling sm-b didn't get a new commit.
assert_branch_at .worktree/feat-y/sm-b main "$sm_b_main_before"
# Default (no rebase=ff): feature branch left exactly where it was, and the
# manual-rebase hint is printed rather than any branch being auto-advanced.
assert_branch_at .worktree/feat-y/sm-a feat/feat-y "$feat_a_before"
assert_grep out "git submodule foreach 'git rebase main'"
# The manual-rebase hint is surfaced under the tagged NEXT STEPS section.
assert_grep out "NEXT STEPS"
assert_grep_v out "Fast-forwarding feature branches"
# §15: status reflects the resulting state. update is ref-only and retains
# the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: _update_sync sentinel cleaned up on success ---
# Verifies both (a) update actually ran (FF-update info line emitted) and
# (b) the sentinel was cleaned up afterward — the absence-of-sentinel
# assertion alone would pass trivially if update were a complete no-op.
mkfixture_local update_sentinel_clean
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
./subgrove update feat-y >out 2>&1
assert_grep out "FF-updating peer worktree"
if git -C sm-a rev-parse --verify --quiet refs/heads/_update_sync >/dev/null 2>&1; then
    fail "_update_sync ref leaked after update (clean run)"
fi
if git -C sm-b rev-parse --verify --quiet refs/heads/_update_sync >/dev/null 2>&1; then
    fail "_update_sync ref leaked after update (clean run)"
fi
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: pre-existing _update_sync ref cleaned up ---
mkfixture_local update_sentinel_pre
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
git -C sm-a update-ref refs/heads/_update_sync "$(git -C sm-a rev-parse main)"
./subgrove update feat-y >out 2>&1
if git -C sm-a rev-parse --verify --quiet refs/heads/_update_sync >/dev/null 2>&1; then
    fail "_update_sync ref leaked after update (pre-existing case)"
fi
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: peer with main checked out → skipped ---
mkfixture_local update_peer_main_co
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
( cd .worktree/feat-y/sm-a && git checkout --quiet main )
peer_main_before="$(git -C .worktree/feat-y/sm-a rev-parse main)"
peer_state_before="$(snapshot_state .worktree/feat-y/sm-a)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream change"
./subgrove update feat-y >out 2>&1
assert_grep out "main checked out"
# The skip is surfaced under the tagged ATTENTION section.
assert_grep out "ATTENTION"
peer_main_after="$(git -C .worktree/feat-y/sm-a rev-parse main)"
assert_eq "$peer_main_before" "$peer_main_after"
# Full state preserved (HEAD on main, working tree clean at original SHA).
assert_state_eq .worktree/feat-y/sm-a "$peer_state_before"
# §15: status reflects the resulting state. The worktree is retained; its
# parent is still on feat/feat-y (only its sm-a was on main).
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: peer's main diverged → skipped; forged SHA preserved ---
mkfixture_local update_peer_diverged
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
forged_sha=$(
    cd .worktree/feat-y/sm-a
    new_sha="$(git commit-tree -m diverge -p main "$(git rev-parse main^{tree})")"
    git update-ref refs/heads/main "$new_sha"
    echo "$new_sha"
)
peer_state_before="$(snapshot_state .worktree/feat-y/sm-a)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream change"
./subgrove update feat-y >out 2>&1
assert_grep out "diverged"
# The skip is surfaced under the tagged ATTENTION section.
assert_grep out "ATTENTION"
# Peer's main is STILL at the forged SHA — the sentinel fetch refused
# rather than clobbering it.
assert_branch_at .worktree/feat-y/sm-a main "$forged_sha"
# Full state preserved.
assert_state_eq .worktree/feat-y/sm-a "$peer_state_before"
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: no refs/remotes/origin/main → skipped with warn ---
# Strip origin from main super's submodules to simulate "user didn't
# configure a remote on the submodules either." cmd_update should warn
# and skip rather than fail. Peer mains must NOT move.
mkfixture_local update_no_origin
cd "$FIXTURE_SUPER"
git -C sm-a remote remove origin
git -C sm-b remote remove origin
./subgrove new feat-y >out 2>&1
peer_a_main_before="$(git -C .worktree/feat-y/sm-a rev-parse main)"
peer_b_main_before="$(git -C .worktree/feat-y/sm-b rev-parse main)"
peer_a_state="$(snapshot_state .worktree/feat-y/sm-a)"
peer_b_state="$(snapshot_state .worktree/feat-y/sm-b)"
./subgrove update feat-y >out 2>&1
assert_grep out "no refs/remotes/origin/main"
assert_branch_at .worktree/feat-y/sm-a main "$peer_a_main_before"
assert_branch_at .worktree/feat-y/sm-b main "$peer_b_main_before"
# Full state preserved on both peer submodules.
assert_state_eq .worktree/feat-y/sm-a "$peer_a_state"
assert_state_eq .worktree/feat-y/sm-b "$peer_b_state"
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: doesn't require clean state — and dirty edit is preserved ---
# cmd_update is ref-only. A dirty edit in the peer's submodule working
# tree should still be there after update.
mkfixture_local update_dirty_ok
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
echo "dirty" >> .worktree/feat-y/sm-a/README
assert_pending_file .worktree/feat-y/sm-a README unstaged
state_peer_a="$(snapshot_state .worktree/feat-y/sm-a)"
./subgrove update feat-y >out 2>&1
# Dirty edit + HEAD + index preserved (refs/heads/main may have moved,
# but snapshot_state doesn't include refs).
assert_pending_file .worktree/feat-y/sm-a README unstaged
assert_state_eq .worktree/feat-y/sm-a "$state_peer_a"
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: nonexistent name refused ---
mkfixture_local update_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove update never-existed >out 2>&1; then
    fail "expected update to fail on nonexistent name"
fi
# §15: status reflects the resulting state. No worktree was ever created.
assert_status "no feature worktrees yet"
cleanup_fixture

# --- case: multiple submodules update in one run ---
# Both sibling sm-a and sm-b get new upstream commits. After update, both
# peer submodules' main refs should advance independently. cmd_update is
# ref-only on submodules — parent main must NOT move.
mkfixture_local update_multi_sm
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
parent_main_before="$(git rev-parse main)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream sm-a"
commit_one "$FIXTURE_ROOT/sm-b" "upstream sm-b"
new_sm_a="$(git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
new_sm_b="$(git -C "$FIXTURE_ROOT/sm-b" rev-parse main)"
./subgrove update feat-y >out 2>&1
assert_branch_at .worktree/feat-y/sm-a main "$new_sm_a"
assert_branch_at .worktree/feat-y/sm-b main "$new_sm_b"
# Parent main never moves during update.
assert_branch_at . main "$parent_main_before"
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: dirty main super doesn't block update — and dirty preserved ---
# cmd_update is ref-only and doesn't `require_clean`. Dirty state in the
# main super (parent + both submodules) should not prevent update, and
# every dirty edit must still be on disk afterward. Peer worktree's
# parent + sm-b state must also be untouched (only sm-a's main moves).
mkfixture_local update_dirty_super_ok
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
echo "dirty parent" >> README
echo "dirty sm-a" >> sm-a/README
echo "dirty sm-b" >> sm-b/README
assert_pending_file .    README unstaged
assert_pending_file sm-a README unstaged
assert_pending_file sm-b README unstaged
peer_parent_state="$(snapshot_state .worktree/feat-y)"
peer_sm_b_state="$(snapshot_state .worktree/feat-y/sm-b)"
# Main super's submodule states should be preserved across update — the
# fetch into refs/remotes/origin/main doesn't touch HEAD or working tree.
# snapshot_state doesn't include refs, so the ref-only update is invisible
# to state_eq.
main_sm_a_state="$(snapshot_state sm-a)"
main_sm_b_state="$(snapshot_state sm-b)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream sm-a"
new_main="$(git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
./subgrove update feat-y >out 2>&1
assert_branch_at .worktree/feat-y/sm-a main "$new_main"
# Dirty edits in main super preserved across update.
assert_pending_file .    README unstaged
assert_pending_file sm-a README unstaged
assert_pending_file sm-b README unstaged
# Main super's submodules — HEAD + working tree + index unchanged.
assert_state_eq sm-a "$main_sm_a_state"
assert_state_eq sm-b "$main_sm_b_state"
# Peer worktree's parent + sm-b untouched (only sm-a was supposed to move).
assert_state_eq .worktree/feat-y      "$peer_parent_state"
assert_state_eq .worktree/feat-y/sm-b "$peer_sm_b_state"
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: pre-existing _update_sync is a USER branch (not a stale sentinel) ---
# The defensive pre-clean must NOT delete a real branch named _update_sync.
# A stale sentinel was written pointing at origin/main, so it's reachable from
# the current origin/main; a user branch with independent work is not. Here
# main super's sm-a has such a user branch (forged as a child of main, so
# unreachable from origin/main) → sm-a is skipped and the branch preserved,
# while sm-b (no collision, origin advanced) still updates — proving the run
# continues past the skip.
mkfixture_local update_sentinel_user_branch
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
# Forge _update_sync at a commit NOT reachable from origin/main (a child of
# main), without moving main. Same commit-tree idiom as update_peer_diverged.
forged_sha=$(
    cd sm-a
    new_sha="$(git commit-tree -m user-work -p main "$(git rev-parse main^{tree})")"
    git update-ref refs/heads/_update_sync "$new_sha"
    echo "$new_sha"
)
peer_sm_a_main_before="$(git -C .worktree/feat-y/sm-a rev-parse main)"
# sm-b has no collision; advance its origin so it actually updates.
commit_one "$FIXTURE_ROOT/sm-b" "upstream sm-b"
new_sm_b="$(git -C "$FIXTURE_ROOT/sm-b" rev-parse main)"
./subgrove update feat-y >out 2>&1
# sm-a skipped; its user _update_sync branch still at the forged SHA.
assert_grep out "sm-a.*not a stale sentinel"
assert_branch_at sm-a _update_sync "$forged_sha"
# sm-a's peer main did NOT move (skipped).
assert_branch_at .worktree/feat-y/sm-a main "$peer_sm_a_main_before"
# sm-b: no collision, origin advanced → peer main FF'd (run continued).
assert_branch_at .worktree/feat-y/sm-b main "$new_sm_b"
# Summary: 1 updated (sm-b), 1 skipped (sm-a).
assert_grep out "Updated 1 submodule main\(s\); 1 skipped"
# §15: status reflects the resulting state. update retains the worktree.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: rebase=ff fast-forwards a branch with nothing to replay ---
# feat/feat-y has no commits of its own, so once update advances main the
# branch is a strict fast-forward — rebase=ff advances it (and the working
# tree) automatically; nothing is left for a manual rebase.
mkfixture_local update_rebase_ff
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
commit_one "$FIXTURE_ROOT/sm-a" "upstream change"
new_main="$(git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
./subgrove update feat-y rebase=ff >out 2>&1
# Both the ref-only main advance AND the feature-branch fast-forward landed.
assert_branch_at .worktree/feat-y/sm-a main "$new_main"
assert_branch_at .worktree/feat-y/sm-a feat/feat-y "$new_main"
# FF moved the branch, did not detach HEAD.
assert_head_on .worktree/feat-y/sm-a feat/feat-y
# sm-a fast-forwarded; sm-b had no upstream movement → already current.
assert_grep out "Fast-forwarded 1;"
assert_grep out "All feature branches caught up"
# Nothing outstanding → no manual-rebase hint, and no tagged notice section.
assert_grep_v out "git submodule foreach 'git rebase main'"
assert_grep_v out "NEXT STEPS"
assert_grep_v out "ATTENTION"
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: rebase=ff leaves a branch with commits to replay for manual rebase ---
# A real feature commit on sm-a's branch + an independent upstream advance
# makes the branch diverge from the new main. rebase=ff refuses to rewrite
# it (that's a real rebase, the user's call) and points at the manual hint.
mkfixture_local update_rebase_ff_diverged
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
commit_one .worktree/feat-y/sm-a "feature work"
feat_a="$(git -C .worktree/feat-y/sm-a rev-parse feat/feat-y)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream change"
new_main="$(git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
./subgrove update feat-y rebase=ff >out 2>&1
# main advanced (ref-only step), feature branch left exactly where it was.
assert_branch_at .worktree/feat-y/sm-a main "$new_main"
assert_branch_at .worktree/feat-y/sm-a feat/feat-y "$feat_a"
assert_grep out "sm-a.*commit\(s\) to replay"
# Per-submodule reason under ATTENTION; the manual-rebase hint under NEXT STEPS.
assert_grep out "ATTENTION"
assert_grep out "Rebase the remaining"
assert_grep out "NEXT STEPS"
assert_grep out "git submodule foreach 'git rebase main'"
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: rebase=ff skips a fast-forwardable but dirty tree ---
# The branch *could* fast-forward, but the peer's working tree is dirty.
# rebase=ff must not touch it (update never clobbers pending edits) and
# must leave it for a manual rebase with the dirty edit preserved.
mkfixture_local update_rebase_ff_dirty
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
feat_a_before="$(git -C .worktree/feat-y/sm-a rev-parse feat/feat-y)"
commit_one "$FIXTURE_ROOT/sm-a" "upstream change"
new_main="$(git -C "$FIXTURE_ROOT/sm-a" rev-parse main)"
echo "dirty" >> .worktree/feat-y/sm-a/README
assert_pending_file .worktree/feat-y/sm-a README unstaged
./subgrove update feat-y rebase=ff >out 2>&1
# main advanced; feature branch NOT moved (dirty tree protected).
assert_branch_at .worktree/feat-y/sm-a main "$new_main"
assert_branch_at .worktree/feat-y/sm-a feat/feat-y "$feat_a_before"
assert_grep out "sm-a.*tree is dirty"
assert_grep out "ATTENTION"
assert_grep out "git submodule foreach 'git rebase main'"
# Dirty edit preserved.
assert_pending_file .worktree/feat-y/sm-a README unstaged
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture
