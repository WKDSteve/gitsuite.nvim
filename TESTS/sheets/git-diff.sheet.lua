-- Live check: `:Git diff ...` (diff.nvim) on a real throwaway repository (task
-- gitsuite.nvim/testblatt-bindings-checkliste; split from the conflict sheet so `testing perf` counts it for
-- its own functionality). Automated: diff head/last/rev/close/history and the key <leader>dh.
return {
  id = "gitsuite.diff",
  feature = "gitsuite.diff",
  title = ":Git diff head/last/rev/history on a real repository",
  task = "gitsuite.nvim/testblatt-bindings-checkliste",
  sizes = { { rows = 40, cols = 120 } },
  requires = {
    { lua = [[vim.fn.executable("git") == 1]], reason = "git is not installed" },
  },
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()]] },
    { keys = ":Git diff head<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("[Diff:target] git:HEAD", 1, true) ~= nil]],
      note = "diff head opens the file against HEAD",
    },
    { keys = ":Git diff close<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("notes.txt", 1, true) ~= nil and not vim.wo.diff]],
      note = "diff close leaves diff mode",
    },
    { keys = ":Git diff last<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("git:HEAD~1", 1, true) ~= nil]],
      note = "diff last is against the previous commit",
    },
    { keys = ":Git diff close<CR>" },
    { keys = ":Git diff rev HEAD~1<CR>" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("git:HEAD~1", 1, true) ~= nil]],
      note = "diff rev takes a revision",
    },
    { keys = ":Git diff close<CR>" },
    { keys = ":Git diff history<CR>" },
    {
      wait = [[_G.floattext():find("second", 1, true) and _G.floattext():find("first", 1, true)]],
      note = "diff history lists both commits",
    },
    { keys = "<Esc>" },
    {
      lua = [[vim.cmd("only!"); vim.cmd("edit! " .. vim.fn.fnameescape(_G.repo .. "/notes.txt"))]],
    },
    { keys = [[\dh]] },
    { wait = [[_G.floattext():find("second", 1, true)]], note = "<leader>dh is diff history" },
    { keys = "<Esc>" },
  },
  judge = { "the diff view reads well" },
}
