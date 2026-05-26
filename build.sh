#!/usr/bin/env bash
# build.sh — assemble the single distributed `subgrove` script from its
# modular source. The init wizard is authored in lib/init.sh; this inlines
# it into the marked region of `subgrove`, so the shipped script is one
# self-contained file with no runtime dependency on lib/. Edit lib/init.sh,
# then run ./build.sh.
#
#   ./build.sh           rewrite subgrove's generated region in place
#   ./build.sh --check   exit non-zero if the region is out of sync (CI/test guard)
set -eo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/subgrove"
LIB="$HERE/lib/init.sh"
BEGIN="# >>> generated from lib/init.sh"
END="# <<< end generated <<<"

[[ -f "$SCRIPT" ]] || { echo "build: missing $SCRIPT" >&2; exit 1; }
[[ -f "$LIB" ]]    || { echo "build: missing $LIB" >&2; exit 1; }
if ! grep -q "$BEGIN" "$SCRIPT" || ! grep -q "$END" "$SCRIPT"; then
    echo "build: generated-region markers not found in $SCRIPT" >&2
    exit 1
fi

# Copy subgrove, replacing everything between the BEGIN and END marker lines
# with the current contents of lib/init.sh. Idempotent: re-running with an
# unchanged lib/init.sh reproduces the same file byte-for-byte.
gen() {
    awk -v libfile="$LIB" -v begin="$BEGIN" -v end="$END" '
        index($0, begin) == 1 {
            print
            while ((getline line < libfile) > 0) print line
            close(libfile)
            skip = 1
            next
        }
        index($0, end) == 1 { skip = 0; print; next }
        skip { next }
        { print }
    ' "$SCRIPT"
}

tmp="$(mktemp "${TMPDIR:-/tmp}/subgrove-build.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
gen > "$tmp"

if [[ "${1:-}" == "--check" ]]; then
    if cmp -s "$tmp" "$SCRIPT"; then
        echo "build: subgrove is in sync with lib/init.sh"
        exit 0
    fi
    echo "build: subgrove is OUT OF SYNC with lib/init.sh — run ./build.sh" >&2
    exit 1
fi

cp "$tmp" "$SCRIPT"
chmod +x "$SCRIPT"
echo "build: regenerated $SCRIPT from lib/init.sh"
