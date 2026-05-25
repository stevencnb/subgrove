#!/usr/bin/env bash
# Tests for `subgrove remove`.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# --- case: golden — worktree gone; parent + submodule feat branches retained ---
# cmd_remove preserves each touched submodule's feat branch by fetching it
# into main worktree's submodule git dir BEFORE `git worktree prune` wipes
# the per-worktree submodule storage. Per the strengthened lifecycle.md.
mkfixture_local remove_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
# Capture branch SHAs BEFORE remove.
sm_a_feat_before="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
sm_b_feat_before="$(git -C .worktree/feat-x/sm-b rev-parse feat/feat-x)"
parent_feat_before="$(git rev-parse feat/feat-x)"
./subgrove remove feat-x >out 2>&1
assert_file_absent .worktree/feat-x
# Parent feat branch retained at the same SHA (shared refs across worktrees).
assert_branch_at . feat/feat-x "$parent_feat_before"
# Submodule feat branches retained in main worktree's submodule git dirs at
# the same SHAs they had in the worktree's submodule pre-prune.
assert_branch_at sm-a feat/feat-x "$sm_a_feat_before"
assert_branch_at sm-b feat/feat-x "$sm_b_feat_before"
# User-visible info line confirms 2 branches were preserved.
assert_grep out "Preserved 2 submodule feat branch"
cleanup_fixture

# --- case: dirty parent worktree refused — state preserved, no preservation msg ---
mkfixture_local remove_dirty_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
echo "uncommitted" >> .worktree/feat-y/README

# --- PRE-remove state: README dirty in worktree parent; submodules clean ---
assert_pending_file .worktree/feat-y README unstaged "README dirty in feat worktree"
assert_clean .worktree/feat-y/sm-a
assert_clean .worktree/feat-y/sm-b
state_wt_p="$(snapshot_state .worktree/feat-y)"
state_wt_a="$(snapshot_state .worktree/feat-y/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-y/sm-b)"
if ./subgrove remove feat-y >out 2>&1; then
    fail "expected remove to refuse on dirty parent"
fi
assert_grep out "feature worktree \(parent\) has uncommitted"
assert_file_exists .worktree/feat-y

# --- POST-remove state: identical to pre. The dirty README must still be
#     there — that's the whole point of refusing without --force.
assert_pending_file .worktree/feat-y README unstaged "README still dirty after refuse"
assert_clean .worktree/feat-y/sm-a
assert_clean .worktree/feat-y/sm-b
assert_state_eq .worktree/feat-y      "$state_wt_p"
assert_state_eq .worktree/feat-y/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-y/sm-b "$state_wt_b"
# Refusal happened before the preservation step — no info line.
assert_grep_v out "Preserved.*submodule feat branch"
cleanup_fixture

# --- case: dirty touched submodule refused — state preserved ---
mkfixture_local remove_dirty_touched
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
echo "uncommitted" >> .worktree/feat-y/sm-a/README
state_wt_p="$(snapshot_state .worktree/feat-y)"
state_wt_a="$(snapshot_state .worktree/feat-y/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-y/sm-b)"
if ./subgrove remove feat-y >out 2>&1; then
    fail "expected remove to refuse on dirty submodule"
fi
assert_grep out "submodule 'sm-a' in feature worktree has uncommitted"
assert_file_exists .worktree/feat-y
assert_state_eq .worktree/feat-y      "$state_wt_p"
assert_state_eq .worktree/feat-y/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-y/sm-b "$state_wt_b"
cleanup_fixture

# --- case: dirty UN-touched submodule refused — state preserved ---
# touch=sm-a means sm-b has no feat branch but IS initialised. A dirty sm-b
# must still block remove — otherwise rm -rf would silently destroy work.
mkfixture_local remove_dirty_untouched
cd "$FIXTURE_SUPER"
./subgrove new feat-y touch=sm-a >out 2>&1
echo "uncommitted" >> .worktree/feat-y/sm-b/README
state_wt_p="$(snapshot_state .worktree/feat-y)"
state_wt_a="$(snapshot_state .worktree/feat-y/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-y/sm-b)"
if ./subgrove remove feat-y >out 2>&1; then
    fail "expected remove to refuse on dirty UN-touched submodule"
fi
# Err names the un-touched submodule specifically — proves the loop
# iterated past sm-a (clean) to sm-b.
assert_grep out "submodule 'sm-b' in feature worktree has uncommitted"
assert_file_exists .worktree/feat-y
assert_state_eq .worktree/feat-y      "$state_wt_p"
assert_state_eq .worktree/feat-y/sm-a "$state_wt_a"
assert_state_eq .worktree/feat-y/sm-b "$state_wt_b"
cleanup_fixture

# --- case: -f overrides dirty + branches still preserved ---
mkfixture_local remove_force
cd "$FIXTURE_SUPER"
./subgrove new feat-y >out 2>&1
sm_a_feat_before="$(git -C .worktree/feat-y/sm-a rev-parse feat/feat-y)"
sm_b_feat_before="$(git -C .worktree/feat-y/sm-b rev-parse feat/feat-y)"
echo "uncommitted" >> .worktree/feat-y/README
./subgrove remove feat-y -f >out 2>&1
assert_file_absent .worktree/feat-y
# Preservation must run even on force-remove of dirty worktree.
assert_branch_at .    feat/feat-y
assert_branch_at sm-a feat/feat-y "$sm_a_feat_before"
assert_branch_at sm-b feat/feat-y "$sm_b_feat_before"
assert_grep out "Preserved 2 submodule feat branch"
cleanup_fixture

# --- case: --force alias + preservation ---
mkfixture_local remove_force_long
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
sm_a_feat_before="$(git -C .worktree/feat-a/sm-a rev-parse feat/feat-a)"
sm_b_feat_before="$(git -C .worktree/feat-a/sm-b rev-parse feat/feat-a)"
echo "uncommitted" >> .worktree/feat-a/README
./subgrove remove feat-a --force >out 2>&1
assert_file_absent .worktree/feat-a
assert_branch_at .    feat/feat-a
assert_branch_at sm-a feat/feat-a "$sm_a_feat_before"
assert_branch_at sm-b feat/feat-a "$sm_b_feat_before"
assert_grep out "Preserved 2 submodule feat branch"
cleanup_fixture

# --- case: force=true alias + preservation ---
mkfixture_local remove_force_kv
cd "$FIXTURE_SUPER"
./subgrove new feat-b >out 2>&1
sm_a_feat_before="$(git -C .worktree/feat-b/sm-a rev-parse feat/feat-b)"
sm_b_feat_before="$(git -C .worktree/feat-b/sm-b rev-parse feat/feat-b)"
echo "uncommitted" >> .worktree/feat-b/README
./subgrove remove feat-b force=true >out 2>&1
assert_file_absent .worktree/feat-b
assert_branch_at .    feat/feat-b
assert_branch_at sm-a feat/feat-b "$sm_a_feat_before"
assert_branch_at sm-b feat/feat-b "$sm_b_feat_before"
assert_grep out "Preserved 2 submodule feat branch"
cleanup_fixture

# --- case: nonexistent name refused ---
mkfixture_local remove_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove remove never-existed >out 2>&1; then
    fail "expected remove to refuse on nonexistent name"
fi
cleanup_fixture

# --- case: removing one worktree leaves siblings untouched ---
mkfixture_local remove_one_of_many
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
./subgrove new feat-b >out 2>&1
feat_a_sm_a_before="$(git -C .worktree/feat-a/sm-a rev-parse feat/feat-a)"
feat_a_sm_b_before="$(git -C .worktree/feat-a/sm-b rev-parse feat/feat-a)"
feat_b_state_parent="$(snapshot_state .worktree/feat-b)"
feat_b_state_sm_a="$(snapshot_state .worktree/feat-b/sm-a)"
feat_b_state_sm_b="$(snapshot_state .worktree/feat-b/sm-b)"
./subgrove remove feat-a >out 2>&1
assert_file_absent .worktree/feat-a
assert_file_exists .worktree/feat-b
# Parent branches retained for both.
assert_branch_at . feat/feat-a
assert_branch_at . feat/feat-b
# feat-a's submodule branches preserved in main super (the removed one).
assert_branch_at sm-a feat/feat-a "$feat_a_sm_a_before"
assert_branch_at sm-b feat/feat-a "$feat_a_sm_b_before"
# feat-b's worktree completely undisturbed.
assert_state_eq .worktree/feat-b      "$feat_b_state_parent"
assert_state_eq .worktree/feat-b/sm-a "$feat_b_state_sm_a"
assert_state_eq .worktree/feat-b/sm-b "$feat_b_state_sm_b"
cleanup_fixture

# --- case: touch=sm-a + remove preserves only sm-a's feat (selective) ---
# Verifies the preservation loop's per-submodule filtering: only submodules
# with the feat branch in the worktree get their branch preserved.
mkfixture_local remove_touch_subset
cd "$FIXTURE_SUPER"
./subgrove new feat-y touch=sm-a >out 2>&1
sm_a_feat_before="$(git -C .worktree/feat-y/sm-a rev-parse feat/feat-y)"
# sm-b is initialised but has no feat/feat-y branch.
assert_no_branch .worktree/feat-y/sm-b feat/feat-y
./subgrove remove feat-y >out 2>&1
assert_file_absent .worktree/feat-y
# sm-a's feat branch preserved in main super.
assert_branch_at sm-a feat/feat-y "$sm_a_feat_before"
# sm-b has no preserved branch (nothing to preserve — it never had one).
assert_no_branch sm-b feat/feat-y
# Info line says exactly 1 branch was preserved.
assert_grep out "Preserved 1 submodule feat branch"
cleanup_fixture

# --- case: preserved feat branch reflects ADVANCED state, not recorded SHA ---
# More realistic than remove_golden: user makes commits on feat-x's sm-a,
# then removes without merging. The preserved branch in main super's sm-a
# should point at the ADVANCED tip (not the original recorded gitlink SHA).
mkfixture_local remove_advanced_feat
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
commit_one .worktree/feat-x/sm-a "advance feat-x in sm-a"
sm_a_feat_advanced="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
sm_a_recorded="$(git ls-tree feat/feat-x sm-a | awk '{print $3}')"
# Sanity: advanced SHA differs from the parent's recorded gitlink SHA.
[[ "$sm_a_feat_advanced" != "$sm_a_recorded" ]] \
    || fail "advanced SHA should differ from recorded SHA"
# Parent has M sm-a (we didn't bump). Use -f to bypass the dirty check.
./subgrove remove feat-x -f >out 2>&1
assert_file_absent .worktree/feat-x
# Preserved branch points at the ADVANCED tip — what the user actually
# committed — not the recorded gitlink SHA.
assert_branch_at sm-a feat/feat-x "$sm_a_feat_advanced"
# sm-b had no commits; its preserved branch is at the recorded SHA.
assert_branch_at sm-b feat/feat-x
# The PREDECESSOR commit (the originally-recorded SHA, which is the parent
# of the advanced commit) is also reachable from the preserved branch.
# Proves the fetch transferred the commit-chain objects, not just the tip
# ref.
assert_ancestor sm-a "$sm_a_recorded" feat/feat-x
# Info line confirms both submodule feat branches were preserved.
assert_grep out "Preserved 2 submodule feat branch"
cleanup_fixture

# --- case: touch=none + remove (no submodule branches to preserve) ---
# Preservation loop iterates and skips all submodules silently.
mkfixture_local remove_touch_none
cd "$FIXTURE_SUPER"
./subgrove new feat-z touch=none >out 2>&1
assert_no_branch .worktree/feat-z/sm-a feat/feat-z
assert_no_branch .worktree/feat-z/sm-b feat/feat-z
./subgrove remove feat-z >out 2>&1
assert_file_absent .worktree/feat-z
# Parent retained.
assert_branch_at . feat/feat-z
# No submodule feat branches existed; none preserved.
assert_no_branch sm-a feat/feat-z
assert_no_branch sm-b feat/feat-z
# `preserved=0`, so the info line is suppressed entirely.
assert_grep_v out "Preserved.*submodule feat branch"
cleanup_fixture

# --- case: re-create same name after remove refused; succeeds after branch deletion ---
# Per lifecycle.md, `remove` retains branches. So `new feat-x` after
# `remove feat-x` should hit the "branch already exists" check. The user
# must delete the branch manually first.
mkfixture_local remove_then_recreate
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
sm_a_recorded_before="$(git -C .worktree/feat-x ls-tree feat/feat-x sm-a | awk '{print $3}')"
sm_b_recorded_before="$(git -C .worktree/feat-x ls-tree feat/feat-x sm-b | awk '{print $3}')"
./subgrove remove feat-x >out 2>&1
if ./subgrove new feat-x >out 2>&1; then
    fail "expected new to refuse re-create when branch is retained"
fi
assert_grep out "already exists"
git branch -D feat/feat-x
./subgrove new feat-x >out 2>&1
assert_file_exists .worktree/feat-x
# Submodule SHAs on the recreated worktree match the original recorded
# gitlink SHAs — the recreate clones fresh from the siblings, and the
# parent's tree references those same SHAs.
[[ "$(git -C .worktree/feat-x/sm-a rev-parse HEAD)" == "$sm_a_recorded_before" ]] \
    || fail "sm-a HEAD doesn't match the original recorded SHA after recreate"
[[ "$(git -C .worktree/feat-x/sm-b rev-parse HEAD)" == "$sm_b_recorded_before" ]] \
    || fail "sm-b HEAD doesn't match the original recorded SHA after recreate"
cleanup_fixture

# --- case: preservation-fetch failure aborts before rm -rf (even under -f) ---
# If the fetch that preserves feat/<name> into main super's submodule fails,
# remove must abort rather than warn-and-rm: the branch's commits live only in
# the worktree's submodule git dir until the fetch copies them out. -f bypasses
# the cleanliness gate but NOT this preservation gate.
mkfixture_local remove_preserve_fetch_fail
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
# Real work on the worktree's sm-a feat branch — what would be lost.
commit_one .worktree/feat-x/sm-a "work on feat-x sm-a"
sm_a_feat="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
# Dirty the worktree so -f is required (proving -f doesn't bypass preservation).
echo "dirty" >> .worktree/feat-x/README
# Force the preservation fetch to fail: a branch named `feat` in main super's
# sm-a is a directory/file conflict against creating refs/heads/feat/feat-x, so
# the fetch errors. Stands in for any real fetch failure (disk full, perms,
# corruption) without engineering one.
git -C sm-a branch feat main
state_wt_sm_a="$(snapshot_state .worktree/feat-x/sm-a)"
if ./subgrove remove feat-x -f >out 2>&1; then
    fail "expected remove to abort on preservation-fetch failure"
fi
# Nothing destroyed: worktree still present, the feat commit still in sm-a.
assert_file_exists .worktree/feat-x
assert_branch_at .worktree/feat-x/sm-a feat/feat-x "$sm_a_feat"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_sm_a"
# Err names the failed preservation; the removal info line never fired.
assert_grep out "sm-a: failed to preserve"
assert_grep_v out "Removing worktree at"
cleanup_fixture
