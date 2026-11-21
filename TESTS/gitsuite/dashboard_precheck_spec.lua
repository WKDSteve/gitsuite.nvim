-- TESTS/gitsuite/dashboard_precheck_spec.lua -- dashboard.fetch_precheck = "github": what is read
-- from a clone's files, the GraphQL query, and which fetches the answer saves. No network: the
-- token lookup and the request are fakes (`precheck.token`, `precheck.request`).
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
describe("gitsuite.features.dashboard.precheck", function()
  local precheck
  local orig_request, orig_token
  local roots = {}
  local OID_A = string.rep("a", 40)
  local OID_B = string.rep("b", 40)

  ---A clone as the files show it: origin url, checked-out branch, origin's ref for it.
  ---@param opts { url?: string, branch?: string, oid?: string, packed?: boolean, detached?: boolean }
  ---@return string dir
  local function clone(opts)
    local dir = vim.fn.tempname()
    roots[#roots + 1] = dir
    vim.fn.mkdir(dir .. "/.git/refs/remotes/origin", "p")
    if opts.url ~= false then
      vim.fn.writefile(
        { '[remote "origin"]', "\turl = " .. (opts.url or "https://github.com/me/a.git") },
        dir .. "/.git/config"
      )
    end
    local branch = opts.branch or "main"
    vim.fn.writefile(
      { opts.detached and OID_A or ("ref: refs/heads/" .. branch) },
      dir .. "/.git/HEAD"
    )
    if opts.oid then
      if opts.packed then
        vim.fn.writefile({
          "# pack-refs with: peeled fully-peeled sorted",
          opts.oid .. " refs/remotes/origin/" .. branch,
        }, dir .. "/.git/packed-refs")
      else
        vim.fn.writefile({ opts.oid }, dir .. "/.git/refs/remotes/origin/" .. branch)
      end
    end
    return dir
  end

  ---A GitHub answer per alias: `{ [i] = { name, oid } | false }`.
  local function answer(entries)
    local data = {}
    for i, e in pairs(entries) do
      data["r" .. i] = e and { defaultBranchRef = { name = e[1], target = { oid = e[2] } } }
        or vim.NIL
    end
    return { status = 200, data = { data = data } }
  end

  local requests
  ---Every request is answered with `responses[n]` (a result, or a string error).
  local function fake_github(responses, token)
    requests = {}
    precheck.token = function()
      if token == false then return nil, "`gh auth token` failed" end
      return "tkn", "gh"
    end
    precheck.request = function(path, opts, cb)
      requests[#requests + 1] = { path = path, opts = opts }
      local r = responses[#requests]
      vim.schedule(function()
        if type(r) == "string" then
          cb(nil, r)
        else
          cb(r, nil)
        end
      end)
    end
  end

  local function run(paths)
    local pc = precheck.new()
    pc:start(paths)
    assert.is_true(vim.wait(2000, function()
      return pc.state == "done"
    end, 5))
    return pc
  end

  before_each(function()
    package.loaded["gitsuite.features.dashboard.precheck"] = nil
    precheck = require("gitsuite.features.dashboard.precheck")
    orig_request, orig_token = precheck.request, precheck.token
  end)

  after_each(function()
    precheck.request, precheck.token = orig_request, orig_token
    for _, r in ipairs(roots) do
      vim.fn.delete(r, "rf")
    end
    roots = {}
  end)

  describe("local_state", function()
    it("reads slug, branch and origin's tip from the files, loose or packed", function()
      local loose = precheck.local_state(clone({ oid = OID_A }))
      assert.same({ slug = "me/a", owner = "me", name = "a", branch = "main", oid = OID_A }, loose)
      local packed = precheck.local_state(clone({ oid = OID_B, packed = true, branch = "dev" }))
      assert.equals(OID_B, packed.oid)
      assert.equals("dev", packed.branch)
    end)

    it("leaves out what it cannot compare", function()
      assert.is_nil(
        precheck.local_state(clone({ url = "https://gitlab.com/me/a.git", oid = OID_A }))
      )
      assert.is_nil(precheck.local_state(clone({ url = false, oid = OID_A })), "no origin")
      assert.is_nil(precheck.local_state(clone({})), "no remote-tracking ref")
      assert.is_nil(precheck.local_state(clone({ detached = true, oid = OID_A })), "detached HEAD")
    end)
  end)

  it("asks for every repository in one query, one alias each", function()
    local q = precheck.query({ { owner = "me", name = "a" }, { owner = "o", name = "b.nvim" } })
    assert.truthy(q:find('r1: repository(owner: "me", name: "a")', 1, true), q)
    assert.truthy(q:find('r2: repository(owner: "o", name: "b.nvim")', 1, true), q)
    assert.truthy(q:find("defaultBranchRef { name target { oid } }", 1, true), q)
  end)

  it("marks fresh only the repositories whose default branch GitHub has where origin is", function()
    local same = clone({ oid = OID_A })
    local moved = clone({ oid = OID_A, url = "https://github.com/me/b.git" })
    local other_branch =
      clone({ oid = OID_A, branch = "feature", url = "https://github.com/me/c.git" })
    local gone = clone({ oid = OID_A, url = "https://github.com/me/d.git" })
    local lab = clone({ oid = OID_A, url = "https://gitlab.com/me/e.git" })
    fake_github({
      answer({ { "main", OID_A }, { "main", OID_B }, { "main", OID_A }, false }),
    })
    local pc = run({ same, moved, other_branch, gone, lab })

    assert.equals(1, #requests, "one query for the page")
    assert.equals("/graphql", requests[1].path)
    assert.equals("POST", requests[1].opts.method)
    assert.equals("tkn", requests[1].opts.token)
    local body = vim.json.decode(requests[1].opts.body)
    assert.truthy(body.query:find('name: "d"', 1, true), "the non-GitHub clone is not asked about")
    assert.is_nil(body.query:find('name: "e"', 1, true))

    assert.same({ [same] = true }, pc.fresh)
    assert.equals(4, pc.asked)
    assert.is_nil(pc.failure)
  end)

  it("splits a big page into batches", function()
    precheck.BATCH = 2
    local dirs = {}
    for i = 1, 3 do
      dirs[i] = clone({ oid = OID_A, url = ("https://github.com/me/r%d.git"):format(i) })
    end
    fake_github({ answer({ { "main", OID_A }, { "main", OID_A } }), answer({ { "main", OID_A } }) })
    local pc = run(dirs)
    assert.equals(2, #requests)
    assert.same({ [dirs[1]] = true, [dirs[2]] = true, [dirs[3]] = true }, pc.fresh)
  end)

  it(
    "without a token or with a failed query everything is fetched, and the summary says why",
    function()
      local dir = clone({ oid = OID_A })
      fake_github({}, false)
      local pc = run({ dir })
      assert.same({}, pc.fresh)
      assert.equals(0, #requests)
      assert.truthy(pc:summary(1):find("no GitHub token", 1, true), pc:summary(1))

      fake_github({ "API rate limit exceeded" })
      pc = run({ dir })
      assert.same({}, pc.fresh)
      assert.truthy(pc:summary(1):find("fell back to fetching: API rate limit exceeded", 1, true))
    end
  )

  it("the wrapped action waits for the answer, skips the fresh ones and counts them", function()
    local same = clone({ oid = OID_A })
    local moved = clone({ oid = OID_A, url = "https://github.com/me/b.git" })
    fake_github({ answer({ { "main", OID_A }, { "main", OID_B } }) })
    local pc = precheck.new()
    local fetched, done = {}, {}
    local action = pc:wrap_action(function(path, on_done)
      fetched[#fetched + 1] = path
      on_done(true)
    end)
    pc:start({ same, moved })
    action(same, function(ok)
      done[#done + 1] = ok
    end)
    action(moved, function(ok)
      done[#done + 1] = ok
    end)
    assert.same({}, done, "held until GitHub answered")
    assert.is_true(vim.wait(2000, function()
      return #done == 2
    end, 5))
    assert.same({ moved }, fetched)
    assert.equals(1, pc.saved)
    assert.equals("GitHub precheck: 1 of 2 fetches saved", pc:summary(2))

    local reread_of = {}
    local reread = pc:wrap_reread(function(path, cb)
      reread_of[#reread_of + 1] = path
      cb({ path = path })
    end)
    reread(same, function() end)
    reread(moved, function() end)
    assert.same({ moved }, reread_of, "an unfetched row is not re-read")
  end)

  it("a precheck that never started holds nothing back and has nothing to say", function()
    local pc = precheck.new()
    local ran = false
    pc:wrap_action(function(_, on_done)
      ran = true
      on_done(true)
    end)("/x", function() end)
    assert.is_true(ran)
    assert.is_nil(pc:summary(1))
  end)
end)
