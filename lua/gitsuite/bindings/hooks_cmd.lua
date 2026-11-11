---@module 'gitsuite.bindings.hooks_cmd'
---@brief The `:Git hooks ...` handlers: resolve the repositories, call `features.hooks`, show the report.

local M = {}

---The repository a command without `--repo` means: the buffer's, else the cwd's.
---@return string
local function current_repo()
  local name = vim.api.nvim_buf_get_name(0)
  local from = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  local root = vim.fs.root(from, ".git")
  return vim.fs.normalize(root or vim.fn.getcwd())
end

---@param flags table<string, any>
---@return string[] repos
local function repos_for(flags)
  if flags.all then
    local repos = require("gitsuite.features.dashboard.repos")
    local base = repos.resolve_base_dir(nil)
    if not base then return {} end
    return repos.collect_repos(base)
  end
  return { flags.repo and vim.fs.normalize(vim.fn.fnamemodify(flags.repo, ":p")) or current_repo() }
end

---@param text string
---@param level integer
local function say(text, level)
  require("gitsuite.util.notify").notify(text, level)
end

---@param action "install"|"uninstall"
---@param flags table<string, any>
function M.run(action, flags)
  local hooks = require("gitsuite.features.hooks")
  local repos = repos_for(flags or {})
  if #repos == 0 then
    say("hooks: no repository (set dashboard.base_dir for --all)", vim.log.levels.WARN)
    return
  end
  local ids = flags and flags.hook and { flags.hook } or nil
  local results = hooks.each(repos, action == "install" and hooks.install or hooks.uninstall, ids)
  local level = vim.log.levels.INFO
  for _, r in ipairs(results) do
    if r.status == "error" or r.status == "foreign" or r.status == "manual" then
      level = vim.log.levels.WARN
    end
  end
  say(hooks.format(results), level)
end

---@param repo string|nil
function M.list(repo)
  local hooks = require("gitsuite.features.hooks")
  local path = repo and vim.fs.normalize(vim.fn.fnamemodify(repo, ":p")) or current_repo()
  local info = hooks.inspect(path)
  if info.err then
    say(info.err, vim.log.levels.WARN)
    return
  end
  local state = {}
  for _, e in ipairs(info.entries) do
    state[e.id] = e.state
  end
  local lines =
    { path .. (info.hooks_path and ("  (core.hooksPath = " .. info.hooks_path .. ")") or "") }
  for _, e in ipairs(hooks.catalog()) do
    lines[#lines + 1] = ("  %-18s %-10s %s"):format(e.id, state[e.id] or "absent", e.desc)
  end
  say(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
