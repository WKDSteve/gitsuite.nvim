-- Live check: the dashboard's export (`E`) in a real Neovim (task
-- gitsuite.nvim/dashboard-export-e-im-echten-neovim-ausprobieren; feature gitsuite.nvim@c37e29b,
-- fix @837aa80). The specs simulate the choice and fake the clipboard; here both choosers are the
-- real lib.nvim kit choosers, driven with keys, on two local repositories (no network): alpha is
-- clean, bravo has an untracked file.
-- Automated: `E` lists the reports with their counts, Clipboard puts the report into `+` (the child's
-- clipboard store, never the system one), New buffer closes the popup and `q` brings it back on the
-- row it was on, File offers a path under the cache directory and the file exists afterwards, the
-- same with `--out=buffer`, and a real right click shows "Export…" under "Whole dashboard".
-- `vim.ui.input` is a recorder that takes the offered default: the child cancels native prompts.
-- The look of the lists, the real system clipboard and a Windows path typed by hand stay with a person.
return {
  id = "gitsuite.dashboard-export",
  title = "gitsuite.nvim: E exports a dashboard report to the clipboard, a new buffer or a file",
  task = "gitsuite.nvim/dashboard-export-e-im-echten-neovim-ausprobieren",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      _G.sheet_said = {}
      if vim.fn.exists("+messagesopt") == 1 then
        vim.o.messagesopt = "wait:0,history:500"
      else
        vim.notify = function(msg) table.insert(_G.sheet_said, tostring(msg)) end
      end
      _G.said = function(text)
        return vim.fn.execute("messages"):find(text, 1, true) ~= nil
          or table.concat(_G.sheet_said, " | "):find(text, 1, true) ~= nil
      end
      -- the File target asks with vim.ui.input; take the default it offers and remember it
      _G.asked = {}
      vim.ui.input = function(opts, on_confirm)
        table.insert(_G.asked, opts)
        on_confirm(opts.default)
      end]],
      note = "no intro, no ruler, no hit-enter prompt; vim.ui.input takes the offered default",
    },
    {
      lua = [=[local root = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(root .. "/repos", "p")
      _G.sheet_root = root
      -- 400 days back: the LAST COMMIT column reads "1y" (masked in the snapshots)
      local date = os.date("!%Y-%m-%dT12:00:00Z", os.time() - 400 * 86400)
      local env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date }
      local calls = {}
      for _, name in ipairs({ "alpha", "bravo" }) do
        local dir = root .. "/repos/" .. name
        table.insert(calls, { "init", "-q", "-b", "main", dir })
        table.insert(calls, { "-C", dir, "commit", "-q", "--allow-empty", "-m", "first" })
      end
      local status = "not started"
      -- asynchronous, so the child keeps answering while git runs (slow on Windows)
      local function run(i)
        local call = calls[i]
        if not call then
          local f = assert(io.open(root .. "/repos/bravo/new.txt", "wb"))
          f:write("new\n")
          f:close()
          status = "ready"
          return
        end
        status = "at: git " .. table.concat(call, " ")
        local argv = { "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.invalid",
          "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false" }
        vim.list_extend(argv, call)
        local spawned, err = pcall(vim.system, argv, { text = true, env = env, timeout = 15000 },
          vim.schedule_wrap(function(res)
            if res.code == 0 then
              run(i + 1)
            else
              status = ("failed: git %s: exit %d: %s"):format(table.concat(call, " "), res.code, res.stderr or "")
            end
          end))
        if not spawned then status = "failed: " .. tostring(err) end
      end
      run(1)
      _G.repos_ready = function()
        assert(not status:find("^failed"), status)
        return status == "ready"
      end
      require("gitsuite").setup({ progress_style = "statusline" })
      _G.dashboard = function(out)
        vim.cmd("Git dashboard " .. (out and ("--out=" .. out .. " ") or "") .. vim.fn.fnameescape(root .. "/repos"))
      end
      -- the dashboard window of the current tab (a float in popup mode), if one is shown
      _G.dwin = function()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "gitsuite-dashboard" then return w end
        end
      end
      _G.lines = function(buf)
        return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), "\n")
      end
      _G.row_of = function(name)
        local w = _G.dwin()
        if not w then return nil end
        for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
          if l:find(" " .. name .. " ", 1, true) then return i end
        end
      end
      _G.scanned = function()
        local w = _G.dwin()
        if not (w and _G.row_of("alpha") and _G.row_of("bravo")) then return false end
        local text = _G.lines(vim.api.nvim_win_get_buf(w))
        return text:find("clean", 1, true) ~= nil and text:find("scanning", 1, true) == nil
      end
      _G.chooser = function(title)
        if not require("lib.nvim.ui.kit.chooser").is_open() then return false end
        if not title then return true end
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local t = vim.api.nvim_win_get_config(w).title
          if type(t) == "table" then
            local parts = {}
            for _, chunk in ipairs(t) do parts[#parts + 1] = chunk[1] end
            t = table.concat(parts)
          end
          if type(t) == "string" and t:find(title, 1, true) then return true end
        end
        return false
      end]=],
      note = "two repositories (alpha clean, bravo with an untracked file), helpers, gitsuite set up",
    },
    { wait = "_G.repos_ready()", timeout = 20000, note = "the repositories are built" },
    { lua = "_G.dashboard()", note = ":Git dashboard (popup) on the two repositories" },
    { wait = "_G.scanned()", timeout = 10000, note = "both rows are scanned" },

    -- Clipboard
    { keys = "E", note = "E: which report?" },
    { wait = [[_G.chooser("Export which repositories?")]], note = "the first chooser is open" },
    { screen = "which", masks = { "%d+y " } },
    { keys = "<CR>", note = "All with status" },
    { wait = [[_G.chooser("Export all to")]], note = "the second chooser asks where to" },
    { screen = "where", masks = { "%d+y " } },
    { keys = "<CR>", note = "Clipboard" },
    {
      wait = [[vim.fn.getreg("+"):find("alpha", 1, true) and vim.fn.getreg("+"):find("bravo", 1, true)]],
      note = "the report of both repositories is in +",
    },
    { expect = [[_G.said("to the clipboard")]], note = "and it says so" },
    { expect = [[_G.dwin() ~= nil]], note = "the popup stays open" },

    -- New buffer, and q back on the same row
    {
      lua = [[vim.api.nvim_win_set_cursor(_G.dwin(), { _G.row_of("bravo"), 0 })
      _G.was_on = _G.row_of("bravo")]],
      note = "the cursor on bravo's row",
    },
    { keys = "E" },
    { wait = [[_G.chooser("Export which repositories?")]] },
    { keys = "<CR>", note = "All with status" },
    { wait = [[_G.chooser("Export all to")]] },
    { keys = "j<CR>", note = "New buffer" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("dashboard-export-all", 1, true) ~= nil]],
      note = "a buffer with the report has the window",
    },
    { expect = [[_G.dwin() == nil]], note = "the popup closed first" },
    {
      expect = [[_G.lines():find("bravo", 1, true) ~= nil and vim.bo.modifiable == false]],
      note = "the report, read-only",
    },
    { screen = "buffer", masks = { "%d+y " } },
    { keys = "q", note = "q in the report" },
    { wait = [[_G.dwin() ~= nil]], note = "the dashboard is back" },
    {
      expect = [[vim.api.nvim_win_get_cursor(_G.dwin())[1] == _G.was_on]],
      note = "on the row it was on",
    },

    -- File
    { keys = "E" },
    { wait = [[_G.chooser("Export which repositories?")]] },
    { keys = "<CR>" },
    { wait = [[_G.chooser("Export all to")]] },
    { keys = "jj<CR>", note = "File" },
    { wait = [[#_G.asked == 1]], note = "it asks for a path" },
    {
      expect = [[vim.fs.normalize(_G.asked[1].default)
        == vim.fs.normalize(vim.fn.stdpath("cache") .. "/gitsuite/dashboard-all.txt")]],
      note = "the default is under the cache directory",
    },
    {
      wait = [[vim.fn.filereadable(_G.asked[1].default) == 1
        and table.concat(vim.fn.readfile(_G.asked[1].default), "\n"):find("bravo", 1, true) ~= nil]],
      note = "the file exists and holds the report",
    },
    { expect = [[_G.said("Dashboard written to")]], note = "and it says where" },

    -- a real right click
    {
      -- screenpos() of the buffer line, not win_screenpos(): the border of the float is not part of the text
      lua = [[local p = vim.fn.screenpos(_G.dwin(), _G.row_of("alpha"), 3)
      vim.api.nvim_input_mouse("right", "press", "", 0, p.row - 1, p.col - 1)
      vim.api.nvim_input_mouse("right", "release", "", 0, p.row - 1, p.col - 1)
      _G.menu_text = function()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if w ~= _G.dwin() and vim.api.nvim_win_get_config(w).relative ~= "" then
            local text = _G.lines(vim.api.nvim_win_get_buf(w))
            if text:find("Whole dashboard", 1, true) then return text end
          end
        end
        return ""
      end]],
      note = "right click on alpha's row",
    },
    {
      wait = [[_G.menu_text():find("Whole dashboard", 1, true) ~= nil]],
      note = "the context menu is open",
    },
    {
      expect = [[(function()
        local text = _G.menu_text()
        local whole = text:find("Whole dashboard", 1, true)
        local export = text:find("Export", whole, true)
        return export ~= nil
      end)()]],
      note = "it shows Export… under Whole dashboard",
    },
    {
      expect = [[_G.menu_text():find(" alpha ", 1, true) ~= nil and _G.menu_text():find(" bravo ", 1, true) == nil]],
      note = "its row group is the row under the pointer (alpha)",
    },
    { screen = "menu", masks = { "%d+y " } },
    { keys = "<Esc>", note = "the menu closes" },
    {
      lua = [[for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
      end]],
      note = "every float closed",
    },

    -- --out=buffer
    { lua = "vim.cmd('enew!'); _G.dashboard('buffer')", note = ":Git dashboard --out=buffer" },
    { wait = "_G.scanned()", timeout = 10000 },
    {
      expect = [[vim.api.nvim_win_get_config(_G.dwin()).relative == ""]],
      note = "a normal window, not a float",
    },
    {
      lua = [[vim.api.nvim_win_set_cursor(_G.dwin(), { _G.row_of("alpha"), 0 }); _G.was_on = _G.row_of("alpha")]],
    },
    { keys = "E" },
    { wait = [[_G.chooser("Export which repositories?")]] },
    { keys = "<CR>" },
    { wait = [[_G.chooser("Export all to")]] },
    { keys = "j<CR>", note = "New buffer" },
    { wait = [[vim.api.nvim_buf_get_name(0):find("dashboard-export-all", 1, true) ~= nil]] },
    { keys = "q" },
    { wait = [[_G.dwin() ~= nil]], note = "the buffer dashboard is back" },
    {
      expect = [[vim.api.nvim_win_get_cursor(_G.dwin())[1] == _G.was_on]],
      note = "on the row it was on",
    },
  },
  judge = {
    "The two export lists (which report, with counts; where to) read well",
    "The report buffer and the right-click menu look right",
  },
  manual = {
    "With the real system clipboard: E, All, Clipboard, then paste into another program",
    "File with a Windows path typed by hand (backslashes, a drive letter): the file lands there",
  },
}
