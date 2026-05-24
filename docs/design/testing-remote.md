# Remote tests

Tests under `tests/remote/`. Run as part of `./tests/run.sh` (default); skip with `--local-only`. Gated on three GitHub URLs in `tests/config.sh` — fill those in once, then run `tests/init_remote.sh` once to bootstrap, then `tests/run.sh` is the day-to-day command.

The remote tier exercises paths the local fixtures can't:

- `merge push=true` happy and failure paths against real `git push`.
- `new`'s fresh-base-from-origin (super origin/main advanced under us between fixture clone and `new`).
- Subgrove's push order on multi-package failures (sm-a → sm-b → super; set -e abort on first failed push).
- Per-package origin drift across `update` and `merge push=true` — the matrix tier exhausts the relevant state combinations.

Companion to [testing-local.md](testing-local.md) and [testing-local-no-sm.md](testing-local-no-sm.md).

43 scenarios across six files (5 + 7 + 8-cell matrix + 5 + 16-cell matrix + 2).

## Why this tier exists

The local fixture has no `origin` on the super (it's `git init`'d in place), so:

- `merge push=true` has nothing to push to. The local-no-sm tier covers the push-with-no-origin error path, but not the happy path against a real remote.
- `new`'s "fetch origin/main and use it as the parent base" path is unreachable — origin isn't there.
- Push order and partial-failure half-states are unobservable.

These are pinned here instead. Wire latency means the remote tier is slower than the local tiers (~22 min full run vs ~30s local), so most scenarios live in `tests/local/`. The remote tests focus on what the local fixture can't reach.

## The fixture

The remote fixture has two layers: a one-time bootstrap and a per-test reset.

### Bootstrap (`tests/init_remote.sh`)

Run once per set of fixture URLs:

```bash
tests/init_remote.sh             # prompts before force-pushing
tests/init_remote.sh --yes       # non-interactive (CI)
tests/init_remote.sh --force --yes  # re-bootstrap even if baseline exists
```

The script pushes an initial baseline commit + `subgrove-baseline` tag to all three remotes:

1. `sm-a` and `sm-b`: one-commit baseline with README only.
2. `super`: README, `.gitignore` (`.worktree/`), `.subgroverc` (matching the local fixtures' content), and `.gitmodules` wiring in sm-a and sm-b via the configured URLs.

Re-runs are idempotent: the script checks `refs/tags/subgrove-baseline` on all three; if present, it exits without touching anything. `--force` bypasses the check.

The `subgrove-test-lock` advisory tag is taken on the super repo for the duration of init (released on `EXIT`/`INT`/`TERM` via the same trap mechanism as per-test runs), so a concurrent test run from another machine can't race the bootstrap.

A human confirmation prompt fires before the force-push when bootstrapping (not when skipping). `--yes` bypasses; non-interactive stdin without `--yes` refuses with a remediation hint. This is the primary defense against a typo in `tests/config.sh` pointing at the wrong repo.

### Per-test reset (`tests/lib/fixture_remote.sh`)

`mkfixture_remote <name>` builds a fresh working clone for each scenario:

1. **Baseline-tag check.** Verify `subgrove-baseline` exists on all three remotes. If missing, fail loudly with "run `tests/init_remote.sh`."
2. **Lock acquisition** (first call per script). `git ls-remote $SUBGROVE_TEST_SUPER_URL refs/tags/subgrove-test-lock`. If present, abort with the remediation command. Otherwise push the tag and register an `EXIT`/`INT`/`TERM` trap to delete it.
3. **Reset main to baseline.** For each URL, `git push --force <url> refs/tags/subgrove-baseline:refs/heads/main`. Cheap on the wire — the baseline objects are already on the server; this is purely a ref move.
4. **Working clone.** `git clone <super-url>` into `tests/run/<ts>-remote-<name>/super/`, init both submodules, drop in the `subgrove` symlink and pre-create `.worktree/`.

The lock is **process-scoped, not iteration-scoped**: a single test script (especially a matrix test with many iterations) acquires the lock on its first `mkfixture_remote` call and keeps it until script exit. `cleanup_fixture_remote` rms the local fixture dir but does NOT release the lock. The teardown trap releases on exit. This avoids per-iteration acquire/release round trips and prevents a foreign run from sneaking in between iterations.

### Teardown trap

On `EXIT`/`INT`/`TERM` of the test script:

1. **`cd`** to a known-existing directory first — the trap may fire after `cleanup_fixture_remote` rm'd the test's cwd, and git refuses to run without a readable cwd. Silent failures here used to leak the lock tag; the harden in `_fixture_remote_teardown` makes this explicit.
2. **Delete every feature branch the script registered** (via `register_feature_branch <branch>`) from all three remotes. Best-effort; errors swallowed.
3. **Delete the lock tag.** Inline-capture stderr so a real release failure surfaces a loud warning with the manual recovery command instead of silently leaking. Non-zero rc on lock-release failure even if the test itself passed.

## Design invariants this tier guards

1. **`merge push=true` advances every origin in lockstep with local.** On the happy path, super's main, sm-a's main, and sm-b's main on the wire all equal the local feat tips after `subgrove merge push=true`. The matrix tier (`test_merge_push_matrix.sh`) verifies this across every combination of origin-drift states on the three packages.

2. **Push is FF-only and aborts on first failure.** Subgrove never `--force`s a push; if origin/main has advanced beyond what we're pushing, the push is rejected. Push order is `list_all_submodules` (sm-a, sm-b in our fixture) then parent. `set -e` aborts on the first failure: packages pushed earlier are already advanced on the wire, packages after the failing one are never attempted. The `non_ff_sm`, `non_ff_super`, and `partial_fail` cases pin each branch of this.

3. **`new` uses origin/main as the parent base when fetchable.** With super's origin/main ahead of stale local main, `subgrove new feat-X` creates `feat/feat-X` at the origin SHA, not the local SHA. Per-submodule origin/main does NOT influence the submodule feat branch base — that always comes from the gitlink SHA in super's tree.

4. **`update` is ref-only over the wire.** `cmd_update` fetches origin/main in main super (parent + each submodule), then FF-propagates the new origin/main into the peer worktree's submodule mains. Local main in main super is never moved; working trees anywhere are never touched. Diverged peer-side mains are refused with a warn, not clobbered. The 16-cell update matrix exhausts the `(origin × peer)^2` combinations.

5. **User-data preservation (see [user-data-rules.md](user-data-rules.md)).** Across every remote scenario — happy, refuse, partial-fail, ahead, diverged — `snapshot_state` + `assert_state_eq` pin the byte-identical preservation of the locations subgrove must not touch:
   - `merge`: feat worktree (parent + sm-a + sm-b) preserved on every outcome. Phase 2 only touches main super; the source worktree never moves.
   - `update`: main super + peer worktree (all three locations on each side) preserved on every outcome. Update is ref-only.
   - `remove`: main super (parent + sm-a + sm-b) preserved. The named worktree disappears (the user's explicit opt-in); main super's working tree is byte-identical.
   - `new`: main super (parent + sm-a + sm-b) preserved. Only the gitignored `.worktree/<name>/` dir is added.

6. **`remove` never reaches out to origin.** Removing a worktree (with or without prior `merge push=true`) leaves every origin ref byte-for-byte where it was.

7. **The bootstrap is destructive only with consent.** `init_remote.sh` won't force-push without an interactive `[y/N]` confirmation or an explicit `--yes` flag.

## Implementation notes

Three things to know before evolving this tier:

**The `_origin_main URL` helper is duplicated across `test_merge_push.sh`, `test_merge_push_matrix.sh`, and `test_remove.sh`.** Each copy uses `git ls-remote -- "$1" refs/heads/main | awk '{print $1}'`. Refactoring into `mutators.sh` would centralize, but the duplication is intentional for now — each test file is independently readable, and the helper is a one-liner. Update all three together if the implementation needs to change.

**The `partial_fail` half-state is documented contract, not a bug to fix.** When `merge push=true` pushes sm-a successfully then sm-b is rejected, sm-a origin advances and sm-b origin stays at upstream. There is no rollback. The `merge_push_partial_fail` case (and the corresponding matrix cells) explicitly pin this. A future two-phase push design with pre-validation across all remotes would update these expectations.

**The 16-cell update matrix and 8-cell merge_push matrix run sequentially under a single process-scoped lock.** Each cell takes ~25-35 s (mostly network), so the matrix tests are the dominant runtime: ~10 min for update_matrix, ~5 min for merge_push_matrix, ~7 min for the remaining single-case files. Full remote run is ~22 min. The lock-once optimization (see fixture above) saves a round-trip per cell — 16 cells × ~1 s lock acquire = ~16 s, small but real.

## `test_new.sh` (5)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden | clean fixture | worktree dir + parent feat branch; submodule HEADs on `feat/feat-golden`; parent base SHA == local `main`; **main super (parent + sm-a + sm-b) byte-identical pre/post** | The happy-path against a real remote. Invariant 3, 5. |
| Super origin ahead | side-clone pushes a commit to super's main; then `new feat-up` | parent feat at the new origin SHA (not stale local); main super preserved | Invariant 3 — `new`'s fetch-and-rebase-on-origin logic. |
| Super origin diverged | local commit on main (unpushed) + side-clone push to super's main; then `new feat-div` | parent feat at origin SHA; local main untouched at the local-commit SHA; main super preserved (status/diffs only — refs change is intentional) | Invariant 3 — origin freshness wins; local commit not bypassed silently in the worktree. |
| Per-submodule origin ahead | side-clones push commits to sm-a AND sm-b mains; then `new feat-smup` | submodule feat branches at the gitlink SHAs (NOT at the new origin/mains); main super preserved | Invariant 3 — submodule feat base comes from super's gitlink, not per-sm origin. |
| Branch collision after fresh clone | `new feat-x`, then `new feat-x` again | second `new` errs with "already exists"; **main super AND existing feat worktree byte-identical** across the refuse | The early-refuse path of `cmd_new` preserves both halves of the fixture. Invariant 5. |

## `test_merge_push.sh` (7)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Golden | commits in feat + both sm; `merge push=true` | all three origins at feat tips; **feat worktree byte-identical pre/post** | Phase 2 only touches main super; push lands on every remote. Invariants 1, 5. |
| Super only | parent commit, no submodule changes; `merge push=true` | super origin advanced; sm-a, sm-b origins unchanged; feat worktree preserved | Subgrove's filter skips sm with no commits; only super pushed. |
| One sm (sm-a) | commit in sm-a only; `merge push=true` | super + sm-a advanced; sm-b origin unchanged; feat worktree preserved | Single-sm push path. |
| Nothing to push | `new` then `merge push=true` with no commits | "Nothing to merge\|Push skipped" in output; main super AND feat worktree byte-identical | The Phase-0 filter short-circuits push too. Invariant 5 (main super preserved). |
| Non-FF super | parent commit; side-clone advances super origin; `merge push=true` | non-zero rc; super origin stays at upstream; feat worktree byte-identical even though Phase 2 + push happened | Invariant 2 — push refused, no force. Invariant 5 — user's WIP preserved regardless of push outcome. |
| Non-FF sm-a | commit in sm-a; side-clone advances sm-a origin; `merge push=true` | non-zero rc; sm-a origin stays at upstream; sm-b and super never pushed (set -e abort); feat worktree preserved | Invariant 2 — first failure aborts, downstream packages untouched on the wire. |
| Partial fail | commits in both sm; side-clone advances sm-b origin; `merge push=true` | non-zero rc; sm-a origin advanced (pushed before failure); sm-b origin stays at upstream; super never pushed (after failure); feat worktree preserved | THE half-state contract — packages pushed earlier are already advanced; no rollback. A future two-phase push design would update these. |

## `test_merge_push_matrix.sh` (8 cells)

Parametric matrix: `2^3` combinations of per-package origin state ∈ `{even, ahead}` across `{super, sm-a, sm-b}`. Each cell:

1. `mkfixture_remote`; `new feat-x`; commits in both sm + bump parent.
2. For each "ahead" package, push a third-party commit to that origin via `push_to_origin_main`.
3. Capture feat tips (what subgrove will attempt to push), pre-merge origin SHAs (to confirm "untouched" packages), and **`snapshot_state` of the feat worktree (parent + sm-a + sm-b)**.
4. Run `merge feat-x push=true`; capture rc.
5. Compute the first-failing package (first `ahead` in push order `sm-a → sm-b → super`).
6. Per package:
   - All-even cell → every push succeeded; assert origin == feat tip for every package.
   - First-fail package → origin stays at upstream.
   - Packages pushed before the failure → origin advanced to feat tip.
   - Packages after the failure → origin unchanged from pre-merge.
7. Exit code: 0 iff every push succeeded; non-zero otherwise.
8. **Assert feat worktree byte-identical** across every cell.

Guards: subgrove's push order (sm-a → sm-b → super) and FF-only contract across the full Cartesian product. The matrix doesn't replace the single-case tests in `test_merge_push.sh`; those remain as readable documentation. The matrix adds exhaustive state-tuple coverage. Invariants 1, 2, 5.

## `test_update.sh` (5)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Happy | side-clone pushes to sm-a origin; sm-b untouched; `update feat-h` | peer's sm-a main at new origin SHA; peer's sm-b main unchanged; **main super + peer worktree byte-identical** | Invariant 4 — single-sm fetch-and-propagate. Invariant 5. |
| Super origin ahead | side-clone pushes to super origin; `update feat-su` | local main NOT moved (update is fetch-only at parent level); `refs/remotes/origin/main` advanced; all working trees preserved | Invariant 4 — super-fetch updates only the remote-tracking ref, not local main. |
| All three origins ahead | side-clones push to all three; `update feat-all` | peer's sm-a and sm-b mains at the respective new origin SHAs; local main untouched; working trees preserved | Invariant 4 — full happy path. |
| Peer sm-a diverged | peer-side commit on sm-a main + side-clone push to sm-a origin; `update feat-d` | peer sm-a main unchanged (refused); "sm-a.*diverged\|skipped" warn fires (same-line match); all working trees preserved | Invariant 4 — non-FF refused, not clobbered. The same-line regex catches false-positive matches across unrelated lines. |
| No drift anywhere | no pushes; `update feat-n` | all submodule mains unchanged; local main unchanged; working trees preserved | True-no-op path. Invariant 4, 5. |

## `test_update_matrix.sh` (16 cells)

Parametric matrix: per-submodule × `{origin: even, ahead} × {peer: clean, local}` = 4 states per sm × 2 sms = 16 cells.

Per-sm outcome class:

- `(even, clean)`: peer main unchanged at baseline tip.
- `(even, local)`: peer main unchanged at peer-local tip (origin had nothing to propagate).
- `(ahead, clean)`: peer main = new origin/main (FF advance).
- `(ahead, local)`: peer main unchanged at peer-local tip + warn "diverged" (non-FF, refused).

Each cell:

1. `mkfixture_remote`; `new feat-x`.
2. `_setup_sm` for sm-a and sm-b. Each invocation:
   - Captures `baseline_sha` via `git rev-parse --verify --quiet main` — `--verify --quiet` ensures a missing ref gives empty output (not the literal string "main") so the caller's non-empty check actually fires.
   - For `peer=local`: checkout main in the peer's sm, commit, checkout back to feat/feat-x.
   - For `origin=ahead`: `push_to_origin_main` from a side-clone.
   - Echoes the expected peer.main SHA after `update` runs (per the outcome class above). Default-case `*) ... return 1` catches any future state typo loudly.
3. Caller asserts `[[ -n "$exp_a" ]]` and `[[ -n "$exp_b" ]]` — pins that `_setup_sm` returned a real SHA (bash 3.2 lacks `inherit_errexit`, so a silent failure inside the function would otherwise feed empty through to a weakened assertion).
4. **`snapshot_state` of the peer worktree (parent + sm-a + sm-b)**.
5. Run `update feat-x`.
6. `assert_branch_at .worktree/feat-x/sm-X main "$exp_X"` per sm.
7. `(ahead, local)` cells require the warn line `"sm-X.*(diverged|skipped)"` (same-line match).
8. **Assert peer worktree byte-identical** across every cell.

Guards: invariant 4 across the full per-sm Cartesian product. Invariant 5 across every cell.

## `test_remove.sh` (2)

| Scenario | Setup | Asserts | Guards |
|---|---|---|---|
| Remove without prior push | `new feat-rmnp`; commit in sm-a; `remove feat-rmnp -f` (force: dirty submodule edits) | worktree gone; origin refs (super + sm-a + sm-b) byte-for-byte unchanged; **main super (parent + sm-a + sm-b) byte-identical pre/post** | Invariant 6 — `remove` never touches origin. Invariant 5 — main super's working tree preserved. |
| Remove after merge push=true | `new feat-rmap`; commit in sm-a; `merge feat-rmap push=true`; snapshot origin SHAs; `remove feat-rmap` | worktree gone; origin SHAs (which advanced via the merge push) unchanged by the subsequent remove; **main super byte-identical** post-remove; parent feat branch retained locally; submodule feat branches preserved into main super's submodule git dirs | Invariant 6 — origin frozen across remove. Invariant 5 — main super preserved (only refs added). The lifecycle.md "branches retained" contract verified over real-wire push. |

`tests/local/test_remove.sh` covers the full state-machine of `remove` (dirty handling, force flag, branch retention edge cases, etc.). This file pins only the wire-specific concerns: that `remove` is purely local, and that main super's working tree survives the remove of a previously-pushed worktree.

## Tests intentionally NOT in `tests/remote/`

These paths are covered by the local tiers and don't gain from wire repetition:

- The full `subgrove remove` state-machine (dirty handling, force flag, multi-worktree interactions) — covered by `tests/local/test_remove.sh` and its 32-cell matrix.
- The two-phase merge half-state invariant (non-FF on submodule N+1 must NOT leave submodules 1..N already moved) — covered by `tests/local/test_merge.sh::merge_two_phase`. Forging a divergent submodule commit while keeping the parent clean is awkward over the wire without an extra contributor clone.
- The dirty-refuse matrix (2^6 combinations across parent + sm-a + sm-b × staged variants) — covered by `tests/local/test_merge_matrix.sh`. Repeating it over the wire would add ~30 minutes for the same logical coverage.
- `subgrove list`, the linked-worktree refusal, and `assert_main_worktree` — pure parent-side flows; not wire-dependent.

The no-submodule tier (`tests/local-no-sm/`) has no remote counterpart. Adding a fourth fixture URL for a no-submodule super buys little over what `local-no-sm/` already covers — the gap subgrove fills is fundamentally about submodules, and the no-submodule tier exists to verify graceful degradation rather than core behavior. Deferred until a concrete need arises.

## Cross-reference

- The fixture builder: `tests/lib/fixture_remote.sh` (`mkfixture_remote` exports `FIXTURE_ROOT`, `FIXTURE_SUPER`; `register_feature_branch` enrolls a branch in the teardown cleanup; `cleanup_fixture_remote` rms the local fixture but keeps the lock for subsequent iterations).
- The bootstrap: `tests/init_remote.sh` (one-time per fixture URL set; idempotent; interactive confirmation by default).
- Push-side helpers: `tests/lib/mutators.sh::push_to_origin_main` and `push_n_to_origin_main` (third-party commits to a URL's main from a side clone; cleanup-on-failure for the temp dir).
- Assertion helpers: `tests/lib/assert.sh` — same set as the local tiers.
- Configuration: `tests/config.sh` (committed; maintainer fills in three GitHub URLs).
- Top-level overview: [testing.md](testing.md).
- User-data preservation rules these tests pin: [user-data-rules.md](user-data-rules.md).
