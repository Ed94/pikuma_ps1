"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const { TOKEN_MODIFIERS, TOKEN_TYPES } = require("../classifier");

const ROOT = path.resolve(__dirname, "..");

function readJson(filePath) {
	return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function collectScopeNames(value, output = new Set()) {
	if (Array.isArray(value)) {
		for (const entry of value) collectScopeNames(entry, output);
		return output;
	}
	if (!value || typeof value !== "object") return output;
	if (typeof value.name === "string") output.add(value.name);
	for (const child of Object.values(value)) collectScopeNames(child, output);
	return output;
}

test("package semantic legend matches classifier exports", () => {
	const packageJson = readJson(path.join(ROOT, "package.json"));
	const contributedTypes = packageJson.contributes.semanticTokenTypes.map((entry) => entry.id);
	const contributedModifiers = packageJson.contributes.semanticTokenModifiers.map((entry) => entry.id);

	assert.equal(packageJson.version, "0.2.0");
	assert.deepEqual(contributedTypes, TOKEN_TYPES);
	assert.deepEqual(contributedModifiers, TOKEN_MODIFIERS.filter((name) => name !== "declaration"));
});

test("package includes runtime files only and acknowledges local-only metadata", () => {
	const packageJson = readJson(path.join(ROOT, "package.json"));

	assert.deepEqual(packageJson.files, [
		"classifier.js",
		"extension.js",
		"lexer.js",
		"source-index.js",
		"syntaxes/tape_atom.tmLanguage.json",
	]);
	assert.equal(packageJson.scripts.package.includes("--allow-missing-repository"), true);
	assert.equal(packageJson.scripts.package.includes("--skip-license"), true);
});

test("every semantic token has a TextMate fallback scope and grammar scope", () => {
	const packageJson = readJson(path.join(ROOT, "package.json"));
	const grammar = readJson(path.join(ROOT, "syntaxes", "tape_atom.tmLanguage.json"));
	const mappings = packageJson.contributes.semanticTokenScopes[0].scopes;
	const grammarScopes = collectScopeNames(grammar);

	for (const tokenType of TOKEN_TYPES) {
		assert.equal(Array.isArray(mappings[tokenType]), true, `missing scope mapping: ${tokenType}`);
		assert.equal(mappings[tokenType].some((scope) => grammarScopes.has(scope)), true, `grammar does not emit: ${tokenType}`);
	}
});

test("TextMate offset labels stay scoped to atom_offset calls", () => {
	const grammar = readJson(path.join(ROOT, "syntaxes", "tape_atom.tmLanguage.json"));
	const serialized = JSON.stringify(grammar);
	const offsetRule = grammar.repository["annotation-arguments"].patterns
		.find((rule) => rule.match.includes("atom_offset"));

	assert.equal(serialized.includes("(?<=,)"), false);
	assert.equal(offsetRule.captures[1].name, "support.function.duffle.annotation");
	assert.equal(offsetRule.captures[2].name, "entity.name.label.duffle.atom");
	assert.equal(offsetRule.captures[3].name, "entity.name.label.duffle.atom");
});

test("workspace enables semantic highlighting and colors every custom token", () => {
	const settings = readJson(path.resolve(ROOT, "..", "settings.json"));
	const semantic = settings["editor.semanticTokenColorCustomizations"];

	assert.equal(settings["editor.semanticHighlighting.enabled"], true);
	assert.equal(semantic.enabled, true);
	for (const tokenType of TOKEN_TYPES) {
		assert.equal(Object.hasOwn(semantic.rules, tokenType), true, `missing color: ${tokenType}`);
	}
	for (const rule of [
		"tapeGprRegister.tapeRead",
		"tapeGprRegister.tapeWrite",
		"tapeCop2Register.tapeRead",
		"tapeCop2Register.tapeWrite",
		"*.tapeAuto",
	]) {
		assert.equal(Object.hasOwn(semantic.rules, rule), true, `missing modifier color: ${rule}`);
	}
});
