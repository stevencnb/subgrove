#!/usr/bin/env bash
# Remote tests for `subgrove new` on a no-submodule super.
#
# Companion to tests/remote/test_new.sh. Pins the wire-only paths the
# local-no-sm fixture can't reach: super origin/main as the parent base
# and fetch-and-rebase-on-origin freshness. Per-submodule paths are N/A
# on a no-sm super; see remote/test_new.sh for those.
#
# user-data-rules.md: cmd_new creates a new worktree + branch but must
# NOT touch main super's working tree. Each case snapshots main super
# pre/new and asserts byte-identical state.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_remote_no_sm.sh"

# --- case: golden — no drift, baseline state ---
mkfixture_remote_no_sm new_golden
cd "$FIXTURE_SUPER"

state_main="$(snapshot_state .)"

./subgrove new feat-golden >out 2>&1
register_feature_branch_no_sm feat/feat-golden

assert_file_exists .worktree/feat-golden
assert_head_on .worktree/feat-golden feat/feat-golden
# Local main and origin/main identical at baseline, so feat base = both.
assert_branch_at . feat/feat-golden "$(git rev-parse main)"
# Distinguishes this tier from local-no-sm: parent fetch SUCCEEDS here
# (real origin) — local-no-sm always emits the warn line. If a future
# regression breaks origin fetch on a no-sm super, the warn would fire
# and this assertion catches it.
assert_grep_v out "warn: parent fetch failed"
# No-sm narration still fires (zero submodules to branch).
assert_grep out "Submodule branching skipped \(touch=none\)"
# Main super untouched — new only added .worktree/feat-golden (gitignored).
assert_state_eq . "$state_main" "[golden] main super"
# §15: status reflects the resulting state.
assert_status feat-golden "feat/feat-golden"
cleanup_fixture_remote_no_sm

# --- case: super origin ahead — feat branch uses origin/main as base ---
# A side-clone pushes a commit to super's main between fixture setup and
# our `new`. The feat branch must start at that new origin/main SHA, not
# at our (stale) local main.
mkfixture_remote_no_sm new_super_origin_ahead
cd "$FIXTURE_SUPER"
upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream super")"

state_main="$(snapshot_state .)"

./subgrove new feat-up >out 2>&1
register_feature_branch_no_sm feat/feat-up

assert_branch_at . feat/feat-up "$upstream_sha"
assert_state_eq . "$state_main" "[super_ahead] main super"
# §15: status reflects the resulting state.
assert_status feat-up "feat/feat-up"
cleanup_fixture_remote_no_sm

# --- case: super origin diverged — local has its own unpushed commits ---
# We commit locally (not pushed) AND a side-clone pushes a different
# commit to origin/main. `new` should base feat on origin/main, not on
# local main — the local commit is silently bypassed.
mkfixture_remote_no_sm new_super_diverged
cd "$FIXTURE_SUPER"

# Local-only commit (never pushed).
echo "local change $$" >> README
git add README
git commit --quiet -m "local-only commit"
local_sha="$(git rev-parse main)"

# Origin advances along a different history.
upstream_sha="$(push_to_origin_main "$SUBGROVE_TEST_SUPER_NO_SM_URL" "upstream super")"
assert_ne "$local_sha" "$upstream_sha" "diverge setup: local != upstream"

# Snapshot AFTER our setup commit — that's the user state we want
# preserved across `subgrove new`.
state_main="$(snapshot_state .)"

./subgrove new feat-div >out 2>&1
register_feature_branch_no_sm feat/feat-div

# Base is origin/main (the freshest available), not our local commit.
assert_branch_at . feat/feat-div "$upstream_sha"
# Our local commit is still on local main — `new` doesn't touch it.
assert_branch_at . main "$local_sha"
# Main super's parent untouched (working tree, index, diffs).
assert_state_eq . "$state_main" "[diverged] main super"
# §15: status reflects the resulting state.
assert_status feat-div "feat/feat-div"
cleanup_fixture_remote_no_sm

# --- case: parent branch already exists locally → refused ---
# Sanity check: `new` rejects name reuse. The refusal must also fire
# after a fresh remote clone (i.e. the check doesn't depend on local-
# fixture history shape).
mkfixture_remote_no_sm new_branch_collision
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x

# Snapshot AFTER the first `new` (which is supposed to succeed). The
# second `new` should refuse and leave everything byte-identical —
# the rollback trap matters here.
state_main="$(snapshot_state .)"
state_wt="$(snapshot_state .worktree/feat-x)"

set +e
./subgrove new feat-x >out 2>&1
rc=$?
set -e
assert_ne "0" "$rc" "second new with same name should fail"
assert_grep out "already exists"
# Refused new must not perturb anything — main super OR the existing
# feat worktree from the first new.
assert_state_eq .                "$state_main" "[collision] main super"
assert_state_eq .worktree/feat-x "$state_wt"   "[collision] existing feat worktree"
# §15: status reflects the resulting state.
assert_status feat-x "feat/feat-x"
cleanup_fixture_remote_no_sm

# --- case: linked-worktree refusal ---
# Pin that `cmd_new`'s `assert_main_worktree` still fires after a real
# clone — i.e. the linked-worktree detection doesn't accidentally depend
# on local-fixture quirks. Mirrors local-no-sm/test_new.sh::new_linked
# on a wire-cloned super.
mkfixture_remote_no_sm new_linked
cd "$FIXTURE_SUPER"
./subgrove new feat-host >out 2>&1
register_feature_branch_no_sm feat/feat-host
ln -s "$SUBGROVE_REPO_ROOT/subgrove" .worktree/feat-host/subgrove
cd .worktree/feat-host
if ./subgrove new feat-from-linked >out 2>&1; then
    cd "$FIXTURE_SUPER"
    fail "expected new to refuse from a linked worktree"
fi
assert_grep out "currently in a linked worktree"
cd "$FIXTURE_SUPER"
# §15: status reflects the resulting state.
assert_status feat-host "feat/feat-host"
assert_status_absent feat-from-linked
cleanup_fixture_remote_no_sm

# --- case: invalid names rejected ---
# These rejections fire BEFORE any origin fetch, so they're cheap on
# the wire. Mirrors the local-no-sm symmetric coverage; pins that the
# validate_name path doesn't change shape on a real clone.
mkfixture_remote_no_sm new_invalid
cd "$FIXTURE_SUPER"

if ./subgrove new ".dotleading" >out 2>&1; then
    fail "expected new to reject '.dotleading'"
fi
assert_grep out "must not start with '\.' or '-'"

if ./subgrove new "-dashleading" >out 2>&1; then
    fail "expected new to reject '-dashleading'"
fi
assert_grep out "must not start with '\.' or '-'"

if ./subgrove new "spaces in name" >out 2>&1; then
    fail "expected new to reject 'spaces in name'"
fi
assert_grep out "name must match"

if ./subgrove new "ba/d" >out 2>&1; then
    fail "expected new to reject 'ba/d'"
fi
assert_grep out "name must match"

if ./subgrove new "" >out 2>&1; then
    fail "expected new to reject ''"
fi
assert_grep out "feature name required"

[[ -z "$(ls .worktree 2>/dev/null)" ]] \
    || fail ".worktree/ should be empty after invalid-name rejections"
[[ -z "$(git for-each-ref --format='%(refname:short)' refs/heads/feat/ 2>/dev/null)" ]] \
    || fail "no feat/ branches should exist after invalid-name rejections"
# §15: status reflects the resulting state.
assert_status "no feature worktrees yet"
cleanup_fixture_remote_no_sm

# --- case: missing .worktree/ in .gitignore refused ---
mkfixture_remote_no_sm new_no_ignore
cd "$FIXTURE_SUPER"
> .gitignore
git add .gitignore
git commit --quiet -m "drop .worktree from .gitignore"
if ./subgrove new feat-noignore >out 2>&1; then
    fail "expected new to refuse when .worktree/ not gitignored"
fi
assert_grep out "\.worktree/ is not gitignored"
assert_file_absent .worktree/feat-noignore
assert_no_branch . feat/feat-noignore
# §15: status reflects the resulting state.
assert_status_absent feat-noignore
cleanup_fixture_remote_no_sm

# --- case: pre-existing worktree dir refused ---
mkfixture_remote_no_sm new_existing_dir
cd "$FIXTURE_SUPER"
mkdir -p .worktree/feat-collide
echo "sentinel" > .worktree/feat-collide/marker
if ./subgrove new feat-collide >out 2>&1; then
    fail "expected new to fail on pre-existing worktree dir"
fi
assert_grep out "\.worktree/feat-collide already exists"
assert_no_branch . feat/feat-collide
# Pre-existing contents untouched.
assert_file_exists .worktree/feat-collide/marker
[[ "$(cat .worktree/feat-collide/marker)" == "sentinel" ]] \
    || fail "pre-existing dir contents modified by failed new"
# §15: status reflects the resulting state. The pre-existing (non-worktree)
# .worktree/feat-collide dir is retained, so status enumerates it as a row.
assert_status feat-collide
cleanup_fixture_remote_no_sm

# --- case: pre-existing parent branch refused ---
mkfixture_remote_no_sm new_existing_branch
cd "$FIXTURE_SUPER"
git branch feat/feat-pre main
register_feature_branch_no_sm feat/feat-pre
pre_branch_sha="$(git rev-parse feat/feat-pre)"
if ./subgrove new feat-pre >out 2>&1; then
    fail "expected new to fail on pre-existing branch"
fi
assert_grep out "branch 'feat/feat-pre' already exists in parent repo"
assert_file_absent .worktree/feat-pre
assert_branch_at . feat/feat-pre "$pre_branch_sha"
# §15: status reflects the resulting state (no worktree dir created).
assert_status_absent feat-pre
cleanup_fixture_remote_no_sm

# --- case: dirty main super doesn't block new ---
# cmd_new doesn't `require_clean` the parent. Replicated here so a
# regression that only fires on a wire-cloned no-sm super is caught.
mkfixture_remote_no_sm new_dirty_super_ok
cd "$FIXTURE_SUPER"
echo "dirty parent" >> README
assert_pending_file . README unstaged
# Snapshot AFTER the dirty edit. `new` only adds the gitignored
# .worktree/feat-x (excluded from snapshot via -uno) and a feat branch
# (refs excluded), so main super — including the dirty README — must be
# byte-identical after.
state_main="$(snapshot_state .)"
./subgrove new feat-x >out 2>&1
register_feature_branch_no_sm feat/feat-x
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
assert_pending_file . README unstaged
assert_state_eq . "$state_main" "[dirty_super_ok] main super"
# §15: status reflects the resulting state.
assert_status feat-x "feat/feat-x"
cleanup_fixture_remote_no_sm

# --- case: custom WORKTREES_DIR honored against a real origin clone ---
# Mirrors remote/test_new.sh::new_custom_wtdir on a flat super.
mkfixture_remote_no_sm new_custom_wtdir
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
SUBGROVE_CONFIG_VERSION="0.2.0"
WORKTREES_DIR="wt"
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
printf 'wt/\n' >> .gitignore
mkdir wt
./subgrove new feat-wtdir >out 2>&1
register_feature_branch_no_sm feat/feat-wtdir
assert_file_exists wt/feat-wtdir
assert_file_absent .worktree/feat-wtdir
assert_head_on wt/feat-wtdir feat/feat-wtdir
# §15: status reflects the resulting state.
assert_status feat-wtdir "feat/feat-wtdir"
cleanup_fixture_remote_no_sm

# --- case: build failure keeps the worktree (wire-cloned no-sm super) ---
# Belt-and-suspenders over local-no-sm/test_new's new_build_fail_keeps (cf. the
# custom-WORKTREES_DIR case above): the build runs after setup, so a build
# failure keeps the worktree + branch rather than rolling back — independent of
# the fetch/push paths, pinned here against a real origin clone. BUILD_CHAIN=(.)
# builds in the worktree root since there are no submodules.
mkfixture_remote_no_sm new_build_fail_keeps
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
SUBGROVE_CONFIG_VERSION="0.2.0"
BUILD_CHAIN=(.)
BUILD_CMD="touch built-marker; false"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
# Commit so the pre-`new` snapshot is clean — otherwise the dirty .subgroverc
# edit is baked into the baseline and a regression that reverted it would slip
# past assert_state_eq (the local tier commits it for the same reason).
git add .subgroverc
git commit --quiet -m "build chain that runs and fails"
state_main="$(snapshot_state .)"
new_failed=0
./subgrove new feat-bc >out 2>&1 || new_failed=1
register_feature_branch_no_sm feat/feat-bc
[[ $new_failed -eq 1 ]] || fail "expected new to exit non-zero when the build fails"
# Reached the build phase, ran it in the worktree root, and reported the
# failure as a kept worktree.
assert_grep out "Running build chain"
assert_grep out "build failed in \."
assert_grep out "worktree kept"
# Failure + recovery are surfaced under the tagged ATTENTION / NEXT STEPS sections.
assert_grep out "ATTENTION"
assert_grep out "NEXT STEPS"
assert_grep_v out "rolling back"
# Worktree + branch survived, on the feature branch, with the artifact the
# build wrote before failing — the folder is kept intact, not cleaned out.
assert_file_exists .worktree/feat-bc
assert_head_on .worktree/feat-bc feat/feat-bc
assert_file_exists .worktree/feat-bc/built-marker
# The build did not commit, so the feat branch stayed at its base (origin/main).
assert_branch_at . feat/feat-bc "$(git rev-parse origin/main)"
# Main super byte-identical: the build ran in the worktree, never main super.
assert_state_eq . "$state_main" "[build_fail_keeps] main super"
# §15: status reflects the resulting state — the kept worktree is listed.
assert_status feat-bc "feat/feat-bc"
cleanup_fixture_remote_no_sm
