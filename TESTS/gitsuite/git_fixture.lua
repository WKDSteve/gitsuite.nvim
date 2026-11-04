-- TESTS/gitsuite/git_fixture.lua -- real repositories for a spec, at the price of a file copy. Not a
-- spec (no `_spec` suffix): a spec loads it with
--
--   local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
--   local F = dofile(dir_of_spec .. "git_fixture.lua")
--
-- A git process costs about 0.2 s on Windows and 3 s or more on a loaded machine, which is what ran
-- cases into their 30 s budget. So a spec builds its repositories once and copies them per case: no
-- process, and every case still gets its own real repository to change. The build counts too: the
-- 30 s also run from the start of the file up to the end of the first case, so a template keeps to a
-- few processes. What can be derived from a finished repository is derived by copy() and
-- append_config(), not by git.
local M = {}

local NULL = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"

-- A commit needs an identity, and the user's own git config must not reach a fixture: it would make
-- every commit a signed one (about four times the cost, and it needs the user's key).
M.ENV = {
  GIT_AUTHOR_NAME = "t",
  GIT_AUTHOR_EMAIL = "t@example.invalid",
  GIT_COMMITTER_NAME = "t",
  GIT_COMMITTER_EMAIL = "t@example.invalid",
  GIT_CONFIG_GLOBAL = NULL,
  GIT_CONFIG_SYSTEM = NULL,
}

---Runs `git -C dir ...`, raises when it fails (also while a `describe` body builds a template, where
---no assertion is running yet), returns its trimmed stdout.
---@param dir string
---@param ... string
---@return string
function M.git(dir, ...)
  local args = { "git", "-C", dir, ... }
  local res = vim.system(args, { text = true, env = M.ENV }):wait()
  if res.code ~= 0 then error(table.concat(args, " ") .. ": " .. (res.stderr or ""), 2) end
  return vim.trim(res.stdout or "")
end

---A folder for a template. Never deleted by hand: nvim removes its temp folder on exit.
---@return string
function M.template_root()
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  return root
end

---Copies a folder and everything below it, the empty folders a repository needs included.
---@param src string
---@param dst string
function M.copy(src, dst)
  vim.fn.mkdir(dst, "p")
  for name, kind in vim.fs.dir(src) do
    local from, to = src .. "/" .. name, dst .. "/" .. name
    if kind == "directory" then
      M.copy(from, to)
    else
      assert(vim.uv.fs_copyfile(from, to))
    end
  end
end

---Adds to a repository's config what `git remote add` or `git config` would, without their process.
---@param dir string The working tree
---@param text string Config file text, one or more complete sections
function M.append_config(dir, text)
  local fd = assert(io.open(dir .. "/.git/config", "ab"))
  fd:write(text)
  fd:close()
end

---Points a remote of a copied clone at `url`. A clone notes where its remote was, so without this a
---copy would fetch from and push to the template.
---@param clone string
---@param name string The remote
---@param url string
function M.point_remote(clone, name, url)
  local path = clone .. "/.git/config"
  local rfd = assert(io.open(path, "rb"))
  local text = rfd:read("*a")
  rfd:close()
  local pattern = '(%[remote "' .. vim.pesc(name) .. '"%]\r?\n%s*url = )[^\r\n]*'
  local new, count = text:gsub(pattern, function(head)
    -- A backslash is an escape in git's config file.
    return head .. vim.fs.normalize(url)
  end)
  if count ~= 1 then error(("%s: no url of remote %q in: %s"):format(path, name, text)) end
  local wfd = assert(io.open(path, "wb"))
  wfd:write(new)
  wfd:close()
end

return M
