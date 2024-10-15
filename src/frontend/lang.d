module frontend.lang;

@safe @nogc pure nothrow:

import util.opt : Opt;
import util.string : CString;
import util.symbol : Symbol, symbol;
import util.union_ : Union;
import util.uri : Uri;
import util.util : typeAs;

// This is the 'request' to which MainFun is the response
immutable struct MainKind {
	immutable struct MainFunction {
		Uri uri;
		// Does not include executable path
		CString[] programArgs;
	}
	immutable struct TestsInConfig { bool all; Uri configUri; }
	immutable struct TestsAtUri {
		bool all;
		Uri crowUri;
		Opt!uint line;
	}
	mixin Union!(MainFunction, TestsInConfig, TestsAtUri);

	@safe @nogc pure nothrow:

	static MainKind fun(Uri mainUri, CString[] args) =>
		MainKind(MainFunction(mainUri, args));
	static MainKind testsInConfig(bool all, Uri configUri) =>
		MainKind(TestsInConfig(all, configUri));
	static MainKind testsAtUri(bool all, Uri uri, Opt!uint line) =>
		MainKind(TestsAtUri(all, uri, line));

	Uri mainUriForAllArgs() scope =>
		matchIn!Uri(
			(in MainFunction x) =>
				x.uri,
			(in TestsInConfig x) =>
				x.configUri,
			(in TestsAtUri x) =>
				x.crowUri);
	
	CString[] programArgs() return scope =>
		match!(CString[])(
			(MainFunction x) =>
				x.programArgs,
			(TestsInConfig _) =>
				typeAs!(CString[])([]),
			(TestsAtUri _) =>
				typeAs!(CString[])([]));
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
