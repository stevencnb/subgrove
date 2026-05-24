#!/usr/bin/env bash
# Remote tests for `subgrove merge ... push=true`.
#
# Subgrove's push is FF-only (no --force). Push order matters on
# multi-package failures: it pushes submodules in .gitmodules order
# (sm-a, then sm-b), then parent. set -e on first failure → packages
# after the failure are never attempted; packages before are already
# advanced on the wire. This file pins both happy paths and the
# partial-failure half-state explicitly.
#
# user-data-rules.md: cmd_merge Phase 2 only mutates main super; the
# source (feat) worktree must survive byte-identically across every
# invocation, success or failure. Each case snapshots the feat
# worktree (parent + sm-a + sm-b) right before `subgrove merge` runs
# and asserts equality after. This is the same contract local merge
# tests pin via snapshot_state/assert_state_eq.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

# Helper: read URL's current main SHA off the wire. `--` terminates
# git's option parsing so a URL beginning with `-` (or a poisoned
# config value like `--upload-pack=...`) can't sneak in as an option.
_origin_main() {
    git ls-remote -- "$1" refs/heads/main | awk '{print $1}'
}

# --- case: golden — both submodules touched; all three origins advance ---
mkfixture_remote merge_push_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-g >out 2>&1
register_feature_branch feat/feat-g

commit_one .worktree/feat-g/sm-a "sm-a feat"
commit_one .worktree/feat-g/sm-b "sm-b feat"
( cd .worktree/feat-g && git add -A && git commit --quiet -m "bump sm-a + sm-b" )

state_wt_p="$(snapshot_state .worktree/feat-g)"
state_wt_a="$(snapshot_state .worktree/feat-g/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-g/sm-b)"

./subgrove merge feat-g push=true >out 2>&1

# Phase 2 only touches main super; feat worktree must be byte-identical.
assert_state_eq .worktree/feat-g      "$state_wt_p" "[golden] feat worktree parent"
assert_state_eq .worktree/feat-g/sm-a "$state_wt_a" "[golden] feat worktree sm-a"
assert_state_eq .worktree/feat-g/sm-b "$state_wt_b" "[golden] feat worktree sm-b"

feat_super="$(git -C .worktree/feat-g      rev-parse feat/feat-g)"
feat_sm_a="$( git -C .worktree/feat-g/sm-a rev-parse feat/feat-g)"
feat_sm_b="$( git -C .worktree/feat-g/sm-b rev-parse feat/feat-g)"

assert_eq "$feat_super" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super origin = feat tip"
assert_eq "$feat_sm_a"  "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a origin = feat tip"
assert_eq "$feat_sm_b"  "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b origin = feat tip"
cleanup_fixture_remote

# --- case: super only — parent edit, no submodule changes; only super pushed ---
mkfixture_remote merge_push_super_only
cd "$FIXTURE_SUPER"
./subgrove new feat-so >out 2>&1
register_feature_branch feat/feat-so

# Only the parent gets a commit — no submodule touched.
( cd .worktree/feat-so && echo "parent change $$" >> README \
    && git add README && git commit --quiet -m "parent-only commit" )

state_wt_p="$(snapshot_state .worktree/feat-so)"
state_wt_a="$(snapshot_state .worktree/feat-so/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-so/sm-b)"

sm_a_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL")"
sm_b_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL2")"

./subgrove merge feat-so push=true >out 2>&1

assert_state_eq .worktree/feat-so      "$state_wt_p" "[super_only] feat worktree parent"
assert_state_eq .worktree/feat-so/sm-a "$state_wt_a" "[super_only] feat worktree sm-a"
assert_state_eq .worktree/feat-so/sm-b "$state_wt_b" "[super_only] feat worktree sm-b"

feat_super="$(git -C .worktree/feat-so rev-parse feat/feat-so)"
assert_eq "$feat_super" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super advanced"
assert_eq "$sm_a_pre"   "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a unchanged"
assert_eq "$sm_b_pre"   "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b unchanged"
cleanup_fixture_remote

# --- case: one sm — sm-a touched, sm-b not; sm-b origin stays put ---
mkfixture_remote merge_push_one_sm
cd "$FIXTURE_SUPER"
./subgrove new feat-1 >out 2>&1
register_feature_branch feat/feat-1

commit_one .worktree/feat-1/sm-a "sm-a only"
( cd .worktree/feat-1 && git add -A && git commit --quiet -m "bump sm-a" )

state_wt_p="$(snapshot_state .worktree/feat-1)"
state_wt_a="$(snapshot_state .worktree/feat-1/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-1/sm-b)"

sm_b_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL2")"

./subgrove merge feat-1 push=true >out 2>&1

assert_state_eq .worktree/feat-1      "$state_wt_p" "[one_sm] feat worktree parent"
assert_state_eq .worktree/feat-1/sm-a "$state_wt_a" "[one_sm] feat worktree sm-a"
assert_state_eq .worktree/feat-1/sm-b "$state_wt_b" "[one_sm] feat worktree sm-b"

feat_super="$(git -C .worktree/feat-1      rev-parse feat/feat-1)"
feat_sm_a="$( git -C .worktree/feat-1/sm-a rev-parse feat/feat-1)"
assert_eq "$feat_super" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super advanced"
assert_eq "$feat_sm_a"  "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a advanced"
assert_eq "$sm_b_pre"   "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b unchanged"
cleanup_fixture_remote

# --- case: nothing to push — no edits anywhere; output narrates skip ---
mkfixture_remote merge_push_nothing
cd "$FIXTURE_SUPER"
./subgrove new feat-n >out 2>&1
register_feature_branch feat/feat-n

state_wt_p="$(snapshot_state .worktree/feat-n)"
state_wt_a="$(snapshot_state .worktree/feat-n/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-n/sm-b)"

# Nothing-to-push also implies main super shouldn't move — capture it.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_URL")"
sm_a_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL")"
sm_b_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL2")"

./subgrove merge feat-n push=true >out 2>&1
assert_grep out "Nothing to merge|Push skipped"

assert_state_eq .worktree/feat-n      "$state_wt_p" "[nothing] feat worktree parent"
assert_state_eq .worktree/feat-n/sm-a "$state_wt_a" "[nothing] feat worktree sm-a"
assert_state_eq .worktree/feat-n/sm-b "$state_wt_b" "[nothing] feat worktree sm-b"
# Main super untouched too (no Phase 2 work).
assert_state_eq .                     "$state_main_p" "[nothing] main super parent"
assert_state_eq sm-a                  "$state_main_a" "[nothing] main super sm-a"
assert_state_eq sm-b                  "$state_main_b" "[nothing] main super sm-b"

assert_eq "$super_pre" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super unchanged"
assert_eq "$sm_a_pre"  "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a unchanged"
assert_eq "$sm_b_pre"  "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b unchanged"
cleanup_fixture_remote

# --- case: non-FF super — origin/super advanced; super push rejected ---
# Submodule pushes (sm-a, sm-b in order) succeed because the test only
# commits in the parent; sm origin/main matches local sm main (no push
# needed, both at gitlink — subgrove's filter skips them as "no commits").
# The parent push fails: origin/super is at upstream, local feat is one
# commit beyond stale baseline → non-FF.
mkfixture_remote merge_push_non_ff_super
cd "$FIXTURE_SUPER"
./subgrove new feat-nffs >out 2>&1
register_feature_branch feat/feat-nffs
( cd .worktree/feat-nffs && echo "feat parent $$" >> README \
    && git add README && git commit --quiet -m "feat parent" )

upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream parent")"

state_wt_p="$(snapshot_state .worktree/feat-nffs)"
state_wt_a="$(snapshot_state .worktree/feat-nffs/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-nffs/sm-b)"

set +e
./subgrove merge feat-nffs push=true >out 2>&1
rc=$?
set -e

assert_ne "0" "$rc" "merge push=true should fail (non-FF super)"
assert_eq "$upstream_sha" "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" \
    "super origin stays at upstream"
# Feat worktree untouched even though Phase 2 + push happened. User's
# work-in-progress is preserved regardless of push outcome.
assert_state_eq .worktree/feat-nffs      "$state_wt_p" "[non_ff_super] feat worktree parent"
assert_state_eq .worktree/feat-nffs/sm-a "$state_wt_a" "[non_ff_super] feat worktree sm-a"
assert_state_eq .worktree/feat-nffs/sm-b "$state_wt_b" "[non_ff_super] feat worktree sm-b"
cleanup_fixture_remote

# --- case: non-FF sm-a — origin/sm-a advanced; sm-a push rejected, super never pushed ---
# Subgrove pushes sm-a first; that push fails, set -e aborts the merge
# before sm-b or super are pushed. Half-state: sm-a origin stays at
# upstream, sm-b and super origins unchanged from pre-merge.
mkfixture_remote merge_push_non_ff_sm
cd "$FIXTURE_SUPER"
./subgrove new feat-nffsm >out 2>&1
register_feature_branch feat/feat-nffsm

commit_one .worktree/feat-nffsm/sm-a "sm-a feat"
( cd .worktree/feat-nffsm && git add -A && git commit --quiet -m "bump sm-a" )

sm_a_upstream="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL" "upstream sm-a")"
sm_b_pre="$(_origin_main "$SUBGROVE_TEST_SM_URL2")"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_URL")"

state_wt_p="$(snapshot_state .worktree/feat-nffsm)"
state_wt_a="$(snapshot_state .worktree/feat-nffsm/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-nffsm/sm-b)"

set +e
./subgrove merge feat-nffsm push=true >out 2>&1
rc=$?
set -e

assert_ne "0" "$rc" "merge push=true should fail (non-FF sm-a)"
assert_eq "$sm_a_upstream" "$(_origin_main "$SUBGROVE_TEST_SM_URL")"  "sm-a origin stays at upstream"
assert_eq "$sm_b_pre"      "$(_origin_main "$SUBGROVE_TEST_SM_URL2")" "sm-b never pushed"
assert_eq "$super_pre"     "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super never pushed"
# Feat worktree untouched even with the multi-phase failure.
assert_state_eq .worktree/feat-nffsm      "$state_wt_p" "[non_ff_sm] feat worktree parent"
assert_state_eq .worktree/feat-nffsm/sm-a "$state_wt_a" "[non_ff_sm] feat worktree sm-a"
assert_state_eq .worktree/feat-nffsm/sm-b "$state_wt_b" "[non_ff_sm] feat worktree sm-b"
cleanup_fixture_remote

# --- case: partial failure — sm-a pushes OK, sm-b push rejected ---
# Pins subgrove's current half-state contract: when a multi-sm push fails
# mid-sequence, packages pushed earlier are already advanced on the wire
# and there is no rollback. A future improvement (e.g. two-phase push
# with pre-validation across all remotes) would need to update this.
mkfixture_remote merge_push_partial_fail
cd "$FIXTURE_SUPER"
./subgrove new feat-pf >out 2>&1
register_feature_branch feat/feat-pf

commit_one .worktree/feat-pf/sm-a "sm-a feat"
commit_one .worktree/feat-pf/sm-b "sm-b feat"
( cd .worktree/feat-pf && git add -A && git commit --quiet -m "bump both sm" )

# sm-b origin advanced — sm-a's push will succeed first, then sm-b fails.
sm_b_upstream="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL2" "upstream sm-b")"
super_pre="$(_origin_main "$SUBGROVE_TEST_SUPER_URL")"

feat_sm_a="$(git -C .worktree/feat-pf/sm-a rev-parse feat/feat-pf)"

state_wt_p="$(snapshot_state .worktree/feat-pf)"
state_wt_a="$(snapshot_state .worktree/feat-pf/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-pf/sm-b)"

set +e
./subgrove merge feat-pf push=true >out 2>&1
rc=$?
set -e

assert_ne "0" "$rc" "merge push=true should fail on partial sm-b failure"
assert_eq "$feat_sm_a"     "$(_origin_main "$SUBGROVE_TEST_SM_URL")"    "sm-a advanced (pushed before failure)"
assert_eq "$sm_b_upstream" "$(_origin_main "$SUBGROVE_TEST_SM_URL2")"   "sm-b stays at upstream"
assert_eq "$super_pre"     "$(_origin_main "$SUBGROVE_TEST_SUPER_URL")" "super never pushed (after failure)"
# Even on partial-failure (Phase 2 complete, push half-done), the source
# feat worktree must be byte-identical — user's work-in-progress preserved.
assert_state_eq .worktree/feat-pf      "$state_wt_p" "[partial_fail] feat worktree parent"
assert_state_eq .worktree/feat-pf/sm-a "$state_wt_a" "[partial_fail] feat worktree sm-a"
assert_state_eq .worktree/feat-pf/sm-b "$state_wt_b" "[partial_fail] feat worktree sm-b"
cleanup_fixture_remote
