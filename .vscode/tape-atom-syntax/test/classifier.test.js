"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const { classifyDocument } = require("../classifier");
const { createIndex } = require("../source-index");

function byText(result, text) {
	return result.spans.filter((span) => span.text === text);
}

test("classifyDocument distinguishes declaration, annotation, phase, bind, and label roles", () => {
	const source = [
		"typedef Struct_(Binds_CubeTri) { U4 PrimCursor; };",
		"MipsAtom_(cube_g4_face) atom_info(atom_bind(Binds_CubeTri), atom_phase(cube_g4),",
		"\tatom_reads(R_PrimCursor), atom_writes(R_FaceCursor)) {",
		"\tbranch_le_zero(R_T0, atom_offset(cull, exit)),",
		"\tatom_label(exit)",
		"};",
	].join("\n");

	const result = classifyDocument(source, "C:/x/code/hello_camera/hello_camera.atom.c", createIndex());

	assert.equal(byText(result, "MipsAtom_")[0].type, "tapeAtomKeyword");
	assert.deepEqual(byText(result, "cube_g4_face")[0].modifiers, ["declaration"]);
	assert.equal(byText(result, "atom_bind")[0].type, "tapeAnnotation");
	assert.equal(byText(result, "Binds_CubeTri").at(-1).type, "tapeBindType");
	assert.equal(byText(result, "cube_g4")[0].type, "tapePhase");
	assert.deepEqual(byText(result, "cube_g4")[0].modifiers, ["declaration"]);
	assert.equal(byText(result, "cull")[0].type, "tapeLabel");
	assert.equal(byText(result, "exit").every((span) => span.type === "tapeLabel"), true);
});

test("classifyDocument applies read and write modifiers to GPRs", () => {
	const source = "atom_info(atom_reads(R_PrimCursor), atom_writes(R_FaceCursor))";
	const result = classifyDocument(source, "C:/x/code/test.atom.c", createIndex());

	assert.deepEqual(byText(result, "R_PrimCursor")[0].modifiers, ["tapeRead"]);
	assert.deepEqual(byText(result, "R_FaceCursor")[0].modifiers, ["tapeWrite"]);
});

test("classifyDocument separates CPU, GTE, GPU, and component domains", () => {
	const workspace = createIndex();
	workspace.macros.set("load_word", "cpu");
	workspace.macros.set("gte_cmdw_rtpt", "gte");
	workspace.macros.set("gp1_word_DisplayOn", "gpu");
	workspace.macros.set("mac_yield", "control");
	workspace.componentAliases.add("mac_yield");

	const source = "load_word(R_T0, R_T1, 0), gte_cmdw_rtpt, gp1_word_DisplayOn(), mac_yield(), C2_MAC0, gte_cr_OFX_Code";
	const result = classifyDocument(source, "C:/x/code/test.c", workspace);

	assert.equal(byText(result, "load_word")[0].type, "tapeCpuInstruction");
	assert.equal(byText(result, "gte_cmdw_rtpt")[0].type, "tapeGteInstruction");
	assert.equal(byText(result, "gp1_word_DisplayOn")[0].type, "tapeGpuInstruction");
	assert.equal(byText(result, "mac_yield")[0].type, "tapeControlFlow");
	assert.equal(byText(result, "C2_MAC0")[0].type, "tapeCop2Register");
	assert.equal(byText(result, "gte_cr_OFX_Code")[0].type, "tapeCop2Register");
});

test("component invocations keep the domain resolved from their emitted instructions", () => {
	const workspace = createIndex();
	workspace.macros.set("mac_load_word_imm", "cpu");
	workspace.macros.set("mac_gcmd_push", "gpu");
	workspace.macros.set("mac_gte_store_f3", "gte");
	workspace.macros.set("mac_load_v3s4", "cpu");

	const source = "mac_load_word_imm(dst, imm), mac_gcmd_push(cmd), mac_gte_store_f3(cursor), mac_load_v3s4()";
	const result = classifyDocument(source, "C:/x/code/hello_camera/hello_camera.atom.c", workspace);

	assert.equal(byText(result, "mac_load_word_imm")[0].type, "tapeCpuInstruction");
	assert.equal(byText(result, "mac_gcmd_push")[0].type, "tapeGpuInstruction");
	assert.equal(byText(result, "mac_gte_store_f3")[0].type, "tapeGteInstruction");
	assert.equal(byText(result, "mac_load_v3s4")[0].type, "tapeCpuInstruction");
});

test("utility macros without a hardware domain use the standard macro token", () => {
	const workspace = createIndex();
	workspace.macros.set("load_word", "cpu");
	workspace.macros.set("assert", "utility");
	workspace.macros.set("stringify", "utility");
	workspace.macros.set("u4_hi", "utility");

	const source = "load_word(R_T0, R_T1, 0), assert(ok), stringify(name), u4_hi(imm)";
	const result = classifyDocument(source, "C:/x/code/hello_camera/hello_camera.c", workspace);

	assert.equal(byText(result, "load_word")[0].type, "tapeCpuInstruction");
	assert.equal(byText(result, "assert")[0].type, "macro");
	assert.equal(byText(result, "stringify")[0].type, "macro");
	assert.equal(byText(result, "u4_hi")[0].type, "macro");
});

test("document-local declarations override an empty workspace index", () => {
	const source = [
		"MipsAtomComp_(ac_new_component) { nop };",
		"MipsAtomComp_Proc_(ab, { nop })",
		"mac_new_component(),",
	].join("\n");
	const result = classifyDocument(source, "C:/x/code/duffle/math.atom.c", createIndex());

	assert.equal(byText(result, "MipsAtomComp_")[0].type, "keyword");
	assert.equal(byText(result, "MipsAtomComp_Proc_")[0].type, "keyword");
	assert.equal(byText(result, "ac_new_component")[0].type, "tapeComponentName");
	assert.equal(byText(result, "mac_new_component")[0].type, "tapeComponentInstruction");
});

test("delay slot markers share the tapeDelaySlot token", () => {
	const source = "LdSlot_ nop, BdSlot_ nop, DmaSlot_ nop2, GteDelay_ nop";
	const result = classifyDocument(source, "C:/x/code/duffle/gte.atom.c", createIndex());

	assert.equal(byText(result, "LdSlot_")[0].type, "tapeDelaySlot");
	assert.equal(byText(result, "BdSlot_")[0].type, "tapeDelaySlot");
	assert.equal(byText(result, "DmaSlot_")[0].type, "tapeDelaySlot");
	assert.equal(byText(result, "GteDelay_")[0].type, "tapeDelaySlot");
});

test("classifier returns ordered non-overlapping spans and partial malformed output", () => {
	const source = "atom_reads(R_A /* broken";
	const result = classifyDocument(source, "C:/x/code/test.atom.c", createIndex());

	assert.equal(result.errors.some((error) => error.kind === "unterminated-block-comment"), true);
	for (let spanIndex = 1; spanIndex < result.spans.length; spanIndex += 1) {
		const previous = result.spans[spanIndex - 1];
		const current = result.spans[spanIndex];
		assert.equal(previous.start + previous.length <= current.start, true);
	}
});
