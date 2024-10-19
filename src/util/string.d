module util.string;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.comparison : compareArrays, compareChar, compareOr, compareSizeT, Comparison;
import util.col.array : append, arrayOfRange, arraysEqual, copyArray, endPtr, isEmpty, small, SmallArray;
import util.conv : safeToUint;
import util.hash : HashCode, hashString;
import util.opt : force, none, Opt, some;
import util.util : castNonScope_ref;

alias SmallString = SmallArray!(immutable char);
alias smallString = small!(immutable char);

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

@trusted Comparison compareStringsNaturally(in string a, in string b) =>
	compareOr(
		compareStringsNaturallyPass(a, b, caseSensitive: false),
		() => compareStringsNaturallyPass(a, b, caseSensitive: true),
		() => compareStringsUtf8Order(a, b));
private Comparison compareStringsNaturallyPass(in string a, in string b, bool caseSensitive) {
	if (isEmpty(a))
		return isEmpty(b) ? Comparison.equal : Comparison.less;
	else if (isEmpty(b))
		return Comparison.greater;
	else if (!isLetterOrDigit(a[0]))
		return compareStringsNaturallyPass(a[1 .. $], b, caseSensitive);
	else if (!isLetterOrDigit(b[0]))
		return compareStringsNaturallyPass(a, b[1 .. $], caseSensitive);
	else if (isDecimalDigit(a[0])) {
		if (isDecimalDigit(b[0])) {
			string[2] na = takeNumberFromFront(a);
			string[2] nb = takeNumberFromFront(b);
			return compareOr(
				compareNumberStrings(na[0], nb[0]),
				() => compareStringsNaturallyPass(na[1], nb[1], caseSensitive));
		} else
			return Comparison.less;
	} else if (isDecimalDigit(b[0]))
		return Comparison.greater;
	else
		return compareOr(
			compareChars(a[0], b[0], caseSensitive),
			() => compareStringsNaturallyPass(a[1 .. $], b[1 .. $], caseSensitive));
}
private Comparison compareChars(char a, char b, bool caseSensitive) =>
	caseSensitive
		? compareChar(a, b)
		: compareChar(toLower(a), toLower(b));
private char toLower(char a) =>
	isUpperCaseLetter(a) ? cast(char) ('a' + (a - 'A')) : a;
private Comparison compareStringsUtf8Order(in string a, in string b) =>
	compareArrays!char(a, b, (in char x, in char y) => compareChar(x, y));
private Comparison compareNumberStrings(in string a, in string b) {
	string a2 = stripLeadingZeroes(a);
	string b2 = stripLeadingZeroes(b);
	return compareOr(
		compareSizeT(a2.length, b2.length),
		() => compareStringsUtf8Order(a2, b2));
}
private string[2] takeNumberFromFront(return string a) {
	size_t i = 0;
	while (i < a.length && isDecimalDigit(a[i]))
		i++;
	return [a[0 .. i], a[i .. $]];
}
private string stripLeadingZeroes(return string a) =>
	isEmpty(a) || a[0] != '0'
		? a
		: stripLeadingZeroes(a[1 .. $]);

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

bool isAsciiIdentifierChar(dchar a) =>
	isLetterOrDigit(a) || a == '_';
private bool isLetterOrDigit(dchar a) =>
	isLetter(a) || isDecimalDigit(a);
private bool isLetter(dchar a) =>
	isLowerCaseLetter(a) || isUpperCaseLetter(a);
private bool isLowerCaseLetter(dchar a) =>
	'a' <= a && a <= 'z';
private bool isUpperCaseLetter(dchar a) =>
	'A' <= a && a <= 'Z';
bool isDecimalDigit(dchar c) =>
	'0' <= c && c <= '9';

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
