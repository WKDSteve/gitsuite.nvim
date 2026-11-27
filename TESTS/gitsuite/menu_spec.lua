-- TESTS/gitsuite/menu_spec.lua -- gitsuite.integrations.menu. gitsigns.nvim
-- is not a sibling checkout in this test environment (like hunk_spec.lua),
-- so `adapter.resolve("gitsigns")` correctly reports "not installed" without
-- faking anything for the "no gitsigns" cases; a faked `gitsigns` module
-- covers the "installed" ones.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite.integrations.menu", function()
  editor_scope.install()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { vim, "cmd" },
  })

  local menu
  local real_gitsigns

  before_each(function()
    package.loaded["gitsuite.integrations.menu"] = nil
    package.loaded["gitsuite.adapter"] = nil
    real_gitsigns = package.loaded["gitsigns"]
    package.loaded["gitsigns"] = nil
    menu = require("gitsuite.integrations.menu")
    require("gitsuite.config").setup({ commands = { git = "Git" } })
    require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())
  end)

  after_each(function()
    package.loaded["gitsigns"] = real_gitsigns
  end)

  ---@param items Lib.ContextMenu.Item[]
  ---@param name string
  ---@return Lib.ContextMenu.Item|nil
  local function find(items, name)
    for _, item in ipairs(items) do
      if item.name == name then return item end
    end
    return nil
  end

  it("without gitsigns: only Blame and Diff entries are offered", function()
    local items = menu.items()

    assert.is_nil(find(items, "Stage Hunk"))
    assert.is_nil(find(items, "Reset Hunk"))
    assert.is_nil(find(items, "Stage Buffer"))
    assert.is_nil(find(items, "Reset Buffer"))
    assert.is_nil(find(items, "Toggle Deleted"))

    assert.is_not_nil(find(items, "Preview Hunk"))
    assert.is_not_nil(find(items, "Blame Line"))
    assert.is_not_nil(find(items, "Toggle Current Line Blame"))
    assert.is_not_nil(find(items, "Diff Against HEAD"))
    assert.is_not_nil(find(items, "Diff Last Commit"))
  end)

  it("with a faked gitsigns.nvim: every entry is offered", function()
    package.loaded["gitsigns"] = {}
    local items = menu.items()

    local expected = {
      "Stage Hunk",
      "Reset Hunk",
      "Stage Buffer",
      "Reset Buffer",
      "Preview Hunk",
      "Blame Line",
      "Toggle Current Line Blame",
      "Diff Against HEAD",
      "Diff Last Commit",
      "Toggle Deleted",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(find(items, name), name .. " missing")
    end
  end)

  it("an entry's cmd dispatches the matching :Git route, honouring a renamed command", function()
    require("gitsuite.config").setup({ commands = { git = "MyGit" } })
    require("gitsuite.bindings.usrcmds").register(require("gitsuite.config").get())

    local calls = {}
    package.loaded["gitsigns"] = {
      blame_line = function() end,
    }
    local original_cmd = vim.cmd
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.cmd = setmetatable({}, {
      __call = function(_, c)
        calls[#calls + 1] = c
      end,
    })

    local items = menu.items()
    local blame_line = find(items, "Blame Line")
    assert.is_not_nil(blame_line)
    blame_line.cmd()

    vim.cmd = original_cmd

    assert.same({ "MyGit blame line" }, calls)
  end)

  it("routes to blame.line() through the real :Git dispatch", function()
    local git = require("lib.nvim.git")
    editor_scope.open_file(vim.fn.getcwd() .. "/README.md")
    local bufnr = vim.api.nvim_get_current_buf()

    local items = menu.items()
    local blame_line = find(items, "Blame Line")
    assert.is_not_nil(blame_line)

    local ok = pcall(blame_line.cmd)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

    assert.is_true(ok)
    assert.is_not_nil(git.repo_root())
  end)

  describe("Browse group (open.nvim)", function()
    local saved_loaded, saved_preload

    before_each(function()
      saved_loaded = package.loaded["open.registry"]
      saved_preload = package.preload["open.registry"]
    end)

    after_each(function()
      package.loaded["open.registry"] = saved_loaded
      package.preload["open.registry"] = saved_preload
    end)

    it("is left out without open.nvim", function()
      package.loaded["open.registry"] = nil
      package.preload["open.registry"] = function()
        error("open.nvim is not installed")
      end
      local items = menu.items()
      assert.is_nil(find(items, "Open File on Web"))
      assert.is_nil(find(items, "Open Repository on Web"))
      assert.is_nil(find(items, "Browse"))
    end)

    it("with open.nvim: both entries route to :Git browse", function()
      package.loaded["open.registry"] = { dispatch = function() end }
      local items = menu.items()
      local file, repo = find(items, "Open File on Web"), find(items, "Open Repository on Web")
      assert.is_not_nil(file)
      assert.is_not_nil(repo)

      local calls = {}
      local original_cmd = vim.cmd
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.cmd = setmetatable({}, {
        __call = function(_, c)
          calls[#calls + 1] = c
        end,
      })
      file.cmd()
      repo.cmd()
      vim.cmd = original_cmd

      assert.same({ "Git browse file", "Git browse repo" }, calls)
    end)
  end)

  describe("Conflict group", function()
    local CONFLICT_NAMES = { "Keep Ours", "Keep Theirs", "Keep Both", "Keep None", "Next Conflict" }

    ---@param lines string[]
    ---@return integer
    local function scratch(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    local CONFLICTED = {
      "a",
      "<<<<<<< HEAD",
      "ours",
      "=======",
      "theirs",
      ">>>>>>> feature",
      "b",
    }

    it("is left out for a buffer without conflict markers", function()
      local buf = scratch({ "plain", "text" })
      local items = menu.items(buf)
      assert.is_nil(find(items, "Conflict"))
      for _, name in ipairs(CONFLICT_NAMES) do
        assert.is_nil(find(items, name), name)
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("with conflict markers: every entry routes to :Git conflict", function()
      local buf = scratch(CONFLICTED)
      local items = menu.items(buf)
      assert.is_not_nil(find(items, "Conflict"))

      local calls = {}
      local original_cmd = vim.cmd
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.cmd = setmetatable({}, {
        __call = function(_, c)
          calls[#calls + 1] = c
        end,
      })
      for _, name in ipairs(CONFLICT_NAMES) do
        local item = find(items, name)
        assert.is_not_nil(item, name)
        ---@cast item -nil
        item.cmd()
      end
      vim.cmd = original_cmd

      assert.same({
        "Git conflict ours",
        "Git conflict theirs",
        "Git conflict both",
        "Git conflict none",
        "Git conflict next",
      }, calls)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("defaults to the current buffer", function()
      local buf = scratch(CONFLICTED)
      local prev = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_current_buf(buf)
      local items = menu.items()
      vim.api.nvim_set_current_buf(prev)
      assert.is_not_nil(find(items, "Keep Ours"))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows key hints only where the conflict keymaps are bound", function()
      local buf = scratch(CONFLICTED)
      assert.is_nil(find(menu.items(buf), "Keep Ours").rtxt)
      vim.b[buf].gitsuite_conflict_mappings_set = true
      assert.equals("co", find(menu.items(buf), "Keep Ours").rtxt)
      assert.equals("]x", find(menu.items(buf), "Next Conflict").rtxt)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("submenu() wraps items() as one 'Git' fly-out entry", function()
    local sub = menu.submenu()
    assert.is_not_nil(sub)
    assert.equals("Git", sub.name)
    assert.is_true(#sub.items > 0)
  end)
end)
