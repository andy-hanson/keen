module util.sourceRange;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.comparison : compareOr, compareUint, Comparison;
import util.col.array : isEmpty;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.conv : safeToUint;
import util.hash : HashCode, hashUints;
import util.json : field, get, Json, jsonObject;
import util.string : CString, MutCString, stringOfRange;
import util.unicode : byteIndexOfCharacterIndex, characterIndexOfByteIndex;
import util.uri : compareUriAlphabetically, mustParseUri, stringOfUri, Uri;
import util.writer : Writer;

// This is a byte offset into a file. (It should generally point to the *start* of a UTF8 character.)
alias Pos = uint;

immutable struct Range {
	@safe @nogc pure nothrow:

	Pos start;
	Pos end;

	@disable this();
	this(Pos s, Pos e) {
		start = s;
		end = e;
		assert(start <= end);
	}

	static Range empty() =>
		Range(0, 0);

	uint opDollar(size_t i : 0)() =>
		length;

	uint length() =>
		end - start;

	bool isEmpty() =>
		length == 0;

	Range opSlice(uint low, uint high) =>
		Range(start + low, start + high);
}

bool rangeContains(in Range a, in Range b) =>
	a.start <= b.start && b.end <= a.end;

Comparison compareRange(in Range a, in Range b) =>
	compareOr(compareUint(a.start, b.start), () => compareUint(a.end, b.end));

Range combineRanges(in Range a, in Range b) =>
	Range(a.start, b.end);

Range rangeOfStartAndLength(Pos start, size_t length) =>
	Range(start, safeToUint(start + length));

immutable struct UriAndPos {
	@safe @nogc pure nothrow:

	Uri uri;
	Pos pos;

	static UriAndPos empty() =>
		UriAndPos(Uri.empty, 0);
}

immutable struct UriAndRange {
	@safe @nogc pure nothrow:

	Uri uri;
	Range range;

	Pos start() =>
		range.start;

	static UriAndRange empty() =>
		topOfFile(Uri.empty);

	static UriAndRange topOfFile(Uri uri) =>
		UriAndRange(uri, Range.empty);
}

Comparison compareUriAndRange(in UriAndRange a, in UriAndRange b) {
	Comparison cmpUri = compareUriAlphabetically(a.uri, b.uri);
	return cmpUri != Comparison.equal ? cmpUri : compareRange(a.range, b.range);
}

UriAndPos toUriAndPos(UriAndRange a) =>
	UriAndPos(a.uri, a.start);

immutable struct LineAndCharacter {
	@safe @nogc pure nothrow:

	uint line;
	// This counts tabs as 1 character.
	uint character;

	void writeTo(scope ref Writer writer) {
		writer ~= line;
		writer ~= 'x';
		writer ~= character;
	}
}
Comparison compareLineAndCharacter(LineAndCharacter a, LineAndCharacter b) =>
	compareOr(compareUint(a.line, b.line), () =>
		compareUint(a.character, b.character));

private immutable struct LineAndColumnRange {
	@safe @nogc pure nothrow:

	LineAndColumn start;
	LineAndColumn end;

	void writeTo(scope ref Writer writer) {
		writer ~= start;
		writer ~= '-';
		writer ~= end;
	}
}

immutable struct UriLineAndColumn {
	Uri uri;
	LineAndColumn pos;
}

immutable struct UriLineAndColumnRange {
	Uri uri;
	LineAndColumnRange range;
}

immutable struct LineAndColumn {
	@safe @nogc pure nothrow:

	uint line0Indexed;
	// This counts tabs as TAB_SIZE characters.
	uint column0Indexed;

	uint line1Indexed() =>
		line0Indexed + 1;
	uint column1Indexed() =>
		column0Indexed + 1;

	void writeTo(scope ref Writer writer) {
		writer ~= line1Indexed;
		writer ~= ':';
		writer ~= column1Indexed;
	}
}

immutable struct LineAndCharacterRange {
	LineAndCharacter start;
	LineAndCharacter end;
}

immutable struct UriAndLine {
	@safe @nogc pure nothrow:
	Uri uri;
	uint line;

	HashCode hash() scope =>
		hashUints(uri.asUintForHash, line);
}
Json jsonOfUriAndLine(ref Alloc alloc, in UriAndLine a) =>
	jsonObject(alloc, [field!"uri"(stringOfUri(alloc, a.uri)), field!"line"(a.line)]);
UriAndLine uriAndLineOfJson(in Json a) =>
	UriAndLine(mustParseUri(get!"uri"(a).as!string), safeToUint(get!"line"(a).as!double));

immutable struct UriAndLineAndCharacterRange {
	Uri uri;
	LineAndCharacterRange range;
};

Json jsonOfUriAndLineAndCharacterRange(ref Alloc alloc, in UriAndLineAndCharacterRange a) =>
	jsonObject(alloc, [
		field!"uri"(stringOfUri(alloc, a.uri)),
		field!"range"(jsonOfLineAndCharacterRange(alloc, a.range))]);

Json jsonOfLineAndColumnRange(ref Alloc alloc, in LineAndColumnRange a) =>
	jsonObject(alloc, [
		field!"start"(jsonOfLineAndColumn(alloc, a.start)),
		field!"end"(jsonOfLineAndColumn(alloc, a.end))]);

Json jsonOfLineAndCharacterRange(ref Alloc alloc, in LineAndCharacterRange a) =>
	jsonObject(alloc, [
		field!"start"(jsonOfLineAndCharacter(alloc, a.start)),
		field!"end"(jsonOfLineAndCharacter(alloc, a.end))]);

Json jsonOfLineAndColumn(ref Alloc alloc, in LineAndColumn a) =>
	jsonObject(alloc, [field!"line"(a.line1Indexed), field!"column"(a.column1Indexed)]);

Json jsonOfLineAndCharacter(ref Alloc alloc, in LineAndCharacter a) =>
	jsonObject(alloc, [field!"line"(a.line), field!"character"(a.character)]);

immutable struct LineAndCharacterGetter {
	@safe @nogc pure nothrow:

	string sourceText;
	uint[] lineToPos;
	uint maxPos;
	bool usesCRLF;

	static LineAndCharacterGetter empty() {
		static immutable Pos[] emptyLineToPos = [0];
		return LineAndCharacterGetter("", emptyLineToPos, 0, false);
	}

	Pos opIndex(in LineAndCharacter lc) scope =>
		lc.line >= lineToPos.length
			? maxPos
			: lineToPos[lc.line] + byteIndexOfCharacterIndex(getLineText(lc.line), lc.character);

	Range opIndex(in LineAndCharacterRange lc) scope =>
		Range(this[lc.start], this[lc.end]);

	LineAndCharacter opIndex(Pos pos, PosKind kind) scope {
		uint line = lineAtPos(lineToPos, pos);
		if (kind == PosKind.endOfRange && lineToPos[line] == pos && line != 0) {
			// Show end of range at the end of the previous line
			line--;
			pos--;
		}
		Pos lineStart = lineToPos[line];
		assert((pos >= lineStart && line == lineToPos.length - 1) || pos <= lineToPos[line + 1]);
		uint character = characterIndexOfByteIndex(getLineText(line), pos - lineStart);
		// Don't include a column for the '\r' in '\r\n'
		if (usesCRLF && line + 1 < lineToPos.length && pos + 1 == lineToPos[line + 1])
			character--;
		return LineAndCharacter(line, character);
	}

	private string getLineText(uint line) return scope =>
		sourceText[lineToPos[line] .. nextLinePos(this, line)];

	size_t lastLine() scope =>
		isEmpty(lineToPos) ? 0 : lineToPos.length - 1;

	LineAndCharacterRange opIndex(in Range range) scope =>
		LineAndCharacterRange(this[range.start, PosKind.startOfRange], this[range.end, PosKind.endOfRange]);
}

private Pos nextLinePos(in LineAndCharacterGetter a, uint line) =>
	line == a.lineToPos.length - 1 ? a.maxPos : a.lineToPos[line + 1] - 1;

LineAndCharacter endOfLine(in LineAndCharacterGetter a, Pos start) {
	LineAndCharacter lc = a[start, PosKind.startOfRange];
	Pos next = nextLinePos(a, lc.line);
	assert(next > start);
	return LineAndCharacter(lc.line, lc.character + (next - start));
}
uint lineOfPos(in LineAndCharacterGetter a, Pos pos) =>
	a[pos, PosKind.startOfRange].line;

immutable struct LineAndColumnGetter {
	@safe @nogc pure nothrow:
	LineAndCharacterGetter lineAndCharacterGetter;
	bool usesCRLF;
	ubyte[] lineToNTabs;

	static LineAndColumnGetter empty() {
		static immutable ubyte[] emptyLineToNTabs = [0];
		return LineAndColumnGetter(LineAndCharacterGetter.empty, false, emptyLineToNTabs);
	}

	Pos opIndex(in LineAndColumn x) scope =>
		lineAndCharacterGetter[toLineAndCharacter(this, x)];

	LineAndColumn opIndex(Pos pos, PosKind kind) scope {
		LineAndCharacter res = lineAndCharacterGetter[pos, kind];
		ubyte nTabs = lineToNTabs[res.line];
		uint column = res.character <= nTabs
			? res.character * TAB_SIZE
			: nTabs * (TAB_SIZE - 1) + res.character;
		return LineAndColumn(res.line, column);
	}

	LineAndColumnRange opIndex(in Range range) scope =>
		LineAndColumnRange(this[range.start, PosKind.startOfRange], this[range.end, PosKind.endOfRange]);
}

LineAndCharacter toLineAndCharacter(in LineAndColumnGetter a, in LineAndColumn lc) =>
	LineAndCharacter(
		lc.line0Indexed,
		columnToCharacter(
			lc.column0Indexed,
			lc.line0Indexed < a.lineToNTabs.length ? a.lineToNTabs[lc.line0Indexed] : 0));

LineAndColumnGetter lineAndColumnGetterForText(ref Alloc alloc, return scope CString text) {
	ArrayBuilder!Pos lineToPos;
	ArrayBuilder!ubyte lineToNTabs;

	MutCString ptr = text;

	add(alloc, lineToPos, 0);
	add(alloc, lineToNTabs, advanceAndGetNTabs(ptr));

	bool usesCRLF = false;
	while (*ptr != '\0') {
		char x = *ptr;
		ptr++;
		if (x == '\r' && *ptr == '\n') usesCRLF = true;
		if (x == '\n' || (x == '\r' && *ptr != '\n')) {
			add(alloc, lineToPos, ptr - text);
			add(alloc, lineToNTabs, advanceAndGetNTabs(ptr));
		}
	}

	return LineAndColumnGetter(
		LineAndCharacterGetter(stringOfRange(text, ptr), finish(alloc, lineToPos), ptr - text, usesCRLF),
		usesCRLF,
		finish(alloc, lineToNTabs));
}

enum PosKind { startOfRange, endOfRange }

uint lineLengthInCharacters(in LineAndCharacterGetter a, uint line) {
	if (line < a.lineToPos.length - 1) {
		Pos next = a.lineToPos[line + 1];
		Pos here = a.lineToPos[line];
		assert(next > here + a.usesCRLF);
		return next - here - 1 - a.usesCRLF;
	} else if (line == a.lineToPos.length - 1)
		return a.maxPos - a.lineToPos[line];
	else
		return 0;
}

private:

Pos columnToCharacter(uint column, ubyte nTabs) =>
	column <= nTabs * TAB_SIZE
		? column / TAB_SIZE
		: column - (nTabs * (TAB_SIZE - 1));

uint lineAtPos(in uint[] lineToPos, Pos pos) {
	uint lowLine = 0; // inclusive
	uint highLine = safeToUint(lineToPos.length);
	assert(highLine != 0);
	while (lowLine < highLine - 1) {
		uint middleLine = mid(lowLine, highLine);
		Pos middlePos = lineToPos[middleLine];
		if (pos == middlePos)
			return middleLine;
		else if (pos < middlePos)
			// Exclusive -- must be on a previous line
			highLine = middleLine;
		else
			// Inclusive -- may be on a later character of the same line
			lowLine = middleLine;
	}
	return lowLine;
}

uint TAB_SIZE() => 4; // TODO: configurable

uint mid(uint a, uint b) =>
	(a + b) / 2;

ubyte advanceAndGetNTabs(ref MutCString a) {
	MutCString begin = a;
	while (*a == '\t') a++;
	return cast(ubyte) (a - begin);
}
