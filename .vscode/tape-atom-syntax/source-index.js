"use strict";

const path = require("node:path");
const { buildCallContexts, lex, nearestCall } = require("./lexer");

const BASE_TYPES = [
	"B1", "B2", "B4", "B8", "F4", "F8", "S1", "S2", "S4", "S8",
	"U1", "U2", "U4", "U8", "MipsAtom", "MipsCode", "Reg",
];

const BASE_ATTRIBUTES = [
	"FI_", "I_", "NI_", "Relative_", "Struct_", "Enum_", "Union_",
	"TypeR_", "TypeV_", "align_", "internal", "local_persist", "global",
	"O_", "S_", "C_", "T_", "tmpl", "glue", "r_", "v_", "tr_", "tv_",
	"rgcc", "rlit", "r_use", "r_set", "r_mod", "r_imm", "r_mem",
	"enc_op", "enc_rs", "enc_rt", "enc_rd", "enc_imm", "enc_i", "enc_r",
];

function createIndex() {
	return {
		atoms: new Set(),
		components: new Set(),
		componentAliases: new Set(),
		macros: new Map(),
		registers: new Map(),
		bindTypes: new Set(),
		types: new Set(BASE_TYPES),
		phases: new Set(),
		labels: new Set(),
		attributes: new Set(BASE_ATTRIBUTES),
	};
}

function cloneIndex(source) {
	const result = createIndex();
	for (const key of ["atoms", "components", "componentAliases", "bindTypes", "types", "phases", "labels", "attributes"]) {
		for (const value of source[key]) result[key].add(value);
	}
	for (const [name, domain] of source.macros) result.macros.set(name, domain);
	for (const [name, domain] of source.registers) result.registers.set(name, domain);
	return result;
}

function mergeIndexes(...sources) {
	const result = createIndex();
	for (const source of sources) {
		if (!source) continue;
		for (const key of ["atoms", "components", "componentAliases", "bindTypes", "types", "phases", "labels", "attributes"]) {
			for (const value of source[key]) result[key].add(value);
		}
		for (const [name, domain] of source.macros) result.macros.set(name, domain);
		for (const [name, domain] of source.registers) result.registers.set(name, domain);
	}
	return result;
}

function domainFromPath(filePath) {
	const base = path.basename(filePath.replaceAll("\\", "/")).toLowerCase();
	if (base === "mips.h" || base === "mips.atom.c") return "cpu";
	if (base === "gte.h" || base === "gte.atom.c") return "gte";
	if (base === "gp.h" || base === "gp.atom.c") return "gpu";
	return "component";
}

function registerKind(name) {
	if (/^R_[A-Za-z0-9_]+$/.test(name)) return "gpr";
	if (/^(?:C2_|gte_cr_)[A-Za-z0-9_]+$/.test(name)) return "cop2";
	return null;
}

function componentAlias(name) {
	return name.startsWith("ac_") ? `mac_${name.slice(3)}` : null;
}

function findFunctionNameBefore(tokens, calleeTokenIndex) {
	let closeIndex = calleeTokenIndex - 1;
	while (closeIndex >= 0 && tokens[closeIndex].kind === "identifier" && tokens[closeIndex].text === "atom_dbg_skip") {
		closeIndex -= 1;
	}
	if (!tokens[closeIndex] || tokens[closeIndex].text !== ")") return null;

	let depth = 1;
	for (let tokenIndex = closeIndex - 1; tokenIndex >= 0; tokenIndex -= 1) {
		if (tokens[tokenIndex].text === ")") depth += 1;
		if (tokens[tokenIndex].text === "(") depth -= 1;
		if (depth !== 0) continue;
		const name = tokens[tokenIndex - 1];
		return name && name.kind === "identifier" ? name : null;
	}
	return null;
}

function scanSource(source, filePath) {
	const lexical = lex(source);
	const balanced = buildCallContexts(lexical.tokens);
	const tokens = lexical.tokens;
	const contexts = balanced.contexts;
	const index = createIndex();
	const declarations = new Map();
	const domain = domainFromPath(filePath);

	function mark(token, role, modifiers = ["declaration"]) {
		declarations.set(token.start, { role, modifiers });
	}

	function componentDomain(name) {
		if (name.startsWith("ac_gte_") || name.startsWith("mac_gte_")) return "gte";
		if (name.startsWith("ac_gp_") || name.startsWith("mac_gp_")) return "gpu";
		return "cpu";
	}

	function addComponent(token) {
		index.components.add(token.text);
		mark(token, "componentName");
		const alias = componentAlias(token.text);
		if (alias) {
			index.componentAliases.add(alias);
			index.macros.set(alias, componentDomain(token.text));
		}
	}

	for (let tokenIndex = 0; tokenIndex < tokens.length; tokenIndex += 1) {
		const token = tokens[tokenIndex];
		if (token.kind !== "identifier") continue;

		const kind = registerKind(token.text);
		if (kind) {
			index.registers.set(token.text, kind);
			if (tokens[tokenIndex + 1] && tokens[tokenIndex + 1].text === "=") {
				mark(token, kind === "gpr" ? "gprRegister" : "cop2Register");
			}
		}

		const context = nearestCall(contexts, tokenIndex);
		if (context && context.argIndex === 0) {
			if (context.callee === "MipsAtom_") {
				index.atoms.add(token.text);
				mark(token, "atomName");
			}
			if (context.callee === "MipsAtomComp_") addComponent(token);
			if (context.callee === "atom_bind") index.bindTypes.add(token.text);
			if (context.callee === "atom_phase" || context.callee === "phase_auto_reg") index.phases.add(token.text);
			if (context.callee === "atom_label" || context.callee === "atom_offset") index.labels.add(token.text);
		}

		const isWrappedType = context && (
			((context.callee === "Struct_" || context.callee === "Union_") && context.argIndex === 0) ||
			(context.callee === "Enum_" && context.argIndex === 1)
		);
		if (isWrappedType) {
			index.types.add(token.text);
			mark(token, token.text.startsWith("Binds_") ? "bindType" : "duffleType");
			if (token.text.startsWith("Binds_")) index.bindTypes.add(token.text);
		}

		if (context && context.callee === "atom_offset" && context.argIndex === 1) index.labels.add(token.text);

		if (context && context.callee === "atom_auto_reg") {
			if (context.argIndex === 0) index.atoms.add(token.text);
			if (context.argIndex === 1) {
				index.registers.set(token.text, "gpr");
				mark(token, "gprRegister", ["declaration", "tapeAuto"]);
			}
		}

		if (context && context.callee === "phase_auto_reg" && context.argIndex === 1) {
			index.registers.set(token.text, "gpr");
			mark(token, "gprRegister", ["declaration", "tapeAuto"]);
		}

		if (token.text === "define" && tokens[tokenIndex - 1] && tokens[tokenIndex - 1].text === "#") {
			const name = tokens[tokenIndex + 1];
			if (name && name.kind === "identifier" && name.line === token.line) {
				if (/^(?:RegUse_|Struct_|Enum_|Union_|TypeR_|TypeV_|Relative_|Binds_)/.test(name.text)) {
					index.types.add(name.text);
				} else {
					index.macros.set(name.text, domain);
				}
			}
		}

		if (token.text === "typedef") {
			let endIndex = tokenIndex + 1;
			let hasBrace = false;
			let lastIdentifier = null;
			while (endIndex < tokens.length && tokens[endIndex].text !== ";") {
				if (tokens[endIndex].text === "{") hasBrace = true;
				if (tokens[endIndex].kind === "identifier") lastIdentifier = tokens[endIndex];
				endIndex += 1;
			}
			if (!hasBrace && lastIdentifier) {
				index.types.add(lastIdentifier.text);
				mark(lastIdentifier, "duffleType");
			}
		}

		if (token.text === "MipsAtom_Proc_") {
			const functionName = findFunctionNameBefore(tokens, tokenIndex);
			if (functionName) {
				const atomName = functionName.text.endsWith("_proc")
					? functionName.text.slice(0, -5)
					: functionName.text;
				index.atoms.add(atomName);
				index.atoms.add(functionName.text);
				mark(functionName, "atomName");
			}
		}

		if (token.text === "MipsAtomComp_Proc_") {
			const functionName = findFunctionNameBefore(tokens, tokenIndex);
			if (functionName) addComponent(functionName);
		}
	}

	for (const call of balanced.calls) {
		if (domain === "component") continue;
		const name = tokens[call.calleeTokenIndex];
		const after = tokens[call.closeTokenIndex + 1];
		if (!name || !after || after.text !== "{") continue;
		if (/^(?:gp0_|gp1_|gte_|mac_)/.test(name.text)) index.macros.set(name.text, domain);
	}

	return {
		index: cloneIndex(index),
		declarations,
		tokens,
		contexts,
		errors: [...lexical.errors, ...balanced.errors],
	};
}

module.exports = {
	createIndex,
	domainFromPath,
	mergeIndexes,
	scanSource,
};
