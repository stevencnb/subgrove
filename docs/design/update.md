# `update`

Manual escape hatch for the case where a peer worktree was created (or has been sitting) before someone else's merge landed, and you want it caught up without going through another full merge. From the main worktree:

```
subgrove update <peer-name>
```

does:

1. `git fetch origin main` in main worktree (parent + each submodule). This advances `refs/remotes/origin/main` in each main-worktree submodule git dir, but deliberately does not advance `refs/heads/main` (which would mean a working-tree mutation in main worktree).
2. For each submodule initialised in `<peer-name>`, FF its `refs/heads/main` to **`refs/remotes/origin/main`** as just fetched into main worktree's submodule. Mechanism: temporarily stage `refs/remotes/origin/main` under a sentinel `refs/heads/_update_sync` ref in main worktree's submodule git dir, peer fetches that sentinel into its own `refs/heads/main`, sentinel is deleted. (The detour exists because `git fetch` over local-path uses `upload-pack`, which only advertises `refs/heads/*` and `refs/tags/*` — a peer can't fetch `refs/remotes/origin/main` directly.) No `+` on the refspec, so a non-FF on the peer's local main is reported and skipped. The pre-clean that clears a leftover sentinel first checks the ref is reachable from `refs/remotes/origin/main`; a user's unrelated branch that happens to be named `_update_sync` is left intact and that submodule skipped (see [user-data-rules.md](user-data-rules.md)).
3. Prints the rebase command the user can run inside the peer worktree to bring its feature branches onto the new main.

Does not touch any working tree, in main worktree or peer. Does not push, does not write to any ref outside the transient sentinel + the peer's local main. Does not auto-rebase — that's the user's call.

## The bug this shape fixes

An earlier version of `cmd_update` propagated `refs/heads/main` (not `refs/remotes/origin/main`) to peers. Because the `git fetch origin main` step never advances `refs/heads/main` in main worktree's submodule git dir (it writes only `refs/remotes/origin/main`), the propagation was a no-op when origin had new commits — peers stayed pinned to whatever `refs/heads/main` had been before the call, while the user observed `refs/remotes/origin/main` was further ahead. The symptom was that running `git rebase main` inside the peer accomplished nothing visible and the user had to rebase directly on `origin/main` instead.
