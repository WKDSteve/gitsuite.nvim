-- Live check: `:Git diff ...` (diff.nvim) and `:Git conflict ...` on a real throwaway repository (task
-- gitsuite.nvim/testblatt-bindings-checkliste). Automated: diff head/last/rev/close/history and the key
-- <leader>dh; conflict refresh/next/prev and the five resolutions ours/theirs/both/none/base on a buffer
-- with conflict markers.
return {
  id = "gitsuite.diff-conflict",
  title = ":Git diff and :Git conflict on a real repository",
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
    {
      lua = [[vim.cmd("only!"); vim.cmd("edit! " .. vim.fn.fnameescape(_G.repo .. "/notes.txt"))
      _G.conflict = function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> topic", "three" })
        vim.cmd("Git conflict refresh")
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
      end
      _G.lines = function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") end
      _G.conflict(); vim.api.nvim_win_set_cursor(0, { 1, 0 })]],
    },
    { keys = ":Git conflict next<CR>" },
    {
      expect = [[vim.api.nvim_win_get_cursor(0)[1] == 2]],
      note = "conflict next jumps to the opening marker",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git conflict prev<CR>" },
    { expect = [[_G.noted("no previous conflict")]], note = "and there is none before it" },
    { lua = [[_G.conflict()]] },
    { keys = ":Git conflict ours<CR>" },
    { expect = [[_G.lines() == "one|a|three"]], note = "ours keeps the HEAD side" },
    { lua = [[_G.conflict()]] },
    { keys = ":Git conflict theirs<CR>" },
    { expect = [[_G.lines() == "one|b|three"]], note = "theirs keeps the other side" },
    { lua = [[_G.conflict()]] },
    { keys = ":Git conflict both<CR>" },
    { expect = [[_G.lines() == "one|a|b|three"]], note = "both keeps both" },
    { lua = [[_G.conflict()]] },
    { keys = ":Git conflict none<CR>" },
    { expect = [[_G.lines() == "one|three"]], note = "none keeps neither" },
    { lua = [[_G.conflict(); _G.forget()]] },
    { keys = ":Git conflict base<CR>" },
    {
      expect = [[_G.noted("no base section") and _G.lines():find("<<<<<<<", 1, true) ~= nil]],
      note = "base without a diff3 section is refused and changes nothing",
    },
  },
  judge = { "the conflict marker highlight is visible and the diff view reads well" },
}
