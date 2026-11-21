-- Live check: `:Git browse` on a real throwaway repository (task gitsuite.nvim/testblatt-bindings-checkliste; split
-- from the sheet gitsuite.optional so `testing perf` counts it for its own functionality). It needs open.nvim:
-- TESTS/sheets/minit-extra.lua puts it on the runtimepath when it finds it, without it the sheet is a reported skip.
-- Automated: browse file/repo/selection; open.nvim's browser dispatch is a recorder, the URL is what counts (no
-- browser opens).
return {
  id = "gitsuite.browse",
  feature = "gitsuite.browse",
  title = ":Git browse file, repo and selection open the right URL (open.nvim)",
  task = "gitsuite.nvim/testblatt-bindings-checkliste",
  minit = "TESTS/sheets/minit-extra.lua",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
    { lua = [[pcall(require, "open.registry")]], reason = "open.nvim is not on the runtimepath" },
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
      wait = [[_G.opened[1] == "browser:https://github.com/me/proj/blob/main/notes.txt"]],
      note = "browse file opens the file on its web host",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git browse repo<CR>" },
    {
      wait = [[_G.opened[1] == "browser:https://github.com/me/proj"]],
      note = "browse repo opens the root",
    },
    { lua = [[_G.forget(); vim.cmd("normal! Vj\27")]] },
    { keys = ":Git browse selection<CR>" },
    {
      wait = [[_G.opened[1] == "browser:https://github.com/me/proj/blob/main/notes.txt#L1-L2"]],
      note = "browse selection carries the line range",
    },
  },
  manual = { ":Git browse in a real browser" },
}
