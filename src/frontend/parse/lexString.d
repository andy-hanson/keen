module frontend.parse.lexString;

@safe @nogc pure nothrow:

import frontend.parse.lexWhitespace : AddDiag;
import model.parseDiag : ParseDiag, ParseDiagExpected, ParseDiagInvalidStringEscape;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.opt : force, has, none, Opt, optIf;
import util.sourceRange : Pos, Range, rangeOfStartAndLength;
import util.string : CString, decodeHexDigit, MutCString, stringOfRange, takeChar, tryTakeChars;
import util.unicode : safeToChar, tryUnicodeEncode;
import util.util : castNonScope_ref;

immutable struct StringPart {
	Range range;
	string text;
	StringPartAfter after;
}
enum StringPartAfter { done, lbrace }

enum QuoteKind {
	quoteBar,
	quoteDouble,
	quoteDouble3,
}

StringPart takeStringPart(
	ref Alloc alloc,
	return scope ref MutCString ptr,
	Pos startPos,
	QuoteKind quoteKind,
	in AddDiag addDiag,
) {
	ArrayBuilder!char res;
	StringRange range = takeStringRange(ptr, startPos, quoteKind, (char x) {
		// To save space, don't collect strings for doc comments.
		if (quoteKind != QuoteKind.quoteBar)
			add(alloc, res, x);
	}, addDiag);
	return StringPart(range.range, finish(alloc, res), range.after);
}

private immutable struct StringRange {
	Range range;
	StringPartAfter after;
}
private StringRange takeStringRange(
	return scope ref MutCString ptr,
	Pos startPos,
	QuoteKind quoteKind,
	in void delegate(char) @safe @nogc pure nothrow cbChar,
	in AddDiag addDiag,
) {
	CString partStart = ptr;
	while (true) {
		CString start = ptr;
		StringRange finishHere(StringPartAfter after) =>
			StringRange(rangeOfStartAndLength(startPos, start - partStart), after);
		switch (*ptr) {
			case '"':
				ptr++;
				final switch (quoteKind) {
					case QuoteKind.quoteBar:
						cbChar('"');
						break;
					case QuoteKind.quoteDouble:
						return finishHere(StringPartAfter.done);
					case QuoteKind.quoteDouble3:
						if (tryTakeChars(ptr, "\"\""))
							return finishHere(StringPartAfter.done);
						else
							cbChar('"');
						break;
				}
				break;
			case '{':
				ptr++;
				return finishHere(StringPartAfter.lbrace);
			case '\\':
				ptr++;
				takeStringEscape(start, ptr, cbChar, addDiag);
				break;
			case '\r':
			case '\n':
				final switch (quoteKind) {
					case QuoteKind.quoteBar:
						MutCString ptr2 = ptr;
						while (*ptr2 == '\n' || *ptr2 == '\r' || *ptr2 == ' ' || *ptr2 == '\t') ptr2++;
						if (*ptr2 == '|') {
							ptr2++;
							if (*ptr2 == ' ') ptr2++;
							ptr = castNonScope_ref(ptr2);
							cbChar('\n');
							break;
						} else
							return finishHere(StringPartAfter.done);
					case QuoteKind.quoteDouble:
						addDiag(start, ParseDiag(ParseDiagExpected(ParseDiagExpected.quoteDouble)));
						return finishHere(StringPartAfter.done);
					case QuoteKind.quoteDouble3:
						cbChar(takeChar(ptr));
						break;
				}
				break;
			case '\0':
				final switch (quoteKind) {
					case QuoteKind.quoteBar:
						break;
					case QuoteKind.quoteDouble:
						addDiag(start, ParseDiag(ParseDiagExpected(ParseDiagExpected.quoteDouble)));
						break;
					case QuoteKind.quoteDouble3:
						addDiag(start, ParseDiag(ParseDiagExpected(ParseDiagExpected.quoteDouble3)));
						break;
				}
				return finishHere(StringPartAfter.done);
			default:
				cbChar(takeChar(ptr));
		}
	}
}

private:

void takeStringEscape(
	in CString start,
	scope ref MutCString ptr,
	in void delegate(char) @safe @nogc pure nothrow cbChar,
	in AddDiag addDiag,
) {
	switch (takeChar(ptr)) {
		case '\\':
			cbChar('\\');
			break;
		case '{':
			cbChar('{');
			break;
		case '0':
			cbChar('\0');
			break;
		case '"':
			cbChar('"');
			break;
		case 'n':
			cbChar('\n');
			break;
		case 'r':
			cbChar('\r');
			break;
		case 't':
			cbChar('\t');
			break;
		case 'u':
			takeUnicodeEscape(start, ptr, cbChar, addDiag, 2);
			break;
		case 'U':
			takeUnicodeEscape(start, ptr, cbChar, addDiag, 4);
			break;
		case 'x':
			takeUnicodeEscape(start, ptr, cbChar, addDiag, 1);
			break;
		default:
			stringEscapeError(start, ptr, cbChar, addDiag);
			break;
	}
}

void takeUnicodeEscape(
	in CString start,
	scope ref MutCString ptr,
	in void delegate(char) @safe @nogc pure nothrow cbChar,
	in AddDiag addDiag,
	size_t nBytes,
) {
	dchar fullChar = 0;
	foreach (size_t i; 0 .. nBytes) {
		Opt!char c = takeCharEscape(ptr);
		if (has(c))
			fullChar = (fullChar << 8) | force(c);
		else {
			stringEscapeError(start, ptr, cbChar, addDiag);
			return;
		}
	}

	if (!tryUnicodeEncode(fullChar, cbChar))
		stringEscapeError(start, ptr, cbChar, addDiag);
}

void stringEscapeError(
	in CString start,
	in CString ptr,
	in void delegate(char) @safe @nogc pure nothrow cbChar,
	in AddDiag addDiag,
) {
	addDiag(start, ParseDiag(ParseDiagInvalidStringEscape(stringOfRange(start, ptr))));
	foreach (char x; "�")
		cbChar(x);
}

Opt!char takeCharEscape(scope ref MutCString ptr) {
	Opt!ubyte digit0 = tryTakeHexDigit(ptr);
	Opt!ubyte digit1 = has(digit0) ? tryTakeHexDigit(ptr) : none!ubyte;
	return optIf(has(digit0) && has(digit1), () =>
		safeToChar((force(digit0) << 4) | force(digit1)));
}

Opt!ubyte tryTakeHexDigit(ref MutCString ptr) {
	Opt!ubyte res = decodeHexDigit(*ptr);
	if (has(res))
		ptr++;
	return res;
}
