---@module 'gitsuite.features.dashboard.bulk'
---@brief Runs one action over many repositories: queue, slots, locks, cancel, generation.
---@description
--- The walk behind every dashboard batch (`gf`, `gp`, `gu`, ...), free of any
--- buffer: the view hands in how to redraw, how to re-read a row and what to do
--- with the results, and `repo_state` carries the per-repository phases and locks
--- the table reads. So the queue's rules can be tested by themselves.

local repo_state = require("gitsuite.features.dashboard.repo_state")

---@class GitSuiteBulkTarget
---@field path string Absolute repository path
---@field name string Name shown in the progress text and the results

---@class GitSuiteBulkOpts
---@field verb string Human-readable action name, also the lock holder
---@field targets GitSuiteBulkTarget[] In row order, which is the order they start in
---@field action fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
---@field limit integer How many may run at once
---@field reread fun(path: string, on_record: fun(record: RepoDashboardRecord|nil)): nil
---@field on_reread fun(record: RepoDashboardRecord|nil): nil Stores a re-read row
---@field redraw fun(): nil Draws the table; called after every phase change
---@field on_finish fun(results: GitSuiteBulkResult[]): nil Results in `targets` order; a target never started has none
---@field handle? table Progress handle (`on_cancel`, `update`, `finish`), when one could be made

---@class GitSuiteDashboardBulk
local M = {}

---How often a batch retries a repository whose lock somebody else holds.
local LOCK_RETRY_MS = 100

---Runs `opts.action` over `opts.targets`, at most `opts.limit` at once, and
---hands all the results to `opts.on_finish` once the last slot is given back.
---
---Cancelling through the progress handle stops the queue from starting further
---repositories rather than killing the ones in flight: interrupting a `pull`
---mid-write is the one outcome worth avoiding.
---@param opts GitSuiteBulkOpts
---@return nil
function M.run(opts)
  local verb, targets, handle = opts.verb, opts.targets, opts.handle
  local total = #targets

  ---@type string[]
  local paths = {}
  for i, target in ipairs(targets) do
    paths[i] = target.path
  end

  -- Every target is queued up front, so the whole batch is visible as a column
  -- of "queued" cells instead of one row lighting up at a time with no clue
  -- what else is behind it. Per-repository phases carry this, so a row the
  -- batch is through with can take its own action meanwhile.
  --
  -- The generation keeps this batch's callbacks out of a newer batch's phases:
  -- should one start before this one is through (a page reload ends the running
  -- bulk), this one's late callbacks still release their locks but neither move
  -- the newer batch's rows nor end it.
  local generation = repo_state.begin_bulk(verb, paths)
  opts.redraw()

  local cancelled = false
  if handle then handle:on_cancel(function()
    cancelled = true
  end) end

  -- Filled per position in `targets`, so the summary lists repositories in
  -- row order whichever of the parallel ones finished first.
  ---@type table<integer, GitSuiteBulkResult>
  local results = {}
  local succeeded, completed = 0, 0
  local next_pos, running, finished = 1, 0, false

  local function finish()
    -- Clears the queue's own phases as well as the cancelled tail's. Row actions
    -- started meanwhile keep their own spinner and lock. A superseded batch ends
    -- nothing: the running bulk is the newer one's.
    repo_state.end_bulk(generation)
    opts.redraw()

    if handle then handle:finish(("%s: %d of %d repositories"):format(verb, succeeded, total)) end
    ---@type GitSuiteBulkResult[]
    local ordered = {}
    for pos = 1, total do
      if results[pos] then ordered[#ordered + 1] = results[pos] end
    end
    opts.on_finish(ordered)
  end

  local pump

  local function launch(target, pos)
    repo_state.set_phase(target.path, "fetching", generation)
    opts.redraw()
    if handle then handle:update({ text = target.name, current = completed, total = total }) end

    local function on_done(ok, err, detail, skipped)
      vim.schedule(function()
        repo_state.unlock(target.path)
        if ok then succeeded = succeeded + 1 end
        results[pos] = {
          name = target.name,
          ok = ok and true or false,
          err = (not ok) and (err or "unknown error") or nil,
          detail = ok and detail or nil,
          skipped = ok and skipped or nil,
        }

        -- The row is re-read *before* its slot is given up, not alongside it:
        -- fired off in parallel, the last repository's re-read would still be
        -- in flight when `finish()` draws the table and announces the batch as
        -- done, leaving that one row showing the state it had before its own
        -- push. The phase settles only after that re-read, so a row action
        -- started on it never races the batch's own stale refresh.
        opts.reread(target.path, function(new_record)
          vim.schedule(function()
            opts.on_reread(new_record)
            repo_state.set_phase(target.path, ok and "done" or "failed", generation)
            opts.redraw()
            running = running - 1
            completed = completed + 1
            pump()
          end)
        end)
      end)
    end

    local started, start_err = pcall(opts.action, target.path, on_done)
    if not started then on_done(false, tostring(start_err)) end
  end

  -- Fills the free slots in row order; also the way the batch ends, once the
  -- last slot is given back.
  pump = function()
    if finished then return end
    while running < opts.limit and not cancelled and next_pos <= total do
      local target = targets[next_pos]
      -- Row actions only start on settled rows and this one is still queued, so
      -- the lock is normally free; should anything else hold it, the queue waits
      -- for it rather than starting a second `git` on the same repository.
      if not repo_state.try_lock(target.path, verb) then
        vim.defer_fn(pump, LOCK_RETRY_MS)
        return
      end
      local pos = next_pos
      next_pos = next_pos + 1
      running = running + 1
      launch(target, pos)
    end
    if running == 0 and (cancelled or next_pos > total) then
      finished = true
      finish()
    end
  end

  pump()
end

return M
