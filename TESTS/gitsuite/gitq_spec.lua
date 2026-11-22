-- TESTS/gitsuite/gitq_spec.lua -- gitsuite.util.gitq on lib.nvim.async: `all` answers once, in query order, on a
-- later tick; `idle` stays false until a whole chain of answers is done; `ticket` lets the newest request of a key
-- win without touching other keys. Nothing runs: a vim.system whose wait() throws, answers given by hand.
---@diagnostic disable: undefined-field
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite.util.gitq", function()
  editor_scope.install()
  local gitq = require("gitsuite.util.gitq")
  local real_system = vim.system
  local calls

  before_each(function()
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
  end)

  after_each(function()
    vim.system = real_system
    assert(vim.wait(2000, gitq.idle), "a query is still counted")
  end)

  local function answer(c, stdout)
    c.on_exit({ code = 0, signal = 0, stdout = stdout, stderr = "" })
  end

  it("all: every query starts at once, done comes once, in query order", function()
    local got, count = nil, 0
    gitq.all(
      { { args = { "rev-parse", "--show-toplevel" } }, { args = { "symbolic-ref", "HEAD" } } },
      function(res)
        count = count + 1
        got = res
      end
    )
    assert.equals(2, #calls, "both started before any answer")
    answer(calls[2], "main\n")
    answer(calls[1], "/repo\n")
    assert(
      vim.wait(2000, function()
        return count > 0
      end),
      "all never answered"
    )
    vim.wait(50)
    assert.equals(1, count)
    assert.equals("/repo", gitq.line(got[1]))
    assert.equals("main", gitq.line(got[2]))
  end)

  it(
    "idle: false while a query runs, while the answer of all is scheduled, and while its chain runs",
    function()
      assert.is_true(gitq.idle())
      local chained, answered = false, false
      gitq.all({ { args = { "rev-parse", "HEAD" } } }, function()
        answered = true
        gitq.run({ "log", "-1" }, nil, function()
          chained = true
        end)
      end)
      assert.is_false(gitq.idle(), "a running query counts")
      answer(calls[1], "abc\n")
      -- The query's callback is scheduled by lib.nvim.git; this probe runs right after it, and the answer of `all`
      -- (scheduled from inside that callback) after the probe: the query is uncounted, the answer still to come.
      local probe
      vim.schedule(function()
        probe = { idle = gitq.idle(), answered = answered }
      end)
      assert(
        vim.wait(2000, function()
          return probe ~= nil
        end),
        "the probe never ran"
      )
      assert.is_false(probe.answered, "the probe must run before the answer of all")
      assert.is_false(probe.idle, "the scheduled answer of all counts")
      assert(
        vim.wait(2000, function()
          return #calls == 2
        end),
        "the chain never started"
      )
      assert.is_false(gitq.idle(), "the chained query counts")
      answer(calls[2], "x\n")
      assert(vim.wait(2000, gitq.idle), "never idle")
      assert.is_true(chained)
    end
  )

  it("ticket: the newest ticket of a key wins, other keys stay valid", function()
    local a1 = gitq.ticket("spec.a")
    local b1 = gitq.ticket("spec.b")
    assert.is_true(a1())
    local a2 = gitq.ticket("spec.a")
    assert.is_false(a1(), "superseded by the newer ticket of the same key")
    assert.is_true(a2())
    assert.is_true(b1(), "another key is not superseded")
  end)

  it("failure names the deadline and a git that could not start", function()
    assert.truthy(
      gitq.failure({ timed_out = true, code = 124 }, "x"):find("timed out after 10000 ms", 1, true)
    )
    assert.truthy(
      gitq
        .failure({ code = -1, stderr = "ENOENT\n" }, "x")
        :find("could not be started: ENOENT", 1, true)
    )
    assert.equals("fallback", gitq.failure({ code = 1 }, "fallback"))
  end)
end)
