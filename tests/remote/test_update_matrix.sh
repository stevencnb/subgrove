#!/usr/bin/env bash
# Matrix: `subgrove update` over real GitHub remotes. Two independent
# dimensions per submodule {sm-a, sm-b}:
#
#   origin ∈ {even, ahead}
#     even  — origin/main matches gitlink baseline (nothing to fetch)
#     ahead — origin/main has a third-party commit beyond baseline
#
#   peer ∈ {clean, local}
#     clean — peer worktree's sm main is at gitlink baseline (init state)
#     local — peer made a peer-side commit on sm main (no rebase, no push)
#
# Outcomes per sm (independent across sm-a and sm-b):
#   (even,  clean): peer.main unchanged at baseline tip
#   (even,  local): peer.main unchanged at peer-local tip
#   (ahead, clean): peer.main = new origin/main (FF advance)
#   (ahead, local): peer.main unchanged at peer-local tip + warn "diverged"
#
# 4 states^2 sms = 16 cells.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

# _setup_sm WT SM ORIGIN_STATE PEER_STATE URL
# Sets up the (origin, peer) state for the named sm under WT. Echoes
# the expected peer.main SHA after `subgrove update` runs. The caller
# captures the echo via $(...) to drive its assertions.
_setup_sm() {
    local wt="$1" sm="$2" origin_state="$3" peer_state="$4" url="$5"
    local sm_path="$wt/$sm"
    local baseline_sha new_origin_sha peer_local_sha

    # `--verify --quiet`: empty output + non-zero rc when the ref is
    # missing. Without these flags, plain `rev-parse main` echoes the
    # literal string "main" on miss and exits 128 — which would slip
    # past the [[ -n "$exp_a" ]] guard in _run_cell and cause
    # assert_branch_at to re-resolve "main" to the current SHA (false
    # positive masking a real fixture/subgrove failure).
    if ! baseline_sha="$(git -C "$sm_path" rev-parse --verify --quiet main)"; then
        echo "_setup_sm: $sm_path has no 'main' branch" >&2
        return 1
    fi

    if [[ "$peer_state" == "local" ]]; then
        (
            cd "$sm_path"
            git checkout --quiet main
            echo "peer-local $sm $$ $RANDOM" >> README
            git add README
            git commit --quiet -m "peer-side commit on $sm main"
            git checkout --quiet feat/feat-x
        )
        if ! peer_local_sha="$(git -C "$sm_path" rev-parse --verify --quiet main)"; then
            echo "_setup_sm: $sm_path lost 'main' branch after peer-side commit" >&2
            return 1
        fi
    fi

    if [[ "$origin_state" == "ahead" ]]; then
        # `|| return 1`: push_to_origin_main fails loud via `exit 1`, but
        # _setup_sm runs inside `exp_a="$(_setup_sm ...)"` — a nested
        # command substitution. Under bash 3.2 (no inherit_errexit) the
        # inner `exit` aborts only THIS subshell, not the outer one, so
        # without the explicit `|| return 1` a failed push would let
        # _setup_sm continue and echo a stale/garbage value. The return
        # converts it into an rc the outer assignment's set -e honors.
        new_origin_sha="$(push_to_origin_main "$url" "upstream $sm")" || return 1
    fi

    case "${origin_state}/${peer_state}" in
        even/clean)  echo "$baseline_sha" ;;
        even/local)  echo "$peer_local_sha" ;;
        ahead/clean) echo "$new_origin_sha" ;;
        ahead/local) echo "$peer_local_sha" ;;   # refused: peer stays
        # Defensive default: an unrecognized state (typo, future refactor)
        # would otherwise echo nothing → caller captures empty → downstream
        # assertions silently weaken to a "branch exists" check. Fail loud.
        *) echo "internal: bad state '${origin_state}/${peer_state}'" >&2
           return 1 ;;
    esac
}

_run_cell() {
    local sm_a_origin="$1" sm_a_peer="$2" sm_b_origin="$3" sm_b_peer="$4"
    local label="sm-a=${sm_a_origin}/${sm_a_peer} sm-b=${sm_b_origin}/${sm_b_peer}"

    mkfixture_remote "update_matrix"
    cd "$FIXTURE_SUPER"

    ./subgrove new feat-x >out 2>&1
    register_feature_branch feat/feat-x

    local exp_a exp_b
    exp_a="$(_setup_sm .worktree/feat-x sm-a "$sm_a_origin" "$sm_a_peer" "$SUBGROVE_TEST_SM_URL")"
    exp_b="$(_setup_sm .worktree/feat-x sm-b "$sm_b_origin" "$sm_b_peer" "$SUBGROVE_TEST_SM_URL2")"
    # bash 3.2 has no inherit_errexit, so a silent failure inside
    # _setup_sm's command-sub wouldn't abort the script — exp_* would
    # be empty and assert_branch_at would degrade to a no-SHA check.
    # Pin that the captures are non-empty.
    [[ -n "$exp_a" ]] || fail "[$label] _setup_sm sm-a returned empty"
    [[ -n "$exp_b" ]] || fail "[$label] _setup_sm sm-b returned empty"

    # user-data-rules.md: cmd_update is ref-only. The peer worktree's
    # working trees must be byte-identical across every cell, including
    # the (ahead, local) cells where update refuses to propagate.
    local state_wt_p state_wt_a state_wt_b
    state_wt_p="$(snapshot_state .worktree/feat-x)"
    state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
    state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"

    ./subgrove update feat-x >out 2>&1

    assert_branch_at .worktree/feat-x/sm-a main "$exp_a" "[$label] sm-a main"
    assert_branch_at .worktree/feat-x/sm-b main "$exp_b" "[$label] sm-b main"

    # Refusal warn must fire for any (ahead, local) cell — i.e. diverged.
    if [[ "$sm_a_origin" == "ahead" && "$sm_a_peer" == "local" ]]; then
        assert_grep out "sm-a.*(diverged|skipped)"
    fi
    if [[ "$sm_b_origin" == "ahead" && "$sm_b_peer" == "local" ]]; then
        assert_grep out "sm-b.*(diverged|skipped)"
    fi

    assert_state_eq .worktree/feat-x      "$state_wt_p" "[$label] peer parent"
    assert_state_eq .worktree/feat-x/sm-a "$state_wt_a" "[$label] peer sm-a"
    assert_state_eq .worktree/feat-x/sm-b "$state_wt_b" "[$label] peer sm-b"

    # §15: status reflects the resulting state.
    assert_status feat-x "feat/feat-x"

    cleanup_fixture_remote
}

iter=0
for a_origin in even ahead; do
for a_peer   in clean local; do
for b_origin in even ahead; do
for b_peer   in clean local; do
    iter=$((iter + 1))
    _run_cell "$a_origin" "$a_peer" "$b_origin" "$b_peer"
done; done; done; done

echo "All $iter update matrix combinations verified."
