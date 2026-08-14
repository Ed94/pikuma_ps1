"use strict";

const vscode = require("vscode");
const { TOKEN_MODIFIERS, TOKEN_TYPES, classifyDocument } = require("./classifier");
const { createIndex, mergeIndexes, scanSource } = require("./source-index");

const SOURCE_GLOB = "**/*.{c,h,cc,cpp,cxx,hh,hpp,hxx}";
const EXCLUDE_GLOB = "**/{gen,build,.slop_cache,toolchain,node_modules}/**";
const EXCLUDED_SEGMENTS = new Set(["gen", "build", ".slop_cache", "toolchain", "node_modules"]);

function isExcluded(uri) {
	const segments = uri.fsPath.replaceAll("\\", "/").split("/");
	return segments.some((segment) => EXCLUDED_SEGMENTS.has(segment));
}

function formatError(filePath, error) {
	return `${filePath}:${error.offset}: ${error.kind}`;
}

async function activate(context) {
	const output = vscode.window.createOutputChannel("Tape Atom DSL");
	const emitter = new vscode.EventEmitter();
	const legend = new vscode.SemanticTokensLegend(TOKEN_TYPES, TOKEN_MODIFIERS);
	let workspaceIndex = createIndex();
	let rebuildGeneration = 0;
	let debounceHandle = null;

	async function rebuildIndex() {
		const generation = ++rebuildGeneration;
		const files = await vscode.workspace.findFiles(SOURCE_GLOB, EXCLUDE_GLOB);
		let nextIndex = createIndex();

		for (const uri of files) {
			if (generation !== rebuildGeneration) return;
			if (isExcluded(uri)) continue;
			try {
				const bytes = await vscode.workspace.fs.readFile(uri);
				const source = Buffer.from(bytes).toString("utf8");
				const result = scanSource(source, uri.fsPath);
				nextIndex = mergeIndexes(nextIndex, result.index);
				for (const error of result.errors) output.appendLine(formatError(uri.fsPath, error));
			} catch (error) {
				output.appendLine(`${uri.fsPath}: ${error.stack || error.message || error}`);
			}
		}

		if (generation !== rebuildGeneration) return;
		workspaceIndex = nextIndex;
		emitter.fire();
	}

	function scheduleRebuild(uri) {
		if (uri && isExcluded(uri)) return;
		if (debounceHandle !== null) clearTimeout(debounceHandle);
		debounceHandle = setTimeout(() => {
			debounceHandle = null;
			rebuildIndex().catch((error) => output.appendLine(error.stack || String(error)));
		}, 100);
	}

	const provider = {
		onDidChangeSemanticTokens: emitter.event,
		provideDocumentSemanticTokens(document, cancellationToken) {
			try {
				const result = classifyDocument(
					document.getText(),
					document.uri.fsPath,
					workspaceIndex,
					() => cancellationToken.isCancellationRequested
				);
				const builder = new vscode.SemanticTokensBuilder(legend);
				for (const span of result.spans) {
					if (cancellationToken.isCancellationRequested) break;
					builder.push(span.line, span.character, span.length, span.typeIndex, span.modifierMask);
				}
				for (const error of result.errors) {
					output.appendLine(formatError(document.uri.fsPath || document.uri.toString(), error));
				}
				return builder.build();
			} catch (error) {
				output.appendLine(`${document.uri}: ${error.stack || error.message || error}`);
				return new vscode.SemanticTokensBuilder(legend).build();
			}
		},
	};

	const selector = [
		{ language: "c", scheme: "file" },
		{ language: "c", scheme: "untitled" },
		{ language: "cpp", scheme: "file" },
		{ language: "cpp", scheme: "untitled" },
	];
	const watcher = vscode.workspace.createFileSystemWatcher(SOURCE_GLOB);

	context.subscriptions.push(
		output,
		emitter,
		watcher,
		watcher.onDidCreate(scheduleRebuild),
		watcher.onDidChange(scheduleRebuild),
		watcher.onDidDelete(scheduleRebuild),
		vscode.languages.registerDocumentSemanticTokensProvider(selector, provider, legend),
		{ dispose() { if (debounceHandle !== null) clearTimeout(debounceHandle); } }
	);

	await rebuildIndex();
}

function deactivate() {}

module.exports = { activate, deactivate };
