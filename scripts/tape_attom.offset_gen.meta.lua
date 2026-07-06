#!/usr/bin/env lua
-- gen_atom_offsets.lua
--
-- Finds every `MipsAtom_(name) { ... }` declaration in the given sources,
-- counts the words in each body using the WORD_COUNT manifest, computes
-- branch offsets for atom_label(name)/atom_offset(name) markers, and writes
-- one header per source into `<source_dir>/gen/<basename>.offsets.h`.
--
-- Usage:
--   lua gen_atom_offsets.lua <metadata.h> <source1> [source2 ...]

-- ============================================================
-- Character classification
-- ============================================================

local function is_space(c)
    return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f"
end

local function is_alpha(c)
    if not c or #c == 0 then return false end
    if c >= "a" and c <= "z" then return true end
    if c >= "A" and c <= "Z" then return true end
    return c == "_"
end

local function is_digit(c)
    return c and c >= "0" and c <= "9"
end

local function is_alnum(c)
    return is_alpha(c) or is_digit(c)
end

-- ============================================================
-- I/O
-- ============================================================

local function read_file(path)
    local f = io.open(path, "r")
    if not f then error("Cannot open " .. path) end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then error("Cannot write " .. path) end
    f:write(content)
    f:close()
end

local function ensure_dir(path)
    os.execute('mkdir -p "' .. path .. '"')
end

-- ============================================================
-- String primitives (no patterns)
-- ============================================================

local function trim(s)
    local a = 1
    while a <= #s and is_space(s:sub(a, a)) do a = a + 1 end
    local b = #s
    while b >= a and is_space(s:sub(b, b)) do b = b - 1 end
    return s:sub(a, b)
end

local function starts_with(s, prefix)
    if #s < #prefix then return false end
    for i = 1, #prefix do
        if s:sub(i, i) ~= prefix:sub(i, i) then return false end
    end
    return true
end

local function ends_with(s, suffix)
    if #s < #suffix then return false end
    local off = #s - #suffix
    for i = 1, #suffix do
        if s:sub(off + i, off + i) ~= suffix:sub(i, i) then return false end
    end
    return true
end

local function find_byte(haystack, target, start)
    for i = start or 1, #haystack do
        if haystack:sub(i, i) == target then return i end
    end
    return nil
end

local function dirname(path)
    local last_sep = 0
    for i = 1, #path do
        local c = path:sub(i, i)
        if c == "/" or c == "\\" then last_sep = i end
    end
    if last_sep == 0 then return "." end
    return path:sub(1, last_sep - 1)
end

local function basename_no_ext(path)
    local last_sep = 0
    for i = 1, #path do
        local c = path:sub(i, i)
        if c == "/" or c == "\\" then last_sep = i end
    end
    local a = last_sep + 1
    local last_dot = #path + 1
    for i = #path, a, -1 do
        if path:sub(i, i) == "." then last_dot = i; break end
    end
    return path:sub(a, last_dot - 1)
end

local function to_upper(s)
    local out = ""
    for i = 1, #s do
        local code = string.byte(s, i)
        if code >= 97 and code <= 122 then
            out = out .. string.char(code - 32)
        else
            out = out .. s:sub(i, i)
        end
    end
    return out
end

local function to_alnum_underscore(s)
    local out = ""
    for i = 1, #s do
        local c = s:sub(i, i)
        if is_alnum(c) then out = out .. c
        else out = out .. "_" end
    end
    return out
end

local function pad_right(s, width)
    while #s < width do s = s .. " " end
    return s
end

-- ============================================================
-- Skip whitespace and comments
-- ============================================================

local function skip_ws_and_comments(source, i)
    local len = #source
    while i <= len do
        local c = source:sub(i, i)
        if is_space(c) then
            i = i + 1
        elseif c == "/" and source:sub(i+1, i+1) == "/" then
            while i <= len and source:sub(i, i) ~= "\n" do i = i + 1 end
        elseif c == "/" and source:sub(i+1, i+1) == "*" then
            i = i + 2
            while i <= len - 1 do
                if source:sub(i, i) == "*" and source:sub(i+1, i+1) == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        else
            break
        end
    end
    return i
end

-- ============================================================
-- Read identifier
-- ============================================================

local function read_ident(source, i)
    if not is_alpha(source:sub(i, i)) then return nil, i end
    local a = i
    i = i + 1
    while i <= #source and is_alnum(source:sub(i, i)) do i = i + 1 end
    return source:sub(a, i - 1), i
end

-- ============================================================
-- Read balanced (open_char, close_char) group, return inner + new pos
-- Skips strings and comments inside.
-- ============================================================

local function read_balanced(source, open_char, close_char, i)
    if source:sub(i, i) ~= open_char then return nil, i end
    i = i + 1
    local len = #source
    local depth = 1
    local a = i
    while i <= len and depth > 0 do
        local c = source:sub(i, i)
        if c == open_char then
            depth = depth + 1
            i = i + 1
        elseif c == close_char then
            depth = depth - 1
            if depth == 0 then break end
            i = i + 1
        elseif c == '"' then
            i = i + 1
            while i <= len do
                if source:sub(i, i) == "\\" then i = i + 2
                elseif source:sub(i, i) == '"' then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "'" then
            i = i + 1
            while i <= len do
                if source:sub(i, i) == "\\" then i = i + 2
                elseif source:sub(i, i) == "'" then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "/" and source:sub(i+1, i+1) == "/" then
            while i <= len and source:sub(i, i) ~= "\n" do i = i + 1 end
        elseif c == "/" and source:sub(i+1, i+1) == "*" then
            i = i + 2
            while i <= len - 1 do
                if source:sub(i, i) == "*" and source:sub(i+1, i+1) == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return source:sub(a, i - 1), i + 1
end

local function read_parens(source, i)   return read_balanced(source, "(", ")", i) end
local function read_braces(source, i)   return read_balanced(source, "{", "}", i) end
local function read_brackets(source, i) return read_balanced(source, "[", "]", i) end

-- ============================================================
-- Scan forward from `start`, skipping balanced (), [], {}, strings, comments.
-- Returns position of first occurrence of `target` char at top level, or nil.
-- ============================================================

local function scan_to_char(source, target, start)
    local len = #source
    local i = start
    while i <= len do
        local c = source:sub(i, i)
        if c == target then
            return i
        elseif c == "(" then
            local _, after = read_parens(source, i); i = after
        elseif c == "{" then
            local _, after = read_braces(source, i); i = after
        elseif c == "[" then
            local _, after = read_brackets(source, i); i = after
        elseif c == '"' then
            i = i + 1
            while i <= len do
                if source:sub(i, i) == "\\" then i = i + 2
                elseif source:sub(i, i) == '"' then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "'" then
            i = i + 1
            while i <= len do
                if source:sub(i, i) == "\\" then i = i + 2
                elseif source:sub(i, i) == "'" then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "/" and source:sub(i+1, i+1) == "/" then
            while i <= len and source:sub(i, i) ~= "\n" do i = i + 1 end
        elseif c == "/" and source:sub(i+1, i+1) == "*" then
            i = i + 2
            while i <= len - 1 do
                if source:sub(i, i) == "*" and source:sub(i+1, i+1) == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return nil
end

-- ============================================================
-- Load WORD_COUNT manifest from metadata.h
-- ============================================================

local function load_word_counts(metadata_path)
    local counts = {}
    local content = read_file(metadata_path)
    local len = #content
    local i = 1
    local prefix = "WORD_COUNT("
    while i <= len do
        local nl = find_byte(content, "\n", i)
        local line_end = nl or (len + 1)
        local line = content:sub(i, line_end - 1)
        local trimmed = trim(line)

        if starts_with(trimmed, prefix) and ends_with(trimmed, ")") then
            local inner = trimmed:sub(#prefix + 1, #trimmed - 1)
            local comma = find_byte(inner, ",", 1)
            if comma then
                local name = trim(inner:sub(1, comma - 1))
                local cnt  = trim(inner:sub(comma + 1))
                counts[name] = tonumber(cnt)
            end
        end

        i = line_end + 1
    end
    return counts
end

-- ============================================================
-- Count words for a single comma-separated token
-- ============================================================

local function word_count_of_token(token, word_counts)
    local i = 1
    local len = #token
    while i <= len and is_space(token:sub(i, i)) do i = i + 1 end
    if i > len then return 0 end
    local name, after = read_ident(token, i)
    if not name then return 1 end
    local j = skip_ws_and_comments(token, after)
    if token:sub(j, j) == "(" then
        local wc = word_counts[name]
        if wc then return wc end
        io.stderr:write("  warning: unknown macro '" .. name .. "', assuming 1 word\n")
        return 1
    end
    return 1
end

-- ============================================================
-- Split brace-body into top-level comma-separated tokens
-- ============================================================

local function split_top_level_commas(body)
    local tokens = {}
    local len = #body
    local i = 1
    local token_start = 1
    while i <= len do
        local c = body:sub(i, i)
        if c == "(" then
            local _, after = read_parens(body, i); i = after
        elseif c == "{" then
            local _, after = read_braces(body, i); i = after
        elseif c == "[" then
            local _, after = read_brackets(body, i); i = after
        elseif c == '"' then
            i = i + 1
            while i <= len do
                if body:sub(i, i) == "\\" then i = i + 2
                elseif body:sub(i, i) == '"' then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "'" then
            i = i + 1
            while i <= len do
                if body:sub(i, i) == "\\" then i = i + 2
                elseif body:sub(i, i) == "'" then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "/" and body:sub(i+1, i+1) == "/" then
            while i <= len and body:sub(i, i) ~= "\n" do i = i + 1 end
        elseif c == "/" and body:sub(i+1, i+1) == "*" then
            i = i + 2
            while i <= len - 1 do
                if body:sub(i, i) == "*" and body:sub(i+1, i+1) == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        elseif c == "," then
            table.insert(tokens, body:sub(token_start, i - 1))
            i = i + 1
            token_start = i
        else
            i = i + 1
        end
    end
    local last = body:sub(token_start, len)
    if trim(last) ~= "" then
        table.insert(tokens, last)
    end
    return tokens
end

-- ============================================================
-- Scan an atom body for atom_label/atom_offset markers, count words
-- ============================================================

local function scan_for_atom_markers(token, at_pos, labels, branches)
    local i = 1
    local len = #token
    while i <= len do
        i = skip_ws_and_comments(token, i)
        if i > len then break end
        local c = token:sub(i, i)
        if c == '"' then
            -- Skip string literal
            i = i + 1
            while i <= len do
                if token:sub(i, i) == "\\" then i = i + 2
                elseif token:sub(i, i) == '"' then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "'" then
            -- Skip char literal
            i = i + 1
            while i <= len do
                if token:sub(i, i) == "\\" then i = i + 2
                elseif token:sub(i, i) == "'" then i = i + 1; break
                else i = i + 1 end
            end
        elseif c == "/" and token:sub(i+1, i+1) == "/" then
            while i <= len and token:sub(i, i) ~= "\n" do i = i + 1 end
        elseif c == "/" and token:sub(i+1, i+1) == "*" then
            i = i + 2
            while i <= len - 1 do
                if token:sub(i, i) == "*" and token:sub(i+1, i+1) == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        elseif is_alpha(c) then
            local ident, after = read_ident(token, i)
            if ident == "atom_label" or ident == "atom_offset" then
                local arg_start = skip_ws_and_comments(token, after)
                if token:sub(arg_start, arg_start) == "(" then
                    local inner, after_paren = read_parens(token, arg_start)
                    local n = 1
                    while n <= #inner and is_space(inner:sub(n, n)) do n = n + 1 end
                    local ns = n
                    while n <= #inner and is_alnum(inner:sub(n, n)) do n = n + 1 end
                    local name = inner:sub(ns, n - 1)
                    if name ~= "" then
                        if ident == "atom_label" then
                            labels[name] = at_pos
                        else
                            table.insert(branches, {pos = at_pos, target = name})
                        end
                    end
                    i = after_paren
                else
                    i = arg_start
                end
            else
                i = after
            end
        else
            -- Anything else (parens, brackets, braces, commas, operators) — walk past
            i = i + 1
        end
    end
end

local function scan_atom_body(body, word_counts)
    local pos = 0
    local labels = {}
    local branches = {}

    for _, tok in ipairs(split_top_level_commas(body)) do
        local k = 1
        local tlen = #tok
        while k <= tlen and is_space(tok:sub(k, k)) do k = k + 1 end
        local leading_ident, leading_after = read_ident(tok, k)

        if leading_ident == "atom_label" or leading_ident == "atom_offset" then
            scan_for_atom_markers(tok, pos, labels, branches)
        else
            local words = word_count_of_token(tok, word_counts)
            scan_for_atom_markers(tok, pos, labels, branches)
            pos = pos + words
        end
    end

    return labels, branches, pos
end

-- ============================================================
-- Token classification for atom detection
-- ============================================================

-- Skip past storage-class / qualifier noise. These appear before MipsCode
-- in raw expanded forms: `static`, `const`, the user's `internal`/`LP_`/
-- `global` macros (which all expand to `static`), `RO_` (which expands to
-- a section attribute), plus standard C qualifiers.
local function skip_qualifiers(source, i)
    local keywords = {
        ["static"]=true, ["const"]=true, ["volatile"]=true,
        ["extern"]=true, ["register"]=true, ["auto"]=true,
        ["inline"]=true, ["typedef"]=true,
        ["internal"]=true, ["LP_"]=true, ["global"]=true, ["gkknown"]=true
    }
    while true do
        i = skip_ws_and_comments(source, i)
        local ident, after = read_ident(source, i)
        if not ident then return i end
        if keywords[ident] then
            i = after
        else
            return i
        end
    end
end

-- Test whether `s` starts with literal `prefix` (no patterns).
local function has_prefix(s, prefix)
    if #s < #prefix then return false end
    for i = 1, #prefix do
        if s:sub(i, i) ~= prefix:sub(i, i) then return false end
    end
    return true
end

-- ============================================================
-- Find every atom declaration in a source, both wrapped and raw
-- ============================================================

local function find_atoms(source_text)
    local atoms = {}
    local len = #source_text
    local i = 1

    -- First, scan inside source_text normally
    local function try_wrapped_form(ident_pos)
        local paren_pos = skip_ws_and_comments(source_text, ident_pos)
        if source_text:sub(paren_pos, paren_pos) ~= "(" then
            return nil  -- not a MipsAtom_() call
        end
        local inner, after_paren = read_parens(source_text, paren_pos)
        -- Extract name (first identifier from inner)
        local n = 1
        while n <= #inner and is_space(inner:sub(n, n)) do n = n + 1 end
        local ns = n
        while n <= #inner and is_alnum(inner:sub(n, n)) do n = n + 1 end
        local name = inner:sub(ns, n - 1)
        if name == "" then return nil end

        local brace_pos = scan_to_char(source_text, "{", after_paren)
        if not brace_pos then return nil end
        local body, after_brace = read_braces(source_text, brace_pos)
        return {name = name, body = body, after_brace = after_brace}
    end

    local function try_raw_form(after_type_pos)
        local next_pos = skip_ws_and_comments(source_text, after_type_pos)
        local next_ident, next_after = read_ident(source_text, next_pos)
        if not next_ident then return nil end
        if not has_prefix(next_ident, "code_") then return nil end
        if #next_ident <= 5 then return nil end  -- bare "code_" — not an atom

        local atom_name = next_ident:sub(6)
        local brace_pos = scan_to_char(source_text, "{", next_after)
        if not brace_pos then return nil end
        local body, after_brace = read_braces(source_text, brace_pos)
        return {name = atom_name, body = body, after_brace = after_brace}
    end

    while i <= len do
        i = skip_ws_and_comments(source_text, i)
        if i > len then break end

        -- Skip past storage-class noise
        i = skip_qualifiers(source_text, i)
        if i > len then break end

        local ident, after = read_ident(source_text, i)
        if not ident then
            i = i + 1
        elseif ident == "MipsAtom_" then
            local atom = try_wrapped_form(after)
            if atom then
                table.insert(atoms, {name = atom.name, body = atom.body})
                i = atom.after_brace
            else
                i = i + 1  -- not actually MipsAtom_(), skip and continue
            end
        elseif ident == "MipsCode" then
            local atom = try_raw_form(after)
            if atom then
                table.insert(atoms, {name = atom.name, body = atom.body})
                i = atom.after_brace
            else
                i = after  -- some other MipsCode use; skip just this token
            end
        else
            -- Anything else: skip just this identifier. The next loop
            -- iteration will see whatever follows (might be more qualifiers,
            -- another type keyword, etc.).
            i = after
        end
    end

    return atoms
end

-- ============================================================
-- Compute branch offsets: target - branch - 1
-- ============================================================

local function compute_offsets(labels, branches)
    local results = {}
    for _, br in ipairs(branches) do
        local target = labels[br.target]
        if not target then
            error("Branch target '" .. br.target .. "' has no atom_label (at word " .. br.pos .. ")")
        end
        table.insert(results, {target = br.target, offset = target - br.pos - 1})
    end
    return results
end

-- ============================================================
-- Generate header for one source
-- ============================================================

local function generate_header(source_path, atoms_data)
    local basename = basename_no_ext(source_path)
    local guard = to_alnum_underscore(to_upper(basename)) .. "_OFFSETS_H"

    local lines = {}
    local function add(s) table.insert(lines, s) end

    add("// Auto-generated by gen_atom_offsets.lua — DO NOT EDIT")
    add("// Source: " .. source_path)
    add("#ifndef " .. guard)
    add("#define " .. guard)
    add("")
    add("#pragma region " .. basename)
    add("")
    add("// Override the placeholder atom_offset() to dispatch via token pasting.")
    add("#undef atom_offset")
    add("#define atom_offset(name)  atom_offset_##name")
    add("")

    for _, atom in ipairs(atoms_data) do
        add("// --- atom: " .. atom.name .. " (" .. atom.total_words .. " words) ---")
        add("")
        for _, r in ipairs(atom.offsets) do
            local const_name = "atom_offset_" .. r.target
            add("#define " .. pad_right(const_name, 40) .. "  (" .. r.offset .. ")")
        end
        add("")
    end

    add("#pragma endregion " .. basename)
    add("")
    add("#endif // " .. guard)
    return table.concat(lines, "\n") .. "\n"
end

-- ============================================================
-- Process one source
-- ============================================================

local function process_source(source_path, word_counts)
    local source = read_file(source_path)
    local atoms_raw = find_atoms(source)

    if #atoms_raw == 0 then
        io.stderr:write("  note: no MipsAtom_ declarations in " .. source_path .. "\n")
        return
    end

    local atoms_data = {}
    for _, atom in ipairs(atoms_raw) do
        local labels, branches, total = scan_atom_body(atom.body, word_counts)
        local offsets = compute_offsets(labels, branches)
        table.insert(atoms_data, {
            name = atom.name,
            total_words = total,
            offsets = offsets
        })
    end

    local basename = basename_no_ext(source_path)
    local out_dir = dirname(source_path) .. "/gen"
    ensure_dir(out_dir)
    local out_path = out_dir .. "/" .. basename .. ".offsets.h"
    write_file(out_path, generate_header(source_path, atoms_data))

    local total_branches = 0
    for _, a in ipairs(atoms_data) do total_branches = total_branches + #a.offsets end
    print("  " .. basename .. ": " .. #atoms_data .. " atom(s), " .. total_branches .. " branch(es)")
    for _, a in ipairs(atoms_data) do
        for _, r in ipairs(a.offsets) do
            print("    " .. a.name .. " -> " .. r.target .. " : " .. r.offset)
        end
    end
end

-- ============================================================
-- Main
-- ============================================================

local function main(args)
    if #args < 2 then
        print("Usage: gen_atom_offsets.lua <metadata.h> <source1> [source2 ...]")
        os.exit(1)
    end

    local metadata_path = args[1]
    local sources = {}
    for i = 2, #args do table.insert(sources, args[i]) end

    local word_counts = load_word_counts(metadata_path)
    for _, src in ipairs(sources) do process_source(src, word_counts) end
end

main({...})
