--- audit_lua_nesting.lua — Walk Lua source files and flag any block
--- nesting deeper than 5 levels.
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
---   - `else`, `elseif`                                 -> depth unchanged
---
--- **Caveats**: doesn't handle string/comment state (will miscount
--- braces inside strings). For our metaprogram files (no embedded
--- code generation), this is acceptable.

local M = {}

local BLOCK_OPEN = {
    ["do"]      = true,
    ["function"] = true,
    ["if"]      = true,
    ["for"]     = true,
    ["while"]   = true,
    ["repeat"]  = true,
}

local function is_block_close(token)
    return token == "end" or token == "until"
end

-- (internal) Walk one source file and return a list of
-- {line, depth, token} entries where depth > MAX_NESTING.
local function audit_file(path, max_nesting)
    local f = io.open(path, "r")
    if not f then
        error("Cannot open " .. path)
    end
    local content = f:read("*a")
    f:close()

    local violations = {}
    local depth = 0
    local line  = 1
    local pos   = 1
    local len   = #content
    local token_start = 0

    local function read_ident_at(p)
        -- Lua ident: [a-zA-Z_][a-zA-Z0-9_]*
        local start = p
        if start > len then return nil end
        local ch = content:sub(start, start)
        if not (ch:match("[%a_]")) then return nil end
        p = p + 1
        while p <= len do
            local c = content:sub(p, p)
            if not (c:match("[%w_]")) then break end
            p = p + 1
        end
        return content:sub(start, p - 1), p
    end

    local function skip_string_or_comment(p)
        local ch = content:sub(p, p)
        if ch == '"' or ch == "'" then
            -- String literal: skip to matching end-quote.
            p = p + 1
            while p <= len do
                local c = content:sub(p, p)
                if c == "\\" then
                    p = p + 2
                elseif c == ch then
                    p = p + 1
                    break
                else
                    p = p + 1
                end
            end
            return p
        elseif ch == "-" and content:sub(p + 1, p + 1) == "-" then
            -- Lua comment: -- to end of line.
            p = p + 2
            if content:sub(p, p + 1) == "[[" and content:sub(p + 2, p + 3) == "[" then
                -- Long bracket comment [==[ ... ]==]
                p = p + 2
                local eq = ""
                while content:sub(p, p) == "=" do
                    eq = eq .. "="
                    p = p + 1
                end
                local close_marker = "]" .. eq .. "]"
                local close_pos = content:find(close_marker, p, true)
                if close_pos then
                    p = close_pos + #close_marker
                else
                    p = len + 1
                end
            else
                while p <= len and content:sub(p, p) ~= "\n" do p = p + 1 end
            end
            return p
        elseif ch == "[" and content:sub(p + 1, p + 1) == "[" then
            -- Long bracket string: [==[ ... ]==]
            p = p + 2
            local eq = ""
            while content:sub(p, p) == "=" do
                eq = eq .. "="
                p = p + 1
            end
            local close_marker = "]" .. eq .. "]"
            local close_pos = content:find(close_marker, p, true)
            if close_pos then
                p = close_pos + #close_marker
            else
                p = len + 1
            end
            return p
        end
        return nil
    end

    local token_count = 0
    while pos <= len do
        local ch = content:sub(pos, pos)
        if ch == "\n" then line = line + 1 end

        local skip_to = skip_string_or_comment(pos)
        if skip_to then
            for i = pos, skip_to - 1 do
                if content:sub(i, i) == "\n" then line = line + 1 end
            end
            pos = skip_to
        elseif ch:match("[%a_]") then
            local tok, next_pos = read_ident_at(pos)
            token_count = token_count + 1
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
    for i = 1, #arg do
        if arg[i] == "--max" and arg[i + 1] then
            max_nesting = tonumber(arg[i + 1]) or 5
        else
            files[#files + 1] = arg[i]
        end
    end

    -- Accept either a directory or a file path. Directory args are
    -- expanded via `dir /b *.lua` (Windows) or `ls *.lua` (Unix).
    local function is_dir(p)
        -- Try opening it as a file; if that succeeds, it's not a dir.
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