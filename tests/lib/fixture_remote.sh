#!/usr/bin/env bash
# Fixture builder for remote tests. Resets the three GitHub repos
# (SUBGROVE_TEST_SUPER_URL, SUBGROVE_TEST_SM_URL, SUBGROVE_TEST_SM_URL2)
# back to the `subgrove-baseline` tag pushed by tests/init_remote.sh,
# then makes a working clone for the test to mutate.
#
# Run `tests/init_remote.sh` ONCE before the first remote test run (or
# whenever the fixture URLs in tests/config.sh change). The fixture
# itself never rewrites the baseline tag — it only force-updates main.
#
# Remote tests are intentionally serial — a `subgrove-test-lock` tag on
# the super repo turns a concurrent invocation into a fast failure
# rather than letting two runs clobber each other.

if [[ -z "${SUBGROVE_REPO_ROOT:-}" ]]; then
    SUBGROVE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if [[ -z "${TESTS_DIR:-}" ]]; then
    TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

. "$(dirname "${BASH_SOURCE[0]}")/mutators.sh"

# When run via tests/run.sh, the runner has already sourced tests/config.sh
# and exported the URL vars. When a test is invoked directly (e.g.
# `bash tests/remote/test_X.sh`), source config.sh as a fallback so the
# URLs are still picked up. Env values take precedence over config.sh.
if [[ -z "${SUBGROVE_TEST_SUPER_URL:-}" || -z "${SUBGROVE_TEST_SM_URL:-}" || -z "${SUBGROVE_TEST_SM_URL2:-}" ]]; then
    if [[ -f "$TESTS_DIR/config.sh" ]]; then
        . "$TESTS_DIR/config.sh"
    fi
fi

# Propagated to every child git invocation. user.{email,name} so that
# freshly-init'd repos can commit without per-repo config.
export GIT_CONFIG_PARAMETERS="'protocol.file.allow=always' 'user.email=test@subgrove.local' 'user.name=Subgrove Tests'"

FIXTURE_ROOT=""
FIXTURE_SUPER=""
SUBGROVE_TEST_LOCK_HELD=""
SUBGROVE_TEST_BRANCHES=()

_require_var() {
    local name="$1"
    # ${!name:-} is bash 3.2+ indirect expansion — no eval, no injection
    # if the variable name itself ever becomes attacker-controlled.
    if [[ -z "${!name:-}" ]]; then
        echo "Remote tests: $name is empty." >&2
        echo "  Fill it in at $TESTS_DIR/config.sh," >&2
        echo "  or run 'tests/run.sh --local-only' to skip the remote tests." >&2
        exit 1
    fi
}

_has_baseline_tag() {
    # `--` terminates option parsing so a URL like `--upload-pack=...`
    # can't slip through as a CLI option (defense-in-depth; URLs come
    # from config.sh which is trusted, but cheap to harden).
    git ls-remote -- "$1" refs/tags/subgrove-baseline 2>/dev/null \
        | grep -q refs/tags/subgrove-baseline
}

# Force-updates URL's main ref to the object refs/tags/subgrove-baseline
# points to. Cheap on the wire — the baseline objects are already on
# the server, this is purely a ref update. We do it from a tiny temp
# repo so we don't need a local clone of every remote.
_reset_main_to_baseline() {
    local url="$1" label="$2"
    local tmp="$FIXTURE_ROOT/_reset_$label"
    git init --quiet "$tmp"
    (
        cd "$tmp"
        git fetch --quiet -- "$url" \
            refs/tags/subgrove-baseline:refs/tags/subgrove-baseline
        git push --quiet --force -- "$url" \
            refs/tags/subgrove-baseline:refs/heads/main
    )
    rm -rf "$tmp"
}

mkfixture_remote() {
    local name="${1:-fixture}"
    _require_var SUBGROVE_TEST_SUPER_URL
    _require_var SUBGROVE_TEST_SM_URL
    _require_var SUBGROVE_TEST_SM_URL2

    # Fail fast if init hasn't been run — much better than the cryptic
    # downstream errors a missing tag would produce in _reset.
    if ! _has_baseline_tag "$SUBGROVE_TEST_SUPER_URL" \
       || ! _has_baseline_tag "$SUBGROVE_TEST_SM_URL" \
       || ! _has_baseline_tag "$SUBGROVE_TEST_SM_URL2"; then
        echo "Remote tests: subgrove-baseline tag missing on one or more remotes." >&2
        echo "  Run tests/init_remote.sh once to bootstrap the fixture repos." >&2
        exit 1
    fi

    local ts
    ts="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    # Fixtures live under $TESTS_DIR/run/ (gitignored). See
    # fixture_local.sh for the rationale.
    FIXTURE_ROOT="${SUBGROVE_TEST_FIXTURES_DIR:-$TESTS_DIR/run}/$ts-remote-$name"
    FIXTURE_SUPER="$FIXTURE_ROOT/super"
    mkdir -p "$FIXTURE_ROOT"

    echo "  fixture: $FIXTURE_ROOT" >&2

    # 1. Lock acquisition. The lock is process-scoped: a multi-iteration
    # test (e.g. matrix) calls mkfixture_remote repeatedly and keeps the
    # lock across iterations; cleanup_fixture_remote does NOT release it.
    # Only the teardown trap at script exit releases. This avoids a
    # per-iteration acquire+release round trip and prevents a foreign
    # run from sneaking in between iterations.
    if [[ -z "$SUBGROVE_TEST_LOCK_HELD" ]]; then
        # One-time URL banner for the script. Surfaces the targets that
        # this script will force-push to (per-test resets + any push=true
        # test) so a developer notices URL typos before tests start
        # nuking the wrong repos.
        cat >&2 <<EOF
  remote test targets (force-push reachable):
    super: $SUBGROVE_TEST_SUPER_URL
    sm-a:  $SUBGROVE_TEST_SM_URL
    sm-b:  $SUBGROVE_TEST_SM_URL2
EOF
        if git ls-remote -- "$SUBGROVE_TEST_SUPER_URL" refs/tags/subgrove-test-lock 2>/dev/null \
                | grep -q refs/tags/subgrove-test-lock; then
            echo "Remote tests: lock tag exists on $SUBGROVE_TEST_SUPER_URL." >&2
            echo "  Another run may be in progress, or a previous run died." >&2
            echo "  Clear with:" >&2
            echo "    git push '$SUBGROVE_TEST_SUPER_URL' :refs/tags/subgrove-test-lock" >&2
            exit 1
        fi
        _push_lock_tag
        trap _fixture_remote_teardown EXIT INT TERM
    fi

    # 2. Reset all three remotes' main to baseline (cheap ref-only push).
    _reset_main_to_baseline "$SUBGROVE_TEST_SUPER_URL" super
    _reset_main_to_baseline "$SUBGROVE_TEST_SM_URL"    sm-a
    _reset_main_to_baseline "$SUBGROVE_TEST_SM_URL2"   sm-b

    # 3. Working clone.
    git clone --quiet -- "$SUBGROVE_TEST_SUPER_URL" "$FIXTURE_SUPER"
    (
        cd "$FIXTURE_SUPER"
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        git submodule update --init --quiet
        ( cd sm-a && git checkout --quiet -B main )
        ( cd sm-b && git checkout --quiet -B main )
        # See fixture_local.sh for why .worktree/ is pre-created.
        mkdir -p .worktree
        ln -s "$SUBGROVE_REPO_ROOT/subgrove" subgrove
    )

    export FIXTURE_ROOT FIXTURE_SUPER
}

_push_lock_tag() {
    local lock_dir="$FIXTURE_ROOT/_lock"
    git init --quiet "$lock_dir"
    (
        cd "$lock_dir"
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        git commit --quiet --allow-empty -m "lock"
        git tag subgrove-test-lock
        git push --quiet -- "$SUBGROVE_TEST_SUPER_URL" refs/tags/subgrove-test-lock
    )
    SUBGROVE_TEST_LOCK_HELD=1
}

# Tests call this after `subgrove new feat-X` so the teardown trap can wipe
# the branch from all three remote repos.
register_feature_branch() {
    SUBGROVE_TEST_BRANCHES+=("$1")
}

_fixture_remote_teardown() {
    local rc=$?
    local b lock_err

    # The test's cwd may have been inside FIXTURE_ROOT, which
    # cleanup_fixture_remote just rm'd. Git refuses to run without a
    # readable cwd — silent failures here were why the lock tag
    # leaked under the old swallow-all-errors teardown.
    cd "${TESTS_DIR:-/}" 2>/dev/null || cd /

    # Feature branches may or may not exist on each remote (depends on
    # whether the test pushed them). Best-effort cleanup, errors ignored.
    if [[ ${#SUBGROVE_TEST_BRANCHES[@]} -gt 0 ]]; then
        for b in "${SUBGROVE_TEST_BRANCHES[@]}"; do
            git push --quiet -- "$SUBGROVE_TEST_SUPER_URL" ":refs/heads/$b" 2>/dev/null || true
            git push --quiet -- "$SUBGROVE_TEST_SM_URL"    ":refs/heads/$b" 2>/dev/null || true
            git push --quiet -- "$SUBGROVE_TEST_SM_URL2"   ":refs/heads/$b" 2>/dev/null || true
        done
    fi

    # The lock MUST be released — if it isn't, the next run blocks.
    # Capture stderr inline so the warning carries the actual git error.
    if [[ -n "$SUBGROVE_TEST_LOCK_HELD" ]]; then
        if ! lock_err=$(git push --quiet -- "$SUBGROVE_TEST_SUPER_URL" \
                            :refs/tags/subgrove-test-lock 2>&1); then
            echo "fixture_remote: WARNING failed to release subgrove-test-lock." >&2
            if [[ -n "$lock_err" ]]; then
                printf '%s\n' "$lock_err" | sed 's/^/  /' >&2
            fi
            echo "  Clear manually with:" >&2
            echo "    git push '$SUBGROVE_TEST_SUPER_URL' :refs/tags/subgrove-test-lock" >&2
            # Don't override the test's own exit code with the lock-release
            # failure, but do surface a non-zero rc if the test itself passed.
            [[ $rc -eq 0 ]] && rc=75   # EX_TEMPFAIL
        fi
        SUBGROVE_TEST_LOCK_HELD=""
    fi
    trap - EXIT INT TERM
    exit "$rc"
}

cleanup_fixture_remote() {
    # cd out of FIXTURE_ROOT before rm'ing it so subsequent code (and
    # the teardown trap) doesn't run with a dead cwd.
    cd "${TESTS_DIR:-/}" 2>/dev/null || cd /
    if [[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
}
