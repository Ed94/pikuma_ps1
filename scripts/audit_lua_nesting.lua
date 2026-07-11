--- audit_lua_nesting.lua — Walk Lua source files and flag any block nesting deeper than 5 levels.
---
--- Usage:
---   luajit scripts/audit_lua_nesting.lua scripts/duffle.lua scripts/ps1_meta.lua
---   luajit scripts/audit_lua_nesting.lua scripts/passes/
---
--- Output: for each file, a list of {line, depth} entries where depth > 5.
--- Returns exit code 1 if any violations found, 0 if clean.
---
--- **Implementation**: a hand-rolled depth tracker that counts:
---   - `do`, `function`, `if`, `for`, `while`, `repeat`  -> depth +1
---   - `end`, `until`                                    -> depth -1
---   - `else`, `elseif`                                  -> depth unchanged
---
--- **Caveats**: doesn't fully handle string/comment state (will miscount braces inside multi-line strings or block comments). 
--- For our metaprogram files (no embedded code generation), this is acceptable.

local M = {}

local BLOCK_OPEN = {
    ["do"]      = true,
    ["function"] = true,
    ["if"]      = true,
    ["for"]     = true,
    ["while"]   = true,
    ["repeat"]  = true,
}

local function is_block_close(token) return token == "end" or token == "until" end

-- (internal) Walk one source file and return a list of
-- {line, depth, token} entries where depth > max_nesting.
local function audit_file(path, max_nesting)
    local f = io.open(path, "r")
    if not f then error("Cannot open " .. path) end
    local content = f:read("*a")
    f:close()

    local violations = {}
    local depth      = 0
    local line       = 1
    local pos        = 1
    local src_len    = #content
    local token_idx  = 0

    local function read_ident_at(start_pos)
        local ident_start = start_pos
        if ident_start > src_len then return nil end
        local first_ch = content:sub(ident_start, ident_start)
        if not (first_ch:match("[%a_]")) then return nil end
        local scan = start_pos + 1
        while scan <= src_len do
            local ch = content:sub(scan, scan)
            if not (ch:match("[%w_]")) then break end
            scan = scan + 1
        end
        return content:sub(ident_start, scan - 1), scan
    end

    -- Skip past a string literal or comment starting at `start_pos`.
    -- Returns the position just past the construct, or nil if `start_pos`
    -- is not the start of a string/comment.
    local function skip_string_or_comment(start_pos)
        local ch = content:sub(start_pos, start_pos)
        if ch == '"' or ch == "'" then
            local scan = start_pos + 1
            while scan <= src_len do
                local c = content:sub(scan, scan)
                if c == "\\" then
                    scan = scan + 2
                elseif c == ch then
                    return scan + 1
                else
                    scan = scan + 1
                end
            end
            return src_len + 1
        elseif ch == "-" and content:sub(start_pos + 1, start_pos + 1) == "-" then
            local scan = start_pos + 2
            if content:sub(scan, scan + 1) == "[[" and content:sub(scan + 2, scan + 3) == "[" then
                -- Long bracket comment [==[ ... ]==]
                scan = scan + 2
                local eq = ""
                while content:sub(scan, scan) == "=" do
                    eq = eq .. "="
                    scan = scan + 1
                end
                local close_marker = "]" .. eq .. "]"
                local close_pos = content:find(close_marker, scan, true)
                if close_pos then
                    return close_pos + #close_marker
                else
                    return src_len + 1
                end
            else
                while scan <= src_len and content:sub(scan, scan) ~= "\n" do scan = scan + 1 end
                return scan + 1
            end
        elseif ch == "[" and content:sub(start_pos + 1, start_pos + 1) == "[" then
            local scan = start_pos + 2
            local eq = ""
            while content:sub(scan, scan) == "=" do
                eq = eq .. "="
                scan = scan + 1
            end
            local close_marker = "]" .. eq .. "]"
            local close_pos = content:find(close_marker, scan, true)
            if close_pos then
                return close_pos + #close_marker
            else
                return src_len + 1
            end
        end
        return nil
    end

    while pos <= src_len do
        local ch = content:sub(pos, pos)
        if ch == "\n" then line = line + 1 end

        local skip_to = skip_string_or_comment(pos)
        if skip_to then
            for scan = pos, skip_to - 1 do
                if content:sub(scan, scan) == "\n" then line = line + 1 end
            end
            pos = skip_to
        elseif ch:match("[%a_]") then
            local tok, next_pos = read_ident_at(pos)
            token_idx = token_idx + 1
            if BLOCK_OPEN[tok] then
                depth = depth + 1
                if depth > max_nesting then
                    violations[#violations + 1] = {
                        line  = line,
                        depth = depth,
                        token = tok,
                    }
                end
            elseif is_block_close(tok) then
                depth = depth - 1
            end
            pos = next_pos
        else
            pos = pos + 1
        end
    end

    return violations
end

--- Audit one file. Returns nil if clean, else a list of violations.
--- @param path string
--- @param max_nesting integer  -- default 5
--- @return table|nil
function M.audit(path, max_nesting)
    local violations = audit_file(path, max_nesting or 5)
    if #violations == 0 then return nil end
    return violations
end

-- Module CLI.
if arg and arg[1] then
    local max_nesting = 5
    local files = {}
    for arg_idx = 1, #arg do
        if arg[arg_idx] == "--max" and arg[arg_idx + 1] then
            max_nesting = tonumber(arg[arg_idx + 1]) or 5
        else
            files[#files + 1] = arg[arg_idx]
        end
    end

    -- Accept either a directory or a file path. Directory args are
    -- expanded via `dir /b *.lua` (Windows) or `ls *.lua` (Unix).
    local function is_dir(p)
        local f = io.open(p, "r")
        if f then f:close() return false end
        return true
    end
    local function list_lua(dir)
        local out = {}
        local cmd
        if package.config:sub(1, 1) == "\\" then
            cmd = 'dir /b "' .. dir .. '\\*.lua" 2>nul'
        else
            cmd = 'ls -1 "' .. dir .. '"/*.lua 2>/dev/null'
        end
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                if line:match("%.lua$") then
                    out[#out + 1] = dir .. "/" .. line
                end
            end
            p:close()
        end
        return out
    end

    local to_check = {}
    for _, f in ipairs(files) do
        if is_dir(f) then
            for _, sub in ipairs(list_lua(f)) do to_check[#to_check + 1] = sub end
        else
            to_check[#to_check + 1] = f
        end
    end

    local total_violations = 0
    for _, f in ipairs(to_check) do
        local v = M.audit(f, max_nesting)
        if v then
            io.write(string.format("\n%s\n", f))
            for _, x in ipairs(v) do
                io.write(string.format("  line %d: depth %d (after '%s')\n", x.line, x.depth, x.token))
            end
            total_violations = total_violations + #v
        end
    end

    if total_violations == 0 then
        io.write("OK: no files exceed max nesting of " .. max_nesting .. "\n")
        os.exit(0)
    else
        io.write(string.format("\n%d nesting violation(s) found.\n", total_violations))
        os.exit(1)
    end
end

return M
