# User-data rules

Two project-wide invariants that constrain every subcommand:

1. **subgrove must not change any user commit.**
2. **subgrove must not amend any user commit or change any user file.**

Operationally these collapse into one: every byte under the user's control — committed objects, working-tree files, index, refs the user owns — must survive every subgrove invocation, unless the user explicitly opted in to the loss (`remove -f`).

## How the script upholds the rules

- **No history-rewriting verbs.** `--amend`, `rebase`, `reset --hard`, `filter-branch` appear nowhere in the script. The only ref-moving operations are `git fetch` and `git checkout -B main <feat_sha>` (`subgrove:514`), and the latter is gated by the Phase 1 ancestor check on the same code region (`subgrove:490`) — so `main` only ever fast-forwards.
- **Two-phase merge.** Validation (`subgrove:468–501`) precedes mutation (`subgrove:503–521`). Any non-FF or dirty refusal in Phase 1 means Phase 2 never runs, so no `main` ref anywhere has moved. See [merge.md](merge.md).
- **Force refspecs (`+ref:ref`) are scoped to script-owned refs:**

| Site | Refspec | Why force is safe |
|---|---|---|
| `subgrove:486` | `+refs/heads/<branch>:refs/heads/<branch>` into main super's submodule (merge Phase 1) | Imports feat objects across the per-worktree git-dir boundary. The destination ref *is* the feat branch being merged. |
| `subgrove:563` | `+refs/heads/main:refs/remotes/origin/main` into peer (merge propagation under `push=true`) | Only touches the peer's remote-tracking ref, mirroring the just-pushed origin/main. |
| `subgrove:364` | `+refs/heads/<branch>:refs/heads/<branch>` into main super's submodule (remove preservation) | Source is the user's own linked-worktree feat branch; `+` exists so a stale copy from a prior remove-then-recreate doesn't block preservation. A failure of this fetch now aborts `remove` before any `rm -rf` (`subgrove:364–374`). |

- **Destructive operations are bounded.** `rm -rf` and `branch -D` appear only in:
  - `cmd_remove` (`subgrove:388–389`) — gated by the cleanliness check, or `-f`; never reached if the feat-branch preservation fetch above fails.
  - `_rollback_new` (`subgrove:62–74`) — only touches the worktree + branch this same invocation just created (trap armed at `subgrove:239`, after the create at `subgrove:231`). The `branch -D` is skipped when the branch advanced past its creation SHA (`ROLLBACK_BR_SHA`, captured at `subgrove:238`), so build-chain commits aren't lost.
- **`cmd_update` is ref-only** (`subgrove:603–681`). No working-tree touch in main worktree or peer; no `require_clean`. The `_update_sync` sentinel is created and deleted around the propagation fetch; the defensive pre-clean refuses to delete a same-named ref that isn't a stale sentinel (`subgrove:646–654`).
- **`merge -f` was deliberately removed.** See [trade-offs.md](trade-offs.md): "The right resolution is to commit or drop that work, not wipe it."

## How the tests check the rules

Patterns enforced across the local suite:

| Pattern | Where it appears | What it pins |
|---|---|---|
| `snapshot_state DIR` + `assert_state_eq DIR EXPECTED` across an operation | 7 refuse scenarios in `test_merge.sh`, every dirty-refuse case in `test_remove.sh`, peer-skip cases in `test_update.sh` | HEAD + index + unstaged + staged diff byte-identical pre/post |
| `assert_pending_file DIR FILE unstaged` after a refuse | every dirty-refuse scenario | The specific pending edit still exists — not just "something is pending" |
| `assert_ancestor` on every commit between old `main` and feat tip after success | `merge_golden`, `merge_partial`, `merge_parent_only` | History correctness — a future regression from `--ff-only` to `--squash` would fail here even if tip equality still held |
| `assert_no_branch` on main super's submodules after a Phase-1 refuse | `merge_dirty_dst_sm`, `merge_dirty_src_sm`, etc. | Phase 1's feat-ref fetch didn't run when an earlier check refused |
| Matrix exhaustion | `test_merge_matrix.sh` (64), `test_remove_matrix.sh` (32) | Every combination of (dirty × commits) across parent + sm-a + sm-b confirms the dirty-refuse contract |
| Worktree-side snapshot pre/post success merge | `merge_golden`, `merge_partial`, `merge_multi_peer` | Phase 2 only touches main super — the feature worktree it merged FROM is byte-identical after |
| Rollback preserves surroundings | `new_rollback` | Sibling sm-a + `.gitignore` + `.subgroverc` byte-identical across a failed `new` |
| `-f` preserves branches | `remove_force`, `remove_force_long`, `remove_force_kv`, `remove_advanced_feat` | `-f` discards dirty edits (the user's explicit opt-in) but the preservation fetch for feat branches still runs |

Untracked files are deliberately excluded from `snapshot_state` so the test's own `out` redirect doesn't pollute the snapshot. See [testing.md § Test design principles](testing.md#test-design-principles).

The no-submodule tier (`tests/local-no-sm/`) enforces the same patterns where they apply: `snapshot_state` + `assert_state_eq` on every refuse/no-op path; `assert_pending_file` on dirty-refuse cases; `assert_ancestor` on the success path of `merge_golden`; `assert_branch_at` (with captured pre-SHA) on each `-f` force-remove case to verify the parent feat branch survives a force-discard of the dirty worktree; parent-state snapshot on the `new_build_chain_bad` rollback to verify the trap's blast radius is bounded. See [testing-local-no-sm.md](testing-local-no-sm.md) for the per-scenario tables.

The remote tier (`tests/remote/`) pins the same byte-identical preservation across wire-only paths the local fixtures can't reach:

| Command | Preserved location(s), pinned every case (happy + refuse + partial) |
|---|---|
| `merge push=true` | feat worktree (parent + sm-a + sm-b) — Phase 2 only touches main super; even on partial-failure (sm-a pushed, sm-b rejected, super never reached) the source feat worktree is byte-identical |
| `update` | main super (parent + sm-a + sm-b) + peer worktree (parent + sm-a + sm-b) — cmd_update is ref-only, no working-tree touch anywhere, including on diverged-peer refusal paths |
| `remove` | main super (parent + sm-a + sm-b) — only the named worktree disappears; main super's working tree is byte-identical, only the preserved feat branch ref is added |
| `new` | main super (parent + sm-a + sm-b) — only the gitignored `.worktree/<name>/` dir is added; on the branch-collision refuse, both main super AND the existing feat worktree are preserved |

The two parametric remote matrices (`test_merge_push_matrix.sh` with 8 cells over per-package origin state `{even, ahead}^3`, `test_update_matrix.sh` with 16 cells over per-sm `{origin: even, ahead} × {peer: clean, local}`) apply the worktree-preservation snapshot to every cell. See [testing-remote.md](testing-remote.md) for the per-scenario tables and the wire-specific invariants (FF-only push, push-order half-state, baseline-tag reset between cells).

The no-submodule remote tier (`tests/remote-no-sm/`) enforces the identical contract on a no-`.gitmodules` super, with the per-package locations collapsing to just the parent: `merge push=true` (and `merge` push=false) preserve the source feat worktree on every case incl. refuse; `update` preserves main super + peer worktree on every case; `remove` preserves main super on every case incl. the `-f` force variants and the multi-worktree case; `new` preserves main super. Success `merge` cases additionally carry `assert_ancestor` for history correctness. The only un-snapshotted paths are `new`'s early-validation refuses, which fire before any mutation. See [testing-remote-no-sm.md](testing-remote-no-sm.md) for the per-scenario tables.

## Hardened edge cases

These were thin edges where the contract could be pushed past by an unusual user state. Each is now closed by an explicit guard with a test pinning the failure path. Recorded so the rationale doesn't have to be re-derived.

### `_update_sync` sentinel collision (`subgrove:646–654`)

`cmd_update` stages `origin/main` under a transient `refs/heads/_update_sync` in each main-worktree submodule git dir. The defensive pre-clean used to `update-ref -d` that ref unconditionally, which would silently delete a user's real branch of the same name. Now the pre-clean deletes it **only when it is reachable from `refs/remotes/origin/main`** — the state any stale sentinel must be in, since it was written pointing at a past `origin/main`. A ref carrying independent work is not reachable, so that submodule is skipped with a warn and the branch is left intact.

Reachability (`merge-base --is-ancestor`) rather than strict equality: a sentinel left by an interrupted run, after `origin/main` later advanced, points at the *old* `origin/main` and is an ancestor of the current one — still recognized as ours and cleaned, rather than wedging recovery. `test_update.sh::update_sentinel_user_branch` forges such a user branch (a child of `main`, unreachable from `origin/main`) and pins that it survives while an un-collided submodule still updates; `update_sentinel_pre` continues to pin the stale-sentinel cleanup path.

### `remove` preservation-fetch failure (`subgrove:364–374`)

`cmd_remove` fetches each touched submodule's `feat/<name>` into the main-worktree submodule git dir before `git worktree prune` wipes the per-worktree storage. If that fetch fails, the commits exist only in the about-to-be-removed worktree. The failure path used to `warn:` and let `rm -rf` proceed — losing the commits, and (under `-f`) the dirty edits too. Now a preservation-fetch failure is an `err` that aborts **before any removal**: `-f` still bypasses the cleanliness gate but never this preservation gate.

`test_remove.sh::remove_preserve_fetch_fail` forces the fetch to fail (a `feat` branch in the main submodule is a directory/file conflict against creating `refs/heads/feat/<name>`) and pins that the worktree and its feat-branch commits survive the aborted `remove -f`.

### `_rollback_new` branch with build-chain commits (`subgrove:56–78`)

`_rollback_new` removes the worktree and deletes its parent feat branch on any failed `cmd_new`. If an atypical build chain committed onto that branch before failing, an unconditional `git branch -D` would lose the commits. Now the branch's SHA at `git worktree add` time is captured (`ROLLBACK_BR_SHA`, set at `subgrove:238`); the rollback deletes the branch **only if it is still at that SHA**, and otherwise leaves it in place with a warn. The worktree dir is still removed, so a retry of the same name errs on the existing branch rather than trampling the work.

`test_new.sh::new_rollback_committed` drives a build chain that commits on the parent then fails, and pins that the branch survives the rollback at the advanced commit.
