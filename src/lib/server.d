module lib.server;

@safe @nogc nothrow: // not pure

import backend.js.sourceMap : JsAndMap;
import backend.js.translateToJs : JsModules, translateToJsModules, translateToJsScript;
import backend.writeToC : writeToC, WriteToCParams, WriteToCResult;
import concretize.concretize : concretize;
import frontend.frontendCompile :
	Frontend,
	initFrontend,
	makeProgram,
	makeProgramWithMain,
	onFileChanged,
	perfStats,
	programWithMainFromProgram;
import frontend.getDiagnosticSeverity : getDiagnosticSeverity;
import frontend.ide.syntaxTranslate : syntaxTranslate;
import frontend.ide.getDefinition : getDefinitionForPosition;
import frontend.ide.getHover : getHover;
import frontend.ide.getPosition : getPosition;
import frontend.ide.getRename : getRenameForPosition;
import frontend.ide.getReferences : getDocumentHighlightsForPosition, getReferencesForPosition;
import frontend.ide.getTokens : jsonOfDecodedTokens, tokensOfAst;
import frontend.ide.position : Position;
import frontend.showDiag :
	sortedDiagnostics, stringOfDiag, stringOfDiagnostics, stringOfParseDiagnostics, UriAndDiagnostics;
import frontend.showModel : ShowCtx, ShowDiagCtx, ShowOptions;
import frontend.storage :
	allKnownGoodCrowUris,
	allStorageUris,
	allUrisWithFileDiag,
	changeFile,
	CrowFileInfo,
	FileContentGetters,
	FileInfo,
	FileInfoOrDiag,
	fileOrDiag,
	FilesState,
	filesState,
	LineAndCharacterGetters,
	LineAndColumnGetters,
	ReadFileResult,
	setFile,
	setFileAssumeUtf8,
	setFileBytes,
	Storage,
	TextFileContent;
import interpret.bytecode : ByteCode;
import interpret.extern_ : Extern, ExternPointersForAllLibraries, WriteError;
import interpret.fakeExtern : withFakeExtern, WriteCb;
import interpret.generateBytecode : generateBytecode;
import interpret.runBytecode : runBytecode;
import lib.lsp.lspToJson : jsonOfDocumentHighlight, jsonOfHover, jsonOfReferences, jsonOfRename;
import lib.lsp.lspTypes :
	BuildJsScriptParams,
	BuildJsScriptResult,
	CancelRequestParams,
	DefinitionParams,
	DidChangeTextDocumentParams,
	DidCloseTextDocumentParams,
	DidOpenTextDocumentParams,
	DidSaveTextDocumentParams,
	DocumentHighlightParams,
	DocumentHighlightResult,
	ExitParams,
	Hover,
	HoverParams,
	InitializedParams,
	InitializeParams,
	InitializeResult,
	LspDiagnostic,
	LspDiagnosticSeverity,
	LspInMessage,
	LspInNotification,
	LspInRequest,
	LspInRequestParams,
	LspOutAction,
	LspOutMessage,
	LspOutNotification,
	LspOutResponse,
	LspOutResult,
	Pipe,
	PublishDiagnosticsParams,
	ReadFileResultParams,
	ReadFileResultType,
	ReferenceParams,
	RegisterCapability,
	RenameParams,
	RunParams,
	RunResult,
	SemanticTokensParams,
	SetTraceParams,
	ShutdownParams,
	SyntaxTranslateParams,
	TextDocumentContentChangeEvent,
	TextDocumentIdentifier,
	TextDocumentPositionParams,
	UnloadedUris,
	UnloadedUrisParams,
	UnknownUris,
	WorkspaceEdit,
	Write;
import lower.lower : lower;
import model.ast : fileAstForDiag, FileAst;
import model.concreteModel : ConcreteProgram;
import model.diag : Diagnostic, DiagnosticSeverity, ReadFileDiag;
import model.jsonOfAst : jsonOfAst;
import model.jsonOfConcreteModel : jsonOfConcreteProgram;
import model.jsonOfLowModel : jsonOfLowProgram;
import model.jsonOfModel : jsonOfModule;
import model.lowModel : ExternLibraries, LowProgram;
import model.model :
	asProgramWithOptMain,
	BuildTarget,
	hasAnyDiagnostics,
	hasFatalDiagnostics,
	Module,
	moduleAtUri,
	Program,
	ProgramWithMain,
	ProgramWithOptMain;
import model.parseDiag : ParseDiag;
import util.alloc.alloc : Alloc, AllocKind, FetchMemoryCb, freeElements, MetaAlloc, newAlloc, withTempAllocImpure;
import util.alloc.stackAlloc : ensureStackAllocInitialized;
import util.col.array : concatenate, contains, map, mapOp, newArray;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.col.mutArr : clearAndDoNotFree, MutArr, push;
import util.exitCode : ExitCode, ExitCodeOrSignal, Signal;
import util.integralValues : initIntegralValues;
import util.json : field, Json, jsonNull, jsonObject;
import util.late : Late, lateGet, lateSet, MutLate;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some;
import util.perf : Perf;
import util.sourceRange : LineAndColumn, toLineAndCharacter, UriAndRange, UriLineAndColumn;
import util.string : copyString, CString, cString;
import util.symbol : initSymbols, Symbol;
import util.uri : FilePath, initUris, stringOfFilePath, Uri, UrisInfo;
import util.union_ : Union;
import util.util : castNonScope, castNonScope_ref, todo;
import versionInfo : getOS, JsTarget, OS, VersionInfo, versionInfoForBuildToC, versionInfoForInterpret, VersionOptions;

ExitCodeOrSignal buildAndInterpret(
	scope ref Perf perf,
	ref Server server,
	in Extern extern_,
	in WriteError writeError,
	ref ProgramWithMain program,
	VersionOptions version_,
	in Opt!(Uri[]) diagnosticsOnlyForUris,
	in CString[] allArgs,
) {
	assert(filesState(server) == FilesState.allLoaded);
	return withTempAllocImpure!ExitCodeOrSignal(server.metaAlloc, AllocKind.buildToLowProgram, (ref Alloc buildAlloc) {
		LowProgram lowProgram = buildToLowProgram(
			perf, buildAlloc, server, versionInfoForInterpret(getOS(), version_), program);
		Opt!ExternPointersForAllLibraries externPointers =
			extern_.loadExternPointers(lowProgram.externLibraries, writeError);
		if (has(externPointers))
			return withTempAllocImpure!ExitCodeOrSignal(
				server.metaAlloc, AllocKind.interpreter, (ref Alloc bytecodeAlloc) {
					ByteCode byteCode = generateBytecode(
						perf, bytecodeAlloc, program.program, lowProgram,
						force(externPointers), extern_.aggregateCbs, extern_.makeSyntheticFunPointers);
					return ExitCodeOrSignal(runBytecode(
						perf, getShowDiagCtx(server, program.program),
						extern_.doDynCall, lowProgram, byteCode, allArgs));
				});
		else {
			writeError("Failed to load external libraries\n");
			return ExitCodeOrSignal.error;
		}
	});
}

LspOutAction handleLspMessage(scope ref Perf perf, ref Alloc alloc, ref Server server, in LspInMessage message) =>
	message.matchImpure!LspOutAction(
		(in LspInNotification x) =>
			handleLspNotification(perf, alloc, server, x),
		(in LspInRequest x) {
			Opt!LspOutResult response = handleLspRequest(perf, alloc, server, x);
			return LspOutAction(
				has(response) ? newArray!LspOutMessage(alloc, [messageForResponse(x, force(response))]) : [],
				none!ExitCode);
		});

private LspOutMessage messageForResponse(in LspInRequest request, LspOutResult result) =>
	LspOutMessage(LspOutResponse(request.id, result));

private LspOutAction handleLspNotification(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LspInNotification a,
) =>
	a.matchImpure!LspOutAction(
		(in CancelRequestParams _) {
			// Ignore because according to documentation,
			// "A request that got canceled still needs to return from the server and send a response back"
			return LspOutAction([]);
		},
		(in DidChangeTextDocumentParams x) {
			changeFile(perf, server, x.textDocument.uri, x.contentChanges);
			return handleFileChanged(perf, alloc, server, x.textDocument.uri);
		},
		(in DidCloseTextDocumentParams x) =>
			LspOutAction([]),
		(in DidOpenTextDocumentParams x) {
			setFileAssumeUtf8(perf, server, x.textDocument.uri, x.textDocument.text);
			return handleFileChanged(perf, alloc, server, x.textDocument.uri);
		},
		(in DidSaveTextDocumentParams x) =>
			LspOutAction([]),
		(in ExitParams x) =>
			LspOutAction([], some(ExitCode.ok)),
		(in InitializedParams _) =>
			initializedAction(alloc, server),
		(in ReadFileResultParams x) {
			final switch (x.type) {
				case ReadFileResultType.ok:
					setFile(perf, server, x.uri, x.content);
					break;
				case ReadFileResultType.notFound:
					setFile(perf, server, x.uri, ReadFileDiag.notFound);
					break;
				case ReadFileResultType.error:
					setFile(perf, server, x.uri, ReadFileDiag.error);
					break;
			}
			return handleFileChanged(perf, alloc, server, x.uri);
		},
		(in SetTraceParams _) =>
			// TODO: implement this
			LspOutAction([]));

private LspOutAction handleFileChanged(scope ref Perf perf, ref Alloc alloc, ref Server server, Uri changed) {
	final switch (filesState(server)) {
		case FilesState.hasUnknown:
			Uri[] unknown = allUnknownUris(alloc, server);
			foreach (Uri uri; unknown)
				setFile(perf, server, uri, ReadFileDiag.loading);
			return LspOutAction(newArray!LspOutMessage(alloc, [notification(UnknownUris(unknown))]));
		case FilesState.hasLoading:
			return LspOutAction([]);
		case FilesState.allLoaded:
			Program program = getProgramForAll(perf, alloc, server);
			ArrayBuilder!LspOutMessage messages;
			foreach (LspInRequest request; server.lspState.pendingRequests)
				add(alloc, messages, messageForResponse(
					request,
					handleLspRequestWithProgram(perf, alloc, server, program, request.params)));
			clearAndDoNotFree(server.lspState.pendingRequests);
			notifyDiagnostics(perf, alloc, messages, server, program);
			return LspOutAction(finish(alloc, messages), none!ExitCode);
	}
}

// Only returns 'none' if not all files are loaded
private Opt!LspOutResult handleLspRequest(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LspInRequest a,
) =>
	a.params.matchImpure!(Opt!LspOutResult)(
		(in BuildJsScriptParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in DefinitionParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in DocumentHighlightParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in HoverParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in InitializeParams x) {
			server.lspState.supportsUnknownUris = x.initializationOptions.unknownUris;
			return some(LspOutResult(InitializeResult()));
		},
		(in ReferenceParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in RenameParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in RunParams x) =>
			respondWithProgram(perf, alloc, server, a),
		(in SemanticTokensParams x) {
			Uri uri = x.textDocument.uri;
			return some(LspOutResult(tokensOfAst(alloc, *getCrowFileForTokens(alloc, server, uri))));
		},
		(in ShutdownParams _) =>
			some(LspOutResult(LspOutResult.Null())),
		(in SyntaxTranslateParams x) =>
			some(LspOutResult(syntaxTranslate(alloc, x))),
		(in UnloadedUrisParams) =>
			some(LspOutResult(UnloadedUris(allUnloadedUris(alloc, server)))));

private Opt!LspOutResult respondWithProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LspInRequest request,
) {
	if (filesState(server) == FilesState.allLoaded) {
		Program program = getProgramForAll(perf, alloc, server);
		return some(handleLspRequestWithProgram(perf, alloc, server, program, request.params));
	} else {
		push(server.lspState.stateAlloc, server.lspState.pendingRequests, request);
		return none!LspOutResult;
	}
}

private LspOutResult handleLspRequestWithProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref Program program,
	in LspInRequestParams a,
) {
	ProgramWithMain programWithMain(Uri main, BuildTarget target) =>
		programWithMainFromProgram(perf, alloc, server.frontend, program, main, [target]);
	return a.matchImpure!LspOutResult(
		(in BuildJsScriptParams x) {
			ProgramWithMain pwm = programWithMain(x.uri, BuildTarget.js);
			return LspOutResult(BuildJsScriptResult(
				showDiagnostics(alloc, server, pwm, x.diagnosticsOnlyForUris),
				optIf(!hasFatalDiagnostics(pwm), () =>
					buildToJsScript(alloc, server, pwm, JsTarget.browser, none!Symbol).js)));
		},
		(in DefinitionParams x) =>
			LspOutResult(getDefinitionForProgram(alloc, server, program, x)),
		(in DocumentHighlightParams x) {
			Opt!DocumentHighlightResult res = getDocumentHighlightsForProgram(alloc, server, program, x);
			return has(res) ? LspOutResult(force(res)) : LspOutResult(LspOutResult.Null());
		},
		(in HoverParams x) =>
			LspOutResult(getHoverForProgram(alloc, server, program, x)),
		(in InitializeParams _) =>
			assert(false),
		(in ReferenceParams x) =>
			LspOutResult(getReferencesForProgram(alloc, server, program, x)),
		(in RenameParams x) =>
			LspOutResult(getRenameForProgram(alloc, server, program, x)),
		(in RunParams x) {
			ArrayBuilder!Write writes;
			ProgramWithMain pwm = programWithMain(x.uri, BuildTarget.native);
			ExitCodeOrSignal exitCode = runFromLsp(
				perf, alloc, server, pwm, x.diagnosticsOnlyForUris,
				(Pipe pipe, in string x) {
					add(alloc, writes, Write(pipe, copyString(alloc, x)));
				});
			ExitCode asExitCode = exitCode.match!ExitCode(
				(ExitCode x) => x,
				(Signal _) => ExitCode.error);
			return LspOutResult(RunResult(asExitCode, finish(alloc, writes)));
		},
		(in SemanticTokensParams _) =>
			assert(false),
		(in ShutdownParams _) =>
			assert(false),
		(in SyntaxTranslateParams x) =>
			assert(false),
		(in UnloadedUrisParams _) =>
			assert(false));
}

private ExitCodeOrSignal runFromLsp(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	in Opt!(Uri[]) diagnosticsOnlyForUris,
	in WriteCb writeCb,
) {
	// TODO: use an arena so anything allocated during interpretation is cleaned up.
	// Or just have interpreter free things.
	CString[1] allArgs = [cString!"/usr/bin/fakeExecutable"];
	return withFakeExtern(alloc, writeCb, (scope ref Extern extern_) {
		if (hasAnyDiagnostics(program))
			writeCb(Pipe.stderr, showDiagnostics(alloc, server, program, diagnosticsOnlyForUris));
		return hasFatalDiagnostics(program) ? ExitCodeOrSignal.error : buildAndInterpret(
			perf, server, extern_,
			(in string x) { writeCb(Pipe.stderr, x); },
			program, VersionOptions(isSingleThreaded: true, stackTraceEnabled: true), diagnosticsOnlyForUris, allArgs);
	});
}

private __gshared Server serverStorage = void;

@system Server* setupServer(FetchMemoryCb fetch) {
	ensureStackAllocInitialized();
	Server* server = &serverStorage;
	server.__ctor(fetch);
	initIntegralValues(server.metaAlloc);
	initSymbols(server.metaAlloc);
	initUris(server.metaAlloc);
	return server;
}

pure:

struct Server {
	@safe @nogc pure nothrow:

	MetaAlloc metaAlloc_;
	private Late!Uri includeDir_;
	private Late!UrisInfo urisInfo_;
	ShowOptions showOptions_ = ShowOptions(false);
	Storage storage;
	LspState lspState;
	MutLate!(Frontend*) frontend_;

	@disable this(ref const Server);
	@trusted this(return scope FetchMemoryCb fetch) {
		metaAlloc_ = MetaAlloc(fetch);
		storage = Storage(metaAlloc);
		lspState = LspState(newAlloc(AllocKind.lspState, metaAlloc));
	}

	inout(MetaAlloc*) metaAlloc() inout =>
		castNonScope(&metaAlloc_);
	Uri includeDir() scope const =>
		lateGet(includeDir_);
	ref UrisInfo urisInfo() return scope const =>
		lateGet(urisInfo_);
	ref inout(Frontend) frontend() return scope inout =>
		*lateGet(frontend_);
	ShowOptions showOptions() scope const =>
		showOptions_;
	LineAndCharacterGetters lineAndCharacterGetters() return scope const =>
		LineAndCharacterGetters(&castNonScope_ref(storage));
	LineAndColumnGetters lineAndColumnGetters() return scope const =>
		LineAndColumnGetters(&castNonScope_ref(storage));
}

immutable struct ServerSettings {
	Uri includeDir;
	Uri cwd;
	ShowOptions showOptions;
}

void setServerSettings(Server* server, ServerSettings settings) {
	lateSet!Uri(server.includeDir_, settings.includeDir);
	lateSet!UrisInfo(server.urisInfo_, UrisInfo(cwd: some(settings.cwd)));
	setShowOptions(*server, settings.showOptions);

	lateSet!(Frontend*)(server.frontend_, initFrontend(server.metaAlloc, &server.storage, server.includeDir));
}

void setShowOptions(ref Server server, in ShowOptions options) {
	server.showOptions_ = options;
}

Json perfStats(ref Alloc alloc, in Server a) =>
	jsonObject(alloc, [
		field!"frontend"(perfStats(alloc, a.frontend))]);

private struct LspState {
	@safe @nogc pure nothrow:

	Alloc* stateAllocPtr;
	bool supportsUnknownUris;
	Uri[] urisWithDiagnostics;
	MutArr!LspInRequest pendingRequests;

	ref inout(Alloc) stateAlloc() return scope inout =>
		*stateAllocPtr;
}

Json version_(ref Alloc alloc, in Server server, FilePath thisExecutable) {
	version (Debug) {
		bool isDebug = true;
	} else {
		bool isDebug = false;
	}
	version (assert) {
		bool isAssert = true;
	} else {
		bool isAssert = false;
	}
	version (TailRecursionAvailable) {
		bool isTailCalls = true;
	} else {
		bool isTailCalls = false;
	}
	version (GccJitAvailable) {
		bool isJit = true;
	} else {
		bool isJit = false;
	}

	return jsonObject(alloc, [
		field!"path"(stringOfFilePath(alloc, thisExecutable)),
		field!"built-on"(import("date.txt")[0 .. "2020-02-02".length]),
		field!"commit-hash"(import("commit-hash.txt")[0 .. 8]),
		field!"is-debug-build"(isDebug),
		field!"has-assertions"(isAssert),
		field!"interpreter-uses-tail-calls"(isTailCalls),
		field!"supports-jit"(isJit),
		field!"d-compiler"(dCompilerName),
	]);
}

private string dCompilerName() {
	version (DigitalMars) {
		return "DMD";
	} else version (GNU) {
		return "GDC";
	} else version (LDC) {
		return "LDC";
	} else {
		static assert(false);
	}
}

void setFile(scope ref Perf perf, ref Server server, Uri uri, in ReadFileResult result) {
	onFileChanged(perf, server.frontend, uri, setFile(perf, server.storage, uri, result));
}
void setFileAssumeUtf8(scope ref Perf perf, ref Server server, Uri uri, in string result) {
	onFileChanged(perf, server.frontend, uri, FileInfoOrDiag(setFileAssumeUtf8(perf, server.storage, uri, result)));
}
void setFile(scope ref Perf perf, ref Server server, Uri uri, in ubyte[] result) {
	onFileChanged(perf, server.frontend, uri, FileInfoOrDiag(setFileBytes(perf, server.storage, uri, result)));
}
void setFile(scope ref Perf perf, ref Server server, Uri uri, ReadFileDiag diag) {
	setFile(perf, server, uri, ReadFileResult(diag));
}

void changeFile(scope ref Perf perf, ref Server server, Uri uri, in TextDocumentContentChangeEvent[] changes) {
	onFileChanged(perf, server.frontend, uri, FileInfoOrDiag(changeFile(perf, server.storage, uri, changes)));
}

FilesState filesState(in Server server) =>
	filesState(server.storage);

Uri[] allStorageUris(ref Alloc alloc, in Server server) =>
	allStorageUris(alloc, server.storage);
Uri[] allUnknownUris(ref Alloc alloc, in Server server) =>
	allUrisWithFileDiag(alloc, server.storage, [ReadFileDiag.unknown]);
private Uri[] allUnloadedUris(ref Alloc alloc, in Server server) =>
	allUrisWithFileDiag(alloc, server.storage, [ReadFileDiag.unknown, ReadFileDiag.loading]);

string showDiagnostics(ref Alloc alloc, in Server server, in Program program) =>
	showDiagnosticsCommon(alloc, server, asProgramWithOptMain(program), none!(Uri[]));
string showDiagnostics(
	ref Alloc alloc,
	in Server server,
	in ProgramWithMain program,
	in Opt!(Uri[]) onlyForUris = none!(Uri[]),
) =>
	showDiagnosticsCommon(alloc, server, asProgramWithOptMain(program), onlyForUris);
private string showDiagnosticsCommon(
	ref Alloc alloc,
	in Server server,
	in ProgramWithOptMain program,
	in Opt!(Uri[]) onlyForUris,
) =>
	stringOfDiagnostics(alloc, getShowDiagCtx(server, program.program), program, onlyForUris);

private UriAndRange[] getDefinitionForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in DefinitionParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params);
	return has(position) ? getDefinitionForPosition(alloc, program.commonTypes, force(position)) : [];
}

private Opt!DocumentHighlightResult getDocumentHighlightsForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in DocumentHighlightParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params);
	return has(position)
		? getDocumentHighlightsForPosition(alloc, program, force(position))
		: none!DocumentHighlightResult;
}

private UriAndRange[] getReferencesForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in ReferenceParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params);
	return has(position) ? getReferencesForPosition(alloc, program, force(position)) : [];
}

private Opt!WorkspaceEdit getRenameForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in RenameParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.textDocumentAndPosition);
	return has(position)
		? getRenameForPosition(alloc, program, force(position), params.newName)
		: none!WorkspaceEdit;
}

private Opt!Hover getHoverForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in HoverParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params);
	return optIf(has(position), () => getHover(alloc, getShowDiagCtx(server, program), force(position)));
}

private Program getProgram(scope ref Perf perf, ref Alloc alloc, ref Server server, in Uri[] roots) =>
	makeProgram(perf, alloc, server.frontend, roots);

ProgramWithMain getProgramForMain(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	Uri mainUri,
	in BuildTarget[] targets,
) =>
	makeProgramWithMain(perf, alloc, server.frontend, mainUri, targets);

Program getProgramForRoots(scope ref Perf perf, ref Alloc alloc, ref Server server, in Uri[] roots) =>
	getProgram(perf, alloc, server, roots);

Program getProgramForAll(scope ref Perf perf, ref Alloc alloc, ref Server server) =>
	getProgram(perf, alloc, server, allKnownGoodCrowUris(alloc, server.storage));

private Opt!Position serverGetPosition(in Server server, ref Program program, in TextDocumentPositionParams where) {
	Opt!(immutable Module*) module_ = program.allModules[where.textDocument.uri];
	return has(module_)
		? getPosition(program, force(module_), server.lineAndCharacterGetters[where])
		: none!Position;
}

struct DiagsAndResultJson {
	string diagnostics;
	Json result;
}

private DiagsAndResultJson printForAst(ref Alloc alloc, ref Server server, Uri uri, in FileAst ast, Json result) =>
	DiagsAndResultJson(
		stringOfParseDiagnostics(alloc, getShowCtx(server), uri, ast.parseDiagnostics),
		result);

DiagsAndResultJson printTokens(ref Alloc alloc, ref Server server, in SemanticTokensParams params) {
	Uri uri = params.textDocument.uri;
	CrowFileInfo* file = getCrowFileForTokens(alloc, server, uri);
	return printForAst(alloc, server, uri, file.ast, jsonOfDecodedTokens(alloc, tokensOfAst(alloc, *file)));
}

DiagsAndResultJson printAst(scope ref Perf perf, ref Alloc alloc, ref Server server, Uri uri) {
	CrowFileInfo* file = getCrowFileForTokens(alloc, server, uri);
	return printForAst(alloc, server, uri, file.ast, jsonOfAst(alloc, server.lineAndColumnGetters[uri], file.ast));
}

private CrowFileInfo* getCrowFileForTokens(ref Alloc alloc, ref Server server, Uri uri) =>
	fileOrDiag(server.storage, uri).match!(CrowFileInfo*)(
		(FileInfo x) =>
			x.as!(CrowFileInfo*),
		(ReadFileDiag x) =>
			allocate(alloc, CrowFileInfo(
				TextFileContent.empty,
				fileAstForDiag(alloc, ParseDiag(x)))));

Json jsonOfModel(scope ref Perf perf, ref Alloc alloc, ref Server server, Program program, Uri uri) =>
	jsonOfModule(alloc, server.lineAndColumnGetters[uri], *moduleAtUri(program, uri));

Json jsonOfConcreteModel(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LineAndColumnGetters lineAndColumnGetters,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) =>
	jsonOfConcreteProgram(
		alloc, lineAndColumnGetters,
		concretize(
			perf, alloc,
			getShowDiagCtx(server, program.program),
			versionInfo, program,
			FileContentGetters(&server.storage)));

Json jsonOfLowModel(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LineAndColumnGetters lineAndColumnGetters,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) =>
	jsonOfLowProgram(alloc, lineAndColumnGetters, buildToLowProgram(perf, alloc, server, versionInfo, program));

immutable struct PrintKind {
	immutable struct Tokens {}
	immutable struct Ast {}
	immutable struct Model {}
	immutable struct ConcreteModel {}
	immutable struct LowModel {}
	immutable struct Ide {
		enum Kind { definition, documentHighlight, hover, references, rename }
		Kind kind;
		LineAndColumn lineAndColumn;
	}

	mixin Union!(Tokens, Ast, Model, ConcreteModel, LowModel, Ide);
}

Json jsonForPrintIde(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref Program program,
	in UriLineAndColumn where,
	PrintKind.Ide.Kind kind,
) {
	TextDocumentPositionParams params = TextDocumentPositionParams(
		TextDocumentIdentifier(where.uri),
		toLineAndCharacter(server.lineAndColumnGetters[where.uri], where.pos));
	Json locations(UriAndRange[] xs) => jsonOfReferences(alloc, server.lineAndCharacterGetters, xs);
	final switch (kind) {
		case PrintKind.Ide.Kind.definition:
			return locations(getDefinitionForProgram(alloc, server, program, DefinitionParams(params)));
		case PrintKind.Ide.Kind.documentHighlight:
			Opt!DocumentHighlightResult res = getDocumentHighlightsForProgram(alloc, server, program, DocumentHighlightParams(params));
			return has(res)
				? jsonOfDocumentHighlight(alloc, server.lineAndCharacterGetters[where.uri], force(res))
				: jsonNull;
		case PrintKind.Ide.Kind.hover:
			return jsonOfHover(alloc, getHoverForProgram(alloc, server, program, HoverParams(params)));
		case PrintKind.Ide.Kind.rename:
			Opt!WorkspaceEdit rename = getRenameForProgram(alloc, server, program, RenameParams(params, "new-name"));
			return jsonOfRename(alloc, server.lineAndCharacterGetters, rename);
		case PrintKind.Ide.Kind.references:
			return locations(getReferencesForProgram(alloc, server, program, ReferenceParams(params)));
	}
}

LowProgram buildToLowProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) {
	assert(!hasFatalDiagnostics(program));
	ShowCtx ctx = getShowDiagCtx(server, program.program);
	ConcreteProgram concreteProgram = concretize(
		perf, alloc, ctx, versionInfo, program, FileContentGetters(&server.storage));
	return lower(perf, alloc, ctx, program.mainConfig.extern_, program.program, concreteProgram);
}

immutable struct BuildToCResult {
	WriteToCResult writeToCResult;
	ExternLibraries externLibraries;
}
BuildToCResult buildToC(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	OS os,
	VersionOptions version_,
	in WriteToCParams params,
	ref ProgramWithMain program,
) {
	LowProgram lowProgram = buildToLowProgram(perf, alloc, server, versionInfoForBuildToC(os, version_,), program);
	return BuildToCResult(
		writeToC(alloc, getShowDiagCtx(server, program.program), lowProgram, params),
		lowProgram.externLibraries);
}

JsAndMap buildToJsScript(
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	JsTarget target,
	Opt!Symbol sourceMapName,
) {
	assert(!hasFatalDiagnostics(program));
	return translateToJsScript(
		alloc,
		program,
		getShowDiagCtx(server, program.program, forceNoColor: true),
		LineAndCharacterGetters(&server.storage),
		FileContentGetters(&server.storage),
		target,
		sourceMapName);
}

JsModules buildToJsModules(
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	JsTarget target,
) =>
	translateToJsModules(
		alloc,
		program,
		getShowDiagCtx(server, program.program, forceNoColor: true),
		LineAndCharacterGetters(&server.storage),
		FileContentGetters(&server.storage),
		target);

ShowDiagCtx getShowDiagCtx(
	return scope ref const Server server,
	return scope ref Program program,
	bool forceNoColor = false,
) =>
	ShowDiagCtx(getShowCtx(server, forceNoColor: forceNoColor), program.commonTypesPtr);

private:

ShowCtx getShowCtx(return scope ref const Server server, bool forceNoColor = false) =>
	ShowCtx(
		server.lineAndColumnGetters,
		server.urisInfo,
		forceNoColor ? server.showOptions.withoutColor : server.showOptions);

LspOutMessage notification(T)(T a) =>
	LspOutMessage(LspOutNotification(a));

void notifyDiagnostics(
	scope ref Perf perf,
	ref Alloc alloc,
	scope ref ArrayBuilder!LspOutMessage out_,
	ref Server server,
	ref Program program,
) {
	UriAndDiagnostics[] diags = sortedDiagnostics(alloc, asProgramWithOptMain(program));
	ref LspState state() => server.lspState;
	Uri[] newUris = map(state.stateAlloc, diags, (ref UriAndDiagnostics x) => x.uri);
	UriAndDiagnostics[] all = concatenate(
		alloc,
		diags,
		mapOp!(UriAndDiagnostics, Uri)(alloc, state.urisWithDiagnostics, (ref Uri uri) =>
			contains(newUris, uri) ? none!UriAndDiagnostics : some(UriAndDiagnostics(uri, []))));
	() @trusted {
		freeElements!Uri(state.stateAlloc, state.urisWithDiagnostics);
	}();
	state.urisWithDiagnostics = castNonScope(newUris);
	ShowDiagCtx ctx = getShowDiagCtx(server, program);
	foreach (ref UriAndDiagnostics ud; all)
		add(alloc, out_, notification(PublishDiagnosticsParams(ud.uri, map(alloc, ud.diagnostics, (ref Diagnostic x) =>
			LspDiagnostic(
				x.range,
				toLspDiagnosticSeverity(getDiagnosticSeverity(x.kind)),
				stringOfDiag(alloc, ctx, x.kind))))));
}

LspDiagnosticSeverity toLspDiagnosticSeverity(DiagnosticSeverity a) {
	final switch (a) {
		case DiagnosticSeverity.unusedCode:
			return LspDiagnosticSeverity.Hint;
		case DiagnosticSeverity.warning:
			return LspDiagnosticSeverity.Warning;
		case DiagnosticSeverity.checkError:
		case DiagnosticSeverity.nameNotFound:
		case DiagnosticSeverity.importError:
		case DiagnosticSeverity.commonMissing:
		case DiagnosticSeverity.parseError:
			return LspDiagnosticSeverity.Error;
	}
}

LspOutAction initializedAction(ref Alloc alloc, ref Server server) {
	return LspOutAction(newArray!LspOutMessage(alloc, [
		register("textDocument/definition"),
		register("textDocument/documentHighlight"),
		register("textDocument/hover"),
		register("textDocument/rename"),
		register("textDocument/references"),
		register("textDocument/semanticTokens/full"),
	]));
}

LspOutMessage register(string method) =>
	notification(RegisterCapability(method, method));
