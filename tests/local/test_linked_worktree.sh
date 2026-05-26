#!/usr/bin/env bash
# Each command refuses with `assert_main_worktree` when invoked from
# inside a linked worktree. Uses the same symlink trick as
# test_new.sh::new_linked but covers merge, remove, and update.
#
# Why explicit per-command coverage: the linked-worktree guard
# (assert_main_worktree, invoked via discover_root) runs once per command,
# but each command has its own discover_root call site. A future refactor
# that dropped the call from one command would only be caught by an
# explicit test that exercises that command from inside a linked worktree.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

_run_linked_refusal() {
    local subcmd="$1" name="$2"
    mkfixture_local "linked_${subcmd}"
    cd "$FIXTURE_SUPER"
    ./subgrove new feat-host >out 2>&1
    # Drop a subgrove symlink inside the linked worktree so we can invoke
    # `./subgrove` from there. Discovery keys off the CWD, so running from
    # inside the linked worktree is what trips the main-worktree guard.
    ln -s "$SUBGROVE_REPO_ROOT/subgrove" .worktree/feat-host/subgrove

    # Capture main super state — refusal must not modify ANY of its three
    # repos. The refusal fires inside `assert_main_worktree` before any
    # other side effect, but a future bug that moved logic above that
    # check would be invisible without this assertion.
    local main_p_state main_a_state main_b_state
    main_p_state="$(snapshot_state .)"
    main_a_state="$(snapshot_state sm-a)"
    main_b_state="$(snapshot_state sm-b)"

    cd .worktree/feat-host
    if ./subgrove "$subcmd" "$name" >out 2>&1; then
        cd "$FIXTURE_SUPER"
        fail "expected $subcmd to refuse from a linked worktree"
    fi
    assert_grep out "currently in a linked worktree"
    cd "$FIXTURE_SUPER"

    # Refused command shouldn't have modified anything in main super.
    assert_state_eq .    "$main_p_state"
    assert_state_eq sm-a "$main_a_state"
    assert_state_eq sm-b "$main_b_state"
    cleanup_fixture
}

# --- case: merge refuses from linked worktree ---
_run_linked_refusal merge feat-host

# --- case: remove refuses from linked worktree ---
_run_linked_refusal remove feat-host

# --- case: update refuses from linked worktree ---
_run_linked_refusal update feat-host
