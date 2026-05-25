# Testing

Subgrove ships with a real-git test suite under `tests/`. Subgrove's logic is too tangled in git's actual behavior — submodule git-dir isolation, `upload-pack` advertising only `refs/heads/*`, `git fetch`'s refusal to update a checked-out branch — to mock cleanly. Every scenario builds real repos from scratch using plain `git init`, runs subgrove against the fixture, and asserts both the script's output and the resulting repository state.

## Layout

```
tests/
├── run.sh           # entry point; runs all tests or a filtered subset
├── init_remote.sh   # one-time bootstrap of the with-sm remote fixture repos
├── config.sh        # remote-test URLs (committed; maintainer fills in)
├── lib/
│   ├── assert.sh    # assert_eq, assert_branch_at, assert_grep, ...
│   ├── mutators.sh  # commit_one + push_to_origin_main (side-clone helpers)
│   ├── fixture_local.sh
│   ├── fixture_local_no_sm.sh
│   ├── fixture_remote.sh
│   └── fixture_remote_no_sm.sh
├── local/           # local-only tests (no GitHub), with-submodule fixture
├── local-no-sm/     # local-only tests, no-submodule fixture
├── remote/          # tests that push to real GitHub, with-submodule fixture
├── remote-no-sm/    # tests that push to real GitHub, no-submodule fixture
└── run/             # gitignored; per-test fixtures land here at runtime
```

## Local tests (default)

The local fixture is three `git init`'d repos at `tests/run/<timestamp>-<name>/`:

- `sm-a/` — standalone submodule source, one commit on `main`
- `sm-b/` — same
- `super/` — `git init`'d in place (so it has **no** `origin`). The two submodules are wired in via `git submodule add file:///…/sm-a` and the equivalent for sm-b.

That super-has-no-origin shape matches the "user didn't configure a remote on the superproject" scenario the local tests are meant to cover. The submodules under `super/` get `file://` origins to their sibling repos (set automatically by `submodule add`) so subgrove can `git fetch` from them.

Tests cd into `super/` and invoke subgrove through a symlink to the script under test. "Upstream change" scenarios are simulated by committing directly in the sibling `sm-a/` or `sm-b/` repo — subgrove's `git fetch origin main` in the main super's submodule picks it up via `file://`.

Paths NOT covered locally:

- `merge push=true` happy path — super has no `origin`, push has no remote to land on. (A push=true error path **is** covered locally — see the no-submodule tier below.)
- `new`'s fresh-base-from-origin — same reason.

Both are covered by the remote tests.

### No-submodule variant (`tests/local-no-sm/`)

A parallel tier under `tests/local-no-sm/` exercises subgrove against a super with **no** `.gitmodules` and no submodules at all. The fixture is a single `git init super/` — no sibling `sm-a/`/`sm-b/` repos. Same `.gitignore` / `.subgroverc` / `subgrove` symlink as the with-submodule fixture.

Full design, scenarios, and per-file case lists live in [testing-local-no-sm.md](testing-local-no-sm.md). At a glance, the tier guards four invariants:

1. **Subgrove degrades gracefully when `.gitmodules` is absent.** `list_all_submodules` returns empty and every consumer no-ops.
2. **Submodule-phase info lines stay honest in the zero-submodule case** — `touched: (none)`, `Submodules merged: (none)`, `Updated 0 submodule main(s)`, etc.
3. **Submodule-relevant parameters never crash on a no-sm super.** `touch=<sm>`, multi-name `touch=`, `BUILD_CHAIN=(<sm>)`, `merge push=true` — each errs cleanly with rollback (where applicable) or produces a defined no-op.
4. **Parent-only flows are isolated from submodule machinery** (no `_update_sync` ref leaks; "Preserved N submodule branch(es)" line absent on no-sm `remove`).

Run with `tests/run.sh --local-only`, which discovers both `local/` and `local-no-sm/`. The remote tier has a no-submodule counterpart under `tests/remote-no-sm/` (uses a fourth fixture URL, `SUBGROVE_TEST_SUPER_NO_SM_URL`, and lazily bootstraps its baseline inside the fixture rather than via `init_remote.sh`). See [testing-remote-no-sm.md](testing-remote-no-sm.md) for what that tier guards.

## Remote tests (opt-in, default-on when configured)

Gated on three GitHub URLs in `tests/config.sh`:

- `SUBGROVE_TEST_SUPER_URL` — the test superproject
- `SUBGROVE_TEST_SM_URL` — first test submodule (mapped to `sm-a`)
- `SUBGROVE_TEST_SM_URL2` — second test submodule (mapped to `sm-b`)

The remote tier uses a two-layer fixture: one-time bootstrap, then per-test reset.

### One-time bootstrap

After filling in `tests/config.sh` (or pointing the env vars at fresh fixture repos), run:

```bash
tests/init_remote.sh             # prompts before force-pushing
tests/init_remote.sh --yes       # non-interactive (CI)
tests/init_remote.sh --force --yes  # re-bootstrap even if baseline exists
```

The script pushes a one-commit baseline + `subgrove-baseline` tag to each of the three remotes. Idempotent: if all three already have the tag, it exits without touching anything. `--force` bypasses the skip-check; a human `[y/N]` prompt fires before the actual force-push and is bypassable with `--yes`.

### Per-test flow

1. **Baseline-tag precondition check.** Verify `subgrove-baseline` exists on all three; fail loudly with a "run `tests/init_remote.sh`" hint if missing.
2. **Lock.** First `mkfixture_remote` in the script checks `git ls-remote $SUBGROVE_TEST_SUPER_URL refs/tags/subgrove-test-lock`; if present, aborts with the remediation command. Otherwise pushes the tag and registers an `EXIT`/`INT`/`TERM` trap to delete it. The lock is process-scoped: a multi-iteration test (matrix) acquires once and keeps the lock until script exit.
3. **Reset main to baseline.** For each URL, `git push --force <url> refs/tags/subgrove-baseline:refs/heads/main` — cheap ref-only push (baseline objects are already on the server). Every test starts from a known-clean state on all three remotes.
4. **Working clone.** Clone super into `tests/run/<ts>-remote-<name>/super/`, init both submodules, drop in the `subgrove` symlink and `.worktree/`.
5. **Teardown trap.** `cd` to a known-good cwd (in case the test rm'd its own cwd), best-effort delete every feature branch the script registered on all three repos, then delete the lock tag (inline stderr capture: a real release failure surfaces a loud warning with manual-recovery hint).

The remote tests are **intentionally serial**. The lock turns a parallel run from another machine into a fast failure rather than corrupted state. Run `tests/run.sh --local-only` to skip the remote tests entirely (useful in CI or for contributors without push access to the fixture repos).

Multi-submodule scenarios over the wire — `push=true` advancing every origin, partial `update` where only one submodule moved, push order on multi-package failures (sm-a → sm-b → super; set -e abort on first), per-package origin-drift matrices for both `merge push=true` and `update` — are covered here. The two-phase merge half-state invariant stays local-only: forging a divergent submodule commit while keeping the parent clean is awkward over the wire without an extra contributor clone.

The no-submodule remote tier (`tests/remote-no-sm/`) pins wire-only paths that neither the with-sm remote tier nor the local-no-sm tier can reach: the `new` parent-base-from-origin, `update`'s real `git fetch origin main`, the `merge push=true` happy path on a no-sm super, and the `remove`-doesn't-touch-origin invariant. Its fixture lazily bootstraps the baseline on first call — no separate init script.

Full case lists in [testing-remote.md](testing-remote.md) and [testing-remote-no-sm.md](testing-remote-no-sm.md).

## Conventions

Each test file is one `bash` script under `set -eo pipefail`. Scenarios are comment-headed blocks (`# --- case: ... ---`); each builds its own fixture and ends with `cleanup_fixture` as the LAST line. Failures under `set -e` exit before `cleanup_fixture` runs, leaving the fixture on disk for inspection — the runner prints the path on failure.

The per-test subshell + per-scenario fixture is the only isolation. No setup/teardown helpers spanning blocks; reading the file top-to-bottom enumerates every scenario in order.

## How a test runs

Per scenario, the lifecycle is:

1. **`mkfixture_local <name>` builds a fresh standalone fixture** at `tests/run/<timestamp>-<pid>-<random>-<name>/`. The fixture is three plain `git init` repos (`sm-a`, `sm-b`, `super`), with the two submodules wired into `super/` via `git submodule add file://…`. A `subgrove` symlink to the script under test is dropped at the super's root, and an empty `.worktree/` directory is pre-created (workaround for subgrove's `git check-ignore` on the trailing-slash pattern). See [testing-local.md](testing-local.md#test-lifecycle) for the full per-step breakdown.
2. **The test does its work.** `cd $FIXTURE_SUPER`, invoke `./subgrove …`, capture output to a file, run assertions. All git operations are scoped to the fixture — subgrove's `$SCRIPT_DIR` resolves to the fixture (via `dirname $0` of the symlink invocation), so it never touches the surrounding subgrove repo.
3. **`cleanup_fixture` removes the fixture — but only on success.** Called as the LAST statement of each scenario. Because every test runs under `set -eo pipefail`, an assertion failure exits the script before `cleanup_fixture` runs, leaving the fixture on disk. The runner prints the fixture path during creation; `tests/run.sh --clean` wipes the whole `tests/run/` directory.

Each scenario is its own fresh repo; scenarios within a file are sequential and independent. Each test file is run in its own subshell by `tests/run.sh`, so a test's `cd` or env mutation can't bleed into the next file.

## Test design principles

The patterns below apply to every test in the suite, local and remote. New tests follow these idioms; deviations need a reason in a comment.

### 1. Real git, no mocks

Every scenario builds real repos with `git init` + `git submodule add` and runs subgrove against them. Subgrove's logic is too tangled with git's actual behavior to mock cleanly. Helpers wrap real git invocations.

### 2. One fresh fixture per scenario

Every scenario starts with `mkfixture_local` (or `mkfixture_remote`) and ends with `cleanup_fixture` as its last statement. No state sharing across scenarios; no setup/teardown helpers that span blocks. Failures under `set -e` exit before `cleanup_fixture` runs, leaving the fixture on disk for inspection.

### 3. Pre-state verification before the operation

After setup, **before invoking the command under test**, assert what the setup actually produced — clean/dirty state per location, commit counts on feat branches, specific files pending. Catches a class of bugs where the setup silently failed (e.g., a no-op `commit_one`) and the test exercises a different scenario than it claims to.

The matrix tests' `_verify_pre_state` helper does this parametrically across all 6 locations.

### 4. State preservation on refuse and no-op paths

For any operation that refuses (dirty check, FF check) or no-ops (Phase 0 filter, sentinel skip), `snapshot_state` all relevant locations before the operation and `assert_state_eq` each one after. Catches silent side-effect bugs that state-specific assertions wouldn't see.

### 5. History correctness on success paths

For successful merges, `assert_ancestor` every commit between old `main` and the feat tip — verifies they're all in `main`'s history. Tip-equality alone wouldn't catch a future change from `git merge --ff-only` to `git merge --squash`: the tip would still match, but the history would differ.

### 6. Specific err-text greps on refuse paths

Each `require_clean` call (and similar gates) passes a unique label naming the affected location. Tests grep for the **exact** err string (e.g., `"main submodule 'sm-a' (dst) has uncommitted"`). Catches label-swap regressions where refusal still fires but with the wrong location named.

### 7. Info-line greps where text encodes behavior

Where subgrove's narration encodes a branch decision (`"Branching 2 submodule(s) to feat/feat-x"`, `"Submodule branching skipped (touch=none)"`, `"Preserved N submodule feat branch(es) ..."`, `"Fast-forwarding parent main"`), tests pin the text. Pure narration (`"Fetching origin/main"`, `"Initialising submodules"`) is not pinned — only lines whose content tells you _which branch of behavior was taken_.

### 8. Negative assertions for skipped phases

On refuse paths, negative-assert that info lines from skipped phases do NOT appear (e.g. `"Moving main forward"` must be absent on a dirty refuse — Phase 2 didn't run). Catches the case where a phase emitted its info line without actually executing.

### 9. Per-file pending state, not just clean/dirty

`assert_pending_file DIR FILE MODE` (MODE ∈ `none | unstaged | staged | both`) pins a specific file's pending state. `assert_pending_submodule DIR SM_PATH` covers the "M `<submodule>`" implicit-dirty case (submodule HEAD moved without parent bumping). Generic `assert_clean` / `assert_dirty` won't catch dropped-pending-edit bugs.

### 10. Commit-count verification

`assert_commits_ahead DIR FROM TO EXPECTED` pins exact commit counts between two refs. Used both pre-operation (verify setup) and post-operation (verify merge caught up). Catches both setup bugs and unexpected commit creation.

### 11. Snapshot composition

`snapshot_state` captures:

- HEAD ref (symbolic) + HEAD sha
- `git status --porcelain -uno` (tracked changes)
- unstaged diff (`git diff`)
- staged diff (`git diff --cached`)

It deliberately **excludes** `git show-ref` because linked worktrees share parent refs with main super — a legitimate ref advance during merge would trip the snapshot. Untracked files are excluded so the test's own `out` redirect doesn't pollute the snapshot.

### 12. Matrix coverage for state-sensitive commands

Commands whose behavior branches on combinations of state (currently `merge` and `remove`) get parametric matrix tests iterating 2^N combinations. Each iteration:

1. `mkfixture_local`
2. `subgrove new feat-x` + sanity-check feat branches were created
3. Apply per-iteration setup (commits via `commit_one`, dirty edits via inline `echo`)
4. `_verify_pre_state` (asserts setup correctness for all 6 locations)
5. Capture `snapshot_state` of relevant locations
6. Run the operation
7. Assert per outcome class (refuse / no-op / success)
8. `cleanup_fixture`

The matrix doesn't replace individual scenario tests — those remain as readable documentation. The matrix adds exhaustive state-tuple coverage.

### 13. Symlink-based subgrove invocation

Tests invoke subgrove via a symlink at `$FIXTURE_SUPER/subgrove` pointing at `$SUBGROVE_REPO_ROOT/subgrove`. The script's `SCRIPT_DIR = "$(cd "$(dirname "$0")" && pwd)"` resolves to `$FIXTURE_SUPER`, so subgrove operates on the fixture's git, never on the surrounding subgrove repo. The `new_from_other_cwd` scenario verifies this resolution holds when invoked from an arbitrary cwd.

### 14. Iterative review

The suite was developed through ~7 rounds of "find new weakness → apply." Each round caught a different bug class. When adding tests for a new subgrove feature, expect 2–3 rounds of review to surface:

- Round 1–2: missing assertions; weak vs strong pinning of state.
- Round 3–4: setup bugs in your own tests; symmetry gaps (sm-a tested but not sm-b).
- Round 5–6: narration regressions; specific err-text not pinned; dead helpers.
- Round 7+: hypothetical edge cases (diminishing returns).

Real bugs surfaced across rounds so far: one subgrove bug (cmd_remove not preserving submodule branches — round 2, caught a doc/code discrepancy), one self-inflicted test bug (round 3, my own incorrect `merge_nothing` skip-list assertion).

## Per-tier case lists

Every scenario, its setup, what it asserts, and which design invariant it guards:

- [testing-local.md](testing-local.md) — with-submodule local scenarios (70 single-case + 96 parametric matrix iterations).
- [testing-local-no-sm.md](testing-local-no-sm.md) — no-submodule local tier.
- [testing-remote.md](testing-remote.md) — with-submodule remote tier (19 single-case + 24 parametric matrix iterations against real GitHub).
- [testing-remote-no-sm.md](testing-remote-no-sm.md) — no-submodule remote tier (48 single-case + 8 parametric matrix iterations against real GitHub).
