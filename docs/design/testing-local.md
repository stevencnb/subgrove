# Local tests (with-submodule tier)

Tests under `tests/local/`. Run with `./tests/run.sh --local-only`, which also discovers the parallel no-submodule tier under `tests/local-no-sm/` — see [testing-local-no-sm.md](testing-local-no-sm.md) for that tier's design, scenarios, and invariants. Each scenario builds a fresh fixture (`super/` + `sm-a/` + `sm-b/`, all via `git init`) under `tests/run/<timestamp>-<name>/` and invokes subgrove through a symlink to the script under test.

The local fixture has **no `origin`** on the superproject (it was `git init`'d in place, never cloned), matching the "user hasn't configured a remote" scenario. The submodules under `super/` do have `file://` origins to their sibling source repos (set automatically by `git submodule add`) — subgrove's submodule-level fetch paths can exercise against those.

166 scenarios across eight files (70 single-case scenarios + 96 parametric matrix iterations).

## Test lifecycle

Each scenario follows the same shape:

```bash
mkfixture_local <name>          # build a fresh standalone fixture
cd "$FIXTURE_SUPER"
./subgrove <command> >out 2>&1  # invoke the script via the fixture's symlink
# ... assertions ...
cleanup_fixture                 # rm -rf $FIXTURE_ROOT (only on success)
```

`mkfixture_local` builds, in order:

1. `mkdir -p tests/run/<timestamp>-<pid>-<random>-<name>/`
2. `git init sm-a` + set HEAD to `main` + commit README → standalone submodule source
3. `git init sm-b` + same
4. `git init super` + set HEAD to `main` + commit README
5. `git submodule add file://.../sm-a sm-a` and same for `sm-b` (clones each sibling into `super/sm-X`, records URL in `.gitmodules`); commit
6. `git checkout -B main` in each `super/sm-X` to lock in `main` as the checked-out branch (some git versions leave it detached after `submodule add`)
7. Write `.gitignore` (`.worktree/`) and `.subgroverc`; commit
8. `mkdir .worktree` so subgrove's `git check-ignore -q .worktree` matches the trailing-slash pattern (see the `mkdir .worktree` comment in `fixture_local.sh`)
9. Symlink `subgrove` → `$SUBGROVE_REPO_ROOT/subgrove`
10. Export `FIXTURE_ROOT` and `FIXTURE_SUPER`

Resulting layout:

```
tests/run/<ts>-<name>/
├── sm-a/             git repo, 1 commit on main
├── sm-b/             git repo, 1 commit on main
└── super/            git repo with both submodules wired in via file://
    ├── .gitmodules
    ├── .gitignore
    ├── .subgroverc
    ├── .worktree/    (empty)
    ├── sm-a/         clone of ../sm-a; origin = file://.../sm-a
    ├── sm-b/         clone of ../sm-b; origin = file://.../sm-b
    └── subgrove → /path/to/subgrove-repo/subgrove
```

Then the test does its work (`cd $FIXTURE_SUPER`, `./subgrove …`, assertions). All git operations are scoped to the fixture: subgrove discovers the superproject from the current directory (`git rev-parse --show-toplevel`), which is `$FIXTURE_SUPER` because the test `cd`s there, so subgrove operates on the fixture's git, never on the surrounding subgrove repo.

`cleanup_fixture` is the LAST statement of each scenario. Because every test runs under `set -eo pipefail`, an assertion failure exits before `cleanup_fixture` runs — the fixture stays on disk and the runner prints the path so the developer can `cd` in and inspect. Passing scenarios are removed.

Each scenario builds its own fresh fixture. No state carries between scenarios; one scenario's success or failure doesn't depend on any other's. `tests/run.sh --clean` wipes the entire `tests/run/` directory (including any kept fixtures from past failures).

## `test_new.sh` (18)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden (`touch=all` default) | clean fixture | `.worktree/feat-x/` exists; parent + both submodules on `feat/feat-x`; parent base SHA == local `main` | The happy-path branching contract. |
| `touch=sm-a` subset | `new feat-y touch=sm-a` | sm-a on `feat/feat-y`; sm-b has no such branch | The `touch=<list>` parser keeps the selection narrow. |
| `touch=none` | `new feat-z touch=none` | parent on `feat/feat-z`; neither submodule has the branch | The all/none/list trichotomy works at the empty extreme. |
| `build=false` skips BUILD_CHAIN | `BUILD_CHAIN=(sm-a)`, `BUILD_CMD="touch .built"`, then `new ... build=false` | `.built` absent in worktree's sm-a; "Build chain skipped" in output | The skip-build escape hatch. |
| Build runs by default | same BUILD_CHAIN, no `build=false` | `.built` exists in worktree's sm-a | The default-enabled build chain actually invokes BUILD_CMD in the right cwd. |
| Pre-existing worktree dir | `mkdir .worktree/feat-collide` before `new` | err with "already exists"; no parent branch | A duplicate `new` doesn't trample existing state. |
| Pre-existing parent branch | `git branch feat/feat-pre main` before `new` | err with "already exists"; no worktree dir | Same check, ref side. |
| Linked-worktree refusal | symlink subgrove inside `.worktree/feat-host/`, invoke from there | err mentioning "main worktree" | `assert_main_worktree` fires when invoked through a path that resolves inside a linked worktree. |
| Missing `.worktree/` in `.gitignore` | empty `.gitignore` in fixture super | err mentioning "not gitignored" | `assert_worktrees_ignored` actually fires; the error message points at the remediation. |
| Invalid names | `.dotleading`, `-dashleading`, `spaces in name`, empty, `ba/d` | err on each | `validate_name` covers the leading-char and char-class constraints. |
| Rollback on submodule-init failure | rename sibling `sm-b/` so its `file://` URL no longer resolves, then `new` | worktree dir gone; parent branch gone | The `EXIT`/`INT`/`TERM` trap from `lifecycle.md` actually cleans up a half-built worktree so a retry of the same name doesn't trip on residue. |
| `COPY_TO_NEW_WORKTREE` happy path | configure `COPY_TO_NEW_WORKTREE=(.copy-me .copy-dir)`; create those items in main super; then `new` | both items present in the new worktree | The copy-into-new-worktree step in `cmd_new` runs for files and dirs. |
| `COPY_TO_NEW_WORKTREE` missing item | configure `COPY_TO_NEW_WORKTREE=(.nonexistent-file)`; then `new` | new succeeds; the missing item is absent in the worktree | The `[[ -e ... ]]` guard silently skips items that don't exist in main super (per the commented contract). |
| `touch=` with nonexistent submodule | `new feat-bad-touch touch=nonexistent` | err mentioning "no such submodule path"; worktree dir gone; parent branch gone | The `[[ -d "$sm_path" ]] || err` guard fires and the rollback trap still cleans up the half-built worktree. |
| BUILD_CHAIN with multiple modules | `BUILD_CHAIN=(sm-a sm-b)`, `BUILD_CMD="touch .built"`; then `new` | `.built` exists in both worktree submodules | The BUILD_CHAIN loop runs each module's BUILD_CMD; order matters but every entry runs. |
| Dirty main super doesn't block | dirty parent + both submodules in main super before `new` | new succeeds; the new worktree's HEAD is on `feat/feat-x`; dirty edits preserved | cmd_new doesn't `require_clean` — main super state is irrelevant. |
| Discovery keys off the CWD, not the script | invoke the script (absolute path) from a temp dir **outside any git repo** | refuses with "not in a git repo"; the script's own repo is untouched (no `.worktree/feat-x`) | Post-refactor contract: subgrove resolves the superproject via `git rev-parse --show-toplevel` from the CWD, not `dirname $0`. The positive case (script on PATH, CWD inside the repo) is in `test_path_invocation.sh`. |
| Rollback keeps a committed branch | `BUILD_CHAIN=(sm-a)` + `BUILD_CMD` that commits on the parent worktree then `false`; `new feat-x` | new fails; worktree dir gone; **`feat/feat-x` retained** at the wip commit (1 ahead of `main`); "advanced past its creation point" warn | `_rollback_new` skips `branch -D` when the branch moved past its creation SHA (`ROLLBACK_BR_SHA`), so build-chain commits onto the parent aren't lost. |

## `test_remove.sh` (14)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden | `new feat-x` then `remove feat-x` | worktree gone; parent feat branch retained; **submodule feat branches preserved** in main-worktree submodule git dirs at the same SHAs | The full lifecycle.md "branches retained" contract — parent (shared refs) AND submodules (cmd_remove now fetches refs into `.git/modules/<sm>/` before prune wipes the per-worktree submodule git dirs). |
| Dirty parent worktree | edit a tracked file in `.worktree/feat-x/` | err; worktree intact | `require_clean` catches dirty parent. |
| Dirty touched submodule | edit in `.worktree/feat-x/sm-a/` | err; worktree intact | `require_clean` covers touched submodules. |
| Dirty UN-touched submodule | `new feat-x touch=sm-a` (sm-b not branched but still initialised), edit in `.worktree/feat-x/sm-b/` | err; worktree intact | The "every initialised submodule" rule from `lifecycle.md` — un-branched-but-edited submodules must not be silently wiped by `rm -rf`. |
| `-f` overrides dirty | dirty parent + `-f` | worktree gone | The force escape hatch. |
| `--force` alias | dirty parent + `--force` | worktree gone | Long-flag alias for `-f`. |
| `force=true` alias | dirty parent + `force=true` | worktree gone | Key=value alias. |
| Nonexistent name | `remove never-existed` | err | Doesn't silently no-op when the worktree isn't there. |
| Remove one of many | `new feat-a` + `new feat-b`; remove only `feat-a` | feat-a's worktree gone; feat-b's worktree intact; both branches retained | `git worktree prune` and `rm -rf` on one worktree don't disturb siblings. |
| Re-create same name after remove | `new feat-x` → `remove feat-x` → `new feat-x` | second `new` errs with "already exists"; after `git branch -D feat/feat-x`, the third `new` succeeds; recreated submodules' HEADs match the original recorded gitlink SHAs | Locks in the documented "branches retained after remove" behavior (lifecycle.md). |
| Selective preservation (`touch=sm-a` + remove) | `new feat-y touch=sm-a` then `remove feat-y` | sm-a's feat preserved; sm-b has no preserved branch (never had one) | The preservation loop's per-submodule filter — only submodules with the feat branch in the worktree get fetched out. |
| Preserved branch reflects advanced state | `new feat-x` + commit on `feat-x/sm-a` + `remove -f feat-x` | preserved `sm-a feat/feat-x` is at the advanced commit, not the original recorded gitlink SHA | Locks in that the preservation fetch transfers the user's actual work — not a stale snapshot of the gitlink SHA. |
| No-op preservation (`touch=none` + remove) | `new feat-z touch=none` then `remove feat-z` | parent feat retained; no submodule feat branches preserved (nothing to preserve) | Preservation loop silently skips when no submodule had the feat branch. |
| Preservation-fetch failure aborts (even `-f`) | commit on worktree's `sm-a` feat; dirty worktree; create a `feat` branch in main super's `sm-a` (D/F conflict vs `refs/heads/feat/feat-x`); `remove feat-x -f` | remove aborts (non-zero); err "sm-a: failed to preserve"; worktree intact; worktree's `sm-a feat/feat-x` preserved; "Removing worktree" absent | `cmd_remove` errs before `rm -rf` on a failed preservation fetch; `-f` bypasses the cleanliness gate but never this preservation gate. |

## `test_merge.sh` (16)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden | commits in parent + each submodule on `feat-x` | parent + each touched sm `main` FF'd in main worktree; worktree retained | Happy-path merge across all touched modules. |
| Nothing to merge | `new feat-y` (no commits) then `merge feat-y` | "Nothing to merge" in output; no refs moved | Phase-0 filter short-circuits when feat tip == main tip in every module. |
| Partial — one submodule unchanged | commit only in sm-a | sm-a in `needs_merge`; sm-b in `skipped`; sm-b main unchanged | The filter splits modules correctly when only some have feat commits. |
| Dirty parent (dst) refused | edit in main worktree's parent before merge | err in validation; **no submodule mains advanced** | The two-phase split means a dirty-parent failure doesn't leave half-moved submodules behind. |
| Dirty submodule (dst, sm-a) refused | edit in main worktree's sm-a | err; all 6 locations preserved; main super's submodules have NO `feat/feat-x` ref (Phase 1 didn't run) | Same on the submodule side. |
| Dirty submodule (dst, sm-b) refused | edit in main worktree's sm-b | err; all 6 locations preserved; main super's submodules have NO `feat/feat-x` ref | Symmetry with sm-a — catches a hardcoded-submodule-arg bug in `require_clean`'s loop. |
| Non-FF parent refused | direct commit on main worktree's parent main, then merge feat-x | err; main unchanged | The parent FF check fires before any submodule mutation. |
| **Non-FF submodule (two-phase invariant)** | feat-x has commits on sm-a AND sm-b; diverge sm-b's main in main worktree via detached-HEAD + `update-ref` (so parent stays clean and Phase 0 doesn't fire) | err in Phase 1; **sm-a main UNCHANGED in main worktree** | THE invariant from `merge.md` — a non-FF on submodule N+1 must NOT leave submodules 1..N already moved. This is the test that distinguishes the current two-phase implementation from the older one-pass version. |
| Peer propagation (clean peer) | `new feat-x` + `new feat-y`; commit on feat-x's sm-a; merge feat-x | feat-y's sm-a main matches the new sm-a main | Step 8 of `merge.md` — peer worktrees see the new submodule main after merge. |
| Peer with main checked out | feat-y/sm-a checked out on `main` (not on a feat branch) | propagation skipped; warn "main checked out"; peer main unchanged | The peer-propagation refusal when git would otherwise update a checked-out branch. |
| Peer's main diverged | forge a divergent commit on feat-y/sm-a's main via `commit-tree` + `update-ref` | propagation skipped; warn "diverged" | The non-`+` refspec refuses non-FF; the script's HEAD-inspection distinguishes "diverged" from "main checked out" — this test pins the diverged branch of that distinction. |
| Nonexistent branch | `merge never-existed` | err | Doesn't try to merge a non-existent ref. |
| Parent-only commit (`touch=none`) | `new feat-x touch=none` + parent-only commit + merge | parent main FF'd; submodules unchanged; summary shows "Submodules merged: (none)" + "Parent merged: true" | Exercises Phase-1-parent-FF-alone-with-empty-needs_merge path; the submodule loops on both phases don't iterate. |
| Dirty source parent refused | edit a tracked file in `.worktree/feat-x/` (the feature worktree's parent) | err; main worktree's submodule mains unchanged | The dirty-check covers the SRC side too, not just DST (parent worktree being merged FROM must also be clean). |
| Dirty source submodule refused | edit a tracked file in `.worktree/feat-x/sm-a/` | err; main worktree's sm-a main unchanged | The dirty-check covers the SRC submodule on every touched submodule. |
| Multi-peer propagation | `new feat-x` + `new feat-y` + `new feat-z`; commit on feat-x/sm-a; merge feat-x | sm-a's main in BOTH feat-y AND feat-z matches the new sm-a main | The peer-propagation loop iterates every peer worktree, not just the first one. |

## `test_update.sh` (10)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Happy path | `commit_one` directly in sibling `sm-a/` (no push needed); `update feat-y` | feat-y/sm-a main == new sm-a SHA | The full `_update_sync` sentinel flow from `update.md` — fetch into main super's submodule, stage `origin/main` under a transient head ref, fetch sentinel into peer's main, delete sentinel. |
| Sentinel cleanup on success | run update on a clean fixture | `refs/heads/_update_sync` absent in both main super submodules afterward | No leftover sentinel ref after a successful run. |
| Sentinel cleanup pre-existing | manually `update-ref refs/heads/_update_sync` before running update | update succeeds; ref absent after | The defensive pre-clean handles a sentinel left over from a prior interrupted run. |
| Peer with main checked out | feat-y/sm-a on `main`, sibling sm-a has a new commit | skipped with warn "main checked out"; peer main unchanged | The skip-on-checked-out-main path; matches `merge`'s analogous case. |
| Peer's main diverged | forge divergent commit on feat-y/sm-a's main + sibling sm-a has new commit | skipped with warn "diverged" | The non-FF refusal in `cmd_update`. |
| No `refs/remotes/origin/main` → skipped | `git remote remove origin` on main super's submodules, then update | warn "no refs/remotes/origin/main" | The "submodule has no origin/main to read from" skip path. |
| Doesn't require clean state | edit in `.worktree/feat-y/sm-a/`, then update | succeeds (ref-only) | The invariant from `implementation-notes.md` — `cmd_update` is ref-only and must not require clean working trees. |
| Nonexistent name | `update never-existed` | err | Doesn't silently no-op. |
| Multiple submodules update in one run | commit in BOTH sibling sm-a and sm-b; then update feat-y | both feat-y submodule mains advance to their respective new SHAs | The per-submodule loop in `cmd_update` handles every submodule independently; one update call can move multiple peer submodules. |
| Dirty main super doesn't block | dirty parent + both submodules in main super; commit in sibling sm-a; then update feat-y | update succeeds; feat-y's sm-a main advances to the new SHA | cmd_update is ref-only and doesn't `require_clean` — main super dirty state is irrelevant. |
| Pre-existing `_update_sync` is a USER branch | forge `_update_sync` in main super's `sm-a` at a commit unreachable from `origin/main`; advance `sm-b`'s origin; `update feat-y` | `sm-a` skipped ("not a stale sentinel" warn) and its `_update_sync` preserved at the forged SHA; `sm-b`'s peer main FF'd; "Updated 1 …; 1 skipped" | The pre-clean refuses to delete a same-named ref not reachable from `origin/main` (a stale sentinel always is); the run continues past the skip. |

## `test_linked_worktree.sh` (3)

Each subgrove subcommand other than `new` (which is already covered by `test_new.sh::new_linked`) must refuse with the "main worktree" error when invoked from inside a linked worktree. Same symlink trick: drop a `subgrove` symlink inside `.worktree/feat-host/`, `cd` in, invoke the subcommand.

| Scenario | Asserts | Guards |
|---|---|---|
| `merge` from linked worktree | err mentioning "main worktree" | `cmd_merge`'s `assert_main_worktree` call still fires. |
| `remove` from linked worktree | err mentioning "main worktree" | `cmd_remove`'s `assert_main_worktree` call still fires. |
| `update` from linked worktree | err mentioning "main worktree" | `cmd_update`'s `assert_main_worktree` call still fires. |

A future refactor that drops the `assert_main_worktree` call from one of these commands would silently break that command's safety guarantee — without these explicit per-command tests, only `test_new` would still catch the function-level removal.

## `test_list.sh` and dispatcher (8)

| Scenario | Asserts | Guards |
|---|---|---|
| `list` after `new feat-a feat-b` | output contains both worktree paths | `cmd_list` reports every worktree. |
| `ls` alias | same effect as `list` | The short alias works. |
| `subgrove` with no args | prints usage; exit 0 | Default subcommand is `help`, exit code is success. |
| `subgrove help` | prints usage; exit 0 | Explicit `help` matches the default-no-args behavior. |
| `subgrove bogus-cmd` | exit non-zero | Unknown subcommands fall through to the catch-all and exit 1. |
| `rm` alias | same effect as `remove` | Short alias for `remove`. |
| `subgrove -h` | prints usage; exit 0 | Short `-h` flag dispatches to `usage`. |
| `subgrove --help` | prints usage; exit 0 | Long `--help` flag dispatches to `usage`. |

## `test_path_invocation.sh` (2)

Pins the runtime repo-discovery contract that makes a PATH/Homebrew install work — subgrove finds the superproject from the CWD, not from its own location. The script is symlinked into a temp dir **outside** this repo and invoked by bare name via `PATH`.

| Scenario | Asserts | Guards |
|---|---|---|
| Invoked via PATH from the main worktree root | `subgrove list` succeeds and names `$FIXTURE_SUPER` | `discover_root` resolves the repo from the CWD even when the script lives elsewhere. |
| Invoked via PATH from a subdirectory | `subgrove new` lands the worktree under `$FIXTURE_SUPER` | `git rev-parse --show-toplevel` works from any subdirectory, like git. |

## `test_version.sh` (2)

| Scenario | Asserts | Guards |
|---|---|---|
| `subgrove --version` from outside any repo | prints `subgrove X.Y.Z` | `--version` reports the version and does no repo discovery. |
| `subgrove version` subcommand | same output | The bare `version` alias matches `--version`. |

## `test_init.sh` (3)

Exercises the `init` wizard non-interactively (`--defaults` / piped stdin), since interactive prompts can't run in the suite.

| Scenario | Asserts | Guards |
|---|---|---|
| Fresh init (no prior `.subgroverc`) | writes `.subgroverc` (`BRANCH_PREFIX="feat/"`, empty `BUILD_CHAIN`), gitignores + creates `.worktree/`, then `new` works end-to-end | The bootstrap makes a never-configured repo usable. |
| Reconfigure | existing `.subgroverc` value preserved; old file backed up to `.subgroverc.bak` | Re-running loads current values as defaults and never silently clobbers. |
| Non-TTY stdin | `init </dev/null` doesn't hang; writes defaults | Piped/CI stdin falls back to defaults instead of blocking on a prompt. |

## `test_build.sh` (1)

| Scenario | Asserts | Guards |
|---|---|---|
| Build tooling (against a throwaway copy) | `build.sh` is idempotent; `build.sh --check` passes when in sync and fails after `lib/init.sh` is edited without a rebuild | The single-file build stays reproducible and drift is detectable. |

## Matrix sizing rationale

The two matrix test files (`test_merge_matrix.sh` and `test_remove_matrix.sh`) cover state combinations at sizes **64** and **32** respectively. The theoretical combinatorial maximum, if staged vs unstaged were treated as an independent per-location dimension, would be **6³ = 216** for merge and **3³ × 2 = 54** for remove. We deliberately don't expand to those.

Reason: subgrove's only place that distinguishes staged from unstaged is `require_clean`, which is `git diff --quiet && git diff --cached --quiet` — both branches fire the same dirty refusal. Subgrove never invokes `git stash` or anything else that handles the two cases differently. So the 216 expansion would add **152 distinct state tuples but zero new subgrove code paths**. Path coverage is already complete at 64 because the staging bit alternates across iterations and exercises both `git diff` checks.

Known small gap in the current matrix: `staged=$(( i & 1 ))`, which happens to be the same bit as `parent_uncommitted`. That correlation means "sm-a alone staged-dirty with clean parent" never appears in the 64 iterations. `require_clean` would still fire (it's path-equivalent), but the test doesn't pin that specific tuple. If subgrove ever gains a feature where staging matters functionally — `merge --autostash`, say — close the gap then by either decoupling the staging derivation from `p_unc` or adding targeted per-location staged-dirty scenarios.

## `test_merge_matrix.sh` (64 iterations)

A single parametric test file that iterates **every** combination of `(uncommitted, commits)` across parent + sm-a + sm-b in the feature worktree — `2^6 = 64` cases. Each iteration:

1. Builds a fresh fixture.
2. Sets up the state (commits via `commit_one`; dirty edits via append to README; staging variant alternates per iteration so both `git diff --quiet` and `git diff --cached --quiet` paths of `require_clean` get exercised across the matrix).
3. Runs `subgrove merge feat-x`.
4. Verifies the outcome:
   - **Any effective dirty** (explicit uncommitted edit, OR implicit `M <submodule>` from a submodule that committed without parent bumping) → merge refused, **no** mains advanced.
   - **All clean + no commits anywhere** → "Nothing to merge"; refs unchanged.
   - **All clean + some commits** → merge succeeds; parent main advances to feat tip; each submodule main advances iff that submodule had commits.

The prediction logic that folds "implicit parent dirty from unbumped submodule commits" into the dirty path lives in the test itself — see the `implicit_p_dirty` computation. This is what makes the matrix's 64 cases tractable instead of contradictory: every combination is now coherent against a known expected outcome.

Guards: the entire dirty-refusal contract of `cmd_merge` across every state combination; the Phase-0 filter ("Nothing to merge", needs_merge vs skipped); the Phase-2 advancement contract; and the two-phase invariant ("non-FF on one module doesn't move other modules' mains") as a consequence of the no-mains-advanced assertion in the refuse branch.

## `test_remove_matrix.sh` (32 iterations)

Parametric matrix for `subgrove remove`: `2^3` dirty combinations × 2 staged variants × 2 force-flag values = 32 iterations. Each iteration:

1. Builds a fresh fixture; `subgrove new feat-x`.
2. Dirties locations as configured (staged or unstaged).
3. Runs `subgrove remove feat-x` (with `-f` when force=1).
4. Verifies:
   - `force=1` → succeeds regardless of dirty state; worktree gone.
   - `force=0` + any dirty → refused; worktree intact.
   - `force=0` + all clean → succeeds; worktree gone.

Guards: the `require_clean` × force-flag matrix across every per-location dirty combination, for both staged and unstaged variants.

## Tests intentionally NOT in `tests/local/`

These paths can't be exercised against the local fixture (super has no `origin`); they live in [testing-remote.md](testing-remote.md):

- `merge push=true` happy path — super has no `origin` to push to. (A push=true error path is locally testable on the no-submodule fixture — see [testing-local-no-sm.md](testing-local-no-sm.md).)
- `new`'s fresh-base-from-origin — super has no `origin` to fetch from.

## Cross-reference

- The fixture builder: `tests/lib/fixture_local.sh` (`mkfixture_local` exports `FIXTURE_ROOT`, `FIXTURE_SUPER`)
- Assertion helpers: `tests/lib/assert.sh`
- Mutator helper: `tests/lib/mutators.sh` (`commit_one` only; tests inline divergence forging, checkout, and dirty-edit operations)
- Top-level overview: [testing.md](testing.md)

## Assertion strength

The dirty/refuse and successful-merge scenarios use precise, layered assertions instead of just "main SHA matches" or "worktree dir exists." The full helper set is in `tests/lib/assert.sh`.

The principles behind these patterns are documented in [testing.md § Test design principles](testing.md#test-design-principles). This section is the detailed-helper reference.

### State-snapshot helpers

- **`snapshot_state DIR`** captures `HEAD` (symbolic ref + SHA), `git status --porcelain -uno` (tracked changes — untracked files like the test's `out` redirect are intentionally excluded), unstaged diff, and staged diff. Pair with `assert_state_eq DIR EXPECTED` across an operation to verify a location wasn't touched. Used on **every refuse path** (all 6 locations preserved), on **"Nothing to merge" paths**, and on the **worktree side of successful merges**.
  - Deliberately excludes `git show-ref`: linked worktrees share the parent repo's refs with main super, so `refs/heads/main` can legitimately change under a worktree's feet when main super advances during merge. The captured fields are local to the working dir.

### Per-repo expected-state helpers

These verify the **explicit expected state** for each of super / sm-a / sm-b, both before and after operations:

- **`assert_commits_ahead DIR FROM TO EXPECTED`** — pins the commit count between two refs. E.g. `assert_commits_ahead .worktree/feat-x main feat/feat-x 1` confirms feat is exactly one commit ahead of main. Used before merge to verify the setup put commits where expected, and after merge to verify main caught up to feat.
- **`assert_pending_file DIR FILE MODE`** — pins the pending state of a specific tracked file. MODE is `none | unstaged | staged | both` and is matched against `git status`'s short-format code (`" M"`, `"M "`, `"MM"`, or empty). Lets a test say e.g. "after refuse, README is STILL unstaged-modified" — much stronger than "something is pending."
- **`assert_pending_submodule DIR SM_PATH`** — pins the "M `<submodule>`" pending state on a parent that captures a submodule SHA delta (the implicit-dirty case when a submodule's HEAD moved without the parent bumping).
- **`assert_clean DIR`** — pins "no pending changes" for a repo.
- **`assert_ancestor GIT_DIR ANCESTOR DESCENDANT`** — verifies a commit is reachable from another. Used after successful merge to confirm every feat-branch commit is now in main's history (FF correctness — guards against a future bug where someone replaces `git merge --ff-only` with `git merge --squash`: the tip would still match, but the history would be wrong).

### How they're applied

**Individual scenarios** (e.g. `merge_golden`, `merge_dirty_dst_parent`, `merge_two_phase`, `remove_dirty_parent`) declare expected state explicitly:

```bash
# Before merge — pin the setup
assert_pending_file . README unstaged   # README is unstaged-modified in main super
assert_clean sm-a                       # main super sm-a is clean
assert_commits_ahead .worktree/feat-x main feat/feat-x 1   # feat parent has 1 commit
# ... (six locations × two dimensions)

# Run operation, capture snapshot, expect refuse
state=$(snapshot_state .)
if ./subgrove merge feat-x; then fail "expected refuse"; fi

# After — same state, dirty edit still on disk
assert_pending_file . README unstaged   # still pending
assert_state_eq . "$state"              # nothing else changed either
```

This catches three different bug classes:
1. **Setup bugs** — if the matrix's `commit_one` or `_apply_dirty` silently fails, the pre-state assertion fires (without it, the test would pass by accident).
2. **Quiet side effects** — if an operation modifies refs or files it shouldn't, `assert_state_eq` detects it via the diff fields.
3. **Lost pending edits** — if a refuse path accidentally drops the user's pending change, `assert_pending_file ... unstaged` after the operation catches it.

**Matrix tests** (`test_merge_matrix.sh`) call a parametric `_verify_pre_state` helper after each setup, before the snapshot+merge. The helper takes the same 7 bits as the iteration and asserts the expected state for all 6 locations (clean/unstaged/staged per location, commit count per submodule, implicit `M <submodule>` when applicable). So every one of the 64 iterations now has both an asserted pre-state AND a snapshot-verified post-state.

**Successful merges** additionally check:
- Every feat-branch commit is an ancestor of main after merge (history correctness).
- `git ls-tree main sm-X` records the feat-branch tip for each submodule in the parent's tree (verifies the parent commit captured the bumps, not just that `main` ref moved).
- The merge-from worktree's state is byte-identical before and after (worktree retained — Phase 2 only touches main super).
