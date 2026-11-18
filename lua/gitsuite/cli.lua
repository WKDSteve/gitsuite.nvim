---@module 'gitsuite.cli'
---@brief The read-only command line: status, log, blame and the breaking check as JSON.
---@description
--- What `scripts/gitsuite.lua` runs (`nvim --headless -u NONE -l scripts/gitsuite.lua <command>`): the parts of
--- gitsuite that read a repository, for scripts and git hooks, without a running editor. Every command answers with
--- one JSON document on stdout, in the envelope `docs/cli.md` describes (`schema = "gitsuite.cli/1"`); messages go
--- to stderr. Nothing here writes to a repository or reaches the network, and every git call comes from a module
--- the editor uses too -- no second implementation:
---
---   status   `features.dashboard.status.dashboard_one` (the dashboard's row of a repository)
---   log      `lib.nvim.git.log_async` in `features.plugins.gitlog`'s environment (pinned config, timeout, bounded
---            output)
---   blame    `lib.nvim.git.blame_porcelain_async` (what `:Git blame` reads)
---   breaking the same `from...to` log + `features.plugins.breaking.digest` (`:Git plugins report`'s check)
---
--- Unlike `:Git plugins`, which reads other people's clones, this reads the caller's own repositories: it does not
--- take `gitlog`'s pre-flight that refuses a worktree or a submodule on Windows (its `.git` is a file, which could
--- point at a network share), since the caller names the repository, as with any `git` command.
---
--- `M.run(argv)` returns the exit code: 0 done, 1 a target failed (the others are still in the result), 2 usage,
--- 3 the environment (no git, a timeout).

local config = require("gitsuite.config")

---@class GitSuite.Cli
local M = {}

---The envelope's `schema`: bumped when a field changes meaning or goes away. New fields do not bump it.
M.SCHEMA = "gitsuite.cli/1"

---Default and largest `--count` of `log`.
local LOG_COUNT, LOG_MAX = 20, 5000

---Default and largest `--max` of `breaking`.
local BREAKING_MAX, BREAKING_LIMIT = 1000, 20000

---Default `--timeout`, seconds, for the whole run.
local TIMEOUT_S = 120

---Largest line number of `blame --line` / `--lines`: an integer in `blame -L`'s `%d`, never a float.
local LINE_MAX = 1000000000

local USAGE = [[
usage: nvim --headless -u NONE -l scripts/gitsuite.lua <command> [options]

commands (read-only, JSON on stdout, see docs/cli.md):
  status [<path>...] [--dir=<dir>]          branch, ahead/behind, dirty, state of each repository
                                            (default: the repository of the current directory;
                                            --dir: every repository directly below <dir>)
  log [<path>] [--count=N] [--rev=<rev>] [--files]
                                            the newest N commits (default 20, at most 5000)
  blame <file> [--line=N | --lines=A-B]     who last changed each line
  breaking [<path>] --from=<rev> [--to=<rev>] [--max=N]
                                            the breaking-change check over from..to (to: HEAD)
  help                                      this text

options of every command:
  --timeout=<seconds>                       give up after this long (default 120): exit 3
  --format=json                             the only format (the default)

exit codes: 0 done, 1 a target failed, 2 usage, 3 the environment (no git, a timeout)
]]

-- Arguments ------------------------------------------------------------------

---@class GitSuite.Cli.Args
---@field command string|nil
---@field positional string[]
---@field opts table<string, string|true>

---Splits `argv` into the command, the positional arguments and the `--key[=value]` options.
---@param argv string[]
---@return GitSuite.Cli.Args
local function parse(argv)
  local out = { command = nil, positional = {}, opts = {} }
  local only_positional = false
  for _, a in ipairs(argv) do
    if not only_positional and a == "--" then
      only_positional = true
    elseif not only_positional and a:sub(1, 2) == "--" then
      local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
      if key then
        out.opts[key] = value
      else
        out.opts[a:sub(3)] = true
      end
    elseif not out.command then
      out.command = a
    else
      out.positional[#out.positional + 1] = a
    end
  end
  return out
end

---A usage error: the message goes to stderr, the caller returns 2.
---@class GitSuite.Cli.UsageError
---@field usage string

---@param msg string
local function usage_error(msg)
  error({ usage = msg }, 0)
end

---Fails on every option `known` does not list.
---@param args GitSuite.Cli.Args
---@param known table<string, true>
local function check_options(args, known)
  for key in pairs(args.opts) do
    if not known[key] and key ~= "timeout" and key ~= "format" then
      usage_error(("unknown option --%s for %s"):format(key, args.command))
    end
  end
  local format = args.opts.format
  if format ~= nil and format ~= "json" then usage_error("--format: only json is supported") end
end

---A whole number option in [1, max], or `default`.
---@param args GitSuite.Cli.Args
---@param key string
---@param default integer
---@param max integer
---@return integer
local function int_option(args, key, default, max)
  local v = args.opts[key]
  if v == nil then return default end
  local n = type(v) == "string" and tonumber(v) or nil
  if not n or n ~= math.floor(n) or n < 1 or n > max then
    usage_error(("--%s must be a whole number from 1 to %d"):format(key, max))
  end
  return n --[[@as integer]]
end

---A string option, or nil; `--key` without a value is a usage error.
---@param args GitSuite.Cli.Args
---@param key string
---@return string|nil
local function string_option(args, key)
  local v = args.opts[key]
  if v == true or v == "" then usage_error(("--%s needs a value"):format(key)) end
  return v --[[@as string|nil]]
end

-- Waiting ---------------------------------------------------------------------

---The run's deadline (`vim.uv.now()` milliseconds), set by `M.run`.
local deadline = 0

---Raised when the deadline passes; `M.run` turns it into exit 3.
local TIMEOUT = {}

---How long a timed-out run waits for the killed git to be reported gone before it exits anyway.
local KILL_GRACE_MS = 2000

---Starts an asynchronous call and waits for its callback, at most until the run's deadline.
---
---On the deadline the call's process is killed (`handle.stop`, the whole tree: `taskkill /T` on Windows) before the
---run ends with exit 3: left running, a long `git log` or `blame` outlived the command line as an orphan.
---@param start fun(done: fun(...)): { stop: fun(self: any, signal?: string) }|nil Calls `done` with the results, once; returns the job's handle where it has one
---@return any ...
local function await(start)
  local results, finished = nil, false
  local handle = start(function(...)
    if finished then return end
    finished = true
    results = { n = select("#", ...), ... }
  end)
  local left = deadline - vim.uv.now()
  if
    not finished and (left <= 0 or not vim.wait(left, function()
      return finished
    end, 10))
  then
    if type(handle) == "table" and type(handle.stop) == "function" then
      pcall(handle.stop, handle, "sigkill")
      -- the kill answers through the callback: let it land before the process exits
      vim.wait(KILL_GRACE_MS, function()
        return finished
      end, 10)
    end
    error(TIMEOUT, 0)
  end
  return unpack(results, 1, results.n)
end

-- Paths and revisions -----------------------------------------------------------

---An absolute path with forward slashes, symlinks resolved when the path exists (git reports resolved paths: on
---macOS `/var/...` is `/private/var/...`).
---@param path string
---@return string
local function canonical(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  local real = vim.uv.fs_realpath(abs)
  return vim.fs.normalize(real or abs)
end

---The repository `path` is in (the folder holding `.git`), or nil.
---@param path string
---@return string|nil
local function repo_root(path)
  local p = canonical(path)
  local stat = vim.uv.fs_stat(p)
  if not stat then return nil end
  local root = vim.fs.root(p, ".git")
  return root and vim.fs.normalize(root) or nil
end

---`path` relative to the folder `root` it lies below, or nil when it does not. A root at the top of a drive or of
---the file system ends in `/` already (`E:/`, `/`): its prefix is the root itself, not `root .. "/"`.
---@param path string normalized, absolute
---@param root string normalized, absolute
---@return string|nil
function M.relative(path, root)
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  if #path <= #prefix or path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1)
end

---Resolves a revision the user typed (`HEAD`, `v1.2`, `main~3`, a short hash) to its full commit hash, read-only.
---@param dir string
---@param rev string
---@return string|nil hash
---@return string|nil err
local function resolve_rev(dir, rev)
  -- Not an option to git, whatever it spells.
  if rev:sub(1, 1) == "-" or rev:find("[%z\r\n]") then return nil, "not a revision: " .. rev end
  local gitlog = require("gitsuite.features.plugins.gitlog")
  local args = { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }
  local ok, err = gitlog.check(args)
  if not ok then return nil, err end
  local res = await(function(done)
    return require("lib.nvim.git").run_async(
      gitlog.argv(args),
      gitlog.opts(dir, { read_only = true }),
      done
    )
  end)
  local hash = vim.trim(res.stdout or "")
  if not res.ok or not hash:match("^%x+$") then return nil, "no such commit: " .. rev end
  return hash, nil
end

---`value`, or JSON's `null` where the schema keeps the field.
---@param value any
---@return any
local function or_null(value)
  if value == nil then return vim.NIL end
  return value
end

-- Commands ----------------------------------------------------------------------

---@class GitSuite.Cli.Outcome
---@field result table
---@field errors { target: string, message: string }[]

---@param args GitSuite.Cli.Args
---@return GitSuite.Cli.Outcome
local function cmd_status(args)
  check_options(args, { dir = true })
  local status = require("gitsuite.features.dashboard.status")
  local repos_util = require("gitsuite.features.dashboard.repos")
  local errors, targets = {}, {}

  local dir = string_option(args, "dir")
  if dir then
    local base = canonical(dir)
    local stat = vim.uv.fs_stat(base)
    if not stat or stat.type ~= "directory" then
      usage_error("--dir is not a directory: " .. dir)
    end
    local found = repos_util.is_git_repo(base) and { base } or repos_util.collect_repos(base)
    for _, path in ipairs(found) do
      targets[#targets + 1] = canonical(path)
    end
  end
  local paths = args.positional
  if not dir and #paths == 0 then paths = { "." } end
  for _, path in ipairs(paths) do
    local root = repo_root(path)
    if root then
      targets[#targets + 1] = root
    else
      errors[#errors + 1] = { target = path, message = "not a git repository" }
    end
  end

  local repos = {}
  -- One after another: two short processes each, and a folder of forty clones is no reason for forty at once.
  for _, path in ipairs(targets) do
    local record, err = await(function(done)
      return status.dashboard_one(path, done)
    end)
    if record then
      repos[#repos + 1] = {
        name = vim.fs.basename(path),
        path = path,
        branch = record.branch,
        detached = record.branch == "(detached)",
        has_upstream = record.has_upstream,
        ahead = record.ahead,
        behind = record.behind,
        dirty = record.dirty,
        state = record.state,
        last_commit = or_null(record.last_commit),
      }
    else
      errors[#errors + 1] = { target = path, message = err or "git status failed" }
    end
  end
  return { result = { repos = repos }, errors = errors }
end

---A log entry as the schema has it.
---@param e Lib.Git.LogEntry
---@param with_files boolean
---@return table
local function commit_of(e, with_files)
  local c = {
    sha = e.sha,
    parents = e.parents or {},
    author = e.author or "",
    email = e.email or "",
    author_time = or_null(e.author_time),
    commit_time = or_null(e.commit_time),
    refs = e.refs or {},
    subject = e.subject or "",
    body = e.body or "",
  }
  if with_files then
    local files = {}
    for i, f in ipairs(e.files or {}) do
      files[i] = { status = f.status, path = f.path, orig_path = f.orig_path }
    end
    c.files = files
  end
  return c
end

---@param args GitSuite.Cli.Args
---@return GitSuite.Cli.Outcome
local function cmd_log(args)
  check_options(args, { count = true, rev = true, files = true })
  if #args.positional > 1 then usage_error("log takes one repository") end
  local count = int_option(args, "count", LOG_COUNT, LOG_MAX)
  local with_files = args.opts.files == true
  if args.opts.files ~= nil and not with_files then usage_error("--files takes no value") end
  local rev = string_option(args, "rev") or "HEAD"
  local target = args.positional[1] or "."
  local root = repo_root(target)
  if not root then
    return { result = vim.NIL, errors = { { target = target, message = "not a git repository" } } }
  end

  local hash, rerr = resolve_rev(root, rev)
  if not hash then
    return { result = vim.NIL, errors = { { target = rev, message = rerr or "?" } } }
  end
  local gitlog = require("gitsuite.features.plugins.gitlog")
  local entries, err = await(function(done)
    return require("lib.nvim.git").log_async(
      hash,
      gitlog.opts(root, { max_count = count, name_status = with_files }),
      done
    )
  end)
  if not entries then
    return { result = vim.NIL, errors = { { target = root, message = err or "git log failed" } } }
  end
  local commits = {}
  for i, e in ipairs(entries) do
    commits[i] = commit_of(e, with_files)
  end
  return { result = { repo = root, rev = rev, head = hash, commits = commits }, errors = {} }
end

---@param args GitSuite.Cli.Args
---@return GitSuite.Cli.Outcome
local function cmd_blame(args)
  check_options(args, { line = true, lines = true })
  if #args.positional ~= 1 then usage_error("blame takes exactly one file") end
  local file = args.positional[1]
  local first, last
  local line, lines = args.opts.line, args.opts.lines
  if line ~= nil and lines ~= nil then usage_error("--line and --lines exclude each other") end
  if line ~= nil then
    first = int_option(args, "line", 1, LINE_MAX)
    last = first
  elseif lines ~= nil then
    local a, b = tostring(lines):match("^(%d+)%-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if not a or not b or a < 1 or b < a or b > LINE_MAX then
      usage_error(("--lines must be A-B with 1 <= A <= B <= %d"):format(LINE_MAX))
    end
    first, last = a, b
  end

  local path = canonical(file)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return { result = vim.NIL, errors = { { target = file, message = "no such file" } } }
  end
  local root = repo_root(path)
  if not root then
    return { result = vim.NIL, errors = { { target = file, message = "not in a git repository" } } }
  end
  local rel = M.relative(path, root)
  if not rel then
    return { result = vim.NIL, errors = { { target = file, message = "not below " .. root } } }
  end

  local git = require("lib.nvim.git")
  local entries, err = await(function(done)
    return git.blame_porcelain_async(rel, { dir = root, first = first, last = last }, done)
  end)
  if not entries then
    return { result = vim.NIL, errors = { { target = rel, message = err or "git blame failed" } } }
  end
  local out = {}
  for i, e in ipairs(entries) do
    local uncommitted = e.sha:match("^0+$") ~= nil
    out[i] = {
      line = e.line,
      sha = e.sha,
      uncommitted = uncommitted,
      author = or_null(e.author),
      author_time = or_null(e.author_time),
      summary = or_null(e.summary),
    }
  end
  return { result = { repo = root, file = rel, lines = out }, errors = {} }
end

---The removed Lua files of a commit (what `breaking` reads as "a module is gone"), from its file list -- the same
---rule as `features.plugins.report`.
---@param files Lib.Git.LogFile[]|nil
---@return string[]|nil
local function gone_of(files)
  local gone = {}
  for _, f in ipairs(files or {}) do
    if f.status == "D" and type(f.path) == "string" and f.path:match("^lua/.+%.lua$") then
      gone[#gone + 1] = f.path
    end
  end
  return #gone > 0 and gone or nil
end

---@param args GitSuite.Cli.Args
---@return GitSuite.Cli.Outcome
local function cmd_breaking(args)
  check_options(args, { from = true, to = true, max = true })
  if #args.positional > 1 then usage_error("breaking takes one repository") end
  local from_rev = string_option(args, "from")
  if not from_rev then usage_error("breaking needs --from=<rev>") end
  local to_rev = string_option(args, "to") or "HEAD"
  local max = int_option(args, "max", BREAKING_MAX, BREAKING_LIMIT)
  local target = args.positional[1] or "."
  local root = repo_root(target)
  if not root then
    return { result = vim.NIL, errors = { { target = target, message = "not a git repository" } } }
  end

  local from, ferr = resolve_rev(root, from_rev --[[@as string]])
  if not from then
    return { result = vim.NIL, errors = { { target = from_rev, message = ferr or "?" } } }
  end
  local to, terr = resolve_rev(root, to_rev)
  if not to then
    return { result = vim.NIL, errors = { { target = to_rev, message = terr or "?" } } }
  end

  local gitlog = require("gitsuite.features.plugins.gitlog")
  local breaking = require("gitsuite.features.plugins.breaking")
  -- `from...to` with --left-right: only the `>` side is new in `to`; one more than `max` tells "cut off".
  local git = require("lib.nvim.git")
  local entries, err = await(function(done)
    return git.log_async(
      from .. "..." .. to,
      gitlog.opts(
        root,
        { left_right = true, topo_order = true, name_status = true, max_count = max + 1 }
      ),
      done
    )
  end)
  if not entries then
    return { result = vim.NIL, errors = { { target = root, message = err or "git log failed" } } }
  end
  local commits = {}
  for _, e in ipairs(entries) do
    if e.side == ">" then
      commits[#commits + 1] =
        { sha = e.sha, subject = e.subject or "", body = e.body or "", gone = gone_of(e.files) }
    end
  end
  local truncated = #entries > max or #commits > max
  while #commits > max do
    commits[#commits] = nil
  end
  local behind = 0
  for _, e in ipairs(entries) do
    if e.side == "<" then behind = behind + 1 end
  end

  local recent = await(function(done)
    return git.log_async(to, gitlog.opts(root, { max_count = 100, no_merges = true }), done)
  end)
  local convention
  if recent then
    local subjects = {}
    for i, e in ipairs(recent) do
      subjects[i] = e.subject or ""
    end
    convention = breaking.convention(subjects)
  end

  local cfg = config.get().plugins.breaking or {}
  local v = vim.version()
  local digest = breaking.digest(commits, {
    ignore = cfg.ignore,
    collapse_repeats = cfg.collapse_repeats,
    nvim = { major = v.major, minor = v.minor, patch = v.patch },
    positions = not truncated and behind == 0,
  })

  local function shas(indices)
    local out = {}
    for i, idx in ipairs(indices) do
      out[i] = commits[idx].sha
    end
    return out
  end

  local list = {}
  for i, c in ipairs(commits) do
    local verdict = digest.verdicts[i]
    list[i] = {
      sha = c.sha,
      subject = c.subject,
      tier = or_null(verdict.tier),
      rules = verdict.rules,
      score = verdict.score,
      revert = verdict.revert == true,
      ignored = verdict.ignored == true,
      position = digest.positions and digest.positions[i] or vim.NIL,
      group = digest.grouped[i] or vim.NIL,
    }
  end
  local groups = {}
  for i, g in ipairs(digest.groups) do
    groups[i] = {
      kind = g.kind,
      key = g.key,
      label = g.label or "",
      members = shas(g.members),
      breaking = g.breaking,
    }
  end

  return {
    result = {
      repo = root,
      from = from,
      to = to,
      total = #commits,
      truncated = truncated,
      rolled_back = behind,
      convention = convention and {
        conventional = convention.conventional,
        total = convention.total,
        recognized = or_null(convention.recognized),
      } or vim.NIL,
      commits = list,
      sure = shas(digest.sure),
      probable = shas(digest.probable),
      hints = shas(digest.hints),
      groups = groups,
    },
    errors = {},
  }
end

---@type table<string, fun(args: GitSuite.Cli.Args): GitSuite.Cli.Outcome>
local COMMANDS = {
  status = cmd_status,
  log = cmd_log,
  blame = cmd_blame,
  breaking = cmd_breaking,
}

-- Entry ---------------------------------------------------------------------------

---`value` with every string in it made valid UTF-8 (`lib.lua.strings.safe.utf8`: a byte that is none becomes `?`).
---A commit message, an author or a path is raw bytes in whatever encoding its author used, and a JSON string must
---be UTF-8 -- one Latin-1 subject would make the whole answer unreadable for a strict parser.
---@param value any
---@return any
function M.valid_utf8(value)
  if type(value) == "string" then return require("lib.lua.strings.safe").utf8(value) end
  if type(value) ~= "table" or value == vim.NIL then return value end
  local out = {}
  for k, v in pairs(value) do
    out[M.valid_utf8(k)] = M.valid_utf8(v)
  end
  -- the metatable says what the JSON is: `vim.empty_dict()` encodes as `{}`, without it as `[]`
  return setmetatable(out, getmetatable(value))
end

---Writes one line to `stream`.
---@param stream file*
---@param text string
local function say(stream, text)
  stream:write(text, "\n")
end

---Runs one command line. Results go to stdout as one JSON document, messages to stderr.
---@param argv string[]
---@return integer code 0 done, 1 a target failed, 2 usage, 3 the environment
function M.run(argv)
  local args = parse(argv or {})
  local command = args.command
  if command == nil or command == "help" or args.opts.help then
    say(command == nil and io.stderr or io.stdout, USAGE)
    return command == nil and 2 or 0
  end
  local handler = COMMANDS[command]
  if not handler then
    say(io.stderr, ("error: unknown command %s\n\n%s"):format(command, USAGE))
    return 2
  end
  if vim.fn.executable("git") ~= 1 then
    say(io.stderr, "error: git is not available in PATH")
    return 3
  end

  local ok, outcome = pcall(function()
    local timeout = int_option(args, "timeout", TIMEOUT_S, 86400)
    deadline = vim.uv.now() + timeout * 1000
    return handler(args)
  end)
  if not ok then
    if outcome == TIMEOUT then
      say(io.stderr, ("error: %s did not finish within --timeout"):format(command))
      return 3
    end
    if type(outcome) == "table" and outcome.usage then
      say(io.stderr, ("error: %s\n\n%s"):format(outcome.usage, USAGE))
      return 2
    end
    error(outcome, 0)
  end

  for _, e in ipairs(outcome.errors) do
    say(io.stderr, ("%s: %s"):format(e.target, e.message))
  end
  say(
    io.stdout,
    vim.json.encode({
      schema = M.SCHEMA,
      command = command,
      ok = #outcome.errors == 0,
      result = M.valid_utf8(outcome.result),
      errors = M.valid_utf8(outcome.errors),
    })
  )
  return #outcome.errors == 0 and 0 or 1
end

return M
