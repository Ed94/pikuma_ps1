-- gte_debug.lua — defensive version + prints error context.
local ok, err = pcall(function()
    print("[debug] PCSX exists:", PCSX ~= nil)
    print("[debug] PCSX.WebServer exists:", PCSX and PCSX.WebServer ~= nil)
    print("[debug] PCSX.WebServer.Handlers exists:", PCSX and PCSX.WebServer and PCSX.WebServer.Handlers ~= nil)
    if not PCSX.WebServer then
        print("[debug] creating PCSX.WebServer...")
        PCSX.WebServer = {}
    end
    if not PCSX.WebServer.Handlers then
        print("[debug] creating PCSX.WebServer.Handlers...")
        PCSX.WebServer.Handlers = {}
    end
    print("[debug] type of Handlers:", type(PCSX.WebServer.Handlers))

    PCSX.WebServer.Handlers.gte = function(req)
        local r = PCSX.getRegisters()
        local out = { "pc=0x" .. string.format("%x", r.pc) }
        for i = 0, 31 do
            out[#out + 1] = string.format("D[%d]=0x%08x C[%d]=0x%08x",
                i, r.CP2D.r[i], i, r.CP2C.r[i])
        end
        return table.concat(out, "\n")
    end
    print("[debug] handler registered")
end)

if not ok then
    print("[debug] ERROR: " .. tostring(err))
end