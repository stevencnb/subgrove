# Local tests — no-submodule tier

Tests under `tests/local-no-sm/`. Run as part of `./tests/run.sh --local-only` (which discovers both `tests/local/` and `tests/local-no-sm/`).

The fixture is a single `git init super/` with no `.gitmodules` and no sibling submodule repos. Subgrove on this fixture is being exercised on the "user is running it on a superproject before any submodules have been added" scenario, and on the broader question of "what happens when a submodule-specific parameter is passed but there are no submodules?"

Companion to [testing-local.md](testing-local.md), which covers the with-submodule fixture.

## Why this tier exists

The with-submodule tier (`tests/local/`) tests subgrove on a fixture that always has at least one submodule. It cannot catch:

- Crashes or undefined behavior when `.gitmodules` is absent.
- Submodule-phase info lines that fire unconditionally (claiming N submodule(s) when N is 0).
- Submodule-specific parameters (`touch=<sm>`, `BUILD_CHAIN=(<sm>)`, `merge push=true`) misbehaving when there are no submodules to operate on.
- Leakage of per-submodule machinery (e.g. the `_update_sync` sentinel ref) into the parent's ref namespace.

A real user has a "no submodules yet" liminal state — between `git init` and the first `git submodule add`. CLAUDE.md is explicit that subgrove is a tool for *superprojects with submodules*, but it must not crash on a no-submodule super; it must degrade gracefully.

## The fixture

`mkfixture_local_no_sm` (see `tests/lib/fixture_local_no_sm.sh`) builds:

```
tests/run/<ts>-no-sm-<name>/
└── super/                       git repo, two commits on main
    ├── .gitignore               .worktree/
    ├── .subgroverc              BUILD_CHAIN=()  BUILD_CMD="true"  ...
    ├── .worktree/               empty dir (check-ignore workaround)
    ├── README
    └── subgrove → /path/to/subgrove-repo/subgrove
```

Notably absent: `.gitmodules`, sibling `sm-a/` / `sm-b/` source repos, any `origin` on the super (subgrove falls back to local refs and emits a `warn: parent fetch failed` line). Same super-no-origin shape as the with-submodule local fixture.

Lifecycle is identical to the with-submodule tier:

```bash
mkfixture_local_no_sm <name>     # builds fresh fixture, exports $FIXTURE_ROOT, $FIXTURE_SUPER
cd "$FIXTURE_SUPER"
./subgrove <command> >out 2>&1
# ... assertions ...
cleanup_fixture                  # rm -rf $FIXTURE_ROOT (only on success)
```

`cleanup_fixture` is the LAST statement of each scenario. Failures under `set -eo pipefail` exit before it runs, leaving the fixture on disk for inspection.

## Design invariants this tier guards

1. **Subgrove degrades gracefully when `.gitmodules` is absent.** `list_all_submodules` returns empty; every consumer (init loop, branching loop, build chain, merge phases, update loop) iterates the empty list and no-ops. No phase errors trying to read a missing `.gitmodules`.

2. **Submodule-phase info lines stay honest in the zero-submodule case.** `Discovering touched submodules` prints `touched: (none)`; `Filtering to modules with new commits` prints `will merge submodules: (none)`; the merge summary prints `Submodules merged: (none)`; `update` prints `Updated 0 submodule main(s); 0 skipped`. The "Branching N submodule(s)" line and the "Preserved N submodule feat branch(es)" line do not fire when N is 0. The narration tells the truth about what subgrove actually did.

3. **Submodule-relevant parameters never crash on a no-sm super.** `touch=<sm-name>`, multi-name `touch=` lists, `BUILD_CHAIN=(<sm>)`, `merge push=true` — every parameter that exists *because of* submodules either errs cleanly (with rollback, where applicable) or produces a defined no-op. The tier pins each parameter's behavior so a future change can't silently break the degenerate case.

4. **Parent-only flows are isolated from submodule machinery.** Merge's two-phase split reduces to a single parent FF; remove's submodule-branch-preservation step no-ops; update's per-submodule sentinel is never created in the parent's refs. Negative-asserts (e.g. `Moving main forward in main worktree's submodules` absent on no-sm merge; `Propagating new main to peer worktrees` absent; `refs/heads/_update_sync` absent in main super after update) lock this in.

## Implementation notes

Three things to know before evolving this tier:

**`Submodule branching skipped (touch=none)` fires even on the default `touch=all` path.** When there are no submodules, `resolve_touch_list all` → `list_all_submodules` → empty list, and the script's narration says "skipped (touch=none)" regardless of what the user actually typed. Tests pin the current behavior; the message text is mildly misleading but distinguishing the two cases is a script change, not a test change. If subgrove later distinguishes "user wrote `none`" from "no submodules at all", the relevant assertions get updated alongside.

**`merge push=true` on a no-`origin` super leaves a defined half-state.** Parent main is advanced LOCALLY in Phase 1, then the push attempt fails with git's own non-zero exit (`fatal: 'origin' does not appear...`). The local advance is **preserved** on disk. The test pins this half-state rather than asserting a rollback — push-after-merge is a separate phase and rolling it back would require a different design.

**`BUILD_CHAIN=(sm-a)` on a no-sm super leaks the shell's `cd: No such file or directory` error** rather than emitting a clean "no such submodule" diagnostic. Rollback still fires correctly (the worktree dir + parent branch are cleaned up), so the test pins on rollback behavior rather than on the exact error text. Pretty-printing this error is a possible follow-up; out of scope for the tier itself.

## `test_new.sh` (15)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden default | `new feat-x` (no touch=, no BUILD_CHAIN) | worktree dir + parent feat branch; parent base SHA == local main; `>>> Initialising submodules` info line fires; **`Branching N submodule(s)` line ABSENT** (N==0 path); `>>> Submodule branching skipped (touch=none)` fires; `>>> No BUILD_CHAIN configured` fires; `warn: parent fetch failed` fires (no origin) | Invariants 1, 2. |
| `touch=none` explicit | `new feat-z touch=none` | parent feat created; same `Submodule branching skipped (touch=none)` message as default | Empty-set path and explicit-none path emit identical narration today (see implementation notes). |
| `touch=` empty value | `new feat-emptyt touch=` | succeeds; same submodule-skipped message | Empty value is treated as `none`. Invariant 3. |
| `touch=sm-a` (no such sm) | `new feat-bad touch=sm-a` | err: "no such submodule path"; **rollback fires** (worktree dir + parent branch gone); `>>> Branching 1 submodule(s)` info line precedes the error | The submodule-path-existence check fires; rollback trap cleans up the half-built worktree. Invariant 3. |
| `touch=sm-a,sm-b` multi | `new feat-multi touch=sm-a,sm-b` | err: "no such submodule path"; rollback; `>>> Branching 2 submodule(s)` info line precedes | Loop errors on the first missing path; doesn't try to power through. Invariant 3. |
| `build=false` (BUILD_CHAIN empty) | default `.subgroverc`; `new feat-bf build=false` | succeeds; `>>> No BUILD_CHAIN configured` fires; **`Build chain skipped` line ABSENT** | The "Build chain skipped" branch only fires when BUILD_CHAIN is non-empty. Invariant 2. |
| `build=true` (BUILD_CHAIN empty) | default `.subgroverc`; `new feat-bt build=true` | same as `build=false` case | Symmetry with above. |
| `build=invalid` (BUILD_CHAIN empty) | default `.subgroverc`; `new feat-bi build=oops` | succeeds (no `build=` validation when BUILD_CHAIN is empty); same `No BUILD_CHAIN configured` message | Pins observed behavior. If subgrove later validates `build=` upfront, this test changes. Invariant 3. |
| `BUILD_CHAIN=(sm-a)` rollback | `.subgroverc` sets `BUILD_CHAIN=(sm-a)`; `new feat-bc` | err (the shell `cd: No such file or directory` leaks; the test pins on `[Nn]o such file or directory` so a regression where rollback fires from a different failure mode is visible); rollback fires (worktree dir + parent branch gone); `>>> Running build chain` appears in output | Rollback works for build-phase failures, not just submodule-init failures. Invariant 3 (the no-sm equivalent of `local/`'s "rollback on submodule-init failure"). |
| Pre-existing worktree dir | `mkdir .worktree/feat-collide`; `new feat-collide` | err; no parent branch; pre-existing dir contents untouched | Dir-collision refusal is independent of submodules. |
| Pre-existing parent branch | `git branch feat/feat-pre main`; `new feat-pre` | err; no worktree dir; pre-existing branch SHA unchanged | Branch-collision refusal is independent of submodules. |
| Linked-worktree refusal | `new feat-host`; invoke `new` from inside `.worktree/feat-host/` | err mentioning "main worktree" | `assert_main_worktree` is independent of submodules. |
| `.worktree/` not gitignored | empty `.gitignore`; `new feat-ni` | err mentioning "not gitignored" | `assert_worktrees_ignored` is independent of submodules. |
| Invalid names | `.dotleading`, `-dashleading`, `bad/name`, `bad name`, empty | err on each (with the specific message per kind); no worktree dirs or feat branches left behind | `validate_name` is independent of submodules. |
| Dirty main super doesn't block | dirty parent; `new feat-x` | new succeeds; dirty edit preserved | `cmd_new` doesn't `require_clean`. Replicated here to catch a regression that would only fire when no submodules are present (e.g., if a future check inspected `.gitmodules` presence as a prerequisite). |

## `test_remove.sh` (6)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden | `new feat-x`; `remove feat-x` | worktree gone; parent feat branch retained; **`Preserved N submodule feat branch(es)` line ABSENT**; "branches retained" still in the remove-message (refers to parent) | The submodule-branch-preservation step is a no-op (nothing to preserve); its info line must not fire. Invariants 2, 4. |
| Dirty parent | edit in `.worktree/feat-x/`; `remove` | err: "uncommitted changes"; worktree intact; state snapshot preserved | `require_clean` on the parent. |
| `-f` overrides dirty parent | dirty + `-f` | worktree gone | Short force flag. |
| `--force` alias | dirty + `--force` | worktree gone | Long alias. |
| `force=true` alias | dirty + `force=true` | worktree gone | Key=value alias. |
| Nonexistent name | `remove never-existed` | err | Doesn't silently no-op. |

## `test_merge.sh` (7)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden (parent-only commits) | parent commit in feat-x; `merge feat-x` | parent main FF'd in main super; `touched: (none)`; `will merge submodules: (none)`; `Fast-forwarding parent main` fires; `Push skipped (push=true to enable)` fires (default is push=false); summary `Submodules merged: (none)`, `Parent merged: true`, `Pushed: false`; worktree retained (state snapshot preserved); **`Moving main forward in main worktree's submodules` line ABSENT** | Phase 0 filters to empty; Phase 1 advances parent only; Phase 2's submodule loop iterates empty. Default push=false exercises the explicit-false code path (no separate `push=false` test). Invariants 2, 4. |
| Nothing to merge | `new feat-x` (no commits); `merge` | `>>> Nothing to merge`; refs unchanged; main super + worktree state snapshots preserved; summary `Parent merged: false` | Phase-0 filter short-circuits without mutating anything. |
| Dirty parent (dst) refused | parent commit on feat-x + dirty edit in main super; `merge` | err: "main worktree (parent, dst) has uncommitted"; state snapshot preserved; **`Fast-forwarding parent main` line ABSENT** (Phase 1 didn't run) | `require_clean` on the dst parent fires before merge mutation. |
| Non-FF parent refused | parent commit on feat-x + direct commit on main super; `merge` | err: "parent main is not ancestor of feat/feat-x (non-FF)"; main SHA unchanged; main super state snapshot preserved; **`Fast-forwarding parent main` line ABSENT** | Parent FF check fires; no half-state. |
| `push=true` (no origin) | parent commit on feat-x; `merge feat-x push=true` | (a) parent main is **advanced LOCALLY first** (`Fast-forwarding parent main` fires); (b) push fails (`Pushing updated main branches to origin` + `'origin' does not appear`); (c) parent main re-read after the failed call is still at the feat tip — **the local advance is preserved on disk** | Pins the documented half-state distinctly across (a)/(b)/(c). Push-after-merge is a separate phase, not a roll-back-able one. See implementation notes. Invariant 3. |
| Nonexistent branch | `merge never-existed` | err | Doesn't try to merge a non-existent ref. |
| Submodule-phase info lines absent (two-peer) | `new feat-x` + `new feat-y`; parent commit on feat-x; `merge feat-x` | **`Propagating new main to peer worktrees` line ABSENT**; **`Moving main forward in main worktree's submodules` line ABSENT**; parent merge still succeeds (`Parent merged: true`) | Submodule-specific narration must not fire when there are no submodules to move or propagate. Invariant 4. |

## `test_update.sh` (5)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Degenerate update | `new feat-y`; `update feat-y` | exit 0; `warn: parent fetch failed` (no origin); `FF-updating peer worktree 'feat-y' submodule mains from origin/main` fires; `>>> Updated 0 submodule main(s); 0 skipped`; rebase-guidance block still printed | The per-submodule loop iterates the empty list; summary reflects the zero-case truthfully. Invariants 1, 2. |
| Sentinel ref never created | `new feat-y`; `update feat-y` | `refs/heads/_update_sync`, `refs/_update_sync`, AND `refs/remotes/origin/_update_sync` all absent in main super | Sentinel lives in per-submodule git dirs; with zero submodules, no sentinel anywhere in any of the parent's ref namespaces. Invariant 4. |
| Pre-existing `_update_sync` in parent untouched | `new feat-y`; `git update-ref refs/heads/_update_sync HEAD`; `update feat-y` | update succeeds; parent's `_update_sync` ref still resolves to the same SHA afterward | Sentinel manipulation is scoped to per-submodule git dirs; an unrelated parent-level ref with the same name must not be clobbered. Invariant 4. |
| Nonexistent name | `update never-existed` | err: "does not exist" | Doesn't silently no-op. |
| Doesn't require clean state | dirty edit in `.worktree/feat-y/`; `update feat-y` | succeeds (ref-only operation); dirty edit preserved | `cmd_update` is ref-only — same as the with-submodule tier. |

## `test_list.sh` (8)

The dispatcher and `list` are independent of submodule state. The tier mirrors the with-submodule tier's coverage on the no-sm fixture to catch any future code path that branches on `list_all_submodules` from the dispatcher (e.g., help text that enumerates submodules).

| Scenario | Asserts |
|---|---|
| `list` after `new feat-a feat-b` | output contains `[feat/feat-a]` and `[feat/feat-b]` |
| `ls` alias | same effect as `list` |
| `subgrove` (no args) | prints usage; exit 0 |
| `subgrove help` | prints usage; exit 0 |
| `subgrove bogus-cmd` | exit non-zero; prints usage |
| `rm` alias | same effect as `remove` |
| `subgrove -h` | prints usage; exit 0 |
| `subgrove --help` | prints usage; exit 0 |

## `test_linked_worktree.sh` (3)

Each of `merge`, `remove`, `update` invoked from inside `.worktree/feat-host/` must err with the "main worktree" message. Same symlink trick as the with-submodule tier's `test_linked_worktree`; the state-preservation snapshot covers only the parent (no sibling sm-a / sm-b).

| Scenario | Asserts | Guards |
|---|---|---|
| `merge` from linked worktree | err mentioning "currently in a linked worktree"; parent state preserved | `cmd_merge`'s `assert_main_worktree` still fires on no-sm super. |
| `remove` from linked worktree | same | `cmd_remove`'s `assert_main_worktree` still fires. |
| `update` from linked worktree | same | `cmd_update`'s `assert_main_worktree` still fires. |

## `test_init.sh` (1)

| Scenario | Asserts | Guards |
|---|---|---|
| Fresh init on a flat super | `--defaults` prints "No submodules detected", writes `.subgroverc` with an empty `BUILD_CHAIN`, gitignores + creates `.worktree/`, then `new` works | The wizard's submodule-detection degrades gracefully when `.gitmodules` is absent. |

## Scenarios intentionally NOT in this tier

Per-submodule scenarios that have no meaningful analog without submodules:

- `touch=sm-a` happy path; rollback on submodule-init failure.
- Partial merge (one submodule unchanged); non-FF submodule (two-phase invariant); peer propagation success; peer's main checked out or diverged.
- Sentinel cleanup success; "no `refs/remotes/origin/main` → skip" submodule path.
- Dirty UN-touched submodule on `remove`; implicit-dirty `M <submodule>`.

The matrix tests (`test_merge_matrix.sh`, `test_remove_matrix.sh`) are also **not** ported. Their state combinations are dominated by per-submodule dimensions; without submodules the remaining bits collapse to a handful already covered by the single-case tests above.

A no-submodule `COPY_TO_NEW_WORKTREE` test is also omitted. The COPY path is identical with or without submodules; the with-submodule tier already pins its happy and missing-item behavior.

## Cross-reference

- Fixture builder: `tests/lib/fixture_local_no_sm.sh` (`mkfixture_local_no_sm` exports `FIXTURE_ROOT`, `FIXTURE_SUPER`)
- Assertion helpers: `tests/lib/assert.sh`
- Mutator helper: `tests/lib/mutators.sh` (`commit_one`)
- With-submodule companion tier: [testing-local.md](testing-local.md)
- Top-level overview: [testing.md](testing.md)
