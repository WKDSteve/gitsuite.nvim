---@module 'gitsuite.features.dashboard.sync_scope'
--- What the dashboard's `gs` (sync what has something to sync) acts on.
---
--- `gS` fetches every repository on the page, which is the point when nothing is
--- known yet and wasted time over forty clones right after a `gf`. `gs` goes by the
--- status on screen instead: only the repositories ahead of or behind their upstream.
---
--- It reads the commit counts and not `state`: a dirty repository's state is "dirty"
--- whatever its counts say, and it has commits to push all the same.
---
--- Two kinds of repository are left out and named, not dropped silently: a diverged
--- one, because a sync could only report it as failed, and one that looks level but
--- has no fetch recorded, because its zero counts prove nothing (as in `pull_scope`).
---
--- Pure: takes the records and a fetch-time lookup, returns the index sets and the
--- text. The view owns the dialog.

local gitfs = require("gitsuite.features.plugins.gitfs")
local names_of = require("gitsuite.features.dashboard.pull_scope").names_of

local M = {}

---@class DashboardSyncPlan
---@field targets integer[] Record indices to sync, in row order
---@field behind integer How many of `targets` are behind their upstream
---@field ahead integer How many of `targets` are ahead of their upstream
---@field diverged integer[] Indices both ahead and behind, left out
---@field unfetched integer[] Indices that look level with no fetch recorded, left out
---@field message string The confirmation question, or with no targets why there are none

---@private
---@internal
---One line for each left-out group that has members.
---@param records RepoDashboardRecord[]
---@param diverged integer[]
---@param unfetched integer[]
---@return string[]
local function left_out_lines(records, diverged, unfetched)
  local lines = {}
  if #diverged > 0 then
    lines[#lines + 1] = ("Diverged, left alone (neither pull nor push can settle it): %s"):format(
      names_of(records, diverged)
    )
  end
  if #unfetched > 0 then
    lines[#lines + 1] = ("No fetch recorded, skipped (fetch first: gf): %s"):format(
      names_of(records, unfetched)
    )
  end
  return lines
end

---Builds `gs`'s target set and text. A repository without an upstream has nothing to
---bring level and is neither a target nor named.
---@param records RepoDashboardRecord[]
---@param fetch_time? fun(path: string): integer|nil Last fetch of a repository; defaults to `FETCH_HEAD`'s mtime
---@return DashboardSyncPlan
function M.plan(records, fetch_time)
  fetch_time = fetch_time or gitfs.fetch_time
  local targets, diverged, unfetched = {}, {}, {}
  local n_behind, n_ahead = 0, 0
  for i, r in ipairs(records) do
    if r.has_upstream then
      local ahead, behind = r.ahead or 0, r.behind or 0
      if ahead > 0 and behind > 0 then
        diverged[#diverged + 1] = i
      elseif ahead > 0 then
        targets[#targets + 1] = i
        n_ahead = n_ahead + 1
      elseif behind > 0 then
        targets[#targets + 1] = i
        n_behind = n_behind + 1
      elseif fetch_time(r.path) == nil then
        unfetched[#unfetched + 1] = i
      end
    end
  end

  local lines
  if #targets > 0 then
    lines = {
      ("Sync %d repositor%s with something to sync (%d behind, %d ahead)?"):format(
        #targets,
        #targets == 1 and "y" or "ies",
        n_behind,
        n_ahead
      ),
      names_of(records, targets),
    }
  else
    lines = { "Nothing to sync: no repository is only ahead of or only behind its upstream" }
  end
  vim.list_extend(lines, left_out_lines(records, diverged, unfetched))

  return {
    targets = targets,
    behind = n_behind,
    ahead = n_ahead,
    diverged = diverged,
    unfetched = unfetched,
    message = table.concat(lines, "\n"),
  }
end

return M
