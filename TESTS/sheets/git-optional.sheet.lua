-- Live check: the `:Git` commands that need an optional plugin, on a real throwaway repository (task
-- gitsuite.nvim/testblatt-bindings-checkliste). TESTS/sheets/minit-extra.lua puts open.nvim, insights.nvim
-- and gitsigns.nvim on the runtimepath when it finds them; without one of them (or without ripgrep) the
-- sheet is a reported skip, never a failure.
-- Automated: browse file/repo/selection (open.nvim's browser dispatch is a recorder: the URL is what
-- counts), status todos (insights.nvim), conflict list on a real merge conflict, hunk preview/inline/
-- stage/reset (gitsigns.nvim, the staged result is read back with `git diff --cached`).
return {
  id = "gitsuite.optional",
  feature = "gitsuite.adapters",
  title = ":Git browse, status todos, conflict list and hunk with the optional plugins",
  task = "gitsuite.nvim/testblatt-bindings-checkliste",
  minit = "TESTS/sheets/minit-extra.lua",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
    {
      lua = [[vim.fn.executable("rg") == 1]],
      reason = "ripgrep is not installed (insights.nvim scans with it)",
    },
    { lua = [[pcall(require, "open.registry")]], reason = "open.nvim is not on the runtimepath" },
    {
      lua = [[pcall(require, "insights.todos")]],
      reason = "insights.nvim is not on the runtimepath",
    },
    { lua = [[pcall(require, "gitsigns")]], reason = "gitsigns.nvim is not on the runtimepath" },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      require("open.registry").dispatch = function(kind, ctx)
        _G.opened[#_G.opened + 1] = kind .. ":" .. ctx.text
        return true
      end]],
    },
    { keys = ":Git browse file<CR>" },
    {
      expect = [[_G.opened[1] == "browser:https://github.com/me/proj/blob/main/notes.txt"]],
      note = "browse file opens the file on its web host",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git browse repo<CR>" },
    {
      expect = [[_G.opened[1] == "browser:https://github.com/me/proj"]],
      note = "browse repo opens the root",
    },
    { lua = [[_G.forget(); vim.cmd("normal! Vj\27")]] },
    { keys = ":Git browse selection<CR>" },
    {
      expect = [[_G.opened[1] == "browser:https://github.com/me/proj/blob/main/notes.txt#L1-L2"]],
      note = "browse selection carries the line range",
    },
    {
      lua = [[_G.write(_G.repo .. "/notes.txt", { "one", "two changed", "three", "TODO fix me" }); vim.cmd("edit!")]],
    },
    { keys = ":Git status todos<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].text:find("TODO fix me", 1, true) ~= nil]],
      timeout = 8000,
      note = "status todos lists the TODO of the changed file",
    },
    {
      lua = [[vim.cmd("cclose"); vim.cmd("edit " .. vim.fn.fnameescape(_G.repo .. "/notes.txt"))
      require("gitsigns").setup({}); vim.cmd("edit!"); vim.api.nvim_win_set_cursor(0, { 4, 0 }); _G.forget()]],
    },
    {
      lua = [[vim.cmd("Gitsigns attach"); _G.gs_attach_at = vim.uv.now()]],
      note = "the sheet's child does not attach on its own",
    },
    {
      -- Once red on the hosted Windows leg (run 42726969266): the one attach never landed. Retry it every
      -- 2 s while the buffer has no gitsigns state, instead of waiting on a single attempt.
      wait = [[(function()
        local now = vim.uv.now()
        if vim.b.gitsigns_status_dict == nil and now - (_G.gs_attach_at or 0) > 2000 then
          _G.gs_attach_at = now
          pcall(vim.cmd, "Gitsigns attach")
        end
        local ok, h = pcall(function() return require("gitsigns").get_hunks() end)
        return ok and h ~= nil and #h == 1
      end)()]],
      timeout = 10000,
      note = "gitsigns has attached and sees the added line",
    },
    { keys = ":Git hunk preview<CR>" },
    {
      wait = [[_G.floattext():find("+TODO fix me", 1, true) ~= nil]],
      timeout = 8000,
      note = "hunk preview shows the added line",
    },
    { keys = "<Esc>" },
    { keys = ":Git hunk inline<CR>" },
    { keys = ":Git hunk inline<CR>", note = "twice: on and off without an error" },
    { keys = "<Esc>" },
    { keys = ":Git hunk stage<CR>" },
    {
      wait = [[vim.fn.system({ "git", "-C", _G.repo, "diff", "--cached", "--stat" }):find("notes.txt", 1, true) ~= nil]],
      timeout = 8000,
      note = "hunk stage puts the change into the index",
    },
    {
      lua = [[_G.write(_G.repo .. "/notes.txt", { "one", "two changed", "three", "TODO fix me", "EXTRA" }); vim.cmd("edit!")
      vim.api.nvim_win_set_cursor(0, { 5, 0 })]],
    },
    {
      wait = [[(function() local ok, signs = pcall(function() return require("gitsigns").get_hunks() end) return ok and signs ~= nil and #signs == 1 end)()]],
      timeout = 8000,
      note = "gitsigns sees the new hunk",
    },
    { keys = ":Git hunk reset<CR>" },
    {
      wait = [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") == "one|two changed|three|TODO fix me"]],
      timeout = 8000,
      note = "hunk reset removes the unstaged line",
    },
    {
      lua = [[local r = _G.repo
      _G.git(r, "reset", "-q", "--hard")
      _G.git(r, "checkout", "-q", "topic"); _G.write(r .. "/notes.txt", { "one", "topic side", "three" }); _G.git(r, "commit", "-q", "-a", "-m", "t")
      _G.git(r, "checkout", "-q", "main"); _G.write(r .. "/notes.txt", { "one", "main side", "three" }); _G.git(r, "commit", "-q", "-a", "-m", "m")
      vim.system({ "git", "-C", r, "-c", "user.name=s", "-c", "user.email=s@e.i", "merge", "topic" }):wait()
      vim.cmd("edit!"); _G.forget(); vim.fn.setqflist({})]],
      note = "a real merge conflict",
    },
    { keys = ":Git conflict list<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].lnum == 1]],
      timeout = 8000,
      note = "conflict list puts the conflicted file into quickfix",
    },
  },
  manual = {
    ":Git hunk stage-buffer, reset-buffer and toggle-deleted",
    ":Git status lint, spell and relink",
    ":Git browse in a real browser",
  },
}
