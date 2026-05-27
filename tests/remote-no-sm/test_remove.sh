#!/usr/bin/env bash
# Remote tests for `subgrove remove` on a no-sm super. Local-no-sm
# fixture covers remove's state-machine (dirty handling, force flag,
# branch retention); this file pins one thing: `remove` never reaches
# out to origin. After remove, the no-sm super's origin ref must be
# byte-for-byte where it was before.
#
# user-data-rules.md: cmd_remove deletes the named worktree (the user's
# explicit opt-in) but must NOT touch main super's working tree.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

# --- case: remove without prior push — origin baseline untouched ---
mkfixture_remote_no_sm remove_no_push
cd "$FIXTURE_SUPER"
./subgrove new feat-rmnp >out 2>&1
register_feature_branch_no_sm feat/feat-rmnp

( cd .worktree/feat-rmnp && echo "feat work" >> README \
    && git add README && git commit --quiet -m "feat commit" )

super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

# Snapshot main super pre-remove. Remove must not touch the parent
# (only adds preserved feat refs, which snapshot_state excludes).
state_main="$(snapshot_state .)"

./subgrove remove feat-rmnp -f >out 2>&1   # -f harmless when clean; mirrors with-sm pattern

assert_file_absent .worktree/feat-rmnp
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin unchanged"
assert_state_eq . "$state_main" "[no_push] main super"
# §15: status reflects the resulting state (last/only worktree removed).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: remove after merge push=true — pushed main untouched, parent feat branch retained ---
mkfixture_remote_no_sm remove_after_push
cd "$FIXTURE_SUPER"
./subgrove new feat-rmap >out 2>&1
register_feature_branch_no_sm feat/feat-rmap

( cd .worktree/feat-rmap && echo "feat work" >> README \
    && git add README && git commit --quiet -m "feat commit" )

./subgrove merge feat-rmap push=true >out 2>&1

# Snapshot post-push origin SHA — it must survive the subsequent remove.
super_post="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

# Snapshot main super state AFTER merge (which moved its parent main
# ref) but BEFORE remove. Remove must not perturb this.
state_main="$(snapshot_state .)"

./subgrove remove feat-rmap >out 2>&1

assert_file_absent .worktree/feat-rmap
# Origin ref frozen — remove is purely local.
assert_eq "$super_post" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "super origin unchanged by remove"
# Main super's working tree untouched by remove.
assert_state_eq . "$state_main" "[after_push] main super"
# Parent feat branch retained locally (lifecycle.md "branches retained").
assert_branch_at . feat/feat-rmap
# §15: status reflects the resulting state (last/only worktree removed;
# the retained branch is not a worktree, so it doesn't show as a row).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: dirty parent worktree refused ---
mkfixture_remote_no_sm remove_dirty_parent
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
echo "dirty" >> .worktree/feat-x/README
assert_pending_file .worktree/feat-x README unstaged
parent_state="$(snapshot_state .worktree/feat-x)"
main_state="$(snapshot_state .)"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"
if ./subgrove remove feat-x >out 2>&1; then
    fail "expected remove to refuse on dirty parent worktree"
fi
assert_grep out "feature worktree \(parent\) has uncommitted"
assert_file_exists .worktree/feat-x
# Specific pending edit still on disk.
assert_pending_file .worktree/feat-x README unstaged
# Nothing else in the worktree changed.
assert_state_eq .worktree/feat-x "$parent_state"
# Main super preserved (rule: remove preserves main super every case).
assert_state_eq . "$main_state" "[dirty_parent] main super"
# Origin untouched on refuse.
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "origin unchanged on refuse"
# §15: status reflects the resulting state (worktree retained on refuse).
assert_status feat-x "feat/feat-x"
cleanup_fixture_remote_no_sm

# --- case: -f overrides dirty parent + parent feat branch preserved ---
# Per user-data-rules.md: `-f` discards dirty edits (the user's explicit
# opt-in) but the parent feat branch must still survive.
mkfixture_remote_no_sm remove_force_short
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
feat_sha_before="$(git rev-parse feat/feat-x)"
echo "dirty" >> .worktree/feat-x/README
# Dirty edit is in the FEATURE worktree (discarded by -f); main super is
# clean and must stay byte-identical across the remove.
main_state="$(snapshot_state .)"
./subgrove remove feat-x -f >out 2>&1
assert_file_absent .worktree/feat-x
# Parent feat branch retained at the original SHA.
assert_branch_at . feat/feat-x "$feat_sha_before"
# Main super preserved (rule: remove preserves main super every case).
assert_state_eq . "$main_state" "[force_short] main super"
# §15: status reflects the resulting state (last/only worktree removed;
# retained branch is not a worktree row).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: --force alias + branch preserved ---
mkfixture_remote_no_sm remove_force_long
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
feat_sha_before="$(git rev-parse feat/feat-x)"
echo "dirty" >> .worktree/feat-x/README
main_state="$(snapshot_state .)"
./subgrove remove feat-x --force >out 2>&1
assert_file_absent .worktree/feat-x
assert_branch_at . feat/feat-x "$feat_sha_before"
assert_state_eq . "$main_state" "[force_long] main super"
# §15: status reflects the resulting state (last/only worktree removed;
# retained branch is not a worktree row).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: force=true alias + branch preserved ---
mkfixture_remote_no_sm remove_force_kv
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
feat_sha_before="$(git rev-parse feat/feat-x)"
echo "dirty" >> .worktree/feat-x/README
main_state="$(snapshot_state .)"
./subgrove remove feat-x force=true >out 2>&1
assert_file_absent .worktree/feat-x
assert_branch_at . feat/feat-x "$feat_sha_before"
assert_state_eq . "$main_state" "[force_kv] main super"
# §15: status reflects the resulting state (last/only worktree removed;
# retained branch is not a worktree row).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: nonexistent name errs ---
mkfixture_remote_no_sm remove_nonexistent
cd "$FIXTURE_SUPER"
if ./subgrove remove never-existed >out 2>&1; then
    fail "expected remove to err on nonexistent name"
fi
assert_grep out "does not exist"
# §15: status reflects the resulting state (no worktree was ever created).
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: multi-worktree — remove middle, others survive ---
# Pin that `remove` is correctly scoped: removing one worktree must not
# touch peer worktrees on disk. Three worktrees so we test both the
# before- and after-target positions of the remove call.
mkfixture_remote_no_sm remove_multi_worktree
cd "$FIXTURE_SUPER"
./subgrove new feat-a >out 2>&1
register_feature_branch_no_sm feat/feat-a
./subgrove new feat-b >out 2>&1
register_feature_branch_no_sm feat/feat-b
./subgrove new feat-c >out 2>&1
register_feature_branch_no_sm feat/feat-c

state_a="$(snapshot_state .worktree/feat-a)"
state_c="$(snapshot_state .worktree/feat-c)"
main_state="$(snapshot_state .)"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

./subgrove remove feat-b >out 2>&1

# Targeted worktree gone; siblings byte-identical.
assert_file_absent .worktree/feat-b
assert_file_exists .worktree/feat-a
assert_file_exists .worktree/feat-c
assert_state_eq .worktree/feat-a "$state_a" "[multi] feat-a preserved"
assert_state_eq .worktree/feat-c "$state_c" "[multi] feat-c preserved"
# Main super preserved (only the removed worktree disappears).
assert_state_eq . "$main_state" "[multi] main super preserved"
# Parent feat-b branch retained.
assert_branch_at . feat/feat-b
# Sibling branches still exist.
assert_branch_at . feat/feat-a
assert_branch_at . feat/feat-c
# Origin frozen.
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")" \
    "origin unchanged by remove"
# §15: status reflects the resulting state (feat-b gone; siblings remain).
assert_status_absent feat-b
assert_status feat-a feat-c "feat/feat-a" "feat/feat-c"
cleanup_fixture_remote_no_sm
