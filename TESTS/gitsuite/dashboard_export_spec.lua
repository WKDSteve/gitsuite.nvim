-- TESTS/gitsuite/dashboard_export_spec.lua -- the reports the dashboard's `E` key exports
-- (gitsuite.features.dashboard.export): which repository lands in which report and how it reads.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

local NOW = 1000000

---@param over table
---@return RepoDashboardRecord
local function rec(over)
  return vim.tbl_extend("force", {
    name = "r",
    path = "/r",
    branch = "main",
    ahead = 0,
    behind = 0,
    has_upstream = true,
    dirty = 0,
    state = "clean",
    last_commit = NOW - 7200,
  }, over)
end

describe("gitsuite.features.dashboard.export.reports", function()
  local export = require("gitsuite.features.dashboard.export")

  local records = {
    rec({ name = "clean" }),
    rec({ name = "dirty", dirty = 4, state = "dirty" }),
    rec({ name = "behind", behind = 3, state = "behind" }),
    rec({ name = "ahead", ahead = 1, state = "ahead" }),
    rec({ name = "split", ahead = 1, behind = 2, state = "diverged" }),
    rec({ name = "pending", state = "scanning", unscanned = true }),
  }

  ---@param id string
  ---@return GitSuiteDashboardExportReport
  local function report(id)
    for _, rep in ipairs(export.reports(records)) do
      if rep.id == id then return rep end
    end
    error("no report " .. id)
  end

  it("sorts each repository into the reports it belongs to", function()
    assert.same({ 1, 2, 3, 4, 5 }, report("all").indices)
    assert.same({ 2, 3, 4, 5 }, report("attention").indices)
    assert.same({ 2 }, report("dirty").indices)
    assert.same({ 3, 5 }, report("behind").indices)
    assert.same({ 4, 5 }, report("ahead").indices)
    assert.same({ 5 }, report("diverged").indices)
  end)

  it("names the count in the choice label", function()
    assert.equals("Behind (2)", report("behind").label)
  end)

  it("leaves out repositories whose scan has not finished", function()
    for _, rep in ipairs(export.reports(records)) do
      assert.is_false(vim.tbl_contains(rep.indices, 6))
    end
  end)
end)

describe("gitsuite.features.dashboard.export.build", function()
  local export = require("gitsuite.features.dashboard.export")

  it("renders a heading and one aligned line per repository", function()
    local lines, n = export.build("behind", {
      rec({ name = "alpha", behind = 3, state = "behind" }),
      rec({ name = "be", behind = 1, state = "behind", branch = "dev" }),
      rec({ name = "gamma" }),
    }, NOW)
    assert.equals(2, n)
    assert.same({
      "Dashboard: 2 of 3 repositories (behind)",
      "",
      "alpha  main  behind  3 behind  2h",
      "be     dev   behind  1 behind  2h",
    }, lines)
  end)

  it("shows dirty file counts and combined state for the others", function()
    local lines = export.build("dirty", { rec({ name = "a", dirty = 4, state = "dirty" }) }, NOW)
    assert.equals("a  main  dirty  4 changed  2h", lines[3])
    local all = export.build("attention", {
      rec({ name = "d", ahead = 1, behind = 2, dirty = 5, state = "diverged" }),
    }, NOW)
    assert.equals("d  main  diverged  1 ahead, 2 behind, 5 changed  2h", all[3])
  end)

  it("lists a clean repository without a detail cell in the full report", function()
    local lines = export.build("all", { rec({ name = "a" }) }, NOW)
    assert.equals("a  main  clean  2h", lines[3])
  end)

  it("answers nil for an unknown report", function()
    assert.is_nil(export.build("nope", { rec({}) }, NOW))
  end)

  it("a report nobody is in is just the heading", function()
    local lines, n = export.build("ahead", { rec({}) }, NOW)
    assert.equals(0, n)
    assert.same({ "Dashboard: 0 of 1 repositories (ahead)", "" }, lines)
  end)
end)

describe("gitsuite.features.dashboard.view: E exports a report", function()
  local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { "gitsuite.util.notify", "notify", "success" },
    { "ui.kit", "select" },
    { vim.ui, "input" },
    { package.loaded, "lib.nvim.cross.copy_to_clipboard" },
  })

  local view, picks, messages, copied, copy_ok

  ---The first message that contains `text`, or nil.
  local function said(text)
    for _, msg in ipairs(messages) do
      if msg:find(text, 1, true) then return msg end
    end
    return nil
  end

  local function bufnr()
    return vim.fn.bufnr("gitsuite://dashboard")
  end

  local function press(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr(), "n")) do
      if m.lhs == lhs then
        m.callback()
        return
      end
    end
    error("no dashboard mapping for " .. lhs)
  end

  before_each(function()
    messages, copied, copy_ok = {}, nil, true
    require("gitsuite.util.notify").notify = function(msg)
      messages[#messages + 1] = msg
    end
    -- Never the real clipboard. The form without `on_done` waits for the clipboard tool (PowerShell on
    -- Windows): calling it is an error here. The form with it answers on a later tick, as lib.nvim does.
    package.loaded["lib.nvim.cross.copy_to_clipboard"] = function(text, on_done)
      if type(on_done) ~= "function" then
        error(
          "copy_to_clipboard(text) without on_done: the editor would wait for the clipboard tool"
        )
      end
      copied = text
      vim.schedule(function()
        on_done(copy_ok)
      end)
    end
    -- Answers each `kit.select` with the item whose label starts with the next entry of `picks`.
    require("ui.kit").select = function(o)
      local want = table.remove(picks, 1)
      for _, item in ipairs(o.items) do
        if o.format_item(item):find(want, 1, true) == 1 then return o.on_select(item) end
      end
      error(("no choice starting with %q"):format(want))
    end
    package.loaded["gitsuite.features.dashboard.view"] = nil
    view = require("gitsuite.features.dashboard.view")
    view.show({
      rec({ name = "alpha" }),
      rec({ name = "beta", behind = 2, state = "behind" }),
    }, { output = "buffer" })
  end)

  after_each(function()
    local buf = bufnr()
    if buf ~= -1 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end)

  it("copies the chosen report to the clipboard", function()
    picks = { "Behind", "Clipboard" }
    press("E")
    assert.is_truthy(copied, "nothing was copied")
    assert.is_truthy(copied:find("beta", 1, true))
    assert.is_nil(copied:find("alpha", 1, true), "a clean repository is not behind")
    assert.is_nil(said("to the clipboard"), "the message waits for the result of the copy")
    assert(
      vim.wait(2000, function()
        return said("Copied Behind (1) to the clipboard") ~= nil
      end),
      "no message once the copy was done: " .. vim.inspect(messages)
    )
  end)

  it("says so when the copy failed", function()
    copy_ok = false
    picks = { "Behind", "Clipboard" }
    press("E")
    assert(
      vim.wait(2000, function()
        return said("Failed to copy to the clipboard") ~= nil
      end),
      "no failure message: " .. vim.inspect(messages)
    )
    assert.is_nil(said("Copied"))
  end)

  it("output = clipboard copies the table without waiting and says so afterwards", function()
    view.show({ rec({ name = "gamma" }) }, { output = "clipboard" })
    assert.is_truthy(
      copied and copied:find("gamma", 1, true),
      "the table was handed to the clipboard"
    )
    assert(
      vim.wait(2000, function()
        return said("Dashboard copied to clipboard") ~= nil
      end),
      "no message once the copy was done: " .. vim.inspect(messages)
    )
  end)

  it("opens the report in a new scratch buffer", function()
    picks = { "All", "New buffer" }
    press("E")
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("nofile", vim.bo[buf].buftype)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("alpha", 1, true))
    assert.is_truthy(text:find("beta", 1, true))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("writes the report to the path asked for", function()
    local target = vim.fn.tempname() .. "/out.txt"
    vim.ui.input = function(_, on_confirm)
      on_confirm(target)
    end
    picks = { "Behind", "File" }
    press("E")
    local written = vim.fn.readfile(target)
    assert.is_truthy(table.concat(written, "\n"):find("beta", 1, true))
    vim.fn.delete(vim.fn.fnamemodify(target, ":h"), "rf")
  end)

  it("says so, and asks nothing more, when the report is empty", function()
    picks = { "Diverged" }
    press("E")
    assert.is_truthy((messages[#messages] or ""):find("Nothing to export", 1, true))
    assert.equals(0, #picks)
  end)
end)
