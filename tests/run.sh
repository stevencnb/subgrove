#!/usr/bin/env bash
# Entry point for subgrove tests. Plain bash, zero deps.
#
#   tests/run.sh                run all tests (local + local-no-sm + remote + remote-no-sm)
#   tests/run.sh --local-only   skip ALL remote tiers (local + local-no-sm only)
#   tests/run.sh test_merge     substring filter against test basenames
#   tests/run.sh -v             stream each test's output live
#   tests/run.sh --clean        rm -rf tests/run/* and exit
#
# Tiers:
#   tests/local/         — with-submodule fixture (super/ + sm-a/ + sm-b/)
#   tests/local-no-sm/   — no-submodule fixture (super/ only, no .gitmodules)
#   tests/remote/        — real GitHub fixture with submodules (gated on tests/config.sh URLs)
#   tests/remote-no-sm/  — real GitHub fixture, no submodules (gated on SUBGROVE_TEST_SUPER_NO_SM_URL)
#
# Remote-test URLs come from tests/config.sh (committed). Override per-run
# via env: SUBGROVE_TEST_SUPER_URL=... SUBGROVE_TEST_SM_URL=...
# SUBGROVE_TEST_SM_URL2=... SUBGROVE_TEST_SUPER_NO_SM_URL=... tests/run.sh

set -eo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBGROVE_REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# Fixtures live under tests/run/ (gitignored). Each fixture is a wholly
# separate git repo built by `git init` so tests can't operate on the
# current git. Override the base with SUBGROVE_TEST_FIXTURES_DIR.
SUBGROVE_TEST_FIXTURES_DIR="${SUBGROVE_TEST_FIXTURES_DIR:-$TESTS_DIR/run}"
export TESTS_DIR SUBGROVE_REPO_ROOT SUBGROVE_TEST_FIXTURES_DIR

# Note: mkdir + the `.subgrove-test-fixtures` marker creation happens
# AFTER --clean parsing below — so a typo'd SUBGROVE_TEST_FIXTURES_DIR
# combined with --clean refuses (no marker present) instead of silently
# creating the marker and then wiping the wrong directory.

# Load remote-test URLs from tests/config.sh unless they're already set in
# env. Env values take precedence (useful for ad-hoc runs against a fork
# without editing the committed file).
if [[ -z "${SUBGROVE_TEST_SUPER_URL:-}" \
   || -z "${SUBGROVE_TEST_SM_URL:-}" \
   || -z "${SUBGROVE_TEST_SM_URL2:-}" \
   || -z "${SUBGROVE_TEST_SUPER_NO_SM_URL:-}" ]]; then
    if [[ -f "$TESTS_DIR/config.sh" ]]; then
        . "$TESTS_DIR/config.sh"
    fi
fi
export SUBGROVE_TEST_SUPER_URL SUBGROVE_TEST_SM_URL SUBGROVE_TEST_SM_URL2 SUBGROVE_TEST_SUPER_NO_SM_URL

usage() {
    cat <<'EOF'
Usage: tests/run.sh [-v] [--local-only] [--clean] [FILTER]

  -v             stream each test's output live (verbose)
  --local-only   skip ALL remote tiers (tests/local/ + tests/local-no-sm/ only)
  --clean        rm -rf tests/run/* and exit
  FILTER         run only tests whose basename contains FILTER

Tiers:
  tests/local/         with-submodule fixture (super/ + sm-a/ + sm-b/)
  tests/local-no-sm/   no-submodule fixture (super/ only, no .gitmodules)
  tests/remote/        real GitHub fixture with submodules (gated on URLs below)
  tests/remote-no-sm/  real GitHub fixture, no submodules (gated on URL below)

By default, runs all tiers. Remote-test URLs come from tests/config.sh.
Override with env:
  SUBGROVE_TEST_SUPER_URL=<git url for test superproject>
  SUBGROVE_TEST_SM_URL=<git url for first test submodule (sm-a)>
  SUBGROVE_TEST_SM_URL2=<git url for second test submodule (sm-b)>
  SUBGROVE_TEST_SUPER_NO_SM_URL=<git url for no-submodule test superproject>
EOF
}

verbose=0
local_only=0
filter=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) verbose=1; shift ;;
        --local-only) local_only=1; shift ;;
        --clean)
            if [[ ! -d "$SUBGROVE_TEST_FIXTURES_DIR" ]]; then
                echo "Nothing to clean: $SUBGROVE_TEST_FIXTURES_DIR/ does not exist." >&2
                exit 0
            fi
            # Resolve to a physical absolute path (defeats symlinks and
            # `..` segments) before any safety check or the rm.
            clean_dir="$(cd "$SUBGROVE_TEST_FIXTURES_DIR" && pwd -P)" \
                || { echo "Refusing --clean: cannot resolve $SUBGROVE_TEST_FIXTURES_DIR." >&2; exit 1; }
            # Protected-path blocklist. The marker check below is NOT
            # sufficient on its own: run.sh stamps the marker into
            # WHATEVER dir is configured, so a typo'd
            # SUBGROVE_TEST_FIXTURES_DIR=$HOME that was run once normally
            # would carry a valid marker. Refuse the high-value targets
            # outright, regardless of marker.
            home_parent="$(cd "$HOME/.." 2>/dev/null && pwd -P || echo /)"
            case "$clean_dir" in
                / | "$HOME" | "$home_parent" | "$SUBGROVE_REPO_ROOT" | "$TESTS_DIR")
                    echo "Refusing --clean: $clean_dir is a protected directory." >&2
                    echo "  SUBGROVE_TEST_FIXTURES_DIR looks misconfigured. Wipe manually if intended." >&2
                    exit 1 ;;
            esac
            # Allowlist on shape: the resolved path must look like a
            # fixtures dir. The default ($TESTS_DIR/run) matches */run;
            # custom overrides are expected to name themselves accordingly.
            case "$clean_dir" in
                */run | *subgrove* | *fixture*) : ;;  # looks like a fixtures dir
                *)
                    echo "Refusing --clean: $clean_dir doesn't look like a subgrove fixtures dir." >&2
                    echo "  Expected a path ending in /run or containing 'subgrove'/'fixture'." >&2
                    echo "  Wipe manually if this is really your fixtures dir." >&2
                    exit 1 ;;
            esac
            # Marker + symlink checks. The `.subgrove-test-fixtures`
            # marker is dropped below after `mkdir -p`; its absence means
            # this script never used the dir. Refuse a symlinked marker
            # so it can't redirect the rm.
            if [[ ! -f "$clean_dir/.subgrove-test-fixtures" ]]; then
                echo "Refusing --clean: $clean_dir/ lacks .subgrove-test-fixtures marker." >&2
                echo "  This dir was not created by tests/run.sh. Wipe manually if intended." >&2
                exit 1
            fi
            if [[ -L "$clean_dir/.subgrove-test-fixtures" ]]; then
                echo "Refusing --clean: marker file is a symlink." >&2
                exit 1
            fi
            echo "Cleaning $clean_dir/"
            rm -rf "$clean_dir"
            exit 0
            ;;
        -h|--help) usage; exit 0 ;;
        *) filter="$1"; shift ;;
    esac
done

# Now safe to create the fixtures dir + drop the marker (--clean has
# already been handled above and exited).
mkdir -p "$SUBGROVE_TEST_FIXTURES_DIR"
touch "$SUBGROVE_TEST_FIXTURES_DIR/.subgrove-test-fixtures"

# Rebuild the single `subgrove` script from its modular source (lib/init.sh)
# before any fixture symlinks it, so the suite always exercises current
# source. A stale committed subgrove then surfaces as a working-tree change.
if [[ -f "$SUBGROVE_REPO_ROOT/build.sh" ]]; then
    bash "$SUBGROVE_REPO_ROOT/build.sh" >/dev/null \
        || { echo "tests: build.sh failed" >&2; exit 1; }
fi

tests=()
for tier in local local-no-sm; do
    for t in "$TESTS_DIR"/"$tier"/test_*.sh; do
        [[ -f "$t" ]] || continue
        if [[ -n "$filter" ]]; then
            case "$(basename "$t")" in *"$filter"*) ;; *) continue ;; esac
        fi
        tests+=("$t")
    done
done
if [[ $local_only -ne 1 ]]; then
    # Sanity-check remote-test config up front so we fail fast (and once)
    # rather than per-test. Both remote tiers required by default.
    if [[ -z "${SUBGROVE_TEST_SUPER_URL:-}" \
       || -z "${SUBGROVE_TEST_SM_URL:-}" \
       || -z "${SUBGROVE_TEST_SM_URL2:-}" \
       || -z "${SUBGROVE_TEST_SUPER_NO_SM_URL:-}" ]]; then
        echo "Remote tests: URLs not configured." >&2
        echo "  Edit $TESTS_DIR/config.sh to point at your fixture repos" >&2
        echo "  (SUBGROVE_TEST_SUPER_URL, SUBGROVE_TEST_SM_URL, SUBGROVE_TEST_SM_URL2," >&2
        echo "  SUBGROVE_TEST_SUPER_NO_SM_URL)," >&2
        echo "  or pass --local-only to skip the remote tests." >&2
        exit 1
    fi
    for tier in remote remote-no-sm; do
        for t in "$TESTS_DIR"/"$tier"/test_*.sh; do
            [[ -f "$t" ]] || continue
            if [[ -n "$filter" ]]; then
                case "$(basename "$t")" in *"$filter"*) ;; *) continue ;; esac
            fi
            tests+=("$t")
        done
    done
fi

if [[ ${#tests[@]} -eq 0 ]]; then
    if [[ -n "$filter" ]]; then
        echo "No tests matched filter '$filter'" >&2
    else
        echo "No tests found under $TESTS_DIR" >&2
    fi
    exit 1
fi

echo "Running ${#tests[@]} test(s)"
if [[ $local_only -eq 1 ]]; then
    echo "(remote tests skipped: --local-only)"
fi
echo

passed=0
failed=0
failed_names=()

for t in "${tests[@]}"; do
    # Include the tier dir in the displayed name so test_new.sh in
    # local/ vs local-no-sm/ are distinguishable in the output.
    name="$(basename "$(dirname "$t")")/$(basename "$t" .sh)"
    if [[ $verbose -eq 1 ]]; then
        echo "--- $name"
        if ( bash "$t" ); then
            passed=$((passed + 1))
            echo "+++ $name PASS"
        else
            failed=$((failed + 1))
            failed_names+=("$name")
            echo "+++ $name FAIL"
        fi
        echo
    else
        out="$(mktemp "${TMPDIR:-/tmp}/subgrove-test.XXXXXX")"
        if ( bash "$t" >"$out" 2>&1 ); then
            passed=$((passed + 1))
            echo "  ok    $name"
        else
            failed=$((failed + 1))
            failed_names+=("$name")
            echo "  FAIL  $name"
            echo "    --- last 30 lines of $name output ---"
            tail -n 30 "$out" | sed 's/^/    /'
            echo "    --- end ---"
        fi
        rm -f "$out"
    fi
done

echo
echo "Passed: $passed"
echo "Failed: $failed"
if [[ $failed -gt 0 ]]; then
    echo "Failed tests:"
    for n in "${failed_names[@]}"; do echo "  - $n"; done
    exit 1
fi
