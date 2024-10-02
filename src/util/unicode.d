module util.unicode;

@safe @nogc pure nothrow:

import util.col.array : every;
import util.col.arrayBuilder : Builder;
import util.conv : safeToUint;
import util.opt : has, none, Opt, optIf, some;
import util.string : CString, CStringAndLength, done, MutCString, next, StringIter;

// File content that could be a string or binary.
// It always has a '\0' at the end just in case it's used as a string.
immutable struct FileContent {
	@safe @nogc pure nothrow:

	this(immutable ubyte[] a) {
		bytesWithNul = a;
		assert(bytesWithNul[$ - 1] == '\0');
	}
	this(CStringAndLength a) {
		this(cast(immutable ubyte[]) a.asStringIncludingNul);
	}

	static FileContent empty = FileContent([0]);

	immutable(ubyte[]) asBytes() return scope =>
		bytesWithNul[0 .. $ - 1];

	@system string assumeUtf8String() return scope =>
		cast(string) bytesWithNul[0 .. $ - 1];

	@system CString assumeUtf8() return scope =>
		CString(cast(immutable char*) bytesWithNul.ptr);

	// This ends with '\0'
	private ubyte[] bytesWithNul;
}

Opt!CStringAndLength unicodeValidate(in FileContent utf8) {
	string str = cast(string) utf8.asBytes;
	StringIter iter = StringIter(str);
	while (true) {
		dchar next = tryDecodeOneUnicodeChar(iter);
		if (next == '\0')
			break;
		else if (next == error)
			return none!CStringAndLength;
	}
	return optIf(iter.byteIndex(str) == str.length, () @trusted =>
		CStringAndLength(utf8.assumeUtf8, str.length));
}

void mustUnicodeEncode(ref Builder!(immutable char) builder, in dchar[] a) {
	bool ok = tryUnicodeEncode(builder, a);
	assert(ok);
}
void mustUnicodeEncode(ref Builder!(immutable char) builder, in dchar a) {
	bool ok = tryUnicodeEncode(builder, a);
	assert(ok);
}

bool tryUnicodeEncode(scope ref Builder!(immutable char) res, in dchar[] a) =>
	every(a, (in dchar x) => tryUnicodeEncode(res, x));

void mustUnicodeDecode(in string utf8, in void delegate(dchar) @safe @nogc pure nothrow cb) {
	StringIter iter = StringIter(utf8);
	while (true) {
		dchar next = tryDecodeOneUnicodeChar(iter);
		assert(next != error);
		if (next == '\0')
			break;
		else
			cb(next);
	}
}

dchar mustTakeOneUnicodeChar(scope ref MutCString ptr) {
	dchar res = tryDecodeOneUnicodeCharInner(() {
		char x = *ptr;
		ptr++;
		return x;
	});
	assert(res != '\0');
	return res;
}

Opt!dchar decodeAsSingleUnicodeChar(string utf8) {
	StringIter iter = StringIter(utf8);
	dchar res = tryDecodeOneUnicodeChar(iter);
	return res != error && done(iter) ? some(res) : none!dchar;
}

uint characterIndexOfByteIndex(in string utf8, uint byteIndex) {
	uint res = 0;
	StringIter iter = StringIter(utf8);
	while (!done(iter) && iter.byteIndex(utf8) < byteIndex) {
		cast(void) mustDecodeOneUnicodeChar(iter);
		res++;
	}
	return res;
}

uint byteIndexOfCharacterIndex(in string utf8, uint characterIndex) {
	StringIter iter = StringIter(utf8);
	foreach (size_t i; 0 .. characterIndex) {
		if (!done(iter))
			cast(void) mustDecodeOneUnicodeChar(iter);
	}
	return safeToUint(iter.byteIndex(utf8));
}

char safeToChar(dchar a) {
	assert(a <= char.max);
	return cast(char) a;
}

bool isValidUnicodeCharacter(dchar a) =>
	a < 0xd800 || (0xe000 <= a && a < 0x110000);

bool isUtf8InitialOrContinueCode(char a) =>
	(a & topBit) != 0;

private:

dchar mustDecodeOneUnicodeChar(scope ref StringIter iter) {
	dchar res = tryDecodeOneUnicodeChar(iter);
	assert(res != '\0' && res != error);
	return res;
}

dchar error() =>
	uint.max;
static assert(error == uint.max);
static assert(error == 0xffffffff);
static assert(!isValidUnicodeCharacter(error));

// Returns '\0' on end of string, 'error' on error
dchar tryDecodeOneUnicodeChar(scope ref StringIter iter) =>
	tryDecodeOneUnicodeCharInner(() => done(iter) ? '\0' : next(iter));

// 'next' should return '\0' to indicate end of string.
dchar tryDecodeOneUnicodeCharInner(in char delegate() @safe @nogc pure nothrow next) {
	char firstChar = next();
	if (!isUtf8InitialOrContinueCode(firstChar))
		return firstChar;
	else if ((firstChar & 0b1100_0000) != 0b1100_0000)
		return error;

	dchar res = firstChar;
	ubyte flag = cast(ubyte) (firstChar << 1);
	foreach (uint i; [1, 2, 3]) {
		char code = next();
		if ((code & 0b1100_0000) != 0b1000_0000)
			return error;

		res = (res << 6) | code.last6Bits;
		flag <<= 1;
		if (!isUtf8InitialOrContinueCode(flag)) {
			if ((res & ~mask(i - 1)) == 0)
				return error; // overlong, could have been encoded with i bytes
			res &= mask(i);
			return isValidUnicodeCharacter(res) ? res : error;
		}
	}
	return error;
}

uint mask(uint i) =>
	i == 0
		? (1 << 7) - 1
		: i == 1
		? (1 << 11) - 1
		: i == 2
		? (1 << 16) - 1
		: i == 3
		? (1 << 21) - 1
		: assert(false);

bool tryUnicodeEncode(scope ref Builder!(immutable char) res, dchar a) {
	if (a < 0x80) {
		res ~= safeToChar(a);
		return true;
	} else if (a < 0x800) {
		res ~= [0b1100_0000 | safeToChar(a >> 6), topBit | a.last6Bits];
		return true;
	} else if (a < 0x10000) {
		if (0xd800 <= a && a < 0xe000)
			return false;
		else {
			res ~= [
				safeToChar(0b1110_0000 | (a >> 12)),
				safeToChar(topBit | (a >> 6).last6Bits),
				safeToChar(topBit | a.last6Bits),
			];
			return true;
		}
	} else if (a < 0x110000) {
		res ~= [
			safeToChar(0b1111_0000 | (a >> 18)),
			safeToChar(topBit | (a >> 12).last6Bits),
			safeToChar(topBit | (a >> 6).last6Bits),
			safeToChar(topBit | a.last6Bits)
		];
		return true;
	} else
		return false;
}

ubyte topBit() =>
	0b1000_0000;
ubyte last6Bits(uint a) =>
	a & 0b111111;
