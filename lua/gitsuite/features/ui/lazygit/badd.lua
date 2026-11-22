---@module 'gitsuite.features.ui.lazygit.badd'
--- Add a file selected in lazygit to the parent Neovim's buffer list,
--- without loading or focusing it (`:badd`). lazygit's `O` action, called
--- via `nvr` -- see docs/lazygit-config.yml. Ported from the nvim config's
--- `lua/config/lazygit/actions/badd.lua`, which pre-existed this plugin.

local notify = require("gitsuite.util.notify")
local resolve = require("lib.nvim.fs.path").from_repo_relative
local open_background = require("lib.nvim.buffer.open_background")

local fn = vim.fn

local M = {}

---Resolve a path lazygit handed over. A repo-relative one is taken below the
---root of the running lazygit, which gitsuite.nvim already knows
---(`lazygit.root()`); only without one does lib.nvim ask git for the root of
---the cwd (a blocking `rev-parse --show-toplevel`). An absolute path is kept.
---@param raw string repo-root-relative or absolute path
---@return string absolute path
function M.resolve(raw)
  local root = require("gitsuite.features.ui.lazygit").root()
  if not root or fn.isabsolutepath(raw) == 1 or raw:match("^[\\/]") then return resolve(raw) end
  local below = root .. "/" .. raw
  if fn.filereadable(below) == 1 then return below end
  return fn.fnamemodify(raw, ":p")
end

---@param raw string path from lazygit (repo-root-relative or absolute)
---@return boolean ok
function M.run(raw)
  if type(raw) ~= "string" or raw == "" then
    notify.warn("lazygit badd: no path received")
    return false
  end

  local path = M.resolve(raw)
  if fn.filereadable(path) ~= 1 then
    notify.warn(("lazygit badd: file not readable: %s"):format(path))
    return false
  end

  local ok, err = open_background(path, { load = false })
  if not ok then
    notify.warn(("lazygit badd failed: %s"):format(err))
    return false
  end

  notify.info(("+buffer %s"):format(fn.fnamemodify(path, ":t")))
  return true
end

return M
