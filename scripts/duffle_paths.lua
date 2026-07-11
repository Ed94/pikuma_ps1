--- duffle_paths.lua — Single-line bootstrap helper for the tape-atom Lua scripts.
---
--- Each entry script (ps1_meta.lua, word_count_eval.lua, and the 5 passes/*.lua files) starts with:
---   ```lua
---   local duffle = dofile((arg[0]:match("(.*[/\\])") or "./") .. "duffle_paths.lua")
---   ```
--- That single line: (a) locates this helper via `arg[0]`, 
--- (b) loads it (which sets `package.path` + `package.cpath` via `git rev-parse`),
--- (c) returns the `M` table (a wrapper around the setup function). 
--- After this line, `require("duffle")` and `require("passes.X")` both resolve normally.

local M = {}

-- Cache key for the repo root. Stored in `package.loaded` (process-global) so all 8 entry scripts + passes scripts share one git call.
-- Without this cache, `git rev-parse --show-toplevel` runs once per script load.
local CACHE_KEY = "__duffle_repo_root__"

--- Resolve the repo root via git (cached after first call).
--- Returns a normalized path with a trailing forward-slash, or nil if not in a git repo.
--- @return string|nil
local function find_repo_root()
	if package.loaded[CACHE_KEY] then return package.loaded[CACHE_KEY] end
	local p = io.popen("git rev-parse --show-toplevel 2>nul")
	local root
	if p then root = p:read("*l"); p:close() end
	if not root or root == "" then return nil end
	-- Normalize to forward slashes (Windows accepts both, but mixed `\` + `/` confuses LuaJIT's file APIs).
	root = root:gsub("\\", "/")
	if not root:match("/$") then root = root .. "/" end
	package.loaded[CACHE_KEY] = root
	return root
end

--- Set `package.path` (for `require("duffle")` + `require("passes.X")`) and
--- `package.cpath` (for `lpeg.dll`).
---
--- This script does NOT touch the OS environment: no `os.setenv`, no `os.putenv`, no `$PATH` mods. 
--- It just sets `package.path` and `package.cpath` (the standard Lua way to register module search dirs). 
--- lpeg is built by `update_deps.ps1` to `toolchain/lpeg/`, 
--- which we wire into `package.cpath` here (so `require("lpeg")` from `duffle.lua` resolves without any global state).
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

	-- lpeg: built by `update_deps.ps1` to `toolchain/lpeg/lpeg.dll`.
	-- Wire its directory into cpath so `require("lpeg")` resolves.
	local lpeg_dir = repo_root .. "toolchain/lpeg/"
	package.cpath = lpeg_dir .. "?.dll;"
		.. package.cpath
end

-- Run the setup as a side effect.
M.setup()

return M
