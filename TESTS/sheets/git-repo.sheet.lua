-- Live check: the repository commands of `:Git` on a real throwaway repository (task
-- gitsuite.nvim/testblatt-bindings-checkliste; the :Git section of BINDINGS-RUNTIME-CHECKLIST.md).
-- Automated: branch current/list/switch, status repo (clean and dirty), status quickfix, blame line,
-- blame toggle (the virtual text appears and goes), blame full and its key <leader>gb.
-- Not here: browse (needs open.nvim), status todos/lint/spell/relink and conflict list (need insights.nvim),
-- hunk (needs gitsigns.nvim), ui neogit/lazygit/diffview and dashboard update (external programs).
return {
  id = "gitsuite.repo",
  feature = "gitsuite.repo",
  title = ":Git branch, status and blame on a real repository",
  task = "gitsuite.nvim/testblatt-bindings-checkliste",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
  },
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()]] },
    { keys = ":Git branch current<CR>" },
    { expect = [[_G.noted("branch: main")]], note = "the current branch" },
    { lua = [[_G.forget()]] },
    { keys = ":Git branch list<CR>" },
    { expect = [[_G.noted("main") and _G.noted("topic")]], note = "both local branches" },
    { lua = [[_G.forget()]] },
    { keys = ":Git status repo<CR>" },
    {
      expect = [[_G.noted("branch: main") and _G.noted("clean")]],
      note = "a clean repository says so",
    },
    { lua = [[_G.write(_G.repo .. "/notes.txt", { "one", "two changed", "three", "four" })]] },
    { lua = [[_G.forget()]] },
    { keys = ":Git status repo<CR>" },
    { expect = [[_G.noted("dirty (1)")]], note = "an edited file makes it dirty (1)" },
    { keys = ":Git status quickfix<CR>" },
    {
      expect = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].text:find("notes.txt", 1, true) ~= nil]],
      note = "quickfix holds the changed file",
    },
    {
      lua = [[vim.cmd("cclose"); vim.cmd("edit! " .. vim.fn.fnameescape(_G.repo .. "/notes.txt")); vim.api.nvim_win_set_cursor(0, { 2, 0 }); _G.forget()]],
    },
    { keys = ":Git blame line<CR>" },
    { wait = [[_G.noted("second")]], note = "blame line names the commit of line 2" },
    { keys = ":Git blame toggle<CR>" },
    {
      wait = [[vim.b.gitsuite_blame_active == true]],
      note = "blame toggle switches the virtual text on",
    },
    {
      wait = [[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("gitsuite_blame"), 0, -1, {}) > 0]],
      note = "and it draws a mark",
    },
    { keys = ":Git blame toggle<CR>" },
    {
      expect = [[not vim.b.gitsuite_blame_active and #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("gitsuite_blame"), 0, -1, {}) == 0]],
      note = "off again, no mark left",
    },
    { keys = ":Git blame full<CR>" },
    {
      wait = [[vim.bo.filetype == "gitsuite-blame" or #vim.api.nvim_tabpage_list_wins(0) > 1]],
      note = "blame full opens its split",
    },
    {
      lua = [[vim.cmd("only!"); vim.cmd("edit! " .. vim.fn.fnameescape(_G.repo .. "/notes.txt"))]],
    },
    { keys = [[\gb]] },
    {
      wait = [[(function() for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype == "gitsuite-blame" and #vim.fn.win_findbuf(b) > 0 then return true end end return false end)()]],
      note = "<leader>gb is blame full",
    },
    {
      lua = [[vim.cmd("only!"); vim.cmd("edit! " .. vim.fn.fnameescape(_G.repo .. "/notes.txt")); _G.forget()]],
    },
    {
      lua = [[_G.asked = nil
      vim.ui.select = function(items, opts, on_choice)
        _G.asked = items
        for _, item in ipairs(items) do
          if tostring(item):find("topic", 1, true) then return on_choice(item) end
        end
        on_choice(nil)
      end]],
      note = "the child cancels native prompts: vim.ui.select takes topic and remembers what it was offered",
    },
    { keys = ":Git branch switch<CR>" },
    {
      wait = [[vim.fn.system({ "git", "-C", _G.repo, "branch", "--show-current" }):match("^topic") ~= nil]],
      timeout = 5000,
      note = "branch switch offers the branches and moves to topic",
    },
    {
      expect = [[type(_G.asked) == "table" and #_G.asked >= 2]],
      note = "and it offered both",
    },
  },
  judge = { "the blame split reads well (author, date, subject aligned) and scrolls with the file" },
  manual = {
    ":Git browse file/repo/selection (needs open.nvim)",
    ":Git hunk stage/preview/inline (needs gitsigns.nvim)",
    ":Git status todos/lint/spell/relink and :Git conflict list (need insights.nvim)",
    ":Git ui lazygit/neogit/diffview open/close and the keys <leader>lg, <leader>dv, <leader>dc, <leader>di",
    ":Git dashboard update and :Git dashboard",
  },
}
