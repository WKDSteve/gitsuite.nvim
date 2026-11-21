---@module 'gitsuite.features.branch'
--- List/switch/show the current branch. Extracted from
--- `ui.nvim/statusline/modules/git_clickable` (see README): only the
--- list/switch logic is reused here, not the click/statusline/context-menu
--- wiring, which stays ui.nvim-specific. Routed through `lib.nvim.git`/
--- `lib.nvim.cross.run_argv` (SEC-01: argv, no shell) instead of the
--- original's `vim.fn.systemlist` -- gitsuite.nvim already treats lib.nvim
--- as a hard dependency, so there is no reason not to.
---
--- Since GS-15, `git_clickable`'s left click delegates back to `M.switch()`
--- here when gitsuite.nvim is loaded (`ui.util.soft_require`, its own
--- `pcall`) -- soft in both directions, never a hard dependency either way
--- (K-5c): this module has no knowledge of ui.nvim at all.
---
--- Native: no adapter needed, only `git` on `$PATH`.
---
--- GS-24, opt-in (`cfg.branch.sessions`, default off): `checkout()` saves
--- the current branch's window/tab layout via sessions.nvim (optional soft
--- dep) before switching, then loads the target branch's layout after --
--- sessions.nvim's own branch-aware naming does the actual per-branch
--- bookkeeping, this module only calls `save(nil)`/`load(nil)` either side
--- of the checkout that moves HEAD.

local gitq = require("gitsuite.util.gitq")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---The local branches, newest first, and which one HEAD is on (nil when detached), from
---one `for-each-ref` in the background: `%(HEAD)` marks the current branch with `*`.
---It used to be `for-each-ref` plus `symbolic-ref`, both synchronous.
---@param done fun(branches: string[], current: string|nil, res: Lib.Git.RunResult)
local function local_branches(done)
  gitq.run(
    {
      "for-each-ref",
      "--sort=-creatordate",
      "--format=%(HEAD)%(refname:short)",
      "refs/heads/",
    },
    nil,
    function(res)
      local branches, current = {}, nil
      if res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\r\n]+") do
          local mark, name = line:sub(1, 1), line:sub(2)
          if name ~= "" then
            branches[#branches + 1] = name
            if mark == "*" then current = name end
          end
        end
      end
      done(branches, current, res)
    end
  )
end

---List local branches.
---@return nil
function M.list()
  local_branches(function(branches)
    if #branches == 0 then
      notify.info("branch: no local branches (not a repo, git not on $PATH, or no commits yet)")
      return
    end
    notify.info(table.concat(branches, "\n"))
  end)
end

---Show the current branch (or the short commit hash in detached HEAD), from one
---`git log -1 --format=%h%x00%D` in the background: `%D` names the branch as
---`HEAD -> <branch>` unless HEAD is detached. A repository without commits has no log;
---its branch then comes from `symbolic-ref`.
---@return nil
function M.current()
  gitq.run({ "log", "-1", "--format=%h%x00%D" }, nil, function(res)
    local line = gitq.line(res)
    if line then
      local hash, decorations = line:match("^([^%z]*)%z(.*)$")
      local name = decorations and decorations:match("HEAD %-> ([^,]+)")
      if name then
        notify.info("branch: " .. vim.trim(name))
      else
        notify.info("branch: detached HEAD" .. ((hash and hash ~= "") and (" @ " .. hash) or ""))
      end
      return
    end
    gitq.run({ "symbolic-ref", "--short", "-q", "HEAD" }, nil, function(sym)
      local name = gitq.line(sym)
      notify.info(name and ("branch: " .. name) or "branch: detached HEAD")
    end)
  end)
end

---@internal
--- sessions.nvim (optional soft dep, GS-24) -- pcall-guarded both at
--- `require` and at the call itself, so a missing or misbehaving
--- sessions.nvim can never block a checkout.
---@param fn "save"|"load"
local function sessions_core(fn)
  local ok, sessions = pcall(require, "sessions.core")
  if ok then pcall(sessions[fn], nil) end
end

---@internal
---@param choice string|nil
---@param current string|nil
local function checkout(choice, current)
  if not choice or choice == current then return end

  -- GS-24, opt-in (cfg.branch.sessions, default false): save the CURRENT
  -- branch's window/tab layout before HEAD moves -- sessions.nvim's own
  -- branch-aware naming (sessions.git.resolve_name, cfg.branch_aware) keys
  -- it under the branch we are about to leave, since git.checkout() has not
  -- run yet at this point.
  local sessions_enabled = require("gitsuite.config").get().branch.sessions
  if sessions_enabled then sessions_core("save") end

  -- A leading `-` would make git read the choice as an option: refused, like
  -- lib.nvim.git.checkout does.
  if choice:sub(1, 1) == "-" then
    notify.error(("branch: git checkout: invalid revision %s"):format(vim.inspect(choice)))
    return
  end

  -- In the background (it used to block for the whole checkout); git's own
  -- reason on failure comes from stderr.
  gitq.run({ "checkout", choice }, nil, function(res)
    if res.code ~= 0 then
      local why = vim.trim(res.stderr or "")
      notify.error(
        ("branch: git checkout %s failed: %s"):format(
          choice,
          gitq.failure(res, why ~= "" and why or "git checkout failed")
        )
      )
      return
    end
    notify.info("branch: switched to " .. choice)

    gitq.run({ "rev-parse", "--show-toplevel" }, nil, function(top)
      local dir = gitq.line(top)
      if dir then require("gitsuite.events").branch_switched(dir, choice) end

      -- ...then load the TARGET branch's layout, now that HEAD has actually
      -- moved and sessions.nvim's own resolve_name() sees the new branch.
      -- Loading can discard unsaved buffers -- sessions.nvim's own call, this
      -- module has no say in it -- which is exactly why this whole feature
      -- stays opt-in.
      if sessions_enabled then sessions_core("load") end
    end)
  end)
end

---Switch to another local branch, picked via pickers.nvim's `git_branches`
---picker (preview included) when available, `vim.ui.select` otherwise
---(LUA-05: `gitsuite.integrations.pickers_nvim` is the only module that
---knows pickers.nvim exists).
---@return nil
function M.switch()
  -- The list and the current branch come from one query in the background; the
  -- picker opens once it answers. A newer :Git branch switch wins: the answer of an
  -- older one opens nothing.
  local valid = gitq.ticket("branch.switch")
  local_branches(function(branches, current)
    if not valid() then return end
    M._offer(branches, current)
  end)
end

---@internal
---Offer `branches` for a switch away from `current` (the picker, else vim.ui.select).
---@param branches string[]
---@param current string|nil
function M._offer(branches, current)
  if #branches == 0 then
    notify.error("branch: no local branches to switch to")
    return
  end
  local is_local = {}
  for _, b in ipairs(branches) do
    is_local[b] = true
  end

  local ok_req, pickers_nvim = pcall(require, "gitsuite.integrations.pickers_nvim")
  if ok_req and pickers_nvim.available() then
    local started = pickers_nvim.branch_picker(function(choice)
      -- Telescope's and fzf-lua's own `git_branches` picker list
      -- remote-tracking branches by default (an engine-level default,
      -- unrelated to gitsuite) -- vim.ui.select below only ever offers
      -- `local_branches()`. Reject anything the picker returned that is not
      -- one of those local branches instead of silently detaching HEAD onto
      -- a remote ref while reporting "switched to <choice>".
      if not is_local[choice] then
        notify.error(
          ("branch: %q is not a local branch -- remote-tracking refs are not supported by switch()"):format(
            choice
          )
        )
        return
      end
      checkout(choice, current)
    end)
    if started then return end
  end

  vim.ui.select(branches, {
    prompt = "Switch branch" .. (current and (" (current: " .. current .. ")") or ""),
  }, function(choice)
    checkout(choice, current)
  end)
end

return M
