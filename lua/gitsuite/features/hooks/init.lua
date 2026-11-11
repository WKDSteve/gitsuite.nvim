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
--- * **A versioned hooks folder is never written to.** A repository whose own config sets `core.hooksPath`
---   (`.husky`, `scripts/hooks`) is not touched at all: the result is `manual`, with the exact line to add to the
---   hook there. A `core.hooksPath` set only globally is reported in `hooks_path` with a note, because whether the
---   repository's own `hooks/` folder is read then depends on that global folder.
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

---@param repo string
---@param ... string git arguments
---@return string|nil stdout trimmed, nil on a non-zero exit
local function git(repo, ...)
  local res = vim.system({ "git", "-C", repo, ... }, { text = true, timeout = 10000 }):wait()
  if res.code ~= 0 then return nil end
  return vim.trim(res.stdout or "")
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
---@field entries { id: string, hook: string, state: "absent"|"ours"|"foreign" }[]
---@field err string|nil

---What is installed in `repo`.
---@param repo string
---@return Gitsuite.Hooks.Inspection
function M.inspect(repo)
  local result = { repo = repo, entries = {}, hooks_path_local = false }
  local common = git(repo, "rev-parse", "--git-common-dir")
  if not common then
    result.err = "not a git repository: " .. repo
    return result
  end
  if not (common:match("^/") or common:match("^%a:[/\\]")) then common = repo .. "/" .. common end
  result.hooks_dir = vim.fs.normalize(common .. "/hooks")
  result.hooks_path = git(repo, "config", "--get", "core.hooksPath")
  if result.hooks_path == "" then result.hooks_path = nil end
  result.hooks_path_local = git(repo, "config", "--local", "--get", "core.hooksPath") ~= nil

  for _, e in ipairs(CATALOG) do
    local file = result.hooks_dir .. "/" .. e.hook
    local state = "absent"
    if vim.uv.fs_stat(file) then
      state = read(file):find(e.marker, 1, true) and "ours" or "foreign"
    end
    result.entries[#result.entries + 1] = { id = e.id, hook = e.hook, state = state }
  end
  return result
end

---@class Gitsuite.Hooks.Result
---@field repo string
---@field id string
---@field status "installed"|"unchanged"|"removed"|"absent"|"foreign"|"manual"|"error"
---@field message string
---@field snippet string|nil for `manual`: the line to add to the hook in the repository's own hooks folder

---The wrapper's text.
---@param entry Gitsuite.Hooks.Entry
---@return string
local function wrapper(entry)
  return ('#!/usr/bin/env bash\n%s\nexec bash "%s" "$@"\n'):format(
    entry.marker,
    M.script_path(entry)
  )
end

---@param entry Gitsuite.Hooks.Entry
---@return string
local function snippet(entry)
  return ('bash "%s" "$@"   %s'):format(M.script_path(entry), entry.marker)
end

---Install hooks into one repository. Never overwrites a foreign hook; leaves a repository with its own
---`core.hooksPath` alone and says what to add by hand.
---@param repo string
---@param ids string[]|nil nil = every shipped hook
---@return Gitsuite.Hooks.Result[]
function M.install(repo, ids)
  local info = M.inspect(repo)
  local results = {}
  if info.err then return { { repo = repo, id = "*", status = "error", message = info.err } } end

  for _, e in ipairs(CATALOG) do
    if not ids or vim.tbl_contains(ids, e.id) then
      local file = info.hooks_dir .. "/" .. e.hook
      local entry_state = "absent"
      for _, s in ipairs(info.entries) do
        if s.id == e.id then entry_state = s.state end
      end
      local r = { repo = repo, id = e.id }
      if info.hooks_path_local then
        r.status = "manual"
        r.message = (
          "core.hooksPath = %s in this repository: its hooks folder is versioned, nothing was written. "
          .. "Add this line to the %s hook there:"
        ):format(info.hooks_path, e.hook)
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

---Remove gitsuite's own hooks from one repository; a foreign hook is never removed.
---@param repo string
---@param ids string[]|nil nil = every shipped hook
---@return Gitsuite.Hooks.Result[]
function M.uninstall(repo, ids)
  local info = M.inspect(repo)
  if info.err then return { { repo = repo, id = "*", status = "error", message = info.err } } end
  local results = {}
  for _, e in ipairs(CATALOG) do
    if not ids or vim.tbl_contains(ids, e.id) then
      local file = info.hooks_dir .. "/" .. e.hook
      local state = "absent"
      for _, s in ipairs(info.entries) do
        if s.id == e.id then state = s.state end
      end
      local r = { repo = repo, id = e.id }
      if state == "ours" then
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

---Run install/uninstall over several repositories.
---@param repos string[]
---@param fn fun(repo: string, ids: string[]|nil): Gitsuite.Hooks.Result[]
---@param ids string[]|nil
---@return Gitsuite.Hooks.Result[]
function M.each(repos, fn, ids)
  local all = {}
  for _, repo in ipairs(repos) do
    vim.list_extend(all, fn(repo, ids))
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
