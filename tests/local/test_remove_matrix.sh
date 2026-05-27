#!/usr/bin/env bash
# State matrix for `subgrove remove`. Iterates every combination of
# (dirty, no-dirty) for the parent + sm-a + sm-b in the feature worktree
# (2^3 = 8 dirty combinations) × 2 staged variants × 2 force-flag values
# = 32 iterations.
#
# Outcome:
# - force=1: remove succeeds regardless of dirty state.
# - force=0 + any dirty: remove refused, worktree intact.
# - force=0 + all clean: remove succeeds.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

_apply_dirty() {
    local dir="$1" staged="$2"
    echo "dirty $$ $RANDOM" >> "$dir/README"
    if [[ "$staged" -eq 1 ]]; then
        git -C "$dir" add README
    fi
}

# _verify_pre_state — confirms the setup actually applied the expected
# dirty state to each location (parity with the merge matrix's helper).
# Catches a silently-failed _apply_dirty before the test reaches its
# assertions.
_verify_pre_state() {
    local p_d="$1" a_d="$2" b_d="$3" staged="$4" label="$5"
    local mode="unstaged"
    [[ "$staged" -eq 1 ]] && mode="staged"

    # Main super: matrix never dirties or commits here. README explicitly
    # clean (mirrors merge matrix's pre-state granularity).
    assert_pending_file .    README none "[$label] main super README clean"
    assert_pending_file sm-a README none "[$label] main super sm-a README clean"
    assert_pending_file sm-b README none "[$label] main super sm-b README clean"

    # Worktree per-location pending state matches the iteration's bits.
    if [[ "$p_d" -eq 1 ]]; then
        assert_pending_file .worktree/feat-x README "$mode" "[$label] wt parent README"
    else
        assert_pending_file .worktree/feat-x README none "[$label] wt parent README clean"
    fi
    if [[ "$a_d" -eq 1 ]]; then
        assert_pending_file .worktree/feat-x/sm-a README "$mode" "[$label] wt sm-a README"
    else
        assert_pending_file .worktree/feat-x/sm-a README none "[$label] wt sm-a README clean"
    fi
    if [[ "$b_d" -eq 1 ]]; then
        assert_pending_file .worktree/feat-x/sm-b README "$mode" "[$label] wt sm-b README"
    else
        assert_pending_file .worktree/feat-x/sm-b README none "[$label] wt sm-b README clean"
    fi
}

_run_case() {
    local p_d="$1" a_d="$2" b_d="$3" staged="$4" force="$5"
    local label="P_dirty=$p_d A_dirty=$a_d B_dirty=$b_d staged=$staged force=$force"

    mkfixture_local "remove_matrix"
    cd "$FIXTURE_SUPER"

    ./subgrove new feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "new failed"; }

    # Sanity-check that subgrove new actually created the feat branches.
    git rev-parse --verify --quiet refs/heads/feat/feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "parent feat branch not created by new"; }
    git -C .worktree/feat-x/sm-a rev-parse --verify --quiet refs/heads/feat/feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "sm-a feat branch not created by new"; }
    git -C .worktree/feat-x/sm-b rev-parse --verify --quiet refs/heads/feat/feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "sm-b feat branch not created by new"; }

    # Capture the recorded gitlink SHAs for verification in success branches.
    local sm_a_recorded sm_b_recorded
    sm_a_recorded="$(git ls-tree feat/feat-x sm-a | awk '{print $3}')"
    sm_b_recorded="$(git ls-tree feat/feat-x sm-b | awk '{print $3}')"

    if [[ "$p_d" -eq 1 ]]; then _apply_dirty .worktree/feat-x      "$staged"; fi
    if [[ "$a_d" -eq 1 ]]; then _apply_dirty .worktree/feat-x/sm-a "$staged"; fi
    if [[ "$b_d" -eq 1 ]]; then _apply_dirty .worktree/feat-x/sm-b "$staged"; fi

    # Verify the setup produced the expected dirty state per location.
    _verify_pre_state "$p_d" "$a_d" "$b_d" "$staged" "$label"

    # Snapshot worktree state — used in the refuse branch to verify the
    # dirty edit (and everything else) is preserved.
    local state_wt_p state_wt_a state_wt_b
    state_wt_p="$(snapshot_state .worktree/feat-x)"
    state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
    state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"

    local args=()
    [[ "$force" -eq 1 ]] && args+=(-f)

    local remove_failed=0
    ./subgrove remove feat-x "${args[@]}" >out 2>&1 || remove_failed=1

    local any_dirty=0
    if [[ "$p_d" -eq 1 || "$a_d" -eq 1 || "$b_d" -eq 1 ]]; then
        any_dirty=1
    fi

    if [[ "$force" -eq 1 ]]; then
        # Force wins regardless of dirty.
        [[ "$remove_failed" -eq 0 ]] \
            || { echo "[$label]"; cat out; fail "expected remove -f to succeed"; }
        [[ ! -e .worktree/feat-x ]] \
            || { echo "[$label]"; fail "worktree should be gone"; }
        # Parent + submodule feat branches retained at the recorded SHAs.
        # The matrix never makes commits, so preserved == recorded.
        assert_branch_at .    feat/feat-x "" "[$label] parent feat retained"
        assert_branch_at sm-a feat/feat-x "$sm_a_recorded" "[$label] sm-a feat preserved at recorded SHA"
        assert_branch_at sm-b feat/feat-x "$sm_b_recorded" "[$label] sm-b feat preserved at recorded SHA"
        # §15: status reflects the resulting state. A successful force-remove
        # drops the worktree, so feat-x is no longer listed.
        assert_status_absent feat-x
    elif [[ "$any_dirty" -eq 1 ]]; then
        # Dirty without force → refuse + dirty edit preserved everywhere.
        [[ "$remove_failed" -eq 1 ]] \
            || { echo "[$label]"; cat out; fail "expected remove to refuse on dirty"; }
        [[ -e .worktree/feat-x ]] \
            || { echo "[$label]"; fail "worktree should be intact"; }
        assert_state_eq .worktree/feat-x      "$state_wt_p" "[$label] worktree parent"
        assert_state_eq .worktree/feat-x/sm-a "$state_wt_a" "[$label] worktree sm-a"
        assert_state_eq .worktree/feat-x/sm-b "$state_wt_b" "[$label] worktree sm-b"
        # Refusal returned before the preservation step — no feat branch
        # was fetched into main super's submodule git dirs.
        assert_no_branch sm-a feat/feat-x "[$label] sm-a feat NOT preserved on refuse"
        assert_no_branch sm-b feat/feat-x "[$label] sm-b feat NOT preserved on refuse"
        # And the "Preserved N" info line must NOT appear.
        grep -qE "Preserved.*submodule feat branch" out \
            && { echo "[$label]"; cat out; fail "preservation info line emitted on refuse"; } || true
        # §15: status reflects the resulting state. A refused remove retains
        # the worktree.
        assert_status feat-x "feat/feat-x"
    else
        # All clean, no force → succeed. Same preservation as force=1.
        [[ "$remove_failed" -eq 0 ]] \
            || { echo "[$label]"; cat out; fail "expected remove to succeed (clean)"; }
        [[ ! -e .worktree/feat-x ]] \
            || { echo "[$label]"; fail "worktree should be gone"; }
        assert_branch_at .    feat/feat-x "" "[$label] parent feat retained"
        assert_branch_at sm-a feat/feat-x "$sm_a_recorded" "[$label] sm-a feat preserved at recorded SHA"
        assert_branch_at sm-b feat/feat-x "$sm_b_recorded" "[$label] sm-b feat preserved at recorded SHA"
        # §15: status reflects the resulting state. A successful clean remove
        # drops the worktree, so feat-x is no longer listed.
        assert_status_absent feat-x
    fi

    cleanup_fixture
}

i=0
while [[ "$i" -lt 32 ]]; do
    p_d=$(( (i >> 0) & 1 ))
    a_d=$(( (i >> 1) & 1 ))
    b_d=$(( (i >> 2) & 1 ))
    staged=$(( (i >> 3) & 1 ))
    force=$(( (i >> 4) & 1 ))
    _run_case "$p_d" "$a_d" "$b_d" "$staged" "$force"
    i=$(( i + 1 ))
done

echo "All 32 remove state combinations verified."
