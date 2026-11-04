-- TESTS/gitsuite/git_fixture_spec.lua -- the helper of the specs that use real repositories: what it
-- writes into a repository's config has to read back as the path it was given, whatever the temp
-- folder is called on the machine.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("git_fixture", function()
  local F = dofile(dir_of_spec .. "git_fixture.lua")
  local root, clone

  before_each(function()
    root = F.template_root()
    clone = root .. "/clone"
    F.git(root, "init", "-q", "--template=", "-b", "main", "clone")
    F.append_config(clone, '[remote "origin"]\n\turl = unset\n')
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("a git started by any spec reads neither the user's nor the machine's config", function()
    -- The variables themselves: CI has no such config, so what git lists would pass there anyway.
    local null = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"
    assert.equals(null, vim.env.GIT_CONFIG_GLOBAL)
    assert.equals(null, vim.env.GIT_CONFIG_SYSTEM)
    -- A plain call, without F.git and without an env of its own.
    local res = vim.system({ "git", "config", "--list", "--show-scope" }, { text = true }):wait()
    assert.equals(0, res.code, res.stderr)
    assert.is_nil(res.stdout:find("global\t", 1, true), res.stdout)
    assert.is_nil(res.stdout:find("system\t", 1, true), res.stdout)
  end)

  for _, name in ipairs({ "plain", "with#hash", "with;semicolon", "with space", "with$HOME" }) do
    it(("point_remote: a path %q reads back whole"):format(name), function()
      local url = root .. "/" .. name .. "/remote.git"
      F.point_remote(clone, "origin", url)
      assert.equals(url, F.git(clone, "config", "--get", "remote.origin.url"))
    end)
  end

  it("point_remote: a backslash is never read as an escape", function()
    local url = root .. "\\sub\\remote.git"
    F.point_remote(clone, "origin", url)
    -- A separator on Windows, an ordinary character of a file name everywhere else.
    local expected = vim.fn.has("win32") == 1 and root .. "/sub/remote.git" or url
    assert.equals(expected, F.git(clone, "config", "--get", "remote.origin.url"))
  end)

  it("point_remote: names the problem when the remote has no url to replace", function()
    local ok, err = pcall(F.point_remote, clone, "other", "x")
    assert.is_false(ok)
    assert.truthy(tostring(err):find('no url of remote "other"', 1, true), err)
  end)

  it("copy: brings the empty folders along, the copy is a repository of its own", function()
    F.git(clone, "commit", "-q", "--allow-empty", "-m", "first")
    local copy = root .. "/copy"
    F.copy(clone, copy)
    F.git(copy, "commit", "-q", "--allow-empty", "-m", "second")
    assert.equals("2", F.git(copy, "rev-list", "--count", "HEAD"))
    assert.equals("1", F.git(clone, "rev-list", "--count", "HEAD"), "the original did not move")
  end)
end)
