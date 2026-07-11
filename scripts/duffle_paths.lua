--- duffle_paths.lua — Single-line bootstrap helper for the tape-atom Lua scripts.
---
--- Each entry script (ps1_meta.lua + the 7 passes/*.lua files) starts with one of:
---   ```lua
---   -- Entry script (ps1_meta.lua — `arg[0]` is set):
---   local duffle = dofile((arg[0]:match("(.*[/\\])") or "./") .. "duffle_paths.lua")
---
---   -- Pass module (debug.getinfo path resolution; works both standalone and when require'd):
---   local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
---   local duffle = dofile(_bootstrap_dir .. "../duffle_paths.lua")
---   ```
---
--- That small bootstrap: (a) locates this helper via `arg[0]` / `debug.getinfo`,
--- (b) loads it (which sets `package.path` + `package.cpath` via cached `git rev-parse`),
--- (c) at the bottom calls `require("duffle")` (now resolvable since `package.path` was just set) and returns the duffle M.
--- Net effect: the caller gets the duffle module in one statement; no separate `dofile(...)` + `require("duffle")` dance.
---
--- Replaces the prior 2-line (entry) or 4-line (pass) pattern that had the call site do its own path resolution + duplicated setup.

local M = {}

-- Cache key for the repo root. Stored in `package.loaded` (process-global) so all 8 entry scripts + passes scripts share one resolution.
local CACHE_KEY = "__duffle_repo_root__"

--- Resolve the repo root from this script's own path. Zero shell spawn.
--- `duffle_paths.lua` always lives at `<repo>/scripts/duffle_paths.lua`, so the repo root is the
--- parent of the directory containing this script. We derive it directly from `debug.getinfo(1, "S").source`
--- (returns `@<path>` for the currently-running chunk).
---
--- Replaces the prior `io.popen("git rev-parse --show-toplevel")` approach, which cost ~100-180ms per
--- LuaJIT process on Windows due to git's CLI startup. The path-derive approach costs <1ms.
---
--- If this script's path can't be parsed (shouldn't happen — dofile/debug.getinfo always populates source),
--- fall back to a defensive walk: starting from this script's directory, walk UP until we find a parent that
--- contains a `scripts/` directory. The first match is the repo root.
--- @return string|nil
local function find_repo_root()
	if package.loaded[CACHE_KEY] then return package.loaded[CACHE_KEY] end

	local source = debug.getinfo(1, "S").source
	-- Strip the leading `@` (Lua's dofile marker) and the trailing `/duffle_paths.lua` filename.
	-- What remains is the directory containing this script, i.e. `<repo>/scripts/` (with trailing slash or not).
	local scripts_dir = source and source:match("^@?(.*)[/\\]duffle_paths%.lua$")
	if scripts_dir then
		-- The repo root is the parent of `scripts/`. Strip the trailing `scripts/` (with or without trailing slash).
		local root = scripts_dir:gsub("scripts[\\/]?$", "")
		root = root:gsub("\\", "/")
		if root == "" then root = "./" end
		if not root:match("/$") then root = root .. "/" end
		package.loaded[CACHE_KEY] = root
		return root
	end

	-- Defensive fallback: walk UP from this script's directory until we find a parent that contains `scripts/`.
	-- In practice this branch never fires — debug.getinfo always returns a source for dofile()'d chunks.
	local lfs = pcall(require, "lfs") and require("lfs") or nil
	if lfs then
		local dir = source and source:match("^@?(.*[/\\])") or "./"
		dir = dir:gsub("\\", "/")
		while dir and dir ~= "" do
			local candidate_scripts = dir .. "scripts"
			if lfs.attributes(candidate_scripts, "mode") == "directory" then
				dir = dir:gsub("/$", "")
				package.loaded[CACHE_KEY] = dir .. "/"
				return dir .. "/"
			end
			local parent = dir:match("^(.*)/[^/]+/$")
			if not parent then break end
			dir = parent .. "/"
		end
	end

	return nil
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
	-- lfs: compiled from pcsx-redux's vendored luafilesystem source to `toolchain/lfs/lfs.dll`.
	-- Wire both directories into cpath so `require("lpeg")` and `require("lfs")` resolve.
	local lpeg_dir = repo_root .. "toolchain/lpeg/"
	local lfs_dir  = repo_root .. "toolchain/lfs/"
	package.cpath = lpeg_dir .. "?.dll;"
		.. lfs_dir  .. "?.dll;"
		.. package.cpath
end

-- Run the setup as a side effect.
M.setup()

-- Now that package.path includes scripts/, `require("duffle")` resolves. Return the duffle module
-- so callers can do `local duffle = dofile(...duffle_paths.lua)` in one line.
return require("duffle")
