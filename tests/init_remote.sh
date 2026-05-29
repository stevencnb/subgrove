#!/usr/bin/env bash
# tests/init_remote.sh — one-time bootstrap of the three GitHub repos used
# by tests/remote/.
#
# ┌────────────────────────────────────────────────────────────────────┐
# │ RUN THIS ONCE per set of test repos.                              │
# │                                                                    │
# │ It pushes an initial baseline to all three remotes and tags it    │
# │ `subgrove-baseline`. After that, every remote test run resets     │
# │ main back to that tag (cheap, ref-only) and adds its own edits.   │
# │                                                                    │
# │ You only need to re-run it if:                                    │
# │   - you rotate to fresh fixture repos (URLs change in config.sh)  │
# │   - someone force-pushed over the baseline tag                    │
# │   - you pass --force to deliberately re-bootstrap                 │
# └────────────────────────────────────────────────────────────────────┘
#
# Usage:
#   tests/init_remote.sh             # init if not already initialized
#   tests/init_remote.sh --force     # re-init even if already initialized
#
# URLs come from tests/config.sh (or env: SUBGROVE_TEST_SUPER_URL,
# SUBGROVE_TEST_SM_URL, SUBGROVE_TEST_SM_URL2).

set -eo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load URLs from config.sh unless already set in env.
if [[ -z "${SUBGROVE_TEST_SUPER_URL:-}" \
   || -z "${SUBGROVE_TEST_SM_URL:-}" \
   || -z "${SUBGROVE_TEST_SM_URL2:-}" ]]; then
    if [[ -f "$TESTS_DIR/config.sh" ]]; then
        . "$TESTS_DIR/config.sh"
    fi
fi

# Match the fixture's identity so commits made here and commits made by
# the per-test fixtures look uniform in the remote history.
export GIT_CONFIG_PARAMETERS="'user.email=test@subgrove.local' 'user.name=Subgrove Tests'"

force=0
yes=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) force=1 ;;
        --yes|-y)   yes=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "init_remote.sh: unknown flag '$arg'" >&2
            echo "  usage: tests/init_remote.sh [--force] [--yes]" >&2
            exit 2 ;;
    esac
done

_require_var() {
    local name="$1"
    # ${!name:-} is bash 3.2+ indirect expansion — no eval, no injection
    # if the variable name itself ever becomes attacker-controlled.
    if [[ -z "${!name:-}" ]]; then
        echo "init_remote.sh: $name is empty." >&2
        echo "  Fill it in at $TESTS_DIR/config.sh and re-run." >&2
        exit 1
    fi
}

# _redact_url URL — strip userinfo from URL for safe stderr printing.
# Inline copy of mutators.sh::_redact_url since init_remote.sh doesn't
# source it. Keep the two implementations in sync. The `.*@` match is
# greedy on purpose so a password containing a literal `@` is fully
# masked (see the fuller rationale in mutators.sh).
_redact_url() {
    local url="$1"
    case "$url" in
        *://*@*) printf '%s\n' "$url" | sed -E 's|://.*@|://REDACTED@|' ;;
        *)       printf '%s\n' "$url" ;;
    esac
}

_require_var SUBGROVE_TEST_SUPER_URL
_require_var SUBGROVE_TEST_SM_URL
_require_var SUBGROVE_TEST_SM_URL2

_has_baseline_tag() {
    # `--` terminates option parsing so a URL like `--upload-pack=...`
    # can't slip through as a CLI option.
    git ls-remote -- "$1" refs/tags/subgrove-baseline 2>/dev/null \
        | grep -q refs/tags/subgrove-baseline
}

if [[ $force -ne 1 ]]; then
    if _has_baseline_tag "$SUBGROVE_TEST_SUPER_URL" \
       && _has_baseline_tag "$SUBGROVE_TEST_SM_URL" \
       && _has_baseline_tag "$SUBGROVE_TEST_SM_URL2"; then
        echo "All three remotes already have subgrove-baseline. Nothing to do."
        echo "(Use --force to re-bootstrap from scratch.)"
        exit 0
    fi
fi

# About to force-push three histories — surface the URLs and require a
# human Y/n before doing it. Bypassable with --yes for scripted/CI use.
# Without this, a typo in tests/config.sh would silently nuke whatever
# the URLs happen to point at. URLs are redacted before display so an
# HTTPS-with-PAT env override doesn't leak credentials into terminal
# scrollback / typescripts.
cat >&2 <<EOF

About to force-push initial baseline + 'subgrove-baseline' tag to:

  super: $(_redact_url "$SUBGROVE_TEST_SUPER_URL")
  sm-a:  $(_redact_url "$SUBGROVE_TEST_SM_URL")
  sm-b:  $(_redact_url "$SUBGROVE_TEST_SM_URL2")

This OVERWRITES whatever 'main' currently points to on each repo. Make
sure these URLs are dedicated subgrove test repos and NOT a real project.

EOF

if [[ $yes -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        echo "init_remote.sh: refusing to bootstrap non-interactively without --yes." >&2
        echo "  Re-run with --yes if you have confirmed the URLs." >&2
        exit 1
    fi
    printf "Proceed? [y/N] " >&2
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Aborted." >&2; exit 1 ;;
    esac
fi

# Take the same advisory lock the per-test fixture uses, so an init can't
# race with a concurrent test run. Released on EXIT/INT/TERM.
if git ls-remote -- "$SUBGROVE_TEST_SUPER_URL" refs/tags/subgrove-test-lock 2>/dev/null \
        | grep -q refs/tags/subgrove-test-lock; then
    echo "init_remote.sh: lock tag exists on $(_redact_url "$SUBGROVE_TEST_SUPER_URL")." >&2
    echo "  A remote test may be running, or a previous run died." >&2
    echo "  Clear with:" >&2
    echo "    git push '$(_redact_url "$SUBGROVE_TEST_SUPER_URL")' :refs/tags/subgrove-test-lock" >&2
    exit 1
fi

INIT_TMP="$(mktemp -d -t subgrove-init.XXXXXX)"
LOCK_HELD=0

_teardown() {
    local rc=$?
    local lock_err
    if [[ $LOCK_HELD -eq 1 ]]; then
        # Inline-capture pattern (matches fixture_remote.sh): robust even
        # if $INIT_TMP becomes inaccessible mid-teardown — no dependency
        # on a file that may have been rm'd.
        if ! lock_err=$(git push --quiet -- "$SUBGROVE_TEST_SUPER_URL" \
                            :refs/tags/subgrove-test-lock 2>&1); then
            echo "init_remote.sh: WARNING failed to release lock tag:" >&2
            if [[ -n "$lock_err" ]]; then
                printf '%s\n' "$lock_err" | sed 's/^/  /' >&2
            fi
            echo "  Clear manually with:" >&2
            echo "    git push '$(_redact_url "$SUBGROVE_TEST_SUPER_URL")' :refs/tags/subgrove-test-lock" >&2
        fi
    fi
    rm -rf "$INIT_TMP"
    trap - EXIT INT TERM
    exit "$rc"
}
trap _teardown EXIT INT TERM

(
    cd "$INIT_TMP"
    git init --quiet _lock
    cd _lock
    git commit --quiet --allow-empty -m "lock"
    git tag subgrove-test-lock
    git push --quiet -- "$SUBGROVE_TEST_SUPER_URL" refs/tags/subgrove-test-lock
)
LOCK_HELD=1

# _init_sm LABEL URL
# Force-pushes a one-commit baseline + subgrove-baseline tag to URL's main.
# Single commit (README only) is enough — the per-test fixture will add
# feature-side changes on top.
_init_sm() {
    local label="$1" url="$2"
    local seed="$INIT_TMP/_seed_$label"
    echo "  init $label: $(_redact_url "$url")"
    git init --quiet "$seed"
    (
        cd "$seed"
        git symbolic-ref HEAD refs/heads/main
        echo "$label baseline" > README
        git add README
        git commit --quiet -m "baseline ($label)"
        git tag subgrove-baseline
        git push --quiet --force -- "$url" \
            refs/heads/main:refs/heads/main \
            refs/tags/subgrove-baseline:refs/tags/subgrove-baseline
    )
}

# Super baseline. Wires sm-a and sm-b in as submodules pointing at their
# (just-pushed) baseline tips. Carries the .subgroverc + .gitignore that
# every test relies on.
_init_super() {
    local seed="$INIT_TMP/_super_seed"
    echo "  init super: $(_redact_url "$SUBGROVE_TEST_SUPER_URL")"
    git init --quiet "$seed"
    (
        cd "$seed"
        git symbolic-ref HEAD refs/heads/main
        echo "super baseline" > README
        git add README
        git commit --quiet -m "baseline (super)"

        # `--` terminates option parsing so a URL beginning with `-`
        # can't slip through as a submodule-add option.
        git submodule add --quiet -- "$SUBGROVE_TEST_SM_URL"  sm-a
        git submodule add --quiet -- "$SUBGROVE_TEST_SM_URL2" sm-b
        git commit --quiet -m "add submodules sm-a sm-b"

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
        git push --quiet --force -- "$SUBGROVE_TEST_SUPER_URL" \
            refs/heads/main:refs/heads/main \
            refs/tags/subgrove-baseline:refs/tags/subgrove-baseline
    )
}

echo "Bootstrapping remote test fixture (this is a one-time operation)..."
_init_sm    sm-a "$SUBGROVE_TEST_SM_URL"
_init_sm    sm-b "$SUBGROVE_TEST_SM_URL2"
_init_super

echo "Done. Remote tests can now run via tests/run.sh."
