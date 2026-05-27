# Motivation

## Goals

- Multiple in-progress features coexist on disk; switching features is `cd`, not `git checkout`.
- Per-feature isolation across the parent repo plus its submodules, with a single helper script for create / merge / remove.
- A merge in any one worktree leaves every *other* worktree's view of `main` consistent — no silent ref staleness.

## Non-goals

- Running multiple application stacks at once. Local service ports collide; assume only one stack runs at a time across all worktrees.
- Saving disk: each worktree carries its own per-submodule object DB (minimized via `--reference`, see [lifecycle.md](lifecycle.md)), build artifacts, caches, state directories. Expect multi-GB cost per worktree.

## The constraint: submodule git-dir isolation

When a parent repo is in a linked git worktree, its submodules get a **fresh git dir** under `.git/worktrees/<wt>/modules/<sm>/` — not a shared link to `.git/modules/<sm>/`. This is git's default behavior for submodules under linked worktrees and there is no flag to make them share.

Concretely:

| Resource | Across parent worktrees |
|---|---|
| Parent-repo object DB | Shared (one `.git/objects`) |
| Parent-repo refs (`refs/heads/*`, `refs/remotes/*`) | Shared (one `.git/refs`) |
| Parent-repo HEAD / index / working tree | Isolated per worktree |
| **Submodule object DB** | **Isolated** per parent worktree |
| **Submodule refs** (`refs/heads/main`, `refs/remotes/origin/main`) | **Isolated** per parent worktree |
| Submodule HEAD / index / working tree | Isolated per worktree |
| Project state dirs (databases, caches, logs, generated certs) | Isolated (gitignored) |
| Local service ports | Conflict — one stack at a time |

Two consequences fall out of this:

1. A `git fetch origin` inside one worktree's submodule does **not** benefit any other worktree's view of that submodule.
2. After a merge, every parent worktree's submodule has its own `refs/heads/main` that has to be moved forward independently.

The script handles both. See [merge.md](merge.md) for how, and [trade-offs.md](trade-offs.md) for why we didn't try to share submodule git dirs.

## Why parent-worktree-per-feature, not per-submodule branching

| Approach | Trade-off |
|---|---|
| Per-submodule branching in one checkout | Cheap, but you must remember "which submodule is on which branch right now" across N repos. Mental overhead scales with feature count. |
| **Parent worktree per feature** | Heavy disk + cold-build cost, but one feature == one directory. Branch state per submodule is naturally scoped to the worktree containing it. |
| Multiple full clones | Heaviest. No shared object DB. Reserved for last-resort isolation. |

Filesystem-as-isolation is easier to keep straight than mental-state-as-isolation. The disk + cold-build cost is paid once per feature.

## Layout

```
<superproject root>/                  ← main worktree (branch: main)
├── .worktree/                        ← gitignored
│   ├── feat-foo/                     ← linked worktree, branch: feat/foo
│   │   ├── <submodule-a>/
│   │   ├── <submodule-b>/
│   │   └── ...
│   └── feat-bar/                     ← linked worktree, branch: feat/bar
└── ...
```

`.worktree/` must be in `.gitignore`. `subgrove` refuses to run otherwise. The folder is configurable via `WORKTREES_DIR` in `.subgroverc` (default `.worktree/`); whatever it is set to must be gitignored, and `subgrove init` both prompts for it and adds the gitignore entry.
