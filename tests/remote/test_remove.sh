#!/usr/bin/env bash
# Remote tests for `subgrove remove`. Local fixture covers remove's
# state-machine (dirty handling, force flag, branch retention, etc.);
# this file pins one thing: `remove` never reaches out to origin. After
# remove, every origin ref must be byte-for-byte where it was before.
#
# user-data-rules.md: cmd_remove deletes the named worktree (the user's
# explicit opt-in) but must NOT touch main super's working tree or any
# of its submodules' working trees. Each case snapshots main super
# (parent + sm-a + sm-b) pre/post remove and asserts byte-identical
# state. Refs added by the preservation fetch are intentional and not
# captured by snapshot_state (which tracks HEAD + status + diffs).
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

# --- case: remove without prior push — origin baseline untouched ---
mkfixture_remote remove_no_push
cd "$FIXTURE_SUPER"
./subgrove new feat-rmnp >out 2>&1
register_feature_branch feat/feat-rmnp

commit_one .worktree/feat-rmnp/sm-a "sm-a edit"
( cd .worktree/feat-rmnp && git add -A && git commit --quiet -m "bump sm-a" )

super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_URL")"
sm_a_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL")"
sm_b_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL2")"

# Snapshot main super pre-remove. Remove must not touch the parent or
# any of its submodule working trees (only adds preserved feat refs).
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

./subgrove remove feat-rmnp -f >out 2>&1   # force: dirty submodule edits

assert_file_absent .worktree/feat-rmnp
assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super origin unchanged"
assert_eq "$sm_a_pre"  "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a origin unchanged"
assert_eq "$sm_b_pre"  "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b origin unchanged"
assert_state_eq .    "$state_main_p" "[no_push] main super parent"
assert_state_eq sm-a "$state_main_a" "[no_push] main super sm-a"
assert_state_eq sm-b "$state_main_b" "[no_push] main super sm-b"
# §15: status reflects the resulting state.
assert_status "no feature worktrees yet"
cleanup_fixture_remote

# --- case: remove after merge push=true — pushed main untouched, feat branches retained locally ---
mkfixture_remote remove_after_push
cd "$FIXTURE_SUPER"
./subgrove new feat-rmap >out 2>&1
register_feature_branch feat/feat-rmap

commit_one .worktree/feat-rmap/sm-a "sm-a edit"
( cd .worktree/feat-rmap && git add -A && git commit --quiet -m "bump sm-a" )

./subgrove merge feat-rmap push=true >out 2>&1

# Snapshot post-push origin SHAs — they must survive the subsequent remove.
super_post="$(_origin_main "$SUBGROVE_TEST_SUPER_URL")"
sm_a_post="$(_origin_main "$SUBGROVE_TEST_SM_URL")"
sm_b_post="$(_origin_main "$SUBGROVE_TEST_SM_URL2")"

# Snapshot main super state AFTER merge (which moved its sm-a/parent
# main refs) but BEFORE remove. Remove must not perturb this.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

./subgrove remove feat-rmap >out 2>&1

assert_file_absent .worktree/feat-rmap
# Origin refs frozen — remove is purely local.
assert_eq "$super_post" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super origin unchanged by remove"
assert_eq "$sm_a_post"  "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a origin unchanged by remove"
assert_eq "$sm_b_post"  "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b origin unchanged by remove"
# Main super's working trees untouched by remove (only refs added).
assert_state_eq .    "$state_main_p" "[after_push] main super parent"
assert_state_eq sm-a "$state_main_a" "[after_push] main super sm-a"
assert_state_eq sm-b "$state_main_b" "[after_push] main super sm-b"
# Parent feat branch retained locally (lifecycle.md "branches retained").
assert_branch_at . feat/feat-rmap
# Submodule feat branches preserved into main worktree's submodule git dirs.
assert_branch_at sm-a feat/feat-rmap
# §15: status reflects the resulting state.
assert_status "no feature worktrees yet"
cleanup_fixture_remote
