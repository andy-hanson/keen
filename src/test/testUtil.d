module test.testUtil;

@safe @nogc nothrow: // not pure

import std.meta : AliasSeq, staticMap;

import frontend.showModel : ShowCtx, ShowOptions;
import frontend.storage : FileContentGetters, FileType, fileType, LineAndColumnGetters, ReadFileResult, Storage;
import interpret.bytecode : ByteCode, ByteCodeIndex, Operation;
import interpret.debugInfo : showDataArr;
import interpret.stacks : dataEnd, returnTempAsArrReverse, Stacks;
import lib.server : allUnknownUris, Server, ServerSettings, setServerSettings, setFile, setFileAssumeUtf8;
import model.diag : ReadFileDiag;
import util.alloc.alloc : Alloc, allocateElements, AllocKind, MetaAlloc, newAlloc, word;
import util.col.array : arraysEqual, arrayOfRange, arraysCorrespond, endPtr, indexOf, isEmpty, makeArray, map;
import util.json : Json, writeJsonPretty;
import util.opt : force, has, none, Opt;
import util.perf : Perf;
import util.string : CString, CStringAndLength, stringOfCString;
import util.symbol : Extension, symbol;
import util.unicode : FileContent;
import util.uri : concatUriAndPath, getExtension, isAncestor, mustParseUri, parsePath, Uri, UrisInfo;
import util.util : castNonScope, castNonScope_ref, ptrTrustMe;
import util.writer : debugLogWithWriter, Writer, writeWithCommas;

struct Test {
	@safe @nogc nothrow:

	MetaAlloc* metaAlloc;
	Perf* perfPtr;
	Alloc* allocPtr;

	@trusted this(MetaAlloc* m, return scope Perf* p) {
		metaAlloc = m;
		perfPtr = p;
		allocPtr = newAlloc(AllocKind.test, m);
	}

	pure:

	ref Perf perf() return scope =>
		*perfPtr;
	ref Alloc alloc() return scope =>
		*allocPtr;
}

void withShowDiagCtxForTestImpure(
	scope ref Test test,
	scope ref Storage storage,
	in void delegate(in ShowCtx) @safe @nogc nothrow cb,
) {
	withShowDiagCtxForTestImpl!cb(test, storage);
}

private void withShowDiagCtxForTestImpl(alias cb)(scope ref Test test, in Storage storage) =>
	cb(ShowCtx(
		LineAndColumnGetters(ptrTrustMe(storage)),
		FileContentGetters(ptrTrustMe(storage)),
		UrisInfo(none!Uri),
		ShowOptions(false)));

@trusted void expectDataStack(ref Test test, in ulong[] storage, in Stacks stacks, in immutable ulong[] expected) {
	scope const ulong[] stack = arrayOfRange(storage.ptr, dataEnd(stacks));
	if (!arraysEqual(stack, expected)) {
		debugLogWithWriter((ref Writer writer) {
			writer ~= "expected:\n";
			showDataArr(writer, expected);
			writer ~= "\nactual:\n";
			showDataArr(writer, stack);
		});
		assert(false);
	}
}

@trusted void expectReturnStack(
	ref Test test,
	in ByteCode byteCode,
	in ulong[] stacksStorage,
	in Stacks stacks,
	in ByteCodeIndex[] expected,
) {
	// Ignore first entry (which is opStopInterpretation)
	scope const Operation*[] reversed = returnTempAsArrReverse(stacks)[0 .. $ - 1];
	// - 1 for null, - 1 for opStopInterpretation
	assert(endPtr(reversed) == (cast(Operation**) endPtr(stacksStorage)) - 2);
	scope const Operation*[] stack = reverse(test.alloc, reversed);
	bool eq = arraysCorrespond!(Operation*, ByteCodeIndex)(
		stack,
		expected,
		(ref const Operation* a, ref ByteCodeIndex b) @trusted =>
			ByteCodeIndex(a - byteCode.byteCode.ptr) == b);
	if (!eq) {
		debugLogWithWriter((ref Writer writer) @trusted {
			writer ~= "expected:\nreturn:";
			foreach (ByteCodeIndex index; expected) {
				writer ~= ' ';
				writer ~= index.index;
			}
			writer ~= "\nactual:\nreturn:";
			foreach (Operation* ptr; stack) {
				writer ~= ' ';
				writer ~= ptr - byteCode.byteCode.ptr;
			}
			writer ~= '\n';
		});
		assert(false);
	}
}

pure:

void assertEqual(T)(
	in T actual,
	in T expected,
	in void delegate(scope ref Writer, in T) @safe @nogc pure nothrow cbShow,
	in void delegate(scope ref Writer) @safe @nogc pure nothrow cbDescribe = null,
) {
	if (actual != expected) {
		debugLogWithWriter((scope ref Writer writer) {
			if (cbDescribe) cbDescribe(writer);
			writer ~= "Actual: ";
			cbShow(writer, actual);
			writer ~= "\nExpected: ";
			cbShow(writer, expected);
		});
		assert(false);
	}
}

void assertEqual(T)(in immutable T actual, in immutable T expected) {
	assertEqual!(immutable T)(actual, expected, (scope ref Writer _) {});
}

void assertEqual(T)(
	in immutable T actual,
	in immutable T expected,
	in void delegate(scope ref Writer) @safe @nogc pure nothrow cbDescribe,
) {
	assertEqual!(immutable T)(
		actual,
		expected,
		(scope ref Writer writer, in immutable T x) {
			static if (is(T == Json))
				writeJsonPretty(writer, x, 0);
			else
				writer ~= x;
		},
		cbDescribe);
}

void assertEqual(in uint[] actual, in uint[] expected) {
	assertEqual(actual, expected, (scope ref Writer writer, in uint[] xs) {
		writer ~= '(';
		writeWithCommas!uint(writer, xs);
		writer ~= ')';
	});
}

void withTestServer(ref Test test, in void delegate(ref Server) @safe @nogc pure nothrow cb) {
	scope Server server = Server((size_t sizeWords, size_t _) =>
		allocateElements!word(test.alloc, sizeWords));
	setServerSettings(ptrTrustMe(server), ServerSettings(
		includeDir: mustParseUri("test:///include"),
		cwd: mustParseUri("test:///"),
		showOptions: ShowOptions(color: false)));
	return cb(castNonScope_ref(server));
}

immutable struct UriAndContent {
	Uri uri;
	string crow;
}
void setupTestServer(ref Test test, ref Server server, Uri mainUri, in string mainContent) {
	setupTestServer(test, server, [UriAndContent(mainUri, castNonScope(mainContent))]);
}
void setupTestServer(ref Test test, ref Server server, in UriAndContent[] files) {
	foreach (UriAndContent file; files) {
		assert(getExtension(file.uri) == Extension.crow);
		setFileAssumeUtf8(test.perf, server, file.uri, file.crow);
	}
	Uri[] testUris = map(test.alloc, testIncludePaths, (ref immutable string path) =>
		concatUriAndPath(server.includeDir, parsePath(path)));
	while (true) {
		Uri[] unknowns = allUnknownUris(test.alloc, server);
		if (isEmpty(unknowns))
			break;
		else
			foreach (Uri unknown; unknowns)
				setFile(test.perf, server, unknown, defaultFileResult(test.alloc, server, testUris, unknown));
	}
}

string defaultIncludeResult(string path) {
	Opt!size_t index = indexOf(testIncludePaths, path);
	return stringOfCString(testIncludeContents[force(index)]);
}

private:

ReadFileResult defaultFileResult(ref Alloc alloc, scope ref Server server, in Uri[] testUris, Uri uri) {
	final switch (fileType(uri)) {
		case FileType.crow:
			Opt!size_t index = indexOf(testUris, uri);
			if (has(index))
				return ReadFileResult(FileContent(CStringAndLength(testIncludeContents[force(index)])));
			else if (isAncestor(server.includeDir, uri)) {
				debugLogWithWriter((scope ref Writer writer) {
					writer ~= "Missing URI: ";
					writer ~= uri;
				});
				assert(false);
			} else
				return ReadFileResult(ReadFileDiag.notFound);
		case FileType.crowConfig:
			return ReadFileResult(ReadFileDiag.notFound);
		case FileType.other:
			assert(false);
	}
}

alias testIncludePathsSeq = AliasSeq!(
	"crow/bits.crow",
	"crow/bool.crow",
	"crow/col/array.crow",
	"crow/col/collection.crow",
	"crow/col/experimental/frozen-map.crow",
	"crow/col/experimental/frozen-set.crow",
	"crow/col/experimental/index-set.crow",
	"crow/col/map.crow",
	"crow/col/mut-slice.crow",
	"crow/col/mut-array.crow",
	"crow/col/mut-map.crow",
	"crow/col/mut-set.crow",
	"crow/col/private/array-low-level.crow",
	"crow/col/private/build.crow",
	"crow/col/set.crow",
	"crow/col/shared-array.crow",
	"crow/col/shared-map.crow",
	"crow/col/sort.crow",
	"crow/col/util.crow",
	"crow/compare.crow",
	"crow/c-types.crow",
	"crow/enum-util.crow",
	"crow/exception.crow",
	"crow/flags-util.crow",
	"crow/fun-util.crow",
	"crow/hash.crow",
	"crow/io/print.crow",
	"crow/io/private/time-low-level.crow",
	"crow/io/win32-util.crow",
	"crow/js.crow",
	"crow/json.crow",
	"crow/log.crow",
	"crow/misc.crow",
	"crow/number.crow",
	"crow/option.crow",
	"crow/parallel.crow",
	"crow/parse.crow",
	"crow/pointer.crow",
	"crow/private/alloc.crow",
	"crow/private/backtrace.crow",
	"crow/private/bare-map.crow",
	"crow/private/bare-priority-queue.crow",
	"crow/private/bare-queue.crow",
	"crow/private/bool-low-level.crow",
	"crow/private/bootstrap.crow",
	"crow/private/c-string-util.crow",
	"crow/private/exception-low-level.crow",
	"crow/private/exclusion-queue.crow",
	"crow/private/fiber-queue.crow",
	"crow/private/future-low-level.crow",
	"crow/private/libunwind.crow",
	"crow/private/number-low-level.crow",
	"crow/private/range-low-level.crow",
	"crow/private/runtime.crow",
	"crow/private/rt-main.crow",
	"crow/private/symbol-low-level.crow",
	"crow/private/thread-utils.crow",
	"crow/range.crow",
	"crow/result.crow",
	"crow/std.crow",
	"crow/string.crow",
	"crow/symbol.crow",
	"crow/test-util.crow",
	"crow/test-util/test-runner.crow",
	"crow/tuple.crow",
	"crow/version.crow",
	"system/errno.crow",
	"system/pthread.crow",
	"system/stdio.crow",
	"system/stdlib.crow",
	"system/string.crow",
	"system/sys/sysinfo.crow",
	"system/sys/types.crow",
	"system/time.crow",
	"system/unistd.crow",
	"system/win32.crow",
	"system/windows/DbgHelp.crow",
);
immutable string[] testIncludePaths = [testIncludePathsSeq];
immutable CString[testIncludePaths.length] testIncludeContents = [staticMap!(getIncludeText, testIncludePathsSeq)];
enum getIncludeText(string path) = CString(import(path));

T[] reverse(T)(ref Alloc alloc, scope T[] xs) =>
	makeArray(alloc, xs.length, (size_t i) =>
		xs[xs.length - 1 - i]);
