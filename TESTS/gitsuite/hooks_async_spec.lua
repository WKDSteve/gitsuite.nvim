-- TESTS/gitsuite/hooks_async_spec.lua -- `:Git hooks` without freezing the editor: `inspect` needs two git calls,
-- started together; the commands never wait for git (a vim.system whose wait() throws), and the error paths
-- (not a repository, a bare one, git missing) still answer.
---@diagnostic disable: undefined-field
describe("gitsuite.features.hooks (async, few git calls)", function()
  local hooks = require("gitsuite.features.hooks")
  local base = vim.fs.normalize(vim.fn.tempname())
  local real_system = vim.system

  local function git(dir, ...)
    local res = real_system({ "git", "-C", dir, ... }, { text = true }):wait()
    assert.equals(0, res.code, res.stderr)
  end
  local function new_repo(name)
    local dir = base .. "/" .. name
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q")
    return dir
  end
  local function by_id(results)
    local out = {}
    for _, r in ipairs(results) do
      out[r.id] = r
    end
    return out
  end

  ---Replace vim.system: every start is recorded, nothing runs, and waiting for it is an error.
  ---@return { cmd: string[], on_exit: fun(res: table) }[]
  local function fake_system()
    local calls = {}
    vim.system = function(cmd, _, on_exit)
      calls[#calls + 1] = { cmd = cmd, on_exit = on_exit }
      return {
        pid = 4242,
        wait = function()
          error("vim.system():wait() called: the editor would freeze")
        end,
        kill = function() end,
        is_closing = function()
          return false
        end,
      }
    end
    return calls
  end

  ---Count the git processes the real vim.system starts.
  ---@return { n: integer }
  local function count_system()
    local count = { n = 0 }
    vim.system = function(cmd, ...)
      if cmd[1] == "git" then count.n = count.n + 1 end
      return real_system(cmd, ...)
    end
    return count
  end

  ---@param calls { cmd: string[] }[]
  ---@param word string
  local function call_with(calls, word)
    for _, c in ipairs(calls) do
      if vim.tbl_contains(c.cmd, word) then return c end
    end
    error("no git call with " .. word)
  end

  after_each(function()
    vim.system = real_system
    vim.fn.delete(base, "rf")
  end)

  it("inspect needs two git calls (it took four to five, one after the other)", function()
    local repo = new_repo("count")
    git(repo, "config", "core.hooksPath", ".husky")
    local count = count_system()
    local info = hooks.inspect(repo)
    vim.system = real_system
    assert.is_nil(info.err)
    assert.equals(2, count.n)
    assert.is_true(info.hooks_path_local)
  end)

  it(
    "inspect_async starts both calls at once and answers from their results, without waiting",
    function()
      local repo = new_repo("fake")
      vim.fn.mkdir(repo .. "/.husky", "p")
      local calls = fake_system()
      local got
      hooks.inspect_async(repo, function(info)
        got = info
      end)
      assert.equals(2, #calls, "both git calls start right away")
      assert.is_nil(got, "no answer before git answered")

      call_with(calls, "rev-parse").on_exit({
        code = 0,
        signal = 0,
        stdout = ".git\n" .. repo .. "\n",
        stderr = "",
      })
      call_with(calls, "config").on_exit({
        code = 0,
        signal = 0,
        stdout = "global\tcore.hookspath /shared/hooks\nlocal\tcore.hookspath .husky\n"
          .. "local\tgitsuite.hook.no-claude-trailer /x y/z.sh\n",
        stderr = "",
      })
      assert.is_true(vim.wait(2000, function()
        return got ~= nil
      end))
      assert.is_nil(got.err)
      assert.equals(vim.fs.normalize(repo .. "/.git/hooks"), got.hooks_dir)
      assert.equals(".husky", got.hooks_path, "the last value wins, as with git config --get")
      assert.is_true(got.hooks_path_local)
      assert.equals(vim.fs.normalize(repo .. "/.husky"), got.versioned_dir)
      assert.equals("/x y/z.sh", got.hook_config["gitsuite.hook.no-claude-trailer"])
    end
  )

  it("a core.hooksPath set only globally is not the repository's own", function()
    local repo = new_repo("global")
    local calls = fake_system()
    local got
    hooks.inspect_async(repo, function(info)
      got = info
    end)
    call_with(calls, "rev-parse").on_exit({
      code = 0,
      signal = 0,
      stdout = ".git\n" .. repo,
      stderr = "",
    })
    call_with(calls, "config").on_exit({
      code = 0,
      signal = 0,
      stdout = "global\tcore.hookspath /shared/hooks\n",
      stderr = "",
    })
    assert.is_true(vim.wait(2000, function()
      return got ~= nil
    end))
    assert.equals("/shared/hooks", got.hooks_path)
    assert.is_false(got.hooks_path_local)
    assert.is_nil(got.versioned_dir)
  end)

  it(":Git hooks install and list never wait for git, and report once git answered", function()
    local repo = new_repo("cmd")
    local cmd = require("gitsuite.bindings.hooks_cmd")
    local said = {}
    local notify = require("gitsuite.util.notify")
    local real_notify = notify.notify
    notify.notify = function(text)
      said[#said + 1] = text
    end
    local ok, err = pcall(function()
      local calls = fake_system()
      cmd.run("install", { repo = repo })
      cmd.list(repo)
      assert.equals(4, #calls, "two calls for each command, none waited for")
      vim.system = real_system
      for _, c in ipairs(calls) do
        local res = real_system(c.cmd, { text = true }):wait()
        c.on_exit({ code = res.code, signal = 0, stdout = res.stdout, stderr = res.stderr })
      end
      assert.is_true(vim.wait(5000, function()
        return #said == 2
      end))
    end)
    notify.notify = real_notify
    assert(ok, err)
    local text = table.concat(said, "\n")
    assert.truthy(text:find("installed", 1, true), text)
    assert.truthy(text:find("no-claude-trailer", 1, true), text)
    assert.is_not_nil(vim.uv.fs_stat(repo .. "/.git/hooks/commit-msg"))
  end)

  it(
    "install_async and uninstall_async work on a real repository, also into a versioned folder",
    function()
      local repo = new_repo("real")
      local got
      hooks.install_async(repo, nil, nil, function(r)
        got = r
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end))
      assert.equals("installed", by_id(got)["no-claude-trailer"].status)
      assert.equals("installed", by_id(got)["large-files"].status)

      got = nil
      hooks.uninstall_async(repo, nil, nil, function(r)
        got = r
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end))
      assert.equals("removed", by_id(got)["no-claude-trailer"].status)

      git(repo, "config", "--local", "core.hooksPath", ".husky")
      got = nil
      hooks.install_async(repo, { "no-claude-trailer" }, { into_versioned = true }, function(r)
        got = r
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end))
      assert.equals(
        "installed",
        by_id(got)["no-claude-trailer"].status,
        by_id(got)["no-claude-trailer"].message
      )
      local key = real_system(
        { "git", "-C", repo, "config", "--local", "--get", "gitsuite.hook.no-claude-trailer" },
        { text = true }
      ):wait()
      assert.equals(hooks.script_path(hooks.find("no-claude-trailer")), vim.trim(key.stdout))

      got = nil
      hooks.uninstall_async(repo, { "no-claude-trailer" }, { into_versioned = true }, function(r)
        got = r
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end))
      assert.equals("removed", by_id(got)["no-claude-trailer"].status)
      key = real_system(
        { "git", "-C", repo, "config", "--local", "--get", "gitsuite.hook.no-claude-trailer" },
        { text = true }
      ):wait()
      assert.equals(1, key.code, "the key is gone from the local config")
    end
  )

  it(
    "a second install into the versioned folder starts no config write (the value is read with the rest)",
    function()
      local repo = new_repo("nowrite")
      git(repo, "config", "--local", "core.hooksPath", ".husky")
      hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true })
      local count = count_system()
      local res = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
      vim.system = real_system
      assert.equals("unchanged", res["no-claude-trailer"].status)
      assert.equals(2, count.n)
    end
  )

  it(
    "each_async goes through the repositories one after the other and keeps their order",
    function()
      local a, b = new_repo("one"), new_repo("two")
      local got
      hooks.each_async({ a, b }, hooks.install_async, { "large-files" }, nil, function(r)
        got = r
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end))
      assert.equals(2, #got)
      assert.equals(a, got[1].repo)
      assert.equals(b, got[2].repo)
    end
  )

  it(
    "a bare repository still has a hooks folder; a folder outside any repository is an error",
    function()
      local bare = base .. "/bare.git"
      vim.fn.mkdir(bare, "p")
      git(bare, "init", "-q", "--bare")
      local info = hooks.inspect(bare)
      assert.is_nil(info.err)
      assert.equals(
        vim.fn.resolve(vim.fs.normalize(bare .. "/hooks")):lower(),
        vim.fn.resolve(info.hooks_dir):lower()
      )

      local plain = base .. "/plain"
      vim.fn.mkdir(plain, "p")
      -- GIT_CEILING_DIRECTORIES: the temp folder must not be read as part of a repository above it.
      vim.env.GIT_CEILING_DIRECTORIES = base
      local outside = hooks.inspect(plain)
      vim.env.GIT_CEILING_DIRECTORIES = nil
      assert.truthy(outside.err and outside.err:find("not a git repository", 1, true), outside.err)
    end
  )

  it("a failure while writing the hooks still answers, as an error result", function()
    local repo = new_repo("nowrite-dir")
    local real_mkdir = vim.fn.mkdir
    vim.fn.mkdir = function()
      error("E739: Cannot create directory")
    end
    local got
    local ok, err = pcall(function()
      hooks.install_async(repo, nil, nil, function(r)
        got = r
      end)
      vim.wait(10000, function()
        return got ~= nil
      end)
    end)
    vim.fn.mkdir = real_mkdir
    assert(ok, err)
    assert.is_not_nil(got, "install_async answered")
    assert.equals("error", got[1].status)
    assert.truthy(got[1].message:find("E739", 1, true), got[1].message)
  end)

  it("git that cannot be started is reported, not raised", function()
    local repo = new_repo("nogit")
    vim.system = function()
      error("ENOENT: no such file or directory (cmd): 'git'")
    end
    local got
    hooks.inspect_async(repo, function(info)
      got = info
    end)
    assert.is_true(vim.wait(2000, function()
      return got ~= nil
    end))
    vim.system = real_system
    assert.truthy(got.err and got.err:find("git could not be started", 1, true), got.err)
  end)
end)
