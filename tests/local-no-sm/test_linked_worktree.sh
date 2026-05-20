#!/usr/bin/env bash
# Each command refuses with `assert_main_worktree` when invoked from
# inside a linked worktree, even on a no-submodule super. The refusal
# fires inside `assert_main_worktree` before any other side effect; this
# tier locks in that the assertion still fires when there's no
# .gitmodules to read.
#
# Companion to tests/local/test_linked_worktree.sh — same idea, but the
# state-preservation snapshot covers only the parent (no sm-a / sm-b).
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

_run_linked_refusal() {
    local subcmd="$1" name="$2"
    mkfixture_local_no_sm "linked_${subcmd}"
    cd "$FIXTURE_SUPER"
    ./subgrove new feat-host >out 2>&1
    ln -s "$SUBGROVE_REPO_ROOT/subgrove" .worktree/feat-host/subgrove

    local main_p_state
    main_p_state="$(snapshot_state .)"

    cd .worktree/feat-host
    if ./subgrove "$subcmd" "$name" >out 2>&1; then
        cd "$FIXTURE_SUPER"
        fail "expected $subcmd to refuse from a linked worktree"
    fi
    assert_grep out "currently in a linked worktree"
    cd "$FIXTURE_SUPER"

    assert_state_eq . "$main_p_state"
    cleanup_fixture
}

# --- case: merge refuses from linked worktree ---
_run_linked_refusal merge feat-host

# --- case: remove refuses from linked worktree ---
_run_linked_refusal remove feat-host

# --- case: update refuses from linked worktree ---
_run_linked_refusal update feat-host
