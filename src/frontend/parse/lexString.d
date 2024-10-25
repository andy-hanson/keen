module frontend.parse.lexString;

@safe @nogc pure nothrow:

import frontend.parse.lexWhitespace : AddDiag;
import model.parseDiag : ParseDiag;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : Builder, finish;
import util.opt : force, has, none, Opt, optIf;
import util.sourceRange : Pos, Range, rangeOfStartAndLength;
import util.string : CString, decodeHexDigit, MutCString, stringOfRange, takeChar, tryTakeChars;
import util.unicode : safeToChar, tryUnicodeEncode;
import util.util : castNonScope_ref;

immutable struct StringPart {
	Range range;
	string text;
	After after;

	enum After { done, lbrace }
}

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
	CString partStart = ptr;
	Builder!(immutable char) res = Builder!(immutable char)(&alloc);
	while (true) {
		CString start = ptr;
		StringPart finishHere(StringPart.After after) =>
			StringPart(rangeOfStartAndLength(startPos, start - partStart), finish(res), after);
		switch (*ptr) {
			case '"':
				ptr++;
				final switch (quoteKind) {
					case QuoteKind.quoteBar:
						res ~= '"';
						break;
					case QuoteKind.quoteDouble:
						return finishHere(StringPart.After.done);
					case QuoteKind.quoteDouble3:
						if (tryTakeChars(ptr, "\"\""))
							return finishHere(StringPart.After.done);
						else
							res ~= '"';
						break;
				}
				break;
			case '{':
				ptr++;
				return finishHere(StringPart.After.lbrace);
			case '\\':
				ptr++;
				takeStringEscape(res, start, ptr, addDiag);
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
							res ~= '\n';
							break;
						} else
							return finishHere(StringPart.After.done);
					case QuoteKind.quoteDouble:
						addDiag(start, ParseDiag(ParseDiag.Expected(ParseDiag.Expected.Kind.quoteDouble)));
						return finishHere(StringPart.After.done);
					case QuoteKind.quoteDouble3:
						res ~= takeChar(ptr);
						break;
				}
				break;
			case '\0':
				final switch (quoteKind) {
					case QuoteKind.quoteBar:
						break;
					case QuoteKind.quoteDouble:
						addDiag(start, ParseDiag(ParseDiag.Expected(ParseDiag.Expected.Kind.quoteDouble)));
						break;
					case QuoteKind.quoteDouble3:
						addDiag(start, ParseDiag(ParseDiag.Expected(ParseDiag.Expected.Kind.quoteDouble3)));
						break;
				}
				return finishHere(StringPart.After.done);
			default:
				res ~= takeChar(ptr);
		}
	}
}

private:

void takeStringEscape(
	scope ref Builder!(immutable char) res,
	in CString start,
	scope ref MutCString ptr,
	in AddDiag addDiag,
) {
	switch (takeChar(ptr)) {
		case '\\':
			res ~= '\\';
			break;
		case '{':
			res ~= '{';
			break;
		case '0':
			res ~= '\0';
			break;
		case '"':
			res ~= '"';
			break;
		case 'n':
			res ~= '\n';
			break;
		case 'r':
			res ~= '\r';
			break;
		case 't':
			res ~= '\t';
			break;
		case 'u':
			takeUnicodeEscape(res, start, ptr, addDiag, 2);
			break;
		case 'U':
			takeUnicodeEscape(res, start, ptr, addDiag, 4);
			break;
		case 'x':
			takeUnicodeEscape(res, start, ptr, addDiag, 1);
			break;
		default:
			stringEscapeError(res, start, ptr, addDiag);
			break;
	}
}

void takeUnicodeEscape(
	scope ref Builder!(immutable char) res,
	in CString start,
	scope ref MutCString ptr,
	in AddDiag addDiag,
	size_t nBytes,
) {
	dchar fullChar = 0;
	foreach (size_t i; 0 .. nBytes) {
		Opt!char c = takeCharEscape(ptr);
		if (has(c))
			fullChar = (fullChar << 8) | force(c);
		else {
			stringEscapeError(res, start, ptr, addDiag);
			return;
		}
	}

	if (!tryUnicodeEncode(res, fullChar))
		stringEscapeError(res, start, ptr, addDiag);
}

void stringEscapeError(
	scope ref Builder!(immutable char) res,
	in CString start,
	in CString ptr,
	in AddDiag addDiag,
) {
	addDiag(start, ParseDiag(ParseDiag.InvalidStringEscape(stringOfRange(start, ptr))));
	res ~= "�";
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
