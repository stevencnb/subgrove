#!/usr/bin/env bash
# Fixture builder for the no-submodule local tests.
#
# Builds a single `git init` super at $FIXTURE_ROOT/super/ with NO
# .gitmodules and NO sibling submodule source repos. Matches the "user
# is running subgrove on a superproject before any submodules have been
# added" scenario, and locks in that subgrove's submodule phases degrade
# gracefully to no-ops in that state. See docs/design/testing-local-no-sm.md
# for the tier's design, scenarios, and invariants.
#
# Reads:
#   $SUBGROVE_REPO_ROOT  path to the subgrove repo (script under test)
#   $TESTS_DIR           path to the tests/ dir
# Exports:
#   $FIXTURE_ROOT, $FIXTURE_SUPER

if [[ -z "${SUBGROVE_REPO_ROOT:-}" ]]; then
    SUBGROVE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if [[ -z "${TESTS_DIR:-}" ]]; then
    TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

. "$(dirname "${BASH_SOURCE[0]}")/mutators.sh"

# Same git-config exports as fixture_local.sh — user.{email,name} are
# required for any commit. protocol.file.allow=always is retained for
# parity with the with-submodule fixture; no current no-sm scenario uses
# file:// remotes, but parity keeps behavior predictable if one is added.
export GIT_CONFIG_PARAMETERS="'protocol.file.allow=always' 'user.email=test@subgrove.local' 'user.name=Subgrove Tests'"

FIXTURE_ROOT=""
FIXTURE_SUPER=""

mkfixture_local_no_sm() {
    local name="${1:-fixture}"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    FIXTURE_ROOT="${SUBGROVE_TEST_FIXTURES_DIR:-$TESTS_DIR/run}/$ts-no-sm-$name"
    FIXTURE_SUPER="$FIXTURE_ROOT/super"
    mkdir -p "$FIXTURE_ROOT"

    echo "  fixture: $FIXTURE_ROOT" >&2

    git init --quiet "$FIXTURE_SUPER"
    (
        cd "$FIXTURE_SUPER"
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        echo "subgrove test super (no submodules)" > README
        git add README
        git commit --quiet -m "initial super commit"

        echo ".worktree/" > .gitignore
        cat > .subgroverc <<'EOF'
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
        git add .gitignore .subgroverc
        git commit --quiet -m "subgrove plumbing"

        # Same trailing-slash workaround as fixture_local.sh.
        mkdir .worktree

        ln -s "$SUBGROVE_REPO_ROOT/subgrove" subgrove
    )

    export FIXTURE_ROOT FIXTURE_SUPER
}

cleanup_fixture() {
    if [[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
    FIXTURE_ROOT=""
    FIXTURE_SUPER=""
}
