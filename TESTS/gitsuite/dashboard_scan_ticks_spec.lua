-- TESTS/gitsuite/dashboard_scan_ticks_spec.lua -- the dashboard scan spreads its git starts over event-loop ticks:
-- libuv starts a process synchronously on the editor thread, so all repositories of a page started in one tick
-- froze the editor for the sum of their starts. At most one repository (status + log) starts per tick; the scan
-- still reads every repository and answers once. Nothing runs: a vim.system whose wait() throws, answers by hand.
---@diagnostic disable: undefined-field
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local editor_scope = dofile(dir_of_spec .. "editor_scope.lua")
describe("gitsuite.features.dashboard.status scan", function()
  editor_scope.install()
  local status = require("gitsuite.features.dashboard.status")
  local real_system = vim.system
  local real_notify = vim.notify
  local git = require("lib.nvim.git")
  local real_run_async = git.run_async
  local starts, tick, counting, root

  ---Counts event-loop ticks: one step per round of scheduled callbacks. Bounded: a callback that schedules
  ---itself forever would keep vim.wait from ever checking its condition.
  local function count_ticks()
    if not counting or #starts >= 12 or tick >= 500 then return end
    tick = tick + 1
    vim.schedule(count_ticks)
  end

  before_each(function()
    starts, tick, counting = {}, 0, true
    vim.schedule(count_ticks)
    vim.notify = function() end
    vim.system = function(cmd, _, on_exit)
      starts[#starts + 1] = { cmd = cmd, on_exit = on_exit, tick = tick }
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
    root = vim.fn.tempname() .. "-gitsuite-scan-ticks"
    for _, name in ipairs({ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" }) do
      vim.fn.mkdir(root .. "/" .. name .. "/.git", "p")
    end
  end)

  after_each(function()
    counting = false
    vim.system = real_system
    vim.notify = real_notify
    git.run_async = real_run_async
    vim.fn.delete(root, "rf")
  end)

  it("starts at most one repository per tick and still reads them all", function()
    local records
    status.scan_group({ root }, function(r)
      records = r
    end)
    assert.equals(2, #starts, "only the first repository starts at once: " .. vim.inspect(starts))
    assert(
      vim.wait(5000, function()
        return #starts == 12
      end),
      ("six repositories, two git starts each; got %d"):format(#starts)
    )
    local per_tick = {}
    for _, s in ipairs(starts) do
      per_tick[s.tick] = (per_tick[s.tick] or 0) + 1
    end
    for t, n in pairs(per_tick) do
      assert.is_true(n <= 2, ("%d git starts in tick %d"):format(n, t))
    end

    for _, s in ipairs(starts) do
      local out = vim.tbl_contains(s.cmd, "status") and "# branch.oid abc\n# branch.head main\n"
        or "1700000000\n"
      s.on_exit({ code = 0, signal = 0, stdout = out, stderr = "" })
    end
    assert(
      vim.wait(5000, function()
        return records ~= nil
      end),
      "the scan never answered"
    )
    assert.equals(6, #records)
  end)

  it("a start that throws, at once or a tick later, counts as that repository's failure", function()
    git.run_async = function(args, opts, on_done)
      local name = vim.fs.basename(opts.dir)
      if name == "alpha" or name == "charlie" then error("boom in " .. name) end
      return real_run_async(args, opts, on_done)
    end
    local records, errors
    local ok, err = pcall(status.scan_group, { root }, function(r, e)
      records, errors = r, e
    end)
    assert.is_true(ok, tostring(err))
    assert(
      vim.wait(5000, function()
        return #starts == 8
      end),
      ("four repositories start; got %d"):format(#starts)
    )
    for _, s in ipairs(starts) do
      local out = vim.tbl_contains(s.cmd, "status") and "# branch.oid abc\n# branch.head main\n"
        or "1700000000\n"
      s.on_exit({ code = 0, signal = 0, stdout = out, stderr = "" })
    end
    assert(
      vim.wait(5000, function()
        return records ~= nil
      end),
      "the scan never answered"
    )
    assert.equals(4, #records)
    assert.equals(2, #errors, vim.inspect(errors))
    assert.truthy(table.concat(errors, "\n"):find("boom in charlie", 1, true), vim.inspect(errors))
  end)
end)
