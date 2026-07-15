-- autoexec.lua - pcsx_debug_helper plugin entry point.
-- Packaged in scripts/pcsx_debug_helper.zip. Loaded by pcsx-redux via the -archive CLI flag (see scripts/launch_pcsx_debug.ps1).
--
-- Registers two web handlers for external CLI tools:
--   /api/v1/lua/gte - full GTE state (32 data + 32 control regs + PC)
--   /api/v1/lua/gp  - GP state summary (screenshot endpoint + VRAM endpoint refs)
--
-- The GTE handler reads COP2 regs via PCSX.getRegisters().CP2D/CP2C.
-- The pcsx-redux gdb stub doesn't expose COP2, so this is the only way for external tools to see GTE state.
--
-- The GP handler is a thin pointer: 
-- pcsx-redux's Lua API exposes only PCSX.GPU.takeScreenShot() (no GPUSTAT, no GP0/GP1 command log, no display state). For richer GP state, the existing web endpoints are the practical path:
--   /api/v1/state/still      - PNG screenshot
--   /api/v1/gpu/vram/raw     - VRAM raw bytes (1MB)
--
-- Companion: scripts/gdb/gdb_tape_atoms.gdb (covers GPRs + atom-aware stepping).

local function register_handlers()
    if not PCSX.WebServer then PCSX.WebServer = {} end
    if not PCSX.WebServer.Handlers then PCSX.WebServer.Handlers = {} end

    -- ── GTE state ──
    PCSX.WebServer.Handlers.gte = function(req)
        local r = PCSX.getRegisters()
        local out = { "pc=0x" .. string.format("%x", r.pc) }
        for i = 0, 31 do
            out[#out + 1] = string.format("D[%d]=0x%08x C[%d]=0x%08x",
                i, r.CP2D.r[i], i, r.CP2C.r[i])
        end
        return table.concat(out, "\n")
    end

		-- ── GP state (pointer to existing endpoints) ──
		-- pcsx-redux's Lua GPU API exposes only takeScreenShot(); no GPUSTAT / GP0 / GP1 command log / display state.
		-- We point to the existing web endpoints that DO expose those (when the emulator is actually rendering. Paused-at-BP frames won't have a fresh frame).
    PCSX.WebServer.Handlers.gp = function(req)
        local out = {
            "gpu_screenshot_png=http://localhost:8080/api/v1/state/still",
            "vram_raw=http://localhost:8080/api/v1/gpu/vram/raw (1MB VRAM)",
            "gpustat=NOT_AVAILABLE_VIA_LUA",
            "gp_command_log=NOT_AVAILABLE_VIA_LUA (use pcsx-redux Debug > GPU Logger)",
            "hint_run_emulator_unpaused_for_screenshot",
        }
        return table.concat(out, "\n")
    end
end

local ok, err = pcall(register_handlers)
if ok then print("[pcsx_debug_helper] handlers registered: gte, gp")
else       print("[pcsx_debug_helper] registration failed: " .. tostring(err))
end
