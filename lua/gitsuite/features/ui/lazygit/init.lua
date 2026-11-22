---@module 'gitsuite.features.ui.lazygit'
--- lazygit float: spawns the real `lazygit` binary in a floating terminal.
--- Replaces kdheepak/lazygit.nvim's wrapper entirely -- the UI itself stays
--- exactly lazygit's own TUI (the part that was worth keeping), only the
--- Neovim-side float/spawn/bridge is gitsuite.nvim's own.
---
--- `GitsuiteLazygitBadd`/`GitsuiteLazygitReplace` are lazygit's `O`/`<C-o>`
--- custom-command targets, called via `nvr` from *inside* lazygit's own
--- process -- see docs/lazygit-config.yml. They are flat commands outside
--- the `:Git` tree on purpose: lazygit's config.yml embeds their exact
--- name, so nesting them under `:Git` would mean users editing a config
--- file most of them never touch, for no benefit (nothing about these two
--- commands is ever typed by a person).

local notify = require("gitsuite.util.notify")
local usercmd = require("lib.nvim.bindings.usercmd")

local M = {}

---@internal
--- DEP-02: `jobstart(argv, {term=true})`, never `termopen()` (deprecated).
--- `argv` is a plain list (SEC-01: no shell string) -- lazygit itself IS
--- the program here, so unlike a general terminal helper there is no
--- Windows "keep the shell open" concern (XP-04): there is no intermediate
--- shell to keep open, only the lazygit process itself, and its own exit
--- is what should close the float (see `on_exit` below).
---@param repo_dir string
---@return string[]
local function build_argv(repo_dir)
  return { "lazygit", "-p", repo_dir }
end

---@internal
---@param bufnr integer
local function setup_terminal_keymaps(bufnr)
  vim.keymap.set(
    "t",
    "<Esc>",
    [[<C-\><C-n>]],
    { buffer = bufnr, silent = true, desc = "[gitsuite] Exit terminal mode" }
  )
  vim.keymap.set(
    "n",
    "q",
    "<Cmd>close<CR>",
    { buffer = bufnr, silent = true, desc = "[gitsuite] Close lazygit" }
  )
end

---@internal
--- The directory lazygit is rooted at: the repo containing `repo_dir` or,
--- without one, the repo of the current cwd. One git call
--- (`rev-parse --show-toplevel` fails outside a work tree, so it is also the
--- "is this a repo" check), and the editor does not wait for it: `done` comes
--- from the event loop.
---@param repo_dir string|nil
---@param done fun(root: string|nil, err: string|nil)
local function resolve_repo_dir(repo_dir, done)
  local gitq = require("gitsuite.util.gitq")
  local dir, suffix = nil, ""
  if repo_dir ~= nil and repo_dir ~= "" then
    dir = vim.fs.normalize(repo_dir)
    local stat = vim.uv.fs_stat(dir)
    if not stat or stat.type ~= "directory" then
      return done(nil, "not a directory: " .. repo_dir)
    end
    suffix = ": " .. repo_dir
  end
  gitq.run({ "rev-parse", "--show-toplevel" }, { dir = dir }, function(res)
    local root = gitq.line(res)
    if not root then
      return done(nil, gitq.failure(res, "not inside a git repository" .. suffix))
    end
    done(root, nil)
  end)
end

---@internal
--- terminal.nvim's facade when it is installed and new enough to offer
--- `run(argv, { direct = true })`; nil otherwise (optional dependency, the
--- own float below is the fallback). Same predicate as `:checkhealth`
--- (`lazygit.facade`), so the two cannot disagree.
---@return table|nil
local function terminal_facade()
  return (require("gitsuite.features.ui.lazygit.facade").resolve())
end

---@internal
--- The terminal.nvim name of the lazygit terminal (one per project).
local TERM_NAME = "lazygit"

---@internal
--- Buffer variable naming the repo root a lazygit terminal started by
--- gitsuite.nvim runs in. A terminal of the same name without it (one a
--- terminal.nvim session restore brought back: no q/<Esc> maps, no
--- `close = "always"`) is not reused but replaced.
local MARKER = "gitsuite_lazygit_root"

---@internal
--- The repo root of the lazygit gitsuite.nvim opened last: the bridge's
--- fallback when the focused buffer is not its terminal (a multiplexer pane).
---@type string|nil
local last_root = nil

---The repo root of the running lazygit, for the nvr bridge (badd/replace)
---to resolve lazygit's repo-relative paths without asking git: the root of
---the focused lazygit terminal, else the one gitsuite.nvim opened last; nil
---when gitsuite.nvim opened none.
---@return string|nil
function M.root()
  local here = vim.b[vim.api.nvim_get_current_buf()][MARKER]
  if type(here) == "string" and here ~= "" then return here end
  return last_root
end

---@internal
--- The live lazygit terminal gitsuite.nvim started for `root` in this
--- project, when terminal.nvim keeps one (hidden by `q`, or visible).
--- Native backend only: that is where `q` hides a terminal whose job keeps
--- running; a multiplexer pane is left to the multiplexer.
---@param term table terminal.nvim's facade
---@param root string repo root
---@return boolean
local function has_running_lazygit(term, root)
  if type(term.list) ~= "function" or type(term.open) ~= "function" then return false end
  local ok, handles = pcall(term.list)
  if not ok or type(handles) ~= "table" then return false end
  for _, h in ipairs(handles) do
    if
      type(h) == "table"
      and h.name == TERM_NAME
      and not h.exited
      and not h.disposed
      and type(h.bufnr) == "number"
      and vim.api.nvim_buf_is_valid(h.bufnr)
      and vim.b[h.bufnr][MARKER] == root
    then
      return true
    end
  end
  return false
end

---@internal
--- Start lazygit through terminal.nvim: it owns the float, the job, the
--- exit handling (`close = "always"`) and the identity.
---
--- * A lazygit of the same repo that is still running (hidden with `q`) is
---   shown again, never replaced: replacing would stop it, and with it a
---   push or rebase lazygit may be in the middle of.
--- * Otherwise `run(argv, { direct = true })` starts one, replacing an
---   earlier lazygit terminal of this project (another repo's, or one a
---   session restore brought back).
---
--- No `env` is passed: a native terminal already gets $NVIM (the `nvr`
--- bridge) from Neovim, and the tmux/WezTerm backends refuse any `env`, so
--- passing it would keep lazygit from starting there at all.
---@param term table terminal.nvim's facade
---@param root string repo root
---@return boolean started false: terminal.nvim did not start it (it reports why itself), use the own float
local function open_via_terminal(term, root)
  if has_running_lazygit(term, root) then
    local ok, handle = pcall(term.open, { name = TERM_NAME, layout = "float" })
    if ok and handle then return true end
    -- Could not be shown again: start a new one below.
  end
  local ok, started = pcall(term.run, build_argv(root), {
    direct = true,
    name = TERM_NAME,
    title = "lazygit",
    cwd = root,
    layout = "float",
    float = { width = 0.9, height = 0.9 },
    close = "always",
    -- Kept out of terminal.nvim's sessions integration: a restored lazygit
    -- would lack `close` and the maps `on_open` sets. A terminal.nvim that
    -- predates the option ignores it (has_running_lazygit's MARKER check
    -- still replaces a restored one).
    session = false,
    on_open = function(handle)
      -- Multiplexer backends have no Neovim buffer to map keys in.
      local bufnr = type(handle) == "table" and handle.bufnr or nil
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr][MARKER] = root
        setup_terminal_keymaps(bufnr)
      end
    end,
  })
  if not ok then
    -- A false return is reported by terminal.nvim itself; a raised error is not.
    notify.error("ui lazygit: terminal.nvim failed: " .. tostring(started))
    return false
  end
  return started == true
end

---@internal
--- Fallback without terminal.nvim: an own float through lib.nvim.terminal.spawn.
---@param repo_dir string repo root
---@return nil
local function open_own_float(repo_dir)
  local libterm = require("lib.nvim.terminal")
  -- An installed lib.nvim older than the helper would fail with "attempt to
  -- call a nil value"; name what to update instead.
  if type(libterm.spawn) ~= "function" then
    notify.error("ui lazygit: lib.nvim is too old (no lib.nvim.terminal.spawn) -- update lib.nvim")
    return
  end
  -- lib.nvim.terminal.spawn closes the float when lazygit exits (the window
  -- may be gone by then) and leaves no float around a dead terminal when the
  -- process does not start.
  local term, err = libterm.spawn({
    argv = build_argv(repo_dir),
    cwd = repo_dir,
    layout = "float",
    title = " lazygit ",
    close_on_exit = "always",
    on_open = function(bufnr)
      vim.b[bufnr][MARKER] = repo_dir
      setup_terminal_keymaps(bufnr)
    end,
  })
  if not term then
    notify.error("ui lazygit: " .. (err or "failed to start the lazygit process"))
  end
end

---Open lazygit in a floating terminal. Without `repo_dir` it is rooted at the
---repo of the current cwd; with one, at the repo containing that directory
---(any subdirectory of a work tree works, not only its root). With
---terminal.nvim installed the float is terminal.nvim's
---(`require("terminal").run(argv, { direct = true })`, or the same repo's
---lazygit hidden with `q` shown again); without it, or when it does not
---start lazygit, gitsuite.nvim's own.
---@param repo_dir? string
---@return nil
function M.open(repo_dir)
  if vim.fn.executable("lazygit") ~= 1 then
    notify.error(
      'ui lazygit: the "lazygit" executable is not on $PATH -- see https://github.com/jesseduffield/lazygit#installation'
    )
    return
  end

  -- A newer :Git ui lazygit wins: the answer of an older one starts nothing.
  local valid = require("gitsuite.util.gitq").ticket("ui.lazygit")
  resolve_repo_dir(repo_dir, function(root, err)
    if not valid() then return end
    if not root then
      notify.error("ui lazygit: " .. err)
      return
    end
    last_root = root
    -- terminal.nvim first; when it is missing or did not start lazygit (it
    -- reported why), the own float.
    local term = terminal_facade()
    if term and open_via_terminal(term, root) then return end
    open_own_float(root)
  end)
end

---Register the nvr bridge commands. Idempotent; called once from
---`bindings.register`.
---@return nil
function M.setup()
  if vim.fn.executable("nvr") == 0 then
    notify.warn(
      "lazygit: nvr not found on $PATH -- lazygit's O/<C-o> need neovim-remote (pip install neovim-remote)"
    )
  end

  usercmd.create("GitsuiteLazygitBadd", function(opts)
    require("gitsuite.features.ui.lazygit.badd").run(opts.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "[gitsuite] Add file to buffer list (called via nvr from lazygit)",
  })

  usercmd.create("GitsuiteLazygitReplace", function(opts)
    require("gitsuite.features.ui.lazygit.replace").run(opts.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "[gitsuite] Replace visible editor buffer with file (called via nvr from lazygit)",
  })
end

return M
