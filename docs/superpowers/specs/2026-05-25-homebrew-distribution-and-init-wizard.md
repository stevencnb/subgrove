# Action plan: Homebrew distribution + `subgrove init` wizard

Status: **draft / awaiting review** · Date: 2026-05-25 · Temporary working plan (not a durable design note — see step 9 for the permanent `docs/design/distribution.md`).

## Problem

subgrove cannot be installed onto `PATH` (Homebrew, or a manual symlink) as written, because one variable conflates two distinct concerns:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # subgrove:33
```

`SCRIPT_DIR` is used as **the superproject root** everywhere: sourcing `.subgroverc` (`subgrove:43-46`), reading `.gitmodules` (`subgrove:166`), placing worktrees, and every `git -C`/`cd`. `README.md:21` and `usage.md:7` codify the assumption ("place subgrove at the superproject root… running it from anywhere else won't find the submodule list").

Under Homebrew the script lives at `/opt/homebrew/bin/subgrove` (a symlink into the Cellar), so `dirname $0` resolves to the Homebrew bin dir — never the user's repo. The tool would look for `.subgroverc` and `.gitmodules` next to itself and fail. Copying the script back into the repo defeats the purpose of installing it.

A second-order problem follows: once the script is on `PATH`, `.subgroverc.example` is no longer sitting next to the user's repo (it's in the Cellar), so "copy the example and edit it" stops being a usable config story.

## Goals

1. `subgrove` runs correctly when invoked from `PATH` (Homebrew or manual symlink), operating on whatever superproject the user is standing in.
2. A guided, per-project config bootstrap that works without the example file being adjacent to the repo.
3. Installable now via a personal Homebrew tap; a documented path to homebrew-core later.
4. The distributed artifact stays **a single self-contained script** ("a single-script tool", per CLAUDE.md) even though source is modular.
5. No regression to the existing command contract or the user-data invariants (`docs/design/user-data-rules.md`).

## Non-goals

- homebrew-core submission itself (documented, not executed — the repo lacks the notability/release history core requires today).
- CI, man pages, shell completions. Flagged below, not built.
- Porting off bash. Implementation stays shell-only; bash 3.2 compatibility retained (the build tool too).

## Design

### 1. Repo-root discovery (the Homebrew fix)

Stop treating the script's location as the repo root. Discover the repo at runtime from the current directory:

- **Repo root** — `git rev-parse --show-toplevel`, taken only after the existing main-worktree gate (`assert_main_worktree`, `subgrove:118`) passes. Replaces `SCRIPT_DIR`-as-root in every command.

There is **no install-root / `lib/` resolution at runtime** — the single-file build (§2) inlines everything, so the running script is self-contained and never sources a sibling file or follows its own symlink.

`.subgroverc` sourcing moves from script load-time (`subgrove:43-46`) to **per-command, after repo discovery**. Consequences:

- `help` and `--version` work outside any git repo (they touch no repo).
- Repo commands work from any subdirectory of the main worktree — the git model. `git rev-parse --show-toplevel` from `super/src/` still yields `super/`.
- Running from a linked worktree (or a subdir of one) still refuses via `assert_main_worktree`, now evaluated against the invocation CWD rather than the script's location. Strictly more correct.

New startup sequence for repo-touching commands (`new`/`merge`/`update`/`remove`/`list`):

1. `assert_in_git_repo` (CWD is inside a work tree).
2. `assert_main_worktree` (git-dir == git-common-dir).
3. `ROOT="$(git rev-parse --show-toplevel)"`.
4. Source `$ROOT/.subgroverc` if present (else built-in defaults).
5. Proceed as today, with `ROOT` wherever `SCRIPT_DIR` was.

`help` / `--version` skip all five. `init` runs 1–3 but **not** 4 (it creates the rc) and does **not** require `.worktree/` to be gitignored (it offers to set that up).

### 2. Single-file build from modular source

The distributed `subgrove` is one self-contained script; the wizard is authored in its own file and inlined by a build step.

```
subgrove          # THE single script: dispatcher + core cmds + a GENERATED region   → ships as-is
lib/init.sh       # wizard source — the canonical place to edit the wizard
build.sh          # syncs subgrove's generated region from lib/init.sh (idempotent)
```

- `subgrove` carries a machine-maintained region:

  ```bash
  # >>> generated from lib/init.sh — edit there, then run ./build.sh >>>
  cmd_init() { … inlined wizard … }
  # <<< end generated <<<
  ```

  Everything outside the markers (dispatcher, core commands, shared helpers) is hand-edited normally. The region is the **only** machine-maintained part.
- `build.sh` replaces the marker region in `subgrove` with the body of `lib/init.sh` (bash 3.2-safe: `awk`/`sed`, no concatenation gymnastics). Idempotent — a no-op when already in sync.
- **Runtime never sources anything.** No `LIBDIR`, no symlink-following. The chosen "no lib-hunting" property.
- **Drift guard.** `build.sh --check` exits non-zero if `subgrove`'s region differs from a fresh build of `lib/init.sh`. `tests/run.sh` runs `./build.sh` at startup so the suite always reflects current `lib/init.sh`; a stale committed `subgrove` then shows as a git diff. (CI enforcement of `--check` is a later follow-up, not in scope.)
- `subgrove` (the built single file) stays committed, so `git clone && ./subgrove …` works with no build step for users.

### 3. `subgrove init` wizard (authored in `lib/init.sh`)

A guided, step-by-step bootstrap. Reuses the repo-discovery from §1. Inlined into `subgrove` at build (§2).

- **Reconfigure-aware.** If `.subgroverc` already exists, it is sourced and its values become the default shown at each prompt; the wizard writes back. If absent, built-in defaults seed the prompts. An existing file is backed up (`.subgroverc.bak`) before writing. ("Respects that this file exists in every project.")
- **Steps**, each a single `read -r` prompt with the current/default value pre-shown:
  1. `BRANCH_PREFIX` (default `feat/`).
  2. `BUILD_CHAIN` — enumerates submodules via the existing `list_all_submodules` (`subgrove:165`: `git config --file <root>/.gitmodules --get-regexp 'submodule\..*\.path'`) and lets the user pick which to build; on a flat repo (no `.gitmodules`) prints "no submodules detected" and leaves it empty.
  3. `BUILD_CMD` — prompted only if `BUILD_CHAIN` is non-empty.
  4. `COPY_TO_NEW_WORKTREE` — comma/space-separated list of paths.
- **`.gitignore` offer.** subgrove refuses to run unless `.worktree/` is gitignored (`subgrove:127`); the wizard detects this and offers to append the entry and stage it.
- **Non-interactive fallback.** When stdin is not a TTY, or `--defaults` / `-y` is passed, the wizard writes the commented template with defaults and makes the `.gitignore` edit without prompting (so CI and scripted setup don't hang).
- **Output.** A fully commented `.subgroverc` (the annotations currently in `.subgroverc.example`), written to the repo root.
- bash 3.2-safe: `read -r`/`read -p`, no associative arrays, no `mapfile`/`readarray`, no `${var,,}`.

### 4. Versioning + `--version`

- A `VERSION` constant near the top of `subgrove`.
- Dispatch `--version` / `version` (alongside `-h`/`--help`) to print it; no repo required.
- Cut tag **`v0.1.0`** — the repo has zero tags today, and the formula's release tarball URL points at the tag.

### 5. Homebrew tap (now) + core (documented, later)

- New repo **`StevenChangZH/homebrew-tap`**, file `Formula/subgrove.rb`:
  - `url` → `v0.1.0` release tarball, with `sha256`.
  - `install`: `bin.install "subgrove"` — one file, because the tarball already contains the built single script. No `libexec`, no symlink-to-libexec.
  - `test do`: run `#{bin}/subgrove --version` and assert it matches.
- Install UX: `brew install StevenChangZH/tap/subgrove`.
- A short "path to homebrew-core" subsection in the distribution doc: core needs notability (stars/forks/watchers) and a stable release history the repo doesn't have yet; revisit once it gains traction. Exact current thresholds confirmed at submission time.

### 6. Docs + repo updates

- `README.md`: lead the Install section with the brew tap; keep the curl one-liner as a fallback; remove the literal `<owner>` placeholder (`README.md:24`, `:31`).
- `usage.md`: setup section reflects run-from-inside-repo and `subgrove init`; drop "place at superproject root."
- `CLAUDE.md`: reframe sacred item #2 — the distributed artifact is still **one script** ("single-script tool" preserved), but it is now *built from modular source* (`lib/init.sh` + `build.sh`); edit the wizard there and rebuild. Note the install model is now Homebrew-tap, not drop-in-only.
- `CONTRIBUTING`/README dev note: "edit `lib/init.sh`, run `./build.sh`" so contributors don't hand-edit the generated region.
- One-line trust note (README or usage gotchas): on `PATH`, `subgrove` sources the `.subgroverc` of whatever repo you're standing in — defensible (you already run its build chain) but worth stating.
- Keep `.subgroverc.example` as the canonical template source (the wizard's embedded comments are generated to match it).

## Command-surface delta

Sacred surface today: `new`, `merge`, `update`, `remove`, `list`, `help`. This plan **adds** (additive, non-breaking):

- `init` — new subcommand.
- `--version` / `version` — version reporting.

No existing command, flag shape, or behavior is removed or changed. `merge -f` stays excluded.

## Behavioral consequences

1. **Run-from-inside-repo.** You now invoke `subgrove` from within the main worktree (any subdir), like `git`. Previously the script's physical location determined the target repo. This is the intended PATH-tool model.
2. **Modular source, single artifact.** The shipped/installed `subgrove` is still one script; the wizard is authored in `lib/init.sh` and inlined by `build.sh`. CLAUDE.md item #2 reframed accordingly — "single-script tool" stays true.
3. **`.subgroverc` trust.** On `PATH`, the sourced rc comes from the CWD's repo, a mild trust escalation versus a script that physically lived in that repo. Documented.

## Testing impact

- **Existing suite stays green for the refactor:** all four fixtures symlink the script (`fixture_local.sh:100`, `fixture_local_no_sm.sh:68`, `fixture_remote.sh:162`, `fixture_remote_no_sm.sh:228`) and every test `cd`s into `$FIXTURE_SUPER` before invoking. git-from-CWD discovery yields the fixture super; the symlinked `subgrove` is self-contained (init inlined), so no runtime lib-resolution is exercised or needed.
- **`tests/run.sh` runs `./build.sh` at startup** so the suite always reflects current `lib/init.sh`.
- **`test_linked_worktree.sh` stays green** but its inline comments about `SCRIPT_DIR`/`dirname $0` (lines 6-10, 21-22) go stale and must be refreshed to describe CWD-based discovery.
- **New tests required:**
  - `init` happy path: fresh repo (no `.subgroverc`) → `--defaults` writes a valid rc + `.gitignore` entry; assert contents and that `subgrove new` then works.
  - `init` reconfigure: existing `.subgroverc` → values load as defaults, `.bak` created, write-back correct.
  - `init` non-TTY safety: piped stdin doesn't hang; produces the default template.
  - `init` on a flat repo (no-sm tier): `BUILD_CHAIN` step degrades to "no submodules."
  - build drift: `./build.sh --check` passes on a clean tree (guards against committing a stale generated region).
- **Fixture work:** current fixtures pre-write `.subgroverc`, `.gitignore`, and `.worktree/`. `init` tests need a variant (or a pre-step) that omits those so the wizard has something to create.
- Run `tests/run.sh --local-only` after each phase; full suite (incl. remote tiers) before tagging `v0.1.0`.

## Out of scope (YAGNI)

CI workflow (incl. enforcing `build.sh --check`), man page, shell completions, the actual homebrew-core PR. Each is a reasonable follow-up; none is required to install and configure subgrove via a tap.

## Action plan (ordered)

Dependency order; each item is independently testable.

1. **Root-discovery refactor.** Add `assert_in_git_repo` + repo-root discovery; replace `SCRIPT_DIR`-as-root with `ROOT`; move `.subgroverc` sourcing per-command. Keep all current behavior. — `tests/run.sh --local-only` must stay green.
2. **`--version`.** Add `VERSION` constant + dispatch.
3. **`lib/init.sh` + `build.sh` + generated region.** Author the wizard in `lib/init.sh`; add the marker region to `subgrove`; write `build.sh` (sync + `--check`); wire `init` into the dispatcher; run `build.sh` to populate the region.
4. **`tests/run.sh` builds first; add init tests + fixture variant + drift test.** Per Testing impact.
5. **Refresh stale test comments** in `test_linked_worktree.sh` (and any other `SCRIPT_DIR`-referencing comments surfaced by the refactor).
6. **Docs.** README (incl. dev "edit lib/init.sh, run build.sh" note), usage.md, CLAUDE.md, `.subgroverc` trust note.
7. **Full test run** (local + remote tiers).
8. **Tag `v0.1.0`** and create the GitHub release (provides the tarball + sha256).
9. **`docs/design/distribution.md`** — durable design note (repo-root discovery, single-file build + generated region, init reconfigure semantics, tap-vs-core), per CLAUDE.md's "every nontrivial choice has a design note" rule.
10. **Homebrew tap repo** — `StevenChangZH/homebrew-tap` with `Formula/subgrove.rb` (`bin.install "subgrove"`); verify `brew install StevenChangZH/tap/subgrove` end-to-end.

Steps 1–9 land in this repo; step 10 is the separate tap repo (depends on the tag/release from step 8).

## Deferred verifications (resolve at plan/implementation time)

- Confirm the `v0.1.0` release tarball includes the built `subgrove` with an in-sync generated region (build before tagging).
- Current homebrew-core acceptable-formulae thresholds (for the "core later" doc section).
