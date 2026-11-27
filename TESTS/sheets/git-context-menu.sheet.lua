-- Live check: gitsuite's "Git Actions" context menu opened through lib.nvim.contextmenu's own kit renderer in a
-- real throwaway repository (task gitsuite.nvim/git-actions-menue-konfliktgruppe-wenn-der-buffer).
-- Automated: a clean buffer's menu has no Conflict group; a buffer with conflict markers gets it, and picking
-- "Keep Ours" in the drawn menu resolves the conflict through :Git conflict ours.
return {
  id = "gitsuite.context-menu",
  feature = "gitsuite.context-menu",
  title = "gitsuite.nvim: the Git Actions menu offers conflict resolution only while the buffer has markers",
  task = "gitsuite.nvim/git-actions-menue-konfliktgruppe-wenn-der-buffer",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      require("lib.nvim.contextmenu").setup({ renderer = "kit" })
      _G.lines = function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") end
      _G.menu_win = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_config(w).relative ~= "" then
            local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
            if text:find("Blame Line", 1, true) then return w end
          end
        end
      end
      _G.open_menu = function()
        require("lib.nvim.contextmenu").open(require("gitsuite.integrations.menu").items(), { mouse = false })
      end]],
    },
    { lua = [[_G.open_menu()]], note = "open the menu on the clean file" },
    { wait = [[_G.menu_win() ~= nil]], note = "the menu is drawn" },
    {
      expect = [[_G.floattext():find("Keep Ours", 1, true) == nil]],
      note = "a buffer without conflict markers offers no Conflict group",
    },
    { keys = "<Esc>" },
    { wait = [[_G.menu_win() == nil]], note = "Esc closes the menu" },
    {
      lua = [[vim.api.nvim_buf_set_lines(0, 0, -1, false,
        { "one", "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> topic", "three" })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      _G.open_menu()]],
      note = "markers in the buffer, open the menu again",
    },
    { wait = [[_G.menu_win() ~= nil]] },
    {
      expect = [[_G.floattext():find("Conflict", 1, true) ~= nil and _G.floattext():find("Keep Theirs", 1, true) ~= nil]],
      note = "now the Conflict group is there",
    },
    {
      lua = [[local w = _G.menu_win()
      for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
        if l:find("Keep Ours", 1, true) then vim.api.nvim_win_set_cursor(w, { i, 0 }) end
      end]],
      note = "move the menu's cursor onto Keep Ours",
    },
    { keys = "<CR>", note = "pick it" },
    {
      wait = [[_G.lines() == "one|a|three"]],
      note = "Keep Ours resolved the conflict to the HEAD side",
    },
  },
  judge = { "the Conflict group reads well beside Hunks, Blame and Diff, its icons line up" },
}
