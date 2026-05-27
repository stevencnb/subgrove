#!/usr/bin/env bash
# Matrix: `subgrove new` over the no-sm super. Two dimensions:
#
#   super_origin ∈ {even, ahead}
#     even  — origin/main matches the cloned baseline (no third-party push)
#     ahead — side-clone pushed a commit; origin/main is one beyond baseline
#
#   local_main ∈ {at_baseline, with_local_commit}
#     at_baseline       — local main has not moved since clone
#     with_local_commit — local has a commit on main (unpushed)
#
# 4 cells. Cmd_new uses refs/remotes/origin/main as the base when the
# fetch succeeds (see subgrove:194-198), so the local-commit-on-main
# state does NOT influence the feat-base SHA — origin wins. The matrix
# proves that's true across all four state combinations.
#
# Expected feat-base per cell:
#   even,  at_baseline:       baseline (= local = origin)
#   even,  with_local_commit: baseline (origin/main; local commit bypassed)
#   ahead, at_baseline:       upstream SHA
#   ahead, with_local_commit: upstream SHA (local commit preserved on main, not used as base)
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

_run_cell() {
    local super_state="$1" local_state="$2"
    local label="super=${super_state} local=${local_state}"

    mkfixture_remote_no_sm "new_matrix"
    cd "$FIXTURE_SUPER"

    local baseline_sha local_sha upstream_sha=""
    baseline_sha="$(git rev-parse main)"

    if [[ "$local_state" == "with_local_commit" ]]; then
        echo "local change $$ $RANDOM" >> README
        git add README
        git commit --quiet -m "local-only commit"
    fi
    local_sha="$(git rev-parse main)"

    if [[ "$super_state" == "ahead" ]]; then
        upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream $label")"
        # bash 3.2 has no inherit_errexit; pin the capture is non-empty.
        [[ -n "$upstream_sha" ]] || fail "[$label] push_to_origin_main returned empty"
    fi

    # Determine expected feat-base SHA. Origin wins when reachable.
    local expected
    case "${super_state}/${local_state}" in
        even/at_baseline)        expected="$baseline_sha" ;;
        even/with_local_commit)  expected="$baseline_sha" ;;
        ahead/at_baseline)       expected="$upstream_sha" ;;
        ahead/with_local_commit) expected="$upstream_sha" ;;
        # Defensive default: an unrecognized state (typo, future refactor)
        # would otherwise leave $expected empty → downstream assertions
        # silently weaken. Fail loud.
        *) fail "internal: bad state '${super_state}/${local_state}'" ;;
    esac

    # user-data-rules.md: main super preserved across `new` (only
    # gitignored .worktree/<name>/ added). Snapshot AFTER the local-
    # commit setup so the user's pre-new state is what we pin.
    local state_main
    state_main="$(snapshot_state .)"

    ./subgrove new feat-x >out 2>&1
    register_feature_branch_no_sm feat/feat-x

    assert_branch_at . feat/feat-x "$expected" "[$label] feat base"
    # Local main preserved at its pre-new SHA — `new` never moves it.
    assert_branch_at . main "$local_sha" "[$label] local main preserved"
    # Main super state preserved (refs change is intentional;
    # snapshot_state excludes refs).
    assert_state_eq . "$state_main" "[$label] main super"

    # §15: status reflects the resulting state.
    assert_status feat-x "feat/feat-x"

    cleanup_fixture_remote_no_sm
}

iter=0
for s_super in even ahead; do
for s_local in at_baseline with_local_commit; do
    iter=$((iter + 1))
    _run_cell "$s_super" "$s_local"
done; done

echo "All $iter new matrix combinations verified."
