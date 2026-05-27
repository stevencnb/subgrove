# subgrove

A single-script tool for parallel feature development across a git superproject and its submodules. Per-feature parent worktree × per-worktree-isolated submodule git dirs × cross-worktree merge propagation.

## Read these first

- `docs/design/` — why every nontrivial choice in the script exists. Each file closes a specific failure mode (two-phase merge, peer propagation, `--reference` for submodule object sharing, the `_update_sync` sentinel in `update`, the rollback trap in `new`). Read the matching note before changing the script.
- `docs/design/prior-art.md` — survey + gap analysis. Explains the niche.
- `docs/design/distribution.md` — repo-root discovery (git toplevel, not script location), the single-file build, and Homebrew packaging. Read before touching `discover_root`, `build.sh`, or `lib/init.sh`.

## The niche, restated

Mature tools cover one or two of (parent worktree per feature) × (isolated submodule git dirs) × (cross-worktree merge propagation), never the intersection. If a change makes subgrove useful for repos without submodules, ask whether it remains useful for repos with submodules. If the answer is "less so", reject the change. subgrove is not on a path to becoming another generic single-repo worktree manager.

## What is sacred

1. **Public command surface.** `new`, `init`, `merge`, `update`, `remove`, `list`, `help`, `--version` with the same flag shapes: `touch=`, `build=`, `push=`, `-f` only on `remove` (`merge -f` was deliberately removed; rationale in `docs/design/trade-offs.md`), `--defaults`/`-y` only on `init`. Downstream projects will reference subgrove by version; breaking the contract is expensive.
2. **Shell-only, single distributed script.** The shipped `subgrove` is one self-contained file ("a single-script tool"), but it is *built from modular source*: the `init` wizard is authored in `lib/init.sh` and inlined into `subgrove`'s generated region by `build.sh`. Edit `lib/init.sh`, then run `./build.sh` (the test suite rebuilds first; `./build.sh --check` flags drift) — never hand-edit the generated region. Everything else is edited directly in `subgrove`. Don't port to Go/Python/Node for v1 — that's a legitimate v2 move if maintenance pain shows up, but it hasn't. The macOS bash 3.2 compatibility comments (`set -eo pipefail` without `-u` is intentional) stay; `build.sh` and `lib/init.sh` are bash-3.2-safe too.

## Configuration, not hardcoding

Project-specific settings live in `.subgroverc` at the superproject root, discovered at runtime via `discover_root` (git toplevel) and sourced. Knobs are `WORKTREES_DIR`, `BUILD_CHAIN`, `BUILD_CMD`, `COPY_TO_NEW_WORKTREE`, `BRANCH_PREFIX`. `subgrove init` generates the file interactively; `.subgroverc.example` is the hand-edit template. If you find yourself wanting to hardcode a submodule name, branch prefix, or build command into the script, put it in the config instead.

A missing `.subgroverc` is fatal for every repo-touching command — `discover_root` errors with a "run `subgrove init`" hint rather than falling back to built-in defaults. Only `init` (which *writes* the file) opts out, via `discover_root --allow-missing-config`; `help`/`--version` never call `discover_root`. `WORKTREES_DIR` is repo-relative and must stay gitignored (`assert_worktrees_ignored`); the script is parameterized on it everywhere, so don't reintroduce a literal `.worktree`.

The `.gitmodules` parser inside `list_all_submodules` gives you the submodule list dynamically. Don't assume a particular count.

## Testing: verify resulting state through `status`

`subgrove status` is the user's primary, frequently-run state-inspection command, so the test suite treats it as the canonical **state oracle**. Every test of a state-changing command (`new`, `merge`, `update`, `remove`) must also assert the resulting repository state through `status` — via the `assert_status` / `assert_status_absent` helpers in `tests/lib/assert.sh` — in **every tier** (`local`, `local-no-sm`, `remote`, `remote-no-sm`) and in the matrix/push variants, not just a local happy path. If a command leaves the repo in state X, `status` must report X; after a successful `remove`, `status` must stop listing the worktree. This is a hard rule for new command tests and for any change to command behavior — it *complements*, never replaces, the precise SHA/ref assertions (`assert_branch_at`, `assert_commits_ahead`). Per-command patterns: `docs/design/testing.md` §15.

## Don't

- Drop a recent addition without reading the matching design note. Each closes a real failure mode.
- Add features beyond what the immediate task requires.
- Add a runtime beyond bash.
- Re-introduce `merge -f` (rationale in `docs/design/trade-offs.md`).
- Commit action-plan / brainstorming spec docs (e.g. under `docs/superpowers/`, which is gitignored). They're scaffolding for a single change — fold any durable rationale into `docs/design/` and let the plan itself go.
