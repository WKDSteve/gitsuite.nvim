-- Live check of `dashboard.fetch_on_open` (task gitsuite.nvim/dashboard-scan-plus-fetch-pipeline): `:Git dashboard`
-- fetches the page it opens with, each repository as soon as its row is read (one at a time while the scan runs,
-- then `fetch_jobs` at once), and redraws every row once its own fetch is through. Six clones with gated local
-- remotes (`_gated_remotes.lua`, no network): the sheet decides when each fetch may finish. The queue is in the
-- order the scan finished reading the rows, which differs between systems: no step names which rows fetch first.
-- Steps: open (no question; two fetch, four queued), the gate of one running fetch opens (its row shows its new
-- commit, a queued one starts), all open (every row settles, one summary). Then the remotes disappear (what no
-- network looks like to the queue): opened again with one fetch at a time, it stops after the first three failures
-- and says so once.
-- Sabotage: without `feeder.push` in features/dashboard/init.lua nothing fetches and the first wait is red.
return {
  id = "gitsuite.dashboard-fetch-on-open",
  feature = "gitsuite.dashboard",
  title = "gitsuite.nvim: :Git dashboard fetches the page it opens with (dashboard.fetch_on_open, local remotes)",
  task = "gitsuite.nvim/dashboard-scan-plus-fetch-pipeline",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      -- the fetch notifications pile up into a hit-enter prompt that would stop the child.
      -- 'messagesopt' exists from Neovim 0.11 on; the plugin promises 0.10+, so older ones keep
      -- the notifications in a list instead of on the screen (_G.said reads both)
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
      require("gitsuite").setup({
        progress_style = "statusline",
        dashboard = { fetch_jobs = 2, fetch_on_open = true },
      })]],
      note = "the helpers; gitsuite set up with fetch_on_open, two fetches at once",
    },
    {
      lua = "_G.build_template()",
      note = "the template: a bare remote and a clone one commit behind it",
    },
    { wait = "_G.template_ready()", timeout = 20000, note = "the template is built" },
    {
      lua = "for _, name in ipairs(_G.NAMES) do _G.make(name) end",
      note = "six clones, every fetch gated",
    },

    { lua = "_G.dashboard()", note = ":Git dashboard on the six clones" },
    {
      wait = [[_G.dwin() ~= nil and _G.count("⟳ fetch...") == 2 and _G.count("· fetch queued") == 4
        and _G.title():find("fetch 0/6", 1, true) ~= nil]],
      timeout = 20000,
      note = "the dashboard is up and already fetching: two run (fetch_jobs), four are queued",
    },
    { expect = [[not _G.asking("Fetch")]], note = "without a question" },

    { keys = "gf", note = "gf while the fetch on open runs" },
    {
      wait = [[_G.said("A bulk fetch is already running")]],
      note = "is refused at once, like during any batch",
    },

    {
      lua = [[for _, name in ipairs(_G.NAMES) do
        if _G.row(name):find("fetch...", 1, true) then _G.first = name; break end
      end
      _G.release(_G.first)]],
      note = "one of the two running fetches may finish (the queue is in the order the scan read the rows)",
    },
    {
      wait = [[_G.row(_G.first):find("↓1", 1, true) and not _G.row(_G.first):find("fetch", 1, true)
        and _G.count("⟳ fetch...") == 2 and _G.count("· fetch queued") == 3]],
      timeout = 20000,
      note = "its row is redrawn by itself with its new commit (↓1); the next one leaves the queue",
    },
    { expect = [[_G.title():find("fetch 1/6", 1, true) ~= nil]], note = "the title counts on" },

    {
      lua = "for _, name in ipairs(_G.NAMES) do _G.release(name) end",
      note = "every other fetch may finish",
    },
    {
      wait = [[_G.verb() == nil and _G.count("fetch") == 0 and _G.count("↓1") == 6]],
      timeout = 30000,
      note = "through: every row settles with its new commit",
    },
    {
      expect = [[_G.said("fetch: 6 repositories done, 6 changed, 0 unchanged")]],
      note = "one summary at the end",
    },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "settled", masks = { "%d+y " } },
    { keys = "q", note = "close the dashboard" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },

    {
      lua = [[assert(vim.uv.fs_rename(_G.sheet_root .. "/remotes", _G.sheet_root .. "/remotes-gone"))
      require("gitsuite.config").get().dashboard.fetch_jobs = 1]],
      note = "the remotes are gone (no network, as far as the queue can tell); one fetch at a time",
    },
    { lua = "_G.dashboard()", note = ":Git dashboard again" },
    {
      wait = [[_G.said("fetch on open stopped: the first 3 fetches failed") and _G.verb() == nil]],
      timeout = 30000,
      note = "after three failures in a row with none through it stops, and says so",
    },
    {
      expect = [[_G.said("fetch: 3 of 3 failed")]],
      note = "the three it tried, named in the same message",
    },
    {
      expect = [[_G.dwin() ~= nil and _G.count("fetch") == 0 and _G.count("↓1") == 6]],
      note = "no row is left on fetch; the rows keep what the last fetch brought",
    },
    { keys = "q", note = "close the dashboard" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },
  },
  judge = {
    "settled: every row shows what its fetch brought (↓1) without a gf, and the title no longer counts a batch",
  },
  manual = {
    "With your real repositories over the network and dashboard.fetch_on_open = true: :Git dashboard opens at once, rows fill in and then show their fetch, each settles by itself; no Falcon/EDR alert with fetch_jobs = 4",
    "Offline (network off): :Git dashboard stops fetching after three failures with one warning, the dashboard stays usable",
  },
}
