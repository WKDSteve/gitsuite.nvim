---@module 'gitsuite.features.hooks'
---@brief Prepared git hooks a user can install into a repository with one command.
---@description
--- Two hooks ship in `scripts/hooks/`:
---
---   no-claude-trailer  commit-msg  strips `Co-Authored-By:` trailers that name Claude or Anthropic
---   large-files        pre-commit  warns about staged files above a limit and lets the committer decide
---
--- Each is installed as a ONE-LINE wrapper that calls the script from this checkout (`exec bash "<script>" "$@"`),
--- so a later change to the script needs no reinstall. The wrapper carries a marker comment; that marker is how
--- gitsuite recognises its own hook.
---
--- Two rules the installer never breaks:
---
--- * **A hook that is not ours is never overwritten** (or removed). It is reported as `foreign`.
--- * **A versioned hooks folder is written to only when asked.** A repository whose own config sets
---   `core.hooksPath` (`.husky`, `scripts/hooks`) is not touched by default: the result is `manual`, with the exact
---   line to add to the hook there. With `into_versioned` that line goes into the hook file of that folder (created
---   if missing), and the path of the script into the repository's local config (`gitsuite.hook.<id>`, never
---   committed): no commit, `core.hooksPath` untouched. The line itself holds no path (no user name lands in a
---   shared repository) and does nothing where the key is not set or names no file (another clone, another
---   machine). A
---   `core.hooksPath` set only globally is reported in `hooks_path` with a note, because whether the repository's
---   own `hooks/` folder is read then depends on that global folder.
---
--- Everything goes through argv-only `git` calls; no hook is executed here.

local M = {}

---@class Gitsuite.Hooks.Entry
---@field id string
---@field hook "commit-msg"|"pre-commit"
---@field script string file name under `scripts/hooks/`
---@field marker string comment line that marks a wrapper as gitsuite's
---@field desc string

---@type Gitsuite.Hooks.Entry[]
local CATALOG = {
  {
    id = "no-claude-trailer",
    hook = "commit-msg",
    script = "commit-msg-no-claude-trailer.sh",
    marker = "# gitsuite-hook: no-claude-trailer",
    desc = "commit-msg: removes Co-Authored-By trailers that name Claude or Anthropic",
  },
  {
    id = "large-files",
    hook = "pre-commit",
    script = "pre-commit-large-files.sh",
    marker = "# gitsuite-hook: large-files",
    desc = "pre-commit: warns about staged files above 5 MB and asks (LARGE_FILE_MB, git config largefiles.action)",
  },
}

---The shipped hooks.
---@return Gitsuite.Hooks.Entry[]
function M.catalog()
  return vim.deepcopy(CATALOG)
end

---@param id string
---@return Gitsuite.Hooks.Entry|nil
function M.find(id)
  for _, e in ipairs(CATALOG) do
    if e.id == id then return e end
  end
  return nil
end

---Absolute path of a shipped script (forward slashes: the wrapper is read by bash on every platform).
---@param entry Gitsuite.Hooks.Entry
---@return string
function M.script_path(entry)
  local here = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))))
  return vim.fs.normalize(root .. "/scripts/hooks/" .. entry.script)
end

---Deadline of every git call here.
local TIMEOUT_MS = 10000

---Runs `git -C <repo> <args>` and hands its result to `done`. Two of them exist, so that one sequence of steps
---serves both forms: `sync_runner` waits (the Lua API, scripts, tests), `async_runner` answers from the event loop
---(the `:Git hooks` commands, which must not freeze the editor).
---@alias Gitsuite.Hooks.Runner fun(args: string[], done: fun(res: Lib.Git.RunResult))

---@param repo string
---@return Gitsuite.Hooks.Runner
local function sync_runner(repo)
  return function(args, done)
    done(require("lib.nvim.git").run(args, { dir = repo, timeout_ms = TIMEOUT_MS }))
  end
end

---@param repo string
---@return Gitsuite.Hooks.Runner
local function async_runner(repo)
  return function(args, done)
    require("lib.nvim.git").run_async(args, { dir = repo, timeout_ms = TIMEOUT_MS }, done)
  end
end

---The keys `inspect` reads in one `git config` call: the hooks folder and gitsuite's own keys (git compares the
---canonical, lower-case names).
local CONFIG_PATTERN = [[^core\.hookspath$|^gitsuite\.hook\.]]

---`path` with every existing part resolved (symlinks, `/var` -> `/private/var`); the parts that do not exist
---yet are kept as they are. nil when not even the root exists.
---@param path string
---@return string|nil
local function real(path)
  local cur, rest = vim.fs.normalize(path), {}
  while not vim.uv.fs_realpath(cur) do
    local up = vim.fs.dirname(cur)
    if up == cur then return nil end
    table.insert(rest, 1, vim.fs.basename(cur))
    cur = up
  end
  local base = vim.fs.normalize(assert(vim.uv.fs_realpath(cur)))
  return #rest > 0 and (base .. "/" .. table.concat(rest, "/")) or base
end

---Whether `path` lies in the folder `top` (or is it), after resolving both.
---@param path string
---@param top string
---@return boolean
local function inside(path, top)
  local p, t = real(path), real(top)
  if not p or not t then return false end
  if vim.fn.has("win32") == 1 then
    p, t = p:lower(), t:lower()
  end
  return p == t or p:sub(1, #t + 1) == (t:sub(-1) == "/" and t or t .. "/")
end

---@param path string
---@return string
local function read(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local text = f:read("*a")
  f:close()
  return text
end

---@class Gitsuite.Hooks.Inspection
---@field repo string
---@field hooks_dir string|nil the repository's own hooks folder (`<git-common-dir>/hooks`)
---@field hooks_path string|nil `core.hooksPath` as configured, when set
---@field hooks_path_local boolean `core.hooksPath` is set in the repository's own config
---@field versioned_dir string|nil the folder `core.hooksPath` names, absolute, when it is set in the repository's own
---  config and lies in its work tree (a folder outside, a shared `~/hooks`, is not versioned with the repository)
---@field entries { id: string, hook: string, state: "absent"|"ours"|"foreign" }[] what is in `hooks_dir`
---@field versioned { id: string, hook: string, file: string, state: "in-versioned"|"manual" }[]|nil only with a
---  `versioned_dir`: whether the hook file there holds gitsuite's line. Kept apart from `entries`, which `uninstall`
---  deletes whole files by: nothing in the versioned folder is ever deleted that way.
---@field hook_config table<string, string> gitsuite's keys in the repository's local config (`gitsuite.hook.<id>`,
---  lower case) and their values
---@field err string|nil

---Why a git call that printed nothing failed: git missing, the deadline, or not a repository.
---@param res Lib.Git.RunResult
---@param repo string
---@return string
local function failure(res, repo)
  if res.timed_out then return ("git timed out after %d ms in %s"):format(TIMEOUT_MS, repo) end
  if res.code == -1 then return "git could not be started: " .. vim.trim(res.stderr or "") end
  return "not a git repository: " .. repo
end

---The inspection from the two answers of `inspect_with`.
---@param repo string
---@param rp Lib.Git.RunResult `rev-parse --git-common-dir --show-toplevel`
---@param cfg Lib.Git.RunResult `config --show-scope --get-regexp CONFIG_PATTERN`
---@return Gitsuite.Hooks.Inspection
local function build(repo, rp, cfg)
  local result = { repo = repo, entries = {}, hooks_path_local = false, hook_config = {} }
  -- A bare repository (or the .git folder itself) has no work tree: rev-parse prints the common dir, then fails
  -- on --show-toplevel. The first line still counts; the top is then the folder itself, as before.
  local lines = vim.split(rp.stdout or "", "\n", { plain = true, trimempty = true })
  local common = lines[1] and vim.trim(lines[1]) or ""
  if common == "" then
    result.err = failure(rp, repo)
    return result
  end
  local top = (rp.code == 0 and lines[2]) and vim.trim(lines[2]) or repo
  if not (common:match("^/") or common:match("^%a:[/\\]")) then common = repo .. "/" .. common end
  result.hooks_dir = vim.fs.normalize(common .. "/hooks")

  -- `scope<TAB>key value`, in the order git reads its files: the last core.hooksPath wins, as with --get. Exit 1
  -- means none of the keys is set; any other failure is read as "not set" too, as the single calls did.
  if cfg.code == 0 then
    for _, line in ipairs(vim.split(cfg.stdout or "", "\n", { plain = true, trimempty = true })) do
      local scope, key, value = line:gsub("\r$", ""):match("^(%S+)\t(%S+) ?(.*)$")
      if key == "core.hookspath" then
        result.hooks_path = value
        if scope == "local" then result.hooks_path_local = true end
      elseif key and scope == "local" then
        result.hook_config[key:lower()] = value
      end
    end
  end
  if result.hooks_path == "" then result.hooks_path = nil end
  if result.hooks_path_local and result.hooks_path then
    -- git reads a relative core.hooksPath from the top of the work tree, and expands a leading ~.
    local dir = result.hooks_path:gsub("^~", (vim.fn.expand("~"):gsub("%%", "%%%%")))
    if not (dir:match("^/") or dir:match("^%a:[/\\]")) then dir = top .. "/" .. dir end
    dir = vim.fs.normalize(dir)
    -- husky 9 points core.hooksPath at `.husky/_`: generated, ignored by git, rewritten on every install, and its
    -- wrappers end in `exit` after running the hook of the same name in `.husky/`. That one is the versioned file.
    if vim.fs.basename(dir) == "_" and vim.fs.basename(vim.fs.dirname(dir)) == ".husky" then
      dir = vim.fs.dirname(dir)
    end
    if inside(dir, top) then result.versioned_dir = dir end
  end

  for _, e in ipairs(CATALOG) do
    local file = result.hooks_dir .. "/" .. e.hook
    local state = "absent"
    if vim.uv.fs_stat(file) then
      state = read(file):find(e.marker, 1, true) and "ours" or "foreign"
    end
    result.entries[#result.entries + 1] = { id = e.id, hook = e.hook, state = state }
  end
  if result.versioned_dir then
    result.versioned = {}
    for _, e in ipairs(CATALOG) do
      local file = result.versioned_dir .. "/" .. e.hook
      local st = vim.uv.fs_lstat(file)
      local has = st and st.type == "file" and read(file):find(e.marker, 1, true) ~= nil
      result.versioned[#result.versioned + 1] =
        { id = e.id, hook = e.hook, file = file, state = has and "in-versioned" or "manual" }
    end
  end
  return result
end

---Two git calls, started together: the folders (`rev-parse`) and every config key that matters (`config`).
---@param repo string
---@param run Gitsuite.Hooks.Runner
---@param done fun(info: Gitsuite.Hooks.Inspection)
local function inspect_with(repo, run, done)
  local rp, cfg
  -- +1 for this function itself: a runner that answers at once must not finish before the second call started.
  local pending = 3
  local function settle()
    pending = pending - 1
    if pending == 0 then done(build(repo, rp, cfg)) end
  end
  run({ "rev-parse", "--git-common-dir", "--show-toplevel" }, function(res)
    rp = res
    settle()
  end)
  run({ "config", "--show-scope", "--get-regexp", CONFIG_PATTERN }, function(res)
    cfg = res
    settle()
  end)
  settle()
end

---What is installed in `repo`. Waits for git; the commands use `inspect_async`.
---@param repo string
---@return Gitsuite.Hooks.Inspection
function M.inspect(repo)
  local info
  inspect_with(repo, sync_runner(repo), function(i)
    info = i
  end)
  return info
end

---`inspect` without waiting: `done` is called from the event loop.
---@param repo string
---@param done fun(info: Gitsuite.Hooks.Inspection)
function M.inspect_async(repo, done)
  inspect_with(repo, async_runner(repo), done)
end

---@class Gitsuite.Hooks.Result
---@field repo string
---@field id string
---@field status "installed"|"updated"|"unchanged"|"removed"|"absent"|"foreign"|"manual"|"error"
---@field message string
---@field snippet string|nil for `manual`: the line to add to the hook in the repository's own hooks folder

---@class Gitsuite.Hooks.Opts
---@field into_versioned boolean|nil write the line into the hook of a versioned `core.hooksPath` folder instead of
---  reporting it as `manual` (never commits, never changes the config)

---The wrapper's text.
---@param entry Gitsuite.Hooks.Entry
---@return string
local function wrapper(entry)
  return ('#!/usr/bin/env bash\n%s\nexec bash "%s" "$@"\n'):format(
    entry.marker,
    M.script_path(entry)
  )
end

---The local git config key that holds the path of the script for the line of `entry`.
---@param entry Gitsuite.Hooks.Entry
---@return string
function M.config_key(entry)
  return "gitsuite.hook." .. entry.id
end

---The line for a hook in a versioned folder. It holds no path: the folder is shared with every other clone (and
---maybe the public), so the script's path is read from the local config, where only this clone has it. It runs the
---script only where that key names a file, survives `sh -e` (husky) when the key is missing, and passes a failure
---on, so a hook shell without `-e` still stops the commit.
---@param entry Gitsuite.Hooks.Entry
---@return string
local function snippet(entry)
  return ('gitsuite_hook=$(git config --get %s || true); if [ -n "$gitsuite_hook" ] && [ -f "$gitsuite_hook" ]; then bash "$gitsuite_hook" "$@" || exit $?; fi   %s'):format(
    M.config_key(entry),
    entry.marker
  )
end

---A change of the local config, made after the files are written: `run_writes` runs them one after another (git
---locks the config file while it writes) and turns a failure into an error of `r`.
---@class Gitsuite.Hooks.Write
---@field args string[]
---@field r Gitsuite.Hooks.Result
---@field err string|nil the message of a failure; nil: a failure does not matter

---Queue setting the local config key of `entry` to the script of this checkout, unless it already is.
---@param info Gitsuite.Hooks.Inspection
---@param entry Gitsuite.Hooks.Entry
---@param r Gitsuite.Hooks.Result
---@param writes Gitsuite.Hooks.Write[]
---@return boolean changed
local function set_config(info, entry, r, writes)
  local want, key = M.script_path(entry), M.config_key(entry)
  if info.hook_config[key:lower()] == want then return false end
  writes[#writes + 1] = {
    args = { "config", "--local", key, want },
    r = r,
    err = "cannot set " .. key .. " in the local config",
  }
  return true
end

---@param writes Gitsuite.Hooks.Write[]
---@param run Gitsuite.Hooks.Runner
---@param done fun()
local function run_writes(writes, run, done)
  local i = 0
  local function next_write()
    i = i + 1
    local w = writes[i]
    if not w then return done() end
    run(w.args, function(res)
      if res.code ~= 0 and w.err then
        w.r.status, w.r.message = "error", w.err
      end
      next_write()
    end)
  end
  next_write()
end

---The shebang of a hook file `into_versioned` creates.
local NEW_HOOK = "#!/usr/bin/env sh\n"

---@param path string
---@param text string
---@return string|nil err
local function write(path, text)
  local f, err = io.open(path, "wb")
  if not f then return "cannot write " .. path .. ": " .. tostring(err) end
  f:write(text)
  f:close()
  return nil
end

---Why the hook file `file` must not be written to, or nil. A symlink is never followed: it could point anywhere
---(`~/.bashrc`), and a dangling one would be created there.
---@param file string
---@return string|nil
local function refuse(file)
  local st = vim.uv.fs_lstat(file)
  if st and st.type == "link" then return file .. " is a symlink: left alone" end
  if st and st.type ~= "file" then return file .. " is not a file: left alone" end
  return nil
end

---Whether a hook line ends the script, so that nothing after it runs: `exec ...`, `exit`, `exit 0`, `exit $?`.
---@param line string
---@return boolean
local function ends_script(line)
  local l = line:gsub("\r$", "")
  return l:match("^%s*exec%s") ~= nil or l:match("^%s*exit%s") ~= nil or l:match("^%s*exit$") ~= nil
end

---Add the line of `entry` to the hook file in the versioned folder; before a last `exec` or `exit` line, after
---which it would never run. A line of an older install (another path to the script) is replaced.
---@param info Gitsuite.Hooks.Inspection
---@param entry Gitsuite.Hooks.Entry
---@param r Gitsuite.Hooks.Result
---@param writes Gitsuite.Hooks.Write[]
local function add_to_versioned(info, entry, r, writes)
  local file = info.versioned_dir .. "/" .. entry.hook
  local why = refuse(file)
  if why then
    r.status, r.message = "error", why
    return
  end
  local exists = vim.uv.fs_lstat(file) ~= nil
  local text = exists and read(file) or NEW_HOOK
  local want = snippet(entry)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end

  local found, current = nil, true
  for i = #lines, 1, -1 do
    if lines[i]:find(entry.marker, 1, true) then
      if lines[i]:gsub("\r$", "") ~= want then current = false end
      if found then table.remove(lines, found) end
      found = i
    end
  end
  if found and current and select(2, text:gsub(vim.pesc(entry.marker), "")) == 1 then
    if set_config(info, entry, r, writes) then
      r.status, r.message =
        "updated",
        ("the line is in %s; set %s in the local config"):format(file, M.config_key(entry))
    else
      r.status, r.message = "unchanged", "already in " .. file
    end
    return
  end

  if found then
    lines[found] = want
  else
    local at = #lines + 1
    for i = #lines, 1, -1 do
      if lines[i]:match("%S") then
        if ends_script(lines[i]) then at = i end
        break
      end
    end
    table.insert(lines, at, want)
  end
  vim.fn.mkdir(info.versioned_dir, "p")
  local err = write(file, table.concat(lines, "\n") .. "\n")
  if err then
    r.status, r.message = "error", err
    return
  end
  if not exists then pcall(vim.uv.fs_chmod, file, tonumber("755", 8)) end
  set_config(info, entry, r, writes)
  r.status = found and "updated" or "installed"
  r.message = ("%s %s (core.hooksPath = %s is versioned: review the change and commit it yourself)"):format(
    found and "updated the line in" or "added to",
    file,
    info.hooks_path
  )
end

---Take the line of `entry` out of the hook file in the versioned folder; a file that held nothing else and was
---created by `add_to_versioned` goes with it.
---@param info Gitsuite.Hooks.Inspection
---@param entry Gitsuite.Hooks.Entry
---@param r Gitsuite.Hooks.Result
---@param writes Gitsuite.Hooks.Write[]
local function remove_from_versioned(info, entry, r, writes)
  local file = info.versioned_dir .. "/" .. entry.hook
  local why = refuse(file)
  if why then
    r.status, r.message = "error", why
    return
  end
  if info.hook_config[M.config_key(entry):lower()] ~= nil then
    writes[#writes + 1] = { args = { "config", "--local", "--unset", M.config_key(entry) }, r = r }
  end
  local text = read(file)
  if not text:find(entry.marker, 1, true) then
    r.status, r.message = "absent", "not in " .. file
    return
  end
  local kept = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    if not l:find(entry.marker, 1, true) then kept[#kept + 1] = l end
  end
  local rest = table.concat(kept, "\n")
  if rest == NEW_HOOK then
    vim.uv.fs_unlink(file)
    r.status, r.message = "removed", "removed " .. file .. " (it held only gitsuite's line)"
    return
  end
  local err = write(file, rest)
  if err then
    r.status, r.message = "error", err
    return
  end
  r.status, r.message =
    "removed", "removed gitsuite's line from " .. file .. " (versioned: commit it yourself)"
end

---The files part of `install`; the config changes it needs go to `writes`.
---@param info Gitsuite.Hooks.Inspection
---@param ids string[]|nil
---@param opts Gitsuite.Hooks.Opts|nil
---@param writes Gitsuite.Hooks.Write[]
---@return Gitsuite.Hooks.Result[]
local function apply_install(info, ids, opts, writes)
  local repo = info.repo
  local results = {}
  for _, e in ipairs(CATALOG) do
    if not ids or vim.tbl_contains(ids, e.id) then
      local file = info.hooks_dir .. "/" .. e.hook
      local entry_state = "absent"
      for _, s in ipairs(info.entries) do
        if s.id == e.id then entry_state = s.state end
      end
      local r = { repo = repo, id = e.id }
      if info.hooks_path_local and info.versioned_dir and opts and opts.into_versioned then
        add_to_versioned(info, e, r, writes)
      elseif info.hooks_path_local and not info.versioned_dir then
        r.status = "manual"
        r.message = (
          "core.hooksPath = %s in this repository points outside its work tree: nothing was written "
          .. "(not even with --into-versioned). Run git config --local %s '%s' once and add this line "
          .. "to the %s hook there:"
        ):format(info.hooks_path, M.config_key(e), M.script_path(e), e.hook)
        r.snippet = snippet(e)
      elseif info.hooks_path_local then
        r.status = "manual"
        r.message = (
          "core.hooksPath = %s in this repository: its hooks folder is versioned, nothing was written. "
          .. "Run git config --local %s '%s' once and add this line to the %s hook there "
          .. "(or run again with --into-versioned, which does both):"
        ):format(info.hooks_path, M.config_key(e), M.script_path(e), e.hook)
        r.snippet = snippet(e)
      elseif entry_state == "foreign" then
        r.status = "foreign"
        r.message = ("%s exists and is not gitsuite's: left alone"):format(file)
      elseif entry_state == "ours" and read(file) == wrapper(e) then
        r.status = "unchanged"
        r.message = "already installed"
      else
        vim.fn.mkdir(info.hooks_dir, "p")
        local f, err = io.open(file, "wb")
        if not f then
          r.status, r.message = "error", "cannot write " .. file .. ": " .. tostring(err)
        else
          f:write(wrapper(e))
          f:close()
          pcall(vim.uv.fs_chmod, file, tonumber("755", 8))
          r.status = "installed"
          r.message = (
            info.hooks_path
            and ("installed in %s (core.hooksPath = %s is set globally: the hook runs only if that folder hands over to this one)"):format(
              file,
              info.hooks_path
            )
          ) or ("installed: " .. file)
        end
      end
      results[#results + 1] = r
    end
  end
  return results
end

---The files part of `uninstall`; the config changes it needs go to `writes`.
---@param info Gitsuite.Hooks.Inspection
---@param ids string[]|nil
---@param opts Gitsuite.Hooks.Opts|nil
---@param writes Gitsuite.Hooks.Write[]
---@return Gitsuite.Hooks.Result[]
local function apply_uninstall(info, ids, opts, writes)
  local repo = info.repo
  local results = {}
  for _, e in ipairs(CATALOG) do
    if not ids or vim.tbl_contains(ids, e.id) then
      local file = info.hooks_dir .. "/" .. e.hook
      local state = "absent"
      for _, s in ipairs(info.entries) do
        if s.id == e.id then state = s.state end
      end
      local r = { repo = repo, id = e.id }
      if info.hooks_path_local and info.versioned_dir and opts and opts.into_versioned then
        remove_from_versioned(info, e, r, writes)
      elseif state == "ours" then
        vim.uv.fs_unlink(file)
        r.status, r.message = "removed", "removed " .. file
      elseif state == "foreign" then
        r.status, r.message = "foreign", file .. " is not gitsuite's: left alone"
      else
        r.status, r.message = "absent", "not installed"
      end
      results[#results + 1] = r
    end
  end
  return results
end

---Inspect, change the files, then the config: the steps of `install` and `uninstall`, for either runner.
---@param repo string
---@param run Gitsuite.Hooks.Runner
---@param apply fun(info: Gitsuite.Hooks.Inspection, writes: Gitsuite.Hooks.Write[]): Gitsuite.Hooks.Result[]
---@param done fun(results: Gitsuite.Hooks.Result[])
local function act_with(repo, run, apply, done)
  inspect_with(repo, run, function(info)
    if info.err then
      return done({ { repo = repo, id = "*", status = "error", message = info.err } })
    end
    local writes = {}
    -- A failure while writing the files (a folder that cannot be created) must still answer: from the event
    -- loop a raised error would leave :Git hooks without any report.
    local ok, results = pcall(apply, info, writes)
    if not ok then
      return done({ { repo = repo, id = "*", status = "error", message = tostring(results) } })
    end
    run_writes(writes, run, function()
      done(results)
    end)
  end)
end

---@param repo string
---@param apply fun(info: Gitsuite.Hooks.Inspection, writes: Gitsuite.Hooks.Write[]): Gitsuite.Hooks.Result[]
---@return Gitsuite.Hooks.Result[]
local function act_sync(repo, apply)
  local out
  act_with(repo, sync_runner(repo), apply, function(results)
    out = results
  end)
  return out
end

---Install hooks into one repository. Never overwrites a foreign hook; leaves a repository with its own
---`core.hooksPath` alone and says what to add by hand, unless `opts.into_versioned` asks to add it there. Waits
---for git; `:Git hooks install` uses `install_async`.
---@param repo string
---@param ids string[]|nil nil = every shipped hook
---@param opts Gitsuite.Hooks.Opts|nil
---@return Gitsuite.Hooks.Result[]
function M.install(repo, ids, opts)
  return act_sync(repo, function(info, writes)
    return apply_install(info, ids, opts, writes)
  end)
end

---`install` without waiting: `done` is called from the event loop.
---@param repo string
---@param ids string[]|nil
---@param opts Gitsuite.Hooks.Opts|nil
---@param done fun(results: Gitsuite.Hooks.Result[])
function M.install_async(repo, ids, opts, done)
  act_with(repo, async_runner(repo), function(info, writes)
    return apply_install(info, ids, opts, writes)
  end, done)
end

---Remove gitsuite's own hooks from one repository; a foreign hook is never removed. With `opts.into_versioned`
---and a versioned `core.hooksPath`, gitsuite's line is taken out of the hook file there instead. Waits for git;
---`:Git hooks uninstall` uses `uninstall_async`.
---@param repo string
---@param ids string[]|nil nil = every shipped hook
---@param opts Gitsuite.Hooks.Opts|nil
---@return Gitsuite.Hooks.Result[]
function M.uninstall(repo, ids, opts)
  return act_sync(repo, function(info, writes)
    return apply_uninstall(info, ids, opts, writes)
  end)
end

---`uninstall` without waiting: `done` is called from the event loop.
---@param repo string
---@param ids string[]|nil
---@param opts Gitsuite.Hooks.Opts|nil
---@param done fun(results: Gitsuite.Hooks.Result[])
function M.uninstall_async(repo, ids, opts, done)
  act_with(repo, async_runner(repo), function(info, writes)
    return apply_uninstall(info, ids, opts, writes)
  end, done)
end

---`each` without waiting: one repository after the other (each one's git calls are few, and starting a process
---blocks on Windows), `done` once with every result, in the order of `repos`.
---@param repos string[]
---@param fn fun(repo: string, ids: string[]|nil, opts: Gitsuite.Hooks.Opts|nil, done: fun(results: Gitsuite.Hooks.Result[]))
---@param ids string[]|nil
---@param opts Gitsuite.Hooks.Opts|nil
---@param done fun(results: Gitsuite.Hooks.Result[])
function M.each_async(repos, fn, ids, opts, done)
  local all, i = {}, 0
  local function next_repo()
    i = i + 1
    if not repos[i] then return done(all) end
    fn(repos[i], ids, opts, function(results)
      vim.list_extend(all, results)
      next_repo()
    end)
  end
  next_repo()
end

---Run install/uninstall over several repositories.
---@param repos string[]
---@param fn fun(repo: string, ids: string[]|nil, opts: Gitsuite.Hooks.Opts|nil): Gitsuite.Hooks.Result[]
---@param ids string[]|nil
---@param opts Gitsuite.Hooks.Opts|nil
---@return Gitsuite.Hooks.Result[]
function M.each(repos, fn, ids, opts)
  local all = {}
  for _, repo in ipairs(repos) do
    vim.list_extend(all, fn(repo, ids, opts))
  end
  return all
end

---A report, one line per result (plus the snippet of a `manual` one).
---@param results Gitsuite.Hooks.Result[]
---@return string
function M.format(results)
  local lines = {}
  for _, r in ipairs(results) do
    lines[#lines + 1] = ("%s  %s  %s: %s"):format(
      r.status,
      vim.fn.fnamemodify(r.repo, ":t"),
      r.id,
      r.message
    )
    if r.snippet then lines[#lines + 1] = "    " .. r.snippet end
  end
  return table.concat(lines, "\n")
end

return M
