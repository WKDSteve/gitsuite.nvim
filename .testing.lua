-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "gitsuite",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "auto",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "diff.nvim", "lib.nvim", "ui.nvim" },
  -- A spec file runs in a child editor that inherits only an allowlist of the environment: lazy_sync_spec.lua runs
  -- lazy.nvim's real event handler from $LAZY_NVIM_DIR when it is set.
  env_allow = { "LAZY_NVIM_DIR" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file.
  isolated = "file",
  -- "c" = child started from a -c command (v:vim_did_enter is 0), "l" = `nvim -l` like the old runner.
  host = "c",
  -- Limits in milliseconds: per case, and per spec file (conflict_git_spec runs real `git merge` processes: about 90 s on Windows).
  timeouts = { case_ms = 30000, file_ms = 180000 },
  -- Safety nets (docs/GUARDS.md). "error" = the suite passes them cleanly, so a regression fails the run.
  guards = {
    -- Real finding, kept at "warn": browse_spec, lazygit_bridge_spec and status_spec write scratch files
    -- (`__gitsuite_*_scratch.md`) into the live repo root instead of a tempname() directory; running files
    -- in parallel can even see each other's file.
    fs = "warn",
    -- "error": the suite leaves no state behind. Every spec that opens windows or buffers closes and wipes
    -- them (TESTS/gitsuite/editor_scope.lua). `keep` names what is the plugin's own on purpose and lives as
    -- long as its module (under isolated = "file" it dies with the spec file's editor):
    --   * setup() is one-shot (later calls are no-ops): the :Git tree, :GitsuiteLazygit{Badd,Replace}, the
    --     default <leader> keymaps (\dc \dh \di \dv \gb \lg) and the gitsuite_conflict_scan autocmds; a spec
    --     that deleted them would leave the next one a plugin that believes it is set up. menu_spec
    --     registers the tree under a custom name (:MyGit) the same way.
    --   * module-load autocmds: gitsuite_statusline (BufWipeout cache), GitsuiteDashboardHighlights and
    --     gitsuite_plugins_report_hl (ColorScheme re-link), lib.nvim's lib_kit_toast_resize (VimResized):
    --     the module stays in package.loaded, deleting its group would break it for the rest of the file.
    state = {
      mode = "error",
      keep = {
        "Git",
        "MyGit",
        -- Exact names: keep entries match as prefixes, "gitsuite_" would also hide the groups one open
        -- creates (gitsuite_plugins_report, gitsuite_lazy_sync, gitsuite_blame_<n>).
        "gitsuite_conflict_scan",
        "gitsuite_statusline",
        "gitsuite_plugins_report_hl",
        "lib_kit_toast_resize",
        "\\dc",
        "\\dh",
        "\\di",
        "\\dv",
        "\\gb",
        "\\lg",
      },
      -- plugin/gitsuite.lua's load lock: set once per process, a second load must find it.
      ignore_vars = { "loaded_gitsuite" },
      -- Highlight groups are listed as info, not warned about: what is left are the syntax groups of the
      -- editor's runtime (css, dtd, lua, qf, ...), which the report, blame and diff specs load when they
      -- render fenced blocks, quickfix text or buffers of those filetypes. The set changes with the
      -- runtime and the specs define none of them.
      categories = { highlights = "info" },
      ignore_highlights = {
        -- the Kit* groups of lib.nvim's ui kit (shared with ui.nvim): defined once per process by the
        -- first kit surface a spec opens, re-linked on ColorScheme, so a spec must not delete them.
        "Kit",
        -- GitSuitePluginsSha is the plugins report's own group, defined when its renderer is first loaded
        -- and re-linked on ColorScheme (gitsuite_plugins_report_hl above).
        "GitSuite",
      },
    },
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- Every spawn of the suite is `git`, allowed below; anything else is a new, unexpected process.
    process_net = "error",
  },
  guard_allow = {
    -- The specs build temporary repositories and test the plugin's git wrappers (`git init`, `commit`,
    -- `rev-parse`, `blame`, `diff`): about 500 spawns in 53 files.
    -- sheets_spec.lua: every test sheet (TESTS/sheets/) runs in a child editor.
    -- hooks_spec.lua runs the shipped commit-msg script under bash.
    spawn = { "git", "nvim", "bash" },
  },
  -- The runner counts which commands, keymaps and autocommands the specs exercise (docs/SURFACE.md of testing.nvim);
  -- `scripts/test.sh surface` compares that with surface.baseline.json (a regression gate, not a percentage).
  surface = { track = true },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {
      {
        check = "K1",
        level = "warn",
        file = "lua/gitsuite/features/dashboard/view.lua",
        reason = "loaded lazily (only when the dashboard opens); the ColorScheme autocmd belongs to the highlights it defines at load, moving either would change when they exist",
        expires = "2027-04-14",
      },
      {
        check = "K1",
        level = "warn",
        file = "lua/gitsuite/statusline.lua",
        reason = "only loaded because the user put the component in their statusline; the BufDelete cache cleanup must start with it (no setup() exists)",
        expires = "2027-04-14",
      },
    },
  },
  -- The pipeline is derived (`scripts/test.sh ci list`). The GitHub workflow is generated from `workflow`:
  -- `testing init --workflow=public --force` writes it (testing.nvim docs/WORKFLOW-CI.md), the step
  -- workflow-in-sync checks it.
  ci = {
    workflow = {
      name = "gitsuite.nvim",
      layout = "hosted",
      -- the steps that depend on the platform: the windows and macOS legs run only these
      platform = { "suite", "conformance" },
      -- `testing ci land`: a check branch ci/** runs the hosted legs, main moves to a commit only once it is green there
      land = true,
      -- the optional plugins the test sheet git-optional loads (TESTS/sheets/minit-extra.lua finds them below .deps/);
      -- without them, or without ripgrep, it is a reported skip. open.nvim and insights.nvim come from their
      -- ci-verified branch, like the fleet's own dependencies; a change there that moves the sheet's snapshots shows
      -- up as a red sheet here, not as a silent drift.
      checkouts = {
        {
          repo = "WKDSteve/open.nvim",
          ref = "ci-verified",
          why = "only the test sheet git-optional loads it (:Git browse)",
        },
        {
          repo = "WKDSteve/insights.nvim",
          ref = "ci-verified",
          why = "only the test sheet git-optional loads it (:Git status todos, :Git conflict list)",
        },
        {
          repo = "lewis6991/gitsigns.nvim",
          ref = "ef707fb93301a9b856f36eae4c8f56f5b988a794",
          why = "only the test sheet git-optional loads it (:Git hunk)",
        },
      },
      packages = {
        { name = "ripgrep", why = "insights.nvim scans with it (the sheet git-optional)" },
      },
    },
    steps = {
      ["workflow-in-sync"] = { preset = "workflow-in-sync" },
    },
  },
}
