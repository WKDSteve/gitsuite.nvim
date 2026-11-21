---@module 'gitsuite.features.status'
--- Repo status / quickfix export -- `lib.nvim.git.status_porcelain`,
--- already written, not duplicated. Native: no adapter needed.

local git = require("lib.nvim.git")
local gitq = require("gitsuite.util.gitq")
local notify = require("gitsuite.util.notify")

local M = {}

---@class Gitsuite.Status.Summary
---@field branch string|nil nil on a detached HEAD
---@field ahead integer|nil commits ahead of the upstream; nil without one
---@field behind integer|nil
---@field changed integer changed and untracked files

---What `git status --porcelain=v2 --branch -z -u` says about the branch and how many files changed. Pure.
---@param raw string
---@return Gitsuite.Status.Summary
function M.parse_summary(raw)
  local out = { changed = 0 }
  local fields = vim.split(raw or "", "\0", { plain = true })
  local i = 1
  while i <= #fields do
    local f = fields[i]
    i = i + 1
    local head = f:match("^# branch%.head (.+)$")
    local a, b = f:match("^# branch%.ab %+(%d+) %-(%d+)$")
    if head then
      out.branch = head ~= "(detached)" and head or nil
    elseif a then
      out.ahead, out.behind = tonumber(a), tonumber(b)
    elseif f:match("^[12u?] ") then
      out.changed = out.changed + 1
      -- A rename or copy (`2 ...`) is followed by its original path as a field of its own.
      if f:sub(1, 1) == "2" then i = i + 1 end
    end
  end
  return out
end

---Show repo status (branch, ahead/behind, dirty) as a notification. One git call (porcelain v2 with the branch
---header carries the branch, the upstream counts and the changed files), and the editor does not wait for it: the
---notification comes when git answered.
---@return nil
function M.repo()
  gitq.run(
    { "status", "--porcelain=v2", "--branch", "-z", "-u" },
    { read_only = true, binary = true },
    function(res)
      if res.code ~= 0 then
        notify.error("status: " .. gitq.failure(res, "not inside a git repository"))
        return
      end
      local s = M.parse_summary(res.stdout)
      local parts = { s.branch and ("branch: " .. s.branch) or "branch: (detached HEAD)" }
      local ahead, behind = (s.ahead or 0) > 0, (s.behind or 0) > 0
      if ahead or behind then
        parts[#parts + 1] = ("ahead=%s behind=%s"):format(tostring(ahead), tostring(behind))
      end
      parts[#parts + 1] = (s.changed > 0) and ("dirty (%d)"):format(s.changed) or "clean"
      notify.info(table.concat(parts, "  "))
    end
  )
end

---Export the working tree's changed files (`git status --porcelain -u`) to
---the quickfix list. The editor does not wait for git; a newer call wins over
---one that is still waiting.
---@return nil
function M.quickfix()
  local valid = gitq.ticket("status.quickfix")
  -- The paths are joined to the directory the command ran in, not the one current when git answers.
  local cwd = vim.fn.getcwd()
  gitq.run(
    { "status", "--porcelain", "-z", "-u" },
    { read_only = true, binary = true },
    function(res)
      if not valid() then return end
      local status = res.code == 0 and git.parse_status(res.stdout) or nil
      if res.code == -1 or res.timed_out then
        notify.error("status: " .. gitq.failure(res, ""))
        return
      end
      M.show_quickfix(status, cwd)
    end
  )
end

---@param status Lib.Git.StatusMap|nil
---@param cwd string
function M.show_quickfix(status, cwd)
  if not status or vim.tbl_isempty(status) then
    notify.info("status: nothing to report (clean working tree, or not a git repo)")
    return
  end

  local qf = {}
  for path, entry in pairs(status) do
    qf[#qf + 1] = {
      filename = vim.fs.joinpath(cwd, path),
      lnum = 1,
      col = 1,
      text = ("[%s] %s"):format(entry.code, path),
    }
  end
  table.sort(qf, function(a, b)
    return a.filename < b.filename
  end)

  vim.fn.setqflist({}, "r", { title = "gitsuite: status", items = qf })
  vim.cmd("copen")
end

return M
