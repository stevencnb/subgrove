#!/usr/bin/env bash
# Fixture builder for local tests.
#
# Builds three plain `git init` repos at $FIXTURE_ROOT/:
#   sm-a/     standalone repo, 1 commit on main
#   sm-b/     standalone repo, 1 commit on main
#   super/    `git init`'d; the two submodules are wired in via file://
#             URLs to the sibling repos. super has NO `origin` configured
#             — it was never cloned from anywhere — which matches the
#             "user didn't configure a remote on the superproject" scenario
#             that local tests are meant to cover.
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

# Propagated to every child git invocation (including subgrove's own).
# - protocol.file.allow=always: re-enables file:// for `git submodule update`,
#   which CVE-2022-39253 disabled by default starting in git 2.38.
# - user.{email,name}: required for any commit; set here so per-repo config
#   is not strictly necessary in freshly-init'd submodule git dirs.
export GIT_CONFIG_PARAMETERS="'protocol.file.allow=always' 'user.email=test@subgrove.local' 'user.name=Subgrove Tests'"

FIXTURE_ROOT=""
FIXTURE_SUPER=""

mkfixture_local() {
    local name="${1:-fixture}"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    # Fixtures live under $TESTS_DIR/run/ (gitignored) so they sit
    # alongside the test runner that creates them. The fixture itself is
    # a wholly separate git repo (built by `git init` below), so even
    # though the parent directory is inside the subgrove repo, no test
    # command operates on the current git. Override the base with
    # SUBGROVE_TEST_FIXTURES_DIR.
    FIXTURE_ROOT="${SUBGROVE_TEST_FIXTURES_DIR:-$TESTS_DIR/run}/$ts-$name"
    FIXTURE_SUPER="$FIXTURE_ROOT/super"
    mkdir -p "$FIXTURE_ROOT"

    echo "  fixture: $FIXTURE_ROOT" >&2

    # 1. Standalone submodule repos as sibling dirs of the super.
    _init_repo "$FIXTURE_ROOT/sm-a" sm-a
    _init_repo "$FIXTURE_ROOT/sm-b" sm-b

    # 2. The super repo, with the two submodules wired in via file://.
    git init --quiet "$FIXTURE_SUPER"
    (
        cd "$FIXTURE_SUPER"
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        echo "subgrove test super" > README
        git add README
        git commit --quiet -m "initial super commit"

        # `submodule add` clones the sibling repo into super/sm-X and
        # records the URL in .gitmodules. The clone sets origin =
        # file://.../sm-X in super/sm-X/.git/config (subgrove's behavior
        # for fetch/push on submodules is exercised against that origin).
        git submodule add --quiet "file://$FIXTURE_ROOT/sm-a" sm-a
        git submodule add --quiet "file://$FIXTURE_ROOT/sm-b" sm-b
        git commit --quiet -m "add submodules sm-a sm-b"

        # Ensure submodules have refs/heads/main as the checked-out branch
        # (some git versions leave them detached after `submodule add`).
        ( cd sm-a && git checkout --quiet -B main )
        ( cd sm-b && git checkout --quiet -B main )

        echo ".worktree/" > .gitignore
        cat > .subgroverc <<'EOF'
SUBGROVE_CONFIG_VERSION="0.2.0"
BUILD_CHAIN=()
BUILD_CMD="true"
COPY_TO_NEW_WORKTREE=()
BRANCH_PREFIX="feat/"
EOF
        git add .gitignore .subgroverc
        git commit --quiet -m "subgrove plumbing"

        # Pre-create an empty .worktree/ so subgrove's
        # `git check-ignore -q .worktree` (which it runs without the
        # trailing slash) matches the `.worktree/` pattern. Without an
        # actual directory on disk, the trailing-slash pattern doesn't
        # match a check-ignore lookup against a path that isn't a
        # directory — git refuses, subgrove errors with "not gitignored."
        mkdir .worktree

        ln -s "$SUBGROVE_REPO_ROOT/subgrove" subgrove
    )

    export FIXTURE_ROOT FIXTURE_SUPER
}

_init_repo() {
    local path="$1" label="$2"
    git init --quiet "$path"
    (
        cd "$path"
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        echo "$label baseline" > README
        git add README
        git commit --quiet -m "initial $label commit"
    )
}

# Called as the LAST statement of a passing scenario. Failures under set -e
# exit earlier and skip this, leaving the fixture for inspection.
cleanup_fixture() {
    if [[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
    FIXTURE_ROOT=""
    FIXTURE_SUPER=""
}
