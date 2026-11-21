---@module 'gitsuite.features.dashboard.precheck'
---@brief `dashboard.fetch_precheck = "github"`: one GitHub GraphQL query tells which repositories need a fetch at all.
---@description
--- A dashboard fetch (`gf`, fetch on open) costs one `git fetch` per repository,
--- and on a page of eighty clones most of them bring nothing. GitHub knows the
--- tip of every repository's default branch: one GraphQL query (in batches of
--- `BATCH`) asks for all of the page at once, and a repository whose
--- `origin/<default branch>` already points there is not fetched.
---
--- What is compared, and what falls back to the normal fetch:
---
---   * only the default branch, and only while it is the branch checked out:
---     a clone on another branch is fetched as before (its own upstream may have
---     moved), and so is one whose remote-tracking ref for it is missing;
---   * other remote branches and tags are not looked at: a repository whose
---     default branch did not move is reported up to date even if a feature
---     branch did (fetch that one by hand, `gf` on its row, or switch the option off);
---   * an `origin` that is not github.com, an owner or name with unusual
---     characters, no token (`gh auth login`, or github_stats' token variable),
---     an answer that fails or leaves the repository out: fetched as before.
---
--- Everything local is read from files (`.git/HEAD`, `refs/remotes/origin/...`,
--- `packed-refs`), never by starting git: the point is fewer processes. The
--- request goes through `lib.nvim.net.github`, the client github_stats.nvim uses
--- as well (same token rules, the token only through curl's `-K -`).

local github = require("lib.nvim.net.github")
local repos_util = require("gitsuite.util.repos")

local M = {}

---Repositories per GraphQL query. GitHub charges one point for such a query
---whatever the count; 50 keeps the query text and the answer small.
M.BATCH = 50

---How long the query may take before the precheck gives up and every
---repository is fetched as before.
M.TIMEOUT_MS = 10000

---Seams for the specs: the request and the token lookup.
M.request = github.request
M.token = github.token

---@type integer
local MAX_REF_FILE = 4 * 1024 * 1024

---@param path string
---@return string|nil
local function read(path)
  local text = require("lib.nvim.fs.read_bounded")(path, MAX_REF_FILE, { follow_symlinks = false })
  return text
end

---A branch name that is safe to join into a ref path.
---@param name string|nil
---@return boolean
local function plain_ref(name)
  return type(name) == "string"
    and name ~= ""
    and name:match("^[%w%._/%-]+$") ~= nil
    and not name:find("..", 1, true)
end

---@param s string|nil
---@return boolean
local function plain_name(s)
  return type(s) == "string" and s:match("^[%w%._%-]+$") ~= nil
end

---What the precheck needs of one clone, read from its files; nil when it
---cannot take part (it is then fetched as before).
---@param dir string
---@return { slug: string, owner: string, name: string, branch: string, oid: string }|nil
function M.local_state(dir)
  local url = repos_util.origin_url(dir)
  if not url then return nil end
  local remote = require("lib.nvim.git.remote").parse_remote(url)
  if not remote or remote.host ~= "github.com" then return nil end
  local owner, name = remote.owner, remote.repo
  if not (plain_name(owner) and plain_name(name)) then return nil end

  local head = read(dir .. "/.git/HEAD")
  local branch = head and head:match("^ref: refs/heads/([^\r\n]+)")
  if not plain_ref(branch) then return nil end

  local ref = "refs/remotes/origin/" .. branch
  local oid = read(dir .. "/.git/" .. ref)
  oid = oid and oid:match("^(%x+)%s*$")
  if not oid then
    local packed = read(dir .. "/.git/packed-refs") or ""
    for line in packed:gmatch("[^\r\n]+") do
      local o, r = line:match("^(%x+) (%S+)$")
      if r == ref then
        oid = o
        break
      end
    end
  end
  if not oid or #oid < 40 then return nil end
  return {
    slug = owner .. "/" .. name,
    owner = owner,
    name = name,
    branch = branch,
    oid = oid:lower(),
  }
end

---The GraphQL query for `states`, one alias per repository (`r1`, `r2`, ...).
---Owner and name are plain (`plain_name`), so quoting them is enough.
---@param states { owner: string, name: string }[]
---@return string
function M.query(states)
  local parts = {}
  for i, s in ipairs(states) do
    parts[#parts + 1] = ('r%d: repository(owner: "%s", name: "%s") { defaultBranchRef { name target { oid } } }'):format(
      i,
      s.owner,
      s.name
    )
  end
  return "query { " .. table.concat(parts, " ") .. " }"
end

---@class GitSuitePrecheck
---@field state "idle"|"running"|"done"
---@field fresh table<string, boolean> Paths whose default branch GitHub reports where `origin/<branch>` already is
---@field saved integer Fetches not run because of `fresh`
---@field asked integer Repositories the query asked about
---@field failure string|nil Why (part of) the precheck fell back to fetching
---@field waiting fun()[]
local Precheck = {}
Precheck.__index = Precheck

---A precheck that has not started yet: until `start`, `wait` runs at once and
---nothing counts as fresh.
---@return GitSuitePrecheck
function M.new()
  return setmetatable({ state = "idle", fresh = {}, saved = 0, asked = 0, waiting = {} }, Precheck)
end

---@private
function Precheck:_finish()
  self.state = "done"
  local waiting = self.waiting
  self.waiting = {}
  for _, fn in ipairs(waiting) do
    pcall(fn)
  end
end

---Asks GitHub about `paths` (once; a second call is ignored). Answers come
---asynchronously; `wait` holds callers until then.
---@param paths string[]
---@return nil
function Precheck:start(paths)
  if self.state ~= "idle" then return end
  self.state = "running"
  vim.schedule(function()
    local ok, err = pcall(self._run, self, paths)
    if not ok then
      self.failure = tostring(err)
      self:_finish()
    end
  end)
end

---@private
---@param paths string[]
function Precheck:_run(paths)
  ---@type { path: string, owner: string, name: string, branch: string, oid: string }[]
  local states = {}
  for _, path in ipairs(paths) do
    local ok, s = pcall(M.local_state, path)
    if ok and s then
      s.path = path
      states[#states + 1] = s
    end
  end
  if #states == 0 then return self:_finish() end

  local env_var
  local gs = package.loaded["github_stats.config"]
  if gs and type(gs.get) == "function" then
    local ok_cfg, cfg = pcall(gs.get)
    if ok_cfg and type(cfg) == "table" and type(cfg.token_env_var) == "string" then
      env_var = cfg.token_env_var
    end
  end
  local token, why = M.token({ env_var = env_var })
  if not token then
    self.failure = "no GitHub token (" .. tostring(why) .. ")"
    return self:_finish()
  end

  local pending = 0
  for first = 1, #states, M.BATCH do
    local batch = vim.list_slice(states, first, first + M.BATCH - 1)
    pending = pending + 1
    self.asked = self.asked + #batch
    M.request("/graphql", {
      method = "POST",
      body = vim.json.encode({ query = M.query(batch) }),
      token = token,
      timeout_ms = M.TIMEOUT_MS,
    }, function(result, err)
      local data = result and type(result.data) == "table" and result.data.data
      if type(data) ~= "table" then
        self.failure = err or "GitHub gave no answer"
      else
        for i, s in ipairs(batch) do
          local repo = data["r" .. i]
          local ref = type(repo) == "table" and repo.defaultBranchRef
          local oid = type(ref) == "table" and type(ref.target) == "table" and ref.target.oid
          if ref and ref.name == s.branch and type(oid) == "string" and oid:lower() == s.oid then
            self.fresh[s.path] = true
          end
        end
      end
      pending = pending - 1
      if pending == 0 then self:_finish() end
    end)
  end
end

---Runs `fn` once the answer is in (at once when the precheck never started or
---is through).
---@param fn fun()
---@return nil
function Precheck:wait(fn)
  if self.state == "running" then
    self.waiting[#self.waiting + 1] = fn
  else
    fn()
  end
end

---A fetch action that skips the repositories GitHub reported unchanged.
---@param action fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
---@return fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
function Precheck:wrap_action(action)
  return function(repo, on_done)
    self:wait(function()
      if self.fresh[repo] then
        self.saved = self.saved + 1
        on_done(true)
      else
        action(repo, on_done)
      end
    end)
  end
end

---A row re-read that leaves an unfetched row as it is: nothing about it changed.
---@param reread fun(path: string, on_record: fun(record: RepoDashboardRecord|nil)): nil
---@return fun(path: string, on_record: fun(record: RepoDashboardRecord|nil)): nil
function Precheck:wrap_reread(reread)
  return function(path, on_record)
    if self.fresh[path] then
      on_record(nil)
    else
      reread(path, on_record)
    end
  end
end

---The line the batch summary ends with, nil when there is nothing to say.
---@param total integer Repositories the batch ran for
---@return string|nil
function Precheck:summary(total)
  if self.state == "idle" then return nil end
  local line
  if self.asked > 0 then
    line = ("GitHub precheck: %d of %d fetches saved"):format(self.saved, total)
  end
  if self.failure then
    local fell = ("GitHub precheck fell back to fetching: %s"):format(self.failure)
    line = line and (line .. "\n" .. fell) or fell
  end
  return line
end

return M
