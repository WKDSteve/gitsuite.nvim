-- TESTS/gitsuite/repo_cmds_async_spec.lua -- the commands on the current repository (:Git status repo|quickfix|
-- todos|relink, :Git browse, :Git ui lazygit) never wait for git: a vim.system whose wait() throws, answers given by
-- hand. Each command starts as few git calls as it needs, all at once, and a newer request wins over an older one
-- that is still waiting.
---@diagnostic disable: undefined-field
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite repository commands (async)", function()
  editor_scope.install()
  local real_system = vim.system
  local real_notify = vim.notify
  local real_executable = vim.fn.executable
  local calls, said

  ---Every start is recorded, nothing runs, and waiting for it is an error.
  local function fake_system()
    calls = {}
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
  end

  ---@param c { on_exit: fun(res: table) }
  ---@param code integer
  ---@param stdout string
  local function answer(c, code, stdout)
    c.on_exit({ code = code, signal = 0, stdout = stdout, stderr = code == 0 and "" or "fatal: no" })
  end

  ---The recorded call whose argv holds `word`.
  local function call_with(word)
    for _, c in ipairs(calls) do
      if vim.tbl_contains(c.cmd, word) then return c end
    end
    error("no git call with " .. word .. " in " .. vim.inspect(calls))
  end

  local function settle()
    assert(vim.wait(5000, require("gitsuite.util.gitq").idle), "an answer is still pending")
  end

  before_each(function()
    said = {}
    vim.notify = function(msg)
      said[#said + 1] = tostring(msg)
    end
    fake_system()
  end)

  after_each(function()
    vim.system = real_system
    vim.notify = real_notify
    vim.fn.executable = real_executable
    pcall(vim.cmd, "cclose")
  end)

  describe(":Git status repo", function()
    it("is one git call, answered later, with branch, upstream counts and changed files", function()
      local status = require("gitsuite.features.status")
      status.repo()
      assert.equals(1, #calls)
      assert.truthy(vim.tbl_contains(calls[1].cmd, "--porcelain=v2"))
      assert.equals(0, #said, "nothing is said before git answered")
      answer(
        calls[1],
        0,
        table.concat({
          "# branch.oid 0123",
          "# branch.head main",
          "# branch.upstream origin/main",
          "# branch.ab +2 -0",
          "1 .M N... 100644 100644 100644 a b notes.txt",
          "2 R. N... 100644 100644 100644 a b R100 new.txt",
          "old.txt",
          "? untracked.txt",
          "",
        }, "\0")
      )
      settle()
      assert.equals(1, #said)
      assert.truthy(
        said[1]:find("branch: main  ahead=true behind=false  dirty (3)", 1, true),
        said[1]
      )
    end)

    it("names a detached HEAD and a clean tree, and says when this is no repository", function()
      local s = require("gitsuite.features.status").parse_summary(
        "# branch.oid 0123\0# branch.head (detached)\0"
      )
      assert.is_nil(s.branch)
      assert.equals(0, s.changed)
      assert.is_nil(s.ahead)

      require("gitsuite.features.status").repo()
      answer(calls[1], 128, "")
      settle()
      assert.truthy(said[1]:find("not inside a git repository", 1, true), said[1])
    end)
  end)

  describe(":Git status quickfix", function()
    it("does not wait, and the newer of two requests fills the list", function()
      local status = require("gitsuite.features.status")
      vim.fn.setqflist({}, "r", { items = {} })
      status.quickfix()
      status.quickfix()
      -- each request asks for the root and the status together (the paths are relative to the root)
      assert.equals(4, #calls)
      answer(calls[3], 0, "/repo\n")
      answer(calls[4], 0, "?? second.txt\0")
      answer(calls[1], 0, "/repo\n")
      answer(calls[2], 0, "?? first.txt\0")
      settle()
      local items = vim.fn.getqflist()
      assert.equals(1, #items)
      assert.truthy(vim.fn.bufname(items[1].bufnr):find("second.txt", 1, true))
    end)
  end)

  describe(":Git status todos|lint|spell and relink", function()
    it("the gates start the root and the status together: two calls instead of four", function()
      local gates = require("gitsuite.features.status.gates")
      gates.spell()
      assert.equals(2, #calls)
      answer(call_with("--show-toplevel"), 0, "/repo\n")
      answer(call_with("status"), 0, "")
      settle()
      assert.truthy(said[1]:find("no changed files to check", 1, true), said[1])
    end)

    it("outside a repository the gates say so", function()
      require("gitsuite.features.status.gates").lint()
      answer(call_with("--show-toplevel"), 128, "")
      answer(call_with("status"), 128, "")
      settle()
      assert.truthy(said[1]:find("not inside a git repository", 1, true), said[1])
    end)

    it("relink starts two calls together, not three in a row", function()
      require("gitsuite.features.status.relink").relink()
      assert.equals(2, #calls)
      answer(call_with("--show-toplevel"), 128, "")
      answer(call_with("status"), 128, "")
      settle()
      assert.truthy(said[1]:find("not inside a git repository", 1, true), said[1])
    end)
  end)

  describe(":Git browse", function()
    local browse, opened, buf

    before_each(function()
      package.loaded["gitsuite.features.browse"] = nil
      browse = require("gitsuite.features.browse")
      opened = {}
      browse.open_url = function(u)
        opened[#opened + 1] = u
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, vim.fs.normalize(vim.fn.tempname()) .. "/notes.txt")
      vim.api.nvim_set_current_buf(buf)
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("starts its three queries at once and opens the URL once git answered", function()
      browse.file()
      assert.equals(3, #calls, "remote, ref and path start together")
      assert.equals(0, #opened)
      answer(call_with("get-url"), 0, "git@github.com:me/proj.git\n")
      answer(call_with("symbolic-ref"), 0, "main\n")
      answer(call_with("ls-files"), 0, "docs/notes.txt\n")
      settle()
      assert.same({ "https://github.com/me/proj/blob/main/docs/notes.txt" }, opened)
    end)

    it("a detached HEAD costs one more call for the short hash", function()
      browse.file()
      answer(call_with("get-url"), 0, "https://github.com/me/proj\n")
      answer(call_with("symbolic-ref"), 128, "")
      answer(call_with("ls-files"), 0, "notes.txt\n")
      assert(vim.wait(5000, function()
        return #calls == 4
      end))
      assert.truthy(vim.tbl_contains(calls[4].cmd, "--short"))
      answer(calls[4], 0, "abc1234\n")
      settle()
      assert.same({ "https://github.com/me/proj/blob/abc1234/notes.txt" }, opened)
    end)

    it("the late answer of an older request opens nothing", function()
      browse.file()
      local first = calls
      fake_system()
      browse.repo()
      local function answer_all(batch)
        for _, c in ipairs(batch) do
          local out = vim.tbl_contains(c.cmd, "get-url") and "https://github.com/me/proj\n"
            or vim.tbl_contains(c.cmd, "symbolic-ref") and "main\n"
            or "notes.txt\n"
          answer(c, 0, out)
        end
      end
      answer_all(calls)
      answer_all(first)
      settle()
      assert.same({ "https://github.com/me/proj" }, opened, "only the newer request (repo) opens")
    end)

    it("a missing origin is reported, nothing opens", function()
      browse.file()
      answer(call_with("get-url"), 2, "")
      answer(call_with("symbolic-ref"), 0, "main\n")
      answer(call_with("ls-files"), 0, "notes.txt\n")
      settle()
      assert.equals(0, #opened)
      assert.truthy(said[1]:find("no 'origin' remote", 1, true), said[1])
    end)
  end)

  describe(":Git ui lazygit", function()
    it("is one git call, and a newer request wins", function()
      vim.fn.executable = function(name)
        return name == "lazygit" and 1 or real_executable(name)
      end
      local lazygit = require("gitsuite.features.ui.lazygit")
      lazygit.open()
      assert.equals(1, #calls)
      assert.truthy(vim.tbl_contains(calls[1].cmd, "--show-toplevel"))
      lazygit.open()
      answer(calls[1], 128, "")
      answer(calls[2], 128, "")
      settle()
      assert.equals(1, #said, "only the newer request reports")
      assert.truthy(said[1]:find("not inside a git repository", 1, true), said[1])
    end)
  end)
end)
