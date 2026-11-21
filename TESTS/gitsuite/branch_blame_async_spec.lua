-- TESTS/gitsuite/branch_blame_async_spec.lua -- :Git branch current|list|switch and :Git blame line|full never wait
-- for git: a vim.system whose wait() throws, answers given by hand. branch list/switch read the branches and the
-- current one from one for-each-ref; current is one git log; a newer switch wins over an older one still waiting.
---@diagnostic disable: undefined-field
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite branch and blame (async)", function()
  editor_scope.install()
  local real_system = vim.system
  local real_notify = vim.notify
  local real_select = vim.ui.select
  local calls, said

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

  local function call_with(word)
    for _, c in ipairs(calls) do
      if vim.tbl_contains(c.cmd, word) then return c end
    end
    error("no git call with " .. word .. " in " .. vim.inspect(calls))
  end

  local function settle()
    assert(vim.wait(5000, require("gitsuite.util.gitq").idle), "an answer is still pending")
    vim.wait(20)
  end

  local function heard(text)
    for _, s in ipairs(said) do
      if s:find(text, 1, true) then return true end
    end
    return false
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
    vim.ui.select = real_select
  end)

  it("branch list: one for-each-ref, answered later", function()
    require("gitsuite.features.branch").list()
    assert.equals(1, #calls, "one git call")
    assert.equals(0, #said, "nothing said before git answered")
    answer(call_with("for-each-ref"), 0, " topic\n*main\n")
    settle()
    assert.truthy(heard("topic") and heard("main"))
  end)

  it("branch current: one git log, branch from the decorations", function()
    require("gitsuite.features.branch").current()
    assert.equals(1, #calls)
    answer(call_with("log"), 0, "abc1234\0HEAD -> main, origin/main\n")
    settle()
    assert.truthy(heard("branch: main"))
  end)

  it("branch current: a detached HEAD names the short hash", function()
    require("gitsuite.features.branch").current()
    answer(call_with("log"), 0, "abc1234\0HEAD, origin/topic\n")
    settle()
    assert.truthy(heard("branch: detached HEAD @ abc1234"))
  end)

  it("branch switch: offers after the answer, checks out in the background", function()
    local offered
    vim.ui.select = function(items, _, on_choice)
      offered = items
      on_choice("topic")
    end
    package.loaded["gitsuite.integrations.pickers_nvim"] = {
      available = function()
        return false
      end,
    }
    require("gitsuite.features.branch").switch()
    assert.equals(nil, offered, "nothing offered before git answered")
    answer(call_with("for-each-ref"), 0, " topic\n*main\n")
    vim.wait(200, function()
      return offered ~= nil
    end)
    assert.same({ "topic", "main" }, offered)
    answer(call_with("checkout"), 0, "")
    vim.wait(200, function()
      for _, c in ipairs(calls) do
        if vim.tbl_contains(c.cmd, "--show-toplevel") then return true end
      end
      return false
    end)
    answer(call_with("--show-toplevel"), 0, "/repo\n")
    settle()
    assert.truthy(heard("switched to topic"))
    package.loaded["gitsuite.integrations.pickers_nvim"] = nil
  end)

  it("branch switch: a newer switch wins, the older answer offers nothing", function()
    local offers = 0
    vim.ui.select = function()
      offers = offers + 1
    end
    package.loaded["gitsuite.integrations.pickers_nvim"] = {
      available = function()
        return false
      end,
    }
    local branch = require("gitsuite.features.branch")
    branch.switch()
    branch.switch()
    assert.equals(2, #calls)
    answer(calls[1], 0, " topic\n*main\n")
    answer(calls[2], 0, " topic\n*main\n")
    settle()
    assert.equals(1, offers, "only the newer switch offered")
    package.loaded["gitsuite.integrations.pickers_nvim"] = nil
  end)

  it("blame line: git blame in the background, the line said after it", function()
    local file = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "one", "two" }, file)
    editor_scope.open_file(file)
    require("gitsuite.features.blame").line()
    assert.equals(1, #calls, "one blame started")
    assert.equals(0, #said, "nothing said before git answered")
    local sha = string.rep("a", 40)
    answer(
      call_with("blame"),
      0,
      sha
        .. " 1 1 1\nauthor Ann\nauthor-time 1700000000\nauthor-tz +0000\nsummary first\nfilename x.txt\n\tone\n"
    )
    vim.wait(500, function()
      return #said > 0
    end)
    assert.truthy(#said > 0, "the blame was said")
  end)
end)
