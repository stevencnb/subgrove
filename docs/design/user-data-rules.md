# User-data rules

Two project-wide invariants that constrain every subcommand:

1. **subgrove must not change any user commit.**
2. **subgrove must not amend any user commit or change any user file.**

Operationally these collapse into one: every byte under the user's control — committed objects, working-tree files, index, refs the user owns — must survive every subgrove invocation, unless the user explicitly opted in to the loss (`remove -f`).

## How the script upholds the rules

- **No history-rewriting verbs.** `--amend`, `rebase`, `reset --hard`, `filter-branch` appear nowhere in the script. The only ref-moving operations are `git fetch` and `git checkout -B main <feat_sha>` (`subgrove:476`), and the latter is gated by the Phase 1 ancestor check on the same code region (`subgrove:452`) — so `main` only ever fast-forwards.
- **Two-phase merge.** Validation (`subgrove:432–463`) precedes mutation (`subgrove:464–479`). Any non-FF or dirty refusal in Phase 1 means Phase 2 never runs, so no `main` ref anywhere has moved. See [merge.md](merge.md).
- **Force refspecs (`+ref:ref`) are scoped to script-owned refs:**

| Site | Refspec | Why force is safe |
|---|---|---|
| `subgrove:448` | `+refs/heads/<branch>:refs/heads/<branch>` into main super's submodule (merge Phase 1) | Imports feat objects across the per-worktree git-dir boundary. The destination ref *is* the feat branch being merged. |
| `subgrove:524` | `+refs/heads/main:refs/remotes/origin/main` into peer (merge propagation under `push=true`) | Only touches the peer's remote-tracking ref, mirroring the just-pushed origin/main. |
| `subgrove:333` | `+refs/heads/<branch>:refs/heads/<branch>` into main super's submodule (remove preservation) | Source is the user's own linked-worktree feat branch; `+` exists so a stale copy from a prior remove-then-recreate doesn't block preservation. |

- **Destructive operations are bounded.** `rm -rf` and `branch -D` appear only in:
  - `cmd_remove` (`subgrove:350–351`) — gated by the cleanliness check, or `-f`.
  - `_rollback_new` (`subgrove:60–63`) — only touches the worktree + branch this same invocation just created (trap armed at `subgrove:208`, after the create at `subgrove:201`).
- **`cmd_update` is ref-only** (`subgrove:565–630`). No working-tree touch in main worktree or peer; no `require_clean`. The `_update_sync` sentinel is created and deleted around the propagation fetch.
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

## Edge cases worth knowing about

None are observed failures or active rule violations. They're places where the contract has a thin edge that future code or unusual user states could push past — recorded so they don't have to be re-derived.

### `_update_sync` sentinel collision (`subgrove:604`, `subgrove:620`)

The sentinel pre-clean is `git update-ref -d "$sync_ref" 2>/dev/null || true`. If a user happens to have a real branch named `_update_sync` in a submodule, `cmd_update` deletes it without warning. The leading-underscore name signals reserved-internal use, and `test_update.sh::update_sentinel_pre` exercises the cleanup path — but the test seeds the sentinel itself, so it doesn't surface "the user's pre-existing branch was their work."

**Why not a real violation:** the name is deliberately unusual; a real user collision is implausible. **If hardened:** check whether the pre-existing ref points at `origin/main` before deleting (the only legitimate state for a sentinel); refuse otherwise.

### `remove` preservation-fetch failure path (`subgrove:332–337`)

If the preservation fetch fails (rare — same machine, same filesystem), the user gets a `warn:` line and `rm -rf` proceeds in the next phase. Combined with `-f`, this can take both the dirty edits *and* the user's feat-branch commits with it. No test exercises this failure mode.

**Why not a real violation:** the fetch is between two paths on the same disk; failure modes are exotic (permissions, disk full, filesystem corruption). The user is informed via warning. **If hardened:** treat preservation-fetch failure as an abort condition; `-f` still bypasses the cleanliness gate but not the preservation gate.

### `_rollback_new` deletes a branch the user might have committed to (`subgrove:56–65`)

The trap fires on any `cmd_new` exit between worktree-create and end-of-`cmd_new`. The branch deleted is the one the script just created, but if the build chain commits to that branch (atypical — `BUILD_CMD` is supposed to be idempotent setup, not commit-generating) and then fails, those commits would be lost.

**Why not a real violation:** `BUILD_CMD` committing to git is an abuse of the configuration knob, not a documented use case. **If hardened:** before `git branch -D`, check whether the branch tip differs from the SHA the script left it at right after `git worktree add`; if so, skip the deletion and warn instead.
