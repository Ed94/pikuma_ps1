"use strict";

const path = require("node:path");
const { buildCallContexts, lex, nearestCall } = require("./lexer");

const BASE_TYPES = [
	"B1", "B2", "B4", "B8", "F4", "F8", "S1", "S2", "S4", "S8",
	"U1", "U2", "U4", "U8", "MipsAtom", "MipsCode", "Reg",
];

const C_BUILTINS = new Set([
	"void", "type", "char", "short", "int", "long", "float", "double",
	"unsigned", "signed", "bool", "size_t", "uint8_t", "uint16_t", "uint32_t",
	"int8_t", "int16_t", "int32_t",
]);

const BASE_ATTRIBUTES = [
	"FI_", "I_", "NI_", "Relative_", "Struct_", "Enum_", "Union_", "Array_",
	"Slice_", "TypeR_", "TypeV_", "align_", "internal", "local_persist", "global",
	"RO_", "LP_", "gknown", "expect_", "cexpr_",
	"asm", "asm_words", "asm_rpins", "asm_clobber",
	"O_", "S_", "C_", "T_", "tmpl", "glue", "r_", "v_", "tr_", "tv_",
	"rgcc", "r_use", "r_set", "r_mod", "r_imm", "r_mem",
	"u1_", "u2_", "u4_", "u8_", "s1_", "s2_", "s4_", "s8_",
	"u1_r", "u2_r", "u4_r", "u8_r", "u1_v", "u2_v", "u4_v", "u8_v",
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
		componentCallees: new Map(),
	};
}

function cloneIndex(source) {
	const result = createIndex();
	for (const key of ["atoms", "components", "componentAliases", "bindTypes", "types", "phases", "labels", "attributes"]) {
		for (const value of source[key]) result[key].add(value);
	}
	for (const [name, domain] of source.macros) result.macros.set(name, domain);
	for (const [name, domain] of source.registers) result.registers.set(name, domain);
	for (const [name, callees] of source.componentCallees) result.componentCallees.set(name, callees.slice());
	return result;
}

function mergeIndexes(...sources) {
	const result = createIndex();
	for (const source of sources) {
		if (!source) continue;
		for (const key of ["atoms", "components", "componentAliases", "bindTypes", "types", "phases", "labels", "attributes"]) {
			for (const value of source[key]) result[key].add(value);
		}
		for (const [name, domain] of source.macros) {
			const existing = result.macros.get(name);
			if (!existing || domainRank(domain) >= domainRank(existing)) result.macros.set(name, domain);
		}
		for (const [name, domain] of source.registers) result.registers.set(name, domain);
		for (const [name, callees] of source.componentCallees) {
			const existing = result.componentCallees.get(name) || [];
			result.componentCallees.set(name, existing.concat(callees));
		}
	}
	return resolveComponentDomains(result);
}

function domainFromPath(filePath) {
	const base = path.basename(filePath.replaceAll("\\", "/")).toLowerCase();
	if (base === "mips.h") return "cpu";
	if (base === "gte.h") return "gte";
	if (base === "gp.h") return "gpu";
	return null;
}

function prefixDomain(name) {
	if (/^(?:branch_|jump_|call_)/.test(name)) return "control";
	if (/^gte_(?!cr_)/.test(name) || name.startsWith("mac_gte_") || name.startsWith("ac_gte_")) return "gte";
	if (/^gp[01]_/.test(name) || name.startsWith("mac_gp_") || name.startsWith("ac_gp_")) return "gpu";
	return null;
}

function collectBraceIdentifiers(tokens, openBraceIndex) {
	const names = [];
	let depth = 0;
	for (let tokenIndex = openBraceIndex; tokenIndex < tokens.length; tokenIndex += 1) {
		if (tokens[tokenIndex].text === "{") depth += 1;
		if (tokens[tokenIndex].text === "}") {
			depth -= 1;
			if (depth === 0) break;
		}
		if (tokens[tokenIndex].kind === "identifier") names.push(tokens[tokenIndex].text);
	}
	return names;
}

function resolveComponentDomains(index) {
	const hardwareRank = { cpu: 1, gpu: 2, gte: 3, control: 4 };
	let changed = true;
	while (changed) {
		changed = false;
		for (const [alias, callees] of index.componentCallees) {
			let best = index.macros.get(alias) || "component";
			let bestRank = hardwareRank[best] || 0;
			for (const callee of callees) {
				const domain = prefixDomain(callee) || index.macros.get(callee);
				const rank = hardwareRank[domain] || 0;
				if (rank > bestRank) {
					best = domain;
					bestRank = rank;
				}
			}
			if (bestRank > 0 && index.macros.get(alias) !== best) {
				index.macros.set(alias, best);
				changed = true;
			}
		}
	}
	return index;
}

function domainRank(domain) {
	if (domain === "control") return 4;
	if (domain === "cpu" || domain === "gte" || domain === "gpu") return 3;
	if (domain === "component") return 2;
	return 1;
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

	function addComponent(token) {
		index.components.add(token.text);
		mark(token, "componentName");
		const alias = componentAlias(token.text);
		if (alias) {
			index.componentAliases.add(alias);
			index.macros.set(alias, prefixDomain(alias) || prefixDomain(token.text) || "component");
		}
	}

	function bindComponentCallees(alias, callees) {
		if (!alias) return;
		index.componentAliases.add(alias);
		index.componentCallees.set(alias, callees);
		if (!index.macros.has(alias)) index.macros.set(alias, "component");
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
				} else if (/^(?:ac_|mac_)/.test(name.text)) {
					const alias = name.text.startsWith("ac_") ? componentAlias(name.text) : name.text;
					const rest = [];
					for (let restIndex = tokenIndex + 2; restIndex < tokens.length && tokens[restIndex].line === name.line; restIndex += 1) {
						if (tokens[restIndex].kind === "identifier") rest.push(tokens[restIndex].text);
					}
					if (alias) {
						index.componentAliases.add(alias);
						index.macros.set(alias, prefixDomain(alias) || "component");
						if (rest.length) index.componentCallees.set(alias, rest);
					}
				} else {
					index.macros.set(name.text, domain || "utility");
				}
			}
		}

		if (token.text === "typedef") {
			let endIndex = tokenIndex + 1;
			let hasBrace = false;
			let lastIdentifier = null;
			while (endIndex < tokens.length && tokens[endIndex].text !== ";") {
				if (tokens[endIndex].text === "{") hasBrace = true;
				if (tokens[endIndex].kind === "identifier" && !C_BUILTINS.has(tokens[endIndex].text)) lastIdentifier = tokens[endIndex];
				endIndex += 1;
			}
			if (!hasBrace && lastIdentifier && !C_BUILTINS.has(lastIdentifier.text)) {
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
		if (call.callee === "MipsAtomComp_") {
			const name = tokens[call.openTokenIndex + 1];
			const brace = tokens[call.closeTokenIndex + 1];
			if (name && name.kind === "identifier" && brace && brace.text === "{") {
				bindComponentCallees(componentAlias(name.text), collectBraceIdentifiers(tokens, call.closeTokenIndex + 1));
			}
		}
		if (call.callee === "MipsAtomComp_Proc_") {
			const functionName = findFunctionNameBefore(tokens, call.calleeTokenIndex);
			let braceIndex = -1;
			for (let tokenIndex = call.openTokenIndex + 1; tokenIndex < call.closeTokenIndex; tokenIndex += 1) {
				if (tokens[tokenIndex].text === "{") {
					braceIndex = tokenIndex;
					break;
				}
			}
			if (functionName && braceIndex >= 0) {
				bindComponentCallees(componentAlias(functionName.text), collectBraceIdentifiers(tokens, braceIndex));
			}
		}
		if (!domain) continue;
		const name = tokens[call.calleeTokenIndex];
		const after = tokens[call.closeTokenIndex + 1];
		if (!name || !after || after.text !== "{") continue;
		if (/^(?:gp0_|gp1_|gte_|mac_)/.test(name.text)) index.macros.set(name.text, domain);
	}

	return {
		index: resolveComponentDomains(cloneIndex(index)),
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
	resolveComponentDomains,
	scanSource,
};
