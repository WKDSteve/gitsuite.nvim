-- Live check of `:Git hooks` on a real throwaway repository: install puts gitsuite's commit-msg and pre-commit
-- wrappers into .git/hooks, a second install changes nothing, list shows them, uninstall takes them out again.
-- Then a repository with its own core.hooksPath (.husky): install writes nothing there (manual), and
-- --into-versioned adds the line to .husky/commit-msg and the script's path to the local config.
-- It is also what `testing perf` measures the hooks' git calls with (features/hooks/init.lua).
return {
  id = "gitsuite.hooks",
  feature = "gitsuite.hooks",
  title = ":Git hooks install, list and uninstall on a real repository, plain and with core.hooksPath",
  task = "gitsuite.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  sizes = { { rows = 40, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      _G.hook = function(name) return vim.uv.fs_stat(_G.repo .. "/.git/hooks/" .. name) ~= nil end]],
      note = "a throwaway repository, gitsuite set up",
    },
    { keys = ":Git hooks install<CR>" },
    {
      expect = [[_G.noted("installed") and _G.hook("commit-msg") and _G.hook("pre-commit")]],
      note = "install writes both wrappers into .git/hooks",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git hooks install<CR>" },
    {
      expect = [[_G.noted("unchanged") and _G.noted("already installed") and not _G.noted("installed: ")]],
      note = "a second install changes nothing",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git hooks list<CR>" },
    {
      expect = [[_G.noted("commit-msg") and _G.noted("pre-commit")]],
      note = "list names both hooks",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git hooks uninstall<CR>" },
    {
      expect = [[not _G.hook("commit-msg") and not _G.hook("pre-commit")]],
      note = "uninstall takes them out again",
    },

    {
      lua = [[vim.fn.mkdir(_G.repo .. "/.husky", "p")
      _G.git(_G.repo, "config", "--local", "core.hooksPath", ".husky")
      _G.forget()]],
      note = "the repository keeps its hooks in a versioned folder (core.hooksPath = .husky)",
    },
    { keys = ":Git hooks install<CR>" },
    {
      expect = [[_G.noted("manual") and vim.uv.fs_stat(_G.repo .. "/.husky/commit-msg") == nil]],
      note = "install writes nothing there and says what to do by hand",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git hooks install --into-versioned<CR>" },
    {
      expect = [[vim.uv.fs_stat(_G.repo .. "/.husky/commit-msg") ~= nil
        and vim.trim(vim.fn.system({ "git", "-C", _G.repo, "config", "--local", "--get-regexp", "^gitsuite\\.hook\\." })) ~= ""]],
      note = "--into-versioned adds the hook file and the script's path to the local config",
    },
    { lua = [[_G.forget()]] },
    { keys = ":Git hooks uninstall --into-versioned<CR>" },
    {
      expect = [[vim.uv.fs_stat(_G.repo .. "/.husky/commit-msg") == nil]],
      note = "uninstall --into-versioned removes the hook file that held nothing else",
    },
  },
  manual = {
    "A real commit in a repository with the hooks installed: a Co-Authored-By: Claude trailer is gone from the message",
  },
}
