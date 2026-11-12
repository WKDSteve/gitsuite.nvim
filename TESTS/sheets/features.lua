-- TESTS/sheets/features.lua -- the functionalities of gitsuite.nvim as its user meets them; `testing sheets report`
-- says which ones have a feature sheet (`feature = "<id>"`) and in which state, and K16 warns about a sheet that names
-- an id not listed here. Data: read with an empty environment like a sheet (testing.nvim docs/SHEETS.md).
-- The list follows docs/what-you-get.md, docs/commands.md, docs/integrations.md and
-- ALL/manual-test-checklists/gitsuite.md.
return {
  {
    id = "gitsuite.repo",
    title = ":Git branch, status and blame on the current repository",
    docs = "docs/commands.md",
  },
  {
    id = "gitsuite.diff",
    title = ":Git diff head/last/rev/history through diff.nvim, and the diff keys",
    docs = "docs/commands.md",
  },
  {
    id = "gitsuite.conflict",
    title = "Conflict markers are found on read (diff3, nested, marker size) and resolved ours/theirs/both/none/base",
    docs = "docs/what-you-get.md",
  },
  {
    id = "gitsuite.browse",
    title = ":Git browse opens the file or line on GitHub, GitLab, Codeberg or a configured host",
    docs = "docs/what-you-get.md",
  },
  {
    id = "gitsuite.adapters",
    title = "open.nvim, insights.nvim and gitsigns, when present, add browse, status todos, the conflict list and hunks",
    docs = "docs/architecture.md",
  },
  {
    id = "gitsuite.lazygit",
    title = ":Git ui lazygit opens the real lazygit in a float; its O and <C-o> open files in this Neovim",
    docs = "docs/what-you-get.md",
  },
  {
    id = "gitsuite.dashboard",
    title = ":Git dashboard shows the git status of a folder of clones or named pages, with push/pull/fetch per row",
    docs = "docs/commands.md",
  },
  {
    id = "gitsuite.dashboard-export",
    title = "E exports a dashboard report to the clipboard, a new buffer or a file",
    docs = "docs/commands.md",
  },
  {
    id = "gitsuite.plugins-log",
    title = ":Git plugins log completes the installed plugins and shows the newest commits of one with a preview",
    docs = "docs/commands.md",
  },
  {
    id = "gitsuite.plugins-report",
    title = ":Git plugins report names what the last plugin update changed, or what the next one would bring",
    docs = "docs/commands.md",
  },
  {
    id = "gitsuite.lazy-sync-hook",
    title = "Opt-in: after :Lazy sync the plugins report of the update follows on its own (plugins.after_sync)",
    docs = "docs/integrations.md",
  },
  {
    id = "gitsuite.plugins-summary",
    title = "An optional AI summary of one plugin's update",
    docs = "docs/integrations.md",
  },
  {
    id = "gitsuite.statusline",
    title = "A statusline component for lualine, heirline, the native statusline and ui.nvim",
    docs = "docs/statusline.md",
  },
  {
    id = "gitsuite.context-menu",
    title = "Context-menu entries for the git actions: conflict resolution, blame, diff, hunks",
    docs = "docs/integrations.md",
  },
  {
    id = "gitsuite.config-check",
    title = "A rejected setup() option is dropped with a warning in :checkhealth gitsuite and the default stays",
    docs = "docs/health.md",
  },
}
