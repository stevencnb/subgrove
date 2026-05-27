#!/usr/bin/env bash
# Remote tests for `subgrove new`.
#
# `new` uses super's origin/main as the parent base when available. Per-
# submodule origin/main does NOT influence the submodule feat branch
# base — that always comes from the gitlink SHA in super's tree. The
# matrix tests don't repeat these axes; they're locked in here.
#
# user-data-rules.md: cmd_new creates a new worktree + branches but
# must NOT touch main super's working tree or any of its submodules.
# Each case snapshots main super pre/new and asserts byte-identical
# state. (The new .worktree/<name>/ dir is gitignored, so snapshot
# excludes it via -uno in `git status`.)
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote.sh"

# --- case: golden — no drift, baseline state ---
mkfixture_remote new_golden
cd "$FIXTURE_SUPER"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

./subgrove new feat-golden >out 2>&1
register_feature_branch feat/feat-golden

assert_file_exists .worktree/feat-golden
assert_head_on .worktree/feat-golden feat/feat-golden
assert_head_on .worktree/feat-golden/sm-a feat/feat-golden
assert_head_on .worktree/feat-golden/sm-b feat/feat-golden
# Local main and origin/main are identical at baseline, so feat base = both.
assert_branch_at . feat/feat-golden "$(git rev-parse main)"
# Main super untouched — new only added .worktree/feat-golden (gitignored).
assert_state_eq .    "$state_main_p" "[golden] main super parent"
assert_state_eq sm-a "$state_main_a" "[golden] main super sm-a"
assert_state_eq sm-b "$state_main_b" "[golden] main super sm-b"
cleanup_fixture_remote

# --- case: super origin ahead — feat branch uses origin/main as base ---
# A second clone pushes a commit to super's main between fixture setup
# and our `new`. The feat branch must start at that new origin/main SHA,
# not at our (stale) local main.
mkfixture_remote new_super_origin_ahead
cd "$FIXTURE_SUPER"
upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream super")"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

./subgrove new feat-up >out 2>&1
register_feature_branch feat/feat-up

assert_branch_at . feat/feat-up "$upstream_sha"
assert_head_on .worktree/feat-up/sm-a feat/feat-up
assert_head_on .worktree/feat-up/sm-b feat/feat-up
assert_state_eq .    "$state_main_p" "[super_ahead] main super parent"
assert_state_eq sm-a "$state_main_a" "[super_ahead] main super sm-a"
assert_state_eq sm-b "$state_main_b" "[super_ahead] main super sm-b"
cleanup_fixture_remote

# --- case: super origin diverged — local main has its own commits ---
# We commit locally (not pushed) AND someone else pushes a different
# commit to origin/main. `new` should base feat on origin/main, not
# local main — the local commit is silently bypassed (the warning of
# Origin freshness wins; the design note in cmd_new spells this out).
mkfixture_remote new_super_diverged
cd "$FIXTURE_SUPER"

# Local-only commit (never pushed).
echo "local change $$" >> README
git add README
git commit --quiet -m "local-only commit"
local_sha="$(git rev-parse main)"

# Origin advances along a different history.
upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_URL" "upstream super")"
assert_ne "$local_sha" "$upstream_sha" "diverge setup: local != upstream"

# Snapshot AFTER our setup commit — that's the user state we want
# preserved across `subgrove new`.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

./subgrove new feat-div >out 2>&1
register_feature_branch feat/feat-div

# Base is origin/main (the freshest available), not our local commit.
assert_branch_at . feat/feat-div "$upstream_sha"
# Our local commit is still on local main — `new` doesn't touch it.
assert_branch_at . main "$local_sha"
# Main super's parent + submodules untouched (working tree, index, diffs).
assert_state_eq .    "$state_main_p" "[diverged] main super parent"
assert_state_eq sm-a "$state_main_a" "[diverged] main super sm-a"
assert_state_eq sm-b "$state_main_b" "[diverged] main super sm-b"
cleanup_fixture_remote

# --- case: per-submodule origin ahead does NOT change feat base ---
# Submodule feat branches come from the gitlink SHA recorded in super's
# tree, not from origin/main of each submodule. Even when each sm's
# origin/main has advanced, the submodule feat branch must start at
# the gitlink SHA (= baseline tip in our fixture).
mkfixture_remote new_sm_origin_ahead
cd "$FIXTURE_SUPER"

# Capture gitlink SHAs from super's current tree (= baseline).
recorded_a="$(git ls-tree main sm-a | awk '{print $3}')"
recorded_b="$(git ls-tree main sm-b | awk '{print $3}')"

# Both submodule origins advance independently.
new_a_main="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL"  "upstream sm-a")"
new_b_main="$(push_to_origin_main "$SUBGROVE_TEST_SM_URL2" "upstream sm-b")"
assert_ne "$recorded_a" "$new_a_main" "test setup: sm-a origin should differ from gitlink"
assert_ne "$recorded_b" "$new_b_main" "test setup: sm-b origin should differ from gitlink"

state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"

./subgrove new feat-smup >out 2>&1
register_feature_branch feat/feat-smup

# Feat branches at gitlink SHAs, NOT at the advanced origin/main.
assert_branch_at .worktree/feat-smup/sm-a feat/feat-smup "$recorded_a"
assert_branch_at .worktree/feat-smup/sm-b feat/feat-smup "$recorded_b"
assert_state_eq .    "$state_main_p" "[sm_ahead] main super parent"
assert_state_eq sm-a "$state_main_a" "[sm_ahead] main super sm-a"
assert_state_eq sm-b "$state_main_b" "[sm_ahead] main super sm-b"
cleanup_fixture_remote

# --- case: parent branch already exists locally → refused ---
# Sanity check: `new` rejects name reuse. Local test covers the same
# refusal; here we confirm the refusal also fires after a fresh remote
# clone (i.e. the check doesn't depend on local-fixture history shape).
mkfixture_remote new_branch_collision
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch feat/feat-x

# Snapshot AFTER the first `new` (which is supposed to succeed). The
# second `new` should refuse and leave everything byte-identical —
# the rollback trap matters here.
state_main_p="$(snapshot_state .)"
state_main_a="$(snapshot_state sm-a)"
state_main_b="$(snapshot_state sm-b)"
state_wt_p="$(snapshot_state .worktree/feat-x)"
state_wt_a="$(snapshot_state .worktree/feat-x/sm-a)"
state_wt_b="$(snapshot_state .worktree/feat-x/sm-b)"

set +e
./subgrove new feat-x >out 2>&1
rc=$?
set -e
assert_ne "0" "$rc" "second new with same name should fail"
assert_grep out "already exists"
# Refused new must not perturb anything — main super OR the existing
# feat worktree from the first new.
assert_state_eq .                    "$state_main_p" "[collision] main super parent"
assert_state_eq sm-a                 "$state_main_a" "[collision] main super sm-a"
assert_state_eq sm-b                 "$state_main_b" "[collision] main super sm-b"
assert_state_eq .worktree/feat-x      "$state_wt_p" "[collision] existing feat worktree parent"
assert_state_eq .worktree/feat-x/sm-a "$state_wt_a" "[collision] existing feat worktree sm-a"
assert_state_eq .worktree/feat-x/sm-b "$state_wt_b" "[collision] existing feat worktree sm-b"
cleanup_fixture_remote

# --- case: custom WORKTREES_DIR honored against a real origin clone ---
# WORKTREES_DIR doesn't interact with the fetch/push paths, so this is
# belt-and-suspenders over the local custom-folder coverage: it pins that
# `new` places the worktree AND initialises submodules under the configured
# folder when run on a wire-cloned super.
mkfixture_remote new_custom_wtdir
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
WORKTREES_DIR="wt"
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
printf 'wt/\n' >> .gitignore   # configured folder must be gitignored
mkdir wt                       # exist-on-disk so check-ignore matches wt/
./subgrove new feat-wtdir >out 2>&1
register_feature_branch feat/feat-wtdir
assert_file_exists wt/feat-wtdir
assert_file_absent .worktree/feat-wtdir
assert_head_on wt/feat-wtdir feat/feat-wtdir
assert_head_on wt/feat-wtdir/sm-a feat/feat-wtdir
assert_head_on wt/feat-wtdir/sm-b feat/feat-wtdir
cleanup_fixture_remote
