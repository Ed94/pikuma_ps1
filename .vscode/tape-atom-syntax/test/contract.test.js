"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const { TOKEN_MODIFIERS, TOKEN_TYPES } = require("../classifier");

const ROOT = path.resolve(__dirname, "..");

function readJson(filePath) {
	const raw = fs.readFileSync(filePath, "utf8");
	const stripped = raw.replace(/\/\/.*$/gm, "").replace(/,\s*([}\]])/g, "$1");
	return JSON.parse(stripped);
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

	assert.equal(packageJson.version, "0.3.0");
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

test("every semantic token has a scope mapping; DSL-specific tokens also have grammar scopes", () => {
	const packageJson = readJson(path.join(ROOT, "package.json"));
	const grammar = readJson(path.join(ROOT, "syntaxes", "tape_atom.tmLanguage.json"));
	const mappings = packageJson.contributes.semanticTokenScopes[0].scopes;
	const grammarScopes = collectScopeNames(grammar);

	const grammarRequired = new Set([
		"tapeAtomKeyword", "tapeAtomName", "tapeComponentKeyword", "tapeComponentName",
		"tapeAnnotation", "tapeBindType", "tapePhase", "tapeLabel",
		"tapeDelaySlot", "tapeDuffleType", "keyword",
	]);

	for (const tokenType of TOKEN_TYPES) {
		assert.equal(Array.isArray(mappings[tokenType]), true, `missing scope mapping: ${tokenType}`);
		if (grammarRequired.has(tokenType)) {
			assert.equal(mappings[tokenType].some((scope) => grammarScopes.has(scope)), true, `grammar does not emit: ${tokenType}`);
		}
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

test("workspace enables semantic highlighting", () => {
	const settings = readJson(path.resolve(ROOT, "..", "settings.json"));
	assert.equal(settings["editor.semanticHighlighting.enabled"], true);
});
