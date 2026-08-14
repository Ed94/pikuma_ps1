"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
	createIndex,
	domainFromPath,
	mergeIndexes,
	scanSource,
} = require("../source-index");

test("scanSource discovers current atom and component forms", () => {
	const source = [
		"MipsAtom_(cube_g4_face) atom_info(atom_phase(cube_g4), atom_reads(R_PrimCursor)) { mac_yield() };",
		"MipsAtomComp_(ac_load_pair) { load_word(R_T0, R_T1, 0) };",
		"internal MipsAtom* normalize_proc(AtomArena_R aa) MipsAtom_Proc_(aa, { mac_yield() })",
		"FI_ void ac_store_pair(MipsAtomBuilder_R ab) atom_dbg_skip MipsAtomComp_Proc_(ab, { store_word(R_T0, R_T1, 0) })",
	].join("\n");

	const result = scanSource(source, "C:/projects/Pikuma/ps1/code/duffle/mips.atom.c");

	assert.equal(result.index.atoms.has("cube_g4_face"), true);
	assert.equal(result.index.atoms.has("normalize"), true);
	assert.equal(result.index.components.has("ac_load_pair"), true);
	assert.equal(result.index.components.has("ac_store_pair"), true);
	assert.equal(result.index.componentAliases.has("mac_load_pair"), true);
	assert.equal(result.index.componentAliases.has("mac_store_pair"), true);
	assert.equal(result.index.macros.get("mac_store_pair"), "cpu");
	assert.equal(result.index.phases.has("cube_g4"), true);
	assert.equal(result.index.registers.get("R_PrimCursor"), "gpr");
	assert.deepEqual(result.errors, []);
});

test("scanSource discovers binds, labels, registers, typedefs, and macro domains", () => {
	const source = [
		"typedef Struct_(Binds_CubeTri) { U4 PrimCursor; };",
		"typedef Enum_(U4, PadStatus) { PadStatus_Ok };",
		"typedef U4 const MipsCode;",
		"enum { R_PrimCursor = R_T7 atom_reg, C2_Custom = 12, gte_cr_Custom = 13 };",
		"#define load_word(rt, base, off) enc_i(rt, base, off)",
		"atom_bind(Binds_CubeTri)",
		"atom_label(exit)",
		"atom_offset(entry, exit)",
	].join("\n");

	const result = scanSource(source, "C:/projects/Pikuma/ps1/code/duffle/mips.h");

	assert.equal(result.index.bindTypes.has("Binds_CubeTri"), true);
	assert.equal(result.index.types.has("PadStatus"), true);
	assert.equal(result.index.types.has("MipsCode"), true);
	assert.equal(result.index.registers.get("R_PrimCursor"), "gpr");
	assert.equal(result.index.registers.get("C2_Custom"), "cop2");
	assert.equal(result.index.registers.get("gte_cr_Custom"), "cop2");
	assert.equal(result.index.macros.get("load_word"), "cpu");
	assert.equal(result.index.labels.has("entry"), true);
	assert.equal(result.index.labels.has("exit"), true);
});

test("domainFromPath uses the declaration file rather than parent directory names", () => {
	assert.equal(domainFromPath("C:/x/code/hello_gte/hello_gte.atom.c"), "component");
	assert.equal(domainFromPath("C:/x/code/duffle/mips.h"), "cpu");
	assert.equal(domainFromPath("C:/x/code/duffle/gte.atom.c"), "gte");
	assert.equal(domainFromPath("C:/x/code/duffle/gp.h"), "gpu");
});

test("mergeIndexes preserves domain-specific aliases", () => {
	const left = createIndex();
	left.macros.set("load_word", "cpu");
	const right = createIndex();
	right.componentAliases.add("mac_gte_store");
	right.macros.set("mac_gte_store", "gte");

	const merged = mergeIndexes(left, right);
	assert.equal(merged.macros.get("load_word"), "cpu");
	assert.equal(merged.macros.get("mac_gte_store"), "gte");
});
