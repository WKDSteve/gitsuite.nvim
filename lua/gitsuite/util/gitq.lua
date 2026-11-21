---@module 'gitsuite.util.gitq'
---@brief git queries of the commands on the current repository, without freezing the editor.
---@description
--- The `:Git status`, `:Git browse` and `:Git ui lazygit` commands used to ask git several times in a row, each
--- call blocking the editor. This module runs them through `lib.nvim.git.run_async` instead:
---
---   * `all` starts several queries at once and answers once, when the last one is back.
---   * `ticket` lets a newer request of the same command win: the answer of an older one is dropped, so a late
---     answer never opens a browser, a terminal or a quickfix list the user already asked for again.
---   * `failure` names why a query failed (git missing, the deadline, git's own message).

local M = {}

---Deadline of one query: these are quick reads of a local repository.
M.TIMEOUT_MS = 10000

---@class Gitsuite.Gitq.Query
---@field args string[] what comes after `git`
---@field opts? Lib.Git.RunOpts `dir`, `read_only`, ...

---Queries started and not answered yet.
local inflight = 0

---Run one query; `done` is called from the event loop.
---@param args string[]
---@param opts Lib.Git.RunOpts|nil
---@param done fun(res: Lib.Git.RunResult)
function M.run(args, opts, done)
  local o = vim.tbl_extend("keep", opts or {}, { timeout_ms = M.TIMEOUT_MS })
  inflight = inflight + 1
  require("lib.nvim.git").run_async(args, o, function(res)
    inflight = inflight - 1
    done(res)
  end)
end

---Whether no query is waiting for git: what a test waits for (`vim.wait(ms, gitq.idle)`) after a command. A
---query started from an answer counts before that answer returns, so idle means the whole chain is done.
---@return boolean
function M.idle()
  return inflight == 0
end

---Start every query at once; `done` gets their results in the order of `queries`, once.
---@param queries Gitsuite.Gitq.Query[]
---@param done fun(results: Lib.Git.RunResult[])
function M.all(queries, done)
  local results = {}
  -- +1 for this function itself: an answer that comes at once must not finish before the last query started.
  local pending = #queries + 1
  local function settle()
    pending = pending - 1
    if pending == 0 then done(results) end
  end
  for i, q in ipairs(queries) do
    M.run(q.args, q.opts, function(res)
      results[i] = res
      settle()
    end)
  end
  settle()
end

---The first line of a successful query, trimmed; nil when it failed or printed nothing.
---@param res Lib.Git.RunResult
---@return string|nil
function M.line(res)
  if not res or res.code ~= 0 then return nil end
  local first = vim.trim((res.stdout or ""):match("^[^\n]*") or "")
  return first ~= "" and first or nil
end

---Why a query failed, for a message: git missing and the deadline are named; otherwise `fallback`.
---@param res Lib.Git.RunResult
---@param fallback string
---@return string
function M.failure(res, fallback)
  if res.timed_out then return ("git timed out after %d ms"):format(M.TIMEOUT_MS) end
  if res.code == -1 then return "git could not be started: " .. vim.trim(res.stderr or "") end
  return fallback
end

---@type table<string, integer>
local generation = {}

---A ticket for one request of command `key`: `valid()` is true until the next ticket of the same key is drawn.
---@param key string
---@return fun(): boolean valid
function M.ticket(key)
  generation[key] = (generation[key] or 0) + 1
  local mine = generation[key]
  return function()
    return generation[key] == mine
  end
end

return M
