#!/usr/bin/env bash
# State matrix for `subgrove merge`. Iterates every combination of
# (uncommitted, commits) across parent + sm-a + sm-b in the feature
# worktree — 2^6 = 64 combinations.
#
# Each iteration builds a fresh fixture, sets up the state, runs
# `subgrove merge feat-x`, and verifies the outcome.
#
# Staging dimension: `staged` alternates per iteration so both variants
# of `require_clean` (it checks both `git diff --quiet` AND
# `git diff --cached --quiet`) get exercised across the matrix.
#
# Implicit parent dirty: when a submodule has commits but `parent_commits`
# is 0, the parent's working tree shows `M <submodule>` (recorded SHA in
# parent's index doesn't match the new submodule HEAD). That counts as a
# dirty parent for require_clean's purposes. The prediction logic below
# folds this into `effective_parent_dirty`.
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

# _verify_pre_state — confirms the setup produced EXACTLY the expected state
# across all 6 locations before the merge runs. Per location:
#   - commit count on feat branch (vs main)
#   - pending change for README (none | unstaged | staged)
#   - implicit M <submodule> in worktree parent when a/b_com=1 but p_com=0
# Verifying pre-state catches bugs in the matrix's setup logic itself, not
# just in subgrove — without this, a silently-failed `commit_one` or a
# botched dirty edit would make a wrong-state test pass by accident.
_verify_pre_state() {
    local p_unc="$1" p_com="$2" a_unc="$3" a_com="$4" b_unc="$5" b_com="$6" staged="$7" label="$8"
    local mode="unstaged"
    [[ "$staged" -eq 1 ]] && mode="staged"

    # Main super: matrix never dirties or commits here. Always clean.
    assert_clean .
    assert_clean sm-a
    assert_clean sm-b

    # Worktree parent: README pending iff p_unc=1; implicit M sm-X when a
    # submodule has commits but parent didn't bump; feat commit count.
    if [[ "$p_unc" -eq 1 ]]; then
        assert_pending_file .worktree/feat-x README "$mode" "[$label] wt parent README"
    else
        assert_pending_file .worktree/feat-x README none "[$label] wt parent README clean"
    fi
    if [[ "$a_com" -eq 1 && "$p_com" -eq 0 ]]; then
        assert_pending_submodule .worktree/feat-x sm-a "[$label] implicit M sm-a"
    fi
    if [[ "$b_com" -eq 1 && "$p_com" -eq 0 ]]; then
        assert_pending_submodule .worktree/feat-x sm-b "[$label] implicit M sm-b"
    fi
    if [[ "$p_com" -eq 1 ]]; then
        assert_commits_ahead .worktree/feat-x main feat/feat-x 1 "[$label] feat parent has 1 commit"
    else
        assert_commits_ahead .worktree/feat-x main feat/feat-x 0 "[$label] feat parent has 0 commits"
    fi

    # Worktree sm-a: pending iff a_unc=1; commit count iff a_com=1.
    if [[ "$a_unc" -eq 1 ]]; then
        assert_pending_file .worktree/feat-x/sm-a README "$mode" "[$label] wt sm-a README"
    else
        assert_pending_file .worktree/feat-x/sm-a README none "[$label] wt sm-a README clean"
    fi
    if [[ "$a_com" -eq 1 ]]; then
        assert_commits_ahead .worktree/feat-x/sm-a main feat/feat-x 1 "[$label] wt sm-a 1 commit"
    else
        assert_commits_ahead .worktree/feat-x/sm-a main feat/feat-x 0 "[$label] wt sm-a 0 commits"
    fi

    # Worktree sm-b: symmetric to sm-a.
    if [[ "$b_unc" -eq 1 ]]; then
        assert_pending_file .worktree/feat-x/sm-b README "$mode" "[$label] wt sm-b README"
    else
        assert_pending_file .worktree/feat-x/sm-b README none "[$label] wt sm-b README clean"
    fi
    if [[ "$b_com" -eq 1 ]]; then
        assert_commits_ahead .worktree/feat-x/sm-b main feat/feat-x 1 "[$label] wt sm-b 1 commit"
    else
        assert_commits_ahead .worktree/feat-x/sm-b main feat/feat-x 0 "[$label] wt sm-b 0 commits"
    fi
}

_run_case() {
    local p_unc="$1" p_com="$2" a_unc="$3" a_com="$4" b_unc="$5" b_com="$6" staged="$7"
    local label="P=(u=$p_unc,c=$p_com) A=(u=$a_unc,c=$a_com) B=(u=$b_unc,c=$b_com) staged=$staged"

    mkfixture_local "merge_matrix"
    cd "$FIXTURE_SUPER"

    ./subgrove new feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "new failed"; }

    # Sanity-check that subgrove new actually created the feat branches
    # we'll be operating on. Catches a regression where `new` silently
    # skips branch creation — the matrix's state-preservation assertions
    # wouldn't otherwise detect this.
    git rev-parse --verify --quiet refs/heads/feat/feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "parent feat branch not created by new"; }
    git -C .worktree/feat-x/sm-a rev-parse --verify --quiet refs/heads/feat/feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "sm-a feat branch not created by new"; }
    git -C .worktree/feat-x/sm-b rev-parse --verify --quiet refs/heads/feat/feat-x >/dev/null 2>&1 \
        || { echo "[$label]"; fail "sm-b feat branch not created by new"; }

    # Commits: submodules first (they advance their own feat branches),
    # then parent (which captures the bumps + any parent-only edit).
    if [[ "$a_com" -eq 1 ]]; then commit_one .worktree/feat-x/sm-a "sm-a feat"; fi
    if [[ "$b_com" -eq 1 ]]; then commit_one .worktree/feat-x/sm-b "sm-b feat"; fi
    if [[ "$p_com" -eq 1 ]]; then
        (
            cd .worktree/feat-x
            # If no submodule commits, give the parent its own edit to
            # commit. Otherwise the commit captures the submodule bumps.
            if [[ "$a_com" -eq 0 && "$b_com" -eq 0 ]]; then
                echo "parent change" >> README
            fi
            git add -A
            git commit --quiet -m "parent commit"
        )
    fi

    # Dirty edits (AFTER commits, so the dirty isn't absorbed into a bump).
    if [[ "$p_unc" -eq 1 ]]; then _apply_dirty .worktree/feat-x        "$staged"; fi
    if [[ "$a_unc" -eq 1 ]]; then _apply_dirty .worktree/feat-x/sm-a   "$staged"; fi
    if [[ "$b_unc" -eq 1 ]]; then _apply_dirty .worktree/feat-x/sm-b   "$staged"; fi

    # Verify the setup produced the exact expected state across all 6
    # locations (commits + pending changes per repo). Catches setup bugs.
    _verify_pre_state "$p_unc" "$p_com" "$a_unc" "$a_com" "$b_unc" "$b_com" "$staged" "$label"

    # Snapshot full state of all six locations BEFORE merge. Used in the
    # refuse and "nothing to merge" branches to verify that subgrove
    # didn't touch ANYTHING — refs, working tree, or index — including
    # that pending dirty edits are still on disk afterward.
    local pre_p pre_a pre_b
    pre_p="$(git rev-parse main)"
    pre_a="$(git -C sm-a rev-parse main)"
    pre_b="$(git -C sm-b rev-parse main)"
    local state_main_p state_main_a state_main_b
    local state_wt_p   state_wt_a   state_wt_b
    state_main_p="$(snapshot_state .)"
    state_main_a="$(snapshot_state sm-a)"
    state_main_b="$(snapshot_state sm-b)"
    state_wt_p="$(snapshot_state .worktree/feat-x)"
    state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
    state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"

    local merge_failed=0
    ./subgrove merge feat-x >out 2>&1 || merge_failed=1

    # Predict
    local implicit_p_dirty=0
    if [[ ( "$a_com" -eq 1 || "$b_com" -eq 1 ) && "$p_com" -eq 0 ]]; then
        implicit_p_dirty=1
    fi
    local any_dirty=0
    if [[ "$p_unc" -eq 1 || "$a_unc" -eq 1 || "$b_unc" -eq 1 || "$implicit_p_dirty" -eq 1 ]]; then
        any_dirty=1
    fi
    local any_commits=0
    if [[ "$p_com" -eq 1 || "$a_com" -eq 1 || "$b_com" -eq 1 ]]; then
        any_commits=1
    fi

    if [[ "$any_dirty" -eq 1 ]]; then
        # Expect refuse — and NOTHING anywhere should have moved. Full
        # state preservation across all 6 locations (refs + working tree
        # + index + pending edits).
        [[ "$merge_failed" -eq 1 ]] \
            || { echo "[$label]"; cat out; fail "expected merge to refuse on dirty"; }
        assert_state_eq .                     "$state_main_p" "[$label] main super parent"
        assert_state_eq sm-a                  "$state_main_a" "[$label] main super sm-a"
        assert_state_eq sm-b                  "$state_main_b" "[$label] main super sm-b"
        assert_state_eq .worktree/feat-x      "$state_wt_p"   "[$label] worktree parent"
        assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"   "[$label] worktree sm-a"
        assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"   "[$label] worktree sm-b"
        # Phase 2 info lines must NOT appear — refusal happened in Phase 0.
        grep -qE "Moving main forward" out \
            && { echo "[$label]"; cat out; fail "Phase 2 info line emitted on refuse"; } || true
        grep -qE "Fast-forwarding parent main" out \
            && { echo "[$label]"; cat out; fail "parent FF info line emitted on refuse"; } || true
        # §15: status reflects the resulting state. A refused merge retains
        # the worktree.
        assert_status feat-x "feat/feat-x"
    elif [[ "$any_commits" -eq 0 ]]; then
        # All clean + no commits → "Nothing to merge" + no state changes
        # anywhere (Phase 0 filter empties needs_merge, parent_needs_merge
        # is false, both phases skip).
        [[ "$merge_failed" -eq 0 ]] \
            || { echo "[$label]"; cat out; fail "expected merge to succeed (nothing to merge)"; }
        grep -qE "Nothing to merge" out \
            || { echo "[$label]"; fail "expected 'Nothing to merge' in output"; }
        assert_state_eq .                     "$state_main_p" "[$label] main super parent"
        assert_state_eq sm-a                  "$state_main_a" "[$label] main super sm-a"
        assert_state_eq sm-b                  "$state_main_b" "[$label] main super sm-b"
        assert_state_eq .worktree/feat-x      "$state_wt_p"   "[$label] worktree parent"
        assert_state_eq .worktree/feat-x/sm-a "$state_wt_a"   "[$label] worktree sm-a"
        assert_state_eq .worktree/feat-x/sm-b "$state_wt_b"   "[$label] worktree sm-b"
        # §15: status reflects the resulting state. A no-op merge retains the
        # worktree.
        assert_status feat-x "feat/feat-x"
    else
        # Clean, has commits → merge succeeds; advance per commits.
        # Worktree is retained as-is (refs + working tree + index).
        [[ "$merge_failed" -eq 0 ]] \
            || { echo "[$label]"; cat out; fail "expected merge to succeed"; }
        local parent_feat
        parent_feat="$(git -C .worktree/feat-x rev-parse feat/feat-x)"
        [[ "$(git rev-parse main)" == "$parent_feat" ]] \
            || { echo "[$label]"; fail "parent main should advance to feat tip"; }
        # Every commit between old main and feat tip is now in main's
        # history (FF correctness — verifies subgrove didn't squash or
        # otherwise reshape history).
        local sha
        for sha in $(git -C .worktree/feat-x rev-list "$pre_p..feat/feat-x"); do
            assert_ancestor . "$sha" main "[$label] parent history"
        done
        if [[ "$a_com" -eq 1 ]]; then
            local a_feat
            a_feat="$(git -C .worktree/feat-x/sm-a rev-parse feat/feat-x)"
            [[ "$(git -C sm-a rev-parse main)" == "$a_feat" ]] \
                || { echo "[$label]"; fail "sm-a main should advance"; }
            for sha in $(git -C .worktree/feat-x/sm-a rev-list "$pre_a..feat/feat-x"); do
                assert_ancestor sm-a "$sha" main "[$label] sm-a history"
            done
        else
            [[ "$(git -C sm-a rev-parse main)" == "$pre_a" ]] \
                || { echo "[$label]"; fail "sm-a main should NOT advance"; }
        fi
        if [[ "$b_com" -eq 1 ]]; then
            local b_feat
            b_feat="$(git -C .worktree/feat-x/sm-b rev-parse feat/feat-x)"
            [[ "$(git -C sm-b rev-parse main)" == "$b_feat" ]] \
                || { echo "[$label]"; fail "sm-b main should advance"; }
            for sha in $(git -C .worktree/feat-x/sm-b rev-list "$pre_b..feat/feat-x"); do
                assert_ancestor sm-b "$sha" main "[$label] sm-b history"
            done
        else
            [[ "$(git -C sm-b rev-parse main)" == "$pre_b" ]] \
                || { echo "[$label]"; fail "sm-b main should NOT advance"; }
        fi
        # Worktree retained exactly as it was — subgrove's Phase 2 only
        # touches main super, not the worktree it merged from.
        assert_state_eq .worktree/feat-x      "$state_wt_p" "[$label] worktree parent (success)"
        assert_state_eq .worktree/feat-x/sm-a "$state_wt_a" "[$label] worktree sm-a (success)"
        assert_state_eq .worktree/feat-x/sm-b "$state_wt_b" "[$label] worktree sm-b (success)"
        # §15: status reflects the resulting state. A successful merge retains
        # the worktree.
        assert_status feat-x "feat/feat-x"
    fi

    cleanup_fixture
}

# 64 combinations encoded as a 6-bit integer.
i=0
while [[ "$i" -lt 64 ]]; do
    p_unc=$(( (i >> 0) & 1 ))
    p_com=$(( (i >> 1) & 1 ))
    a_unc=$(( (i >> 2) & 1 ))
    a_com=$(( (i >> 3) & 1 ))
    b_unc=$(( (i >> 4) & 1 ))
    b_com=$(( (i >> 5) & 1 ))
    staged=$(( i & 1 ))   # alternate per iteration
    _run_case "$p_unc" "$p_com" "$a_unc" "$a_com" "$b_unc" "$b_com" "$staged"
    i=$(( i + 1 ))
done

echo "All 64 merge state combinations verified."
