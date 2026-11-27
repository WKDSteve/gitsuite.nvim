-- TESTS/gitsuite/status_spec.lua -- gitsuite.features.status against this
-- repo's own real git state, no fixture needed.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite.features.status", function()
  editor_scope.install()
  local status

  before_each(function()
    package.loaded["gitsuite.features.status"] = nil
    status = require("gitsuite.features.status")
  end)

  it("repo() does not error inside a real git repository", function()
    local ok = pcall(status.repo)
    assert.is_true(ok)
  end)

  it("quickfix() does not error and does not raise on a clean tree", function()
    local ok = pcall(status.quickfix)
    assert(vim.wait(10000, require("gitsuite.util.gitq").idle), "git did not answer")
    assert.is_true(ok)
  end)

  it("quickfix() populates the quickfix list when there is an untracked file", function()
    -- A throwaway repo: the live checkout must never receive scratch files,
    -- and its own untracked files must not influence the assertion.
    local original_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname() .. "-gitsuite-status-untracked"
    vim.fn.mkdir(dir, "p")
    local init = vim.system({ "git", "-C", dir, "init", "-q" }):wait()
    assert.equals(0, init.code, "fixture: git init failed: " .. tostring(init.stderr))
    vim.fn.writefile({ "scratch" }, dir .. "/scratch.md")
    vim.api.nvim_set_current_dir(dir)

    local ok, err = pcall(function()
      status.quickfix()
      assert(vim.wait(10000, require("gitsuite.util.gitq").idle), "git did not answer")
      local qf = vim.fn.getqflist({ title = 0, items = 0 })
      assert.equals("gitsuite: status", qf.title)

      local found = false
      for _, item in ipairs(qf.items) do
        if vim.fn.bufname(item.bufnr):match("scratch%.md$") then found = true end
      end
      assert.is_true(found, "the untracked scratch file shows up in the quickfix export")
    end)

    vim.api.nvim_set_current_dir(original_cwd)
    vim.cmd("cclose")
    pcall(vim.fn.delete, dir, "rf")
    assert.is_true(ok, tostring(err))
  end)

  -- Without `-z`, git C-quotes a path containing a space or a non-ASCII byte
  -- (`"a b.txt"`, `"\303\274.txt"`), so the quickfix export used to list
  -- entries whose "file" did not exist. Needs a real throwaway repo: the
  -- repo this suite runs in has no such files.
  describe("paths git would otherwise quote", function()
    local original_cwd, repo

    before_each(function()
      original_cwd = vim.fn.getcwd()
      repo = vim.fn.tempname() .. "-gitsuite-status-quoting"
      vim.fn.mkdir(repo, "p")
      local init = vim.system({ "git", "-C", repo, "init", "-q" }):wait()
      assert.equals(0, init.code, "fixture: git init failed: " .. tostring(init.stderr))
      vim.fn.writefile({ "x" }, repo .. "/a b.txt")
      vim.fn.writefile({ "x" }, repo .. "/ü.txt")
      vim.api.nvim_set_current_dir(repo)
    end)

    after_each(function()
      vim.api.nvim_set_current_dir(original_cwd)
      vim.cmd("cclose")
      pcall(vim.fn.delete, repo, "rf")
    end)

    it("quickfix() lists them under their real, existing paths", function()
      status.quickfix()
      assert(vim.wait(10000, require("gitsuite.util.gitq").idle), "git did not answer")
      local items = vim.fn.getqflist({ items = 0 }).items

      assert.equals(2, #items)
      for _, item in ipairs(items) do
        local name = vim.fn.bufname(item.bufnr)
        assert.equals(
          1,
          vim.fn.filereadable(name),
          ("quickfix entry %q is not a real file"):format(name)
        )
        assert.is_nil(item.text:find('"', 1, true), "the entry text carries no git quoting")
      end
    end)
  end)

  -- `status --porcelain` names files relative to the repository root, wherever it runs: from a
  -- subfolder the entries used to be joined to the cwd and pointed at files that do not exist.
  describe("run from a subfolder", function()
    local original_cwd, repo

    before_each(function()
      original_cwd = vim.fn.getcwd()
      repo = vim.fn.tempname() .. "-gitsuite-status-subdir"
      vim.fn.mkdir(repo .. "/sub", "p")
      local init = vim.system({ "git", "-C", repo, "init", "-q" }):wait()
      assert.equals(0, init.code, "fixture: git init failed: " .. tostring(init.stderr))
      vim.fn.writefile({ "x" }, repo .. "/top.txt")
      vim.fn.writefile({ "x" }, repo .. "/sub/s.txt")
      vim.api.nvim_set_current_dir(repo .. "/sub")
    end)

    after_each(function()
      vim.api.nvim_set_current_dir(original_cwd)
      vim.cmd("cclose")
      pcall(vim.fn.delete, repo, "rf")
    end)

    it("quickfix() points every entry at an existing file", function()
      status.quickfix()
      assert(vim.wait(10000, require("gitsuite.util.gitq").idle), "git did not answer")
      local items = vim.fn.getqflist({ items = 0 }).items

      assert.equals(2, #items)
      for _, item in ipairs(items) do
        local name = vim.fn.bufname(item.bufnr)
        assert.equals(
          1,
          vim.fn.filereadable(name),
          ("quickfix entry %q is not a real file"):format(name)
        )
      end
    end)
  end)
end)
