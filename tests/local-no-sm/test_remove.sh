#!/usr/bin/env bash
# Tests for `subgrove remove` on a no-submodule fixture.
#
# Companion to tests/local/test_remove.sh. The submodule-branch-preservation
# step (Phase 2 of cmd_remove) must no-op when there are no submodules;
# its info line must not fire.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

# --- case: golden ---
mkfixture_local_no_sm remove_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
./subgrove remove feat-x >out 2>&1
assert_file_absent .worktree/feat-x
# Parent feat branch is retained (lifecycle.md "branches retained" contract).
assert_branch_at . feat/feat-x
# The "Preserved N submodule feat branch(es)" info line MUST NOT fire on
# a no-sm super — there's nothing to preserve. Catches a regression where
# the preservation loop emits the line unconditionally.
assert_grep_v out "Preserved [0-9]+ submodule feat branch"
# The "branches retained" narration in the remove-message still fires
# (refers to the parent branch).
assert_grep out "branches retained"
cleanup_fixture

# --- case: dirty parent worktree refused ---
mkfixture_local_no_sm remove_dirty_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
echo "dirty" >> .worktree/feat-x/README
# Pin the SPECIFIC pending file before AND after the refuse. The
# `assert_state_eq` snapshot below also catches a dropped pending edit,
# but the explicit per-file assertion is the pattern in user-data-rules.md
# (rules out lost-pending-edit bugs in a more readable way).
assert_pending_file .worktree/feat-x README unstaged
# Snapshot AFTER the dirty edit — must remain dirty post-refusal.
parent_state=$(snapshot_state .worktree/feat-x)
if ./subgrove remove feat-x >out 2>&1; then
    fail "expected remove to refuse on dirty parent worktree"
fi
# Pin the full label so a label-swap regression (e.g. a copy-paste putting
# "main worktree (parent, dst)" in cmd_remove) is caught.
assert_grep out "feature worktree \(parent\) has uncommitted"
assert_file_exists .worktree/feat-x
# The specific pending edit is still on disk.
assert_pending_file .worktree/feat-x README unstaged
# And nothing else in the worktree changed either.
assert_state_eq .worktree/feat-x "$parent_state"
cleanup_fixture

# --- case: -f overrides dirty parent + parent feat branch preserved ---
# Per user-data-rules.md: `-f` discards dirty edits (the user's explicit
# opt-in) but the parent feat branch must still survive. The with-sm
# sibling tier asserts this; mirror that pattern here.
mkfixture_local_no_sm remove_force_short
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
feat_sha_before="$(git rev-parse feat/feat-x)"
echo "dirty" >> .worktree/feat-x/README
./subgrove remove feat-x -f >out 2>&1
assert_file_absent .worktree/feat-x
# Parent feat branch retained, at the original SHA — `-f` only discards
# the dirty working-tree edit, not the user's committed branch.
assert_branch_at . feat/feat-x "$feat_sha_before"
cleanup_fixture

# --- case: --force alias + branch preserved ---
mkfixture_local_no_sm remove_force_long
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
feat_sha_before="$(git rev-parse feat/feat-x)"
echo "dirty" >> .worktree/feat-x/README
./subgrove remove feat-x --force >out 2>&1
assert_file_absent .worktree/feat-x
assert_branch_at . feat/feat-x "$feat_sha_before"
cleanup_fixture

# --- case: force=true alias + branch preserved ---
mkfixture_local_no_sm remove_force_kv
cd "$FIXTURE_SUPER"
./subgrove new feat-x >/dev/null 2>&1
feat_sha_before="$(git rev-parse feat/feat-x)"
echo "dirty" >> .worktree/feat-x/README
./subgrove remove feat-x force=true >out 2>&1
assert_file_absent .worktree/feat-x
assert_branch_at . feat/feat-x "$feat_sha_before"
cleanup_fixture

# --- case: nonexistent name errs ---
mkfixture_local_no_sm remove_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove remove never-existed >out 2>&1; then
    fail "expected remove to err on nonexistent name"
fi
# Pin the specific err-text so a regression where remove exits non-zero
# for an unrelated reason (e.g., syntax error introduced earlier) doesn't
# pass this test silently.
assert_grep out "does not exist"
cleanup_fixture
