-- Live check of the dashboard's git actions on real clones with local remotes (`_gated_remotes.lua`, no network,
-- every gate opened at once): `f` fetches and `P` pulls the row under the cursor, `gu` updates the whole page
-- (fetch + fast-forward), and `gS` syncs it: a repository behind its upstream is pulled, one ahead is pushed, a
-- level one is left alone. The remotes are read back with git, so what counts is what really moved.
-- This is the sheet `testing perf` measures the dashboard's write paths with (features/dashboard/actions.lua:
-- pull, fetch, update, push and sync with its rev-list counts).
return {
  id = "gitsuite.dashboard-actions",
  feature = "gitsuite.dashboard",
  title = "gitsuite.nvim: the dashboard fetches, pulls, updates and syncs real clones (local remotes)",
  task = "gitsuite.nvim/live-test-checklist",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      -- see dashboard-fetch-on-open.sheet.lua: no hit-enter prompt from the notifications
      _G.sheet_said = {}
      if vim.fn.exists("+messagesopt") == 1 then
        vim.o.messagesopt = "wait:0,history:500"
      else
        vim.notify = function(msg) table.insert(_G.sheet_said, tostring(msg)) end
      end]],
      note = "no intro, no ruler; no hit-enter prompt",
    },
    {
      lua = [[dofile("TESTS/sheets/_gated_remotes.lua")
      require("gitsuite").setup({ progress_style = "statusline", dashboard = { fetch_on_open = false } })
      _G.NAMES = { "alpha", "bravo", "charlie" }
      local function url(path)
        return "file://" .. (path:sub(1, 1) == "/" and "" or "/") .. path
      end
      -- sheet preparation: a commit in a clone, or a new commit on one remote
      _G.prep = function(dir, ...)
        local argv = { "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.invalid",
          "-c", "commit.gpgsign=false", "-C", dir }
        vim.list_extend(argv, { ... })
        local res = vim.system(argv, { text = true, timeout = 20000 }):wait()
        assert(res.code == 0, table.concat({ ... }, " ") .. ": " .. (res.stderr or ""))
        return vim.trim(res.stdout or "")
      end
      _G.remote_url = function(name) return url(_G.sheet_root .. "/remotes/" .. name .. ".git") end
      -- the subject of the newest commit of a remote's main
      _G.remote_head = function(name)
        return _G.prep(_G.sheet_root .. "/remotes/" .. name .. ".git", "log", "-1", "--format=%s", "main")
      end
      _G.goto_row = function(name)
        local w = assert(_G.dwin(), "no dashboard")
        for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
          if l:find(" " .. name .. " ", 1, true) then
            vim.api.nvim_set_current_win(w)
            vim.api.nvim_win_set_cursor(w, { i, 0 })
            return
          end
        end
        error("no row " .. name)
      end]],
      note = "the helpers; gitsuite set up without fetch on open",
    },
    {
      lua = "_G.build_template()",
      note = "the template: a bare remote and a clone one commit behind it",
    },
    { wait = "_G.template_ready()", timeout = 20000, note = "the template is built" },
    {
      lua = "for _, name in ipairs(_G.NAMES) do _G.make(name); _G.release(name) end",
      note = "three clones, every gate open: their fetches finish at once",
    },

    { lua = "_G.dashboard()", note = ":Git dashboard on the three clones" },
    {
      wait = [[_G.dwin() ~= nil and _G.row("alpha") ~= "" and _G.row("charlie") ~= ""
        and _G.count("clean") == 3]],
      timeout = 20000,
      note = "the rows are read: clean, and nothing fetched yet",
    },

    { lua = [[_G.goto_row("alpha")]], note = "the cursor on alpha" },
    { keys = "f", note = "f: fetch alpha" },
    {
      wait = [[_G.said("alpha: fetch done") and _G.row("alpha"):find("↓1", 1, true) ~= nil]],
      timeout = 20000,
      note = "alpha knows its new commit (↓1)",
    },
    { keys = "P", note = "P: pull alpha" },
    {
      wait = [[_G.said("alpha: pull done") and not _G.row("alpha"):find("↓", 1, true)]],
      timeout = 20000,
      note = "alpha is level with its remote",
    },

    { keys = "gu", note = "gu: update the whole page" },
    { wait = [[_G.asking("Update 3 repositories in this dashboard?")]], note = "it asks first" },
    { keys = "y", note = "yes" },
    {
      wait = [[_G.said("update: 3 repositories done") and _G.verb() == nil]],
      timeout = 30000,
      note = "every clone is fetched and fast-forwarded",
    },
    {
      expect = [[_G.prep(_G.sheet_root .. "/repos/charlie", "log", "-1", "--format=%s") == "second"]],
      note = "charlie now has the remote's commit",
    },

    {
      lua = [[_G.prep(_G.sheet_root .. "/repos/charlie", "commit", "-q", "--allow-empty", "-m", "local")
      local work = _G.sheet_root .. "/work/template"
      _G.prep(work, "commit", "-q", "--allow-empty", "-m", "third")
      _G.prep(work, "push", "-q", _G.remote_url("bravo"), "main")]],
      note = "charlie gets a commit of its own (ahead), bravo's remote one more (behind)",
    },
    { keys = "gS", note = "gS: sync the whole page" },
    { wait = [[_G.asking("Sync 3 repositories in this dashboard?")]], note = "it asks first" },
    { keys = "y", note = "yes" },
    {
      wait = [[_G.said("sync: 3 repositories done, 2 changed, 1 unchanged") and _G.verb() == nil]],
      timeout = 30000,
      note = "bravo and charlie changed, alpha was level",
    },
    {
      expect = [[_G.said("bravo: pulled 1 commit") and _G.said("charlie: pushed 1 commit")]],
      note = "the summary names the direction of each",
    },
    {
      expect = [[_G.remote_head("charlie") == "local"
        and _G.prep(_G.sheet_root .. "/repos/bravo", "log", "-1", "--format=%s") == "third"]],
      note = "charlie's commit is on its remote, bravo has the remote's new commit",
    },
    { keys = "q", note = "close the dashboard" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },
  },
  manual = {
    "With your real repositories over the network: f, P, gu and gS on :Git dashboard do the same, a credential prompt never appears",
  },
}
