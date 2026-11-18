-- Live check of `:Git plugins log` on a real throwaway checkout named by its path (no plugin manager, no
-- network): the read-only listing (--out=buffer) holds both commits, the picker (default) lists them with the
-- changed files of the commit under the cursor in its preview. One `git log` per call is what `testing perf`
-- measures here (features/plugins/gitlog.lua `M.log`).
return {
  id = "gitsuite.plugins-log",
  feature = "gitsuite.plugins-log",
  title = ":Git plugins log of a checkout as a buffer and as a picker",
  task = "gitsuite.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  sizes = { { rows = 40, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      _G.log_buf = function()
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[b].filetype == "gitsuite-plugins-log" and #vim.fn.win_findbuf(b) > 0 then
            return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
          end
        end
        return ""
      end]],
      note = "a throwaway checkout with two commits",
    },
    { lua = [[vim.cmd("Git plugins log " .. vim.fn.fnameescape(_G.repo) .. " --out=buffer")]] },
    {
      wait = [[_G.log_buf():find("second", 1, true) and _G.log_buf():find("first", 1, true)]],
      timeout = 10000,
      note = "--out=buffer lists both commits",
    },
    { lua = [[vim.cmd("only!"); vim.cmd("enew!")]] },
    { lua = [[vim.cmd("Git plugins log " .. vim.fn.fnameescape(_G.repo))]] },
    {
      wait = [[_G.floattext():find("second", 1, true) and _G.floattext():find("notes.txt", 1, true)]],
      timeout = 10000,
      note = "the picker lists the commits and previews the changed file of the one under the cursor",
    },
    { keys = "<Esc>" },
  },
  judge = { "the picker's rows (hash, age, author, subject) and the preview read well" },
  manual = {
    ":Git plugins log lazy.nvim on your installed plugins: <Tab> completes the names, <CR> opens the commit in the browser",
  },
}
