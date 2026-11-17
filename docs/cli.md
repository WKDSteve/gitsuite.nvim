# Reading a repository without the editor

`scripts/gitsuite.lua` answers what gitsuite reads from a repository — its status, its log, who changed a line,
which commits of a range break something — as JSON, for scripts and git hooks, without a running editor.
It only reads: nothing here writes to a repository or reaches the network.

```sh
nvim --headless -u NONE -l scripts/gitsuite.lua status                       # the repository you are in
nvim --headless -u NONE -l scripts/gitsuite.lua status --dir="$REPOS_DIR"    # every repository directly below
nvim --headless -u NONE -l scripts/gitsuite.lua log --count=5 --files
nvim --headless -u NONE -l scripts/gitsuite.lua blame lua/foo.lua --lines=10-20
nvim --headless -u NONE -l scripts/gitsuite.lua breaking --from=v1.2.0       # v1.2.0..HEAD
```

Give the script's full path when you run it from elsewhere; paths and the repository are taken relative to the
current directory. It needs `git` and `lib.nvim`, which it finds through `$LIB_NVIM_DIR`, `$LIB_NVIM_PATH`,
`$REPOS_DIR/lib.nvim`, `.deps/lib.nvim`, a checkout next to the plugin, or lazy.nvim's data folder (the wrapper is a
copy of lib.nvim's `templates/cli_script.lua`).

A headless run loads no user config: options given to `setup()` in the editor (`plugins.breaking.ignore`, ...) are
not seen; the defaults apply.

## Commands

| Command | What it answers |
| --- | --- |
| `status [<path>...] [--dir=<dir>]` | One entry per repository: the row `:Git dashboard` shows for it. Without arguments the repository of the current directory; a `<path>` inside a repository means that repository. `--dir`: every repository directly below `<dir>` (or `<dir>` itself when it is one), the same rule as `dashboard.base_dir`. Read one after another. |
| `log [<path>] [--count=N] [--rev=<rev>] [--files]` | The newest `N` commits (default 20, at most 5000) reachable from `<rev>` (default `HEAD`); `--files` adds the changed files of each. |
| `blame <file> [--line=N \| --lines=A-B]` | Who last changed each line of `<file>` (or of the given lines); a line changed in the work tree is `uncommitted`. |
| `breaking [<path>] --from=<rev> [--to=<rev>] [--max=N]` | The breaking-change check of `:Git plugins report` over the commits in `<to>` (default `HEAD`) that `<from>` does not have, at most `N` (default 1000, at most 20000). |
| `help` | The usage, on stdout. |

Options every command takes: `--timeout=<seconds>` (default 120; exceeded: exit 3) and `--format=json` (the only
format, and the default). `--` ends the options: a path after it may start with `--`. A `<rev>` is anything
`git rev-parse` reads (`HEAD~3`, `v1.2.0`, `origin/main`, a short hash), never something starting with `-`.

## Exit codes

| Code | Meaning | stdout |
| --- | --- | --- |
| 0 | Done. | The answer, `ok: true`. |
| 1 | A target failed: a path that is no repository, a revision that does not exist, a git call that failed. The others are still in `result`. Each failure is also a line on stderr. | The answer, `ok: false`. |
| 2 | Usage: an unknown command or option, a value out of range, a missing `--from`. | Nothing; the reason and the usage on stderr. |
| 3 | The environment: no `git`, no `lib.nvim`, the run did not finish within `--timeout`, an internal error. | Nothing. |

## The answer (schema `gitsuite.cli/1`)

Every answer is one JSON document on one line of stdout:

```json
{
  "schema": "gitsuite.cli/1",
  "command": "status",
  "ok": true,
  "result": { "...": "per command, below" },
  "errors": [ { "target": "nowhere", "message": "not a git repository" } ]
}
```

- `schema` names this layout. It changes (`gitsuite.cli/2`) only when a field is removed or changes its meaning; a
  field that is added keeps it, so a reader should ignore fields it does not know.
- `ok` is `errors` being empty. `result` is `null` when the command had nothing to answer with (`log` of a path that
  is no repository).
- Paths are absolute, with forward slashes, symlinks resolved (git's own view: `/private/var/...` on macOS).
- Times are Unix seconds. A field the schema lists but git could not tell is `null`, never left out.
- Object keys come in no particular order.

### `status`

```json
{ "repos": [ {
  "name": "gitsuite.nvim", "path": "E:/repos/gitsuite.nvim",
  "branch": "main", "detached": false, "has_upstream": true,
  "ahead": 0, "behind": 2, "dirty": 1,
  "state": "dirty", "last_commit": 1794908898
} ] }
```

| Field | |
| --- | --- |
| `branch` | The current branch; `"(detached)"` on a detached HEAD (then `detached` is `true`). |
| `ahead`, `behind` | Commits ahead of and behind the upstream, as of the last fetch (0 without upstream). |
| `dirty` | Changed and untracked entries of the work tree. |
| `state` | `clean`, `dirty`, `ahead`, `behind` or `diverged` (a dirty work tree wins). |
| `last_commit` | The commit time of HEAD; `null` in a repository without commits. |

### `log`

```json
{ "repo": "...", "rev": "HEAD", "head": "<the full hash rev resolved to>",
  "commits": [ {
    "sha": "...", "parents": ["..."], "author": "...", "email": "...",
    "author_time": 1794908898, "commit_time": 1794908898,
    "refs": ["HEAD -> main", "tag: v1.0"], "subject": "...", "body": "...",
    "files": [ { "status": "D", "path": "lua/x.lua" } ]
  } ] }
```

Newest first. `files` only with `--files`: `status` is git's letter (`A`, `M`, `D`, `T`; `R100` with `orig_path` for
a rename); a merge lists none. `refs` is git's decoration list.

### `blame`

```json
{ "repo": "...", "file": "lua/foo.lua",
  "lines": [ { "line": 10, "sha": "...", "uncommitted": false,
               "author": "...", "author_time": 1794908898, "summary": "..." } ] }
```

`file` is relative to `repo`. An `uncommitted` line has the all-zero `sha`.

### `breaking`

```json
{ "repo": "...", "from": "<hash>", "to": "<hash>", "total": 12, "truncated": false, "rolled_back": 0,
  "convention": { "conventional": 87, "total": 100, "recognized": true },
  "commits": [ { "sha": "...", "subject": "feat!: drop mod.x", "tier": "sure", "rules": ["bang"],
                 "score": 0, "revert": false, "ignored": false, "position": 12, "group": null } ],
  "sure": ["<sha>"], "probable": [], "hints": [],
  "groups": [ { "kind": "repeat", "key": "...", "label": "...", "members": ["<sha>"], "breaking": 0 } ] }
```

| Field | |
| --- | --- |
| `commits` | Every commit of `to` that `from` lacks, newest first, each with its verdict. |
| `tier` | `sure` (a `!` or a `BREAKING CHANGE:` footer), `probable`, `hint`, `bulk` (a parser bump), or `null`. |
| `rules`, `score` | The ids of the rules that matched and the weight of the hint rules (see [architecture.md](architecture.md)). |
| `sure`, `probable`, `hints` | The hashes per tier, what a reader looks at first (`hints` best score first); commits folded into a group are listed there, not here. |
| `groups` | Folded runs: every parser bump (`parsers`), or the same subject at least `plugins.breaking.collapse_repeats` times (`repeat`). `group` of a commit is its 1-based index here. |
| `position` | "commit i of n" (1 = oldest), only when the list is the complete range in topological order; otherwise `null`. |
| `truncated` | More than `--max` commits: the list holds the newest `--max`. |
| `rolled_back` | Commits `from` has that `to` lacks (a force-push, a rollback); not classified. |
| `convention` | Whether the project writes conventional commits, judged on the newest 100 subjects of `to`; `recognized` is `null` with too few. |

## What it uses

No second implementation: `status` is `features/dashboard/status.lua`'s row of one repository, `log` and
`breaking` read through `lib.nvim.git` in the environment of `features/plugins/gitlog.lua` (repository config that
starts programs pinned off, a timeout, bounded output), `breaking` classifies with
`features/plugins/breaking.lua`, `blame` is `lib.nvim.git.blame_porcelain_async`. Unlike `:Git plugins`, which reads
other people's clones and refuses a worktree or a submodule on Windows (its `.git` is a file that could point at a
network share), the command line reads the repositories you name, worktrees included.
