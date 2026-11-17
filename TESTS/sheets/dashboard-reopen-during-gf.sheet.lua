-- Live check: close `:Git dashboard` while `gf` (fetch the whole page) is still running and open
-- it again (task gitsuite.nvim/dashboard-wiederoeffnen-live-test, which went into
-- gitsuite.nvim/live-test-checklist; the fix is gitsuite.nvim@0f81590 and @73a6399).
-- Automated: six local clones whose `origin` is a local bare repository (file://, no network), one
-- commit ahead of each clone. The real `git fetch` runs, but every remote's upload-pack is wrapped
-- in a small sh script (`remote.origin.uploadpack`) that waits for a gate file of its own: the
-- sheet decides when each fetch may finish, so "close before the batch is through" is not a race.
-- The sh script needs `sh` on PATH for git (Git for Windows brings its own). Sabotage: without the
-- redraw of the reopened dashboard (`_redraw` in view.lua, gitsuite.nvim@0f81590) it is red.
-- Steps: `:Git dashboard`, `gf` and yes (4 fetching, 2 queued), q, `:Git dashboard` again (the rows still
-- show the batch), a second `gf` is refused at once, without a question ("A bulk fetch is already running";
-- gitsuite.nvim/git-dashboard-gf-waehrend-eines-laufenden-batches-fragt-erst), one gate opens
-- (that row settles with its new commit, a queued one starts), all gates open (every row settles,
-- none stays on "fetch..."). A snapshot per state. The look of it, real remotes over the network
-- (slow, failing) and the feel stay with a person.
return {
  id = "gitsuite.dashboard-reopen-during-gf",
  feature = "gitsuite.dashboard",
  title = "gitsuite.nvim: close and reopen :Git dashboard while gf runs (local remotes)",
  task = "gitsuite.nvim/live-test-checklist",
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
      -- progress in memory only: the default ("auto" without fidget) adds one vim.notify per
      -- repository to the flood above (the user-facing side of that is a `manual` entry below)
      require("gitsuite").setup({ progress_style = "statusline", dashboard = { fetch_jobs = 4 } })]],
      note = "the helpers; gitsuite set up",
    },
    {
      lua = "_G.build_template()",
      note = "the template: a bare remote and a clone one commit behind it",
    },
    { wait = "_G.template_ready()", timeout = 20000, note = "the template is built" },
    {
      lua = '_G.make("alpha")',
      note = "alpha: a copy, a clone one commit behind its local bare remote, the fetch gated",
    },
    { lua = '_G.make("bravo")' },
    { lua = '_G.make("charlie")' },
    { lua = '_G.make("delta")' },
    { lua = '_G.make("echo")' },
    { lua = '_G.make("foxtrot")' },
    { lua = "_G.dashboard()", note = ":Git dashboard on the six clones" },
    {
      wait = [[_G.dwin() ~= nil and _G.count("clean") == 6 and _G.title():find("6 repos", 1, true) ~= nil]],
      timeout = 20000,
      note = "the dashboard is up: six clean rows, nothing behind yet",
    },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "opened", masks = { "%d+y " } },

    { keys = "gf", note = "gf: fetch the whole page" },
    { wait = [[_G.asking("Fetch 6 repositories in this dashboard?")]], note = "it asks first" },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "confirm", masks = { "%d+y " } },
    { keys = "y", note = "yes" },
    {
      wait = [[_G.count("⟳ fetch...") == 4 and _G.count("· fetch queued") == 2]],
      timeout = 10000,
      note = "four fetches run (dashboard.fetch_jobs), two are queued",
    },
    {
      expect = [[_G.title():find("fetch 0/6", 1, true) ~= nil]],
      note = "the title counts the batch",
    },
    {
      expect = [[_G.row("alpha"):find("fetch...", 1, true) and _G.row("echo"):find("queued", 1, true)
        and _G.row("foxtrot"):find("queued", 1, true)]],
      note = "in row order: alpha to delta run, echo and foxtrot wait",
    },
    { lua = 'vim.cmd("echo")' },
    { screen = "running", masks = { "%d+y " } },

    { keys = "q", note = "close the dashboard before any fetch is through" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },
    { expect = [[_G.verb() == "fetch"]], note = "the batch keeps running" },

    { lua = "_G.dashboard()", note = ":Git dashboard again (a fresh scan, a fresh window)" },
    {
      wait = [[_G.dwin() ~= nil and _G.count("⟳ fetch...") == 4 and _G.count("· fetch queued") == 2]],
      timeout = 20000,
      note = "the reopened dashboard shows the running batch: four fetching, two queued",
    },
    {
      wait = [[_G.title():find("fetch 0/6", 1, true) ~= nil]],
      timeout = 20000,
      note = "once its scan is through, its title counts the batch too",
    },
    { lua = 'vim.cmd("echo")' },
    { screen = "reopened", masks = { "%d+y " } },

    { keys = "gf", note = "a second gf in the reopened dashboard" },
    {
      wait = [[_G.said("A bulk fetch is already running")]],
      note = "it is refused at once: a bulk fetch is already running",
    },
    { expect = [[not _G.asking("Fetch 6 repositories")]], note = "without asking first" },
    {
      expect = [[_G.count("⟳ fetch...") == 4 and _G.count("· fetch queued") == 2]],
      note = "no second batch: the rows are as before",
    },

    { lua = '_G.release("alpha")', note = "alpha's fetch may finish" },
    {
      wait = [[_G.row("alpha"):find("↓1", 1, true) and not _G.row("alpha"):find("fetch", 1, true)
        and _G.row("echo"):find("fetch...", 1, true) and _G.count("· fetch queued") == 1]],
      timeout = 20000,
      note = "alpha settles with the new commit (↓1); echo leaves the queue and fetches",
    },
    {
      expect = [[_G.title():find("fetch 1/6", 1, true) ~= nil]],
      note = "the title counts on",
    },
    { lua = 'vim.cmd("echo")' },
    { screen = "progress", masks = { "%d+y " } },

    {
      lua = "for _, name in ipairs(_G.NAMES) do _G.release(name) end",
      note = "every other fetch may finish",
    },
    {
      wait = [[_G.verb() == nil and _G.count("fetch") == 0 and _G.count("↓1") == 6]],
      timeout = 30000,
      note = "the batch is through: every row settles with its new commit, none stays on fetch...",
    },
    {
      expect = [[_G.title():find("fetch", 1, true) == nil and _G.title():find("6 out of sync", 1, true) ~= nil]],
      note = "the title no longer counts a batch; all six are behind",
    },
    {
      expect = [[_G.said("fetch: 6 repositories done, 6 changed, 0 unchanged")]],
      note = "the closing message: every fetch brought a new commit",
    },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "settled", masks = { "%d+y " } },

    { keys = "gf", note = "gf again, now that the batch is through" },
    { wait = [[_G.asking("Fetch 6 repositories in this dashboard?")]], note = "it asks" },
    { keys = "y", note = "yes" },
    {
      wait = [[_G.said("fetch: 6 repositories done, 0 changed, 6 unchanged") and _G.verb() == nil
        and _G.count("fetch") == 0]],
      timeout = 30000,
      note = "a new batch runs (the gates are open) and finds nothing new",
    },
    { keys = "q", note = "close the dashboard" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },
  },
  judge = {
    "The rows of the running batch read clearly in the reopened dashboard (· fetch queued / ⟳ fetch...) and match the first one",
    "The title's counter (fetch 1/6) is noticeable enough to tell the batch is still running",
    "running/progress/settled: the float keeps the width it was opened with while the STATE and SYNC cells widen -- LAST COMMIT is cut at the border and the title starts with '<' (bug or acceptable?)",
  },
  manual = {
    "With your real repositories over the network: :Git dashboard, gf, close the popup before all repositories are through, :Git dashboard again; the rows go on and all settle",
    "A second gf in the reopened dashboard says 'A bulk fetch is already running' while the first runs",
    "A remote that fails (offline, no access) shows ✗ fetch failed in the reopened dashboard, the closing message names it",
    "In a Neovim without a notifier plugin or fidget (progress_style 'auto' now picks the echo style there, see util/progress.lua): :Git dashboard on a directory with many clones opens without a 'Press ENTER' prompt during the scan",
    "Enter findings under 'Befunde' in docs/ROADMAP/Final_Checks/gitsuite-live-checks-2026-10-22.md (nvim config), each as a kind: bug task",
  },
}
