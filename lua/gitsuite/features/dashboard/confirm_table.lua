---@module 'gitsuite.features.dashboard.confirm_table'
--- The table the dashboard's bulk confirmations show: one row per repository that will
--- be acted on, with how many commits it has to pull and to push, and under it the
--- repositories that cannot be (diverged, no upstream, never fetched) with the reason.
---
--- The confirm dialog centres every line of its question on its own, so every line
--- built here is padded to the same display width: that keeps the columns aligned.
---
--- Pure: takes records and index sets, returns lines. The view owns the dialog.

local M = {}

---How many repository rows of each block are shown before "+N more".
M.MAX_ROWS = 12

local NAME_MAX, BRANCH_MAX = 30, 18

---@class DashboardTableSkip
---@field index integer Record index
---@field reason string Why the repository is left out, e.g. "diverged"

---How many rows each block may show. The dialog cuts a question that is taller than the
---editor from the bottom, which would drop the "not synced" block first, so the rows are
---budgeted against the editor's height: a question line, headers, totals, buttons and
---borders take about 14 lines, and a second block needs its share.
---@param has_skipped boolean
---@return integer
function M.row_budget(has_skipped)
  local free = vim.o.lines - 14
  if has_skipped then free = math.floor(free / 2) end
  return math.max(3, math.min(M.MAX_ROWS, free))
end

---@private
---@internal
---`s` cut to `max` display cells with an ellipsis, then right-padded to `width`.
---@param s string
---@param max integer
---@return string
local function clip(s, max)
  if vim.fn.strdisplaywidth(s) <= max then return s end
  return vim.fn.strcharpart(s, 0, max - 1) .. "…"
end

---@private
---@internal
---@param s string
---@param width integer
---@param right? boolean Right-align instead
---@return string
local function pad(s, width, right)
  local gap = string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(s)))
  return right and (gap .. s) or (s .. gap)
end

---@private
---@internal
---@param n integer|nil
---@return string
local function count(n)
  return (n or 0) > 0 and tostring(n) or "-"
end

---Builds the lines: a header and one row per `targets` index, then (if any) a
---second block for `skipped`, then a totals line for the targets.
---@param records RepoDashboardRecord[]
---@param targets integer[] Record indices that will be acted on
---@param skipped? DashboardTableSkip[] Repositories left out, with the reason
---@param max_rows? integer Rows per block before "+N more"; defaults to `M.MAX_ROWS`
---@return string[]
function M.lines(records, targets, skipped, max_rows)
  skipped = skipped or {}
  max_rows = max_rows or M.row_budget(#skipped > 0)
  -- The dialog wraps a line wider than itself, which would wreck the columns: on a
  -- narrow window the name and branch columns give way first.
  local name_max = math.max(10, math.min(NAME_MAX, vim.o.columns - 60))
  local branch_max = math.max(6, math.min(BRANCH_MAX, vim.o.columns - 72))

  local function row(i, last)
    local r = records[i]
    return {
      clip(r.name or "?", name_max),
      clip(r.branch or "", branch_max),
      count(r.behind),
      count(r.ahead),
      last or "",
    }
  end

  -- Rows first, so the widths can be taken from what is shown.
  local blocks = {
    { head = { "REPOSITORY", "BRANCH", "↓ PULL", "↑ PUSH", "" }, rows = {}, more = 0 },
  }
  for n, i in ipairs(targets) do
    if n > max_rows then
      blocks[1].more = #targets - max_rows
      break
    end
    blocks[1].rows[n] = row(i)
  end
  if #skipped > 0 then
    local block =
      { head = { "NOT SYNCED", "BRANCH", "↓ PULL", "↑ PUSH", "REASON" }, rows = {}, more = 0 }
    for n, s in ipairs(skipped) do
      if n > max_rows then
        block.more = #skipped - max_rows
        break
      end
      block.rows[n] = row(s.index, s.reason)
    end
    blocks[#blocks + 1] = block
  end

  local widths = { 0, 0, 0, 0, 0 }
  for _, b in ipairs(blocks) do
    for _, cells in ipairs(vim.list_extend({ b.head }, b.rows)) do
      for c = 1, 5 do
        widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(cells[c]))
      end
    end
  end

  local function format(cells)
    local parts = {
      pad(cells[1], widths[1]),
      pad(cells[2], widths[2]),
      pad(cells[3], widths[3], true),
      pad(cells[4], widths[4], true),
    }
    local line = table.concat(parts, "  ")
    if widths[5] > 0 then line = line .. "  " .. pad(cells[5], widths[5]) end
    return line
  end

  local total_pull, total_push = 0, 0
  for _, i in ipairs(targets) do
    total_pull = total_pull + (records[i].behind or 0)
    total_push = total_push + (records[i].ahead or 0)
  end

  local out = {}
  for n, b in ipairs(blocks) do
    if n > 1 then out[#out + 1] = "" end
    out[#out + 1] = format(b.head)
    for _, cells in ipairs(b.rows) do
      out[#out + 1] = format(cells)
    end
    if b.more > 0 then out[#out + 1] = ("+%d more"):format(b.more) end
    if n == 1 then
      out[#out + 1] = format({
        "TOTAL",
        "",
        tostring(total_pull),
        tostring(total_push),
        "",
      })
    end
  end

  local width = 0
  for _, l in ipairs(out) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  for k, l in ipairs(out) do
    out[k] = pad(l, width)
  end
  return out
end

---One line on what `gS` / `gu` are going to meet. Those fetch first and decide the
---direction afterwards, so there is no table to show, but the counts as the last fetch
---left them tell how much is pending and what will be left alone. `nil` when nothing is
---known to be pending (a never-fetched dashboard).
---@param records RepoDashboardRecord[]
---@param indices integer[]
---@param verb "sync"|"update"
---@return string|nil
function M.summary(records, indices, verb)
  local behind, ahead, diverged = 0, 0, 0
  for _, i in ipairs(indices) do
    local r = records[i]
    if r.has_upstream then
      local a, b = r.ahead or 0, r.behind or 0
      if a > 0 and b > 0 then
        diverged = diverged + 1
      elseif b > 0 then
        behind = behind + 1
      elseif a > 0 then
        ahead = ahead + 1
      end
    end
  end
  local parts = {}
  if behind > 0 then parts[#parts + 1] = ("%d to pull"):format(behind) end
  if verb == "sync" and ahead > 0 then parts[#parts + 1] = ("%d to push"):format(ahead) end
  if diverged > 0 then
    parts[#parts + 1] = ("%d diverged, left alone (gs lists them)"):format(diverged)
  end
  if #parts == 0 then return nil end
  return "As of the last fetch: " .. table.concat(parts, ", ")
end

---The reason a repository cannot be pulled or pushed by a batch, or nil if it can.
---@param r RepoDashboardRecord
---@return string|nil
function M.problem(r)
  if not r.has_upstream then return "no upstream" end
  if (r.ahead or 0) > 0 and (r.behind or 0) > 0 then return "diverged" end
  return nil
end

return M
