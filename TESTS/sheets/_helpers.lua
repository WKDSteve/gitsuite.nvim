-- TESTS/sheets/_helpers.lua -- what the repository sheets of gitsuite.nvim need in their child editor.
-- Not a sheet (`testing.sheet` only reads *.sheet.lua); a sheet's first step runs it with `dofile`, the
-- child's cwd is the project root. The directory is in the spec's @cache-inputs.
--
-- `_G.boot()` makes a throwaway git repository (no network, no remote but a fake origin URL), sets the
-- plugin up and opens its one file. What would leave the editor (the system opener) is replaced by a
-- recorder.

vim.o.swapfile = false
vim.opt.shortmess:append("I")

_G.notes = {}
vim.notify = function(msg)
  _G.notes[#_G.notes + 1] = tostring(msg)
end

---Whether a notification so far holds `text` (plain).
---@param text string
---@return boolean
function _G.noted(text)
  for _, n in ipairs(_G.notes) do
    if n:find(text, 1, true) then return true end
  end
  return false
end

---Forget the notifications and what the stubs recorded.
function _G.forget()
  _G.notes = {}
  _G.opened = {}
end

---The text of every floating window, joined.
---@return string
function _G.floattext()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      out[#out + 1] = table.concat(lines, "\n")
    end
  end
  return table.concat(out, "\n")
end

---Run git in `dir` with a fixed identity; raises when it fails.
---@param dir string
---@param ... string
---@return string
function _G.git(dir, ...)
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
    "-C",
    dir,
  }
  vim.list_extend(argv, { ... })
  local res = vim.system(argv, { text = true, timeout = 20000 }):wait()
  assert(res.code == 0, ("git %s: %s"):format(table.concat({ ... }, " "), res.stderr or ""))
  return res.stdout or ""
end

---Write `lines` to `path`.
---@param path string
---@param lines string[]
function _G.write(path, lines)
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

---A repository with two commits on main (`notes.txt`), a branch `topic`, an origin URL, the plugin set
---up, and `notes.txt` open.
function _G.boot()
  _G.opened = {}
  package.loaded["lib.nvim.cross.open_default"] = function(url)
    _G.opened[#_G.opened + 1] = url
    return true
  end
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  _G.repo = dir
  _G.git(dir, "init", "-q", "-b", "main")
  _G.write(dir .. "/notes.txt", { "one", "two", "three" })
  _G.git(dir, "add", "notes.txt")
  _G.git(dir, "commit", "-q", "-m", "first")
  _G.write(dir .. "/notes.txt", { "one", "two changed", "three" })
  _G.git(dir, "commit", "-q", "-a", "-m", "second")
  _G.git(dir, "branch", "topic")
  _G.git(dir, "remote", "add", "origin", "https://github.com/me/proj.git")
  require("gitsuite").setup({})
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/notes.txt"))
end
