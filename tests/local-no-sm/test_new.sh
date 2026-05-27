#!/usr/bin/env bash
# Tests for `subgrove new` on a no-submodule fixture.
#
# Companion to tests/local/test_new.sh. Verifies that subgrove's submodule
# init / branching / build phases degrade gracefully when .gitmodules is
# absent, and that submodule-relevant parameters (touch=, BUILD_CHAIN)
# either err cleanly with rollback or produce a defined no-op.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

# --- case: golden default (no touch=, no BUILD_CHAIN) ---
# touch=all is the default; on a no-sm super it resolves to an empty list,
# which the script narrates as `Submodule branching skipped (touch=none)`.
# The submodule-init phase still runs but iterates the empty list.
mkfixture_local_no_sm new_golden
cd "$FIXTURE_SUPER"
./subgrove new feat-x >out 2>&1
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
# Super has no origin; parent fetch fails with a warn, subgrove continues.
assert_grep out "warn: parent fetch failed"
# Parent feat created at local main (origin/main fetch failed).
assert_branch_at . feat/feat-x "$(git rev-parse main)"
# The branching-skipped line fires because the resolved touch list is
# empty. ("Initialising submodules" intentionally NOT pinned — it's
# narration that fires unconditionally before the loop, doesn't encode
# any behavior branch; the other pins here already prove the loop was
# entered with empty.)
assert_grep out "Submodule branching skipped \(touch=none\)"
# The "Branching N submodule(s)" line does NOT fire when N==0 — pin its
# absence so a future change that emits it unconditionally is caught.
assert_grep_v out "Branching [0-9]+ submodule\(s\)"
# BUILD_CHAIN=() in .subgroverc; the "no chain configured" message fires
# regardless of any `build=` flag (no flag passed here).
assert_grep out "No BUILD_CHAIN configured"
# §15: status reflects the resulting state.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: touch=none explicit ---
# Verify the explicit-none path emits the same narration as the empty-set
# default path. This documents that subgrove does NOT distinguish the two
# cases today (see implementation notes in docs/design/testing-local-no-sm.md).
mkfixture_local_no_sm new_touch_none
cd "$FIXTURE_SUPER"
./subgrove new feat-z touch=none >out 2>&1
assert_head_on .worktree/feat-z feat/feat-z
assert_grep out "Submodule branching skipped \(touch=none\)"
# §15: status reflects the resulting state.
assert_status feat-z "feat/feat-z"
cleanup_fixture

# --- case: touch= empty value ---
# Empty value is treated as `none` (not as `all`, not as an error). Pins
# observed behavior.
mkfixture_local_no_sm new_touch_empty
cd "$FIXTURE_SUPER"
./subgrove new feat-emptyt touch= >out 2>&1
assert_head_on .worktree/feat-emptyt feat/feat-emptyt
assert_grep out "Submodule branching skipped \(touch=none\)"
# §15: status reflects the resulting state.
assert_status feat-emptyt "feat/feat-emptyt"
cleanup_fixture

# --- case: touch=sm-a (no such sm) refused + rollback ---
# The submodule-path-existence check fires after subgrove announces intent
# to branch. Rollback must clean up the half-built worktree so a retry of
# the same name doesn't trip on residue.
mkfixture_local_no_sm new_touch_invalid
cd "$FIXTURE_SUPER"
if ./subgrove new feat-bad touch=sm-a >out 2>&1; then
    fail "expected new to fail on nonexistent submodule name in touch="
fi
assert_grep out "Branching 1 submodule\(s\) to feat/feat-bad"
assert_grep out "no such submodule path"
# Rollback fired: worktree dir + parent branch gone.
assert_file_absent .worktree/feat-bad
assert_no_branch . feat/feat-bad
# §15: status reflects the resulting state.
assert_status_absent feat-bad
cleanup_fixture

# --- case: touch=sm-a,sm-b (multi-name list, none exist) refused + rollback ---
# Loop errors on the FIRST missing path; subgrove doesn't power through to
# attempt the second name. The "Branching 2 submodule(s)" intent line
# fires before the path check, so the count reflects the parsed list.
mkfixture_local_no_sm new_touch_multi
cd "$FIXTURE_SUPER"
if ./subgrove new feat-multi touch=sm-a,sm-b >out 2>&1; then
    fail "expected new to fail on multi-name nonexistent touch list"
fi
assert_grep out "Branching 2 submodule\(s\) to feat/feat-multi"
assert_grep out "no such submodule path"
assert_file_absent .worktree/feat-multi
assert_no_branch . feat/feat-multi
# §15: status reflects the resulting state.
assert_status_absent feat-multi
cleanup_fixture

# --- case: build=false with empty BUILD_CHAIN ---
# When BUILD_CHAIN is empty, the "No BUILD_CHAIN configured" message fires
# REGARDLESS of the build= flag (the build=false skip branch fires only
# when there's a chain to skip). The test pins this distinction so a
# future change to validate build= upfront would be visible here.
mkfixture_local_no_sm new_build_false
cd "$FIXTURE_SUPER"
./subgrove new feat-bf build=false >out 2>&1
assert_head_on .worktree/feat-bf feat/feat-bf
assert_grep out "No BUILD_CHAIN configured"
# The "Build chain skipped" message MUST NOT fire — there's no chain to skip.
assert_grep_v out "Build chain skipped"
# §15: status reflects the resulting state.
assert_status feat-bf "feat/feat-bf"
cleanup_fixture

# --- case: build=true with empty BUILD_CHAIN ---
mkfixture_local_no_sm new_build_true
cd "$FIXTURE_SUPER"
./subgrove new feat-bt build=true >out 2>&1
assert_head_on .worktree/feat-bt feat/feat-bt
assert_grep out "No BUILD_CHAIN configured"
# §15: status reflects the resulting state.
assert_status feat-bt "feat/feat-bt"
cleanup_fixture

# --- case: build=invalid with empty BUILD_CHAIN ---
# build= is NOT validated upfront when BUILD_CHAIN is empty. An invalid
# value is silently accepted. Pins observed behavior; if subgrove later
# validates build= regardless of chain state, this test changes to expect
# an err.
mkfixture_local_no_sm new_build_invalid
cd "$FIXTURE_SUPER"
./subgrove new feat-bi build=oops >out 2>&1
assert_head_on .worktree/feat-bi feat/feat-bi
assert_grep out "No BUILD_CHAIN configured"
# §15: status reflects the resulting state.
assert_status feat-bi "feat/feat-bi"
cleanup_fixture

# --- case: BUILD_CHAIN=(sm-a) on no-sm super — rollback via build phase ---
# The build loop does `cd $WT/sm-a` which fails because sm-a doesn't exist.
# The error message leaks from the shell (`cd: ... No such file or directory`)
# rather than being a clean "no such submodule" diagnostic — but rollback
# still fires correctly. The no-sm equivalent of local/test_new's
# "rollback on submodule-init failure" scenario.
mkfixture_local_no_sm new_build_chain_bad
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=(sm-a)
BUILD_CMD="touch .built"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
git add .subgroverc
git commit --quiet -m "BUILD_CHAIN with nonexistent module"
# Snapshot parent super state BEFORE the failed new — the rollback trap
# must clean up the worktree + branch and nothing else. A regression
# where the trap accidentally removes .subgroverc / README / the
# subgrove symlink would be invisible to the "worktree + branch gone"
# assertions alone.
super_state=$(snapshot_state .)
if ./subgrove new feat-bc >out 2>&1; then
    fail "expected new to fail when BUILD_CHAIN references a missing submodule"
fi
# The script reaches the build phase before failing.
assert_grep out "Running build chain"
# Pin SOME trace of the failure mode itself (the leaky `cd: No such file
# or directory` shell error). Without this, "rollback happened" could
# mask a regression where rollback now fires from an unrelated earlier
# failure (e.g. a `set -e` change exiting before the build phase runs).
assert_grep out "[Nn]o such file or directory"
# Rollback fired and bounded its blast radius — worktree+branch gone,
# parent super otherwise byte-identical.
assert_file_absent .worktree/feat-bc
assert_no_branch . feat/feat-bc
assert_state_eq . "$super_state"
# Files the rollback must NOT have eaten.
assert_file_exists .subgroverc
assert_file_exists README
assert_file_exists subgrove
# §15: status reflects the resulting state.
assert_status_absent feat-bc
cleanup_fixture

# --- case: pre-existing worktree dir refused ---
mkfixture_local_no_sm new_existing_dir
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
# §15: status reflects the resulting state. The pre-existing collide dir
# under .worktree/ is enumerated as a row by status (branch never created,
# so do not assert the branch).
assert_status feat-collide
cleanup_fixture

# --- case: pre-existing parent branch refused ---
mkfixture_local_no_sm new_existing_branch
cd "$FIXTURE_SUPER"
git branch feat/feat-pre main
pre_branch_sha="$(git rev-parse feat/feat-pre)"
if ./subgrove new feat-pre >out 2>&1; then
    fail "expected new to fail on pre-existing branch"
fi
assert_grep out "branch 'feat/feat-pre' already exists in parent repo"
assert_file_absent .worktree/feat-pre
assert_branch_at . feat/feat-pre "$pre_branch_sha"
# §15: status reflects the resulting state. No worktree dir was created, so
# the bare feat/feat-pre branch produces no status row.
assert_status_absent feat-pre
cleanup_fixture

# --- case: linked-worktree refusal ---
mkfixture_local_no_sm new_linked
cd "$FIXTURE_SUPER"
./subgrove new feat-host >out 2>&1
ln -s "$SUBGROVE_REPO_ROOT/subgrove" .worktree/feat-host/subgrove
cd .worktree/feat-host
if ./subgrove new feat-from-linked >out 2>&1; then
    cd "$FIXTURE_SUPER"
    fail "expected new to refuse from a linked worktree"
fi
# Pin the full refusal phrase (the looser "main worktree" also appears in
# several success-path narration lines).
assert_grep out "currently in a linked worktree"
cd "$FIXTURE_SUPER"
# §15: status reflects the resulting state. feat-host was created and
# survives; feat-from-linked was refused and never created.
assert_status feat-host "feat/feat-host"
assert_status_absent feat-from-linked
cleanup_fixture

# --- case: missing .worktree/ in .gitignore refused ---
mkfixture_local_no_sm new_no_ignore
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
cleanup_fixture

# --- case: invalid names rejected ---
mkfixture_local_no_sm new_invalid
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
# §15: status reflects the resulting state. No worktrees were created.
assert_status "no feature worktrees yet"
cleanup_fixture

# --- case: dirty main super doesn't block new ---
# cmd_new doesn't `require_clean` the parent. Same invariant as the
# with-submodule tier; replicated here to catch a regression that would
# only fire when no submodules are present (e.g. if a future check
# inspected `.gitmodules` presence as a prerequisite).
mkfixture_local_no_sm new_dirty_super_ok
cd "$FIXTURE_SUPER"
echo "dirty parent" >> README
assert_pending_file . README unstaged
./subgrove new feat-x >out 2>&1
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
assert_pending_file . README unstaged
# §15: status reflects the resulting state.
assert_status feat-x "feat/feat-x"
cleanup_fixture

# --- case: custom WORKTREES_DIR places the worktree in the configured folder ---
# Submodule-agnostic knob, verified on a flat super too. Mirrors
# local/test_new.sh::new_custom_wtdir without the submodule assertions.
mkfixture_local_no_sm new_custom_wtdir
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
WORKTREES_DIR="wt"
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
printf 'wt/\n' >> .gitignore
mkdir wt
git add .subgroverc .gitignore
git commit --quiet -m "custom WORKTREES_DIR=wt"
./subgrove new feat-x >out 2>&1
assert_file_exists wt/feat-x
assert_file_absent .worktree/feat-x
assert_head_on wt/feat-x feat/feat-x
# §15: status reflects the resulting state (custom WORKTREES_DIR=wt).
assert_status feat-x "feat/feat-x"
cleanup_fixture
