module util.symbol;

@safe @nogc nothrow:

import std.meta : staticMap;

import util.alloc.alloc : Alloc, AllocKind, MetaAlloc, newAlloc;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.col.array : lastIndexOf, only, small;
import util.col.mutArr : MutArr, mutArrSize, push;
import util.col.mutMap : mustAdd, MutMap, size;
import util.comparison : Comparison;
import util.conv : safeToUint;
import util.hash : HashCode, hashUlong;
import util.opt : force, has, Opt, optOrDefault, none, some;
import util.string :
	compareStringsAlphabetically, copyString, CString, isDecimalDigit, SmallString, smallString, stringsEqual;
import util.unicode : mustUnicodeDecode;
import util.util : assertNormalEnum, castImmutable, optEnumOfString, stringOfEnum, stripUnderscore;
import util.writer : makeStringWithWriter, withStackWriter, withWriter, writeEscapedChar, Writer;

immutable struct Symbol {
	@safe @nogc pure nothrow:
	// This is either:
	// * A short symbol, tagged with 'shortSymbolTag'
	// * An index into 'largeStrings'.
	uint value; // Public for 'switch'
	@disable this();
	private this(uint v) { value = v; }

	static Symbol fromValue(uint x) =>
		Symbol(x);

	uint asUintForTaggedUnion() =>
		value;
	static Symbol fromUintForTaggedUnion(uint value) =>
		Symbol(value);

	HashCode hash() =>
		hashUlong(value);

	void writeTo(scope ref Writer writer) {
		foreach (char x; this)
			writer ~= x;
	}

	int opApply(in int delegate(dchar) @safe @nogc pure nothrow cb) {
		if (isShortSymbol(this))
			return eachCharInShortSymbol(this, (char x) => cb(x));
		else {
			int res = 0;
			mustUnicodeDecode(asLongSymbol(this), (dchar x) {
				if (res == 0) res = cb(x);
			});
			return res;
		}
	}

	int opApply(in int delegate(char) @safe @nogc pure nothrow cb) {
		if (isShortSymbol(this))
			return eachCharInShortSymbol(this, cb);
		else {
			foreach (char x; asLongSymbol(this)) {
				int res = cb(x);
				if (res != 0) return res;
			}
			return 0;
		}
	}
}

@trusted void initSymbols(MetaAlloc* metaAlloc) {
	symbolAlloc = newAlloc(AllocKind.symbol, metaAlloc);
	foreach (string str; specialSymbols) {
		Opt!Symbol packed = tryPackShortSymbol(str);
		assert(!has(packed));
		cast(void) addLargeString(str);
	}
}

private __gshared Alloc* symbolAlloc;
private __gshared MutMap!(SmallString, Symbol) largeStringToIndex;
private __gshared MutArr!SmallString largeStringFromIndex;

private @trusted pure Symbol getSymbolFromLongString(in string value) =>
	(cast(Symbol function(in string) @safe @nogc pure nothrow) &getSymbolFromLongString_impure)(value);
private @system Symbol getSymbolFromLongString_impure(in string str) {
	Opt!Symbol value = largeStringToIndex[smallString(str)];
	return has(value) ? force(value) : addLargeString(copyString(*symbolAlloc, str));
}

private @system Symbol addLargeString(string value) {
	size_t index = mutArrSize(largeStringFromIndex);
	assert(size(largeStringToIndex) == index);
	Symbol res = Symbol(safeToUint(index));
	SmallString small = smallString(value);
	mustAdd(*symbolAlloc, largeStringToIndex, small, res);
	push(*symbolAlloc, largeStringFromIndex, small);
	return res;
}

@trusted pure string asLongSymbol(Symbol a) =>
	(cast(string function(Symbol) @safe @nogc pure nothrow) &asLongSymbol_impure)(a);
private @system string asLongSymbol_impure(Symbol a) {
	assert(isLongSymbol(a));
	return largeStringFromIndex[a.value];
}

pure:

Comparison compareSymbolsAlphabetically(in Symbol a, in Symbol b) =>
	withStringOfSymbol(a, (in string sa) =>
		withStringOfSymbol(b, (in string sb) =>
			compareStringsAlphabetically(sa, sb)));

Symbol addExtension(Symbol a, Extension extension) {
	assert(extension != Extension.other);
	return extension == Extension.none
		? a
		: makeLongSymbol((scope ref Writer writer) {
			writer ~= a;
			writeExtension(writer, extension);
		});
}

Symbol alterExtension(Symbol a, Extension newExtension) =>
	alterExtensionCb(a, (scope ref Writer writer) {
		writeExtension(writer, newExtension);
	});

void writeExtension(scope ref Writer writer, Extension a) {
	if (a != Extension.none) {
		writer ~= '.';
		writer ~= stringOfEnum(a);
	}
}

private Symbol makeSymbol(in void delegate(scope ref Writer) @safe @nogc pure nothrow cb) =>
	withStackWriter!(0x1000, Symbol)((scope ref Alloc _, scope ref Writer writer) {
		cb(writer);
	}, (in string s) => symbolOfString(s));

Symbol alterExtensionCb(Symbol a, in void delegate(scope ref Writer writer) @safe @nogc pure nothrow cb) =>
	makeSymbol((scope ref Writer writer) {
		size_t index = 0;
		size_t lastDot = size_t.max;
		foreach (char x; a) {
			if (x == '.')
				lastDot = index;
			index++;
		}

		index = 0;
		foreach (char x; a) {
			if (index < lastDot)
				writer ~= x;
			index++;
		}
		cb(writer);
	});

enum Extension {
	c,
	crow,
	dll,
	exe,
	ilk,
	js,
	json,
	lib,
	map,
	none, // ""
	obj,
	other,
	pdb,
}

Extension getExtension(Symbol a) {
	if (isShortSymbol(a))
		// Since only a long symbol can have a '.'
		return Extension.none;
	else {
		string s = asLongSymbol(a);
		Opt!size_t lastDot = lastIndexOf(s, '.');
		if (has(lastDot)) {
			Opt!Extension res = optEnumOfString!Extension(s[force(lastDot) + 1 .. $]);
			return has(res)
				? (force(res) == Extension.none ? Extension.other : force(res))
				: Extension.other;
		} else
			return Extension.none;
	}
}

bool hasExtension(Symbol a) {
	bool hasDot = false;
	foreach (char x; a)
		hasDot = hasDot || x == '.';
	return hasDot;
}

Symbol prependSet(Symbol a) =>
	optOrDefault!Symbol(tryPrefixShortSymbolWithSet(a), () =>
		prependToLongString("set-", a));

Symbol prependSetDeref(Symbol a) =>
	prependToLongString("set-deref-", a);

Symbol appendEquals(Symbol a) =>
	appendToLongString(a, "=");

private Symbol prependToLongString(in string prepend, Symbol a) =>
	makeLongSymbol((scope ref Writer writer) {
		writer ~= prepend;
		writer ~= a;
	});

private Symbol appendToLongString(Symbol a, in string append) =>
	makeLongSymbol((scope ref Writer writer) {
		writer ~= a;
		writer ~= append;
	});

Symbol concatSymbolsWithDot(Symbol a, Symbol b) =>
	makeLongSymbol((scope ref Writer writer) {
		writer ~= a;
		writer ~= '.';
		writer ~= b;
	});

Symbol addPrefixAndExtension(string prefix, Symbol b, string extension) =>
	makeLongSymbol((scope ref Writer writer) {
		writer ~= prefix;
		writer ~= b;
		writer ~= extension;
	});

Symbol symbolOfString(in string str) {
	Opt!Symbol packed = tryPackShortSymbol(str);
	return optOrDefault!Symbol(packed, () => getSymbolFromLongString(str));
}

uint symbolSize(Symbol a) =>
	isShortSymbol(a) ? shortSymbolSize(a) : safeToUint(asLongSymbol(a).length);

enum symbol(string name) = getSymbol(name);
private Symbol getSymbol(string name) {
	foreach (size_t i, string s; specialSymbols)
		if (stringsEqual(s, name))
			return Symbol(safeToUint(i));
	Opt!Symbol opt = tryPackShortSymbol(name);
	return force(opt);
}

string stringOfSymbol(ref Alloc alloc, Symbol a) =>
	isLongSymbol(a)
		? asLongSymbol(a)
		: makeStringWithWriter(alloc, (scope ref Writer writer) {
			writer ~= a;
		});

private Out withStringOfSymbol(Out)(Symbol a, in Out delegate(in string) @safe @nogc pure nothrow cb) =>
	isLongSymbol(a)
		? cb(asLongSymbol(a))
		: withBuildStackArray!(Out, char)(
			(scope ref StackArrayBuilder!char out_) {
				foreach (char x; a)
					out_ ~= x;
			},
			(scope char[] x) => cb(castImmutable(x)));
Out withCStringOfSymbol(Out)(Symbol a, in Out delegate(in CString) @safe @nogc pure nothrow cb) =>
	withBuildStackArray!(Out, char)(
		(scope ref StackArrayBuilder!char out_) {
			foreach (char x; a)
				out_ ~= x;
			out_ ~= '\0';
		},
		(scope char[] x) @trusted => cb(CString(castImmutable(x.ptr))));

CString cStringOfSymbol(ref Alloc alloc, Symbol a) =>
	withWriter(alloc, (scope ref Writer writer) {
		writer ~= a;
	});

void writeQuotedSymbol(scope ref Writer writer, Symbol a) {
	writer ~= '"';
	foreach (char x; a)
		writeEscapedChar(writer, x);
	writer ~= '"';
}

Symbol symbolOfEnum(E)(E a) {
	assertNormalEnum!E();
	static immutable Symbol[] symbols = [staticMap!(symbol, staticMap!(stripUnderscore, __traits(allMembers, E)))];
	return symbols[a];
}

Opt!E enumOfSymbol(E)(Symbol a) {
	assertNormalEnum!E();
	switch (a.value) {
		static foreach (size_t index, string member; __traits(allMembers, E))
			case symbol!(stripUnderscore!member).value:
				return some(cast(E) index);
		default:
			return none!E;
	}
}

Symbol toLowerCase(Symbol a) =>
	makeSymbol((scope ref Writer writer) {
		foreach (char x; a)
			writer ~= toLowerCase(x);
	});

// Only use for things that can't possibly be short symbols (for example, if they always have a '.')
private Symbol makeLongSymbol(in void delegate(scope ref Writer) @safe @nogc pure nothrow cb) =>
	withStackWriter!0x1000((scope ref Alloc _, scope ref Writer writer) {
		cb(writer);
	}, (in string x) => getSymbolFromLongString(x));

char toLowerCase(char a) =>
	'A' <= a && a <= 'Z'
		? cast(char) ('a' + (a - 'A'))
		: a;

private:

// Bit to be set when the symbol is short
uint shortSymbolTag() =>
	0x80000000;

size_t shortSymbolMaxChars() =>
	32 / shortSymbolBitsPerCode;

ubyte codeForLetter(char a) {
	assert('a' <= a && a <= 'z');
	return cast(ubyte) (1 + a - 'a');
}
char letterFromCode(ubyte code) {
	assert(1 <= code && code <= 26);
	return cast(char) ('a' + (code - 1));
}
ubyte codeForHyphen() => 27;
ubyte codeForUnderscore() => 28;
ubyte codeForNextIsCapitalLetter() => 29;
ubyte codeForNextIsDigit() => 30;

ubyte shortSymbolBitsPerCode() => 5;

uint setPrefix() =>
	(codeForLetter('s') << (shortSymbolBitsPerCode * 3)) |
	(codeForLetter('e') << (shortSymbolBitsPerCode * 2)) |
	(codeForLetter('t') << (shortSymbolBitsPerCode * 1)) |
	codeForHyphen;

Opt!Symbol tryPrefixShortSymbolWithSet(Symbol a) {
	if (isShortSymbol(a)) {
		uint size = shortSymbolCodeCount(a);
		return size <= (shortSymbolMaxChars - "set-".length)
			? some(Symbol(a.value | (setPrefix << (size * shortSymbolBitsPerCode))))
			: none!Symbol;
	} else
		return none!Symbol;
}

uint shortSymbolCodeCount(in Symbol a) {
	uint res;
	eachShortSymbolCodeReverse(a, (ubyte _) {
		res++;
	});
	return res;
}

uint shortSymbolSize(in Symbol a) {
	uint res;
	eachShortSymbolCodeReverse(a, (ubyte code) {
		switch (code) {
			case codeForNextIsCapitalLetter:
			case codeForNextIsDigit:
				break;
			default:
				res++;
		}
	});
	return res;
}

void eachShortSymbolCodeReverse(in Symbol a, in void delegate(ubyte code) @safe @nogc pure nothrow cb) {
	assert(isShortSymbol(a));
	ulong value = a.value & ~shortSymbolTag;
	while (value != 0) {
		cb(value & 0b11111);
		value >>= shortSymbolBitsPerCode;
	}
}

Opt!Symbol tryPackShortSymbol(in string str) {
	if (str.length <= shortSymbolMaxChars) {
		uint res = 0;
		size_t len = 0;

		void push(ulong value) {
			res = res << shortSymbolBitsPerCode;
			res |= value;
			len++;
		}

		foreach (char x; str) {
			if ('a' <= x && x <= 'z')
				push(codeForLetter(x));
			else if (x == '-')
				push(codeForHyphen);
			else if (x == '_')
				push(codeForUnderscore);
			else if (isDecimalDigit(x)) {
				push(codeForNextIsDigit);
				push(x - '0');
			} else if ('A' <= x && x <= 'Z') {
				push(codeForNextIsCapitalLetter);
				push(x - 'A');
			} else
				return none!Symbol;
		}
		return len > shortSymbolMaxChars ? none!Symbol : some(Symbol(res | shortSymbolTag));
	} else
		return none!Symbol;
}

int eachCharInShortSymbol(Symbol a, in int delegate(char) @safe @nogc pure nothrow cb) {
	assert(isShortSymbol(a));
	ulong value = a.value;
	ulong remaining = shortSymbolMaxChars;
	ubyte take() {
		ubyte res = (value >> (shortSymbolBitsPerCode * (shortSymbolMaxChars - 1))) & 0b11111;
		value = value << shortSymbolBitsPerCode;
		remaining--;
		return res;
	}

	while (remaining != 0) {
		ubyte code = take();
		int res = () {
			switch (code) {
				case 0:
					return 0;
				case codeForHyphen:
					return cb('-');
				case codeForUnderscore:
					return cb('_');
				case codeForNextIsCapitalLetter:
					return cb(cast(char) ('A' + take()));
				case codeForNextIsDigit:
					return cb(cast(char) ('0' + take()));
				default:
					return cb(letterFromCode(code));
			}
		}();
		if (res != 0)
			return res;
	}
	return 0;
}

// Public for test only
public bool isShortSymbol(Symbol a) =>
	(a.value & shortSymbolTag) != 0;

// Public for test only
public bool isLongSymbol(Symbol a) =>
	!isShortSymbol(a);

immutable string[] specialSymbols = [
	// Putting operator symbols in precedence order so `symbolPrecedence` from `parseExpr` can be efficient.
	// '-' can't be here because it's a short symbol.
	"||",
	"&&",
	"??",
	"=",
	"==",
	"!=",
	"<",
	"<=",
	">",
	">=",
	"<=>",
	"|",
	"^",
	"&",
	"~",
	"~=",
	"~~",
	"~~=",
	"..",
	"<<",
	">>",
	"+",
	"*",
	"/",
	"%",
	"**",
	"!",

	// from names in Crow code
	"array-pointer",
	"array-size",
	"as-any-mut-pointer",
	"as-fun-pointer",
	"as-future",
	"as-future-impl",
	"as-mut-array",
	"as-mut-array-impl",
	"begin-pointer",
	"bool-low-level",
	"call-fun-pointer",
	"catch-point",
	"create-record",
	"clock_gettime",
	"concrete-model",
	"console",
	"const-pointer",
	"crow-config.json",
	"cur-catch-point",
	"cur-thrown",
	"exception-low-level",
	"exponent",
	"extern-pointer",
	"extern-pointers",
	"field-pointer",
	"file://",
	"flags-members",
	"gc-root",
	"global-ctx",
	"global-init",
	"has-non-public-fields",
	"interpreter-backtrace",
	"is-big-endian",
	"is-interpreted",
	"is-single-threaded",
	"is-stack-trace-enabled",
	"local-pointer",
	"loop-continue",
	"mutAllocated",
	"mut-slice-pointer",
	"mut-slice-size",
	"number-low-level",
	"parallel",
	"parseDiagnostics",
	"per-thread-init",
	"pointer-cast-from-extern",
	"pointer-cast-to-extern",
	"pop-gc-root",
	"reference-equal",
	"reference-kind",
	"reference-from-pointer",
	"replace",
	"rethrow-current-exception",
	"round-down",
	"round-up",
	"run-fiber",
	"runtime",
	"set-cur-catch-point",
	"set-gc-root",
	"set-subscript",
	"shared-of-mut-lambda",
	"static-symbols",
	"suffix-special",
	"switch-fiber",
	"switch-fiber-initial",
	"symbol-low-level",
	"to-mut-pointer",
	"trust-as-string",
	"unsafe-bit-shift-left",
	"unsafe-bit-shift-right",
	"variant",
	"variant-member",

	// from perf
	"buildToLowProgram",
	"gccCreateProgram",
	"generateBytecode",
	"instantiateFun",
	"instantiateSpec",
	"instantiateStruct",
	"integralValues",
	"invokeCCompiler",
	"onFileChanged",
	"storageFileInfo",
	"symbolSet",

	// from names in compiled code
	"__builtin_isnan",
	"__builtin_popcountl",

	// from compile
	"vc140.pdb",

	// From JSON output
	"variant-members",

	// from LSP
	"contentChanges",
	"definitionProvider",
	"diagnosticsOnlyForUris",
	"hoverProvider",
	"initializationOptions",
	"referencesProvider",
	"renameProvider",
	"semanticTokensProvider",
	"textDocument",
	"textDocumentSync",
	"tokenModifiers",
	"unloadedUris",

	".",
	"abstract",
	"aliases",
	"alignment",
	"allInsts",
	"allocate",
	"allocated",
	"all-tests",
	"anonymous",
	"as-const",
	"atan2f",
	"atomic-bool",
	"asUintN",
	"BigInt",
	"bootstrap",
	"browser",
	"builtin",
	"built-on",
	"byAlloc",
	"byMeasure",
	"call-new",
	"call-property",
	"call-property-spread",
	"capabilities",
	"case-exprs",
	"case-values",
	"cast-immutable",
	"catch-cases",
	"catching",
	"catch-member",
	"catches",
	"changes",
	"char32",
	"character",
	"checkCall",
	"closure",
	"closure-ref",
	"collection",
	"comment",
	"commit-hash",
	"compare",
	"comparison",
	"concretize",
	"condition",
	"constant",
	"constructor",
	"containing",
	"content",
	"contents",
	"continue",
	"countAllocs",
	"countBlocks",
	"count-ones",
	"c-string-of-symbol",
	"DbgHelp",
	"d-compiler",
	"debugger",
	"default",
	"definition",
	"destruct",
	"destructure",
	"diagnostics",
	"enum-members",
	"enum-or-flags-fun",
	"exception",
	"exception-member-index",
	"exitCode",
	"exports",
	"expr-kind",
	"extern_",
	"false-branch",
	"field-index",
	"file-type",
	"finally",
	"finish-constructor",
	"first-arg",
	"first-branch",
	"first-keyword",
	"float32",
	"float64",
	"for-break",
	"force-ctx",
	"force-shared",
	"for-loop",
	"freeBlocks",
	"frontend",
	"fun-data",
	"fun-kind",
	"fun-name",
	"fun-pointers",
	"fun-util",
	"funInsts",
	"fun-mut",
	"fun-pointer",
	"fun-shared",
	"function",
	"fut-expr",
	"future-impl",
	"future-low-level",
	"gccCompile",
	"gccJit",
	"gc-safe-value",
	"generated",
	"greater",
	"has-assertions",
	"if-kind",
	"import-kind",
	"imports",
	"include",
	"includeDir",
	"infinity",
	"instanceof",
	"int16",
	"int32",
	"int64",
	"interface",
	"interpolate",
	"interpreter",
	"interpreter-uses-tail-calls",
	"intersect",
	"is-debug-build",
	"is-less",
	"isNaN",
	"is-signed",
	"is-wasm",
	"jump-to-catch",
	"js-global",
	"keyword",
	"keyword-pos",
	"library-name",
	"library-names",
	"literal",
	"loop-break",
	"lspState",
	"mallocs",
	"mappings",
	"mark-arr",
	"mark-ctx",
	"mark-root",
	"mark-visit",
	"mark-visit-fiber",
	"matched",
	"member-index",
	"member-indices",
	"member-name",
	"members",
	"_members",
	"memmove",
	"message",
	"messages",
	"method-index",
	"modifiers",
	"modules",
	"mutability",
	"mutable",
	"mut-slice",
	"mut-array",
	"mut-array-impl",
	"mut-map",
	"mut-pointer",
	"nanosleep",
	"nat16",
	"nat32",
	"nat64",
	"newName",
	"newText",
	"new-array",
	"new-mut-slice",
	"new-void",
	"node-js",
	"nominal",
	"n-parents",
	"Number",
	"Object",
	"ok-if-unused",
	"operation",
	"overflow",
	"overhead",
	"param0",
	"param1",
	"param2",
	"param3",
	"param4",
	"param5",
	"param6",
	"param7",
	"param8",
	"param9",
	"param-types",
	"parents",
	"parseFile",
	"pointee",
	"pointer",
	"pointer-cast",
	"position",
	"private",
	"process",
	"Promise",
	"pthread",
	"question-pos",
	"records",
	"reference",
	"reference-type",
	"refKeys",
	"refPairs",
	"rest-args",
	"return-type",
	"rt-main",
	"second-branch",
	"second-keyword",
	"set-deref",
	"set-n0",
	"setup-catch",
	"severity",
	"shared-array",
	"shared-map",
	"size-bytes",
	"size-of",
	"sources",
	"sourcesContent",
	"spec-impls",
	"specInsts",
	"static_",
	"string-of-symbol",
	"storage",
	"structInsts",
	"structs",
	"subscript",
	"suffix-pos",
	"supports-jit",
	"symbol-of-c-string",
	"TextDecoder",
	"TextEncoder",
	"thread-local",
	"throw-impl",
	"tokenTypes",
	"toString",
	"true-branch",
	"truncate-to",
	"trusted",
	"tuple2",
	"tuple3",
	"tuple4",
	"tuple5",
	"tuple6",
	"tuple7",
	"tuple8",
	"tuple9",
	"type-arg",
	"type-args",
	"type-index",
	"type-params",
	"Uint8Array",
	"unknownUris",
	"unsafe-add",
	"unsafe-div",
	"unsafe-log",
	"unsafe-mod",
	"unsafe-mul",
	"unsafe-pow",
	"unsafe-sub",
	"unsafe-to",
	"unsigned",
	"updates",
	"user-main",
	"re-exports",
	"ucrtbase",
	"variadic",
	"variant-member-get",
	"variants",
	"var-kind",
	"version",
	"visibility",
	"windows",
	"with-block",
	"wrap-add",
	"wrap-mul",
	"wrap-sub",
];
