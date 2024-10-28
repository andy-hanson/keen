module frontend.parse.lexWhitespace;

@safe @nogc pure nothrow:

import model.parseDiag : ParseDiag;
import util.col.array : isEmpty;
import util.conv : safeIntFromUint;
import util.sourceRange : Pos, Range;
import util.string : CString, cString, cStringIsEmpty, isWhitespace, MutCString, tryTakeChar, tryTakeChars;
import util.util : castNonScope_ref;

// Takes beginning of range; end is the current ptr
alias AddDiag = void delegate(CString, ParseDiag) @safe @nogc pure nothrow;
// The argument is the start of the comment. (The source ptr will have been advanced to the end of the comment.)
private alias CbComment = void delegate(CString) @safe @nogc pure nothrow;

immutable struct CStringRange {
	@safe @nogc pure nothrow:
	CString start;
	CString end;

	@trusted this(CString s, CString e) {
		start = s;
		end = e;
		assert(start <= end);
	}

	bool isEmpty() scope =>
		start == end;

	@trusted static CStringRange empty() =>
		CStringRange(cString!"", cString!"");
}

enum IndentKind {
	tabs,
	spaces2,
	spaces4,
	ignore,
}

// Note: Not issuing any diagnostics here. We'll fail later if we detect the wrong indent kind.
IndentKind detectIndentKind(in CString a) {
	MutCString ptr = a;
	while (true) {
		switch (*ptr) {
			case '\0':
				// No indented lines, so it's irrelevant
				return IndentKind.tabs;
			case '\t':
				return IndentKind.tabs;
			case ' ':
				// Count spaces
				do { ptr++; } while (*ptr == ' ');
				size_t n = ptr - a;
				// Only allowed amounts are 2 and 4.
				return n == 2 ? IndentKind.spaces2 : IndentKind.spaces4;
			default:
				while (!cStringIsEmpty(ptr) && *ptr != '\n')
					ptr++;
				if (*ptr == '\n')
					ptr++;
				continue;
		}
	}
}

void skipUntilNewline(scope ref MutCString ptr) {
	while (!cStringIsEmpty(ptr) && *ptr != '\n')
		ptr++;
}

// Used to lex the tokens that appear between AST nodes -- always a comment or keyword.
@trusted void lexTokensBetweenAsts(
	in CString source,
	Range range,
	in void delegate(Range) @safe @nogc pure nothrow cbComment,
	in void delegate(Range) @safe @nogc pure nothrow cbKeyword,
) {
	MutCString ptr = source.jumpTo(range.start);
	CString end = source.jumpTo(range.end);
	Range toRange(CString start) =>
		Range(start - source, ptr - source);
	while (ptr < end) {
		skipForTokens(ptr, end, (CString x) {
			cbComment(toRange(x));
		});
		if (ptr < end) {
			CString start = ptr;
			while (!ignoreCharForTokens(*ptr) && ptr < end)
				ptr++;
			assert(start < ptr && ptr <= end);
			cbKeyword(toRange(start));
		}
	}
	assert(ptr == end);
}

// Does not skip newlines (unless within a comment), only spaces within a line
void skipSpacesAndComments(ref MutCString ptr, in CbComment cbComment, in AddDiag addDiag) {
	while (true) {
		CString start = ptr;
		switch (*ptr) {
			case ' ':
			case '\t':
			case '\r':
				ptr++;
				continue;
			case '\\':
				if (tryTakeLineContinuation(ptr, cbComment))
					continue;
				else
					return;
			case '#':
				if (tryTakeTripleHashThenNewline(ptr)) {
					skipRestOfBlockComment(ptr, addDiag);
					cbComment(start);
				} else {
					while (tryTakeChar(ptr, ' ')) {}
					skipUntilNewline(ptr);
					cbComment(start);
				}
				continue;
			default:
				return;
		}
	}
}

int skipBlankLinesAndGetIndentDelta(
	ref MutCString ptr,
	IndentKind indentKind,
	ref uint curIndent,
	in AddDiag addDiag,
) {
	while (true) {
		MutCString start = ptr;
		uint newIndent;
		skipBlankLines(
			ptr,
			cbStartOfLoop: () {
				start = ptr;
				newIndent = takeIndentAmountAfterNewline(ptr, indentKind, addDiag);
			},
			cbComment: (CString _) {},
			addDiag: addDiag);

		if (*ptr == '\0')
			// Ignore indent before EOF
			newIndent = 0;

		// If we got here, we're looking at a non-empty line (or EOF)
		int delta = safeIntFromUint(newIndent) - safeIntFromUint(curIndent);
		if (delta > 1) {
			addDiag(start, ParseDiag(ParseDiag.IndentTooMuch()));
			skipRestOfLineAndNewline(ptr);
			continue;
		} else {
			curIndent = newIndent;
			return delta;
		}
	}
}

bool mayContinueOntoNextLine(ref MutCString ptr, IndentKind indentKind, uint minIndent) {
	MutCString original = ptr;
	while (tryTakeChar(ptr, ' ')) {}
	if (tryTakeNewline(ptr)) {
		bool diag = false;
		uint newIndent = takeIndentAmountAfterNewline(ptr, indentKind, (CString _, ParseDiag _2) { diag = true; });
		if (newIndent >= minIndent) {
			return true;
		} else {
			ptr = original;
			return false;
		}
	} else
		return false;
}

private:

bool tryTakeLineContinuation(ref MutCString ptr, in CbComment cbComment) {
	if (*ptr == '\\') {
		scope MutCString ptr2 = ptr;
		ptr2++;
		bool res = mayContinueOntoNextLine(ptr2, IndentKind.ignore, minIndent: 0);
		if (res) {
			CString start = ptr;
			ptr++;
			cbComment(start);
			ptr = castNonScope_ref(ptr2);
		}
		return res;
	} else
		return false;
}

bool ignoreCharForTokens(char c) =>
	isWhitespace(c) || c == '\\' || c == '#' || isNonKeywordPunctuation(c);

@system void skipForTokens(ref MutCString ptr, CString end, in CbComment cbComment) {
	while (ptr < end) {
		CString start = ptr;
		while (isNonKeywordPunctuation(*ptr) && ptr < end)
			ptr++;
		if (ptr < end)
			skipSpacesAndComments(ptr, cbComment, (CString _, ParseDiag _2) {});
		if (ptr < end && *ptr == '\\')
			// Non-comment '\', skip this too
			ptr++;
		if (ptr < end)
			skipBlankLines(ptr, () {}, cbComment, (CString _, ParseDiag _2) {});
		if (ptr == start)
			break;
	}
}

/*
Used for completions and signature help.
Walks to the left skipping whitespace on the same line. Can also skip a single '.'.
*/
public Pos walkBackwardsForPosition(string sourceText, Pos pos) {
	pos = skipWhitespaceBackwards(sourceText, pos);
	return pos != 0 && sourceText[pos - 1] == '.'
		? skipWhitespaceBackwards(sourceText, pos - 1)
		: pos;
}
Pos skipWhitespaceBackwards(string sourceText, Pos pos) {
	while (pos != 0) {
		char x = sourceText[pos - 1];
		if (x == ' ')
			pos --;
		else
			break;
	}
	return pos;
}

// Skip mundane punctuation instead of highlighting it as a keyword
bool isNonKeywordPunctuation(char a) {
	switch (a) {
		case '.':
		case ',':
		case '(':
		case ')':
		case '[':
		case ']':
			return true;
		default:
			return false;
	}
}


void skipBlankLines(
	ref MutCString ptr,
	in void delegate() @safe @nogc pure nothrow cbStartOfLoop,
	in CbComment cbComment,
	in AddDiag addDiag,
) {
	while (true) {
		cbStartOfLoop();
		CString before = ptr;
		if (tryTakeNewline(ptr)) {
		} else if (tryTakeTripleHashThenNewline(ptr)) {
			skipRestOfBlockComment(ptr, addDiag);
			cbComment(before);
		} else if (tryTakeChar(ptr, '#')) {
			while (tryTakeChar(ptr, ' ')) {}
			skipUntilNewline(ptr);
			cbComment(before);
		} else if (!tryTakeLineContinuation(ptr, cbComment))
			break;
	}
}

void skipRestOfLineAndNewline(ref MutCString ptr) {
	skipUntilNewline(ptr);
	cast(void) tryTakeNewline(ptr);
}

bool tryTakeNewline(ref MutCString ptr) {
	if (tryTakeChar(ptr, '\r')) {
		tryTakeChar(ptr, '\n');
		return true;
	} else
		return tryTakeChar(ptr, '\n');
}

uint takeIndentAmountAfterNewline(ref MutCString ptr, IndentKind indentKind, in AddDiag addDiag) {
	final switch (indentKind) {
		case IndentKind.tabs:
			CString begin = ptr;
			while (tryTakeChar(ptr, '\t')) {}
			if (*ptr == ' ') {
				CString startSpaces = ptr;
				while (*ptr == ' ') ptr++;
				addDiag(startSpaces, ParseDiag(ParseDiag.IndentWrongCharacter(true)));
			}
			return ptr - begin;
		case IndentKind.spaces2:
			return takeIndentAmountAfterNewlineSpaces(ptr, 2, addDiag);
		case IndentKind.spaces4:
			return takeIndentAmountAfterNewlineSpaces(ptr, 4, addDiag);
		case IndentKind.ignore:
			while (tryTakeChar(ptr, '\t') || tryTakeChar(ptr, ' ')) {}
			return 0;
	}
}

uint takeIndentAmountAfterNewlineSpaces(ref MutCString ptr, uint nSpacesPerIndent, in AddDiag addDiag) {
	CString begin = ptr;
	while (tryTakeChar(ptr, ' ')) {}
	if (*ptr == '\t') {
		CString startTabs = ptr;
		while (*ptr == '\t') ptr++;
		addDiag(startTabs, ParseDiag(ParseDiag.IndentWrongCharacter(false)));
	}
	uint nSpaces = ptr - begin;
	uint res = nSpaces / nSpacesPerIndent;
	if (res * nSpacesPerIndent != nSpaces)
		addDiag(begin, ParseDiag(ParseDiag.IndentNotDivisible(nSpaces, nSpacesPerIndent)));
	return res;
}

bool tryTakeTripleHashThenNewline(ref MutCString ptr) {
	MutCString ptr2 = ptr;
	if (tryTakeChars(ptr2, "###")) {
		while (*ptr2 == ' ')
			ptr2++;
		if (tryTakeNewline(ptr2) || cStringIsEmpty(ptr2)) {
			ptr = ptr2;
			return true;
		} else
			return false;
	} else
		return false;
}

// Returns the end of the comment text (ptr will be advanced further, past the '###')
void skipRestOfBlockComment(ref MutCString ptr, in AddDiag addDiag) {
	while (true) {
		while (tryTakeChar(ptr, '\t') || tryTakeChar(ptr, ' ')) {}
		if (tryTakeTripleHashThenNewline(ptr))
			break;
		else if (*ptr == '\0') {
			addDiag(ptr, ParseDiag(ParseDiag.Expected(ParseDiag.Expected.Kind.blockCommentEnd)));
			break;
		}
		skipRestOfLineAndNewline(ptr);
	}
}
