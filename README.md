# subgrove

Parallel feature development for a git superproject with submodules. One feature, one parent worktree, isolated submodule git dirs, automatic propagation of merges across linked worktrees.

A single shell script. Zero install. Readable in fifteen minutes.

## Is this for you?

`subgrove` sits at the intersection of three properties:

1. **Parent worktree per feature** — each in-progress feature is a separate directory on disk; switching is `cd`, not `git checkout`.
2. **Per-worktree-isolated submodule git dirs** — git's default for submodules under linked worktrees, with all the consequences that follow.
3. **Cross-worktree merge propagation** — merging in one worktree updates every other worktree's view of `main` for each affected submodule.

If your repo has no submodules, a single-repo worktree manager like [gwq](https://github.com/d-kuro/gwq) or [grove](https://github.com/DonKoko/grove) is a cleaner fit. If your world is polyrepo (many independent repos, no parent), [Google `repo`](https://source.android.com/docs/setup/reference/repo) or [gita](https://github.com/nosarthur/gita) covers that. If you have a superproject + submodules and want a daily sync rather than per-feature worktrees, [sync_submodules](https://github.com/shibuido/sync_submodules) is the closest thing.

What's left after subtracting those — _per-feature worktree × isolated submodule git dirs × cross-worktree propagation_ — is the gap subgrove fills. See [docs/design/prior-art.md](docs/design/prior-art.md) for the full survey.

## Install

Via [Homebrew](https://brew.sh) (a personal tap):

```bash
brew install StevenChangZH/tap/subgrove
```

Or grab the single self-contained script and put it on your `$PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/StevenChangZH/subgrove/main/subgrove -o subgrove
chmod +x subgrove && sudo mv subgrove /usr/local/bin/   # or any dir on $PATH
```

`subgrove` discovers the superproject from your current directory (like `git`), so you run it from **inside** the main worktree — it no longer needs to live next to your `.gitmodules`.

Then set up the per-project config from your superproject root:

```bash
subgrove init        # guided: writes .subgroverc and gitignores .worktree/
```

`init` is reconfigure-aware — re-run it any time; it backs up the previous `.subgroverc`. Prefer to hand-edit? Copy [`.subgroverc.example`](.subgroverc.example) to `.subgroverc` at the superproject root instead. (subgrove refuses to run until `.worktree/` is gitignored, which `init` handles for you.)

## Quickstart

```bash
cd /path/to/your/superproject         # run subgrove from inside the repo (like git)
subgrove init                         # one-time: write .subgroverc, gitignore .worktree/

subgrove new my-feature               # create .worktree/my-feature/, branch feat/my-feature
cd .worktree/my-feature
# ... do work, commit ...

subgrove merge my-feature             # FF-merge to main everywhere it needs to land
subgrove merge my-feature push=true   # ... and push origin/main

subgrove remove my-feature            # tear down the worktree (branches retained)
```

## Commands

| Command                               | Purpose                                                           |
| ------------------------------------- | ----------------------------------------------------------------- |
| `subgrove init`                       | Guided setup: write `.subgroverc`, gitignore `.worktree/`.        |
| `subgrove new <name>`                 | Create a worktree; branch parent + submodules; run `BUILD_CHAIN`. |
| `subgrove new <name> touch=<sm>,<sm>` | Branch only the listed submodules.                                |
| `subgrove new <name> touch=none`      | Parent-only branch; submodules detached.                          |
| `subgrove new <name> build=false`     | Skip `BUILD_CHAIN`.                                               |
| `subgrove merge <name>`               | FF-merge feature branch → `main`, propagate to peer worktrees.    |
| `subgrove merge <name> push=true`     | ... and push to `origin`.                                         |
| `subgrove update <name>`              | Catch a peer worktree up to `origin/main` without merging.        |
| `subgrove remove <name>`              | Remove a worktree (refuses if dirty).                             |
| `subgrove remove <name> -f`           | Force-remove, discarding uncommitted work.                        |
| `subgrove list`                       | List worktrees.                                                   |
| `subgrove help`                       | Show usage.                                                       |
| `subgrove --version`                  | Print the version.                                                |

**`merge` is fast-forward-only, and stays that way.** It advances `main` to the feature tip in the parent and every touched submodule — preserving each commit — and refuses (asking you to rebase first) when a fast-forward isn't possible. Squash and merge-commit strategies are intentionally **not supported and not planned**: fast-forward keeps each submodule's `main` on exactly the SHA the parent already records as its gitlink, which is what lets a merge propagate across worktrees as a clean fast-forward. Rationale in [trade-offs.md](docs/design/trade-offs.md).

Long-form reference: [docs/usage.md](docs/usage.md).

## Configuration

`.subgroverc` at the superproject root:

```bash
BUILD_CHAIN=(libfoo libbar)              # submodules to init+build after `new`
BUILD_CMD="./init.sh && ./build.sh"      # build command per BUILD_CHAIN module
COPY_TO_NEW_WORKTREE=(.claude)           # items copied from main → new worktrees
BRANCH_PREFIX="feat/"                    # feature branch prefix
```

Generate it interactively with `subgrove init` (reconfigure-safe), or copy [.subgroverc.example](.subgroverc.example) and edit by hand.

## Design

The script's complexity is a direct consequence of holding three properties simultaneously (per-feature parent worktree, per-worktree-isolated submodule git dirs, cross-worktree main propagation). Each design doc walks through one of those decisions:

- [motivation.md](docs/design/motivation.md) — goals, the submodule git-dir isolation constraint, why parent-worktree-per-feature
- [merge.md](docs/design/merge.md) — two-phase merge + peer propagation
- [update.md](docs/design/update.md) — the `_update_sync` sentinel
- [lifecycle.md](docs/design/lifecycle.md) — `new` (rollback, `--reference`) and `remove`
- [trade-offs.md](docs/design/trade-offs.md) — alternatives considered & rejected
- [implementation-notes.md](docs/design/implementation-notes.md) — cross-cutting invariants
- [prior-art.md](docs/design/prior-art.md) — survey of related tools and the gap subgrove fills
- [distribution.md](docs/design/distribution.md) — repo-root discovery, the single-file build, and Homebrew packaging
- [testing.md](docs/design/testing.md) — how the test suite is structured (+ [testing-local.md](docs/design/testing-local.md) listing every local test case)

## Testing

A real-git test suite lives under `tests/`. No mocks — each scenario builds a fresh superproject + two submodules from scratch via `git init`, runs subgrove against the fixture, and asserts both the command output and the resulting repository state.

```bash
./tests/run.sh --local-only       # local tests only (no GitHub needed)
./tests/run.sh                    # local + remote (requires tests/config.sh)
./tests/run.sh -v test_merge      # verbose, filtered to one test
./tests/run.sh --clean            # wipe tests/run/ (kept fixtures from failed scenarios)
```

Remote tests push to four GitHub repos configured in [`tests/config.sh`](tests/config.sh): three for the with-submodule tier (run `tests/init_remote.sh` once to bootstrap them) and one for the no-submodule tier (`tests/remote-no-sm/` — its fixture lazily bootstraps the baseline on first use, no separate init step). Subsequent test runs reset to the baseline tag rather than rewriting history each time. Fixtures land under `tests/run/` (gitignored).

The patterns the suite uses (pre/post state verification, snapshot equality on refuse, history-ancestor on success, specific err-text and info-line greps, matrix coverage for state-sensitive commands) are documented in [docs/design/testing.md § Test design principles](docs/design/testing.md#test-design-principles). Adding new tests should follow those.

## Development

`subgrove` is a single distributed script assembled from modular source: the `init` wizard lives in [`lib/init.sh`](lib/init.sh) and is inlined into `subgrove` by [`build.sh`](build.sh). Edit `lib/init.sh`, then run `./build.sh` to sync (the test suite rebuilds automatically before running; `./build.sh --check` flags drift). Everything else is edited directly in `subgrove`.

## License

MIT. See [LICENSE](LICENSE).
