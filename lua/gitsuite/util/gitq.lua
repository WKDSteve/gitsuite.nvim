---@module 'gitsuite.util.gitq'
---@brief git queries of the commands on the current repository, without freezing the editor.
---@description
--- The `:Git status`, `:Git browse` and `:Git ui lazygit` commands used to ask git several times in a row, each
--- call blocking the editor. This module runs them through `lib.nvim.git.run_async` instead:
---
---   * `all` starts several queries at once and answers once, when the last one is back (`lib.nvim.async.all`).
---   * `idle` is true once no query and no answer of `all` is still to come (`lib.nvim.async.in_flight`).
---   * `ticket` lets a newer request of the same command win: the answer of an older one is dropped, so a late
---     answer never opens a browser, a terminal or a quickfix list the user already asked for again
---     (`lib.nvim.async.latest_wins`, one gate keyed by command).
---   * `failure` names why a query failed (git missing, the deadline, git's own message).

local M = {}

local async = require("lib.nvim.async")

---Deadline of one query: these are quick reads of a local repository.
M.TIMEOUT_MS = 10000

---@class Gitsuite.Gitq.Query
---@field args string[] what comes after `git`
---@field opts? Lib.Git.RunOpts `dir`, `read_only`, ...

---Queries and `all` answers still to come. A tracked callback is uncounted only after it returned, so a query
---started from an answer keeps the count up: idle means the whole chain is done.
local flight = async.in_flight()

---One gate for every command; `ticket(key)` supersedes only tickets of the same key.
local gate = async.latest_wins()

---Run one query; `done` is called from the event loop.
---@param args string[]
---@param opts Lib.Git.RunOpts|nil
---@param done fun(res: Lib.Git.RunResult)
---@return { stop: fun() }|nil handle kills git and drops its answer
function M.run(args, opts, done)
  local o = vim.tbl_extend("keep", opts or {}, { timeout_ms = M.TIMEOUT_MS })
  return require("lib.nvim.git").run_async(args, o, flight:track(done))
end

---Whether no query is waiting for git: what a test waits for (`vim.wait(ms, gitq.idle)`) after a command. A
---query started from an answer counts before that answer returns, so idle means the whole chain is done.
---@return boolean
function M.idle()
  return flight:idle()
end

---Start every query at once; `done` gets their results in the order of `queries`, once, on a later tick.
---@param queries Gitsuite.Gitq.Query[]
---@param done fun(results: Lib.Git.RunResult[])
---@return { stop: fun() } handle kills the queries still running; `done` is then called with what was back
function M.all(queries, done)
  local tasks = {}
  for i, q in ipairs(queries) do
    tasks[i] = function(settle)
      return M.run(q.args, q.opts, function(res)
        settle(res)
      end)
    end
  end
  return async.all(tasks, function(results)
    done(results)
  end, { in_flight = flight })
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

---A ticket for one request of command `key`: `valid()` is true until the next ticket of the same key is drawn.
---@param key string
---@return fun(): boolean valid
function M.ticket(key)
  return gate:ticket(key)
end

return M
