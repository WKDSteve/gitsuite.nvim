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
    assert.truthy(res["no-claude-trailer"].snippet:find("gitsuite.hook.no-claude-trailer", 1, true))
    assert.truthy(res["no-claude-trailer"].message:find("commit-msg-no-claude-trailer.sh", 1, true))
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

  describe("into_versioned, a repository with .husky as its core.hooksPath", function()
    local function husky_repo(name)
      local repo = new_repo(name)
      vim.fn.mkdir(repo .. "/.husky", "p")
      git(repo, "config", "--local", "core.hooksPath", ".husky")
      return repo
    end
    local function write_file(path, text)
      local f = assert(io.open(path, "wb"))
      f:write(text)
      f:close()
    end
    local function config_get(repo, key)
      local res = vim
        .system({ "git", "-C", repo, "config", "--local", "--get", key }, { text = true })
        :wait()
      return res.code == 0 and res.stdout or nil
    end
    local function config_of(repo)
      return vim
        .system({ "git", "-C", repo, "config", "--local", "--get", "core.hooksPath" }, { text = true })
        :wait().stdout
    end

    it("creates the hook file with the line, once, and touches nothing else", function()
      local repo = husky_repo("v1")
      local res = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
      assert.equals("installed", res["no-claude-trailer"].status, res["no-claude-trailer"].message)
      assert.truthy(res["no-claude-trailer"].message:find("commit it yourself", 1, true))
      local text = read(repo .. "/.husky/commit-msg")
      assert.truthy(text:find("^#!/usr/bin/env sh\n"), text)
      assert.truthy(text:find("# gitsuite-hook: no-claude-trailer", 1, true), text)
      assert.truthy(text:find("git config --get gitsuite.hook.no-claude-trailer", 1, true), text)
      assert.truthy(
        text:find('[ -f "$gitsuite_hook" ]', 1, true),
        "only where it names a file: " .. text
      )
      assert.truthy(text:find("|| exit $?", 1, true), "a failure stops the commit: " .. text)
      local script = hooks.script_path(assert(hooks.find("no-claude-trailer")))
      assert.is_nil(text:find(script, 1, true), "no path (no user name) in the versioned file")
      assert.equals(
        script .. "\n",
        config_get(repo, "gitsuite.hook.no-claude-trailer"),
        "the path is local"
      )
      assert.is_nil(vim.uv.fs_stat(repo .. "/.husky/pre-commit"), "only the hook asked for")

      local again = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
      assert.equals("unchanged", again["no-claude-trailer"].status)
      assert.equals(text, read(repo .. "/.husky/commit-msg"), "not added twice")

      assert.equals(".husky\n", config_of(repo), "core.hooksPath is unchanged")
      assert.is_nil(
        vim.uv.fs_stat(hooks.inspect(repo).hooks_dir .. "/commit-msg"),
        "nor .git/hooks"
      )
      local log = vim.system({ "git", "-C", repo, "rev-parse", "--verify", "-q", "HEAD" }):wait()
      assert.is_true(log.code ~= 0, "nothing was committed")
    end)

    it(
      "without the flag it stays manual, and the line it names is the one the flag writes",
      function()
        local repo = husky_repo("v2")
        local res = by_id(hooks.install(repo, { "no-claude-trailer" }))
        assert.equals("manual", res["no-claude-trailer"].status)
        assert.truthy(res["no-claude-trailer"].message:find("--into-versioned", 1, true))
        assert.is_nil(vim.uv.fs_stat(repo .. "/.husky/commit-msg"))
        hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true })
        assert.truthy(
          read(repo .. "/.husky/commit-msg"):find(res["no-claude-trailer"].snippet, 1, true)
        )
      end
    )

    it(
      "adds to a husky hook of the repository, before a last exec line; uninstall restores it",
      function()
        local repo = husky_repo("v3")
        local plain = "npx --no -- commitlint --edit $1\n"
        local with_exec = "#!/bin/sh\necho checking\nexec npx lint-staged\n\n"
        write_file(repo .. "/.husky/commit-msg", plain)
        write_file(repo .. "/.husky/pre-commit", with_exec)

        local res = by_id(hooks.install(repo, nil, { into_versioned = true }))
        assert.equals("installed", res["no-claude-trailer"].status)
        assert.equals("installed", res["large-files"].status)
        local msg = read(repo .. "/.husky/commit-msg")
        assert.equals(1, select(2, msg:gsub("\n", "\n")) - 1, "one line added: " .. msg)
        assert.truthy(msg:find("^npx %-%-no %-%- commitlint %-%-edit %$1\ngitsuite_hook="), msg)
        local pre = vim.split(read(repo .. "/.husky/pre-commit"), "\n", { plain = true })
        assert.equals("#!/bin/sh", pre[1])
        assert.equals("echo checking", pre[2])
        assert.truthy(pre[3]:find("# gitsuite-hook: large-files", 1, true), "before the exec line")
        assert.equals("exec npx lint-staged", pre[4])

        local gone = by_id(hooks.uninstall(repo, nil, { into_versioned = true }))
        assert.equals("removed", gone["no-claude-trailer"].status)
        assert.equals("removed", gone["large-files"].status)
        assert.equals(plain, read(repo .. "/.husky/commit-msg"), "the husky hook as it was")
        assert.is_nil(read(repo .. "/.husky/pre-commit"):find("gitsuite", 1, true))
        local none = by_id(hooks.uninstall(repo, nil, { into_versioned = true }))
        assert.equals("absent", none["no-claude-trailer"].status)
      end
    )

    it("uninstall removes a hook file that held only gitsuite's line", function()
      local repo = husky_repo("v4")
      hooks.install(repo, { "large-files" }, { into_versioned = true })
      assert.is_not_nil(vim.uv.fs_stat(repo .. "/.husky/pre-commit"))
      local gone = by_id(hooks.uninstall(repo, { "large-files" }, { into_versioned = true }))
      assert.equals("removed", gone["large-files"].status)
      assert.is_nil(vim.uv.fs_stat(repo .. "/.husky/pre-commit"))
    end)

    it(
      "list shows the line in the versioned folder: in-versioned or manual, with the folder",
      function()
        local list_lines = require("gitsuite.bindings.hooks_cmd").list_lines
        local repo = husky_repo("v8")
        local function row(lines, id)
          for _, l in ipairs(lines) do
            if l:match("^%s+" .. vim.pesc(id) .. "%s") then return l end
          end
          return ""
        end
        local before = assert(list_lines(repo))
        local text = table.concat(before, "\n")
        assert.truthy(row(before, "no-claude-trailer"):find(" manual ", 1, true), text)
        assert.truthy(row(before, "large-files"):find(" manual ", 1, true), text)
        local folder = before[2]:match("versioned hooks folder: (.+)$")
        assert.is_not_nil(folder, text)
        assert.equals(vim.uv.fs_realpath(repo .. "/.husky"), vim.uv.fs_realpath(folder))

        hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true })
        local after = assert(list_lines(repo))
        assert.truthy(row(after, "no-claude-trailer"):find(" in-versioned ", 1, true))
        assert.truthy(
          row(after, "large-files"):find(" manual ", 1, true),
          "only the hook installed"
        )
      end
    )

    it("uninstall without --into-versioned never deletes in the versioned folder", function()
      local repo = new_repo("v9")
      hooks.install(repo, nil) -- gitsuite's wrappers in .git/hooks
      vim.fn.mkdir(repo .. "/.husky", "p")
      git(repo, "config", "--local", "core.hooksPath", ".husky")
      local only_marker = "#!/usr/bin/env sh\n# gitsuite-hook: large-files\n"
      write_file(repo .. "/.husky/pre-commit", only_marker)
      hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true })
      local husky_msg = read(repo .. "/.husky/commit-msg")
      local info = hooks.inspect(repo)
      assert.equals(2, #info.versioned)

      hooks.uninstall(repo, nil)
      assert.equals(
        husky_msg,
        read(repo .. "/.husky/commit-msg"),
        "the versioned hook is untouched"
      )
      assert.equals(
        only_marker,
        read(repo .. "/.husky/pre-commit"),
        "a versioned file holding only gitsuite's marker is not deleted either"
      )
    end)

    it("list in a repository without core.hooksPath reads .git/hooks as before", function()
      local repo = new_repo("v10")
      hooks.install(repo, { "large-files" })
      local lines = assert(require("gitsuite.bindings.hooks_cmd").list_lines(repo))
      assert.is_nil(hooks.inspect(repo).versioned)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("large%-files%s+ours"), text)
      assert.truthy(text:find("no%-claude%-trailer%s+absent"), text)
    end)

    it(
      "husky 9 (core.hooksPath = .husky/_): the line goes to .husky/, not the generated folder",
      function()
        local repo = new_repo("v7")
        vim.fn.mkdir(repo .. "/.husky/_", "p")
        local generated = '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n'
        write_file(repo .. "/.husky/_/commit-msg", generated)
        write_file(repo .. "/.husky/_/.gitignore", "*\n")
        git(repo, "config", "--local", "core.hooksPath", ".husky/_")

        -- realpath: on macOS the temp folder is under /var, which git reports as /private/var.
        assert.equals(
          vim.uv.fs_realpath(repo .. "/.husky"),
          vim.uv.fs_realpath(hooks.inspect(repo).versioned_dir)
        )
        local res = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
        assert.equals(
          "installed",
          res["no-claude-trailer"].status,
          res["no-claude-trailer"].message
        )
        assert.equals(
          generated,
          read(repo .. "/.husky/_/commit-msg"),
          "husky's wrapper is untouched"
        )
        assert.truthy(
          read(repo .. "/.husky/commit-msg"):find("# gitsuite-hook: no-claude-trailer", 1, true)
        )
      end
    )

    it("puts the line before a last exit, as before a last exec", function()
      local repo = husky_repo("v8")
      write_file(repo .. "/.husky/commit-msg", "#!/bin/sh\nnpx commitlint --edit $1\nexit $?\n")
      write_file(repo .. "/.husky/pre-commit", "#!/bin/sh\necho checking\nexit\n")
      hooks.install(repo, nil, { into_versioned = true })
      local msg = vim.split(read(repo .. "/.husky/commit-msg"), "\n", { plain = true })
      assert.truthy(
        msg[3]:find("# gitsuite-hook: no-claude-trailer", 1, true),
        table.concat(msg, "\n")
      )
      assert.equals("exit $?", msg[4])
      local pre = vim.split(read(repo .. "/.husky/pre-commit"), "\n", { plain = true })
      assert.truthy(pre[3]:find("# gitsuite-hook: large-files", 1, true), table.concat(pre, "\n"))
      assert.equals("exit", pre[4])
    end)

    it("replaces a line of an older install (another path to the script)", function()
      local repo = husky_repo("v9")
      local old = 'if [ -f "/old/place/x.sh" ]; then bash "/old/place/x.sh" "$@" || exit $?; fi   '
        .. "# gitsuite-hook: no-claude-trailer"
      write_file(repo .. "/.husky/commit-msg", "#!/bin/sh\n" .. old .. "\necho after\n")
      local res = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
      assert.equals("updated", res["no-claude-trailer"].status, res["no-claude-trailer"].message)
      local lines = vim.split(read(repo .. "/.husky/commit-msg"), "\n", { plain = true })
      assert.is_nil(table.concat(lines, "\n"):find("/old/place", 1, true))
      assert.truthy(lines[2]:find("gitsuite.hook.no-claude-trailer", 1, true), "in the same place")
      assert.equals("echo after", lines[3])
      local again = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
      assert.equals("unchanged", again["no-claude-trailer"].status)
    end)

    it("never writes through a symlinked hook file", function()
      local repo = husky_repo("v10")
      local target = base .. "/outside-rc"
      write_file(target, "echo mine\n")
      if not vim.uv.fs_symlink(target, repo .. "/.husky/pre-commit") then
        pending("no symlinks here (Windows without the right to create them)")
        return
      end
      assert.is_true(vim.uv.fs_symlink(base .. "/nowhere", repo .. "/.husky/commit-msg") == true)
      local res = by_id(hooks.install(repo, nil, { into_versioned = true }))
      assert.equals("error", res["large-files"].status)
      assert.truthy(res["large-files"].message:find("symlink", 1, true))
      assert.equals("echo mine\n", read(target), "the target is untouched")
      assert.equals("error", res["no-claude-trailer"].status, "a dangling one too")
      assert.is_nil(vim.uv.fs_stat(base .. "/nowhere"), "nothing created at its target")
      local gone = by_id(hooks.uninstall(repo, nil, { into_versioned = true }))
      assert.equals("error", gone["large-files"].status)
    end)

    it(
      "a core.hooksPath outside the work tree is not versioned: manual, even with the flag",
      function()
        local repo = new_repo("v11")
        local shared = base .. "/shared-hooks"
        vim.fn.mkdir(shared, "p")
        git(repo, "config", "--local", "core.hooksPath", shared)
        assert.is_nil(hooks.inspect(repo).versioned_dir)
        local res = by_id(hooks.install(repo, nil, { into_versioned = true }))
        assert.equals("manual", res["no-claude-trailer"].status)
        assert.truthy(res["no-claude-trailer"].message:find("outside its work tree", 1, true))
        assert.is_not_nil(res["no-claude-trailer"].snippet)
        assert.is_nil(vim.uv.fs_stat(shared .. "/commit-msg"), "nothing written there")

        local up = new_repo("v12")
        vim.fn.mkdir(base .. "/up-hooks", "p")
        git(up, "config", "--local", "core.hooksPath", "../up-hooks")
        assert.is_nil(hooks.inspect(up).versioned_dir, "a relative path that leaves the work tree")
      end
    )

    it("a commit runs the line: the Claude trailer is gone", function()
      if vim.fn.executable("bash") == 0 then
        pending("bash not on PATH")
        return
      end
      local repo = husky_repo("v5")
      hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true })
      write_file(repo .. "/a.txt", "a\n")
      git(repo, "add", "a.txt")
      git(
        repo,
        "-c",
        "user.name=spec",
        "-c",
        "user.email=spec@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-q",
        "-m",
        "feat: a\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
      )
      local msg =
        vim.system({ "git", "-C", repo, "log", "-1", "--format=%B" }, { text = true }):wait().stdout
      assert.truthy(msg:find("feat: a", 1, true), msg)
      assert.is_nil(msg:find("Claude", 1, true), msg)
    end)

    it(
      "husky 9 layout: commits run the line through sh -e, in a second clone only once its key is set",
      function()
        if vim.fn.executable("bash") == 0 then
          pending("bash not on PATH")
          return
        end
        -- What `husky` generates on install, in the same shape (written here, not taken from husky): a folder `_`
        -- that git ignores, one wrapper per hook that sources `h`, and `h` running `.husky/<hook>` under `sh -e`.
        local H = table.concat({
          "#!/usr/bin/env sh",
          'n=$(basename "$0")',
          's=$(dirname "$(dirname "$0")")/$n',
          '[ -f "$s" ] || exit 0',
          'sh -e "$s" "$@"',
          "c=$?",
          '[ $c = 0 ] || echo "husky-like: $n failed ($c)" >&2',
          "exit $c",
          "",
        }, "\n")
        local function husky_install(dir)
          vim.fn.mkdir(dir .. "/.husky/_", "p")
          write_file(dir .. "/.husky/_/h", H)
          write_file(dir .. "/.husky/_/commit-msg", '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n')
          write_file(dir .. "/.husky/_/.gitignore", "*\n")
          for _, f in ipairs({ "h", "commit-msg" }) do
            vim.uv.fs_chmod(dir .. "/.husky/_/" .. f, tonumber("755", 8))
          end
          git(dir, "config", "--local", "core.hooksPath", ".husky/_")
        end
        local function commit(dir, file)
          write_file(dir .. "/" .. file, file .. "\n")
          git(dir, "add", "-A")
          git(
            dir,
            "-c",
            "user.name=spec",
            "-c",
            "user.email=spec@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "feat: " .. file .. "\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
          )
          return vim
            .system({ "git", "-C", dir, "log", "-1", "--format=%B" }, { text = true })
            :wait().stdout
        end

        local repo = new_repo("h9")
        husky_install(repo)
        local res = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
        assert.equals(
          "installed",
          res["no-claude-trailer"].status,
          res["no-claude-trailer"].message
        )
        local first = commit(repo, "a.txt")
        assert.truthy(first:find("feat: a.txt", 1, true), first)
        assert.is_nil(first:find("Claude", 1, true), "the line ran under sh -e: " .. first)
        local tracked = vim.system({ "git", "-C", repo, "ls-files" }, { text = true }):wait().stdout
        assert.truthy(
          tracked:find(".husky/commit-msg", 1, true),
          "the line is committed: " .. tracked
        )
        assert.is_nil(tracked:find(".husky/_/", 1, true), "the generated folder is not")

        -- Another clone: the line comes with the repository, the key does not.
        local clone = base .. "/h9-clone"
        local cloned = vim.system({ "git", "clone", "-q", repo, clone }, { text = true }):wait()
        assert.equals(0, cloned.code, cloned.stderr)
        husky_install(clone)
        local without = commit(clone, "b.txt")
        assert.truthy(
          without:find("Claude", 1, true),
          "no key: the line does nothing, the commit goes through"
        )
        local again =
          by_id(hooks.install(clone, { "no-claude-trailer" }, { into_versioned = true }))
        assert.equals(
          "updated",
          again["no-claude-trailer"].status,
          again["no-claude-trailer"].message
        )
        local status =
          vim.system({ "git", "-C", clone, "status", "--porcelain" }, { text = true }):wait().stdout
        assert.equals("", status, "only the local key changed")
        local with = commit(clone, "c.txt")
        assert.is_nil(with:find("Claude", 1, true), "with the key the hook works: " .. with)
      end
    )

    it(
      "the line does nothing without the key or with a key that names no file, even under -e",
      function()
        if vim.fn.executable("bash") == 0 then
          pending("bash not on PATH")
          return
        end
        local repo = husky_repo("v6")
        local line =
          by_id(hooks.install(repo, { "no-claude-trailer" }))["no-claude-trailer"].snippet
        local function run()
          -- -e as husky 9 runs a hook: a missing key must not end it
          return vim
            .system({ "bash", "-e", "-c", line .. "\necho after" }, { text = true, cwd = repo })
            :wait()
        end
        local unset = run()
        assert.equals(0, unset.code, unset.stderr)
        assert.equals("after\n", unset.stdout)
        git(
          repo,
          "config",
          "--local",
          "gitsuite.hook.no-claude-trailer",
          base .. "/no-such-script.sh"
        )
        local missing = run()
        assert.equals(0, missing.code, missing.stderr)
        assert.equals("after\n", missing.stdout)
      end
    )

    it("another clone: the line is already committed, install sets only the local key", function()
      local repo = husky_repo("v13")
      hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true })
      local text = read(repo .. "/.husky/commit-msg")
      git(repo, "config", "--local", "--unset", "gitsuite.hook.no-claude-trailer")
      local res = by_id(hooks.install(repo, { "no-claude-trailer" }, { into_versioned = true }))
      assert.equals("updated", res["no-claude-trailer"].status, res["no-claude-trailer"].message)
      assert.equals(text, read(repo .. "/.husky/commit-msg"), "the file is untouched")
      assert.is_not_nil(config_get(repo, "gitsuite.hook.no-claude-trailer"))

      local gone = by_id(hooks.uninstall(repo, { "no-claude-trailer" }, { into_versioned = true }))
      assert.equals("removed", gone["no-claude-trailer"].status)
      assert.is_nil(config_get(repo, "gitsuite.hook.no-claude-trailer"), "uninstall unsets the key")
    end)
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
