#!/usr/bin/env bash
# build.sh assembles `subgrove` from lib/init.sh: it is idempotent, and
# --check detects when the generated region is out of sync with lib/init.sh.
# Exercised against a throwaway COPY so the real repo's subgrove is untouched.
set -eo pipefail

. "$(dirname "$0")/../lib/assert.sh"
SUBGROVE_REPO_ROOT="${SUBGROVE_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

work="$(mktemp -d "${TMPDIR:-/tmp}/subgrove-build-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$SUBGROVE_REPO_ROOT/subgrove" "$work/subgrove"
mkdir -p "$work/lib"
cp "$SUBGROVE_REPO_ROOT/lib/init.sh" "$work/lib/init.sh"
cp "$SUBGROVE_REPO_ROOT/build.sh" "$work/build.sh"

# In sync to start (the suite builds before running), and idempotent.
( cd "$work" && bash build.sh >/dev/null )
cp "$work/subgrove" "$work/subgrove.1"
( cd "$work" && bash build.sh >/dev/null )
cmp -s "$work/subgrove" "$work/subgrove.1" || fail "build.sh is not idempotent"
( cd "$work" && bash build.sh --check >/dev/null ) || fail "--check should pass when in sync"

# Edit lib/init.sh without rebuilding -> --check must detect the drift.
printf '\n# drift marker\n' >> "$work/lib/init.sh"
if ( cd "$work" && bash build.sh --check >/dev/null 2>&1 ); then
    fail "--check should fail when lib/init.sh changed without a rebuild"
fi
# Rebuild reconciles, and the edit lands inside the generated region.
( cd "$work" && bash build.sh >/dev/null )
( cd "$work" && bash build.sh --check >/dev/null ) || fail "--check should pass after rebuild"
assert_grep "$work/subgrove" "drift marker"

echo "PASS"
