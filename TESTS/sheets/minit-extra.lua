-- TESTS/sheets/minit-extra.lua -- the minimal_init of the sheets that need gitsuite's OPTIONAL plugins
-- (open.nvim for :Git browse, insights.nvim for :Git status todos and :Git conflict list, gitsigns.nvim
-- for :Git hunk). It runs TESTS/minimal_init.lua and then puts each optional plugin on the runtimepath
-- when it can be found (sibling checkout, .deps/<name>, or the plugin manager's directory); one that is
-- missing is not an error here: the sheet says so with `requires` and is reported as a skip.

local init = dofile(
  vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "..", "minimal_init.lua")
)
local root = init.root
local home = vim.fs.normalize((vim.uv or vim.loop).os_homedir() or "")

-- In a worktree the siblings of root are other worktrees; the optional plugins sit beside the MAIN checkout.
-- A worktree's `.git` is a file ("gitdir: <main>/.git/worktrees/<name>"): read it, start no process.
local main_root
do
  -- a plain checkout has a `.git` directory, which readfile refuses: no worktree, nothing to add
  local ok, lines = pcall(vim.fn.readfile, root .. "/.git", "", 1)
  local gitdir = ok and lines[1] and lines[1]:match("^gitdir:%s*(.-)%s*$")
  -- `worktree.useRelativePaths` writes the gitdir relative to the worktree: resolve it against root
  if gitdir and not gitdir:match("^%a:[/\\]") and not gitdir:match("^[/\\]") then
    gitdir = vim.fn.fnamemodify(root .. "/" .. gitdir, ":p")
  end
  main_root = gitdir and vim.fs.normalize(gitdir):match("^(.*)/%.git/worktrees/[^/]+$")
end

for _, name in ipairs({ "open.nvim", "insights.nvim", "gitsigns.nvim" }) do
  local env = vim.env[(name:upper():gsub("[^%w]", "_")) .. "_DIR"]
  local places = {
    env or "",
    root .. "/.deps/" .. name,
    vim.fs.dirname(root) .. "/" .. name,
    main_root and (vim.fs.dirname(main_root) .. "/" .. name) or "",
    vim.fs.normalize(vim.fn.stdpath("data")) .. "/lazy/" .. name,
    -- the child editor of a sheet runs with a clean stdpath: look where a manager installs for the user
    home .. "/AppData/Local/nvim-data/lazy/" .. name,
    home .. "/.local/share/nvim/lazy/" .. name,
  }
  for _, dir in ipairs(places) do
    if dir and dir ~= "" and vim.fn.isdirectory(dir .. "/lua") == 1 then
      vim.opt.rtp:append(dir)
      break
    end
  end
end

return init
