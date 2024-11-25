module frontend.lang;

@safe @nogc pure nothrow:

import util.opt : Opt;
import util.string : CString;
import util.symbol : Extension, Symbol, symbol;
import util.union_ : Union;
import util.uri : baseName, getExtension, Uri;
import util.util : typeAs;

// This is the 'request' to which MainFun is the response
immutable struct MainKind {
	mixin Union!(MainKindMainFunction, MainKindTestsInConfig, MainKindTestsAtUri);

	@safe @nogc pure nothrow:

	static MainKind fun(Uri mainUri, CString[] args) =>
		MainKind(MainKindMainFunction(mainUri, args));
	static MainKind testsInConfig(bool all, Uri configUri) =>
		MainKind(MainKindTestsInConfig(all, configUri));
	static MainKind testsAtUri(bool all, Uri uri, Opt!uint line) =>
		MainKind(MainKindTestsAtUri(all, uri, line));

	Uri mainUriForAllArgs() scope =>
		matchIn!Uri(
			(in MainKindMainFunction x) =>
				x.uri,
			(in MainKindTestsInConfig x) =>
				x.configUri,
			(in MainKindTestsAtUri x) =>
				x.crowUri);

	CString[] programArgs() return scope =>
		match!(CString[])(
			(MainKindMainFunction x) =>
				x.programArgs,
			(MainKindTestsInConfig _) =>
				typeAs!(CString[])([]),
			(MainKindTestsAtUri _) =>
				typeAs!(CString[])([]));
}
immutable struct MainKindMainFunction {
	Uri uri;
	// Does not include executable path
	CString[] programArgs;
}
immutable struct MainKindTestsInConfig { bool all; Uri configUri; }
immutable struct MainKindTestsAtUri {
	bool all;
	Uri crowUri;
	Opt!uint line;
}

Symbol crowConfigBaseName() => symbol!"crow-config.json";

immutable struct JitOptions {
	OptimizationLevel optimization;
}

enum CVersion { c99, c11 }

immutable struct CCompileOptions {
	OptimizationLevel optimizationLevel;
	CVersion cVersion;
}

enum OptimizationLevel {
	none,
	o2,
}

size_t maxSpecDepth() => 8;

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
