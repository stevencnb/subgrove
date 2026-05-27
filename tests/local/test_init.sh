#!/usr/bin/env bash
# `subgrove init` bootstraps a repo for subgrove: writes a commented
# .subgroverc, gitignores .worktree/ (and creates the dir so check-ignore
# matches), and is reconfigure-aware. The interactive wizard is bypassed
# via --defaults / non-TTY stdin so the suite stays deterministic.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# --- case: fresh init (no prior .subgroverc) writes config + gitignore ---
mkfixture_local init_fresh
cd "$FIXTURE_SUPER"
# Simulate a repo that has never run subgrove: no rc, .worktree not ignored.
rm -f .subgroverc
rm -rf .worktree
printf '.DS_Store\n' > .gitignore
git add -A && git commit -q -m "pre-init state"

./subgrove init --defaults >out 2>&1 || { cat out; fail "init --defaults failed"; }
assert_file_exists .subgroverc
assert_grep .subgroverc 'WORKTREES_DIR="\.worktree"'
assert_grep .subgroverc 'BRANCH_PREFIX="feat/"'
assert_grep .subgroverc 'BUILD_CHAIN=\('
assert_grep .gitignore '\.worktree/'
assert_file_exists .worktree           # init creates the dir so check-ignore matches
# End-to-end: the repo is now usable by subgrove.
./subgrove new feat-x >out2 2>&1 || { cat out2; fail "new failed after init"; }
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
cleanup_fixture

# --- case: reconfigure preserves existing values and backs up the old rc ---
mkfixture_local init_reconfig
cd "$FIXTURE_SUPER"
cat > .subgroverc <<'EOF'
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="custom/"
EOF
./subgrove init --defaults >out 2>&1 || { cat out; fail "init reconfigure failed"; }
assert_file_exists .subgroverc.bak                  # existing rc backed up
assert_grep .subgroverc 'BRANCH_PREFIX="custom/"'   # existing value preserved
cleanup_fixture

# --- case: non-TTY stdin doesn't hang (writes defaults) ---
mkfixture_local init_nontty
cd "$FIXTURE_SUPER"
rm -f .subgroverc
./subgrove init </dev/null >out 2>&1 || { cat out; fail "init with non-TTY stdin failed"; }
assert_file_exists .subgroverc
cleanup_fixture

# --- case: a repo without .subgroverc refuses every repo-touching command ---
# discover_root treats a missing config as fatal and points at `init` rather
# than silently running on built-in defaults. init/help/--version are exempt:
# init writes the file, and help/--version never reach discover_root.
mkfixture_local init_required
cd "$FIXTURE_SUPER"
rm -f .subgroverc                       # discover_root checks the file on disk, not git
for sub in "new feat-x" "list" "merge feat-x" "remove feat-x" "update feat-x"; do
    if ./subgrove $sub >out 2>&1; then
        cat out; fail "expected '$sub' to refuse without .subgroverc"
    fi
    assert_grep out "no .subgroverc found"
    assert_grep out "subgrove init"
done
# The refused 'new' had no side effects.
assert_file_absent .worktree/feat-x
assert_no_branch . feat/feat-x
# Exempt commands keep working with no config present.
./subgrove help >out 2>&1      || { cat out; fail "help should work without .subgroverc"; }
assert_grep out "parallel feature worktrees"
./subgrove --version >out 2>&1 || { cat out; fail "--version should work without .subgroverc"; }
assert_grep out "subgrove [0-9]"
# init recreates the config, so the repo becomes usable again.
./subgrove init --defaults >out 2>&1 || { cat out; fail "init should work without .subgroverc"; }
assert_file_exists .subgroverc
cleanup_fixture

echo "PASS"
