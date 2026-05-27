#!/usr/bin/env bash
# Assertions for subgrove tests. macOS bash 3.2 compatible.
#
# Each helper exits non-zero (via `fail`) on assertion failure. Tests run
# under `set -eo pipefail`, so a failed assertion aborts the test and the
# fixture is preserved for inspection.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        fail "${msg:+$msg: }expected '$expected', got '$actual'"
    fi
}

assert_ne() {
    local a="$1" b="$2" msg="${3:-}"
    if [[ "$a" == "$b" ]]; then
        fail "${msg:+$msg: }expected '$a' != '$b' but they are equal"
    fi
}

# assert_branch_at GIT_DIR BRANCH [EXPECTED_REF_OR_SHA]
# Without EXPECTED: asserts BRANCH exists in GIT_DIR.
# With EXPECTED: asserts the branch's SHA equals EXPECTED's resolution.
assert_branch_at() {
    local git_dir="$1" branch="$2" expected="${3:-}"
    local actual_sha
    actual_sha="$(git -C "$git_dir" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" \
        || fail "branch '$branch' missing in $git_dir"
    if [[ -n "$expected" ]]; then
        local expected_sha
        expected_sha="$(git -C "$git_dir" rev-parse --verify --quiet "$expected" 2>/dev/null \
                       || git rev-parse --verify --quiet "$expected" 2>/dev/null \
                       || echo "$expected")"
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            fail "branch '$branch' in $git_dir at $actual_sha, expected $expected_sha (from '$expected')"
        fi
    fi
}

# assert_head_on DIR BRANCH — asserts HEAD is symbolic-ref to refs/heads/BRANCH.
assert_head_on() {
    local dir="$1" branch="$2"
    local actual
    actual="$(git -C "$dir" symbolic-ref --quiet HEAD 2>/dev/null || true)"
    if [[ "$actual" != "refs/heads/$branch" ]]; then
        fail "$dir: expected HEAD on refs/heads/$branch, got '${actual:-(detached)}'"
    fi
}

assert_no_branch() {
    local git_dir="$1" branch="$2"
    if git -C "$git_dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
        fail "branch '$branch' unexpectedly exists in $git_dir"
    fi
}

assert_clean() {
    local dir="$1"
    if ! git -C "$dir" diff --quiet 2>/dev/null; then
        fail "$dir has unstaged changes (expected clean)"
    fi
    if ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        fail "$dir has staged changes (expected clean)"
    fi
}

assert_dirty() {
    local dir="$1"
    if git -C "$dir" diff --quiet 2>/dev/null && git -C "$dir" diff --cached --quiet 2>/dev/null; then
        fail "$dir is clean (expected dirty)"
    fi
}

assert_grep() {
    local file="$1" pattern="$2"
    if ! grep -qE -- "$pattern" "$file"; then
        echo "--- contents of $file ---" >&2
        cat "$file" >&2
        echo "--- end ---" >&2
        fail "pattern '$pattern' not found in $file"
    fi
}

assert_grep_v() {
    local file="$1" pattern="$2"
    if grep -qE -- "$pattern" "$file"; then
        fail "pattern '$pattern' unexpectedly found in $file"
    fi
}

assert_file_exists() {
    local path="$1"
    [[ -e "$path" ]] || fail "expected to exist: $path"
}

assert_file_absent() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "expected to NOT exist: $path"
}

# snapshot_state DIR
# Captures DIR's repo state as a printable blob: HEAD ref + SHA, working
# tree status (`git status --porcelain`), unstaged diff, staged diff.
#
# Intentionally excludes `git show-ref`: linked worktrees share parent-repo
# refs with the main worktree, so `refs/heads/main` legitimately changes
# under a worktree's feet when main super advances during merge. The fields
# captured here track what's local to the working dir + HEAD + index, which
# is what "this dir wasn't touched" really means in practice.
#
# Use with assert_state_eq across an operation to verify it didn't touch
# the repo. Particularly useful on dirty-refuse paths: the pending edits
# (staged or unstaged) must still be present and unchanged afterward.
snapshot_state() {
    local dir="$1"
    {
        echo "HEAD-ref: $(git -C "$dir" symbolic-ref HEAD 2>/dev/null || echo detached)"
        echo "HEAD-sha: $(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
        echo "--- status ---"
        # -uno: exclude untracked files. Tests redirect subgrove's output
        # to an `out` file inside the working dir; that's a test artifact,
        # not state subgrove touched. Modifications and staged changes are
        # still reported as expected.
        git -C "$dir" status --porcelain=v1 -uno 2>/dev/null || true
        echo "--- unstaged ---"
        git -C "$dir" diff 2>/dev/null || true
        echo "--- staged ---"
        git -C "$dir" diff --cached 2>/dev/null || true
    }
}

# assert_state_eq DIR EXPECTED_SNAPSHOT [MSG]
# Verifies DIR's current snapshot matches a previously-captured one.
assert_state_eq() {
    local dir="$1" expected="$2" msg="${3:-}"
    local actual
    actual="$(snapshot_state "$dir")"
    if [[ "$expected" != "$actual" ]]; then
        echo "--- snapshot mismatch in $dir ---" >&2
        diff <(echo "$expected") <(echo "$actual") >&2 || true
        fail "${msg:+$msg: }state in $dir changed unexpectedly"
    fi
}

# assert_ancestor GIT_DIR ANCESTOR DESCENDANT [MSG]
# Verifies ANCESTOR is reachable from DESCENDANT (i.e. ANCESTOR is in
# DESCENDANT's commit history).
assert_ancestor() {
    local dir="$1" ancestor="$2" descendant="$3" msg="${4:-}"
    git -C "$dir" merge-base --is-ancestor "$ancestor" "$descendant" 2>/dev/null \
        || fail "${msg:+$msg: }$ancestor is not an ancestor of $descendant in $dir"
}

# assert_commits_ahead DIR FROM TO EXPECTED [MSG]
# Verifies there are exactly EXPECTED commits between FROM..TO in DIR.
# Use to pin the commit-state of a repo: e.g.
#   assert_commits_ahead .worktree/feat-x main feat/feat-x 1
# verifies feat/feat-x is exactly one commit ahead of main.
assert_commits_ahead() {
    local dir="$1" from="$2" to="$3" expected="$4" msg="${5:-}"
    local actual
    actual="$(git -C "$dir" rev-list --count "${from}..${to}" 2>/dev/null)" || actual="?"
    [[ "$actual" == "$expected" ]] \
        || fail "${msg:+$msg: }$dir: expected $expected commits between $from..$to, got $actual"
}

# assert_pending_file DIR FILE MODE [MSG]
# Verifies FILE has a specific kind of pending change in DIR.
# MODE: "unstaged" | "staged" | "both" | "none"
# Uses `git status --porcelain` short-format codes:
#   " M" = unstaged modification
#   "M " = staged modification (index)
#   "MM" = both staged and unstaged
#   ""   = clean
assert_pending_file() {
    local dir="$1" file="$2" mode="$3" msg="${4:-}"
    local actual
    actual="$(git -C "$dir" status --porcelain -- "$file" 2>/dev/null)"
    case "$mode" in
        none)
            [[ -z "$actual" ]] \
                || fail "${msg:+$msg: }$dir: expected $file clean, got: '$actual'"
            ;;
        unstaged)
            [[ "$actual" == " M $file" ]] \
                || fail "${msg:+$msg: }$dir: expected '$file' unstaged-modified, got: '$actual'"
            ;;
        staged)
            [[ "$actual" == "M  $file" ]] \
                || fail "${msg:+$msg: }$dir: expected '$file' staged-modified, got: '$actual'"
            ;;
        both)
            [[ "$actual" == "MM $file" ]] \
                || fail "${msg:+$msg: }$dir: expected '$file' both staged+unstaged, got: '$actual'"
            ;;
        *)
            fail "assert_pending_file: unknown mode '$mode' (use none|unstaged|staged|both)"
            ;;
    esac
}

# assert_pending_submodule DIR SM_PATH [MSG]
# Verifies the parent at DIR shows SM_PATH as having a submodule SHA delta
# (the "M <submodule>" state that fires when a submodule's HEAD moved
# without the parent recording a bump).
assert_pending_submodule() {
    local dir="$1" sm="$2" msg="${3:-}"
    local actual
    actual="$(git -C "$dir" status --porcelain -- "$sm" 2>/dev/null)"
    [[ "$actual" == " M $sm" ]] \
        || fail "${msg:+$msg: }$dir: expected '$sm' as M (submodule SHA delta), got: '$actual'"
}

# assert_status PATTERN...
# Run `subgrove status` (read-only) from the current worktree super and
# assert each PATTERN (ERE) appears in its output. Encodes the suite rule
# (docs/design/testing.md §15) that a state-changing command's test also
# verifies the resulting state through `status`. Captures into a variable,
# so it never clobbers the conventional `out` file. Requires the cwd to be a
# worktree where `./subgrove` resolves and `discover_root` succeeds (i.e.
# $FIXTURE_SUPER), which every scenario already cd's into.
assert_status() {
    local sout p
    sout="$(./subgrove status 2>&1)" \
        || { printf '%s\n' "$sout" >&2; fail "subgrove status exited non-zero"; }
    for p in "$@"; do
        if ! grep -qE -- "$p" <<<"$sout"; then
            printf '%s\n' "--- subgrove status ---" "$sout" "--- end ---" >&2
            fail "status output missing pattern: $p"
        fi
    done
}

# assert_status_absent PATTERN...
# Inverse of assert_status: each PATTERN must NOT appear in `subgrove status`
# output (e.g. a feature name after a successful `remove`).
assert_status_absent() {
    local sout p
    sout="$(./subgrove status 2>&1)" \
        || { printf '%s\n' "$sout" >&2; fail "subgrove status exited non-zero"; }
    for p in "$@"; do
        if grep -qE -- "$p" <<<"$sout"; then
            printf '%s\n' "--- subgrove status ---" "$sout" "--- end ---" >&2
            fail "status output unexpectedly contains: $p"
        fi
    done
}
