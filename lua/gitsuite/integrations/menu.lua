---@module 'gitsuite.integrations.menu'
--- Right-click-menu contributor (LUA-05: the one module that builds a
--- `Lib.ContextMenu.Item[]` for gitsuite's git actions). "Contributes only"
--- shape (see `lib.nvim.contextmenu`'s docstring): `M.items()`/`M.submenu()`
--- build data, nothing here opens or binds a menu -- a host composes the
--- result into its own (see this user's own `config.menu.custom_menu`,
--- which wraps `M.items()` in one "Git Actions" row).
---
--- Builds against `lib.nvim.contextmenu`, not `ui.contextmenu` (D-3's
--- literal recommendation): compared field for field (K-10), the two are
--- byte-identical item tables (`{name, rtxt, cmd, icon, icon_hl, hl}` for
--- `entry`, the same `__heading`/`separator` convention for `group`) --
--- `ui.nvim` calls its own copy "the pre-migration copy", but nothing about
--- the *table shape* differs, so an item list built with either renderer's
--- builder opens fine on either. gitsuite already treats lib.nvim as a hard
--- dependency (same reasoning as `features/branch/init.lua`'s SEC-01
--- comment), so this needs no new one -- `ui.contextmenu` would make
--- ui.nvim a hard dependency of a plugin meant to work without it.
---
--- Every entry routes through gitsuite's own `:Git ...` commands, not raw
--- `gitsigns.<fn>()` calls the way the config-local menu section this
--- replaces did -- a renamed `commands.git` (see `bindings/keymaps.lua`)
--- never desyncs this from it. Only the entries with no fallback at all
--- (stage/reset a hunk or the whole buffer, toggle deleted lines -- gitsigns'
--- own hunk engine, never reimplemented) gate on gitsigns being
--- loaded: blame is gitsuite's own native implementation and diff is
--- diff.nvim, gitsuite's other hard dependency, so both stay offered either
--- way -- the whole point of GS-09 (previously the entire section, blame and
--- diff included, vanished the moment gitsigns wasn't loaded).

local contextmenu = require("lib.nvim.contextmenu")
local nerd = require("lib.nvim.ui.nerd_font")

local M = {}

---@internal
---@param hex string
---@param fallback string
---@return string
local function icon(hex, fallback)
  return nerd.glyph(hex, fallback)
end

---@internal
---@return boolean
local function has_gitsigns()
  return require("gitsuite.adapter").resolve("gitsigns") ~= nil
end

---@internal
--- Whether open.nvim is installed: `:Git browse` hands the web URL to its
--- dispatcher (`open.registry`) and only errors without it.
---@return boolean
local function has_open()
  return (pcall(require, "open.registry"))
end

---@internal
--- A menu callback that dispatches one `:Git <args>` route, resolved at call
--- time so a `commands.git` rename (or a `setup()` that has not run yet when
--- this module loads) is always honoured.
---@param args string  Everything after the command name, e.g. "hunk stage".
---@return fun()
local function route(args)
  return function()
    vim.cmd(require("gitsuite.config").get().commands.git .. " " .. args)
  end
end

---The git actions, as a flat item list a host composes into its own menu.
---Never empty: Blame and Diff always contribute at least one entry.
---@param bufnr? integer  Buffer the menu acts on (default: the current one);
---  only the Conflict group depends on it.
---@return Lib.ContextMenu.Item[]
function M.items(bufnr)
  local out = {}
  local gitsigns = has_gitsigns()

  contextmenu.group(
    out,
    contextmenu.heading("Hunks"),
    contextmenu.entry(
      gitsigns,
      "Stage Hunk",
      route("hunk stage"),
      "sh",
      { icon = icon("F067", "+") }
    ),
    contextmenu.entry(
      gitsigns,
      "Reset Hunk",
      route("hunk reset"),
      "rh",
      { icon = icon("F0E2", "-") }
    ),
    contextmenu.entry(
      gitsigns,
      "Stage Buffer",
      route("hunk stage-buffer"),
      "sb",
      { icon = icon("F0FE", "+") }
    ),
    contextmenu.entry(
      gitsigns,
      "Reset Buffer",
      route("hunk reset-buffer"),
      "rb",
      { icon = icon("F021", "-") }
    ),
    -- Falls back to :Git diff head (diff.nvim) without gitsigns -- always offered.
    contextmenu.entry(
      true,
      "Preview Hunk",
      route("hunk preview"),
      "hp",
      { icon = icon("F06E", "o") }
    )
  )

  -- Native (`git blame --porcelain`), no adapter -- never gated on gitsigns.
  contextmenu.group(
    out,
    contextmenu.heading("Blame"),
    contextmenu.entry(true, "Blame Line", route("blame line"), "b", { icon = icon("F007", "b") }),
    contextmenu.entry(
      true,
      "Toggle Current Line Blame",
      route("blame toggle"),
      "tb",
      { icon = icon("F205", "t") }
    )
  )

  -- diff.nvim, gitsuite's own hard dependency -- never gated on gitsigns.
  -- "Diff Against HEAD", not "Diff This": gitsigns' diffthis() compares
  -- against the index by default, gitsuite's diff.head() against HEAD --
  -- close enough to replace, not close enough to relabel as the same thing.
  --
  -- Neither entry gets an rtxt hint: neither :Git diff head nor :Git diff
  -- last has a default keymap of its own, and "dh"/"dc" specifically would
  -- have been actively misleading here -- gitsuite's real <leader>dh/<leader>dc
  -- are bound to diff_history/diffview_close, two different commands.
  contextmenu.group(
    out,
    contextmenu.heading("Diff"),
    contextmenu.entry(
      true,
      "Diff Against HEAD",
      route("diff head"),
      nil,
      { icon = icon("F0EC", "d") }
    ),
    contextmenu.entry(
      true,
      "Diff Last Commit",
      route("diff last"),
      nil,
      { icon = icon("F1DA", "h") }
    ),
    contextmenu.entry(
      gitsigns,
      "Toggle Deleted",
      route("hunk toggle-deleted"),
      "td",
      { icon = icon("F205", "t") }
    )
  )

  -- `:Git browse` through open.nvim (an optional dependency of the browse
  -- feature only): without open.nvim the whole group is left out.
  local browse = has_open()
  contextmenu.group(
    out,
    contextmenu.heading("Browse"),
    contextmenu.entry(
      browse,
      "Open File on Web",
      route("browse file"),
      nil,
      { icon = icon("F0AC", "w") }
    ),
    contextmenu.entry(
      browse,
      "Open Repository on Web",
      route("browse repo"),
      nil,
      { icon = icon("F09B", "r") }
    )
  )

  -- Merge-conflict resolution (`:Git conflict ...`), only while the buffer
  -- actually has conflict markers: an always-present group would be noise
  -- in every clean file. The key hints are the buffer-local maps the
  -- conflict scan binds (`bindings/autocmds.lua`), shown only where they
  -- are really set.
  local buf = bufnr or vim.api.nvim_get_current_buf()
  local conflicted = vim.api.nvim_buf_is_valid(buf)
    and require("gitsuite.features.conflict").has_conflicts(buf)
  local keys = conflicted and vim.b[buf].gitsuite_conflict_mappings_set == true
  ---@param key string
  ---@return string|nil
  local function hint(key)
    return keys and key or nil
  end
  contextmenu.group(
    out,
    contextmenu.heading("Conflict"),
    contextmenu.entry(
      conflicted,
      "Keep Ours",
      route("conflict ours"),
      hint("co"),
      { icon = icon("F060", "<") }
    ),
    contextmenu.entry(
      conflicted,
      "Keep Theirs",
      route("conflict theirs"),
      hint("ct"),
      { icon = icon("F061", ">") }
    ),
    contextmenu.entry(
      conflicted,
      "Keep Both",
      route("conflict both"),
      hint("cb"),
      { icon = icon("F0EC", "=") }
    ),
    contextmenu.entry(
      conflicted,
      "Keep None",
      route("conflict none"),
      hint("c0"),
      { icon = icon("F05E", "0") }
    ),
    contextmenu.entry(
      conflicted,
      "Next Conflict",
      route("conflict next"),
      hint("]x"),
      { icon = icon("F063", "v") }
    )
  )

  return out
end

---Wrap `M.items()` as one nested "Git" fly-out entry.
---@return Lib.ContextMenu.Item|nil
function M.submenu()
  return contextmenu.submenu("Git", M.items(), { icon = icon("F1D3", "git") })
end

return M
