#!/usr/bin/env bash
# Matrix: `subgrove update` over the no-sm super. Single dimension:
#
#   super_origin ∈ {even, ahead}
#     even  — origin/main matches local main (nothing to fetch)
#     ahead — origin/main has a third-party commit beyond local
#
# 2 cells. Kept for structural symmetry with the with-sm tier's 16-cell
# matrix; reader who knows that file finds the same shape here.
#
# Outcome per cell:
#   even:  local main unchanged; refs/remotes/origin/main unchanged
#   ahead: local main unchanged; refs/remotes/origin/main = upstream SHA
#
# Both: `Updated 0 submodule main(s); 0 skipped` summary; main super +
# peer worktree byte-identical.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

_run_cell() {
    local super_state="$1"
    local label="super=${super_state}"

    mkfixture_remote_no_sm "update_matrix"
    cd "$FIXTURE_SUPER"

    ./subgrove new feat-x >out 2>&1
    register_feature_branch_no_sm feat/feat-x

    local local_main_pre origin_main_pre upstream_sha=""
    local_main_pre="$(git rev-parse main)"
    origin_main_pre="$(git rev-parse refs/remotes/origin/main)"

    if [[ "$super_state" == "ahead" ]]; then
        upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream super")"
        # Pin the captures are non-empty (bash 3.2 lacks inherit_errexit,
        # so a silent failure in the command sub would otherwise feed
        # empty through to a weakened assertion).
        [[ -n "$upstream_sha" ]] || fail "[$label] push_to_origin_main returned empty"
    fi

    # user-data-rules.md: cmd_update is ref-only. Working trees byte-
    # identical across every cell.
    local state_main state_wt
    state_main="$(snapshot_state .)"
    state_wt="$(snapshot_state .worktree/feat-x)"

    ./subgrove update feat-x >out 2>&1

    # Local main never moves in either cell.
    assert_eq "$local_main_pre" "$(git rev-parse main)" "[$label] local main"

    # origin/main reflects the cell.
    if [[ "$super_state" == "ahead" ]]; then
        assert_eq "$upstream_sha" "$(git rev-parse refs/remotes/origin/main)" \
            "[$label] origin/main advanced"
    else
        assert_eq "$origin_main_pre" "$(git rev-parse refs/remotes/origin/main)" \
            "[$label] origin/main unchanged"
    fi

    # Summary always truthful: zero submodules.
    assert_grep out "Updated 0 submodule main\(s\); 0 skipped"
    # Fetch succeeded (this is the wire-only distinction vs local-no-sm).
    assert_grep_v out "warn: parent fetch failed"

    assert_state_eq .               "$state_main" "[$label] main super"
    assert_state_eq .worktree/feat-x "$state_wt"   "[$label] peer"

    # §15: status reflects the resulting state (update retains the worktree).
    assert_status feat-x "feat/feat-x"

    cleanup_fixture_remote_no_sm
}

iter=0
for s_super in even ahead; do
    iter=$((iter + 1))
    _run_cell "$s_super"
done

echo "All $iter update matrix combinations verified."
