-- TESTS/gitsuite/dashboard_sync_spec.lua -- `gS`: bringing a repository level with its upstream in
-- whichever direction it is off (gitsuite.features.dashboard.actions.sync).
--
-- Real git on throw-away repositories under a temp folder, the remote being a bare repository
-- next to them: no network, nothing outside the temp folder is read or written. Each case starts from
-- a copy of the same template, builds its own state (behind, ahead, diverged, ...) from there and
-- checks what happened to both sides.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.dashboard.actions.sync (real git, local remote)", function()
  local actions = require("gitsuite.features.dashboard.actions")
  local F = dofile(dir_of_spec .. "git_fixture.lua")
  local git = F.git

  ---One process: an empty commit counts like any other, and two sides can never conflict over it.
  ---@param dir string
  ---@param name string
  local function commit(dir, name)
    git(dir, "commit", "-q", "--allow-empty", "-m", name)
  end

  ---Commits a new file, for a case that looks at what arrives in the working tree.
  ---@param dir string
  ---@param name string
  local function commit_file(dir, name)
    local fd = assert(io.open(dir .. "/" .. name, "w"))
    fd:write(name, "\n")
    fd:close()
    git(dir, "add", name)
    git(dir, "commit", "-q", "-m", name)
  end

  -- Built once, per case it is a copy (git_fixture.lua says why): `remote.git` and its level clones
  -- `a` and `b` (`b` is what a second clone would be: a copy of `a`).
  local TEMPLATE = F.template_root()
  do
    local tpl_a = TEMPLATE .. "/a"
    git(TEMPLATE, "init", "-q", "--template=", "--bare", "-b", "main", "remote.git")
    git(TEMPLATE, "clone", "-q", "--template=", "remote.git", "a")
    commit(tpl_a, "seed")
    git(tpl_a, "push", "-q", "-u", "origin", "main")
    F.copy(tpl_a, TEMPLATE .. "/b")
  end

  local root, remote, a, b

  -- How long a case waits for git's answer: seconds per process on a loaded machine, and a push starts
  -- several. Stays under the case's budget of 30 s, so a broken case fails on its assertion.
  local WAIT_MS = 28000

  ---Runs `actions.sync` on `dir` and waits for its answer.
  ---@param dir string
  ---@return boolean ok
  ---@return string|nil err
  ---@return string|nil detail What the batch summary lists as changed
  ---@return string|nil skipped Why there was nothing to work on
  local function sync(dir)
    local done, ok, err, detail, skipped = false, nil, nil, nil, nil
    actions.sync(dir, function(o, e, d, s)
      done, ok, err, detail, skipped = true, o, e, d, s
    end)
    assert.is_true(
      vim.wait(WAIT_MS, function()
        return done
      end, 20),
      "sync did not answer"
    )
    return ok, err, detail, skipped
  end

  ---Runs `actions.push` on `dir` and waits for its answer.
  ---@param dir string
  ---@return boolean|nil ok
  ---@return string|nil err
  ---@return string|nil detail
  local function push(dir)
    local done, ok, err, detail = false, nil, nil, nil
    actions.push(dir, function(o, e, d)
      done, ok, err, detail = true, o, e, d
    end)
    assert.is_true(vim.wait(WAIT_MS, function()
      return done
    end, 20))
    return ok, err, detail
  end

  before_each(function()
    root = vim.fs.normalize(vim.fn.tempname())
    F.copy(TEMPLATE, root)
    remote = root .. "/remote.git"
    a, b = root .. "/a", root .. "/b"
    F.point_remote(a, "origin", remote)
    F.point_remote(b, "origin", remote)
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("does nothing more than the fetch for a repository that is level", function()
    local before = git(a, "rev-parse", "HEAD")
    local ok, err, detail, skipped = sync(a)
    assert.is_true(ok, err)
    assert.is_nil(detail, "a level repository is reported as unchanged")
    assert.is_nil(skipped)
    assert.equals(before, git(a, "rev-parse", "HEAD"))
    assert.equals(before, git(remote, "rev-parse", "main"))
  end)

  it("pulls a repository that is behind", function()
    commit_file(b, "from-b")
    commit(b, "from-b2")
    git(b, "push", "-q")
    local ok, err, detail = sync(a)
    assert.is_true(ok, err)
    assert.equals("pulled 2 commits", detail)
    assert.equals(git(remote, "rev-parse", "main"), git(a, "rev-parse", "HEAD"))
    assert.equals(1, vim.fn.filereadable(a .. "/from-b"), "the file arrived in the working tree")
  end)

  it("pushes a repository that is ahead", function()
    commit(a, "from-a")
    local ok, err, detail = sync(a)
    assert.is_true(ok, err)
    assert.equals("pushed 1 commit", detail)
    assert.equals(git(a, "rev-parse", "HEAD"), git(remote, "rev-parse", "main"))
  end)

  it("touches neither side of a repository that diverged, and says how far", function()
    commit(b, "from-b")
    git(b, "push", "-q")
    commit(a, "from-a")
    local mine, theirs = git(a, "rev-parse", "HEAD"), git(remote, "rev-parse", "main")

    local ok, err = sync(a)
    assert.is_false(ok)
    assert.truthy((err or ""):find("diverged: 1 ahead, 1 behind", 1, true), err)
    assert.equals(mine, git(a, "rev-parse", "HEAD"), "no pull")
    assert.equals(theirs, git(remote, "rev-parse", "main"), "no push")
  end)

  it("counts a repository without an upstream as fetched, not as failed", function()
    local lone = root .. "/lone"
    git(root, "init", "-q", "-b", "main", "lone")
    commit(lone, "only")
    local ok, err, detail, skipped = sync(lone)
    assert.is_true(ok, err)
    assert.is_nil(detail)
    assert.equals("no upstream or detached HEAD", skipped, "the summary lists it as skipped")
  end)

  it("counts a detached HEAD as nothing to bring level", function()
    git(a, "checkout", "-q", "--detach")
    local ok, err = sync(a)
    assert.is_true(ok, err)
  end)

  it("reports a failed fetch and does not go on", function()
    commit(a, "from-a")
    local ahead = git(a, "rev-parse", "HEAD")
    vim.fn.delete(remote, "rf")
    local ok, err = sync(a)
    assert.is_false(ok)
    assert.truthy(err and err ~= "", "the reason is given")
    assert.equals(ahead, git(a, "rev-parse", "HEAD"))
  end)

  it("push (p/gp) reports nothing for a level branch", function()
    local ok, err, detail = push(a)
    assert.is_true(ok, err)
    assert.is_nil(detail, "nothing to push is unchanged")
  end)

  it("push (p/gp) reports how many commits it pushed", function()
    commit(a, "p1")
    commit(a, "p2")
    local ok, err, detail = push(a)
    assert.is_true(ok, err)
    assert.equals("pushed 2 commits", detail)
    assert.equals(git(a, "rev-parse", "HEAD"), git(remote, "rev-parse", "main"))
  end)

  describe("triangular: the upstream stays origin/main, pushes go to a fork", function()
    local tri, fork

    -- The three processes of this template are paid by the first case here, not by the file's start.
    -- `tpl_tri` is two commits ahead of its upstream, and the fork already has both.
    local tpl_tri, tpl_fork
    local function build_template()
      -- A folder of its own: what lies in TEMPLATE is copied for every case of this file.
      local tpl_root = F.template_root()
      tpl_tri, tpl_fork = tpl_root .. "/tri", tpl_root .. "/fork.git"
      F.copy(TEMPLATE .. "/a", tpl_tri)
      F.copy(TEMPLATE .. "/remote.git", tpl_fork)
      F.append_config(
        tpl_tri,
        ('[remote "fork"]\n\turl = %s\n'):format(tpl_fork)
          .. "\tfetch = +refs/heads/*:refs/remotes/fork/*\n"
          .. "[remote]\n\tpushDefault = fork\n"
      )
      commit(tpl_tri, "t1")
      commit(tpl_tri, "t2")
      git(tpl_tri, "push", "-q", "fork", "main")
    end

    before_each(function()
      if not tpl_tri then build_template() end
      tri, fork = root .. "/tri", root .. "/fork.git"
      F.copy(tpl_tri, tri)
      F.copy(tpl_fork, fork)
      F.point_remote(tri, "origin", remote)
      F.point_remote(tri, "fork", fork)
    end)

    it("push counts against the push destination, not the upstream", function()
      assert.equals("2\t0", git(tri, "rev-list", "--left-right", "--count", "HEAD...@{u}"))
      local ok, err, detail = push(tri)
      assert.is_true(ok, err)
      assert.is_nil(detail, "the fork was level: nothing was pushed")
    end)

    it("sync counts against the push destination, not the upstream", function()
      local ok, err, detail = sync(tri)
      assert.is_true(ok, err)
      assert.is_nil(detail, "the fork was level: sync's push sent nothing")
    end)

    it("sync pushes to the push destination what only it lacks", function()
      commit(tri, "t3")
      local ok, err, detail = sync(tri)
      assert.is_true(ok, err)
      assert.equals("pushed 1 commit", detail, "one commit went to the fork, not three")
      assert.equals(git(tri, "rev-parse", "HEAD"), git(fork, "rev-parse", "main"))
    end)
  end)

  it("reads the counts after the fetch, not from the last time", function()
    -- a is level when b pushes; only a fetch inside sync can show that a is now behind.
    assert.equals("0\t0", git(a, "rev-list", "--left-right", "--count", "HEAD...@{u}"))
    commit(b, "from-b")
    git(b, "push", "-q")
    assert.equals(
      "0\t0",
      git(a, "rev-list", "--left-right", "--count", "HEAD...@{u}"),
      "stale until fetched"
    )
    local ok, err = sync(a)
    assert.is_true(ok, err)
    assert.equals(git(remote, "rev-parse", "main"), git(a, "rev-parse", "HEAD"))
  end)
end)
