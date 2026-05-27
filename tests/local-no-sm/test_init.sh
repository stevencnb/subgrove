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
assert_grep .subgroverc 'WORKTREES_DIR="\.worktree"'
assert_grep .subgroverc 'BUILD_CHAIN=\(\)'      # empty chain on a flat repo
assert_grep .gitignore '\.worktree/'
assert_file_exists .worktree
# Repo is usable: new works on the flat super.
./subgrove new feat-x >out2 2>&1 || { cat out2; fail "new failed after init on flat repo"; }
assert_file_exists .worktree/feat-x
assert_head_on .worktree/feat-x feat/feat-x
cleanup_fixture

# --- case: a repo without .subgroverc refuses every repo-touching command ---
# Same discover_root gate as the with-submodule tier, replicated on a flat
# super so a regression that only fires without .gitmodules is caught.
# init/help/--version are exempt: init writes the file, help/--version
# never reach discover_root.
mkfixture_local_no_sm init_required
cd "$FIXTURE_SUPER"
rm -f .subgroverc                       # discover_root checks the file on disk, not git
for sub in "new feat-x" "list" "merge feat-x" "remove feat-x" "update feat-x"; do
    if ./subgrove $sub >out 2>&1; then
        cat out; fail "expected '$sub' to refuse without .subgroverc"
    fi
    assert_grep out "no .subgroverc found"
    assert_grep out "subgrove init"
done
assert_file_absent .worktree/feat-x
assert_no_branch . feat/feat-x
# Exempt commands keep working with no config present.
./subgrove help >out 2>&1      || { cat out; fail "help should work without .subgroverc"; }
assert_grep out "parallel feature worktrees"
./subgrove --version >out 2>&1 || { cat out; fail "--version should work without .subgroverc"; }
assert_grep out "subgrove [0-9]"
./subgrove init --defaults >out 2>&1 || { cat out; fail "init should work without .subgroverc"; }
assert_file_exists .subgroverc
cleanup_fixture

echo "PASS"
