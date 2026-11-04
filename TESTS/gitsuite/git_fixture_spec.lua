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

  for _, name in ipairs({ "plain", "with#hash", "with;semicolon", "with space", "with$HOME" }) do
    it(("point_remote: a path %q reads back whole"):format(name), function()
      local url = root .. "/" .. name .. "/remote.git"
      F.point_remote(clone, "origin", url)
      assert.equals(url, F.git(clone, "config", "--get", "remote.origin.url"))
    end)
  end

  it("point_remote: a backslash arrives as a forward slash, not as an escape", function()
    F.point_remote(clone, "origin", root .. "\\sub\\remote.git")
    assert.equals(root .. "/sub/remote.git", F.git(clone, "config", "--get", "remote.origin.url"))
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
