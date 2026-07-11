--- duffle_paths.lua — Single-line bootstrap helper for the tape-atom
--- Lua scripts.
---
--- Each entry script (ps1_meta.lua, word_count_eval.lua, and the 5
--- passes/*.lua files) starts with:
---
---   ```lua
---   local duffle = dofile((arg[0]:match("(.*[/\\])") or "./") .. "duffle_paths.lua")
---   ```
---
--- That single line: (a) locates this helper via `arg[0]`, (b) loads
--- it (which sets `package.path` + `package.cpath` via `git rev-parse`),
--- (c) returns the `M` table (a wrapper around the setup function).
--- After this line, `require("duffle")` and `require("passes.X")` both
--- resolve normally.
---
--- **Why a helper instead of inline?**
---   - The 8-line path-setup boilerplate was duplicated across 7 entry
---     scripts (one per file). Single source of truth here.
---   - Mirrors the build script's pattern in `build_psyq.ps1`:
---     `$path_root = split-path -Path $PSScriptRoot -Parent;` then
---     derive everything from there.
---
--- **Why `git rev-parse --show-toplevel`?**
--- Hardcoding `C:\\projects\\Pikuma\\ps1\\...` breaks portability. Git
--- gives us the canonical repo root regardless of where the repo lives
--- on disk.

local M = {}

--- Resolve the repo root via git. Returns a normalized path with a
--- trailing forward-slash, or nil if not in a git repo.
--- @return string|nil
local function find_repo_root()
	local p = io.popen("git rev-parse --show-toplevel 2>nul")
	local root
	if p then
		root = p:read("*l")
		p:close()
	end
	if not root or root == "" then return nil end
	-- Normalize to forward slashes (Windows accepts both, but mixed
	-- `\` + `/` confuses LuaJIT's file APIs).
	root = root:gsub("\\", "/")
	if not root:match("/$") then root = root .. "/" end
	return root
end

--- Set `package.path` (for `require("duffle")` + `require("passes.X")`)
--- and `package.cpath` (for `lpeg.dll` on Windows).
function M.setup()
	local repo_root = find_repo_root()
	if not repo_root then
		io.stderr:write("[duffle_paths] git rev-parse failed -- not in a git repo?\n")
		os.exit(2)
	end

	local scripts_dir = repo_root .. "scripts/"
	local passes_dir  = repo_root .. "scripts/passes/"
	package.path = scripts_dir .. "?.lua;"
		.. scripts_dir .. "?/init.lua;"
		.. passes_dir  .. "?.lua;"
		.. passes_dir  .. "?/init.lua;"
		.. package.path

	if package.config:sub(1, 1) == "\\" then
		package.cpath = repo_root .. "toolchain/luajit-2.1/lib/lua/5.1/?.dll;"
			.. package.cpath
	end
end

-- Run the setup as a side effect.
M.setup()

return M