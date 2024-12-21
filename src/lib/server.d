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
import document.document : documentModules;
import frontend.getDiagnosticSeverity : getDiagnosticSeverity, hasFatalDiagnostics;
import frontend.ide.getCodeLenses : getCodeLenses;
import frontend.ide.getCompletion : getCompletionForPosition;
import frontend.ide.getDefinition : getDefinitionForPosition, getTypeDefinitionForPosition;
import frontend.ide.getFoldingRanges : foldingRangesOfAst;
import frontend.ide.getHover : getHover;
import frontend.ide.getImplementation : getImplementationForPosition;
import frontend.ide.getInlayHints : getInlayHints;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getRename : getRenameForPosition;
import frontend.ide.getReferences : getDocumentHighlightsForPosition, getReferencesForPosition;
import frontend.ide.getSignatureHelp : getSignatureHelpForPosition;
import frontend.ide.getTokens : jsonOfDecodedTokens, tokensOfAst;
import frontend.ide.position : Position;
import frontend.ide.syntaxTranslate : syntaxTranslate;
import frontend.lang : MainKind;
import frontend.showDiag :
	sortedDiagnostics, stringOfDiag, stringOfDiagnostics, stringOfParseDiagnostics, UriAndDiagnostics;
import frontend.showModel : ShowCtx, ShowDiagCtx, ShowOptions;
import frontend.storage :
	allStorageUris,
	allUrisWithFileDiag,
	changeFile,
	CrowFileInfo,
	fileContentGetters,
	FileInfo,
	FileInfoOrDiag,
	fileOrDiag,
	FilesState,
	filesState,
	lineAndCharacterGetter,
	lineAndCharacterGetters,
	lineAndColumnGetter,
	lineAndColumnGetters,
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
import lib.lsp.lspToJson :
	jsonOfCodeLensResult,
	jsonOfCompletionList,
	jsonOfDocumentHighlight,
	jsonOfFoldingRangeResult,
	jsonOfHover,
	jsonOfInlayHintResult,
	jsonOfReferences,
	jsonOfSignatureHelp,
	jsonOfWorkspaceEdit;
import lib.lsp.lspTypes :
	BuildJsScriptParams,
	BuildJsScriptResult,
	CancelRequestParams,
	CodeLensParams,
	CompletionList,
	CompletionParams,
	DefinitionParams,
	DidChangeTextDocumentParams,
	DidCloseTextDocumentParams,
	DidOpenTextDocumentParams,
	DidSaveTextDocumentParams,
	DocumentHighlightParams,
	DocumentHighlightResult,
	ExecuteCommandParams,
	ExitParams,
	FoldingRangeParams,
	Hover,
	HoverParams,
	ImplementationParams,
	InitializedParams,
	InitializeParams,
	InitializeResult,
	InlayHint,
	InlayHintParams,
	InlayHintRefresh,
	InlayHintResult,
	LspDiagnostic,
	LspDiagnosticSeverity,
	LspInMessage,
	LspInNotification,
	LspInRequest,
	LspInResponse,
	LspOutAction,
	LspOutMessage,
	LspOutNotification,
	LspOutRequest,
	LspOutRequestParams,
	LspOutResponse,
	LspOutResult,
	NullLspOutResult,
	Pipe,
	PublishDiagnosticsParams,
	RangesResult,
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
	SignatureHelp,
	SignatureHelpParams,
	SyntaxTranslateParams,
	TestStates,
	TextDocumentContentChangeEvent,
	TextDocumentPositionParams,
	TypeDefinitionParams,
	UnloadedUris,
	UnloadedUrisParams,
	UnknownUris,
	WorkspaceEdit,
	Write;
import lower.lower : lower;
import model.ast : fileAstForDiag, FileAst;
import model.concreteModel : ConcreteProgram;
import model.integralValues : initIntegralValues;
import model.jsonOfAst : jsonOfAst;
import model.jsonOfConcreteModel : jsonOfConcreteProgram;
import model.jsonOfLowModel : jsonOfLowProgram;
import model.jsonOfModel : jsonOfModule;
import model.lowModel : ExternLibraries, LowProgram;
import model.model :
	asProgramWithOptMain,
	BuildTarget,
	Diagnostic,
	DiagnosticSeverity,
	hasAnyDiagnostics,
	moduleAtUri,
	Program,
	ProgramWithMain,
	ProgramWithOptMain;
import model.parseDiag : ParseDiag, ReadFileDiag;
import model.sourceRange :
	FileContentGetters,
	LineAndCharacterGetter,
	LineAndCharacterGetters,
	LineAndColumn,
	LineAndColumnGetter,
	LineAndColumnGetters,
	toLineAndCharacter,
	UriAndLineAndCharacterRange,
	UriLineAndColumn;
import util.alloc.alloc : Alloc, AllocKind, FetchMemoryCb, freeElements, MetaAlloc, newAlloc, withTempAllocImpure;
import util.alloc.stackAlloc : ensureStackAllocInitialized;
import util.cell : Cell, cellGet, cellSet;
import util.col.array : concatenate, contains, map, mapOp, newArray;
import util.col.arrayBuilder : add, addAll, ArrayBuilder, finish;
import util.col.mutArr : clearAndDoNotFree, MutArr, push;
import util.col.mutMap : clear, setInMap;
import util.exitCode : ExitCode, ExitCodeOrSignal;
import util.json : field, Json, jsonNull, jsonObject;
import util.late : Late, lateGet, lateSet, MutLate;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some;
import util.perf : Perf;
import util.string : copyString, CString, cString;
import util.symbol : initSymbols, Symbol;
import util.uri : FilePath, initUris, stringOfFilePath, Uri, UrisInfo;
import util.union_ : Union;
import util.util : castNonScope;
import versionInfo : JsTarget, OS, VersionInfo, versionInfoForBuildToC, versionInfoForInterpret, VersionOptions;

ExitCodeOrSignal buildAndInterpret(
	scope ref Perf perf,
	ref Server server,
	in Extern extern_,
	in WriteError writeError,
	ref ProgramWithMain program,
	OS os,
	VersionOptions version_,
	in Opt!(Uri[]) diagnosticsOnlyForUris,
	in CString[] allArgs,
) {
	assert(filesState(server) == FilesState.allLoaded);
	return withTempAllocImpure!ExitCodeOrSignal(server.metaAlloc, AllocKind.buildToLowProgram, (ref Alloc buildAlloc) {
		LowProgram lowProgram = buildToLowProgram(
			perf, buildAlloc, server, versionInfoForInterpret(os, version_), program);
		Opt!ExternPointersForAllLibraries externPointers =
			extern_.loadExternPointers(lowProgram.externLibraries, writeError);
		if (has(externPointers))
			return withTempAllocImpure!ExitCodeOrSignal(
				server.metaAlloc, AllocKind.interpreter, (ref Alloc bytecodeAlloc) {
					ByteCode byteCode = generateBytecode(
						perf, bytecodeAlloc, program.program, lowProgram,
						force(externPointers), extern_.aggregateCbs, extern_.makeSyntheticFunPointers);
					return ExitCodeOrSignal(runBytecode(
						perf, getShowDiagCtx(buildAlloc, server, program.program),
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
		(in LspInRequest x) =>
			handleLspRequest(perf, alloc, server, x),
		(in LspInResponse _) =>
			LspOutAction());

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
			changeFile(perf, server, x.textDocument, x.contentChanges);
			return handleFileChanged(perf, alloc, server, x.textDocument);
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
			Program program = getProgram(perf, alloc, server);
			ArrayBuilder!LspOutMessage messages;
			Cell!(Opt!ExitCode) exitCode;
			foreach (LspInRequest request; server.lspState.pendingRequests) {
				LspOutAction action = handleLspRequestWithProgram(perf, alloc, server, program, request);
				addAll(alloc, messages, action.outMessages);
				if (has(action.exitCode)) {
					cellSet(exitCode, action.exitCode);
					break;
				}
			}
			clearAndDoNotFree(server.lspState.pendingRequests);
			notifyDiagnostics(perf, alloc, messages, server, program);
			return LspOutAction(finish(alloc, messages), cellGet(exitCode));
	}
}

// Only returns 'none' if not all files are loaded
private LspOutAction handleLspRequest(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LspInRequest request,
) {
	LspOutAction respond(LspOutResult x) =>
		singleResponse(alloc, request, x);
	LspOutAction needProgram() =>
		respondWithProgram(perf, alloc, server, request);
	return request.params.matchImpure!LspOutAction(
		(in BuildJsScriptParams _) =>
			needProgram(),
		(in CodeLensParams _) =>
			needProgram(),
		(in CompletionParams _) =>
			needProgram(),
		(in DefinitionParams _) =>
			needProgram(),
		(in DocumentHighlightParams _) =>
			needProgram(),
		(in ExecuteCommandParams _) =>
			needProgram(),
		(in FoldingRangeParams x) =>
			respond(LspOutResult(foldingRangesOfAst(alloc, *getCrowFileForTokens(alloc, server, x.textDocument)))),
		(in HoverParams _) =>
			needProgram(),
		(in ImplementationParams _) =>
			needProgram(),
		(in InitializeParams x) {
			server.lspState.supportsUnknownUris = x.initializationOptions.unknownUris;
			return respond(LspOutResult(InitializeResult()));
		},
		(in InlayHintParams _) =>
			needProgram(),
		(in ReferenceParams _) =>
			needProgram(),
		(in RenameParams _) =>
			needProgram(),
		(in RunParams _) =>
			needProgram(),
		(in SemanticTokensParams x) =>
			respond(LspOutResult(tokensOfAst(alloc, *getCrowFileForTokens(alloc, server, x.textDocument)))),
		(in ShutdownParams _) =>
			respond(LspOutResult(NullLspOutResult())),
		(in SignatureHelpParams _) =>
			needProgram(),
		(in SyntaxTranslateParams x) =>
			respond(LspOutResult(syntaxTranslate(alloc, x))),
		(in TypeDefinitionParams _) =>
			needProgram(),
		(in UnloadedUrisParams _) =>
			respond(LspOutResult(UnloadedUris(allUnloadedUris(alloc, server)))));
}

private pure LspOutAction singleResponse(ref Alloc alloc, in LspInRequest request, LspOutResult response) =>
	LspOutAction(
		newArray!LspOutMessage(alloc, [messageForResponse(request, response)]),
		none!ExitCode);

private pure LspOutMessage messageForResponse(in LspInRequest request, LspOutResult result) =>
	LspOutMessage(LspOutResponse(request.id, result));

private LspOutAction respondWithProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in LspInRequest request,
) {
	if (filesState(server) == FilesState.allLoaded) {
		Program program = getProgram(perf, alloc, server);
		return handleLspRequestWithProgram(perf, alloc, server, program, request);
	} else {
		push(server.lspState.stateAlloc, server.lspState.pendingRequests, request);
		return LspOutAction();
	}
}

private LspOutAction handleLspRequestWithProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref Program program,
	in LspInRequest request,
) {
	ProgramWithMain programWithMain(MainKind main, BuildTarget target) =>
		programWithMainFromProgram(perf, alloc, server.frontend, program, main, [target]);
	LspOutAction respond(LspOutResult x) =>
		singleResponse(alloc, request, x);
	return request.params.matchImpure!LspOutAction(
		(in BuildJsScriptParams x) {
			ProgramWithMain pwm = programWithMain(MainKind.fun(x.uri, []), BuildTarget.js);
			return respond(LspOutResult(BuildJsScriptResult(
				showDiagnostics(alloc, server, pwm, x.diagnosticsOnlyForUris),
				optIf(!hasFatalDiagnostics(pwm), () =>
					buildToJsScript(alloc, server, pwm, JsTarget.browser, none!Symbol).js))));
		},
		(in CodeLensParams x) =>
			respond(LspOutResult(getCodeLenses(alloc, program, x))),
		(in CompletionParams x) {
			Opt!CompletionList res = getCompletionForProgram(alloc, server, program, x);
			return respond(has(res) ? LspOutResult(force(res)) : LspOutResult(NullLspOutResult()));
		},
		(in DefinitionParams x) =>
			respond(LspOutResult(RangesResult(getDefinitionForProgram(alloc, server, program, x)))),
		(in DocumentHighlightParams x) {
			Opt!DocumentHighlightResult res = getDocumentHighlightsForProgram(alloc, server, program, x);
			return respond(has(res) ? LspOutResult(force(res)) : LspOutResult(NullLspOutResult()));
		},
		(in ExecuteCommandParams x) =>
			executeCommand(perf, alloc, server, program, request, x),
		(in FoldingRangeParams x) =>
			assert(false),
		(in HoverParams x) {
			Opt!Hover result = getHoverForProgram(alloc, server, program, x);
			return respond(has(result) ? LspOutResult(force(result)) : LspOutResult(NullLspOutResult()));
		},
		(in ImplementationParams x) =>
			respond(LspOutResult(RangesResult(getImplementationForProgram(alloc, server, program, x)))),
		(in InitializeParams _) =>
			assert(false),
		(in InlayHintParams x) =>
			respond(LspOutResult(getInlayHintsForProgram(alloc, server, program, x))),
		(in ReferenceParams x) =>
			respond(LspOutResult(RangesResult(getReferencesForProgram(alloc, server, program, x)))),
		(in RenameParams x) {
			Opt!WorkspaceEdit res = getRenameForProgram(alloc, server, program, x);
			return respond(has(res) ? LspOutResult(force(res)) : LspOutResult(NullLspOutResult()));
		},
		(in RunParams x) {
			ArrayBuilder!Write writes;
			ProgramWithMain pwm = programWithMain(MainKind.fun(x.uri, []), BuildTarget.native(OS.none));
			if (hasAnyDiagnostics(pwm))
				add(alloc, writes, Write(Pipe.stderr, showDiagnostics(alloc, server, pwm, x.diagnosticsOnlyForUris)));
			ExitCodeOrSignal exit = runFromLsp(
				perf, alloc, server, pwm, x.diagnosticsOnlyForUris,
				(Pipe pipe, in string x) {
					add(alloc, writes, Write(pipe, copyString(alloc, x)));
				});
			return respond(LspOutResult(RunResult(exit, finish(alloc, writes))));
		},
		(in SemanticTokensParams _) =>
			assert(false),
		(in ShutdownParams _) =>
			assert(false),
		(in SignatureHelpParams x) {
			Opt!SignatureHelp res = getSignatureHelpForProgram(alloc, server, program, x);
			return respond(has(res) ? LspOutResult(force(res)) : LspOutResult(NullLspOutResult()));
		},
		(in SyntaxTranslateParams x) =>
			assert(false),
		(in TypeDefinitionParams x) =>
			respond(LspOutResult(RangesResult(getTypeDefinitionForProgram(alloc, server, program, x)))),
		(in UnloadedUrisParams _) =>
			assert(false));
}

private LspOutAction executeCommand(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref Program program,
	in LspInRequest request,
	in ExecuteCommandParams params,
) =>
	params.matchImpure!LspOutAction(
		(in ExecuteCommandParams.RunTest x) {
			ProgramWithMain pwm = programWithMainFromProgram(
				perf, alloc, server.frontend, program,
				MainKind.testsAtUri(all: false, x.where.uri, some(x.where.line)), [BuildTarget.native(OS.none)]);
			ArrayBuilder!Write writes;
			ExitCodeOrSignal exit = runFromLsp(perf, alloc, server, pwm, none!(Uri[]), (Pipe pipe, in string text) {
				add(server.lspState.stateAlloc, writes, Write(pipe, copyString(alloc, text)));
			});
			setInMap(
				server.lspState.stateAlloc, server.lspState.testStates, x.where,
				RunResult(exit, finish(server.lspState.stateAlloc, writes)));
			return LspOutAction(
				newArray!LspOutMessage(alloc, [
					messageForResponse(request, LspOutResult(NullLspOutResult())),
					LspOutMessage(LspOutRequest(1, LspOutRequestParams(InlayHintRefresh())))]));
		});

private ExitCodeOrSignal runFromLsp(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	in Opt!(Uri[]) diagnosticsOnlyForUris,
	in WriteCb writeCb,
) =>
	withFakeExtern(alloc, writeCb, (scope ref Extern extern_) {
		CString[1] allArgs = [cString!"/usr/bin/fakeExecutable"];
		if (hasFatalDiagnostics(program)) {
			writeCb(Pipe.stderr, "Can't run due to compile errors");
			return ExitCodeOrSignal.error;
		} else
			return buildAndInterpret(
				perf, server, extern_,
				(in string x) { writeCb(Pipe.stderr, x); },
				program, OS.none,
				VersionOptions(isSingleThreaded: true, stackTraceEnabled: true),
				diagnosticsOnlyForUris, allArgs);
	});

private __gshared Server serverStorage = void;

@system Server* setupServer(return scope FetchMemoryCb fetch) {
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
}
FileContentGetters fileContentGetters(ref Alloc alloc, return scope const ref Server server) =>
	fileContentGetters(alloc, server.storage);
LineAndCharacterGetter lineAndCharacterGetter(ref Alloc alloc, return scope ref const Server server, Uri uri) =>
	lineAndCharacterGetter(alloc, server.storage, uri);
LineAndCharacterGetters lineAndCharacterGetters(ref Alloc alloc, return scope ref const Server server) =>
	lineAndCharacterGetters(alloc, server.storage);
LineAndColumnGetter lineAndColumnGetter(ref Alloc alloc, return scope ref const Server server, Uri uri) =>
	lineAndColumnGetter(alloc, server.storage, uri);
LineAndColumnGetters lineAndColumnGetters(ref Alloc alloc, return scope ref const Server server) =>
	lineAndColumnGetters(alloc, server.storage);

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
	TestStates testStates;

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

private void contentChanged(scope ref Server server) {
	clear(server.lspState.testStates);
}

void setFile(scope ref Perf perf, ref Server server, Uri uri, in ReadFileResult result) {
	contentChanged(server);
	onFileChanged(perf, server.frontend, uri, setFile(perf, server.storage, uri, result));
}
void setFileAssumeUtf8(scope ref Perf perf, ref Server server, Uri uri, in string result) {
	contentChanged(server);
	onFileChanged(perf, server.frontend, uri, FileInfoOrDiag(setFileAssumeUtf8(perf, server.storage, uri, result)));
}
void setFile(scope ref Perf perf, ref Server server, Uri uri, in ubyte[] result) {
	contentChanged(server);
	onFileChanged(perf, server.frontend, uri, FileInfoOrDiag(setFileBytes(perf, server.storage, uri, result)));
}
void setFile(scope ref Perf perf, ref Server server, Uri uri, ReadFileDiag diag) {
	setFile(perf, server, uri, ReadFileResult(diag));
}

void changeFile(scope ref Perf perf, ref Server server, Uri uri, in TextDocumentContentChangeEvent[] changes) {
	contentChanged(server);
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
	stringOfDiagnostics(alloc, getShowDiagCtx(alloc, server, program.program), program, onlyForUris);

Json document(ref Alloc alloc, in Server server, in Program program, in Uri[] uris) =>
	documentModules(alloc, program, getShowDiagCtx(alloc, server, program), uris);

private Opt!CompletionList getCompletionForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in CompletionParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params, GetPositionKind.after);
	return has(position)
		? getCompletionForPosition(alloc, getShowDiagCtx(alloc, server, program, forceNoColor: true), force(position))
		: none!CompletionList;
}

private UriAndLineAndCharacterRange[] getDefinitionForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in DefinitionParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params, GetPositionKind.exact);
	return has(position) ? getDefinitionForPosition(alloc, program, force(position)) : [];
}

private UriAndLineAndCharacterRange[] getImplementationForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in ImplementationParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params, GetPositionKind.exact);
	return has(position) ? getImplementationForPosition(alloc, program, force(position)) : [];
}

private UriAndLineAndCharacterRange[] getTypeDefinitionForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in TypeDefinitionParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.textDocumentAndPosition, GetPositionKind.exact);
	return has(position) ? getTypeDefinitionForPosition(alloc, program, force(position)) : [];
}

private Opt!DocumentHighlightResult getDocumentHighlightsForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in DocumentHighlightParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params, GetPositionKind.exact);
	return has(position)
		? getDocumentHighlightsForPosition(alloc, program, force(position))
		: none!DocumentHighlightResult;
}

private UriAndLineAndCharacterRange[] getReferencesForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in ReferenceParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params, GetPositionKind.exact);
	return has(position) ? getReferencesForPosition(alloc, program, force(position)) : [];
}

private Opt!WorkspaceEdit getRenameForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in RenameParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.textDocumentAndPosition, GetPositionKind.exact);
	return has(position)
		? getRenameForPosition(alloc, program, force(position), params.newName)
		: none!WorkspaceEdit;
}

private Opt!SignatureHelp getSignatureHelpForProgram(
	ref Alloc alloc,
	scope ref Server server,
	in Program program,
	in SignatureHelpParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.textDocumentAndPosition, GetPositionKind.after);
	return has(position)
		? getSignatureHelpForPosition(
			alloc, getShowDiagCtx(alloc, server, program, forceNoColor: true), force(position))
		: none!SignatureHelp;
}

private Opt!Hover getHoverForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in HoverParams params,
) {
	Opt!Position position = serverGetPosition(server, program, params.params, GetPositionKind.exact);
	return optIf(has(position), () =>
		getHover(alloc, getShowDiagCtx(alloc, server, program, forceNoColor: true), force(position)));
}

private InlayHintResult getInlayHintsForProgram(
	ref Alloc alloc,
	in Server server,
	in Program program,
	in InlayHintParams params,
) =>
	getInlayHints(
		alloc,
		program,
		getShowDiagCtx(alloc, server, program, forceNoColor: true),
		server.lspState.testStates,
		params);

Program getProgram(scope ref Perf perf, ref Alloc alloc, ref Server server) =>
	makeProgram(perf, alloc, server.frontend);

ProgramWithMain getProgramForMain(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in MainKind main,
	in BuildTarget[] targets,
) =>
	makeProgramWithMain(perf, alloc, server.frontend, main, targets);

private Opt!Position serverGetPosition(
	in Server server,
	ref Program program,
	in TextDocumentPositionParams where,
	GetPositionKind kind,
) =>
	where.uri in program.allModules
		? getPosition(program, where, kind)
		: none!Position;

struct DiagsAndResultJson {
	string diagnostics;
	Json result;
}

private DiagsAndResultJson printForAst(ref Alloc alloc, ref Server server, Uri uri, in FileAst ast, Json result) =>
	DiagsAndResultJson(
		stringOfParseDiagnostics(alloc, getShowCtx(alloc, server), uri, ast.parseDiagnostics),
		result);

DiagsAndResultJson printAst(scope ref Perf perf, ref Alloc alloc, ref Server server, Uri uri) {
	CrowFileInfo* file = getCrowFileForTokens(alloc, server, uri);
	return printForAst(
		alloc, server, uri, file.ast, jsonOfAst(alloc, lineAndColumnGetter(alloc, server, uri), file.ast));
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
	jsonOfModule(alloc, lineAndColumnGetter(alloc, server, uri), *moduleAtUri(program, uri));

Json jsonOfConcreteModel(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) =>
	jsonOfConcreteProgram(
		alloc, lineAndColumnGetters(alloc, server),
		concretize(perf, alloc, getShowDiagCtx(alloc, server, program.program), versionInfo, program));

Json jsonOfLowModel(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) =>
	jsonOfLowProgram(
		alloc, lineAndColumnGetters(alloc, server), buildToLowProgram(perf, alloc, server, versionInfo, program));

immutable struct PrintKind {
	mixin Union!(PrintAst, PrintModel, PrintConcreteModel, PrintLowModel, PrintIdeAtPos, PrintIdeWholeFile);
}
immutable struct PrintAst {}
immutable struct PrintModel {}
immutable struct PrintConcreteModel {}
immutable struct PrintLowModel {}
immutable struct PrintIdeAtPos {
	PrintIdeAtPosKind kind;
	LineAndColumn lineAndColumn;
}
enum PrintIdeAtPosKind {
	completion,
	definition,
	documentHighlight,
	hover,
	implementation,
	references,
	rename,
	signatureHelp,
	typeDefinition,
}
enum PrintIdeWholeFile {
	codeLenses,
	foldingRanges,
	inlayHints,
	tokens,
}

Json jsonForPrintIdeAtPos(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref Program program,
	in UriLineAndColumn where,
	PrintIdeAtPosKind kind,
) {
	TextDocumentPositionParams params = TextDocumentPositionParams(
		where.uri,
		toLineAndCharacter(lineAndColumnGetter(alloc, server, where.uri), where.pos));
	Json locations(UriAndLineAndCharacterRange[] xs) =>
		jsonOfReferences(alloc, xs);
	final switch (kind) {
		case PrintIdeAtPosKind.completion:
			Opt!CompletionList res = getCompletionForProgram(alloc, server, program, CompletionParams(params));
			return has(res) ? jsonOfCompletionList(alloc, force(res)) : jsonNull;
		case PrintIdeAtPosKind.definition:
			return locations(getDefinitionForProgram(alloc, server, program, DefinitionParams(params)));
		case PrintIdeAtPosKind.documentHighlight:
			Opt!DocumentHighlightResult res = getDocumentHighlightsForProgram(
				alloc, server, program, DocumentHighlightParams(params));
			return has(res) ? jsonOfDocumentHighlight(alloc, force(res)) : jsonNull;
		case PrintIdeAtPosKind.hover:
			Opt!Hover res = getHoverForProgram(alloc, server, program, HoverParams(params));
			return has(res) ? jsonOfHover(alloc, force(res)) : jsonNull;
		case PrintIdeAtPosKind.implementation:
			return locations(getImplementationForProgram(alloc, server, program, ImplementationParams(params)));
		case PrintIdeAtPosKind.rename:
			Opt!WorkspaceEdit rename = getRenameForProgram(alloc, server, program, RenameParams(params, "new-name"));
			return has(rename) ? jsonOfWorkspaceEdit(alloc, force(rename)) : jsonNull;
		case PrintIdeAtPosKind.references:
			return locations(getReferencesForProgram(alloc, server, program, ReferenceParams(params)));
		case PrintIdeAtPosKind.signatureHelp:
			Opt!SignatureHelp res = getSignatureHelpForProgram(alloc, server, program, SignatureHelpParams(params));
			return has(res) ? jsonOfSignatureHelp(alloc, force(res)) : jsonNull;
		case PrintIdeAtPosKind.typeDefinition:
			return locations(getTypeDefinitionForProgram(alloc, server, program, TypeDefinitionParams(params)));
	}
}

Json jsonForPrintIdeWholeFile(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Server server,
	ref Program program,
	in Uri uri,
	PrintIdeWholeFile kind,
) {
	final switch (kind) {
		case PrintIdeWholeFile.codeLenses:
			return jsonOfCodeLensResult(alloc, getCodeLenses(alloc, program, CodeLensParams(uri)));
		case PrintIdeWholeFile.foldingRanges:
			CrowFileInfo* file = getCrowFileForTokens(alloc, server, uri);
			return jsonOfFoldingRangeResult(alloc, foldingRangesOfAst(alloc, *file));
		case PrintIdeWholeFile.inlayHints:
			return jsonOfInlayHintResult(
				alloc,
				getInlayHintsForProgram(alloc, server, program, InlayHintParams(uri)));
		case PrintIdeWholeFile.tokens:
			CrowFileInfo* file = getCrowFileForTokens(alloc, server, uri);
			return jsonOfDecodedTokens(alloc, tokensOfAst(alloc, *file));
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
	ShowCtx ctx = getShowDiagCtx(alloc, server, program.program);
	ConcreteProgram concreteProgram = concretize(perf, alloc, ctx, versionInfo, program);
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
		writeToC(alloc, getShowDiagCtx(alloc, server, program.program), lowProgram, params),
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
		alloc, program, getShowDiagCtx(alloc, server, program.program, forceNoColor: true), target, sourceMapName);
}

JsModules buildToJsModules(
	ref Alloc alloc,
	ref Server server,
	ref ProgramWithMain program,
	JsTarget target,
) =>
	translateToJsModules(
		alloc, program, getShowDiagCtx(alloc, server, program.program, forceNoColor: true), target);

ShowDiagCtx getShowDiagCtx(
	ref Alloc alloc,
	return scope ref const Server server,
	return scope ref Program program,
	bool forceNoColor = false,
) =>
	ShowDiagCtx(getShowCtx(alloc, server, forceNoColor: forceNoColor), program.commonTypesPtr);

ShowCtx getShowCtx(ref Alloc alloc, return scope ref const Server server, bool forceNoColor = false) =>
	ShowCtx(
		lineAndColumnGetters(alloc, server),
		fileContentGetters(alloc, server),
		server.urisInfo,
		forceNoColor ? server.showOptions.withoutColor : server.showOptions);

private:

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
	ShowDiagCtx ctx = getShowDiagCtx(alloc, server, program);
	foreach (ref UriAndDiagnostics ud; all)
		add(alloc, out_, notification(PublishDiagnosticsParams(ud.uri, map(alloc, ud.diagnostics, (ref Diagnostic x) =>
			LspDiagnostic(
				lineAndCharacterGetter(alloc, server, ud.uri)[x.range],
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
		register("textDocument/codeLens"),
		register("textDocument/completion"),
		register("textDocument/definition"),
		register("textDocument/documentHighlight"),
		register("textDocument/foldingRange"),
		register("textDocument/hover"),
		register("textDocument/implementation"),
		register("textDocument/inlayHint"),
		register("textDocument/rename"),
		register("textDocument/references"),
		register("textDocument/semanticTokens/full"),
		register("textDocument/signatureHelp"),
		register("textDocument/typeDefinition"),
		register("workspace/executeCommand"),
	]));
}

LspOutMessage register(string method) =>
	notification(RegisterCapability(method, method));
