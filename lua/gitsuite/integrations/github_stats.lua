---@module 'gitsuite.integrations.github_stats'
---@brief The VIEWS/CLONES cell of a dashboard row: GitHub views and clones of the last 14 days (`12/3`), from github_stats.
---@description
--- A soft dependency: the cell exists only while `github_stats` is loaded
--- (`package.loaded`, so the dashboard never pulls the plugin in), and only for
--- repositories it tracks. Everything is read from what github_stats has stored
--- on disk (`analytics.query_metric`); the dashboard never asks GitHub, so
--- opening it stays free of network access. Any failure reads as "no badge".
--- The answer per directory is cached for a short while: a redraw happens on
--- every phase change of a batch and must not re-read the stored history.

local M = {}

---How long a badge stays fresh, in seconds.
local TTL_SECONDS = 60
---The window the badge covers, as github_stats spells it.
local WINDOW = "14d"

---@type table<string, { text: string, expires_at: integer }>
local cache = {}

---Forgets every cached badge (a test, or after github_stats fetched anew).
---@return nil
function M.invalidate()
  cache = {}
end

---@param slug string
---@param metric "views"|"clones"
---@param analytics table
---@return integer|nil
local function total(analytics, slug, metric)
  local ok, stats, err =
    pcall(analytics.query_metric, { repo = slug, metric = metric, time_range = WINDOW })
  if not ok or err or type(stats) ~= "table" or type(stats.total_count) ~= "number" then
    return nil
  end
  return stats.total_count
end

---@param dir string
---@return string
local function compute(dir)
  if not package.loaded["github_stats"] then return "" end
  local ok_a, analytics = pcall(require, "github_stats.analytics")
  local ok_c, gs_config = pcall(require, "github_stats.config")
  if not (ok_a and ok_c and type(analytics) == "table" and type(gs_config) == "table") then
    return ""
  end

  local url = require("gitsuite.util.repos").origin_url(dir)
  local parsed = url and require("lib.nvim.git.remote").parse_remote(url)
  if not parsed or parsed.host ~= "github.com" then return "" end
  local slug = parsed.owner .. "/" .. parsed.repo

  local ok_r, tracked = pcall(gs_config.get_repos)
  if not ok_r or type(tracked) ~= "table" or not vim.tbl_contains(tracked, slug) then return "" end

  local views, clones = total(analytics, slug, "views"), total(analytics, slug, "clones")
  if not views and not clones then return "" end
  if (views or 0) == 0 and (clones or 0) == 0 then return "" end
  return ("%d/%d"):format(views or 0, clones or 0)
end

---The badge text for the repository at `dir`, `""` when there is none.
---@param dir string
---@return string
function M.badge(dir)
  local now = os.time()
  local hit = cache[dir]
  if hit and hit.expires_at > now then return hit.text end
  local ok, text = pcall(compute, dir)
  if not ok then text = "" end
  cache[dir] = { text = text, expires_at = now + TTL_SECONDS }
  return text
end

return M
