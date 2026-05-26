#!/usr/bin/env bash
# subgrove discovers the superproject from the current directory (git
# toplevel), NOT from the script's own location. This is the property
# that makes a PATH install (Homebrew) work: the script lives outside the
# repo and is invoked from inside it — the git model. Also covers
# invocation from a subdirectory of the main worktree.
#
# The script-under-test is symlinked into a temp dir OUTSIDE this dev repo
# (not under tests/run/, which is inside it) so that a location-based
# discovery would find no repo at all — a clean failure — rather than
# walking up into the subgrove dev repo and operating on the wrong git.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/fixture_local.sh"

# Install subgrove the way Homebrew would: a symlink in a bin dir that is
# nowhere near the superproject, invoked by bare name via PATH.
BINDIR="$(mktemp -d "${TMPDIR:-/tmp}/subgrove-bin.XXXXXX")"
ln -s "$SUBGROVE_REPO_ROOT/subgrove" "$BINDIR/subgrove"
trap 'rm -rf "$BINDIR"' EXIT

# --- case: invoked via PATH from the main worktree root ---
mkfixture_local "path_root"
cd "$FIXTURE_SUPER"
if ! PATH="$BINDIR:$PATH" subgrove list >out 2>&1; then
    echo "--- out ---"; cat out
    fail "subgrove list failed when invoked via PATH from the repo root"
fi
assert_grep out "$FIXTURE_SUPER"
cleanup_fixture

# --- case: invoked via PATH from a subdirectory of the main worktree ---
mkfixture_local "path_subdir"
mkdir -p "$FIXTURE_SUPER/sub/deeper"
cd "$FIXTURE_SUPER/sub/deeper"
if ! PATH="$BINDIR:$PATH" subgrove new feat-subdir >out 2>&1; then
    echo "--- out ---"; cat out
    fail "subgrove new failed when invoked from a subdirectory"
fi
assert_file_exists "$FIXTURE_SUPER/.worktree/feat-subdir"
assert_branch_at "$FIXTURE_SUPER" "feat/feat-subdir"
cleanup_fixture

echo "PASS"
