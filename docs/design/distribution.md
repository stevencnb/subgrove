# Distribution: PATH install, the single-file build, and Homebrew

subgrove is distributed as a single self-contained script installed on `$PATH` (Homebrew, or a manual copy). Two changes made that possible without giving up the modular source the `init` wizard wanted. This note records why each is shaped the way it is.

## Repo-root discovery (not script location)

The original script set `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` and used it as **the superproject root** — sourcing `.subgroverc`, reading `.gitmodules`, placing worktrees, every `git -C`. That conflates two unrelated things: where the script file lives, and which repo to operate on. It only holds when the script sits at the repo root, which a PATH install (`/opt/homebrew/bin/subgrove`) never does.

`discover_root` replaces it: it asserts the main worktree (`assert_main_worktree`), sets the global `ROOT` from `git rev-parse --show-toplevel` — the top of whatever repo the **current directory** is in — and sources `$ROOT/.subgroverc`. Every repo-touching command calls `discover_root` first.

Consequences, all intended:

- **Run from inside the repo, like git.** The superproject is found from the CWD, so you invoke `subgrove` from within the main worktree (any subdirectory). The script's own location is irrelevant. This is the inverse of the old contract: `tests/local/test_new.sh::new_from_other_cwd` pins the new one (a CWD outside any repo refuses with "not in a git repo" and touches nothing), and `tests/local/test_path_invocation.sh` pins the positive case (script symlinked outside the repo, invoked via PATH from inside it, also from a subdirectory).
- **`.subgroverc` sourcing is per-command, after discovery** — not at script load. So `help` and `--version` work outside any repo (they call neither `discover_root` nor anything needing `ROOT`). The built-in defaults (`BUILD_CHAIN=()`, `BRANCH_PREFIX="feat/"`, …) are still assigned at load; `discover_root` layers the repo's `.subgroverc` over them. A *missing* `.subgroverc` is fatal for repo-touching commands: `discover_root` stops with a "run `subgrove init`" hint rather than silently operating on those built-in defaults, so an un-set-up repo fails loudly. `init` alone opts out (`discover_root --allow-missing-config`) since its job is to write the file.
- **Trust escalation.** Because the sourced `.subgroverc` comes from the CWD's repo, running `subgrove` inside an untrusted repo runs that repo's config (and, via `new`, its build chain) as shell. This is the same trust you extend by building the project, but it is now CWD-scoped rather than tied to a script you placed yourself. Documented in `docs/usage.md` gotchas.

`assert_main_worktree` is otherwise unchanged and still the linked-worktree guard; it now evaluates the invocation CWD rather than the script's directory, which is strictly more correct — it catches "you're standing in a linked worktree."

## Single distributed file, modular source

CLAUDE.md keeps "a single-script tool" as the *shipped* artifact, but the `init` wizard is large enough to want its own source file. Both hold via a build step rather than a runtime split:

- The wizard is authored in `lib/init.sh` (defines `cmd_init` and its `_init_*` helpers; reuses `err`/`info`/`list_all_submodules`/`discover_root` and the config defaults from the parent script, since it is inlined into it).
- `subgrove` carries a **generated region** between two marker comments. `build.sh` replaces everything between them with the current contents of `lib/init.sh`. The committed, shipped, executed `subgrove` is therefore one self-contained file with the wizard inlined.
- **Nothing is sourced at runtime.** No `lib/` lookup, no `$0` symlink-following — the inlined region means the running script needs no siblings. (An earlier design considered shipping `lib/` alongside and resolving it at runtime; the build step removes that complexity from every invocation and keeps the install a single file.)

`build.sh` is idempotent (re-running with an unchanged `lib/init.sh` reproduces the file byte-for-byte) and offers `--check`, which exits non-zero when the region is out of sync — the guard against committing a stale build. `tests/run.sh` runs `build.sh` before any fixture symlinks the script, so the suite always exercises current `lib/init.sh`; `tests/local/test_build.sh` exercises the build tool itself (idempotency + drift detection) against a throwaway copy.

Workflow: **edit `lib/init.sh`, run `./build.sh`.** Never hand-edit the generated region in `subgrove` — `build.sh` overwrites it.

## `init` reconfigure semantics and the `.worktree/` gotcha

`subgrove init` seeds its prompts from `discover_root` (so an existing `.subgroverc` becomes the defaults), writes a commented `.subgroverc`, and backs any existing one up to `.subgroverc.bak`. Two robustness points:

- **`.worktree/` must exist on disk for the ignore check to pass.** `git check-ignore -q .worktree` matches the trailing-slash `.worktree/` pattern only when `.worktree` is an actual directory (verified empirically: absent dir → no match, exit 1). So `init` both appends the gitignore entry *and* `mkdir -p`s the directory, guaranteeing the first `new` clears `assert_worktrees_ignored`.
- **Non-interactive when it must be.** `--defaults`/`-y`, or any non-TTY stdin, takes defaults without prompting — so `init` never blocks a script or CI run.

## Homebrew packaging

A personal tap now, homebrew-core later:

- **Tap** (`StevenChangZH/homebrew-tap`, `Formula/subgrove.rb`): `url` points at a tagged release tarball; `install` is `bin.install "subgrove"` (one file — the tarball already contains the built script); `test do` runs `subgrove --version`. Install: `brew install StevenChangZH/tap/subgrove`.
- **homebrew-core** is deferred: it requires notability and a stable release history the repo doesn't yet have. Revisit once it gains traction; the formula is essentially the same, submitted to `homebrew/homebrew-core` instead of the tap.

The release tarball must be built (`./build.sh`) and in sync before tagging, so the shipped `subgrove` carries the inlined wizard.
