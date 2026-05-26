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

echo "PASS"
