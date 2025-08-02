#!/usr/bin/env lua

local usage = [[
lua bin2exe.lua infile outfile

Converts a raw binary file to PlayStation 1 (PS-X) executable format.
]]

function file_size(filename)
    local file = io.open(filename, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

function main(args)
    if #args ~= 2 then
        io.stderr:write(usage)
        os.exit(1)
    end

    -- print(string.format("Input file:  %s", args[1]))
    -- print(string.format("Output file: %s", args[2]))
    
    -- PS1 executables have a maximum size limit of 2MB
    local max_size = 0x200000
    -- print(string.format("\nChecking input file size (max: %d bytes)...", max_size))
    
    local infile_size = file_size(args[1])
    if not infile_size then
        io.stderr:write("Error: Cannot open input file " .. args[1] .. "\n")
        os.exit(1)
    end
    
    -- print(string.format("Input file size: %d bytes", infile_size))
    
    if infile_size > max_size then
        io.stderr:write(string.format("Error: Input file %s longer than %d bytes\n", args[1], max_size))
        os.exit(1)
    end

    -- print("\nOpening files...")
    local ofile = io.open(args[2], "wb")
    if not ofile then
        io.stderr:write("Error: Cannot open output file " .. args[2] .. "\n")
        os.exit(1)
    end
    
    local ifile = io.open(args[1], "rb")
    if not ifile then
        io.stderr:write("Error: Cannot open input file " .. args[1] .. "\n")
        os.exit(1)
    end

    -- PS1 executables start with "PS-X EXE" magic string
    -- print("Writing PS-X executable header...")
    ofile:write("PS-X EXE")
    
    -- Write entry point address (where the PS1 will jump to start execution)
    -- 0x80010000 is a standard entry point in PS1 RAM
    ofile:seek("set", 0x10)
    ofile:write(string.pack("<I4", 0x80010000))
    -- print("  Entry point:   0x80010000")
    
    -- Initial GP/R28 register value (Global Pointer for data addressing)
    -- 0xFFFFFFFF means it will be set by crt0.S startup code
    ofile:write(string.pack("<I4", 0xFFFFFFFF))
    
    -- Destination address in RAM where the executable will be loaded
    ofile:write(string.pack("<I4", 0x80010000))
    -- print("  Load address:  0x80010000")
    
    -- Initial stack pointer (SP/R29) and frame pointer (FP/R30)
    -- 0x801FFF00 points near the top of the 2MB main RAM
    ofile:seek("set", 0x30)
    ofile:write(string.pack("<I4", 0x801FFF00))
    -- print("  Stack pointer: 0x801FFF00")
    
    -- PS1 executables have an 0x800 (2048) byte header
    -- Zero fill the rest of the header
    ofile:seek("set", 0x800)
    -- print("  Header padding complete (2048 bytes)")

    -- Copy the actual program binary data after the header
    -- print("\nCopying program data...")
    local buffer_size = 0x2000  -- 8KB chunks for efficient copying
    local bytes_copied = 0
    
    for i = 0, math.ceil(infile_size / buffer_size) - 1 do
        local buffer = ifile:read(buffer_size)
        if buffer then
            ofile:write(buffer)
            bytes_copied = bytes_copied + #buffer
            -- Show progress every 64KB
            if bytes_copied % 0x10000 == 0 or bytes_copied == infile_size then
                print(string.format("  Copied %d/%d bytes (%.1f%%)", 
                    bytes_copied, infile_size, (bytes_copied / infile_size) * 100))
            end
        end
    end

    -- PS1 executables must be padded to 0x800 (2048) byte boundaries
    print("\nAligning to 2048-byte boundary...")
    local exe_size = ofile:seek()
    if exe_size % 0x800 ~= 0 then
        local padding = 0x800 - (exe_size % 0x800)
        exe_size = exe_size + padding
        ofile:seek("set", exe_size - 1)
        ofile:write(string.pack("B", 0))
        print(string.format("  Added %d bytes of padding", padding))
    else
        print("  No padding needed")
    end

    -- Write the size of the executable (excluding the 0x800 byte header)
    -- This goes at offset 0x1C in the header
    ofile:seek("set", 0x1C)
    ofile:write(string.pack("<I4", exe_size - 0x800))
    -- print(string.format("\nProgram size field set to: %d bytes", exe_size - 0x800))

    ifile:close()
    ofile:close()
    
    -- print(string.format("\nSuccess! PS1 executable created: %s", args[2]))
    print(string.format("Total file size: %d bytes\n", exe_size))
end

-- Run main with command line arguments
main(arg)
os.exit(0)
