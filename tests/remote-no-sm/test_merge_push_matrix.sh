#!/usr/bin/env bash
# Matrix: `subgrove merge ... push=true` over the no-sm super. Single
# dimension:
#
#   super_origin ∈ {even, ahead}
#     even  — origin/main matches our local main (push FF-succeeds)
#     ahead — origin/main has a third-party commit beyond local (push rejected)
#
# 2 cells. Kept for structural symmetry with the with-sm tier's 8-cell
# matrix; reader who knows that file finds the same shape here.
#
# Outcome per cell:
#   even:  super origin advances to feat tip; rc=0
#   ahead: super origin stays at upstream; rc!=0
#
# Both: feat worktree byte-identical (Phase 2 only touches main super).
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

_run_cell() {
    local super_state="$1"
    local label="super=${super_state}"

    mkfixture_remote_no_sm "merge_push_matrix"
    cd "$FIXTURE_SUPER"

    ./subgrove new feat-x >out 2>&1
    register_feature_branch_no_sm feat/feat-x
    ( cd .worktree/feat-x && echo "feat parent $$" >> README \
        && git add README && git commit --quiet -m "feat parent" )

    local upstream_sha=""
    if [[ "$super_state" == "ahead" ]]; then
        upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream parent")"
        [[ -n "$upstream_sha" ]] || fail "[$label] push_to_origin_main returned empty"
    fi

    # Capture local feat tip + pre-merge origin SHA.
    local feat_super pre_super
    feat_super="$(git -C .worktree/feat-x rev-parse feat/feat-x)"
    pre_super="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"

    # user-data-rules.md: cmd_merge's Phase 2 only mutates main super.
    # The source (feat) worktree must be byte-identical post-merge for
    # every cell — including the rejected-push cell.
    local state_wt
    state_wt="$(snapshot_state .worktree/feat-x)"

    set +e
    ./subgrove merge feat-x push=true >out 2>&1
    local rc=$?
    set -e

    assert_state_eq .worktree/feat-x "$state_wt" "[$label] feat worktree"

    local actual
    actual="$(_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL")"
    if [[ "$super_state" == "ahead" ]]; then
        assert_eq "$upstream_sha" "$actual" "[$label] super should stay at upstream"
        assert_ne "0" "$rc" "[$label] merge should fail (non-FF super)"
    else
        assert_eq "$feat_super" "$actual" "[$label] super should advance to feat tip"
        assert_eq "0" "$rc" "[$label] merge should succeed (rc=0)"
    fi

    # §15: status reflects the resulting state (merge retains the worktree
    # in both cells, including the rejected-push cell).
    assert_status feat-x "feat/feat-x"

    cleanup_fixture_remote_no_sm
}

iter=0
for s_super in even ahead; do
    iter=$((iter + 1))
    _run_cell "$s_super"
done

echo "All $iter merge_push matrix combinations verified."
