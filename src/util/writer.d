module util.writer;

@safe @nogc nothrow:

import util.alloc.alloc : Alloc, withStackAlloc, withStackAllocImpure;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.col.arrayBuilder : asTemporaryArray, Builder, finish, sizeSoFar;
import util.col.array : reverseInPlace, zip;
import util.conv : bitsOfFloat64, powerOf10, round, safeToSizeT, safeToUlong;
import util.string : eachChar, CString, stringOfCString;
import util.unicode : isValidUnicodeCharacter, mustUnicodeDecode, mustUnicodeEncode;
import util.util : abs, castImmutable, debugLog, isNan, max, min;

T withStackWriterImpure(T)(
	in void delegate(scope ref Writer) @safe @nogc nothrow cb,
	in T delegate(in string) @safe @nogc nothrow cbRes,
) =>
	withStackAllocImpure!(0x10000, T)((scope ref Alloc alloc) {
		scope Writer writer = Writer(&alloc);
		cb(writer);
		return cbRes(finish(writer.res));
	});

T withStackWriterImpureCString(T, size_t maxSize = 0x10000)(
	in void delegate(scope ref Writer) @safe @nogc nothrow cb,
	in T delegate(in CString) @safe @nogc nothrow cbRes,
) =>
	withStackAllocImpure!(maxSize, T)((scope ref Alloc alloc) {
		scope Writer writer = Writer(&alloc);
		cb(writer);
		return cbRes(finishCString(writer));
	});

pure:

struct Writer {
	@safe @nogc pure nothrow:

	private:
	Builder!(immutable char) res;

	public this(return scope Alloc* allocPtr) {
		res = Builder!(immutable char)(allocPtr);
	}

	public ref Alloc alloc() return scope =>
		res.alloc;

	void opOpAssign(string op : "~")(bool a) {
		res ~= (a ? "true" : "false");
	}
	void opOpAssign(string op : "~")(char a) {
		res ~= a;
	}
	void opOpAssign(string op : "~")(dchar a) {
		mustUnicodeEncode(res, a);
	}
	void opOpAssign(string op : "~")(in char[] a) {
		res ~= castImmutable(a);
	}
	void opOpAssign(string op : "~")(in CString a) {
		eachChar(a, (char c) {
			this ~= c;
		});
	}
	void opOpAssign(string op : "~")(ubyte a) {
		writeNat(this, a);
	}
	void opOpAssign(string op : "~")(ushort a) {
		writeNat(this, a);
	}
	void opOpAssign(string op : "~")(uint a) {
		writeNat(this, a);
	}
	void opOpAssign(string op : "~")(int a) {
		this ~= long(a);
	}
	void opOpAssign(string op : "~")(ulong a) {
		writeNat(this, a);
	}
	void opOpAssign(string op : "~")(long a) {
		if (a < 0)
			this ~= '-';
		this ~= abs(a);
	}
	void opOpAssign(string op : "~", T)(T a) {
		a.writeTo(this);
	}
}

void debugLogWithWriter(in void delegate(scope ref Writer) @safe @nogc pure nothrow cb) {
	debugLogWithWriter((scope ref Alloc, scope ref Writer writer) {
		cb(writer);
	});
}
void debugLogWithWriter(in void delegate(scope ref Alloc, scope ref Writer) @safe @nogc pure nothrow cb) {
	debug {
		withStackWriter!0x10000((scope ref Alloc alloc, scope ref Writer writer) {
			cb(alloc, writer);
			writer ~= '\0';
		}, (in string x) => debugLog(x.ptr));
	}
}
T withStackWriter(size_t nBytes, T)(
	in void delegate(scope ref Writer) @safe @nogc pure nothrow cb,
	in T delegate(in string) @safe @nogc pure nothrow cbRes,
) =>
	withStackWriter!(nBytes, T)(
		(scope ref Alloc _, scope ref Writer writer) { cb(writer); },
		cbRes);
T withStackWriter(size_t nBytes, T)(
	in void delegate(scope ref Alloc, scope ref Writer) @safe @nogc pure nothrow cb,
	in T delegate(in string) @safe @nogc pure nothrow cbRes,
) =>
	withStackAlloc!nBytes((scope ref Alloc alloc) =>
		cbRes(makeStringWithWriter(alloc, (scope ref Writer writer) {
			cb(alloc, writer);
		})));
T withStackWriterCString(size_t sizeBytes = 0x1000, T)(
	in void delegate(scope ref Writer) @safe @nogc pure nothrow cb,
	in T delegate(in CString) @safe @nogc pure nothrow cbRes,
) =>
	withStackAlloc!(sizeBytes * ulong.sizeof)((scope ref Alloc alloc) =>
		cbRes(withWriter(alloc, (scope ref Writer writer) {
			cb(writer);
		})));

CString withWriter(ref Alloc alloc, in void delegate(scope ref Writer writer) @safe @nogc pure nothrow cb) {
	scope Writer writer = Writer(&alloc);
	cb(writer);
	return finishCString(writer);
}

void writeAndVerify(
	scope ref Writer writer,
	in void delegate() @safe @nogc pure nothrow cbWrite,
	in void delegate(in string) @safe @nogc pure nothrow cbVerify,
) {
	size_t prevSize = sizeSoFar(writer.res);
	cbWrite();
	cbVerify(asTemporaryArray(writer.res)[prevSize .. $]);
}

string finish(scope ref Writer writer) =>
	finish(writer.res);

private @trusted CString finishCString(scope ref Writer writer) {
	writer ~= '\0';
	return CString(finish(writer.res).ptr);
}

string makeStringWithWriter(ref Alloc alloc, in void delegate(scope ref Writer writer) @safe @nogc pure nothrow cb) {
	scope Writer writer = Writer(&alloc);
	cb(writer);
	return finish(writer);
}
string makeStringWithWriter(T)(ref Alloc alloc, in T value) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= value;
	});

void writeHex(scope ref Writer writer, ulong a, uint minDigits = 1) {
	writeNat(writer, a, 16, minDigits);
}

void writeHex(scope ref Writer writer, long a) {
	if (a < 0)
		writer ~= '-';
	writeHex(writer, cast(ulong) (a < 0 ? -a : a));
}

void writeFloatLiteralForJS(scope ref Writer writer, double a) {
	writeFloatLiteral(writer, a, infinity: "Number.POSITIVE_INFINITY", nan: "Number.NaN");
}

void writeFloatLiteral(scope ref Writer writer, double a, in string infinity, in string nan) {
	if (a < 0) {
		writer ~= '-';
		writeFloatLiteral(writer, -a, infinity, nan);
	} else if (isNan(a))
		writer ~= nan;
	else if (a == double.infinity)
		writer ~= infinity;
	else if ((cast(double) (cast(long) a)) == a) {
		// Being careful to handle -0
		if (1.0 / a < 0)
			writer ~= '-';
		writer ~= abs(cast(long) a);
	} else {
		DecimalAndExponent de = toDecimalAndExponent(a);
		ulong dec = de.decimal;
		long exp = de.exponent;
		withBuildStackArray!(void, char)(
			(ref StackArrayBuilder!char out_) {
				while (dec != 0) {
					ulong digit = dec % 10;
					out_ ~= digitChar(digit);
					dec /= 10;
					exp++;
				}
				if (exp <= 0) {
					foreach (ulong i; 0 .. abs(exp))
						out_ ~= '0';
					out_ ~= '.';
					out_ ~= '0';
				}
				reverseInPlace(out_.asTemporaryArray);
				if (exp <= 0) {
					// did before reverse
				} else if (safeToSizeT(exp) < out_.sizeSoFar)
					out_.insertAt(safeToSizeT(exp), '.');
				else {
					foreach (size_t _; out_.sizeSoFar .. safeToSizeT(exp))
						out_ ~= '0';
				}
			},
			(scope char[] xs) {
				writer ~= xs;
			});
	}
}

private immutable struct DecimalAndExponent {
	ulong decimal;
	long exponent;
}
private DecimalAndExponent toDecimalAndExponent(double a) {
	assert(a > 0);
	double x = a;
	long power = 0;
	while (x < 1) {
		power++;
		x = a * powerOf10(power);
	}

	ulong digits = 0;
	while (!isNearInt(x) && digits < 15) {
		power++;
		x = a * powerOf10(power);
		digits++;
	}

	ulong dec = safeToUlong(cast(long) round(x));
	while (dec % 10 == 0) {
		dec /= 10;
		power--;
	}
	return DecimalAndExponent(dec, -power);
}
private bool isNearInt(double a) {
	double b = round(a);
	double diff = abs(a - b);
	double epsilon = 2.22e-16;
	return a == b || diff <= epsilon || diff <= epsilon * min(abs(a), abs(b));
}

void writeFloatLiteralForC(scope ref Writer writer, double a) {
	if (isNan(a))
		writer ~= "NAN";
	else if (a == double.infinity)
		writer ~= "INFINITY";
	else if (a == -double.infinity)
		writer ~= "-INFINITY";
	// Print simple floats as decimal
	else if ((cast(double) (cast(long) a)) == a) {
		// Being careful to handle -0
		if (1.0 / a < 0)
			writer ~= '-';
		writer ~= abs(cast(long) a);
	} else if ((cast(double) (cast(long) (a * 10.0))) == a * 10.0) {
		writer ~= cast(long) a;
		writer ~= '.';
		writer ~= (cast(long) (abs(a) * 10)) % 10;
	} else {
		ulong u = bitsOfFloat64(a);
		bool isNegative = u >> (64 - 1);
		ulong exponentPlus1023 = (u >> (64 - 1 - 11)) & ((1 << 11) - 1);
		ulong fraction = u & ((1uL << 52) - 1);
		long exponent = (cast(long) exponentPlus1023) - 1023;
		if (isNegative)
			writer ~= '-';
		writer ~= "0x1.";
		writeHex(writer, fraction, minDigits: 52 / 4);
		writer ~= 'p';
		writer ~= exponent;
	}
}

private void writeNat(scope ref Writer writer, ulong n, ulong base = 10, uint minDigits = 1) {
	assert(minDigits != 0);
	if (n >= base || minDigits > 1)
		writeNat(writer, n / base, base, max(minDigits - 1, 1));
	writer ~= digitChar(n % base);
}

char digitChar(ulong digit) {
	assert(digit < 16);
	return digit < 10 ? cast(char) ('0' + digit) : cast(char) ('a' + (digit - 10));
}

void writeWithCommas(T)(scope ref Writer writer, in T[] a) {
	writeWithCommas!T(writer, a, (in T x) {
		writer ~= x;
	});
}

void writeWithCommas(T)(scope ref Writer writer, in T[] a, in void delegate(in T) @safe @nogc pure nothrow cb) {
	writeWithSeparator!T(writer, a, ", ", cb);
}

void writeWithCommasAndAnd(T)(scope ref Writer writer, in T[] a, in void delegate(in T) @safe @nogc pure nothrow cb) {
	if (a.length == 2) {
		cb(a[0]);
		writer ~= " and ";
		cb(a[1]);
	} else {
		foreach (size_t i; 0 .. a.length) {
			if (i != 0) {
				writer ~= ", ";
				if (i == a.length - 1)
					writer ~= "and ";
			}
			cb(a[i]);
		}
	}
}

void writeWithCommasCompact(T)(scope ref Writer writer, in T[] a) {
	writeWithCommasCompact!T(writer, a, (in T x) {
		writer ~= x;
	});
}
void writeWithCommasCompact(T)(scope ref Writer writer, in T[] a, in void delegate(in T) @safe @nogc pure nothrow cb) {
	writeWithSeparator!T(writer, a, ",", cb);
}

void writeWithCommas(T)(
	scope ref Writer writer,
	in T[] a,
	in bool delegate(in T) @safe @nogc pure nothrow filter,
	in void delegate(in T) @safe @nogc pure nothrow cb,
) {
	writeWithSeparatorAndFilter!T(writer, a, ", ", filter, cb);
}

void writeWithCommasZip(T, U)(
	scope ref Writer writer,
	in T[] a,
	in U[] b,
	in void delegate(in T, in U) @safe @nogc pure nothrow cb,
) {
	writeWithCommasZip!(T, U)(writer, a, b, (in T x, in U y) => true, cb);
}

void writeWithCommasZip(T, U)(
	scope ref Writer writer,
	in T[] a,
	in U[] b,
	in bool delegate(in T, in U) @safe @nogc pure nothrow filter,
	in void delegate(in T, in U) @safe @nogc pure nothrow cb,
) {
	bool needsComma = false;
	zip!(const T, const U)(a, b, (ref const T x, ref const U y) {
		if (filter(x, y)) {
			if (needsComma)
				writer ~= ", ";
			else
				needsComma = true;
			cb(x, y);
		}
	});
}

void writeWithSpaces(T)(scope ref Writer writer, in T[] a, in void delegate(in T) @safe @nogc pure nothrow cb) {
	writeWithSeparator!T(writer, a, " ", cb);
}

void writeWithNewlines(T)(scope ref Writer writer, in T[] a, in void delegate(in T) @safe @nogc pure nothrow cb) {
	writeWithSeparator!T(writer, a, "\n", cb);
}

void writeWithSeparator(T)(
	scope ref Writer writer,
	in T[] a,
	in string separator,
	in void delegate(in T) @safe @nogc pure nothrow cb,
) {
	writeWithSeparatorAndFilter!T(writer, a, separator, (in T _) => true, cb);
}

void writeWithSeparatorAndFilter(T)(
	scope ref Writer writer,
	in T[] a,
	in string separator,
	in bool delegate(in T) @safe @nogc pure nothrow filter,
	in void delegate(in T) @safe @nogc pure nothrow cb,
) {
	bool first = true;
	foreach (size_t i, ref const T x; a)
		if (filter(x)) {
			if (first)
				first = false;
			else
				writer ~= separator;
			cb(x);
		}
}

void writeQuotedString(scope ref Writer writer, in string s) {
	writer ~= '"';
	mustUnicodeDecode(s, (dchar x) {
		writeEscapedChar_inner(writer, x);
	});
	writer ~= '"';
}
void writeQuotedString(scope ref Writer writer, in CString s) {
	writeQuotedString(writer, stringOfCString(s));
}

void writeQuotedChar(scope ref Writer writer, dchar c) {
	writer ~= '"';
	writeEscapedChar_inner(writer, c);
	writer ~= '"';
}

void writeEscapedChar(scope ref Writer writer, dchar c) {
	if (c == '\'')
		writer ~= "\\\'";
	else
		writeEscapedChar_inner(writer, c);
}

void writeEscapedChar_inner(scope ref Writer writer, dchar c, bool forC = false) {
	switch (c) {
		case '\n':
			writer ~= "\\n";
			break;
		case '\r':
			writer ~= "\\r";
			break;
		case '\t':
			writer ~= "\\t";
			break;
		case '"':
			writer ~= "\\\"";
			break;
		case '\\':
			writer ~= "\\\\";
			break;
		case '\0':
			writer ~= "\\0";
			break;
		// TODO: handle other special characters like this one
		case '\x1b':
			writer ~= "\\x1b";
			if (forC)
				// Need two adjacent concatenated strings in case the next character is a valid hex digit
				writer ~= "\"\"";
			break;
		default:
			writer ~= isValidUnicodeCharacter(c) ? c : '�';
			break;
	}
}

void writeBold(scope ref Writer writer) {
	version (Windows) { } else {
		writer ~= "\x1b[1m";
	}
}

void writeRed(scope ref Writer writer) {
	version (Windows) { } else {
		writer ~= "\x1b[31m";
	}
}

// Undo bold, color, etc
void writeReset(scope ref Writer writer) {
	version (Windows) { } else {
		writer ~= "\x1b[m";
	}
}

void writeHyperlink(
	scope ref Writer writer,
	in void delegate() @safe @nogc pure nothrow writeUrl,
	in void delegate() @safe @nogc pure nothrow writeText,
) {
	// documentation: https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
	// https://purpleidea.com/blog/2018/06/29/hyperlinks-in-gnome-terminal/
	if (canWriteHyperlink()) {
		writer ~= "\x1b]8;;";
		writeUrl();
		writer ~= "\x1b\\";
		writeText();
		writer ~= "\x1b]8;;\x1b\\";
	} else {
		writeText();
	}
}

private bool canWriteHyperlink() {
	version (Windows) {
		return false;
	} else {
		// TODO: I haven't got this to work on any terminal emulator I have installed. :(
		return false;
	}
}

void writeNewline(scope ref Writer writer, size_t indent) {
	writer ~= '\n';
	foreach (size_t _; 0 .. indent)
		writer ~= '\t';
}
