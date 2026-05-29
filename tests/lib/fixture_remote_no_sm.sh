#!/usr/bin/env bash
# Fixture builder for the no-submodule remote tests. Resets a single
# GitHub repo (SUBGROVE_TEST_SUPER_NO_SM_URL) back to the
# `subgrove-baseline` tag, then makes a working clone for the test to
# mutate.
#
# Unlike the with-sm remote tier, there is no separate init script.
# `mkfixture_remote_no_sm` lazily pushes the baseline on its first call
# per machine — if the tag is missing on the remote, the fixture
# bootstraps it inline (one-commit baseline + `.gitignore` + `.subgroverc`
# matching the local-no-sm fixture's content). After that, every call is
# the same cheap ref-only baseline reset the with-sm tier uses.
#
# The lazy bootstrap intentionally has NO Y/N confirmation prompt — the
# consent gate moves to the committed tests/config.sh (URLs are reviewed
# when added). The configured URL must be a dedicated test fixture; if it
# points at a real project, the force-push damages it without warning.
# See docs/design/testing-remote-no-sm.md for the trade-off rationale.
#
# Remote tests are intentionally serial — a `subgrove-test-lock` tag on
# the no-sm super turns a concurrent invocation into a fast failure
# rather than letting two runs clobber each other. The lock is distinct
# from the with-sm tier's lock (different URLs).

if [[ -z "${SUBGROVE_REPO_ROOT:-}" ]]; then
    SUBGROVE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if [[ -z "${TESTS_DIR:-}" ]]; then
    TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

. "$(dirname "${BASH_SOURCE[0]}")/mutators.sh"

# When run via tests/run.sh, the runner has already sourced tests/config.sh
# and exported the URL var. When a test is invoked directly (e.g.
# `bash tests/remote-no-sm/test_X.sh`), source config.sh as a fallback so
# the URL is still picked up. Env value takes precedence over config.sh.
if [[ -z "${SUBGROVE_TEST_SUPER_NO_SM_URL:-}" ]]; then
    if [[ -f "$TESTS_DIR/config.sh" ]]; then
        . "$TESTS_DIR/config.sh"
    fi
fi

# Propagated to every child git invocation. user.{email,name} so that
# freshly-init'd repos can commit without per-repo config.
#
# Intentionally OMITS `protocol.file.allow=always` (the CVE-2022-39253
# workaround used by the local fixtures): the remote tier uses SSH/HTTPS
# URLs only — there's no legitimate file:// remote in any remote test.
# Defense in depth against a future regression in subgrove that might
# clone a file:// URL.
export GIT_CONFIG_PARAMETERS="'user.email=test@subgrove.local' 'user.name=Subgrove Tests'"

FIXTURE_ROOT=""
FIXTURE_SUPER=""
SUBGROVE_TEST_NO_SM_LOCK_HELD=""
SUBGROVE_TEST_NO_SM_BRANCHES=()

_require_var_no_sm() {
    local name="$1"
    # ${!name:-} is bash 3.2+ indirect expansion — no eval, no injection
    # if the variable name itself ever becomes attacker-controlled.
    if [[ -z "${!name:-}" ]]; then
        echo "Remote no-sm tests: $name is empty." >&2
        echo "  Fill it in at $TESTS_DIR/config.sh," >&2
        echo "  or run 'tests/run.sh --local-only' to skip remote tests." >&2
        exit 1
    fi
}

_has_baseline_tag_no_sm() {
    # `--` terminates option parsing so a URL like `--upload-pack=...`
    # can't slip through as a CLI option (defense-in-depth; URLs come
    # from config.sh which is trusted, but cheap to harden).
    git ls-remote -- "$1" refs/tags/subgrove-baseline 2>/dev/null \
        | grep -q refs/tags/subgrove-baseline
}

# Force-pushes a one-commit-plus-plumbing baseline + subgrove-baseline tag
# to the no-sm super URL. Called only when the tag is missing. Content
# matches fixture_local_no_sm.sh's super setup so a user moving between
# tiers sees the same baseline shape.
#
# Safety gate: refuses to bootstrap if the remote already has refs.
# Without this, a typo in SUBGROVE_TEST_SUPER_NO_SM_URL pointing at a
# real project (which has `main` but no `subgrove-baseline` tag) would
# silently force-push and damage it. The with-sm tier uses init_remote.sh
# with a Y/N prompt as its consent gate; here the empty-remote check is
# the equivalent — present-and-empty is the only state we'll initialize.
_bootstrap_no_sm_baseline() {
    local url="$1"
    local seed="$FIXTURE_ROOT/_seed_no_sm"

    # Refuse to bootstrap a populated remote. `ls-remote` returns one
    # line per ref (heads + tags). A truly empty remote returns nothing.
    #
    # CRITICAL: exclude our own `subgrove-test-lock` tag. Lock acquisition
    # runs BEFORE this bootstrap (see mkfixture_remote_no_sm step order),
    # so on a genuinely empty remote — the actual first-bootstrap case —
    # ls-remote would otherwise see the lock tag we just pushed and wrongly
    # refuse, making the zero-setup lazy bootstrap impossible. Any ref
    # OTHER than the lock tag means a real project we must not clobber.
    #
    # `|| true`: when grep filters out every line (remote had only the
    # lock tag) it exits 1; with pipefail that would abort the assignment
    # under set -e. The `|| true` keeps "no other refs" a clean empty
    # result rather than a fatal error.
    local existing_refs
    existing_refs="$(git ls-remote -- "$url" 2>/dev/null \
        | grep -v 'refs/tags/subgrove-test-lock' || true)"
    if [[ -n "$existing_refs" ]]; then
        cat >&2 <<EOF
Remote no-sm tests: refusing to bootstrap baseline on a non-empty remote.
  url: $(_redact_url "$url")
  This URL has existing refs but no \`subgrove-baseline\` tag. The fixture
  refuses to force-push to avoid clobbering a real project on a config typo.

  If this URL really is your dedicated no-sm test fixture and you want to
  re-bootstrap, delete its refs first:
    git push --delete '$(_redact_url "$url")' main
  (and any other refs the remote has) — then re-run the test. After the
  one-time bootstrap, every subsequent run sees the baseline tag and
  proceeds without this check.
EOF
        exit 1
    fi

    echo "  bootstrap no-sm baseline: $(_redact_url "$url")" >&2
    git init --quiet "$seed"
    (
        cd "$seed"
        git symbolic-ref HEAD refs/heads/main
        echo "super (no-sm) baseline" > README
        git add README
        git commit --quiet -m "baseline (super-no-sm)"

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

        git tag subgrove-baseline
        git push --quiet --force -- "$url" \
            refs/heads/main:refs/heads/main \
            refs/tags/subgrove-baseline:refs/tags/subgrove-baseline
    )
    rm -rf "$seed"
}

# Force-updates URL's main ref to the object refs/tags/subgrove-baseline
# points to. Cheap on the wire — baseline objects are already on the
# server. We do it from a tiny temp repo so we don't need a local clone.
_reset_main_to_baseline_no_sm() {
    local url="$1"
    local tmp="$FIXTURE_ROOT/_reset_no_sm"
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

mkfixture_remote_no_sm() {
    local name="${1:-fixture}"
    _require_var_no_sm SUBGROVE_TEST_SUPER_NO_SM_URL

    local ts
    ts="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    # Fixtures live under $TESTS_DIR/run/ (gitignored). See
    # fixture_local.sh for the rationale.
    FIXTURE_ROOT="${SUBGROVE_TEST_FIXTURES_DIR:-$TESTS_DIR/run}/$ts-remote-no-sm-$name"
    FIXTURE_SUPER="$FIXTURE_ROOT/super"
    mkdir -p "$FIXTURE_ROOT"

    echo "  fixture: $FIXTURE_ROOT" >&2

    # 1. Lock acquisition. Process-scoped — held across all iterations of
    # a single test script, released only at script exit via the teardown
    # trap. See fixture_remote.sh for the rationale.
    if [[ -z "$SUBGROVE_TEST_NO_SM_LOCK_HELD" ]]; then
        # URL is redacted via _redact_url (in mutators.sh) so an HTTPS-
        # with-PAT env override doesn't leak credentials into captured
        # test output / CI logs.
        cat >&2 <<EOF
  remote no-sm test target (force-push reachable):
    super: $(_redact_url "$SUBGROVE_TEST_SUPER_NO_SM_URL")
EOF
        if git ls-remote -- "$SUBGROVE_TEST_SUPER_NO_SM_URL" refs/tags/subgrove-test-lock 2>/dev/null \
                | grep -q refs/tags/subgrove-test-lock; then
            echo "Remote no-sm tests: lock tag exists on $(_redact_url "$SUBGROVE_TEST_SUPER_NO_SM_URL")." >&2
            echo "  Another run may be in progress, or a previous run died." >&2
            echo "  Clear with:" >&2
            echo "    git push '$(_redact_url "$SUBGROVE_TEST_SUPER_NO_SM_URL")' :refs/tags/subgrove-test-lock" >&2
            exit 1
        fi
        _push_lock_tag_no_sm
        trap _fixture_remote_no_sm_teardown EXIT INT TERM
    fi

    # 2. Lazy bootstrap. If the baseline tag is missing, push one. This
    # is the no-sm tier's substitute for the with-sm tier's separate
    # init_remote.sh script. Idempotent: tag-present skips, tag-missing
    # bootstraps once.
    if ! _has_baseline_tag_no_sm "$SUBGROVE_TEST_SUPER_NO_SM_URL"; then
        _bootstrap_no_sm_baseline "$SUBGROVE_TEST_SUPER_NO_SM_URL"
    fi

    # 3. Reset main to baseline (cheap ref-only push).
    _reset_main_to_baseline_no_sm "$SUBGROVE_TEST_SUPER_NO_SM_URL"

    # 4. Working clone. No submodule init step — there are no submodules.
    git clone --quiet -- "$SUBGROVE_TEST_SUPER_NO_SM_URL" "$FIXTURE_SUPER"
    (
        cd "$FIXTURE_SUPER"
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        # See fixture_local.sh for why .worktree/ is pre-created.
        mkdir -p .worktree
        ln -s "$SUBGROVE_REPO_ROOT/subgrove" subgrove
    )

    export FIXTURE_ROOT FIXTURE_SUPER
}

_push_lock_tag_no_sm() {
    local lock_dir="$FIXTURE_ROOT/_lock"
    git init --quiet "$lock_dir"
    (
        cd "$lock_dir"
        git config user.email "test@subgrove.local"
        git config user.name  "Subgrove Tests"
        git commit --quiet --allow-empty -m "lock"
        git tag subgrove-test-lock
        # IMPORTANT: this `git push` MUST NOT use `--force`. Tag-uniqueness
        # at the server is what closes the TOCTOU window between our
        # `ls-remote` check above and the push here: a concurrent run that
        # passed the same check loses this race (its push is rejected
        # with "would clobber existing tag") and exits cleanly under
        # `set -e`. Adding `--force` would silently break the lock.
        git push --quiet -- "$SUBGROVE_TEST_SUPER_NO_SM_URL" refs/tags/subgrove-test-lock
    )
    SUBGROVE_TEST_NO_SM_LOCK_HELD=1
}

# Tests call this after `subgrove new feat-X` so the teardown trap can
# wipe the branch from the remote.
register_feature_branch_no_sm() {
    SUBGROVE_TEST_NO_SM_BRANCHES+=("$1")
}

_fixture_remote_no_sm_teardown() {
    local rc=$?
    local b lock_err

    # The test's cwd may have been inside FIXTURE_ROOT, which
    # cleanup_fixture_remote_no_sm just rm'd. Git refuses to run without
    # a readable cwd.
    cd "${TESTS_DIR:-/}" 2>/dev/null || cd /

    # Feature branches may or may not exist on the remote (depends on
    # whether the test pushed them). Best-effort cleanup, errors ignored.
    if [[ ${#SUBGROVE_TEST_NO_SM_BRANCHES[@]} -gt 0 ]]; then
        for b in "${SUBGROVE_TEST_NO_SM_BRANCHES[@]}"; do
            git push --quiet -- "$SUBGROVE_TEST_SUPER_NO_SM_URL" ":refs/heads/$b" 2>/dev/null || true
        done
    fi

    # The lock MUST be released — if it isn't, the next run blocks.
    # Capture stderr inline so the warning carries the actual git error.
    if [[ -n "$SUBGROVE_TEST_NO_SM_LOCK_HELD" ]]; then
        if ! lock_err=$(git push --quiet -- "$SUBGROVE_TEST_SUPER_NO_SM_URL" \
                            :refs/tags/subgrove-test-lock 2>&1); then
            echo "fixture_remote_no_sm: WARNING failed to release subgrove-test-lock." >&2
            if [[ -n "$lock_err" ]]; then
                printf '%s\n' "$lock_err" | sed 's/^/  /' >&2
            fi
            echo "  Clear manually with:" >&2
            echo "    git push '$(_redact_url "$SUBGROVE_TEST_SUPER_NO_SM_URL")' :refs/tags/subgrove-test-lock" >&2
            # Don't override the test's own exit code with the lock-release
            # failure, but do surface a non-zero rc if the test itself passed.
            [[ $rc -eq 0 ]] && rc=75   # EX_TEMPFAIL
        fi
        SUBGROVE_TEST_NO_SM_LOCK_HELD=""
    fi
    trap - EXIT INT TERM
    exit "$rc"
}

cleanup_fixture_remote_no_sm() {
    # cd out of FIXTURE_ROOT before rm'ing it so subsequent code (and
    # the teardown trap) doesn't run with a dead cwd.
    cd "${TESTS_DIR:-/}" 2>/dev/null || cd /
    if [[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
}
