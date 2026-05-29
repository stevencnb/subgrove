# `update`

Manual escape hatch for the case where a peer worktree was created (or has been sitting) before someone else's merge landed, and you want it caught up without going through another full merge. From the main worktree:

```
subgrove update <peer-name>
```

does:

1. `git fetch origin main` in main worktree (parent + each submodule). This advances `refs/remotes/origin/main` in each main-worktree submodule git dir, but deliberately does not advance `refs/heads/main` (which would mean a working-tree mutation in main worktree).
2. For each submodule initialised in `<peer-name>`, FF its `refs/heads/main` to **`refs/remotes/origin/main`** as just fetched into main worktree's submodule. Mechanism: temporarily stage `refs/remotes/origin/main` under a sentinel `refs/heads/_update_sync` ref in main worktree's submodule git dir, peer fetches that sentinel into its own `refs/heads/main`, sentinel is deleted. (The detour exists because `git fetch` over local-path uses `upload-pack`, which only advertises `refs/heads/*` and `refs/tags/*` — a peer can't fetch `refs/remotes/origin/main` directly.) No `+` on the refspec, so a non-FF on the peer's local main is reported and skipped. The pre-clean that clears a leftover sentinel first checks the ref is reachable from `refs/remotes/origin/main`; a user's unrelated branch that happens to be named `_update_sync` is left intact and that submodule skipped (see [user-data-rules.md](user-data-rules.md)).
3. Prints, under `→ NEXT STEPS`, the rebase command the user can run inside the peer worktree to bring its feature branches onto the new main; any submodule the FF step skipped (checked-out, diverged, sentinel collision, no `origin/main`) is listed under `⚠ ATTENTION`. See [user-data-rules.md](user-data-rules.md).

Does not touch any working tree, in main worktree or peer. Does not push, does not write to any ref outside the transient sentinel + the peer's local main. Does not auto-rebase — that's the user's call.

## `rebase=ff` — the one opt-in working-tree exception

`subgrove update <peer-name> rebase=ff` adds a phase after the main-FF step that advances the peer's feature branches automatically, but **fast-forward only**. For each submodule in the peer:

- HEAD already at or ahead of the new `main` → counted as "already current", nothing done.
- HEAD strictly behind `main` (HEAD is an ancestor of `main`, i.e. zero commits of its own to replay) **and** the working tree is clean → `git merge --ff-only main`, advancing the branch (and the working tree) to the new main.
- HEAD has commits not in `main` (a real rebase) **or** the working tree is dirty → left untouched and reported under `⚠ ATTENTION`; the manual `git submodule foreach 'git rebase main'` hint is printed under `→ NEXT STEPS` naming exactly those submodules.

Detached-HEAD (untouched) submodules are eligible too — a clean FF just moves the detached HEAD, which is what the manual `foreach` hint would also do.

### Why fast-forward only, and why opt-in

Default `update` is ref-only: it touches no working tree anywhere (the property above). `rebase=ff` is the single, explicit exception, and it stays *inside the spirit* of that property by mutating a working tree only when the move is a strict fast-forward of an already-clean tree — an operation that cannot conflict and cannot lose work. Everything that *could* surprise (replaying commits, or a tree with pending edits that a checkout might clobber) is deliberately excluded and handed back to the user. A non-FF case is precisely where rebase decisions, conflict resolution, and `--force-with-lease`-style judgement belong to a human, so `update` never makes them. The flag is off by default because silently moving a checked-out branch is exactly the kind of thing a user should ask for, not inherit. `rebase=ff` (not `rebase=true`) is the only accepted value: there is intentionally no "rebase everything, halt on conflicts" mode — that is the manual hint's job.

## The bug this shape fixes

An earlier version of `cmd_update` propagated `refs/heads/main` (not `refs/remotes/origin/main`) to peers. Because the `git fetch origin main` step never advances `refs/heads/main` in main worktree's submodule git dir (it writes only `refs/remotes/origin/main`), the propagation was a no-op when origin had new commits — peers stayed pinned to whatever `refs/heads/main` had been before the call, while the user observed `refs/remotes/origin/main` was further ahead. The symptom was that running `git rebase main` inside the peer accomplished nothing visible and the user had to rebase directly on `origin/main` instead.
