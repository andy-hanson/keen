module util.json;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.col.array : arraysEqual, concatenateIn, copyArray, every, exists, find, isEmpty, map, newArray, SmallArray;
import util.col.fullIndexMap : FullIndexMap;
import util.col.hashTable : HashTable, withSortedKeys;
import util.col.map : KeyValuePair;
import util.comparison : Comparison;
import util.opt : force, has, Opt;
import util.string : copyString, CString, stringsEqual, stringOfCString;
import util.symbol : Symbol, symbol, writeQuotedSymbol;
import util.union_ : Union;
import util.writer :
	makeStringWithWriter,
	withWriter,
	writeFloatLiteral,
	Writer,
	writeQuotedString,
	writeWithCommasCompact,
	writeWithSeparator;

immutable struct Json {
	@safe @nogc pure nothrow:

	immutable struct Null {}
	alias List = immutable Json[];
	alias ObjectField = immutable KeyValuePair!(Symbol, Json);
	alias Object = immutable ObjectField[];
	// string and Symbol cases should be treated as equivalent.
	mixin Union!(
		Null,
		bool,
		double,
		string,
		Symbol,
		SmallArray!Json,
		SmallArray!ObjectField);

	// Distinguishes CString / string / Symbol. Use only for tests.
	bool opEquals(in Json b) scope =>
		matchIn!bool(
			(in Null _) =>
				b.isA!Null,
			(in bool x) =>
				b.isA!bool && b.as!bool == x,
			(in double x) =>
				b.isA!double && b.as!double == x,
			(in string x) =>
				b.isA!string && stringsEqual(x, b.as!string),
			(in Symbol x) =>
				b.isA!Symbol && x == b.as!Symbol,
			(in Json[] x) =>
				b.isA!(Json[]) && arraysEqual!Json(x, b.as!(Json[])),
			(in Json.Object oa) =>
				b.isA!Object && arraysEqual(oa, b.as!Object));

	void writeTo(scope ref Writer writer) scope {
		writeJson(writer, this);
	}
}

Json get(string key)(in Json a) {
	Opt!(Json.ObjectField) pair = find!(Json.ObjectField)(a.as!(Json.Object), (in Json.ObjectField pair) =>
		pair.key == symbol!key);
	return has(pair) ? force(pair).value : jsonNull;
}
bool hasKey(string key)(in Json a) =>
	a.isA!(Json.Object) && exists!(Json.ObjectField)(a.as!(Json.Object), (in Json.ObjectField pair) =>
		pair.key == symbol!key);

Json jsonObject(return scope Json.ObjectField[] fields) =>
	Json(fields);
Json jsonObject(ref Alloc alloc, in Json.ObjectField[] fields) =>
	jsonObject(copyArray(alloc, fields));

// TODO: should be possible to concatenate in the caller (assuming array sizes are compile-time constants).
// But a D bug prevents this: https://issues.dlang.org/show_bug.cgi?id=1654
Json jsonObject(ref Alloc alloc, in Json.ObjectField[] fields1, in Json.ObjectField[] fields2) =>
	jsonObject(alloc, concatenateIn!(Json.ObjectField)(alloc, fields1, fields2));

Json jsonBool(bool b) =>
	Json(b);

Json jsonNull() =>
	Json(Json.Null());

Json.ObjectField optionalField(string name)(bool isPresent, in Json delegate() @safe @nogc pure nothrow cb) =>
	field!name(isPresent ? cb() : jsonNull);

Json.ObjectField optionalField(string name)(in Opt!uint a) =>
	field!name(has(a) ? Json(force(a)) : jsonNull);
Json.ObjectField optionalField(string name)(in Opt!string a) =>
	field!name(has(a) ? jsonString(force(a)) : jsonNull);
Json.ObjectField optionalField(string name, T)(Opt!T a, in Json delegate(T) @safe @nogc pure nothrow cb) =>
	field!name(has(a) ? cb(force(a)) : jsonNull);
Json.ObjectField optionalField(string name, T)(in Opt!T a, in Json delegate(in T) @safe @nogc pure nothrow cb) =>
	field!name(has(a) ? cb(force(a)) : jsonNull);

Json.ObjectField optionalFlagField(string name)(bool value) =>
	field!name(value ? jsonBool(true) : jsonNull);

Json.ObjectField optionalArrayField(string name)(Json[] array) =>
	optionalField!name(!isEmpty(array), () => jsonList(array));
Json.ObjectField optionalArrayField(string name, T)(
	ref Alloc alloc,
	in T[] array,
	in Json delegate(in T) @safe @nogc pure nothrow cb,
) =>
	optionalField!name(!isEmpty(array), () =>
		jsonList(map!(Json, const T)(alloc, array, (ref const T x) => cb(x))));

Json.ObjectField kindField(string kindName)() =>
	.kindField(kindName);
Json.ObjectField kindField(string kindName) =>
	field!"kind"(kindName);

Json jsonList(Json[] xs) =>
	Json(xs);
Json jsonList(ref Alloc alloc, in Json[] xs) =>
	Json(newArray(alloc, xs));
Json jsonList(T)(ref Alloc alloc, in T[] xs, in Json delegate(in T) @safe @nogc pure nothrow cb) =>
	jsonList(map!(Json, const T)(alloc, xs, (ref const T x) => cb(x)));

Json jsonList(K, V)(
	ref Alloc alloc,
	in immutable FullIndexMap!(K, V) a,
	in Json delegate(in V) @safe @nogc pure nothrow cb,
) =>
	.jsonList!V(alloc, a.values, cb);

Json jsonListOfKeys(T, K, alias getKey)(
	ref Alloc alloc,
	in HashTable!(T, K, getKey) a,
	in Comparison delegate(in K, in K) @safe @nogc pure nothrow cbCompare,
	in Json delegate(in K) @safe @nogc pure nothrow cb,
) =>
	withSortedKeys!(Json, T, K, getKey)(a, cbCompare, (in K[] keys) =>
		jsonList!K(alloc, keys, cb));

Json jsonInt(long a) =>
	Json(a);

Json jsonString(string a) =>
	Json(a);

Json jsonString(ref Alloc alloc, in string a) =>
	jsonString(copyString(alloc, a));

Json jsonString(Symbol a) =>
	Json(a);

Json jsonString(string a)() =>
	jsonString(a);

Json.ObjectField field(string name)(return scope Json value) =>
	Json.ObjectField(symbol!name, value);
Json.ObjectField field(string name)(double value) =>
	field!name(Json(value));
Json.ObjectField field(string name)(bool value) =>
	field!name(Json(value));
Json.ObjectField field(string name)(CString value) =>
	field!name(stringOfCString(value));
Json.ObjectField field(string name)(string value) =>
	field!name(Json(value));
Json.ObjectField field(string name)(Symbol value) =>
	field!name(Json(value));

CString jsonToCString(ref Alloc alloc, in Json a) =>
	withWriter(alloc, (scope ref Writer writer) {
		writer ~= a;
	});

string jsonToString(ref Alloc alloc, in Json a) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= a;
	});

private void writeJson(ref Writer writer, in Json a) =>
	a.matchIn!void(
		(in Json.Null _) {
			writer ~= "null";
		},
		(in bool x) {
			writer ~= x ? "true" : "false";
		},
		(in double x) {
			writeFloatLiteral(writer, x, infinity: "null", nan: "null");
		},
		(in string x) {
			writeQuotedString(writer, x);
		},
		(in Symbol x) {
			writeQuotedSymbol(writer, x);
		},
		(in Json[] x) {
			writer ~= '[';
			writeWithCommasCompact!Json(writer, x);
			writer ~= ']';
		},
		(in Json.Object x) {
			writeObjectCompact!Symbol(writer, x, (in Symbol key) {
				writeQuotedSymbol(writer, key);
			});
		});

void writeJsonPretty(ref Writer writer, in Json a, in uint indent) {
	if (a.isA!(Json[])) {
		bool singleLine = every!Json(a.as!(Json[]), (in Json x) => isPrimitive(x));
		writer ~= '[';
		writeWithSeparator!Json(writer, a.as!(Json[]), singleLine ? ", " : ",", (in Json x) {
			if (!singleLine) writeNewlineAndIndent(writer, indent + 1);
			writeJsonPretty(writer, x, indent + 1);
		});
		if (!singleLine) writeNewlineAndIndent(writer, indent);
		writer ~= ']';
	} else if (a.isA!(Json.Object)) {
		bool singleLine = every!(Json.ObjectField)(a.as!(Json.Object), (in Json.ObjectField x) =>
			isPrimitive(x.value));
		writer ~= '{';
		string comma = singleLine ? ", " : ",";
		writeWithSeparator!(Json.ObjectField)(writer, a.as!(Json.Object), comma, (in Json.ObjectField pair) {
			if (!singleLine) writeNewlineAndIndent(writer, indent + 1);
			writeQuotedSymbol(writer, pair.key);
			writer ~= ": ";
			writeJsonPretty(writer, pair.value, indent + 1);
		});
		if (!singleLine) writeNewlineAndIndent(writer, indent);
		writer ~= '}';
	} else
		writer ~= a;
}

private:

void writeObjectCompact(K)(
	ref Writer writer,
	in KeyValuePair!(K, Json)[] pairs,
	in void delegate(in K) @safe @nogc pure nothrow writeKey,
) {
	writer ~= '{';
	writeWithCommasCompact!(KeyValuePair!(K, Json))(writer, pairs, (in KeyValuePair!(K, Json) pair) {
		writeKey(pair.key);
		writer ~= ':';
		writer ~= pair.value;
	});
	writer ~= '}';
}

void writeNewlineAndIndent(ref Writer writer, in uint indent) {
	writer ~= '\n';
	foreach (uint i; 0 .. indent)
		writer ~= '\t';
}

bool isPrimitive(in Json a) =>
	!a.isA!(Json[]) && !a.isA!(Json.Object);
