---@module 'gitsuite.util.progress'
---@brief Progress indicator for bulk repository operations.
---@description
--- Thin wrapper over `lib.nvim.progress`, which abstracts "an operation is
--- running" away from "how that is shown" (notify, statusline, fidget, or a
--- floating window). gitsuite needs it for the two commands that walk a whole
--- directory of clones — `:Git dashboard update` and `:Git dashboard` — where the
--- per-repository `git` calls are individually fast but collectively take long
--- enough to look like a hang.
---
--- `lib.nvim` itself is a hard, required dependency of this plugin (see
--- docs/requirements.md): every other module requires it bare, at module
--- load, with no fallback, so a missing lib.nvim already stops the plugin
--- long before this module's `M.create` would ever run. The `pcall` below is
--- local defensive padding for this one indicator, not evidence of a
--- project-wide soft-dependency convention -- if it ever did trip, `M.create`
--- returns `nil` and every call site's `if handle then` guard skips the
--- indicator entirely; nothing else is affected.
---
--- Style comes from `config.get().progress_style` and is read on each call
--- rather than cached at require time, so `setup()` ordering never matters.

---@class GitSuite.Util.Progress
local M = {}

local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

---True when `vim.notify` is still Neovim's own (no notifier plugin replaced it).
---@return boolean
local function stock_notify()
  -- (a notifier can be a callable table: `debug.getinfo` only takes a function)
  if type(vim.notify) ~= "function" then return false end
  local info = debug.getinfo(vim.notify, "S")
  return info ~= nil and info.source:find("vim/_editor.lua", 1, true) ~= nil
end

---"auto" means fidget, else `vim.notify`. With the stock `vim.notify` that is one message per
---repository, which fills the command line and raises a "Press ENTER" prompt in the middle of
---the scan; the `echo` style rewrites one line instead.
---@param style string
---@return string
function M.resolve_style(style)
  if style ~= "auto" or pcall(require, "fidget") or not stock_notify() then return style end
  return "echo"
end

---Starts a progress handle, or returns nil when lib.nvim isn't installed.
---@param text string Initial message, shown after the "[gitsuite]" title
---@param total integer|nil Total unit count, when the operation is countable
---@return Lib.Progress.Handle|nil
function M.create(text, total)
  if not ok_progress then return nil end

  local style = "auto"
  local ok_cfg, config = pcall(require, "gitsuite.config")
  if ok_cfg then style = config.get().progress_style or style end

  local handle = progress_mod.create({ title = "[gitsuite]", style = M.resolve_style(style) })
  handle:update({ text = text, current = 0, total = total })
  return handle
end

return M
