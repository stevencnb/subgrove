#!/usr/bin/env bash
# Tests for `subgrove update` on a no-submodule fixture.
#
# Companion to tests/local/test_update.sh. With zero submodules, the
# per-submodule sentinel-update loop iterates the empty list and the
# final summary truthfully reports "Updated 0 submodule main(s); 0 skipped".
# Parent-level refs (including any that happen to be named _update_sync)
# must not be touched.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

# --- case: degenerate update succeeds with truthful zero-case summary ---
mkfixture_local_no_sm update_degenerate
cd "$FIXTURE_SUPER"
./subgrove new feat-y >/dev/null 2>&1
./subgrove update feat-y >out 2>&1
# Parent fetch warn fires (super has no origin).
assert_grep out "warn: parent fetch failed"
# Submodule-update phase narration reflects zero submodules.
assert_grep out "FF-updating peer worktree 'feat-y' submodule mains from origin/main"
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
# Rebase guidance is unconditional and still printed.
assert_grep out "git submodule foreach 'git rebase main'"
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: sentinel ref never created in main super ---
# The sentinel `refs/heads/_update_sync` lives in per-submodule git dirs.
# With zero submodules, no sentinel should be created ANYWHERE in the
# main super's ref tree — not refs/heads/, not refs/, and not under any
# remotes namespace. Three checks below catch each variant of leakage.
#
# Must-fire greps prove the update phase was actually entered with an
# empty list, not short-circuited entirely. Without them, a regression
# that early-returns from cmd_update when list_all_submodules is empty
# would pass this test trivially.
mkfixture_local_no_sm update_no_sentinel
cd "$FIXTURE_SUPER"
./subgrove new feat-y >/dev/null 2>&1
./subgrove update feat-y >out 2>&1
assert_grep out "FF-updating peer worktree 'feat-y'"
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
for ref in refs/heads/_update_sync refs/_update_sync refs/remotes/origin/_update_sync; do
    if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
        fail "main super has $ref after update on no-sm fixture"
    fi
done
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: pre-existing _update_sync ref in parent is untouched ---
# Subgrove's sentinel manipulation is scoped to per-submodule git dirs.
# If a user happens to have a parent-level ref with the same name (e.g.
# from a different tool or an unrelated workflow), subgrove must not
# clobber it. Mirror update_no_sentinel's three-namespace symmetry:
# heads, root, and remotes — set each before update, verify each unchanged.
mkfixture_local_no_sm update_parent_sentinel_preserved
cd "$FIXTURE_SUPER"
./subgrove new feat-y >/dev/null 2>&1
git update-ref refs/heads/_update_sync HEAD
git update-ref refs/_update_sync HEAD
git update-ref refs/remotes/origin/_update_sync HEAD
pre_heads="$(git rev-parse refs/heads/_update_sync)"
pre_root="$(git rev-parse refs/_update_sync)"
pre_remote="$(git rev-parse refs/remotes/origin/_update_sync)"
./subgrove update feat-y >out 2>&1
post_heads="$(git rev-parse --verify --quiet refs/heads/_update_sync 2>/dev/null || echo MISSING)"
post_root="$(git rev-parse --verify --quiet refs/_update_sync 2>/dev/null || echo MISSING)"
post_remote="$(git rev-parse --verify --quiet refs/remotes/origin/_update_sync 2>/dev/null || echo MISSING)"
assert_eq "$pre_heads"  "$post_heads"  "refs/heads/_update_sync changed during update"
assert_eq "$pre_root"   "$post_root"   "refs/_update_sync changed during update"
assert_eq "$pre_remote" "$post_remote" "refs/remotes/origin/_update_sync changed during update"
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture

# --- case: nonexistent name errs ---
mkfixture_local_no_sm update_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove update never-existed >out 2>&1; then
    fail "expected update to err on nonexistent worktree name"
fi
assert_grep out "does not exist"
# §15: status reflects the resulting state. No worktree was ever created.
assert_status "no feature worktrees yet"
cleanup_fixture

# --- case: doesn't require clean state ---
# cmd_update is ref-only (no working-tree mutation), so a dirty worktree
# must not block it. Same invariant as the with-submodule tier.
mkfixture_local_no_sm update_dirty_ok
cd "$FIXTURE_SUPER"
./subgrove new feat-y >/dev/null 2>&1
echo "dirty" >> .worktree/feat-y/README
assert_pending_file .worktree/feat-y README unstaged
./subgrove update feat-y >out 2>&1
assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
# Dirty edit preserved.
assert_pending_file .worktree/feat-y README unstaged
# §15: status reflects the resulting state.
assert_status feat-y "feat/feat-y"
cleanup_fixture
