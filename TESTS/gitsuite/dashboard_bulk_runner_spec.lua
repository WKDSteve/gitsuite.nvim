-- TESTS/gitsuite/dashboard_bulk_runner_spec.lua -- the walk behind a dashboard batch, without a
-- buffer: slots, row order, when a row settles, cancel, somebody else's lock, a superseded batch.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's; the test body itself is the guard.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
describe("gitsuite.features.dashboard.bulk", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({ { "gitsuite.util.notify", "notify" } })

  local bulk, state
  local run -- what the running batch did so far, see `start`
  local warnings

  before_each(function()
    warnings = {}
    require("gitsuite.util.notify").notify = function(msg)
      warnings[#warnings + 1] = msg
    end
    package.loaded["gitsuite.features.dashboard.repo_state"] = nil
    package.loaded["gitsuite.features.dashboard.bulk"] = nil
    state = require("gitsuite.features.dashboard.repo_state")
    bulk = require("gitsuite.features.dashboard.bulk")
  end)

  ---Starts a batch over `names` whose action waits for `complete`, and whose re-read answers at
  ---once unless `opts.hold_rereads`.
  ---@param names string[]
  ---`opts.reread`, `opts.on_reread` and `opts.redraw` replace the harmless default ones.
  ---`opts.open` and `opts.stop_after_failures` go to `bulk.run` as they are; an open queue's feeder
  ---lands in `run.feeder`, how the walk ended in `run.ended`.
  ---@param opts? { limit?: integer, action?: function, handle?: table, hold_rereads?: boolean, reread?: function, on_reread?: function, redraw?: function, open?: boolean, open_limit?: integer, stop_after_failures?: integer }
  local function start(names, opts)
    opts = opts or {}
    run = { started = {}, waiting = {}, rereads = {}, stored = {}, redraws = 0 }
    local targets = {}
    for i, name in ipairs(names) do
      targets[i] = { path = "/" .. name, name = name }
    end
    run.feeder = bulk.run({
      verb = "fetch",
      targets = targets,
      open = opts.open,
      open_limit = opts.open_limit,
      stop_after_failures = opts.stop_after_failures,
      limit = opts.limit or 1,
      action = opts.action or function(path, on_done)
        run.started[#run.started + 1] = path
        run.waiting[path] = on_done
      end,
      reread = opts.reread or function(path, on_record)
        if opts.hold_rereads then
          run.rereads[path] = on_record
        else
          on_record({ path = path })
        end
      end,
      on_reread = opts.on_reread or function(record)
        run.stored[#run.stored + 1] = record and record.path or "nil"
      end,
      redraw = opts.redraw or function()
        run.redraws = run.redraws + 1
      end,
      handle = opts.handle,
      on_finish = function(results, ended)
        run.results = results
        run.ended = ended
      end,
    })
  end

  ---Lets the scheduled callbacks of a completed action run until `pred` holds.
  local function until_(pred, what)
    assert.is_true(vim.wait(2000, pred, 5), what or "the batch did not get there in time")
  end

  ---@param path string
  ---@param ok? boolean Defaults to success
  local function complete(path, ok)
    local on_done = assert(run.waiting[path], "no call waiting on " .. path)
    run.waiting[path] = nil
    if ok == false then
      on_done(false, "exploded")
    else
      on_done(true)
    end
  end

  local function names_of(results)
    return vim.tbl_map(function(r)
      return r.name
    end, results)
  end

  it("queues every target up front, then fills the slots in row order up to the limit", function()
    start({ "a", "b", "c", "d" }, { limit = 2 })
    assert.same({ "/a", "/b" }, run.started)
    assert.equals("fetching", state.phase("/a"))
    assert.equals("pending", state.phase("/c"))
    assert.equals("fetch", state.holder("/a"))
    assert.is_nil(state.holder("/c"), "a queued repository holds no lock yet")

    complete("/b")
    until_(function()
      return #run.started == 3
    end)
    assert.same({ "/a", "/b", "/c" }, run.started, "a freed slot takes the next row")
    assert.equals("done", state.phase("/b"))
  end)

  it("reports in row order whichever finished first, and ends the bulk", function()
    start({ "a", "b", "c" }, { limit = 3 })
    complete("/c")
    complete("/a", false)
    complete("/b")
    until_(function()
      return run.results ~= nil
    end)

    assert.same({ "a", "b", "c" }, names_of(run.results))
    assert.is_false(run.results[1].ok)
    assert.equals("exploded", run.results[1].err)
    assert.is_true(run.results[3].ok)
    assert.is_nil(state.bulk_verb())
    assert.is_nil(state.phase("/a"))
  end)

  it("a row settles and gives up its slot only after its re-read", function()
    start({ "a", "b" }, { hold_rereads = true })
    complete("/a")
    until_(function()
      return run.rereads["/a"] ~= nil
    end)

    assert.is_nil(state.holder("/a"), "the lock goes with the process")
    assert.equals("fetching", state.phase("/a"), "not settled while the re-read is out")
    assert.same({ "/a" }, run.started, "the slot is still taken")

    run.rereads["/a"]({ path = "/a" })
    until_(function()
      return #run.started == 2
    end)
    assert.equals("done", state.phase("/a"))
    assert.same({ "/a" }, run.stored)
  end)

  it("a failed row is `failed` until the batch ends", function()
    start({ "a", "b" })
    complete("/a", false)
    until_(function()
      return #run.started == 2
    end)
    assert.equals("failed", state.phase("/a"))
  end)

  it("an action that raises counts as failed and the walk goes on", function()
    local seen = {}
    start({ "a", "b" }, {
      action = function(path, on_done)
        seen[#seen + 1] = path
        if path == "/a" then error("no git here") end
        on_done(true)
      end,
    })
    until_(function()
      return run.results ~= nil
    end)

    assert.same({ "/a", "/b" }, seen)
    assert.is_false(run.results[1].ok)
    assert.truthy(run.results[1].err:find("no git here", 1, true))
    assert.is_nil(state.holder("/a"), "its lock is released too")
    assert.is_true(run.results[2].ok)
  end)

  it(
    "cancel starts nothing further, the running one finishes, only what ran is reported",
    function()
      local cancel, finished_with, updates
      updates = 0
      local handle = {
        on_cancel = function(_, fn)
          cancel = fn
        end,
        update = function()
          updates = updates + 1
        end,
        finish = function(_, text)
          finished_with = text
        end,
      }
      start({ "a", "b", "c" }, { handle = handle })
      assert.equals(1, updates)
      cancel()
      assert.is_nil(run.results, "the one in flight is not abandoned")

      complete("/a")
      until_(function()
        return run.results ~= nil
      end)
      assert.same({ "/a" }, run.started)
      assert.same({ "a" }, names_of(run.results))
      assert.equals("fetch: 1 of 3 repositories", finished_with)
      assert.is_nil(state.phase("/b"), "the cancelled tail is no longer queued")
      assert.is_nil(state.bulk_verb())
    end
  )

  it("waits for a lock somebody else holds instead of a second git on that repository", function()
    assert.is_true(state.try_lock("/b", "other"))
    start({ "a", "b", "c" }, { limit = 3 })
    assert.same({ "/a" }, run.started, "stops at the locked row, keeping the row order")
    assert.equals("pending", state.phase("/b"))

    state.unlock("/b")
    until_(function()
      return #run.started == 3
    end, "the queue did not retry the lock")
    assert.same({ "/a", "/b", "/c" }, run.started)
    assert.equals("fetch", state.holder("/b"))
  end)

  it("a superseded batch releases its locks but neither moves nor ends the newer one", function()
    start({ "a" })
    state.begin_bulk("pull", { "/a", "/n" })
    complete("/a")
    until_(function()
      return run.results ~= nil
    end)

    assert.is_nil(state.holder("/a"), "its process returned, so its lock goes")
    assert.equals("pending", state.phase("/a"), "the newer batch's row is not moved")
    assert.equals("pull", state.bulk_verb(), "the newer batch is not ended")
    assert.equals("pending", state.phase("/n"))
  end)

  it("redraws at every step a row's phase changes", function()
    start({ "a" })
    assert.equals(2, run.redraws, "queued, then running")
    complete("/a")
    until_(function()
      return run.results ~= nil
    end)
    assert.equals(4, run.redraws, "then settled, then the batch's end")
  end)

  describe("a callback that raises does not strand the batch", function()
    ---Completes `a` and `b` in turn and asserts the batch ended, with the locks gone.
    local function walk_to_the_end()
      complete("/a")
      until_(function()
        return run.waiting["/b"] ~= nil
      end, "b never started")
      complete("/b")
      until_(function()
        return run.results ~= nil
      end, "the batch never ended")
      assert.same({ "a", "b" }, names_of(run.results))
      assert.is_true(run.results[1].ok)
      assert.is_nil(state.bulk_verb(), "later batches are not refused")
      assert.is_nil(state.holder("/a"))
      assert.is_nil(state.holder("/b"))
    end

    it("the redraw, reported once", function()
      start({ "a", "b" }, {
        redraw = function()
          error("window gone")
        end,
      })
      walk_to_the_end()
      assert.equals(1, #warnings, table.concat(warnings, "\n"))
      assert.truthy(warnings[1]:find("window gone", 1, true), warnings[1])
    end)

    it("the re-read: the row settles on its old record", function()
      start({ "a", "b" }, {
        reread = function()
          error("no status")
        end,
      })
      walk_to_the_end()
      assert.same({ "nil", "nil" }, run.stored)
      assert.truthy(warnings[1]:find("no status", 1, true), warnings[1])
    end)

    it("a re-read that answered and then raised settles the row only once", function()
      start({ "a", "b", "c" }, {
        reread = function(path, on_record)
          on_record({ path = path })
          error("after the answer")
        end,
      })
      complete("/a")
      until_(function()
        return run.waiting["/b"] ~= nil
      end, "b never started")
      vim.wait(30, function()
        return false
      end)
      assert.same({ "/a", "/b" }, run.started, "a second settle would have freed a second slot")
      assert.same({ "/a" }, run.stored)
    end)

    it("storing the re-read row", function()
      start({ "a", "b" }, {
        on_reread = function()
          error("store failed")
        end,
      })
      walk_to_the_end()
      assert.truthy(warnings[1]:find("store failed", 1, true), warnings[1])
    end)

    it("every method of the progress handle", function()
      local function boom()
        error("no progress")
      end
      start({ "a", "b" }, { handle = { on_cancel = boom, update = boom, finish = boom } })
      walk_to_the_end()
      assert.equals(1, #warnings, table.concat(warnings, "\n"))
    end)
  end)

  describe("an open queue (fetch on open, fed by the scan)", function()
    local function target(name)
      return { path = "/" .. name, name = name }
    end

    it("hands back a feeder only when open", function()
      start({ "a" })
      assert.is_nil(run.feeder)
      start({}, { open = true })
      assert.is_function(run.feeder.push)
    end)

    it("runs pushed targets as they come, and does not end before close", function()
      start({}, { open = true, limit = 2 })
      assert.equals("fetch", state.bulk_verb())
      assert.is_true(run.feeder.push(target("a")))
      assert.same({ "/a" }, run.started)
      complete("/a")
      until_(function()
        return state.phase("/a") == "done"
      end)
      -- through with everything queued so far, but still open: the scan may push more
      assert.is_nil(run.results)
      assert.equals("fetch", state.bulk_verb())
      assert.is_true(run.feeder.push(target("b")))
      assert.is_true(run.feeder.push(target("c")))
      assert.is_true(run.feeder.push(target("d")))
      assert.same({ "/a", "/b", "/c" }, run.started)
      assert.equals("pending", state.phase("/d"))
      run.feeder.close()
      assert.is_false(run.feeder.push(target("e")), "closed: nothing more is taken")
      complete("/b")
      complete("/c")
      until_(function()
        return run.waiting["/d"] ~= nil
      end)
      complete("/d")
      until_(function()
        return run.results ~= nil
      end)
      assert.same({ "a", "b", "c", "d" }, names_of(run.results))
      assert.same({ cancelled = false, stopped = false }, run.ended)
      assert.is_nil(state.bulk_verb())
    end)

    it("runs open_limit at once while open, limit once closed", function()
      start({}, { open = true, open_limit = 1, limit = 3 })
      for _, name in ipairs({ "a", "b", "c", "d" }) do
        run.feeder.push(target(name))
      end
      assert.same({ "/a" }, run.started, "one while the feeder is busy")
      run.feeder.close()
      assert.same({ "/a", "/b", "/c" }, run.started, "the full limit once it is closed")
    end)

    it("ends at once when closed with nothing queued", function()
      start({}, { open = true })
      run.feeder.close()
      assert.same({}, run.results)
      assert.is_nil(state.bulk_verb())
    end)

    it("takes a path only once", function()
      start({}, { open = true })
      assert.is_true(run.feeder.push(target("a")))
      assert.is_false(run.feeder.push(target("a")))
    end)

    it("a target pushed while another holds its lock waits for it", function()
      state.try_lock("/a", "pull")
      start({}, { open = true })
      run.feeder.push(target("a"))
      assert.same({}, run.started)
      state.unlock("/a")
      until_(function()
        return #run.started == 1
      end)
    end)
  end)

  describe("stop_after_failures", function()
    it("stops starting further targets when the first ones all fail", function()
      start({ "a", "b", "c", "d", "e" }, { limit = 2, stop_after_failures = 2 })
      complete("/a", false)
      until_(function()
        return run.waiting["/c"] ~= nil
      end)
      complete("/b", false)
      -- the second failure stops the queue; c still runs to its end
      until_(function()
        return state.phase("/b") == "failed"
      end)
      assert.is_nil(run.waiting["/d"])
      complete("/c", false)
      until_(function()
        return run.results ~= nil
      end)
      assert.same({ "a", "b", "c" }, names_of(run.results))
      assert.same({ cancelled = true, stopped = true }, run.ended)
      assert.is_nil(state.bulk_verb())
    end)

    it("keeps going once one went through", function()
      start({ "a", "b", "c", "d" }, { stop_after_failures = 2 })
      for _, path in ipairs({ "/a", "/b", "/c", "/d" }) do
        until_(function()
          return run.waiting[path] ~= nil
        end)
        complete(path, path == "/a")
      end
      until_(function()
        return run.results ~= nil
      end)
      assert.equals(4, #run.results)
      assert.is_false(run.ended.stopped)
    end)

    it("refuses pushes once stopped", function()
      start({}, { open = true, stop_after_failures = 1 })
      run.feeder.push({ path = "/a", name = "a" })
      complete("/a", false)
      until_(function()
        return state.phase("/a") ~= "fetching"
      end)
      assert.is_false(run.feeder.push({ path = "/b", name = "b" }))
      run.feeder.close()
      until_(function()
        return run.results ~= nil
      end)
      assert.is_true(run.ended.stopped)
    end)
  end)
end)
