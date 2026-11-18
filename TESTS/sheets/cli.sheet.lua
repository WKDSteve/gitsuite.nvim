-- Live check of the read-only command line (`nvim --headless -u NONE -l scripts/gitsuite.lua <command>`, docs/cli.md)
-- on a real throwaway repository: status, log, blame and breaking each answer one JSON document.
-- The script only puts the plugin on the runtimepath and calls `require("gitsuite.cli").run(argv)`; the sheet calls
-- that same function in its child editor, so `testing perf` sees the git processes of every command (a separate
-- `nvim -l` would start them in a process the trace does not reach). stdout is the child's RPC channel: while a
-- command runs, io.stdout and io.stderr are swapped for recorders.
return {
  id = "gitsuite.cli",
  feature = "gitsuite.cli",
  title = "scripts/gitsuite.lua status, log, blame and breaking answer JSON on a real repository",
  task = "gitsuite.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  sizes = { { rows = 40, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua"); _G.boot()
      -- runs one command line like the script does; returns the exit code and the decoded stdout
      _G.cli = function(argv)
        local out, err = {}, {}
        local function recorder(into)
          return { write = function(self, ...) for _, s in ipairs({ ... }) do into[#into + 1] = s end return self end }
        end
        local stdout, stderr = io.stdout, io.stderr
        io.stdout, io.stderr = recorder(out), recorder(err)
        local ok, code = pcall(require("gitsuite.cli").run, argv)
        io.stdout, io.stderr = stdout, stderr
        assert(ok, code)
        local text = table.concat(out)
        _G.cli_err = table.concat(err)
        return code, text ~= "" and vim.json.decode(text) or nil
      end]],
      note = "a throwaway repository with two commits; the command line as a function",
    },
    {
      expect = [[(function()
        local code, doc = _G.cli({ "status", _G.repo })
        return code == 0 and doc.schema == "gitsuite.cli/1" and doc.ok and #doc.result.repos == 1
          and doc.result.repos[1].branch == "main"
      end)()]],
      note = "status names the branch of the repository",
    },
    {
      expect = [[(function()
        local code, doc = _G.cli({ "log", _G.repo, "--count=5", "--files" })
        return code == 0 and #doc.result.commits == 2 and doc.result.commits[1].subject == "second"
      end)()]],
      note = "log lists both commits, newest first",
    },
    {
      expect = [[(function()
        local code, doc = _G.cli({ "blame", _G.repo .. "/notes.txt", "--line=2" })
        return code == 0 and doc.ok and vim.inspect(doc.result):find("second", 1, true) ~= nil
      end)()]],
      note = "blame names the commit of line 2",
    },
    {
      expect = [[(function()
        local code, doc = _G.cli({ "breaking", _G.repo, "--from=HEAD~1" })
        return code == 0 and doc.ok and doc.command == "breaking"
      end)()]],
      note = "breaking checks HEAD~1..HEAD",
    },
    {
      expect = [[(function()
        local code = _G.cli({ "log", _G.repo, "--count=x" })
        return code == 2 and _G.cli_err:find("usage", 1, true) ~= nil
      end)()]],
      note = "a bad option is a usage error (exit 2) on stderr",
    },
  },
  manual = {
    "nvim --headless -u NONE -l scripts/gitsuite.lua status --dir=<your repos> prints one JSON document",
  },
}
