-- TESTS/gitsuite/progress_style_spec.lua -- which progress style "auto" ends up as.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
describe("gitsuite.util.progress.resolve_style", function()
  local progress = require("gitsuite.util.progress")
  local notify, fidget

  before_each(function()
    notify, fidget = vim.notify, package.loaded.fidget
    package.loaded.fidget = nil
    package.preload.fidget = nil
  end)

  after_each(function()
    vim.notify = notify
    package.loaded.fidget = fidget
    package.preload.fidget = nil
  end)

  it("keeps an explicit style", function()
    assert.equals("notify", progress.resolve_style("notify"))
    assert.equals("float", progress.resolve_style("float"))
  end)

  it("turns auto into echo with the stock vim.notify and no fidget", function()
    -- a function that reads as Neovim's own: its chunk is runtime/lua/vim/_editor.lua
    vim.notify = load("return function() end", "@/rt/lua/vim/_editor.lua")()
    package.preload.fidget = function()
      error("no fidget")
    end
    assert.equals("echo", progress.resolve_style("auto"))
  end)

  it("leaves auto alone when a notifier plugin replaced vim.notify", function()
    vim.notify = function() end
    package.preload.fidget = function()
      error("no fidget")
    end
    assert.equals("auto", progress.resolve_style("auto"))
  end)

  it("leaves auto alone when vim.notify is a callable table", function()
    vim.notify = setmetatable({}, { __call = function() end })
    package.preload.fidget = function()
      error("no fidget")
    end
    assert.equals("auto", progress.resolve_style("auto"))
  end)

  it("leaves auto alone when fidget is there", function()
    package.preload.fidget = function()
      return {}
    end
    assert.equals("auto", progress.resolve_style("auto"))
  end)
end)
