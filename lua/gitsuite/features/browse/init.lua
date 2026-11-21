---@module 'gitsuite.features.browse'
--- `:Git browse file|selection|repo` -- open the current file/selection/repo
--- on its web host (GitHub, GitLab, Codeberg, or a self-hosted instance
--- declared in `cfg.browse.hosts`). Replaces vim-rhubarb's `:Gbrowse`
--- entirely.
---
--- reposcope.nvim has no file->web-URL mapping to reuse (only hardcoded
--- README-fetch URLs, see README.md). open.nvim is an optional dependency
--- of THIS feature only (LUA-05): gitsuite.nvim as a whole stays usable
--- without it, only `:Git browse *` degrades to a clear error.
---
--- This file is the impure shell (buffer/cursor reads, the actual git
--- calls, opening the browser) around `lib.nvim.git.remote`'s pure
--- parsing/building (GS-16: moved there once github_stats.nvim and
--- docmap.nvim needed the same remote-URL grammar this module used
--- to own alone as `features/browse/url.lua`).

local gitq = require("gitsuite.util.gitq")
local url = require("lib.nvim.git.remote")
local notify = require("gitsuite.util.notify")

local M = {}

---@internal
---@param bufnr integer
---@return string|nil dir
---@return string|nil basename
local function file_location(bufnr)
  local abspath = vim.api.nvim_buf_get_name(bufnr)
  if abspath == "" then return nil, nil end
  return vim.fs.dirname(abspath), vim.fs.basename(abspath)
end

---@internal
--- Resolve remote/host/branch/relative-path for the current buffer.
--- Every failure reason is distinct (ERR-10/11) so the caller can say
--- exactly what went wrong instead of one generic "browse failed".
---
--- The three git queries (`remote get-url`, `symbolic-ref`, `ls-files`) start
--- together and the editor does not wait for them: `done` comes from the event
--- loop. Only a detached HEAD costs a fourth call (`rev-parse --short HEAD`),
--- after the others.
---@param bufnr integer
---@param done fun(r: { kind: "github"|"gitlab"|"codeberg", remote: { host: string, owner: string, repo: string }, branch: string, rel_path: string }|nil, err: string|nil)
local function resolve(bufnr, done)
  local cfg = require("gitsuite.config").get()
  local dir, basename = file_location(bufnr)
  if not dir then return done(nil, "buffer has no file") end

  gitq.all({
    -- `--`: a remote name is caller data and must not be readable as an option.
    { args = { "remote", "get-url", "--", "origin" }, opts = { dir = dir } },
    { args = { "symbolic-ref", "--short", "HEAD" }, opts = { dir = dir } },
    { args = { "ls-files", "--full-name", "--", basename }, opts = { dir = dir } },
  }, function(res)
    if res[1].code == -1 or res[1].timed_out then return done(nil, gitq.failure(res[1], "")) end
    local remote_url = gitq.line(res[1])
    if not remote_url then return done(nil, "no 'origin' remote") end
    local remote = url.parse_remote(remote_url)
    if not remote then return done(nil, "could not parse remote URL: " .. remote_url) end

    local kind = url.host_kind(remote.host, cfg.browse.hosts)
    if not kind then
      return done(
        nil,
        ("unrecognized host '%s' -- add it to browse.hosts in setup()"):format(remote.host)
      )
    end

    local function finish(branch)
      if not branch then
        return done(nil, "could not determine a branch or commit to link against")
      end
      local rel_path = gitq.line(res[3])
      if not rel_path then return done(nil, "file is not tracked by git") end
      done({ kind = kind, remote = remote, branch = branch, rel_path = rel_path }, nil)
    end

    -- The branch, or (detached HEAD) the short commit hash.
    local branch = gitq.line(res[2])
    if branch then return finish(branch) end
    gitq.run({ "rev-parse", "--short", "HEAD" }, { dir = dir }, function(short)
      finish(gitq.line(short))
    end)
  end)
end

---@internal
--- Resolve, then build and open the URL; a newer `:Git browse` wins over one
--- that is still waiting for git (its late answer opens nothing).
---@param build fun(r: table): string|nil, string|nil the URL, or nil and why not
local function browse(build)
  local valid = gitq.ticket("browse")
  resolve(vim.api.nvim_get_current_buf(), function(r, err)
    if not valid() then return end
    if not r then
      notify.error("browse: " .. err)
      return
    end
    local web_url, why = build(r)
    if not web_url then
      notify.error("browse: " .. why)
      return
    end
    M.open_url(web_url)
  end)
end

---Open `web_url` in a browser through open.nvim.
---@param web_url string
function M.open_url(web_url)
  local ok_req, open_registry = pcall(require, "open.registry")
  if not ok_req then
    notify.error(
      'browse: open.nvim is not installed -- install "WKDSteve/open.nvim" to use :Git browse'
    )
    return
  end
  local ok, dispatch_err = open_registry.dispatch("browser", {
    text = web_url,
    is_url = true,
    is_path = false,
  })
  if not ok then notify.error("browse: " .. (dispatch_err or "could not open a browser")) end
end

---Open the current file on its web host (no line anchor).
---@return nil
function M.file()
  browse(function(r)
    return url.build(r.kind, r.remote, r.branch, r.rel_path)
  end)
end

---Open the current visual selection (line range from the `'<`/`'>` marks)
---on its web host. The marks are read now, not when git answered.
---@return nil
function M.selection()
  local first = vim.fn.getpos("'<")[2]
  local last = vim.fn.getpos("'>")[2]
  if first > last then
    first, last = last, first
  end
  browse(function(r)
    if first == 0 or last == 0 then return nil, 'no visual selection ("\'<"/"\'>" not set)' end
    return url.build(r.kind, r.remote, r.branch, r.rel_path, first, last)
  end)
end

---Open the repository root on its web host.
---@return nil
function M.repo()
  browse(function(r)
    return url.build(r.kind, r.remote, r.branch, nil)
  end)
end

return M
