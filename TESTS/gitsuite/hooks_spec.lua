-- TESTS/gitsuite/hooks_spec.lua -- gitsuite.features.hooks against throwaway repositories: one-line wrappers,
-- a foreign hook is never overwritten, a repository with its own core.hooksPath is never written to.
---@diagnostic disable: undefined-field
describe("gitsuite.features.hooks", function()
  local hooks = require("gitsuite.features.hooks")
  local base = vim.fs.normalize(vim.fn.tempname())

  local function git(repo, ...)
    local res = vim.system({ "git", "-C", repo, ... }, { text = true }):wait()
    assert.equals(0, res.code, res.stderr)
  end
  local function new_repo(name)
    local dir = base .. "/" .. name
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q")
    return dir
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end
  local function by_id(results)
    local out = {}
    for _, r in ipairs(results) do
      out[r.id] = r
    end
    return out
  end

  after_each(function()
    vim.fn.delete(base, "rf")
  end)

  it("ships both scripts, and the catalog names them", function()
    local ids = {}
    for _, e in ipairs(hooks.catalog()) do
      ids[#ids + 1] = e.id
      assert.is_not_nil(vim.uv.fs_stat(hooks.script_path(e)), e.script .. " is shipped")
    end
    assert.same({ "no-claude-trailer", "large-files" }, ids)
  end)

  it("installs one-line wrappers that call the shipped script, and is idempotent", function()
    local repo = new_repo("a")
    local res = by_id(hooks.install(repo))
    assert.equals("installed", res["no-claude-trailer"].status)
    assert.equals("installed", res["large-files"].status)

    local info = hooks.inspect(repo)
    for _, e in ipairs(info.entries) do
      assert.equals("ours", e.state)
    end
    local text = read(info.hooks_dir .. "/commit-msg")
    assert.truthy(text:find("# gitsuite-hook: no-claude-trailer", 1, true))
    assert.truthy(
      text:find("commit-msg-no-claude-trailer.sh", 1, true),
      "the wrapper calls the shipped script"
    )
    assert.truthy(text:find('"$@"', 1, true), "and passes the hook's arguments on")

    local again = by_id(hooks.install(repo))
    assert.equals("unchanged", again["no-claude-trailer"].status)
  end)

  it("never overwrites a hook that is not ours, and uninstall never removes it", function()
    local repo = new_repo("b")
    local dir = hooks.inspect(repo).hooks_dir
    vim.fn.mkdir(dir, "p")
    local mine = "#!/bin/sh\necho my own hook\n"
    local f = assert(io.open(dir .. "/commit-msg", "wb"))
    f:write(mine)
    f:close()

    local res = by_id(hooks.install(repo))
    assert.equals("foreign", res["no-claude-trailer"].status)
    assert.equals(mine, read(dir .. "/commit-msg"), "the foreign hook is untouched")
    assert.equals("installed", res["large-files"].status, "the other hook is still installed")

    local gone = by_id(hooks.uninstall(repo))
    assert.equals("foreign", gone["no-claude-trailer"].status)
    assert.equals(mine, read(dir .. "/commit-msg"), "uninstall leaves it alone")
    assert.equals("removed", gone["large-files"].status)
    assert.is_nil(vim.uv.fs_stat(dir .. "/pre-commit"))
  end)

  it("installs only the hook asked for", function()
    local repo = new_repo("c")
    local res = hooks.install(repo, { "large-files" })
    assert.equals(1, #res)
    local states = {}
    for _, e in ipairs(hooks.inspect(repo).entries) do
      states[e.id] = e.state
    end
    assert.equals("ours", states["large-files"])
    assert.equals("absent", states["no-claude-trailer"])
  end)

  it("leaves a repository with its own core.hooksPath alone and says what to add", function()
    local repo = new_repo("d")
    vim.fn.mkdir(repo .. "/.husky", "p")
    git(repo, "config", "--local", "core.hooksPath", ".husky")

    local res = by_id(hooks.install(repo))
    assert.equals("manual", res["no-claude-trailer"].status)
    assert.truthy(res["no-claude-trailer"].snippet:find("commit-msg-no-claude-trailer.sh", 1, true))
    assert.truthy(res["no-claude-trailer"].message:find(".husky", 1, true))
    assert.is_nil(
      vim.uv.fs_stat(repo .. "/.husky/commit-msg"),
      "nothing is written to the versioned folder"
    )
    assert.is_nil(
      vim.uv.fs_stat(hooks.inspect(repo).hooks_dir .. "/commit-msg"),
      "nor to .git/hooks"
    )
  end)

  it("reports a path that is not a repository as an error, and formats a report", function()
    local res = hooks.install(base .. "/missing")
    assert.equals("error", res[1].status)
    local repo = new_repo("e")
    local text = hooks.format(hooks.install(repo))
    assert.truthy(text:find("installed  e  no-claude-trailer", 1, true), text)
  end)

  it("the shipped commit-msg script strips Claude trailers and keeps the rest", function()
    if vim.fn.executable("bash") == 0 then
      pending("bash not on PATH")
      return
    end
    local e = hooks.find("no-claude-trailer")
    local msg = base .. "-msg.txt"
    local f = assert(io.open(msg, "wb"))
    f:write(
      "feat: a thing\n\nbody\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nCo-Authored-By: Pat <pat@example.com>\n"
    )
    f:close()
    local res = vim.system({ "bash", hooks.script_path(e), msg }, { text = true }):wait()
    assert.equals(0, res.code)
    local out = read(msg)
    assert.is_nil(out:find("Claude", 1, true), out)
    assert.truthy(out:find("Pat", 1, true), "a real person's trailer stays")
    os.remove(msg)
  end)
end)
