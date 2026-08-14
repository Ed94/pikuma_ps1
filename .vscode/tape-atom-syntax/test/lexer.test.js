"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const { buildCallContexts, lex, nearestCall } = require("../lexer");

test("lex skips comments, strings, and character literals", () => {
	const source = [
		"MipsAtom_(visible)",
		"// MipsAtom_(line_comment)",
		"const char *s = \"atom_reads(R_Hidden)\";",
		"char c = '\\''; /* gte_cmdw_hidden */",
		"atom_reads(R_Visible)",
	].join("\n");

	const result = lex(source);
	const identifiers = result.tokens
		.filter((token) => token.kind === "identifier")
		.map((token) => token.text);

	assert.deepEqual(result.errors, []);
	assert.equal(identifiers.includes("visible"), true);
	assert.equal(identifiers.includes("R_Visible"), true);
	assert.equal(identifiers.includes("line_comment"), false);
	assert.equal(identifiers.includes("R_Hidden"), false);
	assert.equal(identifiers.includes("gte_cmdw_hidden"), false);
});

test("lex reports unterminated block comments without returning comment tokens", () => {
	const result = lex("R_Visible /* atom_reads(R_Hidden)");

	assert.equal(result.tokens.some((token) => token.text === "R_Visible"), true);
	assert.equal(result.tokens.some((token) => token.text === "R_Hidden"), false);
	assert.deepEqual(result.errors.map((error) => error.kind), ["unterminated-block-comment"]);
});

test("line comments stop at CRLF boundaries", () => {
	const result = lex("// atom_reads(R_Hidden)\r\natom_reads(R_Visible)\r\n");
	const identifiers = result.tokens
		.filter((token) => token.kind === "identifier")
		.map((token) => token.text);

	assert.equal(identifiers.includes("R_Hidden"), false);
	assert.equal(identifiers.includes("R_Visible"), true);
});

test("balanced contexts retain multiline nesting and argument indexes", () => {
	const source = [
		"atom_info(",
		"\tatom_phase(cube_g4),",
		"\tatom_reads(R_A, nested(R_B, R_C)),",
		"\tatom_writes(R_D)",
		")",
	].join("\n");
	const lexical = lex(source);
	const balanced = buildCallContexts(lexical.tokens);

	const byText = new Map();
	lexical.tokens.forEach((token, index) => {
		if (token.kind === "identifier") byText.set(token.text, index);
	});

	assert.equal(nearestCall(balanced.contexts, byText.get("cube_g4")).callee, "atom_phase");
	assert.equal(nearestCall(balanced.contexts, byText.get("R_A")).callee, "atom_reads");
	assert.equal(nearestCall(balanced.contexts, byText.get("R_A")).argIndex, 0);
	assert.equal(nearestCall(balanced.contexts, byText.get("R_C")).callee, "nested");
	assert.equal(nearestCall(balanced.contexts, byText.get("R_D")).callee, "atom_writes");
	assert.deepEqual(balanced.errors, []);
});

test("balanced contexts report unmatched parentheses", () => {
	const lexical = lex("atom_reads(R_A");
	const balanced = buildCallContexts(lexical.tokens);

	assert.deepEqual(balanced.errors.map((error) => error.kind), ["unmatched-open-paren"]);
});
