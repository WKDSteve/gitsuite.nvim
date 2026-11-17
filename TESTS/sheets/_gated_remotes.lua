-- TESTS/sheets/_gated_remotes.lua -- clones with local, gated remotes for the dashboard sheets.
-- Not a sheet (`testing.sheet` only reads *.sheet.lua); a sheet step runs it with `dofile`, the child's cwd is the
-- project root. Six clones whose `origin` is a local bare repository (file://, no network), one commit ahead of each
-- clone. The real `git fetch` runs, but every remote's upload-pack is wrapped in a small sh script
-- (`remote.origin.uploadpack`) that waits for a gate file of its own: the sheet decides when each fetch may finish.
-- The sh script needs `sh` on PATH for git (Git for Windows brings its own). It does not set gitsuite up: each
-- sheet does that with the options it is about.
--
-- Defines: `_G.sheet_root`, `_G.NAMES`, `_G.build_template()`/`_G.template_ready()`, `_G.make(name)`,
-- `_G.release(name)`, `_G.dashboard()`, `_G.dwin()`, `_G.row(name)`, `_G.count(text)`, `_G.title()`,
-- `_G.asking(text)`, `_G.said(text)`, `_G.verb()`.

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root .. "/repos", "p")
vim.fn.mkdir(root .. "/remotes", "p")
vim.fn.mkdir(root .. "/gates", "p")
_G.sheet_root = root
_G.NAMES = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" }
-- dates 400 days back from now, so the LAST COMMIT column always reads "1y" (masked in the
-- snapshots); a fixed date would turn into "10y" one day and widen the column
local date = os.date("!%Y-%m-%dT12:00:00Z", os.time() - 400 * 86400)
local env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date }
local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end
local function url(path)
  return "file://" .. (path:sub(1, 1) == "/" and "" or "/") .. path
end
-- One remote and one clone are built with git, the repositories are copies of them. git is
-- what costs here (about 0.7 s per process on Windows, more under load): a clone of their own
-- by git took 42 processes, 29 s of the 30 s a case has. It runs asynchronously, so the child
-- keeps answering: a step that blocks in git under load runs past the 10 s of its RPC call.
local tpl_work = root .. "/work/template"
local tpl_remote, tpl_clone = root .. "/template/remote.git", root .. "/template/clone"
local template_status = "not started"
_G.build_template = function()
  local calls = {
    { nil, { "init", "-q", "-b", "main", tpl_work } },
    { tpl_work, { "commit", "-q", "--allow-empty", "-m", "first" } },
    { nil, { "clone", "-q", "--bare", tpl_work, tpl_remote } },
    { nil, { "clone", "-q", url(tpl_remote), tpl_clone } },
    -- the remote moves on: after the fetch every clone is one behind
    { tpl_work, { "commit", "-q", "--allow-empty", "-m", "second" } },
    { tpl_work, { "push", "-q", url(tpl_remote), "main" } },
  }
  local function run(i)
    local call = calls[i]
    if not call then
      template_status = "ready"
      return
    end
    template_status = "at: git " .. table.concat(call[2], " ")
    local argv = {
      "git",
      "-c",
      "user.name=sheet",
      "-c",
      "user.email=sheet@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.autocrlf=false",
      "-c",
      "init.defaultBranch=main",
    }
    if call[1] then vim.list_extend(argv, { "-C", call[1] }) end
    vim.list_extend(argv, call[2])
    local function failed(why)
      template_status = "failed: git " .. table.concat(call[2], " ") .. ": " .. why
    end
    -- the process's own timeout is below the wait step's, so a git that hangs is named too
    local spawned, err = pcall(
      vim.system,
      argv,
      { text = true, env = env, timeout = 15000 },
      vim.schedule_wrap(function(res)
        if res.code == 0 then
          run(i + 1)
        else
          failed(("exit %d: %s"):format(res.code, res.stderr or ""))
        end
      end)
    )
    -- from the second call on this runs outside any step, where an error would reach nobody
    if not spawned then failed(tostring(err)) end
  end
  run(1)
end
-- true once built; a git call that failed, hung or did not start fails the step by name
-- instead of running out its time
_G.template_ready = function()
  assert(not template_status:find("^failed"), template_status)
  return template_status == "ready"
end
local function copy_tree(from, to)
  vim.fn.mkdir(to, "p")
  for entry, kind in vim.fs.dir(from) do
    if kind == "directory" then
      copy_tree(from .. "/" .. entry, to .. "/" .. entry)
    else
      assert(vim.uv.fs_copyfile(from .. "/" .. entry, to .. "/" .. entry))
    end
  end
end
_G.make = function(name)
  local remote, clone = root .. "/remotes/" .. name .. ".git", root .. "/repos/" .. name
  copy_tree(tpl_remote, remote)
  copy_tree(tpl_clone, clone)
  -- the copy still fetches from the template's remote: its url names the repository's own
  local config = clone .. "/.git/config"
  local cf = assert(io.open(config, "rb"))
  local text = cf:read("*a")
  cf:close()
  local cloned_from, own = url(tpl_remote), url(remote)
  local at, stop = text:find(cloned_from, 1, true)
  assert(at, "no url of the template's remote in " .. config)
  write(config, text:sub(1, at - 1) .. own .. text:sub(stop + 1))
  -- every later upload-pack of this remote waits for its gate file (at most a minute, so a
  -- failed sheet leaves no process behind for long)
  local gate, script = root .. "/gates/" .. name, root .. "/gates/" .. name .. ".sh"
  write(
    script,
    (
      "i=0\nwhile [ ! -f '%s' ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done\n"
      .. 'exec git upload-pack "$@"\n'
    ):format(gate)
  )
  local cfg = assert(io.open(clone .. "/.git/config", "ab"))
  cfg:write(("[remote \"origin\"]\n\tuploadpack = sh '%s'\n"):format(script))
  cfg:close()
end
_G.release = function(name)
  write(root .. "/gates/" .. name, "")
end
_G.dashboard = function()
  vim.cmd("Git dashboard " .. vim.fn.fnameescape(root .. "/repos"))
end
-- the dashboard float of the current tab, if one is open
_G.dwin = function()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if
      vim.bo[b].filetype == "gitsuite-dashboard" and vim.api.nvim_win_get_config(w).relative ~= ""
    then
      return w
    end
  end
end
_G.row = function(name)
  local w = _G.dwin()
  if not w then return "" end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
    if l:find(" " .. name .. " ", 1, true) then return l end
  end
  return ""
end
-- how many rows show `text` in their STATE column
_G.count = function(text)
  local n = 0
  for _, name in ipairs(_G.NAMES) do
    if _G.row(name):find(text, 1, true) then n = n + 1 end
  end
  return n
end
_G.title = function()
  local w = _G.dwin()
  if not w then return "" end
  local t = vim.api.nvim_win_get_config(w).title or ""
  if type(t) == "table" then
    local parts = {}
    for _, chunk in ipairs(t) do
      parts[#parts + 1] = chunk[1]
    end
    t = table.concat(parts)
  end
  return t
end
-- the confirm dialog of a whole-page action, if one is open
_G.asking = function(text)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= _G.dwin() and vim.api.nvim_win_get_config(w).relative ~= "" then
      local lines =
        table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), " ")
      if lines:find(text, 1, true) then return true end
    end
  end
  return false
end
_G.said = function(text)
  return vim.fn.execute("messages"):find(text, 1, true) ~= nil
    or table.concat(_G.sheet_said, " | "):find(text, 1, true) ~= nil
end
_G.verb = function()
  return require("gitsuite.features.dashboard.repo_state").bulk_verb()
end
