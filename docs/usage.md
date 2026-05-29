# Usage

`subgrove` is a single shell script driving the lifecycle of feature worktrees in a superproject with submodules. Run it from the main worktree (it refuses inside a linked worktree).

## Setup

1. Install `subgrove` on your `$PATH` (`brew install stevencnb/tap/subgrove`, or drop the script into a `$PATH` directory). It discovers the superproject from your current directory via `git rev-parse --show-toplevel`, so run it from **inside** the main worktree — any subdirectory works, like `git`. It refuses inside a linked worktree.

2. From the superproject root, run the guided setup:

   ```bash
   subgrove init
   ```

   This writes `.subgroverc`, adds `.worktree/` to `.gitignore` (and creates the directory so the ignore check matches), and is reconfigure-aware — re-run any time; it backs up the previous `.subgroverc`. Use `subgrove init --defaults` for a non-interactive run.

3. Prefer to configure by hand? `subgrove` sources `.subgroverc` from the superproject root if present, and runs with all-empty defaults otherwise (enough for a no-build, no-copy workflow). Copy [`.subgroverc.example`](../.subgroverc.example) — see [Configuration](#configuration) for the schema — and add `.worktree/` to `.gitignore` yourself, since `subgrove` refuses to run otherwise.

## Commands

### `subgrove init`

Guided, one-time setup for a superproject. Prompts for `BRANCH_PREFIX`, which submodules to build (`BUILD_CHAIN`, offered from the detected `.gitmodules` list), `BUILD_CMD` (only if a chain is selected), and `COPY_TO_NEW_WORKTREE`, then writes a commented `.subgroverc`. Also ensures `.worktree/` is gitignored and present on disk so the first `new` passes the ignore check.

Reconfigure-aware: re-running loads the existing `.subgroverc` as the prompt defaults and backs the old file up to `.subgroverc.bak`. Non-interactive (`--defaults` / `-y`, or any non-TTY stdin) writes defaults without prompting, so it's safe in scripts and CI.

### `subgrove new <name>`

Create `.worktree/<name>/`, branch parent + every submodule onto `<BRANCH_PREFIX><name>`, and run the build chain.

Flags:

- `touch=<csv>` — comma-separated list of submodule paths to branch. Default: all initialized submodules. `touch=none` leaves all submodules in detached HEAD.
- `build=false` — skip `BUILD_CHAIN`. Useful when you don't need a working build immediately.

Behavior:

- Fetches `origin/main` first to anchor the new worktree on the freshest base. The feature branch is created off `origin/main`, not local `main`.
- Initializes submodules with `git submodule update --init --reference <main-worktree-sm-gitdir>`, which makes the new worktree share the main worktree's submodule object DB via `objects/info/alternates`. Refs stay isolated per worktree (git's submodule isolation is unavoidable); only objects are shared.
- Copies items in `COPY_TO_NEW_WORKTREE` from the main worktree into the new worktree. Missing items are silently skipped.
- Runs `BUILD_CMD` inside each `BUILD_CHAIN` module in order, stopping at the first failure. With `build=false`, prints the commands the user would run instead.
- Has an `EXIT`/`INT`/`TERM` rollback trap covering **setup** (submodule init, branch creation): if a setup step fails, the half-built worktree and its feature branch are removed so a retry of the same name doesn't trip on residue.
- A **build failure does not roll back.** The build runs after setup, when the worktree is already complete, so `new` keeps the worktree, its branches (and any commits the build made), surfaces the failure and the command(s) to finish the build by hand under `⚠ ATTENTION` / `→ NEXT STEPS`, and exits non-zero. Re-run the build manually, or `remove` the worktree to start over.

See [docs/design/lifecycle.md](design/lifecycle.md) for the full rationale.

### `subgrove merge <name>`

Fast-forward `<BRANCH_PREFIX><name>` → `main` in every place that has its own view of `main`:

- The main worktree (parent + each touched submodule).
- Every other linked parent worktree's git dir for each touched submodule (peer propagation).

Flags:

- `push=true` — push merged `main` to origin (parent + each affected submodule). Additionally mirrors the new `origin/main` into peer worktrees' `refs/remotes/origin/main`.

Algorithm: split into validation and mutation phases. Phase 0 discovers touched submodules and filters those that need merging. Phase 1 fetches feat objects into the main worktree and verifies fast-forward feasibility for parent + each submodule — no `main` ref is moved. Phase 2 only runs if Phase 1 passed: moves `main` in main worktree's submodule via `git checkout -B main <feat_sha>`, FF-merges parent's `main`, and propagates to peer worktrees.

Refuses if anything is dirty (parent + every touched submodule, on both sides). The cleanliness gate intentionally has no bypass — see [docs/design/trade-offs.md](design/trade-offs.md) for why `merge -f` is excluded.

See [docs/design/merge.md](design/merge.md) for the full algorithm.

### `subgrove update <name>`

Manual escape hatch: catch a peer worktree's submodule `main` up to `origin/main` without going through `merge`.

From the main worktree: fetches `origin/main` (parent + every submodule), then for each submodule in `<name>` FF-updates its `refs/heads/main` to point at the just-fetched `origin/main`.

Does not touch any working tree, does not auto-rebase, does not push. Prints the rebase command under `→ NEXT STEPS` for the user to run themselves.

See [docs/design/update.md](design/update.md) for the sentinel mechanism that makes this possible.

### `subgrove remove <name>`

Remove the worktree at `.worktree/<name>/`. Refuses if dirty (parent or any initialized submodule). Use `-f` (or `--force` / `force=true`) to bypass the dirty check.

Submodule branches `<BRANCH_PREFIX><name>` are retained — they're cheap and removing them across many submodules is its own footgun. Delete manually when confident.

Internal mechanism: `rm -rf` + `git worktree prune` rather than `git worktree remove`. The latter refuses on parent worktrees containing initialized submodules (git ≥ 2.40, no `--force` bypass); the cleanliness gate above is the equivalent safety check.

### `subgrove list`

Wraps `git worktree list`. No subgrove-specific formatting.

### `subgrove help`

Print usage.

### `subgrove --version`

Print the version (`subgrove X.Y.Z`). Like `help`, it does no repo discovery, so it works outside a git repo.

## Output: next steps & attention

Every command prints its progress as it runs, then — **only** if it left you something to do — a tagged section at the very end, so it can't scroll away under the progress above:

- **`→ NEXT STEPS`** — manual follow-up to run: the rebase after `update`, the build commands skipped by `build=false`, the rebuild commands after a build that failed.
- **`⚠ ATTENTION`** — work subgrove skipped or refused that you need to resolve: a peer whose `main` is checked out or has diverged, a submodule left for a manual rebase under `rebase=ff`, a build that failed (the worktree is kept).

A clean run that left nothing outstanding prints no such section. Hard errors are tagged `✗ Error:` and carry their own recovery hint inline.

Color is emitted only when output is a terminal: piping or redirecting (`subgrove … | tee`, CI logs) yields plain text, and setting [`NO_COLOR`](https://no-color.org) disables it outright.

## Workflows

### Create a feature

```bash
subgrove new my-feature
cd .worktree/my-feature
# ... do work, commit ...
```

### Merge back to main

```bash
# from main worktree
subgrove merge my-feature              # FF main everywhere it needs to land
subgrove merge my-feature push=true    # ... and push origin/main

subgrove remove my-feature             # tear down the worktree (branches retained)
```

### Catch a peer worktree up

When `my-other-feature` was created (or was sitting idle) before someone else's merge landed:

```bash
# from main worktree
subgrove update my-other-feature
# then rebase feature branches inside my-other-feature:
( cd .worktree/my-other-feature && git submodule foreach 'git rebase main' )
```

The `git submodule foreach 'git rebase main'` line is deliberately written without `|| true` — a real conflict should halt the loop and prompt the user, not look like a no-op pass.

## Configuration

`subgrove` sources `.subgroverc` at the superproject root, if present. Recognized variables:

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `BUILD_CHAIN` | bash array | `()` | Ordered submodule paths to init+build during `new`. |
| `BUILD_CMD` | string | `./init.sh && ./build.sh` | Shell command run inside each `BUILD_CHAIN` module. |
| `COPY_TO_NEW_WORKTREE` | bash array | `()` | Files/dirs in main worktree to copy into new worktrees. |
| `BRANCH_PREFIX` | string | `feat/` | Prefix for feature branch names. Include the trailing separator. |

Generate this file with `subgrove init` (reconfigure-safe), or see [`.subgroverc.example`](../.subgroverc.example) for the template to copy by hand.

## Gotchas

- **Cold build cost:** each new worktree pays a full `BUILD_CHAIN` build. Object sharing via alternates makes the *clone* part nearly free; the build chain is the remaining cost.
- **Alternates are followed, not copied.** New worktrees' submodule git dirs depend on `.git/modules/<sm>/objects` continuing to exist. If you ever want to delete the main worktree's submodule git dir, run `git -C <each-peer-sm> repack -a` first to detach the dependency.
- **Detached-HEAD commits in submodules:** without `touch=` covering the submodule, commits there land on a detached HEAD and are easily lost. The default branches every submodule for this reason.
- **Branch name collisions in parent refs (shared):** the parent feature branch is one ref across all worktrees — pick distinct feature names. Submodule refs are isolated, so per-worktree submodule-side collisions are fine, but distinct names are cleanest.
- **State directories empty by default:** new worktrees start with no app-state populated. Bootstrap via `BUILD_CMD` or whatever per-project setup you have.
- **Submodule pointer drift in parent:** bumping a submodule SHA on a feat branch makes the parent feat branch record a different submodule SHA than `main`. Normal; merging carries the SHA bump along with the code.
- **`origin/main` staleness in peers when `push=false`:** without `push=true`, peer worktrees' `refs/remotes/origin/main` is *not* updated. Their `refs/heads/main` *is* (merge step 8). For most workflows this is fine — `refs/heads/main` is what `git rebase main` consults. Run `subgrove update <peer>` if you need the remote-tracking ref current.
- **Stashing across submodule changes:** if `git status` shows `M <submodule>`, don't `git stash` to clear the dirty-check. The stash captures an old SHA delta that re-applies as a revert after merge advances HEAD past it. Commit or drop those changes instead.
- **`.subgroverc` is sourced from the repo you're in:** subgrove discovers the superproject from your current directory and sources that repo's `.subgroverc` as shell. Running it inside a repo you don't trust executes that repo's config (and, via `new`, its build chain) — the same trust you already extend by building the project. Don't run subgrove in untrusted repos.

## When to reach for what

- `new` — start a feature.
- `merge` + `remove` — finish a feature.
- `update` — peer worktree fell behind because someone else's merge landed; catch up its view of `main` without doing a fresh merge.
- `list` — sanity-check what's around.
