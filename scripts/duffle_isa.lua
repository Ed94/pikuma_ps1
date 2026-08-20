--- duffle_isa.lua — encoder / GTE / hardware tables.

--- @class InstructionImm
--- @field arg    integer
--- @field signed boolean|nil
--- @field width  integer

--- @class InstructionValue
--- @field dest      integer
--- @field op        string
--- @field sources   integer[]|nil
--- @field immediate integer|nil
--- @field source    integer|nil

--- @class InstructionRow
--- @field cycles        integer
--- @field kind          string
--- @field reads         integer[]|nil
--- @field writes        integer[]|nil
--- @field imm           InstructionImm[]|nil
--- @field value         InstructionValue|nil
--- @field delay_slot    boolean|nil
--- @field suppress_arg1 table<string, string>|nil  -- bag: GPR ident -> reason

--- @class TapeAtomMacroRow
--- @field kind  string
--- @field binds boolean

--- @class GteCommandPort
--- @field register string
--- @field role     string

--- @class GteCommandLatch
--- @field register string
--- @field required integer

--- @class GteCommandRow
--- @field aliases string[]
--- @field cycles  integer
--- @field inputs  string[]
--- @field outputs GteCommandPort[]
--- @field latch   GteCommandLatch[]

--- @class GteCrAliasGroup
--- @field [1] integer   -- C2 control-register slot
--- @field [2] string[]  -- aliases that share that slot

--- @class GtePackedSlotRelation
--- @field slot   integer
--- @field first  string
--- @field second string

--- @class HardwareRelationPort
--- @field domain string
--- @field arg    integer

--- @class HardwareRelationVisibility
--- @field kind     string
--- @field required integer

--- @class HardwareRelationEvidence
--- @field confidence string
--- @field source     string

--- @class HardwareRelationRow
--- @field id                string
--- @field semantic          string
--- @field consumer          string
--- @field token             string
--- @field direction         string
--- @field reads             HardwareRelationPort
--- @field writes            HardwareRelationPort
--- @field visibility        HardwareRelationVisibility|nil
--- @field evidence          HardwareRelationEvidence
--- @field violation_kind    string
--- @field destination_match string|nil
--- @field fanout_to         string[]|nil
--- @field required          integer|nil
--- @field clear_on_consumer boolean|nil
--- @field stage             boolean|nil
--- @field cu2_transition    boolean|nil
--- @field status_register   integer|nil

--- @class Cu2TransitionPolicy
--- @field status_register integer
--- @field enable_bit      integer
--- @field required        integer
--- @field visibility_kind string
--- @field evidence        HardwareRelationEvidence

--- @class GprRole
--- @field name     string
--- @field pool     boolean
--- @field optional boolean
--- @field carrier  boolean

--- @class DuffleIsa
--- @field GPR_ROLE                    table<string, GprRole>
--- @field TAPE_ATOM_MACROS            table<string, TapeAtomMacroRow>
--- @field DELAY_MARKERS               table<string, boolean>
--- @field INSTRUCTION                 table<string, InstructionRow>
--- @field GTE_COMMAND                 table<string, GteCommandRow>
--- @field ALIAS_TO_CANONICAL          table<string, string>
--- @field instr                       fun(ident: string): InstructionRow|nil
--- @field gte_canon                   fun(ident: string): string
--- @field gte                         fun(ident: string): GteCommandRow|nil
--- @field GTE_CR_ALIAS_GROUPS         GteCrAliasGroup[]
--- @field GTE_PACKED_SLOT_RELATIONS   GtePackedSlotRelation[]
--- @field OPERAND_READ_POSITIONS      table<string, integer[]>
--- @field GP0_CMD_SIZE                table<integer, integer>
--- @field GP0_CMD_BY_SHAPE            table<string, integer>
--- @field UNKNOWN_INSTRUCTION_CYCLES  integer
--- @field HARDWARE_RELATIONS          HardwareRelationRow[]
--- @field CU2_TRANSITION_POLICY       Cu2TransitionPolicy

local M = {} ---@type DuffleIsa

-- Section 7: domain tables
-- ════════════════════════════════════════════════════════════════════════════

-- One GprRole row per name. Construction order is the auto_reg pool order,
-- then R_AT, then the three carriers. Index by name into M.GPR_ROLE.
--- @type table<string, GprRole>
M.GPR_ROLE = {
	{ name = "R_V0",          pool = true,  optional = true, carrier = false },
	{ name = "R_V1",          pool = true,  optional = true, carrier = false },
	{ name = "R_T0",          pool = true,  optional = true, carrier = false },
	{ name = "R_T1",          pool = true,  optional = true, carrier = false },
	{ name = "R_T2",          pool = true,  optional = true, carrier = false },
	{ name = "R_T3",          pool = true,  optional = true, carrier = false },
	{ name = "R_T4",          pool = true,  optional = true, carrier = false },
	{ name = "R_T5",          pool = true,  optional = true, carrier = false },
	{ name = "R_T6",          pool = true,  optional = true, carrier = false },
	{ name = "R_T7",          pool = true,  optional = true, carrier = false },
	{ name = "R_A0",          pool = true,  optional = true, carrier = false },
	{ name = "R_A1",          pool = true,  optional = true, carrier = false },
	{ name = "R_A2",          pool = true,  optional = true, carrier = false },
	{ name = "R_A3",          pool = true,  optional = true, carrier = false },
	{ name = "R_S0",          pool = true,  optional = true, carrier = false },
	{ name = "R_S1",          pool = true,  optional = true, carrier = false },
	{ name = "R_S2",          pool = true,  optional = true, carrier = false },
	{ name = "R_S3",          pool = true,  optional = true, carrier = false },
	{ name = "R_S4",          pool = true,  optional = true, carrier = false },
	{ name = "R_S5",          pool = true,  optional = true, carrier = false },
	{ name = "R_S6",          pool = true,  optional = true, carrier = false },
	{ name = "R_S7",          pool = true,  optional = true, carrier = false },
	{ name = "R_T8",          pool = true,  optional = true, carrier = false },
	{ name = "R_T9",          pool = true,  optional = true, carrier = false },
	{ name = "R_AT",          pool = false, optional = true, carrier = false },
	{ name = "R_TapePtr",     pool = false, optional = true, carrier = true  },
	{ name = "R_AtomJmp",     pool = false, optional = true, carrier = true  },
	{ name = "R_ScratchBase", pool = false, optional = true, carrier = true  },
}
for _, row in ipairs(M.GPR_ROLE) do ---@type integer, GprRole
	M.GPR_ROLE[row.name] = row
end

-- atom_info sub-calls: atom_bind, atom_reads, atom_writes, atom_view, atom_reg_types, atom_ctx, atom_phase.
--- @type table<string, TapeAtomMacroRow>
M.TAPE_ATOM_MACROS = {
	["atom_info"] = { kind = "info", binds = false },
}

-- Empty C macros that prefix the next encoder. Zero words.
-- BdSlot_ nop is one nop word. The marker is not the BD instruction.
--- @type table<string, boolean>  -- bag: marker prefix -> true
M.DELAY_MARKERS = {
	["GteDelay_"] = true,
	["LdSlot_"]   = true,
	["BdSlot_"]   = true,
	["DmaSlot_"]  = true,
}

-- One row per encoder. Read through duffle.instr.
--- @type table<string, InstructionRow>
M.INSTRUCTION = {
	["BdSlot_"]            = { cycles = 0,  kind = "marker", },
	["LdSlot_"]            = { cycles = 0,  kind = "marker", },
	["add_s"]              = { cycles = 1,  kind = "alu", },
	["add_si"]             = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm = { { arg = 3, signed = true, width  = 16, },}, },
	["add_u"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["add_u_self"]         = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 },                                                       value = { dest = 1, op = "add_u", sources = { 1, 2 }, }, },
	["add_ui"]             = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm   = { { arg = 3, signed = true, width = 16, }, }, value = { dest = 1, immediate = 3, op = "add_ui", source = 2, }, },
	["add_ui_self"]        = { cycles = 1,  kind = "alu",        reads = { 1 },    writes = { 1 }, imm   = { { arg = 2, signed = true, width = 16, }, }, value = { dest = 1, immediate = 2, op = "add_ui", source = 1, },  },
	["and"]                = { cycles = 1,  kind = "alu", },
	["and_i"]              = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm   = { { arg = 3, width = 16, }, },                value = { dest = 1, immediate = 3, op = "and_i", source = 2, }, },
	["and_u"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["atom_bind"]          = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["atom_info"]          = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["atom_label"]         = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["atom_offset"]        = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["atom_reads"]         = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["atom_writes"]        = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["branch_equal"]       = { cycles = 2,  kind = "branch",     reads = { 1, 2 }, writes = {}, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["branch_ge_zero"]     = { cycles = 2,  kind = "branch",     reads = { 1 },    writes = {}, imm = { { arg = 2, signed = true, width = 16, }, }, },
	["branch_gt_zero"]     = { cycles = 2,  kind = "branch",     reads = { 1 },    writes = {}, imm = { { arg = 2, signed = true, width = 16, }, }, },
	["branch_le_zero"]     = { cycles = 2,  kind = "branch",     reads = { 1 },    writes = {}, imm = { { arg = 2, signed = true, width = 16, }, }, },
	["branch_lt_zero"]     = { cycles = 2,  kind = "branch",     reads = { 1 },    writes = {}, imm = { { arg = 2, signed = true, width = 16, }, }, },
	["branch_ne"]          = { cycles = 2,  kind = "branch",     reads = { 1, 2 }, writes = {}, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["call_addr"]          = { cycles = 2,  kind = "call",       reads = {},       writes = { 1 }, },
	["call_reg"]           = { cycles = 2,  kind = "call",       reads = { 1 },    writes = { 2 }, },
	["div_s"]              = { cycles = 35, kind = "alu",        reads = { 1, 2 }, writes = {}, },
	["div_u"]              = { cycles = 35, kind = "alu",        reads = { 1, 2 }, writes = {}, },
	["gte_load_v0"]        = { cycles = 2,  kind = "cop2_xfer",  reads = { 2 },    writes = {}, },
	["gte_load_v0v1v2"]    = { cycles = 6,  kind = "cop2_xfer",  reads = { 2 },    writes = {}, },
	["gte_load_v1"]        = { cycles = 2,  kind = "cop2_xfer",  reads = { 2 },    writes = {}, },
	["gte_load_v2"]        = { cycles = 2,  kind = "cop2_xfer",  reads = { 2 },    writes = {}, },
	["gte_lw"]             = { cycles = 1,  kind = "load",       reads = { 2 },    writes = {}, },
	["gte_lwc2"]           = { cycles = 1,  kind = "load", },
	["gte_mv_from_ctrl_r"] = { cycles = 1,  kind = "cop2_xfer",  reads = {},       writes = { 1 }, },
	["gte_mv_from_data_r"] = { cycles = 1,  kind = "cop2_xfer",  reads = {},       writes = { 1 }, },
	["gte_mv_to_ctrl_r"]   = { cycles = 1,  kind = "cop2_xfer",  reads = { 1 },    writes = {}, },
	["gte_mv_to_data_r"]   = { cycles = 1,  kind = "cop2_xfer",  reads = { 1 },    writes = {}, },
	["gte_stotz"]          = { cycles = 1,  kind = "cop2_xfer",  reads = {},       writes = {}, },
	["gte_stsxy3"]         = { cycles = 1,  kind = "cop2_xfer",  reads = {},       writes = {}, },
	["gte_sw"]             = { cycles = 1,  kind = "store",      reads = { 2 },    writes = {}, },
	["gte_swc2"]           = { cycles = 1,  kind = "store", },
	["jump"]               = { cycles = 2,  kind = "jump",       reads = {},       writes = {}, },
	["jump_link"]          = { cycles = 2,  kind = "call",       reads = { 1 },    writes = { 2 }, },
	["jump_reg"]           = { cycles = 2,  kind = "jump",       reads = { 1 },    writes = {}, suppress_arg1 = { R_AtomJmp = "fixed mac_yield handshake", }, },
	["jump_rel"]           = { cycles = 2,  kind = "branch", delay_slot = true, },
	["li_s"]               = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, value = { dest = 1, immediate = 3, op = "add_ui", source = 2, }, },
	["load_byte"]          = { cycles = 1,  kind = "load",       reads = { 2 },    writes = { 1 }, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["load_byte_u"]        = { cycles = 1,  kind = "load",       reads = { 2 },    writes = { 1 }, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["load_half"]          = { cycles = 1,  kind = "load",       reads = { 2 },    writes = { 1 }, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["load_half_u"]        = { cycles = 1,  kind = "load",       reads = { 2 },    writes = { 1 }, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["load_imm"]           = { cycles = 2,  kind = "alu",        reads = {},       writes = { 1 }, },
	["load_ui"]            = { cycles = 1,  kind = "alu",        reads = {},       writes = { 1 }, },
	["load_upper_i"]       = { cycles = 1,  kind = "alu",        reads = {},       writes = { 1 }, imm = { { arg = 2, width = 16, }, }, value = { dest = 1, immediate = 2, op = "load_upper_i", }, },
	["load_word"]          = { cycles = 1,  kind = "load",       reads = { 2 },    writes = { 1 }, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["mac_yield"]          = { cycles = 0,  kind = "marker",     reads = {},       writes = {}, },
	["mask_upper"]         = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, },
	["mov_from_high"]      = { cycles = 2,  kind = "alu",        reads = {},       writes = { 1 }, },
	["mov_from_low"]       = { cycles = 2,  kind = "alu",        reads = {},       writes = { 1 }, },
	["mov_to_high"]        = { cycles = 1,  kind = "alu",        reads = { 1 },    writes = {}, },
	["mov_to_low"]         = { cycles = 1,  kind = "alu",        reads = { 1 },    writes = {}, },
	["mult_s"]             = { cycles = 12, kind = "alu",        reads = { 1, 2 }, writes = {}, },
	["mult_u"]             = { cycles = 12, kind = "alu",        reads = { 1, 2 }, writes = {}, },
	["nop"]                = { cycles = 1,  kind = "nop",        reads = {},       writes = {}, },
	["nop2"]               = { cycles = 2,  kind = "nop",        reads = {},       writes = {}, },
	["nor_u"]              = { cycles = 1,  kind = "alu", },
	["or_i"]               = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm = { { arg = 3, width = 16, }, }, value = { dest = 1, immediate = 3, op = "or_i", source = 2, }, },
	["or_i_self"]          = { cycles = 1,  kind = "alu",        reads = { 1 },    writes = { 1 }, imm = { { arg = 2, width = 16, }, }, value = { dest = 1, immediate = 2, op = "or_i", source = 1, }, },
	["or_u"]               = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["or_u_self"]          = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, value = { dest = 1, op = "or", sources = { 1, 2 }, }, },
	["set_lt_s"]           = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["set_lt_si"]          = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, },
	["set_lt_u"]           = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["set_lt_ui"]          = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, },
	["shift_aright"]       = { cycles = 1,  kind = "alu",        reads = { 2 },    writes = { 1 }, imm = { { arg = 3, width = 5, }, }, },
	["shift_aright_var"]   = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, imm = { { arg = 3, width = 5, }, }, },
	["shift_lleft"]        = { cycles = 1,  kind = "alu",        reads = { 2 },    writes = { 1 }, imm = { { arg = 3, width = 5, }, }, },
	["shift_lleft_self"]   = { cycles = 1,  kind = "alu",        reads = { 1 },    writes = { 1 }, imm = { { arg = 2, width = 5, }, }, value = { dest = 1, immediate = 2, op = "shift_lleft", source = 1, }, },
	["shift_lleft_var"]    = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["shift_lright"]       = { cycles = 1,  kind = "alu",        reads = { 2 },    writes = { 1 }, imm = { { arg = 3, width = 5, }, }, },
	["slt_s"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["slt_si"]             = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm = { { arg = 3, signed = true, width = 16, }, }, },
	["slt_u"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["slt_ui"]             = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm = { { arg = 3, signed = true, width = 16,}, }, },
	["store_byte"]         = { cycles = 1,  kind = "store",      reads = { 1, 2 }, writes = {},    imm = { { arg = 3, signed = true, width = 16, }, }, },
	["store_half"]         = { cycles = 1,  kind = "store",      reads = { 1, 2 }, writes = {},    imm = { { arg = 3, signed = true, width = 16, }, }, },
	["store_word"]         = { cycles = 1,  kind = "store",      reads = { 1, 2 }, writes = {},    imm = { { arg = 3, signed = true, width = 16, }, }, },
	["sub_s"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["sub_u"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
	["sys_mov_from_cop0"]  = { cycles = 1,  kind = "cop0_xfer",  reads = {},       writes = { 1 }, },
	["sys_mov_to_cop0"]    = { cycles = 1,  kind = "cop0_xfer",  reads = { 1 },    writes = {}, },
	["xor_i"]              = { cycles = 1,  kind = "alu",        reads = { 1, 2 }, writes = { 1 }, imm = { { arg = 3, width = 16, }, }, value = { dest = 1, immediate = 3, op = "xor_i", source = 2, }, },
	["xor_u"]              = { cycles = 1,  kind = "alu",        reads = { 2, 3 }, writes = { 1 }, },
}

-- One row per GTE command. Alias cycle numbers live here, not on INSTRUCTION.
--- @type table<string, GteCommandRow>
M.GTE_COMMAND = {
	["gte_cmdw_avsz3"] = {
		aliases = { "gte_avg_sort_z3", "gte_avsz3", "gte_cmdw_avg_sort_z3" },
		cycles  = 5,
		inputs  = { "C2_SZ0", "C2_SZ1", "C2_SZ2", "C2_SZ3", "gte_cr_ZSF3" },
		outputs = {
			{ register = "C2_OTZ", role = "otz", },
		},
		latch = {
			{ register = "C2_OTZ", required = 4, },
		},
	},
	["gte_cmdw_avsz4"] = {
		aliases = { "gte_avg_sort_z4", "gte_avsz4", "gte_cmdw_avg_sort_z4" },
		cycles  = 6,
		inputs  = { "C2_SZ0", "C2_SZ1", "C2_SZ2", "C2_SZ3", "gte_cr_ZSF4" },
		outputs = {
			{ register = "C2_OTZ", role = "otz", },
		},
		latch = {
			{ register = "C2_OTZ", required = 4, },
		},
	},
	["gte_cmdw_gpf"] = {
		aliases = {},
		cycles = 5,
		inputs = { "C2_IR0", "C2_IR1", "C2_IR2", "C2_IR3" },
		outputs = {
			{ register = "C2_MAC1", role = "mac_result", },
			{ register = "C2_MAC2", role = "mac_result", },
			{ register = "C2_MAC3", role = "mac_result", },
			{ register = "C2_IR1", role = "latest_color", },
			{ register = "C2_IR2", role = "latest_color", },
			{ register = "C2_IR3", role = "latest_color", },
		},
		latch = {
			{ register = "C2_MAC1", required = 4, },
			{ register = "C2_MAC2", required = 4, },
			{ register = "C2_MAC3", required = 4, },
			{ register = "C2_IR1",  required = 4, },
			{ register = "C2_IR2",  required = 4, },
			{ register = "C2_IR3",  required = 4, },
		},
	},
	["gte_cmdw_mvmva"] = {
		aliases = {},
		cycles = 8,
		inputs = { 
			"C2_VXY0", "C2_VZ0",
			"C2_VXY1", "C2_VZ1",
			"C2_VXY2", "C2_VZ2",
			"C2_IR1", "C2_IR2", "C2_IR3",
			"gte_cr_RT11", "gte_cr_RT12", "gte_cr_RT13",
			"gte_cr_RT21", "gte_cr_RT22", "gte_cr_RT23",
			"gte_cr_RT31", "gte_cr_RT32", "gte_cr_RT33",
			"gte_cr_TRX", "gte_cr_TRY", "gte_cr_TRZ"
		},
		outputs = {
			{ register = "C2_IR1", role = "latest_color", },
			{ register = "C2_IR2", role = "latest_color", },
			{ register = "C2_IR3", role = "latest_color", },
		},
		latch = {
			{ register = "C2_IR1", required = 4, },
			{ register = "C2_IR2", required = 4, },
			{ register = "C2_IR3", required = 4, },
		},
	},
	["gte_cmdw_nclip"] = {
		aliases = { "gte_nclip" },
		cycles  = 8,
		inputs  = { "C2_SXY0", "C2_SXY1", "C2_SXY2" },
		outputs = {
			{ register = "C2_SZ3", role = "mac_result", },
		},
		latch = {
			{ register = "C2_SZ3", required = 4, },
		},
	},
	["gte_cmdw_op"] = {
		aliases = { "gte_cmdw_outer_product", "gte_cmdw_wedge" },
		cycles  = 6,
		inputs  = {},
		outputs = {
			{ register = "C2_IR1", role = "latest_color", },
			{ register = "C2_IR2", role = "latest_color", },
			{ register = "C2_IR3", role = "latest_color", },
		},
		latch = {
			{ register = "C2_IR1", required = 4, },
			{ register = "C2_IR2", required = 4, },
			{ register = "C2_IR3", required = 4, },
		},
	},
	["gte_cmdw_rtps"] = {
		aliases = { "gte_cmdw_rotate_translate_perspective_single", "gte_rtps" },
		cycles = 15,
		inputs = { 
			"C2_VXY0", "C2_VZ0",
			"C2_VXY1", "C2_VZ1",
			"C2_VXY2", "C2_VZ2",
			"C2_RGB", "C2_OTZ",
			"C2_IR0", "C2_IR1", "C2_IR2", "C2_IR3",
			"C2_SZ0", "C2_SZ1", "C2_SZ2", "C2_SZ3",
			"gte_cr_RT11", "gte_cr_RT12", "gte_cr_RT13",
			"gte_cr_RT21", "gte_cr_RT22", "gte_cr_RT23",
			"gte_cr_RT31", "gte_cr_RT32", "gte_cr_RT33",
			"gte_cr_TRX", "gte_cr_TRY", "gte_cr_TRZ",
			"gte_cr_OFX", "gte_cr_OFY",
			"gte_cr_H",
			"gte_cr_DQA", "gte_cr_DQB" 
		},
		outputs = {
			{ register = "C2_SXY2", role = "latest_screen_xy", },
			{ register = "C2_SZ2",  role = "latest_screen_z", },
			{ register = "C2_OTZ",  role = "otz", },
			{ register = "C2_IR0",  role = "latest_color", },
		},
		latch = {
			{ register = "C2_SXY2", required = 4, },
			{ register = "C2_SZ2",  required = 4, },
			{ register = "C2_OTZ",  required = 4, },
			{ register = "C2_IR0",  required = 4, },
		},
	},
	["gte_cmdw_rtpt"] = {
		aliases = { "gte_cmdw_rotate_translate_perspective_triple", "gte_rtpt" },
		cycles = 23,
		inputs = { 
			"C2_VXY0", "C2_VZ0",
			"C2_VXY1", "C2_VZ1",
			"C2_VXY2", "C2_VZ2",
			"C2_RGB",  "C2_OTZ",
			"C2_IR0",  "C2_IR1", "C2_IR2", "C2_IR3",
			"C2_SZ0",  "C2_SZ1", "C2_SZ2", "C2_SZ3",
			"gte_cr_RT11", "gte_cr_RT12", "gte_cr_RT13",
			"gte_cr_RT21", "gte_cr_RT22", "gte_cr_RT23",
			"gte_cr_RT31", "gte_cr_RT32", "gte_cr_RT33",
			"gte_cr_TRX",  "gte_cr_TRY",  "gte_cr_TRZ",
			"gte_cr_OFX",  "gte_cr_OFY",
			"gte_cr_H",
			"gte_cr_DQA", "gte_cr_DQB"
		},
		outputs = {
			{ register = "C2_SXY0", role = "screen_xy[0]", },
			{ register = "C2_SXY1", role = "screen_xy[1]", },
			{ register = "C2_SXY2", role = "latest_screen_xy", },
			{ register = "C2_SZ3",  role = "latest_screen_z", },
			{ register = "C2_OTZ",  role = "otz", },
		},
		latch = {
			{ register = "C2_SXY0", required = 4, },
			{ register = "C2_SXY1", required = 4, },
			{ register = "C2_SXY2", required = 4, },
			{ register = "C2_SZ3",  required = 4, },
			{ register = "C2_OTZ",  required = 4, },
		},
	},
	["gte_cmdw_sqr"] = {
		aliases = {},
		cycles  = 5,
		inputs  = { "C2_IR1", "C2_IR2", "C2_IR3" },
		outputs = {
			{ register = "C2_MAC1", role = "mac_result", },
			{ register = "C2_MAC2", role = "mac_result", },
			{ register = "C2_MAC3", role = "mac_result", },
			{ register = "C2_IR1",  role = "latest_color", },
			{ register = "C2_IR2",  role = "latest_color", },
			{ register = "C2_IR3",  role = "latest_color", },
		},
		latch = {
			{ register = "C2_MAC1", required = 4, },
			{ register = "C2_MAC2", required = 4, },
			{ register = "C2_MAC3", required = 4, },
			{ register = "C2_IR1",  required = 4, },
			{ register = "C2_IR2",  required = 4, },
			{ register = "C2_IR3",  required = 4, },
		},
	},
}

--- @param ident string
--- @return InstructionRow|nil
function M.instr    (ident) return M.INSTRUCTION            [ident]          end
--- @param ident string
--- @return string
function M.gte_canon(ident) return M.ALIAS_TO_CANONICAL     [ident] or ident end
--- @param ident string
--- @return GteCommandRow|nil
function M.gte      (ident) return M.GTE_COMMAND[M.gte_canon(ident)]         end

--- @return nil
local function build_alias_map()
	--- @type table<string, string>  -- bag: alias or canon -> canon
	M.ALIAS_TO_CANONICAL = {}
	for canon, row in pairs(M.GTE_COMMAND) do ---@type string, GteCommandRow
		M.ALIAS_TO_CANONICAL[canon] = canon
		for _, alias in ipairs(row.aliases or {}) do ---@type integer, string
			M.ALIAS_TO_CANONICAL[alias] = canon
		end
	end
end
build_alias_map()


--- GTE control-register alias groups.
--- Aliases within a group write to the same C2 control-register slot (the HW double-maps some C2 slots across multiple PSX SDK / libgte conventions).
--- Aliases across groups write to distinct C2 slots.
---
--- Cross-alias writes inside one atom body, or across the wave-context boundary, silently clobber each other.
--- The `check_gte_cr_alias_writes` check warns about each pair per source. See `docs/gte_reference.md` §"Control-register alias table"
--- for the HW rationale and the libgte outer-product convention.
--- @type GteCrAliasGroup[]
M.GTE_CR_ALIAS_GROUPS = {
	{ 24, { "gte_cr_RBK", "gte_cr_OFX" } },   -- background R vs screen offset X
	{ 25, { "gte_cr_GBK", "gte_cr_OFY" } },   -- background G vs screen offset Y
	{ 26, { "gte_cr_BBK", "gte_cr_H"   } },   -- background B vs projection plane distance H
}

-- Packed RT slots named by the gte.h packed-slot comment. First must be written before second.
--- @type GtePackedSlotRelation[]
M.GTE_PACKED_SLOT_RELATIONS = {
	{ slot = 2, first = "gte_cr_RT13", second = "gte_cr_RT22" },
}

-- Operand-class table for the COP2->GPR load-delay check.
-- Maps each emitting-token ident to the set of GPR operand positions it reads.
-- Covers the current encoder vocabulary (`code/duffle/mips.h` + `code/duffle/gte.h`); add rows here as new encoders land.
--
-- Semantics:
--   * A "GPR operand position" is the textual slot in the macro's argument list, 1-based; e.g. `load_word(rt, base, off)` has positional operands 1 (rt), 2 (base), 3 (off).
--     The table reads operands 1 + 2 + 3 to find what GPRs the macro touches.
--   * The check tracks one entry per destination GPR per MFC2 / CFC2 event.
--     A subsequent event counts as a "use" iff any of its read operand positions reference that destination GPR's ident (e.g. `R_T0`).
--   * Branch delay slots are out of scope (MIPS control-flow; tracked separately).
--- @type table<string, integer[]>  -- bag: encoder ident -> GPR operand positions
M.OPERAND_READ_POSITIONS = {
	-- CPU ALU with one or two GPR operands. Reads every GPR operand.
	["add_ui"]                 = {1, 2},
	["li_s"]                   = {1, 2},  -- rt (write), imm16 (immediate)
	["add_ui_self"]            = {1},
	["add_si"]                 = {1, 2},
	["add_u"]                  = {1, 2, 3},
	["add_u_self"]             = {1, 2},
	["sub_s"]                  = {1, 2, 3},
	["sub_u"]                  = {1, 2, 3},
	["and_i"]                  = {1, 2},
	["and"]                    = {1, 2, 3},
	["or_i"]                   = {1, 2},
	["or_i_self"]              = {1},
	["or"]                     = {1, 2, 3},
	["or_self"]                = {1, 2},
	["xor_i"]                  = {1, 2},
	["xor"]                    = {1, 2, 3},
	["slt_s"]                  = {1, 2, 3},
	["slt_u"]                  = {1, 2, 3},
	["slt_si"]                 = {1, 2},
	["slt_ui"]                 = {1, 2},
	["mult_s"]                 = {1, 2},
	["mult_u"]                 = {1, 2},
	["div_s"]                  = {1, 2},
	["div_u"]                  = {1, 2},
	-- Shifts: shift_lleft(rd, rt, shamt); the rt operand is the value, rd is dest.
	["shift_lleft"]            = {1, 2},
	["shift_lright"]           = {1, 2},
	["shift_aright"]           = {1, 2},
	["shift_lleft_self"]       = {1},
	-- Loads: load_word(rt, base, off); the rt operand is the destination (it's written, not read) and base + off are non-GPR operands.
	-- The check treats the rt operand as a write, so the read-positions table for `load_*` is empty.
	["load_word"]              = {},
	["load_half_u"]            = {},
	["load_byte_u"]            = {},
	["load_half"]              = {},
	["load_byte"]              = {},
	["load_upper_i"]           = {},
	["load_ui"]                = {},
	-- Stores write to memory; base + rt operands are non-read for load-delay purposes.
	["store_word"]             = {},
	["store_half"]             = {},
	["store_byte"]             = {},
	-- Branches read rs (+ rt for beq/bne). The branch delay slot is out of scope.
	["branch_equal"]           = {1, 2},
	["branch_ne"]              = {1, 2},
	["branch_le_zero"]         = {1},
	["branch_lt_zero"]         = {1},
	["branch_ge_zero"]         = {1},
	["branch_gt_zero"]         = {1},
	-- Jumps / link: jr / jalr read rs only (the target). RD is the destination link.
	["jump_reg"]               = {1},
	["jump_link"]              = {1},
	["call_reg"]               = {1},
	["call_addr"]              = {},
	["jump"]                   = {},
	-- mask_upper is a 2-word macro: shift_lleft then shift_lright. The first reads rt.
	["mask_upper"]             = {1, 2},
	-- move from/to HI/LO.
	["mov_from_high"]          = {},
	["mov_from_low"]           = {},
	["mov_to_high"]            = {1},
	["mov_to_low"]             = {1},
	-- GTE transfers / loads / stores / commands: the relevant table values live in the check itself.
	-- `gte_mv_to_*` writes its rt operand; `gte_mv_from_*` writes its rt operand; `gte_*` commands are atomic-from-the-CPU-POV
	-- once they issue (the CPU holds until the command completes, so load-delay violations don't surface here).
	["gte_mv_from_data_r"]     = {},
	["gte_mv_from_ctrl_r"]     = {},
	["gte_mv_to_data_r"]       = {},
	["gte_mv_to_ctrl_r"]       = {},
	["gte_lw"]                 = {},
	["gte_sw"]                 = {},
	["shift_lleft_var"]        = {1, 2, 3},  -- rd, rt, rs (variable shift amount)
	["shift_aright_var"]       = {1, 2, 3},
}

-- GP0 packet sizes (total words including the 1-word tag) per GP0 cmd byte.
-- Per PSX-SPX `docs/psx-spx/docs/graphicsprocessingunitgpu.md` §"GPU Render Polygon Commands":
--   Each polygon command's word count = 1 (tag/cmd) + per-vertex (vertex + optional color + optional UV).
--   F3:  cmd + 3 vertices = 4 words; +1 tag = 5
--   F4:  cmd + 4 vertices = 5 words; +1 tag = 6
--   G3:  cmd + 3×(color + vertex) = 6 words; +1 tag = 7
--   G4:  cmd + 4×(color + vertex) = 8 words; +1 tag = 9
--   FT3: cmd + tpage + clut + 3×(vertex + UV) = 7 words; +1 tag = 8
--   FT4: cmd + tpage + clut + 4×(vertex + UV) = 9 words; +1 tag = 10
--   GT3: cmd + tpage + clut + 3×(color + vertex + UV) = 9 words; +1 tag = 10
--   GT4: cmd + tpage + clut + 4×(color + vertex + UV) = 12 words; +1 tag = 13
--
-- Cross-checked against code/duffle/gp.h struct sizes + the set_poly_* macros
-- (which encode "len" = "words after tag"):
--   set_poly_f3(p)   -> set_len(p, 4)   ->  5 total GP0 0x20
--   set_poly_ft3(p)  -> set_len(p, 7)   ->  8 total GP0 0x24
--   set_poly_f4(p)   -> set_len(p, 5)   ->  6 total GP0 0x28
--   set_poly_ft4(p)  -> set_len(p, 9)   -> 10 total GP0 0x2C
--   set_poly_g3(p)   -> set_len(p, 6)   ->  7 total GP0 0x30
--   set_poly_gt3(p)  -> set_len(p, 9)   -> 10 total GP0 0x34
--   set_poly_g4(p)   -> set_len(p, 8)   ->  9 total GP0 0x38
--   set_poly_gt4(p)  -> set_len(p, 12)  -> 13 total GP0 0x3C
--- @type table<integer, integer>  -- bag: GP0 cmd byte -> word count
M.GP0_CMD_SIZE = {
	[0x20] =  5,  -- Poly_F3
	[0x24] =  8,  -- Poly_FT3
	[0x28] =  6,  -- Poly_F4
	[0x2C] = 10,  -- Poly_FT4
	[0x30] =  7,  -- Poly_G3
	[0x34] = 10,  -- Poly_GT3
	[0x38] =  9,  -- Poly_G4
	[0x3C] = 13,  -- Poly_GT4
}

-- Shape suffix (after `ac_format_` / `mac_format_` prefix) -> GP0 cmd byte.
-- Lets the static-analysis check derive the cmd byte from a macro name like `mac_format_g4_color` -> `g4` -> 0x38 -> 9 expected words.
--- @type table<string, integer>  -- bag: shape suffix -> GP0 cmd byte
M.GP0_CMD_BY_SHAPE = {
	["f3"]  = 0x20, ["ft3"] = 0x24,
	["f4"]  = 0x28, ["ft4"] = 0x2C,
	["g3"]  = 0x30, ["gt3"] = 0x34,
	["g4"]  = 0x38, ["gt4"] = 0x3C,
}

--- @type integer
M.UNKNOWN_INSTRUCTION_CYCLES = 1

-- Hardware-relation policy table.
--
-- The forward walker in `passes/static_analysis.lua::analyze_hardware_relations` reads every emitted word_event, matches its `encoder` against `row.token`, and:
--   * stages the event as a producer in `atom.paths.forward_state`; or
--   * matches it as a consumer against pending producers and records a hazard on `atom.paths.hazards` when the gap is below `visibility.required`.
--
-- Each row is the contract for one CPU-to-coprocessor transfer semantic (the coprocessor-to-CPU path mirrors the same shape).
-- The `reads` / `writes` sub-tables carry the argument positions the analyzer inspects:
--   * `writes.arg` is the destination operand (the producer's effect); the analyzer stages this register as a pending producer.
--   * `reads` (when present) lists the operand positions the same token reads back from hardware; for MTC2 / CTC2 the producer reads the GPR source it is loading from.
--     The `fanout_to` field (MTC2-IRGB row only) tells the consumer-match logic which downstream COP2 registers are transitively updated by the write.
--
-- Visibility semantics:
--   * `kind = "post_producer_words"` means the consumer observes the producer's effect after `required` independent emitted words that are
--     strictly between the producer and the consumer. The producer's own emitted slot is implicit (it counts as the slot of issue, not toward `required`) 
--     per the PSX-SPX rule: "Store delays are counted in numbers of clock cycles (not in numbers of opcodes).
--     For 3 cycle delay, one must usually insert 3 cached opcodes (or one uncached opcode)."
--   * `required` is the minimum count of intervening emitted words between producer and consumer.
--     `required = 0` permits the consumer on the very next slot; `required < 0` would place the consumer on the same slot as the producer
--     and is reserved for future "self-retires" relations.
--
-- Evidence:
--   * `evidence.confidence` is one of `"exact"`, `"conservative"`, `"unknown"`. The severity comes from `violation_kind`;
--     A hardware measurement that the vendor caveats may still classify as `"conservative"` even when the underlying timing is numerically known.
--   * `evidence.source` is the upstream reference (file + line range) the row is sourced from. New rows must carry this citation.
--
-- Consumers:
--   * passes/static_analysis.lua::analyze_hardware_relations          (forward walker).
--   * passes/static_analysis.lua::transfer_hazards CHECK_RULES reader (renders hazards onto `findings`).
-- This table is consumed by the hardware-relation analyzer and hazard renderer.
--- @type HardwareRelationRow[]
M.HARDWARE_RELATIONS = {
	-- CPU → COP2 data register (MTC2). The ordinary default is 2 cached words between producer and consumer (cpuspecifications.md:407-419).
	{
		id             = "mtc2_gpr_visibility",
		semantic       = "MTC2",
		consumer       = "cop2_input",
		token          = "gte_mv_to_data_r",
		direction      = "gpr_to_cop2_data",
		reads          = { domain = "gpr",       arg = 1 },
		writes         = { domain = "cop2.data", arg = 2 },
		visibility     = { kind = "post_producer_words", required = 2 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind = "error",
	},
	-- CPU → COP2 data register when the destination is C2_IRGB (data 28).
	-- C2_IRGB drives the IR1/IR2/IR3 color-conversion fan-out, which extends the propagation delay to 3 cached words.
	-- `destination_match = "C2_IRGB"` is the row's filter; the analyzer consults this when the producer's destination operand equals "C2_IRGB".
	-- C2_ORGB (data 29) is read-only and is never classified as a writable fan-out destination.
	{
		id              = "mtc2_irgb_visibility",
		semantic        = "MTC2",
		consumer        = "cop2_input",
		token           = "gte_mv_to_data_r",
		direction       = "gpr_to_cop2_data",
		reads           = { domain = "gpr",       arg = 1 },
		writes          = { domain = "cop2.data", arg = 2 },
		destination_match = "C2_IRGB",
		fanout_to       = { "C2_IR1", "C2_IR2", "C2_IR3" },
		visibility      = { kind = "post_producer_words", required = 3 },
		evidence        = {
			confidence = "exact",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind  = "error",
	},
	-- CPU → COP2 control register (CTC2). Ordinary minimum 2;
	-- no IRGB-style fan-out exists for control registers (per spec §3.6: only C2_IRGB has the 3-cycle fan-out on the data side).
	{
		id             = "ctc2_gpr_visibility",
		semantic       = "CTC2",
		consumer       = "cop2_input",
		token          = "gte_mv_to_ctrl_r",
		direction      = "gpr_to_cop2_control",
		reads          = { domain = "gpr",        arg = 1 },
		writes         = { domain = "cop2.ctrl",  arg = 2 },
		visibility     = { kind = "post_producer_words", required = 2 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind = "error",
	},
	-- COP2 data → GPR (MFC2). One cached slot between the transfer and the first GPR consumer;
	-- the GPR is not updated until the instruction AFTER the MFC2 completes (geometrytransformationenginegte.md:29-32).
	{
		id             = "mfc2_gpr_visibility",
		semantic       = "MFC2",
		consumer       = "gpr_read",
		token          = "gte_mv_from_data_r",
		direction      = "cop2_data_to_gpr",
		reads          = { domain = "cop2.data",  arg = 2 },
		writes         = { domain = "gpr",        arg = 1 },
		visibility     = { kind = "post_producer_words", required = 1 },
		evidence       = {
			confidence = "exact",
			source     = "geometrytransformationenginegte.md:29-32",
		},
		violation_kind = "error",
	},
	-- COP2 control → GPR (CFC2). Same delay as MFC2 (cpuspecifications.md treats the two load-from-COP2 paths symmetrically).
	{
		id             = "cfc2_gpr_visibility",
		semantic       = "CFC2",
		consumer       = "gpr_read",
		token          = "gte_mv_from_ctrl_r",
		direction      = "cop2_control_to_gpr",
		reads          = { domain = "cop2.ctrl",  arg = 2 },
		writes         = { domain = "gpr",        arg = 1 },
		visibility     = { kind = "post_producer_words", required = 1 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:382-419",
		},
		violation_kind = "error",
	},
	-- COP0 control → GPR (MFC0).
	-- One cached slot; the analyzer treats `sys_mov_from_cop0(rt, 12)` (the SR/CU2 transfer) as the same shape as the COP2 load-delay path.
	-- The semantic-level SR/CU2 transition models the load delay;
	-- SR.CU2 bounded-value propagation is modeled separately).
	{
		id             = "mfc0_gpr_visibility",
		semantic       = "MFC0",
		consumer       = "gpr_read",
		token          = "sys_mov_from_cop0",
		direction      = "cop0_control_to_gpr",
		reads          = { domain = "cop0.ctrl",  arg = 2 },
		writes         = { domain = "gpr",        arg = 1 },
		visibility     = { kind = "post_producer_words", required = 1 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:171-178",
		},
		violation_kind = "error",
	},
	-- Memory -> COP2 data register (LWC2).
	-- The memory-side timing is not measured by the vendored GTE latch experiment, so this relation has no numeric retirement threshold.
	-- The LWC2 destination has TWO retirement regimes (per PSX-SPX):
	--   * GTE-command consumer (`gte_cmdw_*`): the GTE pipeline LATCHES the LWC2 result, so a `gte_cmdw_*`
	--     in the very next slot uses the latched value. Gap = 0 is allowed. (Per `docs/psx-spx/docs/gtepipelinetimings.md:271-274`.)
	--   * Any other consumer: standard MIPS load delay applies. Gap = 1 required. (Per `docs/psx-spx/docs/cpuspecifications.md:407-419`.)
	-- Two separate relations so the walker can dispatch by consumer type and emit different severities
	-- (the GTE-command path is `info` because the latch is intentional; the non-GTE-consumer path is `error` because the missing nop is a real bug).
	{
		id             = "lwc2_to_gte_command",
		semantic       = "LWC2_to_GTE",
		consumer       = "cop2_input",
		token          = "gte_lw",
		direction      = "memory_to_cop2_data",
		reads          = { domain = "memory",    arg = 2 },
		writes         = { domain = "cop2.data", arg = 1 },
		required       = 0,  -- GTE-command consumer: gap = 0 OK (latched).
		evidence       = {
			confidence = "measured",
			source     = "gtepipelinetimings.md:271-274",
		},
		violation_kind = "info",
		clear_on_consumer = true,
	},
	{
		id             = "lwc2_to_other_consumer",
		semantic       = "LWC2_to_other",
		consumer       = "cop2_input",
		token          = "gte_lw",
		direction      = "memory_to_cop2_data",
		reads          = { domain = "memory",    arg = 2 },
		writes         = { domain = "cop2.data", arg = 1 },
		required       = 1,  -- Non-GTE-consumer: standard MIPS load delay.
		evidence       = {
			confidence = "inferred",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind = "error",
		clear_on_consumer = true,
	},
	-- COP2 data register -> memory (SWC2). A read of C2 state, not a CPU-to-COP2 write.
	-- The policy row stays in for direction/provenance; staging it as a later command-input producer is suppressed.
	{
		id             = "swc2_memory_write",
		semantic       = "SWC2",
		consumer       = "gpr_read",
		token          = "gte_sw",
		direction      = "cop2_data_to_memory",
		reads          = { domain = "cop2.data", arg = 1 },
		writes         = { domain = "memory",    arg = 2 },
		visibility     = { kind = "none", required = 0 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:79",
		},
		violation_kind = "info",
		stage          = false,
	},
	-- MTC0 Status/SR.CU2. The ordinary COP0 store has no general store-delay relation;
	-- this row feeds the dedicated CU2 transition logic in the same forward walk and is therefore not staged in `pending`.
	{
		id             = "mtc0_cu2_visibility",
		semantic       = "MTC0",
		consumer       = "gpr_read",
		token          = "sys_mov_to_cop0",
		direction      = "gpr_to_cop0_status",
		reads          = { domain = "gpr",          arg = 1 },
		writes         = { domain = "cop0.status",  arg = 2 },
		status_register = 12,
		visibility     = { kind = "post_producer_words", required = 2 },
		evidence       = {
			confidence = "conservative",
			source     = "cpuspecifications.md:543,625-628",
		},
		violation_kind = "warning",
		stage          = false,
		cu2_transition = true,
	},
 }

-- Bounded Status/SR.CU2 transition policy.
-- The value lattice and the transition consumer both read this immutable row; no second value pass is permitted.
-- The source says the enable/disable transition takes "2 clock cycles or so", so the boundary is conservative rather than exact.
--- @type Cu2TransitionPolicy
M.CU2_TRANSITION_POLICY = {
	status_register = 12,
	enable_bit      = 0x40000000,
	required        = 2,
	visibility_kind = "post_producer_words",
	evidence        = {
		confidence = "conservative",
		source     = "cpuspecifications.md:543,625-628",
	},
}

return M
