# Lifecycle: `new` and `remove`

## `new` — defaults

1. **Fresh base.** `cmd_new` runs `git fetch origin main` upfront and bases the new worktree off `origin/main`, so the feature doesn't silently start from a stale local `main`. Submodule clones, in turn, check out the parent's just-fetched recorded SHAs.
2. **Submodule object sharing.** Each submodule clone uses `git submodule update --init --reference <main-worktree-submodule-gitdir>`, which writes `objects/info/alternates` in the new submodule git dir to borrow objects from the main worktree's submodule. New worktrees inherit existing object storage instead of refetching ~everything from origin. Refs stay isolated (that's the unavoidable per-worktree property); only the object DB is shared.
3. **Worktree location:** `.worktree/<name>/` (project-local, hidden, gitignored).
4. **Submodule branching:** every submodule, unless `touch=<list>` or `touch=none`. Branch creation is strict — collisions are errors, not silently-skipped warnings, because per-parent-worktree submodule git dirs are fresh and a real collision indicates something is wrong.
5. **State sharing:** runtime state (databases, caches, etc.) stays isolated per worktree. Items configured in `COPY_TO_NEW_WORKTREE` are copied from the main worktree (missing items silently skipped).
6. **Build chain:** if `BUILD_CHAIN` is non-empty, runs `BUILD_CMD` inside each module in order. Submodules outside the chain are initialised but not built — run their build commands manually if you'll develop on them.

## Rollback on partial failure

If anything during `new` fails after the worktree directory has been created (submodule init, branch creation, build), an `EXIT`/`INT`/`TERM` trap removes the half-built worktree (`rm -rf <wt>` + `git worktree prune` + `git branch -D <prefix><name>`) so a retry of the same name doesn't trip on residue. The trap is disarmed at the end of `cmd_new` on success. The `branch -D` is skipped when the feat branch advanced past the SHA it was created at — e.g. an atypical build chain that committed onto the parent branch before failing — so those commits survive the rollback (see [user-data-rules.md](user-data-rules.md)).

## `remove`

`git worktree remove` refuses on parent worktrees containing initialized submodules (git ≥ 2.40), and `--force` doesn't bypass that. The cleanliness gate in `remove` is the equivalent safety check; the actual removal is `rm -rf <wt>` + `git worktree prune`. Prune recursively cleans `.git/worktrees/<name>/` including the per-worktree submodule git dirs nested under `modules/<sm>/`, so no additional cleanup is needed for this layout.

The cleanliness gate covers **every initialised submodule** in the worktree, not just those with a `<prefix><name>` branch — un-branched-but-edited submodules would otherwise be silently destroyed by the `rm -rf`.

Submodule branches `<prefix><name>` are retained — they're cheap and removing them across many submodules is its own footgun. Delete manually when you're confident.

Because the per-worktree submodule git dirs live under `.git/worktrees/<name>/modules/<sm>/` and `git worktree prune` (below) wipes that subtree, `remove` fetches each touched submodule's `refs/heads/<prefix><name>` into the main-worktree submodule git dir (`.git/modules/<sm>/`) **before** running prune. The branch survives the prune there, addressable via `git -C <super>/<sm> log <prefix><name>`. Re-creating the worktree later (`subgrove new <name>` after a manual `git branch -D <prefix><name>` on the parent) starts the submodule branch fresh from the recorded gitlink SHA — the preserved branch lives only in the main-worktree submodule git dir.
