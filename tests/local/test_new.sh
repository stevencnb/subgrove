#!/usr/bin/env bash
# Tests for `subgrove new`.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# --- case: golden, touch=all default ---
mkfixture_local new_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
assert_head_on .worktree/feat-x/sm-a feat/feat-x
assert_head_on .worktree/feat-x/sm-b feat/feat-x
# Super has no origin; subgrove's base falls back to local main.
assert_branch_at . feat/feat-x "$(git rev-parse main)"
# Worktree's submodule HEADs match the gitlink SHAs in the parent's tree —
# i.e. submodule init checked out the SHAs that the parent commit records.
recorded_a="$(git ls-tree feat/feat-x sm-a | awk '{print $3}')"
recorded_b="$(git ls-tree feat/feat-x sm-b | awk '{print $3}')"
[[ "$(git -C .worktree/feat-x/sm-a rev-parse HEAD)" == "$recorded_a" ]] \
    || fail "worktree's sm-a HEAD doesn't match parent's recorded sm-a SHA"
[[ "$(git -C .worktree/feat-x/sm-b rev-parse HEAD)" == "$recorded_b" ]] \
    || fail "worktree's sm-b HEAD doesn't match parent's recorded sm-b SHA"
# Behaviorally-significant info-line output (catches a regression where
# subgrove changed its narration to no longer reflect what it did).
assert_grep out "Branching 2 submodule\(s\) to feat/feat-x"
assert_grep out "No BUILD_CHAIN configured"
cleanup_fixture

# --- case: touch=sm-a (subset) ---
# sm-b is initialised but un-branched — HEAD must be DETACHED at the
# parent's recorded SHA (the documented behavior for untouched submodules).
mkfixture_local new_touch_subset
cd "$FIXTURE_SUPER"
./subgrove new feat-y touch=sm-a >out 2>&1
assert_head_on .worktree/feat-y/sm-a feat/feat-y
assert_no_branch .worktree/feat-y/sm-b feat/feat-y
sm_b_recorded="$(git -C .worktree/feat-y ls-tree feat/feat-y sm-b | awk '{print $3}')"
[[ -z "$(git -C .worktree/feat-y/sm-b symbolic-ref HEAD 2>/dev/null)" ]] \
    || fail "sm-b HEAD should be detached, not on a branch"
[[ "$(git -C .worktree/feat-y/sm-b rev-parse HEAD)" == "$sm_b_recorded" ]] \
    || fail "sm-b HEAD doesn't match the parent's recorded gitlink SHA"
# Info line reflects the selection — exactly 1 submodule branched.
assert_grep out "Branching 1 submodule\(s\) to feat/feat-y"
cleanup_fixture

# --- case: touch=none (parent only) ---
# Both submodules detached at the parent's recorded SHAs.
mkfixture_local new_touch_none
cd "$FIXTURE_SUPER"
./subgrove new feat-z touch=none >out 2>&1
assert_head_on .worktree/feat-z feat/feat-z
assert_no_branch .worktree/feat-z/sm-a feat/feat-z
assert_no_branch .worktree/feat-z/sm-b feat/feat-z
for sm in sm-a sm-b; do
    [[ -z "$(git -C ".worktree/feat-z/$sm" symbolic-ref HEAD 2>/dev/null)" ]] \
        || fail "$sm HEAD should be detached, not on a branch"
    recorded="$(git -C .worktree/feat-z ls-tree feat/feat-z "$sm" | awk '{print $3}')"
    [[ "$(git -C ".worktree/feat-z/$sm" rev-parse HEAD)" == "$recorded" ]] \
        || fail "$sm HEAD doesn't match the parent's recorded gitlink SHA"
done
# Info line explicitly confirms the touch=none path.
assert_grep out "Submodule branching skipped \(touch=none\)"
cleanup_fixture

# --- case: build=false skips BUILD_CHAIN ---
mkfixture_local new_build_false
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=(sm-a)
BUILD_CMD="touch .built"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "enable BUILD_CHAIN for test"
./subgrove new feat-build-skip build=false >out 2>&1
assert_file_absent .worktree/feat-build-skip/sm-a/.built
# sm-b isn't in BUILD_CHAIN — its .built must also be absent. Catches a
# bug where BUILD_CMD ran in submodules outside the chain.
assert_file_absent .worktree/feat-build-skip/sm-b/.built
assert_grep out "Build chain skipped"
cleanup_fixture

# --- case: build runs by default with BUILD_CHAIN ---
mkfixture_local new_build_runs
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=(sm-a)
BUILD_CMD="touch .built"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "enable BUILD_CHAIN for test"
./subgrove new feat-build >out 2>&1
assert_file_exists .worktree/feat-build/sm-a/.built
cleanup_fixture

# --- case: pre-existing worktree dir refused (and untouched) ---
mkfixture_local new_existing_dir
cd "$FIXTURE_SUPER"
mkdir -p .worktree/feat-collide
echo "sentinel" > .worktree/feat-collide/marker
if ./subgrove new feat-collide >out 2>&1; then
    fail "expected new to fail on pre-existing worktree dir"
fi
# Specific to the path-collision error (not the branch-collision error).
assert_grep out "\.worktree/feat-collide already exists"
assert_no_branch . feat/feat-collide
# Pre-existing dir contents are untouched — subgrove errored without writing.
assert_file_exists .worktree/feat-collide/marker
[[ "$(cat .worktree/feat-collide/marker)" == "sentinel" ]] \
    || fail "pre-existing dir contents modified by failed new"
cleanup_fixture

# --- case: pre-existing parent branch refused (branch SHA unchanged) ---
mkfixture_local new_existing_branch
cd "$FIXTURE_SUPER"
git branch feat/feat-pre main
pre_branch_sha="$(git rev-parse feat/feat-pre)"
if ./subgrove new feat-pre >out 2>&1; then
    fail "expected new to fail on pre-existing branch"
fi
# Specific to the branch-collision error (not the path-collision error).
assert_grep out "branch 'feat/feat-pre' already exists in parent repo"
assert_file_absent .worktree/feat-pre
# Pre-existing branch SHA unchanged.
assert_branch_at . feat/feat-pre "$pre_branch_sha"
cleanup_fixture

# --- case: linked-worktree refusal ---
mkfixture_local new_linked
cd "$FIXTURE_SUPER"
./subgrove new feat-host >out 2>&1
ln -s "$SUBGROVE_REPO_ROOT/subgrove" .worktree/feat-host/subgrove
cd .worktree/feat-host
if ./subgrove new feat-from-linked >out 2>&1; then
    cd "$FIXTURE_SUPER"
    fail "expected new to refuse from a linked worktree"
fi
assert_grep out "main worktree"
cd "$FIXTURE_SUPER"
cleanup_fixture

# --- case: missing .worktree/ in .gitignore (no side effects) ---
mkfixture_local new_no_ignore
cd "$FIXTURE_SUPER"
> .gitignore
git add .gitignore
git commit --quiet -m "drop .worktree from .gitignore"
if ./subgrove new feat-noignore >out 2>&1; then
    fail "expected new to refuse when .worktree/ not gitignored"
fi
# Specific err names the resource being flagged.
assert_grep out "\.worktree/ is not gitignored"
# assert_worktrees_ignored fires before `git worktree add` runs — no
# worktree dir, no parent branch should exist.
assert_file_absent .worktree/feat-noignore
assert_no_branch . feat/feat-noignore
cleanup_fixture

# --- case: invalid name rejected (per-pattern error messages) ---
# Each kind of invalid name produces a SPECIFIC error from validate_name.
# Verifying per-pattern catches a bug where one validation branch fired
# for the wrong reason.
mkfixture_local new_invalid
cd "$FIXTURE_SUPER"

# Leading dot → "must not start with '.' or '-'"
if ./subgrove new ".dotleading" >out 2>&1; then
    fail "expected new to reject '.dotleading'"
fi
assert_grep out "must not start with '\.' or '-'"

# Leading dash → same error
if ./subgrove new "-dashleading" >out 2>&1; then
    fail "expected new to reject '-dashleading'"
fi
assert_grep out "must not start with '\.' or '-'"

# Spaces and slashes → "must match [a-zA-Z0-9._-]+"
if ./subgrove new "spaces in name" >out 2>&1; then
    fail "expected new to reject 'spaces in name'"
fi
assert_grep out "name must match"

if ./subgrove new "ba/d" >out 2>&1; then
    fail "expected new to reject 'ba/d'"
fi
assert_grep out "name must match"

# Empty → "feature name required"
if ./subgrove new "" >out 2>&1; then
    fail "expected new to reject ''"
fi
assert_grep out "feature name required"

# validate_name fires before any side effect — no worktree subdir or
# feat/ branch was created during any of the rejections.
[[ -z "$(ls .worktree 2>/dev/null)" ]] \
    || fail ".worktree/ should be empty after invalid-name rejections"
[[ -z "$(git for-each-ref --format='%(refname:short)' refs/heads/feat/ 2>/dev/null)" ]] \
    || fail "no feat/ branches should exist after invalid-name rejections"
cleanup_fixture

# --- case: rollback on submodule-init failure ---
# Rename sibling sm-b so the file:// URL recorded in .gitmodules no longer
# resolves. `git submodule update --init` will fail in the new worktree.
# cmd_new's rollback trap should clean up the half-built worktree (rm +
# branch -D) so a retry of the same name wouldn't trip on residue.
mkfixture_local new_rollback
cd "$FIXTURE_SUPER"
# Capture state of things that should be unchanged across the rollback.
sibling_a_state="$(snapshot_state "$FIXTURE_ROOT/sm-a")"
gitignore_before="$(cat .gitignore)"
subgroverc_before="$(cat .subgroverc)"
mv "$FIXTURE_ROOT/sm-b" "$FIXTURE_ROOT/sm-b.disabled"
new_failed=0
./subgrove new feat-rollback >out 2>&1 || new_failed=1
mv "$FIXTURE_ROOT/sm-b.disabled" "$FIXTURE_ROOT/sm-b" 2>/dev/null || true
[[ $new_failed -eq 1 ]] || fail "expected new to fail on submodule init failure"
assert_file_absent .worktree/feat-rollback
assert_no_branch . feat/feat-rollback
# Sibling sm-a (which init'd successfully before sm-b's failure) is the
# source of cloned data — clone reads from it, doesn't modify it.
assert_state_eq "$FIXTURE_ROOT/sm-a" "$sibling_a_state"
# Main super's config files were never touched.
[[ "$(cat .gitignore)" == "$gitignore_before" ]] \
    || fail ".gitignore modified by failed new"
[[ "$(cat .subgroverc)" == "$subgroverc_before" ]] \
    || fail ".subgroverc modified by failed new"
cleanup_fixture

# --- case: COPY_TO_NEW_WORKTREE copies items from main super ---
mkfixture_local new_copy
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=(.copy-me .copy-dir)
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "configure COPY_TO_NEW_WORKTREE"
echo "shared config" > .copy-me
mkdir -p .copy-dir && echo "in dir" > .copy-dir/file
./subgrove new feat-copy >out 2>&1
assert_file_exists .worktree/feat-copy/.copy-me
assert_file_exists .worktree/feat-copy/.copy-dir/file
# Contents match — cp -a preserved the actual bytes, not just created empty
# files at the destination.
[[ "$(cat .worktree/feat-copy/.copy-me)" == "shared config" ]] \
    || fail "COPY_TO_NEW_WORKTREE corrupted .copy-me contents"
[[ "$(cat .worktree/feat-copy/.copy-dir/file)" == "in dir" ]] \
    || fail "COPY_TO_NEW_WORKTREE corrupted .copy-dir/file contents"
# cp -a copies; sources still in main super after.
assert_file_exists .copy-me
assert_file_exists .copy-dir/file
[[ "$(cat .copy-me)" == "shared config" ]] \
    || fail "main super's .copy-me modified by COPY_TO_NEW_WORKTREE"
cleanup_fixture

# --- case: COPY_TO_NEW_WORKTREE silently skips missing items ---
mkfixture_local new_copy_missing
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=(.nonexistent-file)
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "configure COPY_TO_NEW_WORKTREE with missing item"
./subgrove new feat-skip >out 2>&1
assert_file_absent .worktree/feat-skip/.nonexistent-file
cleanup_fixture

# --- case: rollback keeps a branch that gained commits ---
# If the build chain commits onto the parent feat branch and then fails,
# _rollback_new must NOT delete the branch — those commits would be lost. The
# worktree dir is still removed; the branch survives, so a retry errs on
# "already exists" rather than trampling the work. BUILD_CMD runs with cwd
# $wt/sm-a, so `git -C ..` operates on the parent worktree (HEAD on feat/feat-x).
mkfixture_local new_rollback_committed
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=(sm-a)
BUILD_CMD="git -C .. commit --allow-empty -m wip-on-parent && false"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "build chain that commits on the parent then fails"
base_sha="$(git rev-parse main)"
new_failed=0
./subgrove new feat-x >out 2>&1 || new_failed=1
[[ $new_failed -eq 1 ]] || fail "expected new to fail when build chain fails"
# Worktree torn down...
assert_file_absent .worktree/feat-x
# ...but the branch survived because it advanced past its creation SHA.
assert_branch_at . feat/feat-x
assert_commits_ahead . main feat/feat-x 1
assert_grep out "advanced past its creation point"
assert_ne "$base_sha" "$(git rev-parse feat/feat-x)" "feat branch should have advanced"
cleanup_fixture

# --- case: touch= with nonexistent submodule name refused ---
mkfixture_local new_touch_invalid
cd "$FIXTURE_SUPER"
if ./subgrove new feat-bad-touch touch=nonexistent >out 2>&1; then
    fail "expected new to fail on nonexistent submodule name in touch="
fi
# Subgrove prints the branching intent BEFORE discovering the bad path.
assert_grep out "Branching 1 submodule\(s\) to feat/feat-bad-touch"
assert_grep out "no such submodule path"
# Rollback fires, so the worktree dir is cleaned up.
assert_file_absent .worktree/feat-bad-touch
assert_no_branch . feat/feat-bad-touch
cleanup_fixture

# --- case: BUILD_CHAIN runs each module in declared order ---
# BUILD_CMD increments a shared counter (in the worktree parent's dir,
# accessible from each submodule as `../.build-counter`) and writes the
# turn number into `.built-order` in its own submodule cwd. Lets us pin
# the order subgrove iterated BUILD_CHAIN, not just that both modules ran.
mkfixture_local new_build_multi
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=(sm-a sm-b)
BUILD_CMD='n=$(($(cat ../.build-counter 2>/dev/null || echo 0) + 1)); echo "$n" > ../.build-counter; echo "$n" > .built-order; touch .built'
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "BUILD_CHAIN with two modules + order tracking"
./subgrove new feat-multi >out 2>&1
# Both modules built.
assert_file_exists .worktree/feat-multi/sm-a/.built
assert_file_exists .worktree/feat-multi/sm-b/.built
# Order: sm-a is first in BUILD_CHAIN, sm-b second.
[[ "$(cat .worktree/feat-multi/sm-a/.built-order)" == "1" ]] \
    || fail "sm-a should be built 1st (got: $(cat .worktree/feat-multi/sm-a/.built-order))"
[[ "$(cat .worktree/feat-multi/sm-b/.built-order)" == "2" ]] \
    || fail "sm-b should be built 2nd (got: $(cat .worktree/feat-multi/sm-b/.built-order))"
cleanup_fixture

# --- case: discovery keys off the CWD's repo, not the script's location ---
# Post-refactor contract (the inverse of the old one): the script no longer
# self-locates via `dirname $0`; it discovers the superproject from the CWD
# (`git rev-parse --show-toplevel`). Invoked with the CWD outside any git
# repo, `new` refuses with "not in a git repo" and leaves the script's own
# repo untouched. The positive case — script on PATH outside the repo, CWD
# inside it — lives in test_path_invocation.sh.
mkfixture_local new_from_other_cwd
sg="$FIXTURE_SUPER/subgrove"
outside="$(mktemp -d "${TMPDIR:-/tmp}/subgrove-outside.XXXXXX")"
cd "$outside"
if "$sg" new feat-x >out 2>&1; then
    cd "$FIXTURE_SUPER"; rm -rf "$outside"
    fail "new should refuse when the CWD is not inside a git repo"
fi
assert_grep out "not in a git repo"
[[ ! -e "$FIXTURE_SUPER/.worktree/feat-x" ]] \
    || fail "new must not touch the script's repo when run from outside it"
cd "$FIXTURE_SUPER"
rm -rf "$outside"
cleanup_fixture

# --- case: dirty main super doesn't block new (and dirty is preserved) ---
# cmd_new doesn't `require_clean` the main super, so uncommitted changes
# in the surrounding super (parent and submodules) should not prevent
# creating a new worktree. Additionally, the dirty edits must still be on
# disk after — `git worktree add` shouldn't accidentally stash them.
mkfixture_local new_dirty_super_ok
cd "$FIXTURE_SUPER"
echo "dirty parent" >> README
echo "dirty sm-a" >> sm-a/README
echo "dirty sm-b" >> sm-b/README
assert_pending_file .    README unstaged
assert_pending_file sm-a README unstaged
assert_pending_file sm-b README unstaged
./subgrove new feat-x >out 2>&1
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
# Dirty edits in main super preserved.
assert_pending_file .    README unstaged
assert_pending_file sm-a README unstaged
assert_pending_file sm-b README unstaged
cleanup_fixture

# --- case: custom WORKTREES_DIR places the worktree in the configured folder ---
# The worktree dir is a config knob (WORKTREES_DIR), not a hardcoded .worktree/.
# A non-default value must be gitignored just the same; init normally wires
# that up, here we set it by hand.
mkfixture_local new_custom_wtdir
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
WORKTREES_DIR="wt"
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
printf 'wt/\n' >> .gitignore       # the configured folder must be gitignored too
mkdir wt                           # exist-on-disk so `git check-ignore wt` matches wt/
git add .subgroverc .gitignore
git commit --quiet -m "custom WORKTREES_DIR=wt"
./subgrove new feat-x >out 2>&1
# Worktree (and its branched submodules) landed under wt/, not .worktree/.
assert_file_exists wt/feat-x
assert_file_absent .worktree/feat-x
assert_head_on wt/feat-x feat/feat-x
assert_head_on wt/feat-x/sm-a feat/feat-x
assert_head_on wt/feat-x/sm-b feat/feat-x
cleanup_fixture
