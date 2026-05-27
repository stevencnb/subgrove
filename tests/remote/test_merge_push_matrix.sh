#!/usr/bin/env bash
# Matrix: `subgrove merge ... push=true` over real GitHub remotes,
# varying origin drift independently across the three packages.
#
#   even  — origin/main matches our local main (push FF-succeeds)
#   ahead — origin/main has a third-party commit beyond local (push rejected)
#
# 2 states^3 packages = 8 combinations.
#
# Outcome model (subgrove's push order: list_all_submodules then parent,
# which in our fixture is sm-a → sm-b → super; set -e aborts on first
# failed push):
#   - All packages "even": all three origins advance to feat tip.
#   - First "ahead" in push order: its origin stays at upstream, merge
#     exits non-zero, packages after it are never pushed.
#   - Packages before the first failure: their origin advances to feat tip.
#
# Cautious-with-push=true note: this matrix is the destructive one — every
# iteration force-resets all three origins via the fixture's baseline tag,
# so leakage between cells is impossible, and the per-iteration register/
# trap cleanup wipes feature branches at script exit.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

# Push order subgrove uses (matches list_all_submodules order then parent).
PUSH_ORDER="sm-a sm-b super"

_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

# _url_of PKG — echoes the URL for a package label.
_url_of() {
    case "$1" in
        super) echo "$SUBGROVE_TEST_SUPER_URL" ;;
        sm-a)  echo "$SUBGROVE_TEST_SM_URL" ;;
        sm-b)  echo "$SUBGROVE_TEST_SM_URL2" ;;
        *)     echo "internal: bad package '$1'" >&2; exit 99 ;;
    esac
}

_run_cell() {
    local super_state="$1" sm_a_state="$2" sm_b_state="$3"
    local label="super=${super_state} sm-a=${sm_a_state} sm-b=${sm_b_state}"

    mkfixture_remote "matrix"
    cd "$FIXTURE_SUPER"

    ./subgrove new feat-x >out 2>&1
    register_feature_branch feat/feat-x
    commit_one .worktree/feat-x/sm-a "feat sm-a"
    commit_one .worktree/feat-x/sm-b "feat sm-b"
    ( cd .worktree/feat-x && git add -A && git commit --quiet -m "bump both + parent" )

    # Set each origin state per the matrix cell. Parallel arrays index
    # super/sm-a/sm-b → upstream SHA (empty when state is "even").
    local upstream_super="" upstream_sm_a="" upstream_sm_b=""
    if [[ "$super_state" == "ahead" ]]; then
        upstream_super="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream super")"
    fi
    if [[ "$sm_a_state" == "ahead" ]]; then
        upstream_sm_a="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL" "upstream sm-a")"
    fi
    if [[ "$sm_b_state" == "ahead" ]]; then
        upstream_sm_b="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL2" "upstream sm-b")"
    fi

    # Capture local feat tips (what subgrove will attempt to push).
    local feat_super feat_sm_a feat_sm_b
    feat_super="$(git -C .worktree/feat-x      rev-parse feat/feat-x)"
    feat_sm_a="$( git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
    feat_sm_b="$( git -C .worktree/feat-x/sm-b rev-parse feat/feat-x)"

    # Capture pre-merge origin SHAs (used to confirm "untouched" packages).
    local pre_super pre_sm_a pre_sm_b
    pre_super="$(_origin_main "$SUBGROVE_TEST_SUPER_URL")"
    pre_sm_a="$( _origin_main "$SUBGROVE_TEST_SM_URL")"
    pre_sm_b="$( _origin_main "$SUBGROVE_TEST_SM_URL2")"

    # user-data-rules.md: cmd_merge's Phase 2 only mutates main super.
    # The source (feat) worktree must be byte-identical post-merge for
    # every cell — including the partial-failure ones where Phase 2
    # completed and push half-failed.
    local state_wt_p state_wt_a state_wt_b
    state_wt_p="$(snapshot_state .worktree/feat-x)"
    state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
    state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"

    set +e
    ./subgrove merge feat-x push=true >out 2>&1
    local rc=$?
    set -e

    assert_state_eq .worktree/feat-x      "$state_wt_p" "[$label] feat worktree parent"
    assert_state_eq .worktree/feat-x/sm-a "$state_wt_a" "[$label] feat worktree sm-a"
    assert_state_eq .worktree/feat-x/sm-b "$state_wt_b" "[$label] feat worktree sm-b"

    # Determine the first package to fail (first 'ahead' in push order).
    local first_fail="" pkg
    for pkg in $PUSH_ORDER; do
        case "$pkg" in
            super) [[ "$super_state" == "ahead" ]] && first_fail="$pkg" ;;
            sm-a)  [[ "$sm_a_state"  == "ahead" ]] && first_fail="$pkg" ;;
            sm-b)  [[ "$sm_b_state"  == "ahead" ]] && first_fail="$pkg" ;;
        esac
        [[ -n "$first_fail" ]] && break
    done

    # Per-package verification.
    local pushed_yet=1
    for pkg in $PUSH_ORDER; do
        local actual feat_tip upstream pre
        actual="$(_origin_main "$(_url_of "$pkg")")"
        case "$pkg" in
            super) feat_tip="$feat_super"; upstream="$upstream_super"; pre="$pre_super" ;;
            sm-a)  feat_tip="$feat_sm_a";  upstream="$upstream_sm_a";  pre="$pre_sm_a"  ;;
            sm-b)  feat_tip="$feat_sm_b";  upstream="$upstream_sm_b";  pre="$pre_sm_b"  ;;
        esac

        if [[ -z "$first_fail" ]]; then
            # All-even cell: every push succeeds.
            assert_eq "$feat_tip" "$actual" "[$label] $pkg should advance"
        elif [[ "$pkg" == "$first_fail" ]]; then
            assert_eq "$upstream" "$actual" "[$label] $pkg should stay at upstream"
            pushed_yet=0
        elif [[ "$pushed_yet" -eq 1 ]]; then
            assert_eq "$feat_tip" "$actual" "[$label] $pkg should advance (pushed before failure)"
        else
            assert_eq "$pre" "$actual" "[$label] $pkg should NOT advance (after failure)"
        fi
    done

    # Exit code: 0 iff every push succeeded.
    if [[ -z "$first_fail" ]]; then
        assert_eq "0" "$rc" "[$label] merge should succeed (rc=0)"
    else
        assert_ne "0" "$rc" "[$label] merge should fail (first-fail: $first_fail)"
    fi

    # §15: status reflects the resulting state.
    assert_status feat-x "feat/feat-x"

    cleanup_fixture_remote
}

iter=0
for s_super in even ahead; do
for s_sm_a  in even ahead; do
for s_sm_b  in even ahead; do
    iter=$((iter + 1))
    _run_cell "$s_super" "$s_sm_a" "$s_sm_b"
done; done; done

echo "All $iter merge_push matrix combinations verified."
