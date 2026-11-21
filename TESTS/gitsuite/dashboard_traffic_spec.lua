-- TESTS/gitsuite/dashboard_traffic_spec.lua -- the VIEWS/CLONES column of the dashboard: a soft
-- dependency on github_stats, read from its stored data only, never a failure without it.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
describe("gitsuite.integrations.github_stats", function()
  local traffic, view
  local saved = {}
  local roots = {}

  local function fake_clone(name, url)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/" .. name .. "/.git", "p")
    vim.fn.writefile(
      { '[remote "origin"]', "\turl = " .. url },
      root .. "/" .. name .. "/.git/config"
    )
    roots[#roots + 1] = root
    return root .. "/" .. name
  end

  ---Installs a github_stats stand-in; `queries` records what was asked of it.
  local function stub_stats(tracked, totals, queries)
    package.loaded["github_stats"] = {}
    package.loaded["github_stats.config"] = {
      get_repos = function()
        return tracked
      end,
    }
    package.loaded["github_stats.analytics"] = {
      query_metric = function(q)
        queries[#queries + 1] = q
        return { total_count = totals[q.metric] or 0 }, nil
      end,
    }
  end

  local function record(path, name)
    return {
      name = name,
      path = path,
      branch = "main",
      ahead = 0,
      behind = 0,
      has_upstream = true,
      dirty = 0,
      state = "clean",
      last_commit = os.time(),
    }
  end

  before_each(function()
    for _, k in ipairs({ "github_stats", "github_stats.config", "github_stats.analytics" }) do
      saved[k] = package.loaded[k]
      package.loaded[k] = nil
    end
    package.loaded["gitsuite.integrations.github_stats"] = nil
    traffic = require("gitsuite.integrations.github_stats")
    view = require("gitsuite.features.dashboard.view")
  end)

  after_each(function()
    for k, v in pairs(saved) do
      package.loaded[k] = v
    end
    for _, r in ipairs(roots) do
      vim.fn.delete(r, "rf")
    end
    roots = {}
    package.loaded["gitsuite.integrations.github_stats"] = nil
  end)

  it("is empty and asks for nothing while github_stats is not loaded", function()
    local dir = fake_clone("a", "https://github.com/me/a.git")
    assert.equals("", traffic.badge(dir))
    assert.is_nil(package.loaded["github_stats"], "the dashboard never loads it")
    local lines = view.render({ record(dir, "a") })
    assert.is_nil(lines[1]:find("VIEWS", 1, true))
  end)

  it("shows views/clones of the last 14 days for a tracked github repository", function()
    local dir = fake_clone("a", "https://github.com/me/a.git")
    local queries = {}
    stub_stats({ "me/a" }, { views = 12, clones = 3 }, queries)
    assert.equals("12/3", traffic.badge(dir))
    assert.equals("me/a", queries[1].repo)
    assert.equals("14d", queries[1].time_range)

    traffic.invalidate()
    local lines = view.render({ record(dir, "a") })
    assert.truthy(lines[1]:find("VIEWS/CLONES 14D", 1, true), lines[1])
    assert.truthy(lines[2]:find("12/3", 1, true), lines[2])
  end)

  it("leaves untracked, non-github and silent repositories without a badge or column", function()
    local queries = {}
    local other = fake_clone("o", "https://github.com/me/other.git")
    local lab = fake_clone("l", "https://gitlab.com/me/l.git")
    local quiet = fake_clone("q", "https://github.com/me/q.git")
    stub_stats({ "me/q" }, { views = 0, clones = 0 }, queries)
    assert.equals("", traffic.badge(other))
    assert.equals("", traffic.badge(lab))
    assert.equals("", traffic.badge(quiet), "zero traffic is not worth a cell")
    local lines = view.render({ record(other, "o"), record(lab, "l"), record(quiet, "q") })
    assert.is_nil(lines[1]:find("VIEWS", 1, true), "no column of blanks")
  end)

  it("a failing github_stats reads as no badge", function()
    local dir = fake_clone("a", "https://github.com/me/a.git")
    package.loaded["github_stats"] = {}
    package.loaded["github_stats.config"] = {
      get_repos = function()
        error("boom")
      end,
    }
    package.loaded["github_stats.analytics"] = {
      query_metric = function()
        error("boom")
      end,
    }
    assert.equals("", traffic.badge(dir))
  end)

  it("answers from its cache within the TTL", function()
    local dir = fake_clone("a", "https://github.com/me/a.git")
    local queries = {}
    stub_stats({ "me/a" }, { views = 1, clones = 1 }, queries)
    traffic.badge(dir)
    local n = #queries
    traffic.badge(dir)
    assert.equals(n, #queries)
  end)
end)
