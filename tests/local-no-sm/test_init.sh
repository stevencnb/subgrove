#!/usr/bin/env bash
# `subgrove init` on a no-submodule super: the BUILD_CHAIN step degrades to
# "no submodules detected" and leaves the chain empty; the rest of the
# bootstrap (write .subgroverc, gitignore + create .worktree/) still works,
# and the repo is usable by `new` afterward.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local_no_sm.sh"

mkfixture_local_no_sm init_flat
cd "$FIXTURE_SUPER"
rm -f .subgroverc
rm -rf .worktree
printf '.DS_Store\n' > .gitignore
git add -A && git commit -q -m "pre-init state"

./subgrove init --defaults >out 2>&1 || { cat out; fail "init --defaults failed on flat repo"; }
assert_grep out "No submodules detected"
assert_file_exists .subgroverc
assert_grep .subgroverc 'BUILD_CHAIN=\(\)'      # empty chain on a flat repo
assert_grep .gitignore '\.worktree/'
assert_file_exists .worktree
# Repo is usable: new works on the flat super.
./subgrove new feat-x >out2 2>&1 || { cat out2; fail "new failed after init on flat repo"; }
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
cleanup_fixture

echo "PASS"
