module util.string;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.comparison : compareArrays, compareChar, Comparison;
import util.col.array :
	append, arrayOfRange, arraysEqual, copyArray, emptySmallArray, endPtr, isEmpty, small, SmallArray;
import util.conv : safeToUint;
import util.hash : HashCode, hashString;
import util.opt : force, none, Opt, some;
import util.util : castNonScope_ref;

alias SmallString = SmallArray!(immutable char);
alias smallString = small!(immutable char);
SmallString emptySmallString() =>
	emptySmallArray!(immutable char);

// Like 'immutable char*' but guaranteed to have a terminating '\0'
// (Preferred to `string` as it is 8 bytes instead of 16)
struct MutCString {
	@safe @nogc pure nothrow:

	@disable this();
	@system this(immutable char* p) inout {
		assert(p != null);
		ptr = p;
	}

	char opUnary(string op : "*")() scope const =>
		*ptr;
	// Unsafe since this does not check bounds
	@system CString jumpTo(uint n) immutable =>
		inout MutCString(ptr + n);

	@system ptrdiff_t opCmp(in MutCString b) scope const =>
		ptr - b.ptr;

	@trusted void opUnary(string op : "++")() {
		assert(*ptr != '\0');
		ptr++;
	}

	@system CString opBinary(string op : "-")(in size_t b) const =>
		MutCString(ptr - b);
	@system void opUnary(string op : "--")() {
		ptr--;
	}

	uint opBinary(string op : "-")(in MutCString b) scope const =>
		safeToUint(ptr - b.ptr);

	immutable(char)* ptr;

	bool opEquals(in string b) scope const =>
		stringsEqual(stringOfCString(this), b);
	bool opEquals(in CString b) scope const =>
		this == stringOfCString(b);

	HashCode hash() scope const =>
		hashString(stringOfCString(this));
}

alias CString = immutable MutCString;

immutable struct CStringAndLength {
	@safe @nogc pure nothrow:

	CString cString;
	size_t length;
	this(CString c) {
		cString = c;
		length = cStringSize(c);
	}
	@system this(CString c, size_t l) {
		cString = c;
		length = l;
	}

	CString asCString() =>
		cString;
	@trusted string asString() =>
		cString.ptr[0 .. length];
	@trusted string asStringIncludingNul() =>
		cString.ptr[0 .. length + 1];
}

@trusted immutable(ubyte[]) bytesOfString(return scope string a) {
	static assert(char.sizeof == ubyte.sizeof);
	return cast(ubyte[]) a;
}

private @trusted immutable(char*) cStringEnd(immutable(char)* ptr) {
	while (*ptr != '\0')
		ptr++;
	return ptr;
}

@trusted CString copyToCString(ref Alloc alloc, in char[] s) =>
	isEmpty(s)
		? cString!""
		: CString(cast(immutable) append(alloc, s, '\0').ptr);

bool stringsEqual(in string a, in string b) =>
	arraysEqual(a, b);

@trusted CString cString(immutable char* content)() =>
	CString(content);

@trusted size_t cStringSize(in CString a) =>
	cStringEnd(a.ptr) - a.ptr;

bool cStringIsEmpty(CString a) =>
	*a.ptr == '\0';

@trusted string stringOfRange(return scope CString begin, return scope CString end) =>
	arrayOfRange(begin.ptr, end.ptr);

@trusted string stringOfCString(return scope CString a) =>
	stringOfRange(a, CString(cStringEnd(a.ptr)));

string copyString(ref Alloc alloc, in string a) =>
	copyArray(alloc, a);

@trusted void eachChar(in CString a, in void delegate(char) @safe @nogc pure nothrow cb) {
	for (immutable(char)* p = a.ptr; *p != '\0'; p++)
		cb(*p);
}

@trusted Comparison compareStringsAlphabetically(in string a, in string b) =>
	compareArrays!char(a, b, (in char x, in char y) => compareChar(x, y));

char takeChar(scope ref MutCString ptr) {
	char res = *ptr;
	ptr++;
	return res;
}

bool tryTakeChar(scope ref MutCString ptr, char expected) {
	if (*ptr == expected) {
		ptr++;
		return true;
	} else
		return false;
}

pure @trusted CString mustStripPrefix(CString a, string prefix) {
	Opt!CString res = tryGetAfterStartsWith(a, prefix);
	return force(res);
}

bool startsWith(in CString a, in string chars) {
	MutCString ptr = a;
	return tryTakeChars(ptr, chars);
}

bool startsWithThenWhitespace(in CString a, in string chars) {
	MutCString ptr = a;
	return tryTakeChars(ptr, chars) && isWhitespace(*ptr);
}

Opt!CString tryGetAfterStartsWith(MutCString ptr, in string chars) =>
	tryTakeChars(ptr, chars) ? some!CString(ptr) : none!CString;

immutable struct PrefixAndRest {
	string prefix;
	CString rest;
}
Opt!PrefixAndRest trySplit(CString a, char splitter) {
	MutCString cur = a;
	while (!cStringIsEmpty(cur)) {
		if (*cur == splitter) {
			string prefix = stringOfRange(a, cur);
			cur++;
			return some(PrefixAndRest(prefix, cur));
		}
		cur++;
	}
	return none!PrefixAndRest;
}

bool endsWith(string a, string b) =>
	a.length >= b.length && a[$ - b.length .. $] == b;

bool tryTakeChars(scope ref MutCString a, in string chars) {
	MutCString ptr = a;
	foreach (immutable char expected; chars) {
		if (*ptr != expected)
			return false;
		ptr++;
	}
	a = castNonScope_ref(ptr);
	return true;
}

bool isWhitespace(char a) {
	switch (a) {
		case ' ':
		case '\t':
		case '\r':
		case '\n':
			return true;
		default:
			return false;
	}
}

bool isDecimalDigit(dchar c) =>
	'0' <= c && c <= '9';

bool isAsciiIdentifierChar(dchar a) =>
	('a' <= a && a <= 'z') ||
	('A' <= a && a <= 'Z') ||
	isDecimalDigit(a) ||
	a == '_';

Opt!ubyte decodeHexDigit(char a) =>
	isDecimalDigit(a)
		? some!ubyte(cast(ubyte) (a - '0'))
		: 'a' <= a && a <= 'f'
		? some!ubyte(cast(ubyte) (10 + (a - 'a')))
		: 'A' <= a && a <= 'F'
		? some!ubyte(cast(ubyte) (10 + (a - 'A')))
		: none!ubyte;

struct StringIter {
	@safe @nogc pure nothrow:

	immutable(char)* cur;
	immutable(char)* end;

	@trusted this(return scope string a) {
		cur = a.ptr;
		end = endPtr(a);
	}

	@trusted size_t byteIndex(string original) scope const {
		assert(original.ptr <= cur && endPtr(original) == end);
		return cur - original.ptr;
	}
}
bool done(in StringIter a) {
	assert(a.cur <= a.end);
	return a.cur == a.end;
}
@trusted char next(scope ref StringIter a) {
	assert(!done(a));
	char res = *a.cur;
	a.cur++;
	return res;
}
char nextOrDefault(scope ref StringIter a, char default_) =>
	done(a) ? default_ : next(a);
