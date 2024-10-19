module util.uri;

@safe @nogc nothrow: // not pure

import util.alloc.alloc : Alloc, AllocKind, MetaAlloc, newAlloc;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.cell : Cell, cellGet, cellSet;
import util.col.array : applyNTimes, fold, indexOf, indexOfStartingAt, isEmpty, reverseInPlace, sum;
import util.col.mutArr : MutArr, mutArrSize, push;
import util.comparison : Comparison;
import util.conv : uintOfUshorts, ushortsOfUint, safeToUshort;
import util.hash : HashCode;
import util.opt : has, force, none, Opt, optIf, optOrDefault, some;
import util.string :
	compareStringsNaturally,
	CString,
	decodeHexDigit,
	done,
	isAsciiIdentifierChar,
	next,
	nextOrDefault,
	StringIter,
	stringOfCString;
import util.symbol :
	addExtension,
	alterExtension,
	alterExtensionCb,
	asLongSymbol,
	Extension,
	getExtension,
	hasExtension,
	isLongSymbol,
	Symbol,
	symbol,
	symbolOfString,
	symbolSize,
	toLowerCase,
	writeExtension;
import util.util : min, todo, typeAs;
import util.writer : digitChar, makeStringWithWriter, withStackWriter, withStackWriterImpureCString, withWriter, Writer;

T withCStringOfFilePath(T)(FilePath path, in T delegate(in CString) @safe @nogc nothrow cb) =>
	withStackWriterImpureCString!(T, 0x1000)((scope ref Writer writer) {
		writer ~= path;
	}, cb);

// Root path at index 0 will have children, but they won't have it as a parent
private __gshared Alloc* uriAlloc;
private __gshared MutArr!(Opt!Path) pathToParent;
private __gshared MutArr!Symbol pathToBaseName;
private __gshared MutArr!(MutArr!Path) pathToChildren;
private __gshared MutArr!PathInfo pathToInfo;

@trusted void initUris(MetaAlloc* metaAlloc) {
	uriAlloc = newAlloc(AllocKind.uri, metaAlloc);
	// 0 must be the empty URI
	push(*uriAlloc, pathToParent, none!Path);
	push(*uriAlloc, pathToBaseName, symbol!"");
	push(*uriAlloc, pathToChildren, MutArr!Path());
	push(*uriAlloc, pathToInfo, PathInfo(false, false));
}

private @trusted pure Path getOrAddChild(ref MutArr!Path children, Opt!Path parent, Symbol namePre, PathInfo info) =>
	(cast(Path function(ref MutArr!Path, Opt!Path, Symbol, PathInfo) @safe @nogc pure nothrow) &getOrAddChild_impure)(
		children, parent, namePre, info);
private @trusted Path getOrAddChild_impure(ref MutArr!Path children, Opt!Path parent, Symbol namePre, PathInfo info) {
	Symbol name = info.isWindowsPath ? toLowerCase(namePre) : namePre;
	foreach (Path child; children)
		if (baseName(child) == name)
			return child;

	Path res = Path(safeToUshort(mutArrSize(pathToParent)));
	push(*uriAlloc, children, res);
	push(*uriAlloc, pathToParent, parent);
	push(*uriAlloc, pathToBaseName, name);
	push(*uriAlloc, pathToChildren, MutArr!Path());
	push(*uriAlloc, pathToInfo, info);
	return res;
}

pure Path rootPathPlain(Symbol name) =>
	rootPath(name, PathInfo(isUriFile: false, isWindowsPath: false));
private @trusted pure Path rootPath(Symbol name, PathInfo info) =>
	(cast(Path function(Symbol, PathInfo) @safe @nogc pure nothrow) &rootPath_impure)(name, info);
private @system Path rootPath_impure(Symbol name, PathInfo info) =>
	getOrAddChild(pathToChildren[Path.empty.index], none!Path, name, info);

private @trusted pure Path childPathWithInfo(Path parent, Symbol name, PathInfo info) =>
	(cast(Path function(Path, Symbol, PathInfo) @safe @nogc pure nothrow) &childPathWithInfo_impure)(
		parent, name, info);
private @system Path childPathWithInfo_impure(Path parent, Symbol name, PathInfo info) {
	assert(name != symbol!".." && name != symbol!".");
	return getOrAddChild(pathToChildren[parent.index], some(parent), name, info);
}

private @trusted pure PathInfo pathInfo(Path a) =>
	(cast(PathInfo function(Path) @safe @nogc pure nothrow) &pathInfo_impure)(a);
private @system PathInfo pathInfo_impure(Path a) =>
	pathToInfo[a.index];

@trusted pure Opt!Path parent(Path a) =>
	(cast(Opt!Path function(Path) @safe @nogc pure nothrow) &parent_impure)(a);
private @system Opt!Path parent_impure(Path a) =>
	pathToParent[a.index];

@trusted pure bool uriIsFile(Uri a) =>
	(cast(bool function(Uri) @safe @nogc pure nothrow) &uriIsFile_impure)(a);
private @system bool uriIsFile_impure(Uri a) =>
	pathToInfo[a.path.index].isUriFile;

@trusted pure Symbol baseName(Path a) =>
	(cast(Symbol function(Path) @safe @nogc pure nothrow) &baseName_impure)(a);
private @system Symbol baseName_impure(Path a) =>
	pathToBaseName[a.index];

pure:

// This information could be derived from the first two components, but this is easier
private immutable struct PathInfo {
	// First component is 'file://'
	bool isUriFile;
	// First component is 'c:' (or 'd:' etc), or first component is 'file://' and second component is 'c:'.
	// If so, all components will be converted to lower-case to enforce case-insensitivity.
	bool isWindowsPath;
}

// Uniform Resource Identifier ; does not support query or fragment.
immutable struct Uri {
	@safe @nogc pure nothrow:

	// The first component is the scheme + authority packed into a Symbol
	private Path path;

	Path pathIncludingScheme() =>
		path;

	static Uri empty() =>
		Uri(Path.empty);

	HashCode hash() =>
		path.hash();

	uint asUintForHash() =>
		path.asUintForTaggedUnion;
	uint asUintForTaggedUnion() =>
		path.asUintForTaggedUnion;
	static Uri fromUintForTaggedUnion(uint a) =>
		Uri(Path.fromUintForTaggedUnion(a));

	void writeTo(scope ref Writer writer) {
		writePath(writer, path, uriEncode: true);
	}

	Uri opBinary(string op : "/")(Symbol name) =>
		Uri(path / name);
}

private bool isRootUri(Uri a) =>
	!has(parent(a));

private Symbol fileScheme() =>
	symbol!"file://";

FilePath asFilePath(Uri a) {
	assert(uriIsFile(a));
	return withComponents(a.path, (in Symbol[] components) {
		assert(components[0] == fileScheme);
		return FilePath(descendentPath(
			rootPath(components[1], PathInfo(isUriFile: true, isWindowsPath(a))),
			components[2 .. $]));
	});
}

// Uri that is restricted to be a 'file:'
immutable struct FilePath {
	@safe @nogc pure nothrow:
	// Unlike for a Uri, this doesn't have "file" as the first component
	Path path;

	void writeTo(scope ref Writer writer) {
		if (!isWindowsPath(this))
			writer ~= '/';
		writePath(writer, path);
	}

	FilePath opBinary(string op : "/")(Symbol name) =>
		FilePath(path / name);
}
FilePath rootFilePath(Symbol firstComponent) =>
	FilePath(rootPath(firstComponent, PathInfo(isUriFile: false, isWindowsPath: isWindowsPathStart(firstComponent))));

Uri toUri(FilePath a) =>
	concatUriAndPath(
		Uri(rootPath(fileScheme, PathInfo(isUriFile: true, isWindowsPath: isWindowsPath(a)))),
		a.path);

// Represents the path part of a URI, e.g. 'a/b/c'
immutable struct Path {
	@safe @nogc pure nothrow:

	private ushort index;

	static Path empty() =>
		Path(0);

	HashCode hash() =>
		HashCode(index);

	uint asUintForTaggedUnion() =>
		index;
	static Path fromUintForTaggedUnion(uint a) =>
		Path(safeToUshort(a));

	Path opBinary(string op : "/")(Symbol name) =>
		childPathWithInfo(this, name, pathInfo(this));

	void writeTo(scope ref Writer writer) {
		writePath(writer, this);
	}
}

Opt!Uri parent(Uri a) {
	Opt!Path res = parent(a.path);
	return has(res) ? some(Uri(force(res))) : none!Uri;
}
Opt!FilePath parent(FilePath a) {
	Opt!Path res = parent(a.path);
	return has(res) ? some(FilePath(force(res))) : none!FilePath;
}
Uri parentOrEmpty(Uri a) =>
	optOrDefault!Uri(parent(a), () => a);
FilePath parentOrEmpty(FilePath a) =>
	optOrDefault!FilePath(parent(a), () => a);
Path parentOrEmpty(Path a) =>
	optOrDefault!Path(parent(a), () => a);

private Uri firstNComponents(Uri a, size_t n) =>
	Uri(firstNComponents(a.path, n));
private Path firstNComponents(Path a, size_t n) {
	size_t count = countComponents(a);
	assert(count >= n);
	Path res = applyNTimes!Path(a, count - n, (Path x) => force(parent(x)));
	assert(countComponents(res) == n);
	return res;
}

// Removes an existing extension and adds a new one.
Uri alterExtension(Uri a, Extension newExtension) =>
	Uri(alterExtension(a.path, newExtension));
FilePath alterExtension(FilePath a, Extension newExtension) =>
	FilePath(alterExtension(a.path, newExtension));
private Path alterExtension(Path a, Extension newExtension) =>
	modifyBaseName(a, (Symbol name) =>
		.alterExtension(name, newExtension));

// Adds an extension after any already existing extension.
Uri addExtension(Uri a, Extension extension) =>
	Uri(addExtension(a.path, extension));
FilePath addExtension(FilePath a, Extension extension) =>
	FilePath(addExtension(a.path, extension));
private Path addExtension(Path a, Extension extension) =>
	modifyBaseName(a, (Symbol name) =>
		addExtension(name, extension));

// E.g., changes 'foo.crow' to 'foo.deadbeef.c'
FilePath alterExtensionWithHex(FilePath a, in ubyte[] bytes, Extension newExtension) =>
	FilePath(modifyBaseName(a.path, (Symbol name) =>
		alterExtensionCb(name, (scope ref Writer writer) {
			writer ~= '.';
			foreach (ubyte x; bytes) {
				writer ~= digitChar(x / 16);
				writer ~= digitChar(x % 16);
			}
			writeExtension(writer, newExtension);
		})));

private bool hasExtension(Path a) =>
	hasExtension(baseName(a));

private Path modifyBaseName(Path a, in Symbol delegate(Symbol) @safe @nogc pure nothrow cb) {
	Symbol newBaseName = cb(baseName(a));
	Opt!Path parent = parent(a);
	return has(parent)
		? force(parent) / newBaseName
		: rootPath(newBaseName, pathInfo(a));
}

// This will either be "" or start with a "."
Extension getExtension(Uri a) =>
	isRootUri(a)
		? Extension.none
		: getExtension(a.path);
Extension getExtension(FilePath a) =>
	getExtension(a.path);
Extension getExtension(Path a) =>
	getExtension(baseName(a));

Symbol baseName(Uri a) =>
	isRootUri(a) ? symbol!"" : baseName(a.path);
Symbol baseName(FilePath a) =>
	baseName(a.path);

immutable struct PathFirstAndRest {
	Symbol first;
	Opt!Path rest;
}

PathFirstAndRest firstAndRest(Path a) {
	Opt!Path par = parent(a);
	Symbol baseName = baseName(a);
	if (has(par)) {
		PathFirstAndRest parentRes = firstAndRest(force(par));
		Path rest = has(parentRes.rest)
			? force(parentRes.rest) / baseName
			: rootPathPlain(baseName);
		return PathFirstAndRest(parentRes.first, some(rest));
	} else
		return PathFirstAndRest(baseName, none!Path);
}

bool isWindowsPath(Uri a) =>
	isWindowsPath(a.path);
bool isWindowsPath(FilePath a) =>
	isWindowsPath(a.path);
bool isWindowsPath(Path a) =>
	pathInfo(a).isWindowsPath;

Uri bogusUri() =>
	mustParseUri("bogus:bogus");

private Path descendentPath(Path parent, in Symbol[] childComponentNames) =>
	fold!(Path, Symbol)(parent, childComponentNames, (Path acc, in Symbol component) => acc / component);

immutable struct RelPath {
	@safe @nogc pure nothrow:

	ushort nParents;
	Path path;

	uint asUintForTaggedUnion() =>
		uintOfUshorts([nParents, path.index]);
	static RelPath fromUintForTaggedUnion(uint a) {
		ushort[2] xs = ushortsOfUint(a);
		return RelPath(xs[0], Path(xs[1]));
	}

	void writeTo(scope ref Writer writer) {
		if (nParents == 0)
			writer ~= "./";
		foreach (ushort i; 0 .. nParents)
			writer ~= "../";
		writer ~= path;
	}
}

Opt!Uri resolveUri(Uri base, RelPath relPath) {
	Opt!Path res = resolvePath(base.path, relPath);
	return optIf(has(res), () => Uri(force(res)));
}

private Opt!Path resolvePath(Path base, RelPath relPath) {
	if (relPath.nParents == 0)
		return some(concatPaths(base, relPath.path));
	else {
		Opt!Path par = parent(base);
		return has(par)
			? resolvePath(force(par), RelPath(cast(ushort) (relPath.nParents - 1), relPath.path))
			: none!Path;
	}
}

Uri concatUriAndPath(Uri a, Path b) =>
	withComponents(b, (in Symbol[] components) =>
		Uri(descendentPath(a.path, components)));
private Path concatPaths(Path a, Path b) =>
	withComponents(b, (in Symbol[] components) =>
		descendentPath(a, components));
FilePath concatFilePathAndPath(FilePath a, Path b) =>
	withComponents(b, (in Symbol[] components) =>
		FilePath(descendentPath(a.path, components)));

size_t countComponents(Uri a) =>
	countComponents(a.path);
size_t countComponents(Path a) =>
	countComponentsRecur(0, a);
private size_t countComponentsRecur(size_t acc, Path a) {
	Opt!Path parent = parent(a);
	return has(parent) ? countComponentsRecur(acc + 1, force(parent)) : acc + 1;
}

T withComponents(T)(Path a, in T delegate(in Symbol[]) @safe @nogc pure nothrow cb) =>
	withComponentsPreferRelative!T(none!Path, a, (bool isRelative, in Symbol[] components) {
		assert(!isRelative);
		return cb(components);
	});

private T withComponentsPreferRelative(T)(
	in Opt!Path cwd,
	Path a,
	in T delegate(bool isRelative, in Symbol[]) @safe @nogc pure nothrow cb,
) {
	bool isRelative = false;
	return withBuildStackArray!(T, Symbol)(
		(ref StackArrayBuilder!Symbol stack) {
			Cell!Path cur = Cell!Path(a);
			while (true) {
				stack ~= baseName(cellGet(cur));
				Opt!Path par = parent(cellGet(cur));
				if (!has(par))
					break;
				else if (has(cwd) && force(cwd) == force(par)) {
					isRelative = true;
					break;
				} else {
					cellSet(cur, force(par));
					continue;
				}
			}
		},
		(scope Symbol[] stack) {
			reverseInPlace(stack);
			return cb(isRelative, stack);
		});
}

size_t pathLength(Path path) =>
	withComponents(path, (in Symbol[] components) {
		assert(!isEmpty(components));
		size_t slashes = components.length - 1;
		return sum!Symbol(components, (in Symbol component) => symbolSize(component)) + slashes;
	});

CString cStringOfUriPreferRelative(ref Alloc alloc, in UrisInfo urisInfo, Uri a) =>
	withWriter(alloc, (scope ref Writer writer) {
		writeUriPreferRelative(writer, urisInfo, a);
	});
string stringOfUri(ref Alloc alloc, Uri a) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= a;
	});
string stringOfFilePath(ref Alloc alloc, FilePath a) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= a;
	});

private T withStringOfUri(T)(Uri a, in T delegate(in string) @safe @nogc pure nothrow cb) =>
	withStackWriter!(0x1000, T)((scope ref Alloc _, scope ref Writer writer) {
		writer ~= a;
	}, cb);

Symbol symbolOfUri(Uri a) =>
	withStringOfUri(a, (in string x) => symbolOfString(x));

CString cStringOfFilePath(ref Alloc alloc, FilePath a) =>
	withWriter(alloc, (scope ref Writer writer) {
		writer ~= a;
	});
string stringOfPath(ref Alloc alloc, Path a) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writePath(writer, a);
	});

public CString cStringOfUriPreferRelative(ref Alloc alloc, ref UrisInfo urisInfo, Uri a) =>
	withWriter(alloc, (scope ref Writer writer) {
		writeUriPreferRelative(writer, urisInfo, a);
	});

Uri mustParseUri(in string str) {
	Opt!Uri res = parseUri(str);
	return force(res);
}
private Opt!Uri parseUri(in CString str) =>
	parseUri(stringOfCString(str));
private Opt!Uri parseUri(in string uri) {
	Opt!size_t optColon = indexOf(uri, ':');
	if (has(optColon)) {
		size_t colon = force(optColon);
		size_t start = colon < uri.length - 2 && uri[colon + 1] == '/' && uri[colon + 2] == '/' ? colon + 3 : colon + 1;
		Opt!size_t slash = indexOfStartingAt(uri, '/', start);
		if (has(slash)) {
			Uri root = rootUri(uri[0 .. force(slash)]);
			return some(Uri(parsePathInner(
				uri[force(slash) + 1 .. $],
				ParsePathOptions(uriDecode: true, isUriFile: uriIsFile(root)),
				(Symbol rootSymbol) =>
					childPathWithInfo(root.path, rootSymbol, PathInfo(
						isUriFile: uriIsFile(root),
						isWindowsPath: isWindowsPathStart(rootSymbol))))));
		} else
			return some(rootUri(uri));
	} else
		return none!Uri;
}
private Uri rootUri(in string schemeAndAuthority) {
	Symbol schemeSymbol = symbolOfString(schemeAndAuthority);
	return Uri(rootPath(schemeSymbol, PathInfo(isUriFile: schemeSymbol == fileScheme, isWindowsPath: false)));
}

Path parsePath(in string str) =>
	parsePathInner(str, ParsePathOptions(uriDecode: false, isUriFile: false), (Symbol rootSymbol) =>
		rootPath(rootSymbol, PathInfo(isUriFile: false, isWindowsPath: false)));
private immutable struct ParsePathOptions {
	bool uriDecode;
	bool isUriFile;
}
private Path parsePathInner(
	in string str,
	in ParsePathOptions options,
	in Path delegate(Symbol) @safe @nogc pure nothrow cbRoot,
) {
	StringIter iter = StringIter(str);
	Cell!Path res = Cell!Path(cbRoot(parsePathComponent(iter, options.uriDecode)));
	while (!done(iter))
		cellSet(res, cellGet(res) / parsePathComponent(iter, options.uriDecode));
	return cellGet(res);
}
private @trusted Symbol parsePathComponent(scope ref StringIter iter, bool uriDecode) =>
	withStackWriter!0x1000((scope ref Alloc _, scope ref Writer writer) {
		while (!done(iter)) {
			char x = next(iter);
			if (x == '%' && uriDecode) {
				Opt!ubyte x0 = decodeHexDigit(nextOrDefault(iter, 'x'));
				Opt!ubyte x1 = decodeHexDigit(nextOrDefault(iter, 'x'));
				if (has(x0) && has(x1)) {
					char decoded = cast(char) ((force(x0) << 4) | force(x1));
					writer ~= toLowerCase(decoded);
				} else
					writer ~= "�";
				continue;
			} else if (x == '/' || x == '\\')
				break;
			else {
				writer ~= x;
				continue;
			}
		}
	}, (in string x) => symbolOfString(x));

private void encodePathComponent(scope ref Writer writer, Symbol component) {
	foreach (char x; component) {
		if (!isUriSafeChar(x)) {
			writer ~= '%';
			writer ~= typeAs!string(encodeAsHex(x));
		} else
			writer ~= x;
	}
}

private bool isWindowsPathStart(Symbol a) =>
	isLongSymbol(a) && isWindowsPathStart(asLongSymbol(a));
private bool isWindowsPathStart(in string a) =>
	a.length == 2 && isLetter(a[0]) && a[1] == ':';
private bool isLetter(char a) =>
	('a' <= a && a <= 'z') ||
	('A' <= a && a <= 'Z');

private bool isUriSafeChar(char x) =>
	isAsciiIdentifierChar(x) || x == '-' || x == '.' || x == '~';
private char[2] encodeAsHex(ubyte a) =>
	[encodeAsHexDigit(a >> 4), encodeAsHexDigit(a & 0xf)];
private char encodeAsHexDigit(ubyte a) {
	assert(a <= 0xf);
	char res = a <= 9 ? cast(char) ('0' + a) : cast(char) ('a' + (a - 10));
	Opt!ubyte decoded = decodeHexDigit(res);
	assert(force(decoded) == a);
	return res;
}

private @trusted RelPath parseRelPath(in string a) =>
	parseRelPathRecur(0, a);
private @system RelPath parseRelPathRecur(size_t nParents, in string a) =>
	a.length >= 2 && a[0] == '.' && isSlash(a[1])
		? parseRelPathRecur(nParents, a[2 .. $])
		: a.length >= 3 && a[0] == '.' && a[1] == '.' && isSlash(a[2])
		? parseRelPathRecur(nParents + 1, a[3 .. $])
		: RelPath(safeToUshort(nParents), parsePath(a));

FilePath parseFilePath(in CString a) =>
	parseFilePath(stringOfCString(a));
FilePath parseFilePath(in string a) =>
	FilePath(parsePathInner(
		!isEmpty(a) && a[0] == '/' ? a[1 .. $] : a,
		ParsePathOptions(uriDecode: false, isUriFile: false),
		(Symbol firstComponent) => rootFilePath(firstComponent).path));

Opt!FilePath parseFilePathWithCwd(FilePath cwd, in CString a) {
	Uri res = parseUriWithCwd(cwd, stringOfCString(a));
	return optIf(uriIsFile(res), () => asFilePath(res));
}

Uri parseUriWithCwd(FilePath cwd, in string a) =>
	parseUriWithCwd(toUri(cwd), a);

Uri parseUriWithCwd(Uri cwd, in string a) {
	//TODO: handle actual URIs...
	if (looksLikeAbsolutePath(a))
		return toUri(parseFilePath(a));
	else if (looksLikeUri(a))
		return mustParseUri(a);
	else {
		//TODO: handle parse error (return none if so)
		RelPath rp = parseRelPath(a);
		Opt!Uri resolved = resolveUri(cwd, rp);
		return has(resolved)
			? force(resolved)
			: todo!Uri("relative path reaches past file system root");
	}
}

private @trusted bool looksLikeAbsolutePath(in string a) =>
	(a.length >= 1 && a[0] == '/') ||
	(a.length >= 3 && isWindowsPathStart(a[0 .. 2]) && isSlash(a[2]));

private bool looksLikeUri(in string a) =>
	containsSubstring(a, "://");

private bool containsSubstring(in string a, in string b) =>
	a.length >= b.length && (a[0 .. b.length] == b || containsSubstring(a[1 .. $], b));

@trusted Comparison compareUriNaturally(Uri a, Uri b) =>
	withStringOfUri(a, (in string aStr) =>
		withStringOfUri(b, (in string bStr) =>
			compareStringsNaturally(aStr, bStr)));

immutable struct UrisInfo {
	Opt!Uri cwd;
}

bool isAncestor(Uri a, Uri b) =>
	isAncestor(a.path, b.path);
bool isAncestor(Path a, Path b) {
	if (a == b)
		return true;
	else {
		Opt!Path par = parent(b);
		return has(par) && isAncestor(a, force(par));
	}
}

// 'a' must be an ancestor of 'b'. Gives the path from 'a' to 'b'.
Path pathFromAncestor(Uri a, Uri b) =>
	pathFromAncestor(a.path, b.path);
Path pathFromAncestor(Path a, Path b) {
	assert(isAncestor(a, b));
	Path parent = force(parent(b));
	return parent == a
		? rootPath(baseName(b), PathInfo())
		: pathFromAncestor(a, parent) / baseName(b);
}

Opt!Uri commonAncestor(Uri a, Uri b) {
	Opt!Path res = commonAncestor(a.path, b.path);
	return optIf(has(res), () => Uri(force(res)));
}
private Opt!Path commonAncestor(Path a, Path b) {
	size_t minCount = min(countComponents(a), countComponents(b));
	return commonAncestorRecur(firstNComponents(a, minCount), firstNComponents(b, minCount));
}
private Opt!Path commonAncestorRecur(Path a, Path b) {
	assert(countComponents(a) == countComponents(b));
	return a == b
		? some(a)
		: has(parent(a))
		? commonAncestorRecur(force(parent(a)), force(parent(b)))
		: none!Path;
}

RelPath relativePath(Path from, Path to) {
	ushort nParents = 0;
	Cell!Path ancestor = Cell!Path(parentOrEmpty(from));
	while (!isAncestor(cellGet(ancestor), to)) {
		nParents++;
		Opt!Path parent = parent(cellGet(ancestor));
		if (has(parent))
			cellSet(ancestor, force(parent));
		else
			return RelPath(nParents, to);
	}
	return RelPath(nParents, pathFromAncestor(cellGet(ancestor), to));
}

Opt!RelPath relativePathForUri(Uri from, Uri to) {
	RelPath res = relativePath(from.pathIncludingScheme, to.pathIncludingScheme);
	return optIf(res.nParents != countComponents(from.pathIncludingScheme) - 1, () => res);
}

private:

bool isSlash(char a) =>
	a == '/' || a == '\\';

void writePath(scope ref Writer writer, Path a, bool uriEncode = false) { // TODO: implement 'writeTo' for 'Path'
	withComponents(a, (in Symbol[] components) {
		writeComponents(writer, components, uriEncode);
	});
}

void writeComponents(scope ref Writer writer, in Symbol[] components, bool uriEncode) {
	foreach (size_t index, Symbol component; components) {
		if (uriEncode && index != 0) // First component or a Uri is the scheme, which is not encoded
			encodePathComponent(writer, component);
		else
			writer ~= component;
		if (index != components.length - 1)
			writer ~= '/';
	}
}

public void writeUriPreferRelative(ref Writer writer, in UrisInfo urisInfo, Uri a) {
	withComponentsPreferRelative(
		has(urisInfo.cwd) ? some(force(urisInfo.cwd).path) : none!Path,
		a.path,
		(bool isRelative, in Symbol[] components) {
			writeComponents(writer, components, uriEncode: !isRelative);
		});
}

public size_t relPathLength(in RelPath a) =>
	(a.nParents == 0 ? "./".length : a.nParents * "../".length) + pathLength(a.path);

public enum FilePermissions { regular, executable }
public immutable struct PathAndContent {
	Path path;
	FilePermissions permissions;
	string content;
}
