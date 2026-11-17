-- TESTS/gitsuite/cli_spec.lua -- the read-only command line (`scripts/gitsuite.lua`, `gitsuite.cli`), run as the
-- process a script or a hook starts: `nvim --headless -u NONE -l scripts/gitsuite.lua ...` against a throwaway
-- repository, the JSON on stdout decoded and held against the schema of docs/cli.md (`gitsuite.cli/1`).
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's; the test body itself is the guard.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local F = dofile(dir_of_spec .. "git_fixture.lua")

describe("gitsuite command line (scripts/gitsuite.lua)", function()
  local root = F.path(vim.fn.fnamemodify(dir_of_spec .. "../..", ":p"))
  local script = root .. "/scripts/gitsuite.lua"
  local lib_init = vim.api.nvim_get_runtime_file("lua/lib/nvim/git/init.lua", false)[1]
  local lib = F.path(vim.fn.fnamemodify(lib_init, ":h:h:h:h:h"))

  -- One repository for every case (they only read): `a.txt` and `lua/mod/x.lua` in a first commit, `x.lua`
  -- removed in a second, marked breaking; `a.txt` left changed in the work tree.
  local repo = F.template_root() .. "/repo"
  vim.fn.mkdir(repo .. "/lua/mod", "p")
  F.git(repo, "init", "-q", "-b", "main")
  vim.fn.writefile({ "one", "two" }, repo .. "/a.txt")
  vim.fn.writefile({ "return {}" }, repo .. "/lua/mod/x.lua")
  F.git(repo, "add", "-A")
  F.git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "feat: first")
  F.git(repo, "rm", "-q", "lua/mod/x.lua")
  F.git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "feat!: drop mod.x")
  vim.fn.writefile({ "one", "changed" }, repo .. "/a.txt")
  local real = F.path(vim.uv.fs_realpath(repo) or repo)

  ---Runs the script with `args` in `cwd` (default: the repository).
  ---@param args string[]
  ---@param cwd? string
  ---@return integer code
  ---@return table|nil json Decoded stdout, when it is JSON
  ---@return string stderr
  local function cli(args, cwd)
    local argv = { vim.v.progpath, "--headless", "-u", "NONE", "-l", script }
    vim.list_extend(argv, args)
    local res =
      vim.system(argv, { text = true, cwd = cwd or repo, env = { LIB_NVIM_DIR = lib } }):wait(20000)
    local ok, json = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true } })
    return res.code, ok and json or nil, res.stderr or ""
  end

  ---The envelope every answer has.
  local function envelope(json, command, ok)
    assert.is_table(json)
    assert.equals("gitsuite.cli/1", json.schema)
    assert.equals(command, json.command)
    assert.equals(ok, json.ok)
    assert.is_table(json.errors)
  end

  it(
    "status: the repository of the current directory, and a path that is none as an error",
    function()
      local code, json, err = cli({ "status", ".", "nowhere" })
      assert.equals(1, code, err)
      envelope(json, "status", false)
      local r = json.result.repos[1]
      assert.equals(real, r.path)
      assert.equals("main", r.branch)
      assert.is_false(r.detached)
      assert.is_false(r.has_upstream)
      assert.equals(1, r.dirty)
      assert.equals("dirty", r.state)
      assert.is_number(r.last_commit)
      assert.same({ { target = "nowhere", message = "not a git repository" } }, json.errors)
      assert.truthy(err:find("nowhere: not a git repository", 1, true))
    end
  )

  it("log: the newest commits with their files", function()
    local code, json, err = cli({ "log", "--count=1", "--files" })
    assert.equals(0, code, err)
    envelope(json, "log", true)
    assert.equals(real, json.result.repo)
    assert.equals(1, #json.result.commits)
    local c = json.result.commits[1]
    assert.equals("feat!: drop mod.x", c.subject)
    assert.equals(json.result.head, c.sha)
    assert.same({ { status = "D", path = "lua/mod/x.lua" } }, c.files)
    assert.equals("t", c.author)
  end)

  it("blame: one line of a file, the work tree's change as uncommitted", function()
    local code, json, err = cli({ "blame", "a.txt", "--lines=1-2" })
    assert.equals(0, code, err)
    envelope(json, "blame", true)
    assert.equals("a.txt", json.result.file)
    local lines = json.result.lines
    assert.equals(2, #lines)
    assert.is_false(lines[1].uncommitted)
    assert.equals("feat: first", lines[1].summary)
    assert.is_true(lines[2].uncommitted)
  end)

  it("breaking: the check over a range names the breaking commit", function()
    local code, json, err = cli({ "breaking", "--from=HEAD~1" })
    assert.equals(0, code, err)
    envelope(json, "breaking", true)
    local r = json.result
    assert.equals(1, r.total)
    assert.is_false(r.truncated)
    assert.equals("feat!: drop mod.x", r.commits[1].subject)
    assert.equals("sure", r.commits[1].tier)
    assert.same({ r.commits[1].sha }, r.sure)
  end)

  it("usage errors exit 2 without JSON; a revision that is an option is refused", function()
    local code, json = cli({ "log", "--count=0" })
    assert.equals(2, code)
    assert.is_nil(json)
    code = cli({ "frobnicate" })
    assert.equals(2, code)
    code = cli({ "breaking" })
    assert.equals(2, code, "--from is required")
    local rcode, rjson = cli({ "log", "--rev=--output=x" })
    assert.equals(1, rcode)
    envelope(rjson, "log", false)
    assert.truthy(rjson.errors[1].message:find("not a revision", 1, true))
  end)
end)
