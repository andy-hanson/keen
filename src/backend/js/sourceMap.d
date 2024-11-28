module backend.js.sourceMap;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.cell : Cell, cellGet, cellSet;
import util.col.map : Map, mustGet;
import util.col.mutArr : findIndexOrPush, moveToArray, MutArr;
import util.comparison : Comparison;
import util.conv : safeToInt, safeToUint;
import util.json : field, jsonList, jsonObject, jsonString, jsonToString;
import util.opt : Opt;
import util.sourceRange : compareLineAndCharacter, FileContentGetters, LineAndCharacter;
import util.symbol : Extension, Symbol, symbol;
import util.uri : alterExtension, Path, stringOfPath, Uri;
import util.util : abs;
import util.writer : finish, Writer;

immutable struct JsAndMap {
	string js;
	Opt!string map;
}
immutable struct ModulePaths {
	@safe @nogc pure nothrow:
	Map!(Uri, Path) crowPaths;

	Path crowPath(Uri uri) scope =>
		mustGet(crowPaths, uri);
	Path jsPath(Uri uri) scope =>
		alterExtension(crowPath(uri), Extension.js);
}

// https://docs.google.com/document/d/1U1RGAehQwRypUTovF1KRlpiOFze0b-_2gc6fAH0KY0k/edit?pli=1
struct SourceMapBuilder {
	@safe @nogc pure nothrow:
	private:
	Writer mappings;
	MutArr!Uri sources;
	MutArr!Symbol names;

	public ref Alloc alloc() return scope =>
		mappings.alloc;

	Cell!SingleSourceMapping prev = Cell!SingleSourceMapping(SingleSourceMapping(Source(Uri.empty, symbol!"")));
	uint prevSourceUriIndex;
	uint prevSourceNameIndex;

	void opOpAssign(string op : "~")(in SingleSourceMapping x) scope {
		add(this, x);
	}
}
string finish(SourceMapBuilder a, in FileContentGetters files, in ModulePaths modulePaths) {
	Uri[] sources = moveToArray(a.alloc, a.sources);
	return jsonToString(a.alloc, jsonObject(a.alloc, [
		field!"version"(3),
		field!"sources"(jsonList!Uri(a.alloc, sources, (in Uri source) =>
			jsonString(stringOfPath(a.alloc, modulePaths.crowPath(source))))),
		field!"sourcesContent"(jsonList!Uri(a.alloc, sources, (in Uri source) =>
			jsonString(files[source]))),
		field!"names"(jsonList!Symbol(a.alloc, moveToArray(a.alloc, a.names), (in Symbol name) =>
			jsonString(name))),
		field!"mappings"(finish(a.mappings))]));
}

immutable struct Source {
	Uri uri;
	Symbol name; // E.g. a function name
	LineAndCharacter pos;
}

immutable struct SingleSourceMapping {
	Source source;
	LineAndCharacter outPos;
}

private:

void add(scope ref SourceMapBuilder a, in SingleSourceMapping mapping) {
	SingleSourceMapping prev = cellGet(a.prev);
	if (mapping.source == prev.source) return;

	assert(compareLineAndCharacter(prev.outPos, mapping.outPos) != Comparison.greater);

	void outVLQ(int value) {
		writeBase64VLQ(a.mappings, value);
	}

	foreach (uint _; prev.outPos.line .. mapping.outPos.line)
		a.mappings ~= ';';

	if (prev.outPos.line == mapping.outPos.line) {
		if (prev.source.uri != Uri.empty)
			a.mappings ~= ',';
		outVLQ(mapping.outPos.character);
	} else
		outVLQ(mapping.outPos.character);

	if (prev.source.uri != mapping.source.uri ||
		prev.source.name != mapping.source.name ||
		prev.source.pos != mapping.source.pos) {

		// As an optimization, check if it's the same URI as last time
		if (prev.source.uri == mapping.source.uri)
			outVLQ(0);
		else {
			uint uriIndex = safeToUint(findIndexOrPush(a.alloc, a.sources, mapping.source.uri));
			outVLQ(safeToInt(uriIndex) - a.prevSourceUriIndex);
			a.prevSourceUriIndex = uriIndex;
		}

		outVLQ(safeToInt(mapping.source.pos.line) - safeToInt(prev.source.pos.line));
		outVLQ(safeToInt(mapping.source.pos.character) - safeToInt(prev.source.pos.character));

		if (prev.source.name == mapping.source.name)
			outVLQ(0);
		else {
			uint nameIndex = safeToUint(findIndexOrPush(a.alloc, a.names, mapping.source.name));
			outVLQ(safeToInt(nameIndex) - a.prevSourceNameIndex);
			a.prevSourceNameIndex = nameIndex;
		}
	}

	cellSet(a.prev, mapping);
}

public void writeBase64VLQ(scope ref Writer writer, int value) {
	bool signBit = value < 0;
	ulong valueRemaining = ulong(abs(value) << 1) | signBit;
	do {
		ubyte code = valueRemaining & 0b11111;
		valueRemaining >>= 5;
		writer ~= base64Char((valueRemaining == 0 ? 0 : 0b100000) | code);
	} while (valueRemaining != 0);
}

char base64Char(ubyte number) {
	assert((number & 0b111111) == number);
	return base64Chars[number];
}

immutable char[] base64Chars =
	"ABCDEFGHIJKLMNOP" ~
	"QRSTUVWXYZabcdef" ~
	"ghijklmnopqrstuv" ~
	"wxyz0123456789+/";
