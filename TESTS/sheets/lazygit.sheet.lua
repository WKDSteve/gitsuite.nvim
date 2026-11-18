-- Live check of `:Git ui lazygit` with a recording stand-in for lazygit (`fakes`): the real lazygit is an
-- interactive program that needs a person, the stand-in proves what gitsuite starts and where. Without a
-- directory it is rooted at the repository of the current directory, with one (a subdirectory works) at the
-- repository that holds it; both start `lazygit -p <root>` in gitsuite's own float (no terminal.nvim here), which
-- closes when the program ends. Then what lazygit's O and <C-o> call back: :GitsuiteLazygitBadd adds the file as
-- a buffer, :GitsuiteLazygitReplace opens it in the window. `testing perf` counts the starts here (repository
-- root, the terminal job), the stand-in costs nothing.
return {
  id = "gitsuite.lazygit",
  feature = "gitsuite.lazygit",
  title = ":Git ui lazygit starts lazygit -p <repository root> (stand-in), and the O/<C-o> commands",
  task = "gitsuite.nvim/live-test-checklist",
  sizes = { { rows = 40, cols = 120 } },
  fakes = { "lazygit" },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      vim.fn.mkdir(_G.repo .. "/sub", "p")
      _G.calls = function() return require("testing.fake_programs").read(vim.env.TESTING_FAKES, "lazygit") end
      -- no float left and no terminal whose job still runs
      _G.closed = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_config(w).relative ~= "" then return false end
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          local job = vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" and vim.b[b].terminal_job_id
          if job and vim.fn.jobwait({ job }, 0)[1] == -1 then return false end
        end
        return true
      end
      _G.same = function(a, b)
        local function norm(p) return vim.fs.normalize(vim.uv.fs_realpath(p) or p):lower() end
        return norm(a) == norm(b)
      end]],
      note = "a throwaway repository with a subdirectory; lazygit is a recorder",
    },
    { keys = ":Git ui lazygit<CR>" },
    {
      wait = [[#_G.calls() == 1]],
      timeout = 10000,
      note = "lazygit is started once",
    },
    {
      expect = [[(function()
        local argv = _G.calls()[1].argv
        return argv[1] == "-p" and _G.same(argv[2], _G.repo)
      end)()]],
      note = "with -p and the repository root",
    },
    {
      wait = [[_G.closed()]],
      timeout = 10000,
      note = "the float closes when the program ends",
    },
    { lua = [[vim.cmd("Git ui lazygit " .. vim.fn.fnameescape(_G.repo .. "/sub"))]] },
    {
      wait = [[#_G.calls() == 2 and _G.same(_G.calls()[2].argv[2], _G.repo)]],
      timeout = 10000,
      note = "a subdirectory roots it at the repository that holds it",
    },
    {
      -- Before the next commands open buffers: on Windows the child editor crashed now and then (0xC0000005)
      -- when they ran while the terminal of the ending program was being closed.
      wait = [[_G.closed()]],
      timeout = 10000,
      note = "its float closes too",
    },
    {
      lua = [[_G.write(_G.repo .. "/other.txt", { "other" }); _G.forget()
      vim.cmd("GitsuiteLazygitBadd other.txt")]],
    },
    {
      expect = [[_G.noted("+buffer other.txt") and vim.fn.bufexists(_G.repo .. "/other.txt") == 1]],
      note = "O: the file is added as a buffer, the window keeps its file",
    },
    { lua = [[vim.cmd("GitsuiteLazygitReplace other.txt")]] },
    {
      wait = [[vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "other.txt"]],
      note = "<C-o>: the window shows it",
    },
  },
  manual = {
    ":Git ui lazygit with the real lazygit: it opens in a float, O and <C-o> on a file open it in this Neovim, q closes",
  },
}
