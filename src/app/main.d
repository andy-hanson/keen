module app.main;

@safe @nogc nothrow: // not pure

import core.memory : pureMalloc;
import core.stdc.signal : raise;
import core.stdc.stdlib : abort;
version (Windows) {
	import core.sys.windows.core : GetTickCount;
} else {
	import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC, timespec;
}

import app.backtrace : writeBacktrace;
import app.command : BuildOptions, Command, CommandKind, isFakeExtern, RunOptions, SingleBuildOutput, targetsForBuild;
import app.dyncall : withRealExtern;
import app.fileSystem :
	cleanupCompile,
	eachFileInDirectoryRecursive,
	FileOverwrite,
	findPathToCCompiler,
	getCwd,
	getPathToThisExecutable,
	print,
	printCb,
	printError,
	printErrorCb,
	readExactFromStdin,
	readLineFromStdin,
	runCompiler,
	runNodeJsProgram,
	runProgram,
	tryReadFile,
	withTempPath,
	writeFile,
	writeFilesToDir,
	writeStringNoNewline;
import app.parseCommand : defaultExecutableExtension, defaultExecutablePath, parseCommand;
version (GccJitAvailable) {
	import backend.jit : jitAndRun;
}
import backend.js.sourceMap : JsAndMap;
import backend.js.translateToJs : JsModules;
import backend.writeToC : PathAndArgs, WriteToCParams;
import frontend.lang : CCompileOptions, MainKind;
import frontend.showModel : ShowOptions;
import frontend.storage : FilesState;
import interpret.extern_ : Extern;
import interpret.fakeExtern : withFakeExtern;
import lib.lsp.lspParse : parseLspInMessage;
import lib.lsp.lspToJson : jsonOfLspOutMessage;
import lib.lsp.lspTypes :
	LspInMessage,
	LspInNotification,
	LspOutAction,
	LspOutMessage,
	LspOutNotification,
	Pipe,
	ReadFileResultParams,
	ReadFileResultType,
	UnknownUris;
import lib.server :
	allUnknownUris,
	buildAndInterpret,
	buildToC,
	BuildToCResult,
	buildToJsModules,
	buildToJsScript,
	buildToLowProgram,
	DiagsAndResultJson,
	document,
	filesState,
	getProgram,
	getProgramForMain,
	getShowCtx,
	handleLspMessage,
	jsonForPrintIdeAtPos,
	jsonForPrintIdeWholeFile,
	jsonOfConcreteModel,
	jsonOfLowModel,
	jsonOfModel,
	perfStats,
	printAst,
	PrintKind,
	Server,
	ServerSettings,
	setFile,
	setServerSettings,
	setShowOptions,
	setupServer,
	showDiagnostics,
	version_;
import model.diag : ReadFileDiag;
import model.model : BuildTarget, hasAnyDiagnostics, hasFatalDiagnostics, Program, ProgramWithMain;
import model.lowModel : ExternLibraries;
version (Test) {
	import test.test : test;
}
import util.alloc.alloc : Alloc, AllocKind, FetchMemoryCb, newAlloc, withTempAllocImpure, word;
import util.col.array : find, isEmpty, prepend;
import util.col.mutQueue : enqueue, isEmpty, mustDequeue, MutQueue;
import util.exitCode : eachUntilError, ExitCode, exitCodeCombine, ExitCodeOrSignal, okAnd, Signal;
import util.json : Json, jsonToString, writeJsonPretty;
import util.jsonParse : mustParseJson, mustParseUint, skipWhitespace;
import util.late : Late, late, lateGet, lateIsSet, lateSet;
import util.opt : force, has, none, Opt, optIf, optOrDefault, some;
import util.perf : disablePerf, isEnabled, Perf, PerfMeasure, withMeasureNoAlloc, withNullPerf;
import util.perfReport : perfReport;
import util.sourceRange : UriLineAndColumn;
import util.string : CString, mustStripPrefix, MutCString;
import util.symbol : Extension, symbol;
import util.unicode : FileContent;
import util.uri :
	addExtension,
	asFilePath,
	baseName,
	concatFilePathAndPath,
	cStringOfUriPreferRelative,
	FilePath,
	FilePermissions,
	getExtension,
	parent,
	parentOrEmpty,
	rootFilePath,
	toUri,
	Uri,
	uriIsFile;
import util.util : castNonScope_ref, debugLog;
import util.writer : makeStringWithWriter, writeNat, Writer;
import versionInfo : getOS, JsTarget, OS, versionInfoForInterpret, versionInfoForJIT, VersionOptions;

@system extern(C) int main(int argc, immutable char** argv) {
	ulong function() @safe @nogc pure nothrow getTimeNanosPure =
		cast(ulong function() @safe @nogc pure nothrow) &getTimeNanos;
	scope Perf perf = Perf(() => getTimeNanosPure());
	size_t totalAllocatedWords = 0;
	scope FetchMemoryCb fetchCb = (size_t sizeWords, size_t _) {
		totalAllocatedWords += sizeWords;
		if (totalAllocatedWords > 0x40000000) {
			assert(false, "Exceeded 8GB total allocated");
		}
		return (cast(word*) pureMalloc(sizeWords * word.sizeof))[0 .. sizeWords];
	};
	Server* server = setupServer(castNonScope_ref!FetchMemoryCb(fetchCb));
	FilePath cwd = getCwd();
	FilePath thisExecutable = getPathToThisExecutable();
	setServerSettings(server, ServerSettings(
		includeDir: toUri(getCrowIncludeDir(thisExecutable)),
		cwd: toUri(cwd),
		showOptions: ShowOptions(color: true)));
	Alloc* alloc = newAlloc(AllocKind.main, server.metaAlloc);
	Command command = parseCommand(*alloc, cwd, getOS(), cast(CString[]) argv[1 .. argc]);
	if (!command.options.perf)
		disablePerf(perf);
	ExitCodeOrSignal res = go(perf, *alloc, *server, cwd, thisExecutable, command.kind);
	if (isEnabled(perf)) {
		withTempAllocImpure!void(server.metaAlloc, (ref Alloc alloc) @trusted {
			printJson(alloc, perfReport(alloc, perf, *server.metaAlloc, perfStats(alloc, *server)));
		});
	}
	return res.matchImpure!int(
		(in ExitCode x) =>
			x.value,
		(in Signal x) @trusted =>
			raise(x.signal));
}

private:

version (Windows) {
	extern(C) noreturn _assert(immutable char* asserted, immutable char* file, uint lineNumber) =>
		assertFailed(asserted, file, lineNumber);
} else {
	extern(C) noreturn __assert(immutable char* asserted, immutable char* file, uint lineNumber) =>
		assertFailed(asserted, file, lineNumber);
}

bool inAssert;
@trusted noreturn assertFailed(immutable char* asserted, immutable char* file, uint lineNumber) {
	if (!inAssert) {
		inAssert = true;
		printErrorCb((scope ref Writer writer) @trusted {
			writer ~= "Assert failed: ";
			writer ~= CString(asserted);
			writer ~= " at ";
			writer ~= CString(file);
			writer ~= " line ";
			writer ~= lineNumber;
			writeBacktrace(writer);
		});
	}
	abort();
}

@trusted ExitCode runLsp(ref Server server, FilePath thisExecutable) {
	withTempAllocImpure!void(server.metaAlloc, (ref Alloc alloc) @trusted {
		printErrorCb((scope ref Writer writer) {
			writer ~= version_(alloc, server, thisExecutable);
			writer ~= "\nRunning language server protocol";
		});
	});

	setShowOptions(server, ShowOptions(false));

	while (true) {
		// TODO: get this from specified trace level
		bool logLsp = false;
		//TODO: track perf for each message/response
		Opt!ExitCode stop = withNullPerf!(Opt!ExitCode, (scope ref Perf perf) =>
			withTempAllocImpure!(Opt!ExitCode)(server.metaAlloc, (ref Alloc alloc) =>
				handleOneMessageIn(perf, alloc, server, logLsp)));
		if (has(stop))
			return force(stop);
		else
			continue;
	}
}

Opt!ExitCode handleOneMessageIn(scope ref Perf perf, ref Alloc alloc, ref Server server, bool logLsp) {
	MutQueue!LspInMessage bufferedMessages;
	enqueue(alloc, bufferedMessages, lspRead(alloc, logLsp));
	do {
		LspInMessage message = mustDequeue(bufferedMessages);
		LspOutAction action = handleLspMessage(perf, alloc, server, message);
		foreach (LspOutMessage outMessage; action.outMessages) {
			if (!server.lspState.supportsUnknownUris && isUnknownUris(outMessage)) {
				debugLog("Server will load unknown URIs itself (since client does not support them)");
				foreach (Uri uri; outMessage.as!LspOutNotification.as!UnknownUris.unknownUris)
					enqueue(alloc, bufferedMessages, LspInMessage(LspInNotification(readFileLocally(alloc, uri))));
			} else
				lspWrite(alloc, jsonOfLspOutMessage(alloc, outMessage), logLsp);
		}
		if (has(action.exitCode))
			return action.exitCode;
	} while (!isEmpty(bufferedMessages));
	return none!ExitCode;
}

bool isUnknownUris(in LspOutMessage a) =>
	a.isA!LspOutNotification && a.as!LspOutNotification.isA!UnknownUris;

@trusted LspInMessage lspRead(ref Alloc alloc, bool logLsp) {
	char[0x10000] buffer = void;
	CString line0 = readLineFromStdin(buffer);
	CString stripped = mustStripPrefix(line0, "Content-Length: ");
	uint contentLength = mustParseUint(stripped);
	assert(contentLength < buffer.length);

	MutCString line1 = readLineFromStdin(buffer);
	skipWhitespace(line1);
	assert(*line1 == '\0');

	readExactFromStdin(buffer[0 .. contentLength]);
	buffer[contentLength] = '\0';

	if (logLsp)
		printErrorCbWithTime((scope ref Writer writer) @trusted {
			writer ~= "LSP message in: ";
			writer ~= CString(cast(immutable) buffer.ptr);
		});

	return parseLspInMessage(alloc, mustParseJson(alloc, CString(cast(immutable) buffer.ptr)));
}

@trusted void lspWrite(ref Alloc alloc, in Json contentJson, bool logLsp) {
	string jsonString = jsonToString(alloc, contentJson);
	string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= "Content-Length: ";
		writer ~= jsonString.length;
		writer ~= "\r\n\r\n";
		writer ~= contentJson;
	});
	writeStringNoNewline(Pipe.stdout, message);
	if (logLsp) {
		printErrorCbWithTime((scope ref Writer writer) {
			writer ~= "LSP out:";
			writer ~= contentJson;
		});
	}
}

ExitCode loadAllFilesForMain(scope ref Perf perf, ref Server server, in MainKind main) =>
	main.matchImpure!ExitCode(
		(in MainKind.MainFunction x) {
			loadAllFiles(perf, server, [x.uri]);
			return ExitCode.ok;
		},
		(in MainKind.TestsInConfig x) =>
			loadAllFilesForConfig(perf, server, x.configUri),
		(in MainKind.TestsAtUri x) {
			loadAllFiles(perf, server, [x.crowUri]);
			return ExitCode.ok;
		});

ExitCode loadAllFilesForConfig(scope ref Perf perf, ref Server server, Uri configUri) =>
	okAnd(
		uriIsFile(configUri)
			? ExitCode.ok
			: printErrorCb((scope ref Writer writer) {
				writer ~= "Can't list test files at non-file URI ";
				writer ~= configUri;
			}),
		() => eachFileInDirectoryRecursive(force(parent(asFilePath(configUri))), (FilePath file) {
			if (getExtension(file) == Extension.crow)
				loadSingleFile(perf, server, toUri(file));
			return ExitCode.ok;
		}),
		() {
			loadUntilNoUnknownUris(perf, server);
			return ExitCode.ok;
		});

void loadAllFiles(scope ref Perf perf, ref Server server, in Uri[] rootUris) {
	foreach (Uri uri; rootUris)
		loadSingleFile(perf, server, uri);
	loadUntilNoUnknownUris(perf, server);
}

ReadFileResultParams readFileLocally(ref Alloc alloc, Uri uri) =>
	tryReadFile(alloc, uri).match!ReadFileResultParams(
		(FileContent x) =>
			ReadFileResultParams(uri, ReadFileResultType.ok, x.asBytes),
		(ReadFileDiag x) {
			ReadFileResultType type = () {
				final switch (x) {
					case ReadFileDiag.unknown:
					case ReadFileDiag.loading:
						assert(false);
					case ReadFileDiag.notFound:
						return ReadFileResultType.notFound;
					case ReadFileDiag.error:
						return ReadFileResultType.error;
				}
			}();
			return ReadFileResultParams(uri, type, []);
		});

void loadUntilNoUnknownUris(scope ref Perf perf, ref Server server) {
	while (filesState(server) != FilesState.allLoaded) {
		withTempAllocImpure(server.metaAlloc, (ref Alloc alloc) {
			foreach (Uri uri; allUnknownUris(alloc, server))
				loadSingleFile(perf, server, uri);
		});
	}
}

void loadSingleFile(scope ref Perf perf, ref Server server, Uri uri) {
	withTempAllocImpure(server.metaAlloc, (ref Alloc alloc) {
		setFile(perf, server, uri, tryReadFile(alloc, uri));
	});
}

void printErrorCbWithTime(in void delegate(scope ref Writer) @safe @nogc pure nothrow cb) {
	printErrorCb((scope ref Writer writer) {
		ulong x = getTimeMsec();
		writer ~= x / 1000;
		writer ~= '.';
		writeNat(writer, x % 1000, minDigits: 3);
		writer ~= ' ';
		cb(writer);
	});
}

ulong getTimeMsec() =>
	getTimeNanos() / 1_000_000;

@trusted ulong getTimeNanos() {
	version (Windows) {
		return (cast(ulong) GetTickCount()) * 1_000_000;
	} else {
		timespec time;
		clock_gettime(CLOCK_MONOTONIC, &time);
		return time.tv_sec * 1_000_000_000 + time.tv_nsec;
	}
}

ExitCodeOrSignal go(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	FilePath cwd,
	FilePath thisExecutable,
	in CommandKind command,
) =>
	command.matchImpure!ExitCodeOrSignal(
		(in CommandKind.Build x) =>
			withProgramForMain(
				perf, alloc, server, x.main, targetsForBuild(alloc, getOS(), x), (ref ProgramWithMain program) =>
					buildAllOutputs(perf, alloc, server, cwd, x.options, program)),
		(in CommandKind.Check x) =>
			withProgramForRoots(perf, alloc, server, x.rootUris, (ref Program program) =>
				hasAnyDiagnostics(program) ? ExitCodeOrSignal.error : ExitCodeOrSignal(print("OK"))),
		(in CommandKind.Document x) =>
			withProgramForRoots(perf, alloc, server, x.rootUris, (ref Program program) =>
				printJson(alloc, document(alloc, server, program, x.rootUris))),
		(in CommandKind.Help x) {
			print(x.helpText);
			return ExitCodeOrSignal(x.exitCode);
		},
		(in CommandKind.Lsp) =>
			ExitCodeOrSignal(runLsp(server, thisExecutable)),
		(in CommandKind.Print x) =>
			doPrint(perf, alloc, server, x),
		(in CommandKind.Run x) =>
			run(perf, alloc, server, cwd, x),
		(in CommandKind.SelfTest x) {
			version (Test)
				return ExitCodeOrSignal(test(server.metaAlloc, x.names));
			else
				return ExitCodeOrSignal(printError("Did not compile with tests"));
		},
		(in CommandKind.Version) =>
			ExitCodeOrSignal(printCb((scope ref Writer writer) {
				writeJsonPretty(writer, version_(alloc, server, thisExecutable), 0);
			})));

ExitCodeOrSignal run(scope ref Perf perf, ref Alloc alloc, ref Server server, FilePath cwd, in CommandKind.Run run) {
	OS os = isFakeExtern(run.options) ? OS.none : getOS();
	return withProgramForMain(perf, alloc, server, run.main, [BuildTarget.native(os)], (ref ProgramWithMain program) =>
		run.options.matchImpure!ExitCodeOrSignal(
			(in RunOptions.Aot x) @safe =>
				buildAndRun(perf, alloc, server, cwd, program, run.main.programArgs, x),
			(in RunOptions.Interpret x) =>
				withRealOrFakeExtern(
					x.fakeExtern, *newAlloc(AllocKind.extern_, server.metaAlloc), (scope ref Extern extern_) =>
						buildAndInterpret(
							perf, server, extern_,
							(in string x) { printError(x); },
							program, os, x.version_, none!(Uri[]),
							getAllArgs(alloc, server, run.main))),
			(in RunOptions.Jit options) {
				version (GccJitAvailable)
					return ExitCodeOrSignal(jitAndRun(
						perf,
						alloc,
						getShowCtx(server),
						buildToLowProgram(perf, alloc, server, versionInfoForJIT(getOS(), options.version_), program),
						options.options,
						getAllArgs(alloc, server, run.main)));
				else
					return ExitCodeOrSignal(printError("This build does not support '--jit'"));
			},
			(in RunOptions.NodeJs) =>
				buildAndRunNodeJs(perf, alloc, server, cwd, program, run.main.programArgs)));
}

ExitCodeOrSignal withRealOrFakeExtern(
	bool fakeExtern,
	ref Alloc alloc,
	in ExitCodeOrSignal delegate(scope ref Extern) @safe @nogc nothrow cb,
) =>
	fakeExtern
		? withFakeExtern!ExitCodeOrSignal(alloc, (Pipe pipe, in string x) {
			writeStringNoNewline(pipe, x);
		}, cb)
		: withRealExtern(alloc, cb);

FilePath getCrowIncludeDir(FilePath thisExecutable) {
	FilePath thisDir = parentOrEmpty(thisExecutable);
	FilePath thisDirDir = parentOrEmpty(thisDir);
	version (Windows) {
		assert(baseName(thisDirDir) == symbol!"crow");
		return thisDirDir / symbol!"include";
	} else {
		FilePath usr = rootFilePath(symbol!"usr");
		return thisDir == usr / symbol!"bin"
			? usr / symbol!"include" / symbol!"crow"
			: thisDir == usr / symbol!"local" / symbol!"bin"
			? usr / symbol!"local" / symbol!"include" / symbol!"crow"
			: () {
				assert(baseName(thisDirDir) == symbol!"crow");
				return thisDirDir / symbol!"include";
			}();
	}
}

CString[] getAllArgs(ref Alloc alloc, in Server server, in MainKind main) =>
	prepend(alloc, cStringOfUriPreferRelative(alloc, server.urisInfo, main.mainUriForAllArgs), main.programArgs);

ExitCodeOrSignal doPrint(scope ref Perf perf, ref Alloc alloc, ref Server server, in CommandKind.Print command) {
	Uri mainUri = command.mainUri;
	return command.kind.matchImpure!ExitCodeOrSignal(
		(in PrintKind.Ast) {
			loadSingleFile(perf, server, mainUri);
			return printDiagsAndJson(alloc, printAst(perf, alloc, server, mainUri));
		},
		(in PrintKind.Model) =>
			withProgramForRoots(perf, alloc, server, [mainUri], (ref Program program) =>
				printJson(alloc, jsonOfModel(perf, alloc, server, program, mainUri))),
		(in PrintKind.ConcreteModel) =>
			withProgramForMain(perf, alloc, server, MainKind.fun(mainUri, []), [], (ref ProgramWithMain program) =>
				printJson(alloc, jsonOfConcreteModel(
					perf, alloc, server, versionInfoForInterpret(getOS(), VersionOptions()), program))),
		(in PrintKind.LowModel) =>
			withProgramForMain(perf, alloc, server, MainKind.fun(mainUri, []), [], (ref ProgramWithMain program) =>
				printJson(alloc, jsonOfLowModel(
					perf, alloc, server, versionInfoForInterpret(getOS(), VersionOptions()), program))),
		(in PrintKind.IdeAtPos x) =>
			withProgramForRoots(perf, alloc, server, [mainUri], (ref Program program) =>
				printJson(alloc, jsonForPrintIdeAtPos(
					perf, alloc, server, program, UriLineAndColumn(mainUri, x.lineAndColumn), x.kind))),
		(in PrintKind.IdeWholeFile x) =>
			withProgramForRoots(perf, alloc, server, [mainUri], (ref Program program) =>
				printJson(alloc, jsonForPrintIdeWholeFile(perf, alloc, server, program, mainUri, x.kind))));
}

ExitCodeOrSignal buildAndRun(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	FilePath cwd,
	ref ProgramWithMain program,
	in CString[] programArgs,
	in RunOptions.Aot options,
) {
	Uri tempBase = tempBasePath(program, cwd);
	return withTempPath(tempBase, Extension.c, (FilePath cPath) =>
		withTempPath(tempBase, defaultExecutableExtension(getOS()), (FilePath exePath) =>
			withBuildToCAndExe(
				perf, alloc, server, cPath, exePath, options.version_, options.compileOptions, program,
				(in ExternLibraries libs) {
					ExitCodeOrSignal res = runProgram(libs, PathAndArgs(exePath, programArgs));
					// Doing this after 'runProgram' since that may use the '.pdb' file
					ExitCode cleanup = cleanupCompile(cwd, cPath, exePath);
					// Delay aborting with the signal so we can clean up temp files
					return exitCodeCombine(res, cleanup);
				})));
}

ExitCodeOrSignal buildAndRunNodeJs(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	FilePath cwd,
	ref ProgramWithMain program,
	in CString[] programArgs,
) =>
	withTempPath(tempBasePath(program, cwd), Extension.js, (FilePath js) =>
		withWriteToJsScript(perf, alloc, server, program, js, JsTarget.node, false, () =>
			runNodeJsProgram(PathAndArgs(js, programArgs))));

Uri tempBasePath(in ProgramWithMain program, FilePath cwd) =>
	optOrDefault!Uri(program.mainFun.uriForTempPath, () => toUri(cwd / symbol!"temp"));

ExitCodeOrSignal buildAllOutputs(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	FilePath cwd,
	in BuildOptions options,
	ref ProgramWithMain program,
) {
	Opt!FilePath findPath(SingleBuildOutput.Kind kind) {
		Opt!SingleBuildOutput s = find!SingleBuildOutput(options.out_, (in SingleBuildOutput x) => x.kind == kind);
		return optIf(has(s), () => force(s).path);
	}
	// 'exe' build must be done after 'c' build.
	Opt!FilePath exe = findPath(SingleBuildOutput.Kind.executable);
	Late!PathAndArgs exeCompileCommand = late!PathAndArgs();

	ExitCodeOrSignal buildC(FilePath cPath) =>
		withWriteToC(
			perf, alloc, server, cPath, exe, options.version_, options.cCompileOptions, program,
			(PathAndArgs compileCommand, in ExternLibraries _) {
				lateSet(exeCompileCommand, compileCommand);
				return ExitCodeOrSignal.ok;
			});

	ExitCodeOrSignal buildJsScript(FilePath path, JsTarget target) =>
		withWriteToJsScript(perf, alloc, server, program, path, target, true, () =>
			ExitCodeOrSignal.ok);
	ExitCodeOrSignal buildJsModules(FilePath dir, JsTarget target) =>
		withWriteToJsModules(perf, alloc, server, program, dir, target, (FilePath main) =>
			ExitCodeOrSignal(printCb((scope ref Writer writer) {
				writer ~= "Main module is ";
				writer ~= main;
			})));

	ExitCodeOrSignal res = eachUntilError!SingleBuildOutput(options.out_, (ref SingleBuildOutput out_) {
		final switch (out_.kind) {
			case SingleBuildOutput.Kind.c:
				return buildC(out_.path);
			case SingleBuildOutput.Kind.executable:
				return ExitCodeOrSignal.ok; // do this last
			case SingleBuildOutput.Kind.jsModules:
				return buildJsModules(out_.path, JsTarget.browser);
			case SingleBuildOutput.Kind.jsScript:
				return buildJsScript(out_.path, JsTarget.browser);
			case SingleBuildOutput.Kind.nodeJsModules:
				return buildJsModules(out_.path, JsTarget.node);
			case SingleBuildOutput.Kind.nodeJsScript:
				return buildJsScript(out_.path, JsTarget.node);
		}
	});
	return okAnd(res, () {
		if (has(exe))
			return lateIsSet(exeCompileCommand)
				? buildToExeFromC(perf, lateGet(exeCompileCommand))
				: withTempPath(force(exe), Extension.c, (FilePath cPath) =>
					okAnd(buildC(cPath), () => buildToExeFromC(perf, lateGet(exeCompileCommand))));
		else
			return ExitCodeOrSignal.ok;
	});
}

ExitCodeOrSignal withWriteToJsScript(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	FilePath outFile,
	JsTarget target,
	bool includeSourceMap,
	in ExitCodeOrSignal delegate() @safe @nogc nothrow cb,
) {
	Opt!FilePath sourceMapPath = optIf(includeSourceMap, () => addExtension(outFile, Extension.map));
	JsAndMap result = buildToJsScript(alloc, server, program, target, optIf(has(sourceMapPath), () =>
		baseName(force(sourceMapPath))));
	FilePermissions mainPermissions = () {
		final switch (target) {
			case JsTarget.browser:
				return FilePermissions.regular;
			case JsTarget.node:
				return FilePermissions.executable;
		}
	}();
	return okAnd(
		ExitCodeOrSignal(writeFile(outFile, result.js, mainPermissions, FileOverwrite.allow)),
		() => has(sourceMapPath)
			? ExitCodeOrSignal(
				writeFile(force(sourceMapPath), force(result.map), FilePermissions.regular, FileOverwrite.allow))
			: ExitCodeOrSignal.ok,
		cb);
}

ExitCodeOrSignal withWriteToJsModules(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	FilePath outDir,
	JsTarget target,
	in ExitCodeOrSignal delegate(FilePath mainJs) @safe @nogc nothrow cb,
) {
	JsModules result = buildToJsModules(alloc, server, program, target);
	return okAnd(
		ExitCodeOrSignal(writeFilesToDir(outDir, result.outputFiles)),
		() => cb(concatFilePathAndPath(outDir, result.mainJs)));
}

ExitCodeOrSignal withProgramForMain(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in MainKind main,
	in BuildTarget[] targets,
	in ExitCodeOrSignal delegate(ref ProgramWithMain) @safe @nogc nothrow cb,
) =>
	okAnd(
		ExitCodeOrSignal(loadAllFilesForMain(perf, server, main)),
		() {
			ProgramWithMain program = getProgramForMain(perf, alloc, server, main, targets);
			if (hasAnyDiagnostics(program))
				printError(showDiagnostics(alloc, server, program));
			return hasFatalDiagnostics(program)
				? ExitCodeOrSignal(printError("Stopping due to compile errors."))
				: cb(program);
		});
ExitCodeOrSignal withProgramForRoots(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in Uri[] roots,
	in ExitCodeOrSignal delegate(ref Program) @safe @nogc nothrow cb,
) {
	loadAllFiles(perf, server, roots);
	Program program = getProgram(perf, alloc, server);
	if (hasAnyDiagnostics(program))
		printError(showDiagnostics(alloc, server, program));
	return cb(program);
}

ExitCodeOrSignal withWriteToC(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	FilePath cPath,
	Opt!FilePath exePath,
	in VersionOptions version_,
	in CCompileOptions cCompileOptions,
	ref ProgramWithMain program,
	in ExitCodeOrSignal delegate(PathAndArgs, in ExternLibraries) @safe @nogc nothrow cb,
) {
	Opt!FilePath cCompiler = findPathToCCompiler();
	if (has(cCompiler)) {
		OS os = getOS();
		WriteToCParams params = WriteToCParams(
			force(cCompiler), cPath,
			optOrDefault!FilePath(exePath, () => defaultExecutablePath(cPath, os)),
			cCompileOptions);
		BuildToCResult result = buildToC(perf, alloc, server, os, version_, params, program);
		return okAnd(
			ExitCodeOrSignal(
				writeFile(cPath, result.writeToCResult.cSource, FilePermissions.regular, FileOverwrite.allow)),
			() => cb(result.writeToCResult.compileCommand, result.externLibraries));
	} else
		return ExitCodeOrSignal.error;
}

ExitCodeOrSignal withBuildToCAndExe(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	FilePath cPath,
	FilePath exePath,
	in VersionOptions version_,
	in CCompileOptions cCompileOptions,
	ref ProgramWithMain program,
	in ExitCodeOrSignal delegate(in ExternLibraries) @safe @nogc nothrow cb,
) =>
	withWriteToC(
		perf, alloc, server, cPath, some(exePath), version_, cCompileOptions, program,
		(PathAndArgs compileCommand, in ExternLibraries externLibraries) =>
			okAnd(
				buildToExeFromC(perf, compileCommand),
				() => cb(externLibraries)));

ExitCodeOrSignal buildToExeFromC(scope ref Perf perf, PathAndArgs compileCommand) =>
	ExitCodeOrSignal(withMeasureNoAlloc!(ExitCode, () =>
		runCompiler(compileCommand)
	)(perf, PerfMeasure.invokeCCompiler));

ExitCodeOrSignal printDiagsAndJson(ref Alloc alloc, in DiagsAndResultJson a) {
	if (!isEmpty(a.diagnostics))
		printError(a.diagnostics);
	return printJson(alloc, a.result);
}

ExitCodeOrSignal printJson(ref Alloc alloc, in Json json) =>
	ExitCodeOrSignal(print(jsonToString(alloc, json)));
