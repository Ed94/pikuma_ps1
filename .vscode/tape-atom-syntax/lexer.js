"use strict";

function isIdentifierStart(code) {
	return code === 95 ||
		(code >= 65 && code <= 90) ||
		(code >= 97 && code <= 122);
}

function isIdentifierContinue(code) {
	return isIdentifierStart(code) || (code >= 48 && code <= 57);
}

function lex(source) {
	if (typeof source !== "string") throw new TypeError("source must be a string");

	const tokens = [];
	const errors = [];
	let offset = 0;
	let line = 0;
	let character = 0;

	function advance() {
		if (source[offset] === "\r" && source[offset + 1] === "\n") {
			offset += 2;
			line += 1;
			character = 0;
			return;
		}
		if (source[offset] === "\n") {
			offset += 1;
			line += 1;
			character = 0;
			return;
		}
		offset += 1;
		character += 1;
	}

	function pushToken(kind, start, startLine, startCharacter) {
		tokens.push({
			kind,
			text: source.slice(start, offset),
			start,
			end: offset,
			line: startLine,
			character: startCharacter,
		});
	}

	while (offset < source.length) {
		const ch = source[offset];

		if (/\s/.test(ch)) {
			advance();
			continue;
		}

		if (ch === "/" && source[offset + 1] === "/") {
			while (offset < source.length && source[offset] !== "\r" && source[offset] !== "\n") advance();
			continue;
		}

		if (ch === "/" && source[offset + 1] === "*") {
			const start = offset;
			advance();
			advance();
			let closed = false;
			while (offset < source.length) {
				if (source[offset] === "*" && source[offset + 1] === "/") {
					advance();
					advance();
					closed = true;
					break;
				}
				advance();
			}
			if (!closed) errors.push({ kind: "unterminated-block-comment", offset: start });
			continue;
		}

		if (ch === "\"" || ch === "'") {
			const quote = ch;
			const start = offset;
			advance();
			let closed = false;
			while (offset < source.length) {
				if (source[offset] === "\\") {
					advance();
					if (offset < source.length) advance();
					continue;
				}
				if (source[offset] === quote) {
					advance();
					closed = true;
					break;
				}
				if (source[offset] === "\n" || source[offset] === "\r") break;
				advance();
			}
			if (!closed) errors.push({ kind: "unterminated-literal", offset: start });
			continue;
		}

		const code = source.charCodeAt(offset);
		if (isIdentifierStart(code)) {
			const start = offset;
			const startLine = line;
			const startCharacter = character;
			advance();
			while (offset < source.length && isIdentifierContinue(source.charCodeAt(offset))) advance();
			pushToken("identifier", start, startLine, startCharacter);
			continue;
		}

		const start = offset;
		const startLine = line;
		const startCharacter = character;
		advance();
		pushToken("punctuation", start, startLine, startCharacter);
	}

	return { tokens, errors };
}

function buildCallContexts(tokens) {
	const contexts = Array.from({ length: tokens.length }, () => []);
	const calls = [];
	const errors = [];
	const stack = [];

	for (let tokenIndex = 0; tokenIndex < tokens.length; tokenIndex += 1) {
		const token = tokens[tokenIndex];

		if (token.text === ")") {
			if (stack.length === 0) {
				errors.push({ kind: "unmatched-close-paren", offset: token.start });
			} else {
				const frame = stack.pop();
				if (frame.callee !== null) calls.push({ ...frame, closeTokenIndex: tokenIndex });
			}
		}

		contexts[tokenIndex] = stack
			.filter((frame) => frame.callee !== null)
			.map((frame) => ({
				callee: frame.callee,
				calleeTokenIndex: frame.calleeTokenIndex,
				openTokenIndex: frame.openTokenIndex,
				argIndex: frame.argIndex,
			}));

		if (token.text === "(") {
			const previous = tokens[tokenIndex - 1];
			const hasCallee = previous && previous.kind === "identifier";
			stack.push({
				callee: hasCallee ? previous.text : null,
				calleeTokenIndex: hasCallee ? tokenIndex - 1 : -1,
				openTokenIndex: tokenIndex,
				argIndex: 0,
			});
			continue;
		}

		if (token.text === "," && stack.length > 0) {
			const frame = stack[stack.length - 1];
			if (frame.callee !== null) frame.argIndex += 1;
		}
	}

	for (const frame of stack) {
		errors.push({ kind: "unmatched-open-paren", offset: tokens[frame.openTokenIndex].start });
	}

	return { contexts, calls, errors };
}

function nearestCall(contexts, tokenIndex, callee) {
	const entries = contexts[tokenIndex] || [];
	for (let contextIndex = entries.length - 1; contextIndex >= 0; contextIndex -= 1) {
		const entry = entries[contextIndex];
		if (callee === undefined || entry.callee === callee) return entry;
	}
	return null;
}

module.exports = { buildCallContexts, lex, nearestCall };
