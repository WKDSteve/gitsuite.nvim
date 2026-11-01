-- TESTS/gitsuite/adapter_door_spec.lua -- PRIN-07: `adapter.resolve` is the one door to a soft dependency.
-- A feature module that `pcall(require, "gitsuite.adapter.<name>")`s an adapter itself skips the
-- registry (and its cache), so the source tree is scanned for that form outside lua/gitsuite/adapter/.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

---@param dir string
---@param hits string[]
local function scan(dir, hits)
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    if kind == "directory" then
      if name ~= "adapter" then scan(path, hits) end
    elseif name:match("%.lua$") then
      local f = io.open(path, "rb")
      if f then
        local text = f:read("*a")
        f:close()
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          if line:find('pcall(require, "gitsuite.adapter.', 1, true) then
            hits[#hits + 1] = path .. ": " .. vim.trim(line)
          end
        end
      end
    end
  end
  return hits
end

describe("soft dependencies go through adapter.resolve", function()
  it("no feature module pcall-requires an adapter itself", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
      .. "/lua/gitsuite"
    local hits = scan(root, {})
    assert.same({}, hits)
  end)
end)
