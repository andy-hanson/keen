module frontend.storage;

@safe @nogc pure nothrow:

import frontend.config : parseConfig;
import frontend.lang : crowConfigBaseName;
import frontend.parse.parse : parseFile;
import lib.lsp.lspTypes : TextDocumentContentChangeEvent, TextDocumentPositionParams;
import model.ast : FileAst, fileAstForDiag;
import model.diag : Diag, ReadFileDiag;
import model.model : Config, configForDiag;
import model.parseDiag : ParseDiag;
import util.alloc.alloc :
	Alloc,
	AllocAndValue,
	AllocKind,
	freeAlloc,
	MetaAlloc,
	newAlloc,
	withAlloc,
	withTempAlloc;
import util.col.array : concatenateIn, contains;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.mutMap : getOrAdd, keys, mayDelete, mustAdd, MutMap, values;
import util.memory : allocate;
import util.opt : ConstOpt, force, has, MutOpt, none, Opt, some;
import util.perf : Perf;
import util.sourceRange :
	LineAndCharacterGetter,
	LineAndColumnGetter,
	lineAndColumnGetterForText,
	Pos,
	PosKind,
	Range,
	UriAndPos,
	UriAndRange,
	UriAndLineAndCharacterRange,
	UriLineAndColumn,
	UriLineAndColumnRange;
import util.string : CString, cString, CStringAndLength, stringOfRange;
import util.symbol : Extension;
import util.unicode : FileContent, unicodeValidate;
import util.union_ : Union;
import util.uri : baseName, getExtension, Uri;
import util.writer : makeStringWithWriter, Writer;

struct Storage {
	@safe @nogc pure nothrow:

	this(MetaAlloc* a) {
		metaAlloc = a;
		mapAlloc_ = newAlloc(AllocKind.storage, metaAlloc);
	}

	private:
	MetaAlloc* metaAlloc;
	Alloc* mapAlloc_;
	// Store in separate maps depending on success / diag
	MutMap!(Uri, AllocAndValue!FileInfo) successes;
	MutMap!(Uri, ReadFileDiag) diags;

	ref inout(Alloc) mapAlloc() return scope inout =>
		*mapAlloc_;
}

immutable struct FileInfo {
	@safe @nogc pure nothrow:
	mixin Union!(CrowFileInfo*, CrowConfigFileInfo*, OtherFileInfo*);

	FileContent content() =>
		match!FileContent(
			(ref CrowFileInfo x) =>
				x.content.asFileContent,
			(ref CrowConfigFileInfo x) =>
				x.content.asFileContent,
			(ref OtherFileInfo x) =>
				x.content);
	TextFileContent asTextFile() =>
		match!TextFileContent(
			(ref CrowFileInfo x) =>
				x.content,
			(ref CrowConfigFileInfo x) =>
				x.content,
			(ref OtherFileInfo _) =>
				assert(false));
}

immutable struct TextFileContent {
	@safe @nogc pure nothrow:

	CString content;
	LineAndColumnGetter lineAndColumnGetter;

	@trusted FileContent asFileContent() =>
		FileContent(cStringAndLength);

	@trusted CStringAndLength cStringAndLength() =>
		CStringAndLength(content, length);

	static TextFileContent empty() =>
		TextFileContent(cString!"", LineAndColumnGetter.empty);

	LineAndCharacterGetter lineAndCharacterGetter() return scope =>
		lineAndColumnGetter.lineAndCharacterGetter;

	@trusted string asString() =>
		stringOfRange(content, content.jumpTo(length));

	uint length() scope =>
		lineAndCharacterGetter.maxPos;
}

immutable struct CrowFileInfo {
	TextFileContent content;
	FileAst ast;
}

immutable struct CrowConfigFileInfo {
	TextFileContent content;
	Config config;
}

immutable struct OtherFileInfo {
	FileContent content;
}

immutable struct FileInfoOrDiag {
	mixin Union!(FileInfo, ReadFileDiag);
}

FileInfoOrDiag setFile(scope ref Perf perf, ref Storage a, Uri uri, in ReadFileResult result) =>
	result.matchIn!FileInfoOrDiag(
		(in FileContent x) =>
			FileInfoOrDiag(setFileBytes(perf, a, uri, x.asBytes)),
		(in ReadFileDiag x) {
			setFileDiag(perf, a, uri, x);
			return FileInfoOrDiag(x);
		});
FileInfo setFileBytes(scope ref Perf perf, ref Storage a, Uri uri, in ubyte[] content) {
	prepareSetFile(a, uri);
	AllocAndValue!FileInfo info = initFileInfo(perf, a, uri, content, assumeUtf8: false);
	mustAdd(a.mapAlloc, a.successes, uri, info);
	return info.value;
}
FileInfo setFileAssumeUtf8(scope ref Perf perf, ref Storage a, Uri uri, in string content) {
	prepareSetFile(a, uri);
	AllocAndValue!FileInfo info = initFileInfo(perf, a, uri, cast(const ubyte[]) content, assumeUtf8: true);
	mustAdd(a.mapAlloc, a.successes, uri, info);
	return info.value;
}
private void setFileDiag(scope ref Perf perf, ref Storage a, Uri uri, ReadFileDiag diag) {
	prepareSetFile(a, uri);
	return mustAdd(a.mapAlloc, a.diags, uri, diag);
}
private @trusted void prepareSetFile(ref Storage a, Uri uri) {
	mayDelete(a.diags, uri);
	MutOpt!(AllocAndValue!FileInfo) oldContent = mayDelete(a.successes, uri);
	if (has(oldContent))
		freeAlloc(force(oldContent).alloc);
}

FileInfo changeFile(scope ref Perf perf, ref Storage a, Uri uri, in TextDocumentContentChangeEvent[] changes) {
	foreach (TextDocumentContentChangeEvent change; changes[0 .. $ - 1])
		cast(void) changeFile(perf, a, uri, change);
	return changeFile(perf, a, uri, changes[$ - 1]);
}

FileInfo changeFile(scope ref Perf perf, ref Storage a, Uri uri, in TextDocumentContentChangeEvent change) {
	FileInfo info = fileOrDiag(a, uri).as!FileInfo;
	return withTempAlloc(a.metaAlloc, (ref Alloc tempAlloc) {
		string newContent = applyChange(
			tempAlloc, info.asTextFile.asString, info.asTextFile.lineAndCharacterGetter, change);
		// TODO:PERF This means an unnecessary copy in 'setFile'.
		// Would be better to modify the array in place and force re-parse.
		return setFileAssumeUtf8(perf, a, uri, newContent);
	});
}

private AllocAndValue!FileInfo initFileInfo(
	scope ref Perf perf,
	ref Storage storage,
	Uri uri,
	in ubyte[] input,
	bool assumeUtf8
) =>
	withAlloc!FileInfo(AllocKind.storageFileInfo, storage.metaAlloc, (ref Alloc alloc) @trusted {
		FileContent content = FileContent(concatenateIn(alloc, input, [ubyte('\0')]));
		Opt!CString cString = assumeUtf8 ? some(content.assumeUtf8) : unicodeValidateAsCString(content);
		TextFileContent textFileContent() =>
			has(cString)
				? TextFileContent(force(cString), lineAndColumnGetterForText(alloc, force(cString)))
				: TextFileContent(.cString!"", LineAndColumnGetter.empty);
		final switch (fileType(uri)) {
			case FileType.crow:
				return FileInfo(allocate(alloc, CrowFileInfo(
					textFileContent(),
					has(cString)
						? parseFile(perf, alloc, force(cString))
						: fileAstForDiag(alloc, ParseDiag(ParseDiag.FileNotUtf8())))));
			case FileType.crowConfig:
				return FileInfo(allocate(alloc, CrowConfigFileInfo(
					textFileContent(),
					has(cString)
						? parseConfig(alloc, uri, force(cString))
						: configForDiag(alloc, uri, Diag(ParseDiag(ParseDiag.FileNotUtf8()))))));
			case FileType.other:
				return FileInfo(allocate(alloc, OtherFileInfo(content)));
		}
	});

private Opt!CString unicodeValidateAsCString(FileContent a) {
	Opt!CStringAndLength res = unicodeValidate(a);
	return has(res) ? some(force(res).asCString) : none!CString;
}

enum FileType {
	crow,
	crowConfig,
	other,
}

FileType fileType(Uri uri) {
	switch (getExtension(uri)) {
		case Extension.crow:
			return FileType.crow;
		case Extension.json:
			return baseName(uri) == crowConfigBaseName ? FileType.crowConfig : FileType.other;
		default:
			return FileType.other;
	}
}

enum FilesState {
	hasUnknown,
	hasLoading,
	allLoaded,
}

FilesState filesState(in Storage a) {
	FilesState res = FilesState.allLoaded;
	foreach (ReadFileDiag x; values(a.diags)) {
		final switch (x) {
			case ReadFileDiag.unknown:
				return FilesState.hasUnknown;
			case ReadFileDiag.loading:
				res = FilesState.hasLoading;
				break;
			case ReadFileDiag.notFound:
			case ReadFileDiag.error:
				break;
		}
	}
	return res;
}

Uri[] allStorageUris(ref Alloc alloc, in Storage a) =>
	buildArray!Uri(alloc, (scope ref Builder!Uri res) {
		foreach (Uri uri; keys(a.successes))
			res ~= uri;
		foreach (Uri uri; keys(a.diags))
			res ~= uri;
	});

Uri[] allUrisWithFileDiag(ref Alloc alloc, in Storage a, in ReadFileDiag[] searchDiags) =>
	buildArray!Uri(alloc, (scope ref Builder!Uri res) {
		foreach (Uri uri, ReadFileDiag diag; a.diags)
			if (contains(searchDiags, diag))
				res ~= uri;
	});

FileInfoOrDiag fileOrDiag(ref Storage a, Uri uri) {
	ConstOpt!(AllocAndValue!FileInfo) res = a.successes[uri];
	return has(res)
		? FileInfoOrDiag(force(res).value)
		: FileInfoOrDiag(getOrAdd!(Uri, ReadFileDiag)(a.mapAlloc, a.diags, uri, () => ReadFileDiag.unknown));
}

void markUnknownIfNotExist(scope ref Storage a, Uri uri) {
	cast(void) fileOrDiag(a, uri);
}

immutable struct ReadFileResult {
	mixin Union!(FileContent, ReadFileDiag);
}

const struct FileContentGetters {
	@safe @nogc pure nothrow:

	private const Storage* storage;

	private Opt!FileInfo getFileInfo(Uri uri) scope {
		ConstOpt!(AllocAndValue!FileInfo) res = storage.successes[uri];
		return has(res) ? some(force(res).value) : none!FileInfo;
	}

	string getSourceText(Uri uri) scope =>
		force(getFileInfo(uri)).as!(CrowFileInfo*).content.asString;
	string getSourceText(Uri uri, Range range) scope =>
		getSourceText(uri)[range.start .. range.end];
	string opIndex(in UriAndRange x) scope =>
		x.range.isEmpty ? "" : getSourceText(x.uri, x.range);
}

const struct LineAndCharacterGetters {
	@safe @nogc pure nothrow:

	private const Storage* storage;

	LineAndCharacterGetter opIndex(Uri uri) scope {
		ConstOpt!(AllocAndValue!FileInfo) res = storage.successes[uri];
		return has(res) ? force(res).value.asTextFile.lineAndCharacterGetter : LineAndCharacterGetter.empty;
	}

	Pos opIndex(in TextDocumentPositionParams x) scope =>
		this[x.textDocument.uri][x.position];

	UriAndLineAndCharacterRange opIndex(in UriAndRange x) scope =>
		UriAndLineAndCharacterRange(x.uri, this[x.uri][x.range]);
}

const struct LineAndColumnGetters {
	@safe @nogc pure nothrow:

	private const Storage* storage;

	LineAndColumnGetter opIndex(Uri uri) scope {
		ConstOpt!(AllocAndValue!FileInfo) res = storage.successes[uri];
		return has(res) ? force(res).value.asTextFile.lineAndColumnGetter : LineAndColumnGetter.empty;
	}

	UriLineAndColumn opIndex(in UriAndPos pos, PosKind kind) scope =>
		UriLineAndColumn(pos.uri, this[pos.uri][pos.pos, kind]);

	UriLineAndColumnRange opIndex(in UriAndRange x) scope =>
		UriLineAndColumnRange(x.uri, this[x.uri][x.range]);

	LineAndCharacterGetters lineAndCharacterGetters() return scope =>
		LineAndCharacterGetters(storage);
}

private string applyChange(
	ref Alloc alloc,
	in string input,
	in LineAndCharacterGetter lc,
	in TextDocumentContentChangeEvent event,
) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		if (has(event.range)) {
			Range range = lc[force(event.range)];
			writer ~= input[0 .. range.start];
			writer ~= event.text;
			writer ~= input[range.end .. $];
		} else
			writer ~= event.text;
	});
