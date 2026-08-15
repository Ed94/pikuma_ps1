"use strict";

const { nearestCall } = require("./lexer");
const { mergeIndexes, scanSource } = require("./source-index");

const TOKEN_TYPES = [
	"tapeAtomKeyword",
	"tapeAtomName",
	"tapeComponentKeyword",
	"tapeComponentName",
	"tapeAnnotation",
	"tapeBindType",
	"tapePhase",
	"tapeLabel",
	"tapeCpuInstruction",
	"tapeControlFlow",
	"tapeGteInstruction",
	"tapeGpuInstruction",
	"tapeComponentInstruction",
	"tapeDelaySlot",
	"tapeGprRegister",
	"tapeCop2Register",
	"tapeDuffleType",
	"tapeAttribute",
	"keyword",
	"macro",
];

const TOKEN_MODIFIERS = ["declaration", "tapeRead", "tapeWrite", "tapeAuto"];
const TOKEN_TYPE_INDEX = new Map(TOKEN_TYPES.map((name, index) => [name, index]));
const TOKEN_MODIFIER_INDEX = new Map(TOKEN_MODIFIERS.map((name, index) => [name, index]));

const ATOM_KEYWORDS = new Set(["MipsAtom_", "MipsAtom_Proc_"]);
const COMPONENT_KEYWORDS = new Set(["MipsAtomComp_", "MipsAtomComp_Proc_"]);
const ANNOTATIONS = new Set([
	"atom_info", "atom_bind", "atom_reads", "atom_writes", "atom_label",
	"atom_offset", "atom_reg", "atom_type", "atom_ctx", "atom_phase",
	"atom_auto_reg", "phase_auto_reg", "atom_dbg_skip",
]);

const DSL_KEYWORDS = new Set([
	"FI_", "I_", "NI_", "Relative_", "Struct_", "Enum_", "Union_", "Array_",
	"Slice_", "TypeR_", "TypeV_", "align_", "internal", "local_persist", "global",
	"RO_", "LP_", "gknown", "expect_", "cexpr_",
	"asm", "asm_words", "asm_rpins", "asm_clobber",
	"O_", "S_", "C_", "T_", "tmpl", "glue", "r_", "v_", "tr_", "tv_",
	"rgcc", "r_use", "r_set", "r_mod", "r_imm", "r_mem",
	"u1_", "u2_", "u4_", "u8_", "s1_", "s2_", "s4_", "s8_",
	"u1_r", "u2_r", "u4_r", "u8_r", "u1_v", "u2_v", "u4_v", "u8_v",
]);

const DELAY_SLOT_KEYWORDS = new Set(["LdSlot_", "BdSlot_", "DmaSlot_", "GteDelay_"]);

const CONTROL_FLOW_PREFIXES = /^(?:branch_|jump_|call_)/;

const ROLE_TO_TYPE = {
	atomName: "tapeAtomName",
	componentName: "tapeComponentName",
	bindType: "tapeBindType",
	duffleType: "tapeDuffleType",
	gprRegister: "tapeGprRegister",
	cop2Register: "tapeCop2Register",
};

function registerType(name, index) {
	const kind = index.registers.get(name);
	if (kind === "gpr" || /^R_[A-Za-z0-9_]+$/.test(name)) return "tapeGprRegister";
	if (kind === "cop2" || /^(?:C2_|gte_cr_)[A-Za-z0-9_]+$/.test(name)) return "tapeCop2Register";
	return null;
}

function instructionType(name, index) {
	const domain = index.macros.get(name);
	if (domain === "control") return "tapeControlFlow";
	if (domain === "cpu") return "tapeCpuInstruction";
	if (domain === "gte") return "tapeGteInstruction";
	if (domain === "gpu") return "tapeGpuInstruction";
	if (domain === "component") {
		if (/^mac_gte_/.test(name)) return "tapeGteInstruction";
		if (/^mac_gp/.test(name)) return "tapeGpuInstruction";
		if (/^mac_/.test(name)) return "tapeComponentInstruction";
		return "macro";
	}
	if (domain === "utility") return "macro";
	if (/^gte_(?!cr_)/.test(name)) return "tapeGteInstruction";
	if (/^gp[01]_/.test(name)) return "tapeGpuInstruction";
	if (/^mac_gte_/.test(name)) return "tapeGteInstruction";
	if (/^mac_gp/.test(name)) return "tapeGpuInstruction";
	if (/^mac_/.test(name)) return "tapeComponentInstruction";
	return null;
}

function modifierMask(modifiers) {
	let mask = 0;
	for (const modifier of modifiers) {
		const index = TOKEN_MODIFIER_INDEX.get(modifier);
		if (index !== undefined) mask |= (1 << index);
	}
	return mask;
}

function isRegUseAccess(tokens, tokenIndex) {
	const prev = tokens[tokenIndex - 1];
	if (!prev || prev.text !== ".") return false;
	const prevPrev = tokens[tokenIndex - 2];
	if (!prevPrev || prevPrev.kind !== "identifier") return false;
	const next = tokens[tokenIndex + 1];
	if (next && next.text === ".") return false;
	if (prevPrev.text === "r") return true;
	const prev3 = tokens[tokenIndex - 3];
	const prev4 = tokens[tokenIndex - 4];
	if (prev3 && prev3.text === "." && prev4 && prev4.kind === "identifier" && prev4.text === "r") return true;
	return false;
}

function classifyDocument(source, filePath, workspaceIndex, shouldCancel = () => false) {
	const scanned = scanSource(source, filePath);
	const index = mergeIndexes(workspaceIndex, scanned.index);
	const spans = [];

	for (let tokenIndex = 0; tokenIndex < scanned.tokens.length; tokenIndex += 1) {
		if (shouldCancel()) break;
		const token = scanned.tokens[tokenIndex];
		if (token.kind !== "identifier") continue;

		let type = null;
		let modifiers = [];
		const declaration = scanned.declarations.get(token.start);
		const context = nearestCall(scanned.contexts, tokenIndex);

		if (declaration) {
			type = ROLE_TO_TYPE[declaration.role] || null;
			modifiers = declaration.modifiers.slice();
		} else if (ATOM_KEYWORDS.has(token.text)) {
			type = "tapeAtomKeyword";
		} else if (COMPONENT_KEYWORDS.has(token.text)) {
			type = "keyword";
		} else if (ANNOTATIONS.has(token.text)) {
			type = "tapeAnnotation";
		} else if (context && context.callee === "atom_bind" && context.argIndex === 0) {
			type = "tapeBindType";
		} else if (context && context.callee === "atom_phase" && context.argIndex === 0) {
			type = "tapePhase";
			modifiers = ["declaration"];
		} else if (context && context.callee === "atom_ctx" && context.argIndex === 0) {
			type = "tapeAtomName";
		} else if (context && context.callee === "atom_label" && context.argIndex === 0) {
			type = "tapeLabel";
			modifiers = ["declaration"];
		} else if (context && context.callee === "atom_offset" && context.argIndex <= 1) {
			type = "tapeLabel";
		} else if (context && context.callee === "atom_reads") {
			type = registerType(token.text, index);
			if (type) modifiers = ["tapeRead"];
		} else if (context && context.callee === "atom_writes") {
			type = registerType(token.text, index);
			if (type) modifiers = ["tapeWrite"];
		} else if (context && context.callee === "atom_auto_reg") {
			if (context.argIndex === 0) type = "tapeAtomName";
			if (context.argIndex === 1) {
				type = "tapeGprRegister";
				modifiers = ["declaration", "tapeAuto"];
			}
		} else if (context && context.callee === "phase_auto_reg") {
			if (context.argIndex === 0) type = "tapePhase";
			if (context.argIndex === 1) {
				type = "tapeGprRegister";
				modifiers = ["declaration", "tapeAuto"];
			}
		}

		if (!type && index.bindTypes.has(token.text)) type = "tapeBindType";
		if (!type && DSL_KEYWORDS.has(token.text)) type = "keyword";
		if (!type && index.types.has(token.text)) type = "tapeDuffleType";
		if (!type && index.attributes.has(token.text)) type = "tapeAttribute";
		if (!type) type = registerType(token.text, index);
		if (!type && DELAY_SLOT_KEYWORDS.has(token.text)) type = "tapeDelaySlot";
		if (!type) {
			const domain = index.macros.get(token.text);
			if (domain === "control" || (domain && CONTROL_FLOW_PREFIXES.test(token.text))) {
				type = "tapeControlFlow";
			}
		}
		if (!type && isRegUseAccess(scanned.tokens, tokenIndex)) type = "tapeGprRegister";
		if (!type) type = instructionType(token.text, index);
		if (!type && /^(?:Slice_|A[0-9]+_)/.test(token.text)) type = "tapeDuffleType";
		if (!type && /_[RV]$/.test(token.text)) type = "tapeDuffleType";
		if (!type && index.atoms.has(token.text)) type = "tapeAtomName";
		if (!type && index.components.has(token.text)) type = "tapeComponentName";
		if (!type && index.phases.has(token.text)) type = "tapePhase";
		if (!type && index.labels.has(token.text)) type = "tapeLabel";
		if (!type) continue;

		spans.push({
			text: token.text,
			type,
			typeIndex: TOKEN_TYPE_INDEX.get(type),
			modifiers,
			modifierMask: modifierMask(modifiers),
			start: token.start,
			length: token.end - token.start,
			line: token.line,
			character: token.character,
		});
	}

	spans.sort((left, right) => left.start - right.start || left.length - right.length);
	const nonOverlapping = [];
	for (const span of spans) {
		const previous = nonOverlapping[nonOverlapping.length - 1];
		if (!previous || previous.start + previous.length <= span.start) nonOverlapping.push(span);
	}

	return { spans: nonOverlapping, errors: scanned.errors };
}

module.exports = {
	TOKEN_MODIFIERS,
	TOKEN_TYPES,
	classifyDocument,
	modifierMask,
};
