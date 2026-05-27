# `status`: a read-only, submodule-aware view across worktrees

`subgrove status` answers the one question the other commands can't: *across all my feature worktrees, where does each stand — locally and against `origin/main` — and which submodules has it touched?* It is the only read-only command besides `list`, and unlike `list` (a thin `git worktree list`) it understands the submodule layer. That is the whole point: no surveyed worktree manager ([prior-art.md](prior-art.md)) can show submodule state, because none model submodules at all. `status` is where the niche is most visibly subgrove's own.

## Read-only, and offline by default

Two stances, both load-bearing:

- **Read-only.** `status` never moves a ref and never touches a working tree. There is no rollback trap (contrast `cmd_new`) because there is nothing to roll back. Safe to run anywhere, anytime — including in the middle of a half-finished merge.
- **Offline by default.** Plain `subgrove status` does no network I/O. It reports the REMOTE column from whatever `refs/remotes/origin/main` each git dir already holds (populated by the last `new` / `update` / fetch). "Remote status if possible" means *if that ref exists* — otherwise the cell is `—`. This matches `git status` (offline) and preserves subgrove's standing rule that **network is always opt-in** (`merge push=`, `update`'s fetch).

`subgrove status --fetch` is the opt-in online path: it runs `git fetch origin main` in each git dir it is about to report on, refreshing that dir's `refs/remotes/origin/main`, then renders the same table against current data. A fetch advances only remote-tracking refs — no branch moves, no working-tree change — so `--fetch` stays non-destructive, just no longer strictly offline. It is the slow path (the parent `origin/main` fetched once — remote-tracking refs are shared across worktrees — plus one fetch per touched submodule git dir, which are isolated), which is exactly why it isn't the default.

## What it shows

One row per feature worktree under `WORKTREES_DIR`, plus a `(main)` row for the main worktree:

- **BRANCH** — the worktree's *actual* checked-out parent branch (`git -C <wt> rev-parse --abbrev-ref HEAD`), not `${BRANCH_PREFIX}<dir>` inferred from the directory name. A worktree whose parent was manually checked out to something else still reports truthfully.
- **SUBMODULES (touched)** — submodules whose isolated git dir carries that same branch, found with the same loop `cmd_merge` uses to discover touched submodules (iterate `list_all_submodules`, test `refs/heads/<branch>` in `<wt>/<sm>`). A `*` suffix marks a touched submodule with uncommitted changes (`is_clean`).
- **LOCAL** — `dirty`/`clean` (via `is_clean` over the parent and every touched submodule) plus ahead/behind the worktree's *local* `main` (`git -C <wt> rev-list --count --left-right main...HEAD` → `↑ahead ↓behind`).
- **REMOTE** — the parent branch vs `origin/main` (`rev-list --left-right refs/remotes/origin/main...HEAD`), shown only when that ref exists. A touched submodule that *trails* its `origin/main` is the actionable case and is flagged inline — it points the user straight at `subgrove update <name>`, which exists precisely to fast-forward a peer's submodule mains from `origin/main`.

Exact column alignment is an implementation detail; the rule is *the table stays scannable, and submodule-level remote detail surfaces only when a submodule is behind.*

## Why comparisons are per-git-dir

Submodule git dirs are isolated per parent worktree ([motivation.md](motivation.md)), so there is no single `origin/main` to compare against — each git dir has its own. `status` reads each branch against `origin/main` *in the same git dir that holds the branch*: the worktree's parent dir for the parent row, the worktree's submodule git dir for each submodule. `--fetch` likewise fetches into each of those dirs in place.

Because `status` only ever *reads* — it never propagates a ref from one git dir into another — it needs none of the cross-isolation machinery `merge` and `update` require: no peer propagation, no `_update_sync` sentinel ([update.md](update.md)). The cost is honest and worth stating: a freshly created worktree's submodule may have no `origin/main` yet, so its REMOTE cell is `—` until a `--fetch` (or a prior `update`) populates it.

## Edge cases

- **`touch=none` worktree** — SUBMODULES shows `—` (nothing touched); LOCAL/REMOTE still report the parent.
- **No `origin/main`** in a given git dir — that scope's REMOTE is `—`, never an error.
- **Empty `WORKTREES_DIR`** — a single friendly "no worktrees yet" line, not an empty table.
- **Repo with no submodules** — SUBMODULES is `—` throughout; still useful as a parent-only overview, and covered by the no-submodule test tier.

## Testing

Real-git fixtures, per [testing.md](testing.md). The state-sensitive assertions:

- **Default `status` is read-only** — snapshot the whole repo (parent + every submodule git dir: refs + working tree) before and after; assert byte-for-byte unchanged. This is the `status`-specific analogue of the suite's "snapshot equality on refuse" pattern.
- **`--fetch` moves only remote-tracking refs** — after `--fetch`, `refs/remotes/origin/*` may have advanced, but assert no `refs/heads/*` moved and no working tree changed.
- **Output greps** — branch names, touched-submodule names, the `*` dirty marker, `↑`/`↓` counts, the `—` placeholder when `origin/main` is absent, and the "behind origin/main" flag appearing only when a touched submodule trails.
- **Tiers** — exercised on both the with-submodule and no-submodule fixtures, plus the empty-`WORKTREES_DIR` case.
