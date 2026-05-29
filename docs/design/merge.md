# `merge`

Goal: make `main` reflect feat work in every place that has its own view of `main`. Because of submodule git-dir isolation (see [motivation.md](motivation.md)), "every place" means:

- the main parent worktree itself (parent + each touched submodule),
- every *other* linked parent worktree's git dir for each touched submodule.

The command splits into a **validation phase** and a **mutation phase** so a non-FF on submodule N+1 can never leave submodules 1..N already moved (avoiding the half-state that the previous one-pass implementation had).

## Phase 0 — discovery & filter (read-only)

1. **Discover touched submodules.** Those with a local `<prefix><name>` branch in the source worktree's submodule.
2. **Refuse on dirty source or destination** (parent + every touched submodule on both sides). No bypass — commit or drop the changes first. (A `git stash` is fine for plain file edits but *not* when status shows `M <submodule>`: that stash captures an old SHA delta that re-applies as a revert after the merge advances HEAD past it.)
3. **Filter to "needs merge".** A submodule is skipped if its feat tip already equals main worktree's `refs/heads/main`. Likewise for parent.

## Phase 1 — validation (small, recoverable side effects only)

4. For each needs-merge submodule:
   - `git -C <main_sm> fetch <linked_sm> +refs/heads/<branch>:refs/heads/<branch>` — copies feat objects across the isolation boundary and creates the feat branch ref in main worktree's submodule. **Does not move `main`.**
   - **FF check:** refuse if main worktree's `refs/heads/main` is not an ancestor of `<feat_sha>`.
5. **Parent FF check:** refuse if parent's `refs/heads/main` is not an ancestor of `<prefix><name>`.

If anything fails here, no `main` ref has been moved anywhere. The user can fix and retry.

## Phase 2 — mutation (only runs if validation passed)

6. **Move main + working tree** in main worktree, per submodule: `git -C <main_sm> checkout -B main <feat_sha>`. This re-attaches HEAD to `refs/heads/main`, force-moves it to `<feat_sha>`, and updates the index/working tree atomically. Replaces an older `update-ref` plumbing call, which left the working tree silently desynced when the submodule happened to be on `main` rather than detached. (An earlier revision had a `force=true` fallback to `update-ref`; it was removed because its only purpose was to recreate the very desync this `checkout -B` form fixes.)
7. **FF parent main** in main worktree (`git merge --ff-only <prefix><name>`). Parent refs are shared across linked worktrees, so peer worktrees see the new parent main immediately.
8. **Propagate to peer worktrees.** For every other `.worktree/<peer>/`, for every needs-merge submodule whose git dir exists there:
   - `git -C <peer_sm> fetch <main_sm_path> refs/heads/main:refs/heads/main` — no `+`, so a non-FF on the peer's local main is reported and skipped rather than clobbered.
   - If the fetch fails, the script inspects the peer's `symbolic-ref HEAD` to distinguish "main is currently checked out in the peer (git refused to update a checked-out branch)" from "peer's main has actually diverged" — the warning text reflects whichever applies, and is surfaced under `⚠ ATTENTION` at the end of the run (see [user-data-rules.md](user-data-rules.md)) rather than only as an inline `warn:` line that a long merge could bury.
   - If `push=true`, also `git -C <peer_sm> fetch <main_sm_path> +refs/heads/main:refs/remotes/origin/main` — mirrors the just-pushed origin/main into the peer's remote-tracking ref so the peer doesn't need a manual `git fetch origin` to see the merge.
9. **Optional push.** If `push=true`, push parent main and each merged submodule's main from the main worktree to origin.
10. **Worktree retained.** `merge` never removes the source worktree. Use `remove` separately.

Steps 8 and 9 are the cross-worktree correctives. Without step 8, a peer worktree's `refs/heads/main` for a merged submodule lags the actual main forever, and `git rebase main` from the peer's feat branch silently no-ops. Step 9's origin/main mirroring is gated on `push=true` because that's the only case where origin actually reflects the merge.

## What's shared vs isolated for parent refs

Parent refs (including `refs/heads/main`) are shared across linked worktrees, so step 7 alone propagates the new parent main to peers — no parent-side step 8 needed. Only submodule refs are isolated, which is what makes step 8 necessary for submodules.

## Two-pass vs one-pass

An earlier shape was a single pass with FF checks inline (check submodule N, move submodule N, check submodule N+1, move submodule N+1, ...). A non-FF discovered at submodule N+1 left N already moved — half-state. The two-phase split has a small validation-pass cost paid only once per merge; the half-state is impossible by construction. See [trade-offs.md](trade-offs.md) for related alternatives that were considered.
