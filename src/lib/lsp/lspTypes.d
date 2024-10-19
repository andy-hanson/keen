module lib.lsp.lspTypes;

@safe @nogc pure nothrow:

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/

import util.alloc.alloc : Alloc;
import util.exitCode : ExitCode, ExitCodeOrSignal;
import util.col.map : KeyValuePair;
import util.opt : Opt;
import util.sourceRange :
	LineAndCharacter,
	LineAndCharacterRange,
	Pos,
	Range,
	UriAndLine,
	UriAndRange,
	UriLineAndCharacter,
	UriAndLineAndCharacterRange;
import util.string : SmallString;
import util.union_ : Union;
import util.uri : Uri;

// Types and their properties are a subset of what's in the LSP.
// For output types, they also use Range instead of LineAndCharacterRange. Use LineAndColumnGetters to convert.
// (This makes it easier to use a LineAndColumnRange instead for text output.)

private alias Location = UriAndLineAndCharacterRange;
alias Position = LineAndCharacter;
alias TextDocumentIdentifier = Uri;
alias TextDocumentPositionParams = UriLineAndCharacter;

immutable struct LspInMessage {
	mixin Union!(LspInNotification, LspInRequest, LspInResponse);
}

immutable struct LspInNotification {
	mixin Union!(
		CancelRequestParams,
		DidChangeTextDocumentParams,
		DidCloseTextDocumentParams,
		DidOpenTextDocumentParams,
		DidSaveTextDocumentParams,
		ExitParams,
		InitializedParams,
		ReadFileResultParams,
		SetTraceParams);
}

immutable struct LspInRequest {
	uint id;
	LspInRequestParams params;
}
immutable struct LspInRequestParams {
	mixin Union!(
		BuildJsScriptParams,
		CodeLensParams,
		CompletionParams,
		DefinitionParams,
		DocumentHighlightParams,
		ExecuteCommandParams,
		FoldingRangeParams,
		HoverParams,
		ImplementationParams,
		InitializeParams,
		InlayHintParams,
		ReferenceParams,
		RenameParams,
		RunParams,
		SemanticTokensParams,
		ShutdownParams,
		SignatureHelpParams,
		SyntaxTranslateParams,
		TypeDefinitionParams,
		UnloadedUrisParams);
}
immutable struct LspInResponse {
	// Nothing here for now since we don't need the response
}

immutable struct LspOutAction {
	LspOutMessage[] outMessages;
	Opt!ExitCode exitCode;
}

immutable struct LspOutMessage {
	mixin Union!(LspOutNotification, LspOutRequest, LspOutResponse);
}
immutable struct LspOutNotification {
	mixin Union!(
		PublishDiagnosticsParams,
		RegisterCapability,
		UnknownUris);
}
immutable struct LspOutRequest {
	uint id;
	LspOutRequestParams params;
}
immutable struct LspOutRequestParams {
	mixin Union!(InlayHintRefresh);
}
immutable struct InlayHintRefresh {}

immutable struct LspOutResponse {
	uint id;
	LspOutResult result;
}
immutable struct LspOutResult {
	immutable struct Null {}
	mixin Union!(
		BuildJsScriptResult,
		CodeLens[],
		CompletionList,
		DocumentHighlightResult,
		FoldingRange[],
		InitializeResult,
		InlayHint,
		InlayHint[],
		Opt!Hover,
		RunResult,
		SemanticTokens,
		SignatureHelp,
		SyntaxTranslateResult,
		UnloadedUris,
		UriAndRange[], // for definition, implementation, or references
		WorkspaceEdit, // for rename
		Null,
	);
}

immutable struct RegisterCapability {
	string id;
	string method;
}

// Only used if it's in InitializeOptions. (Currently that is true for VSCode but not for Sublime Text.)
// The editor should send back a readFileResult notification for each unknown URI.
immutable struct UnknownUris {
	Uri[] unknownUris;
}

immutable struct InitializeResult {
	// We'll just hardcode toJson
}

immutable struct SetTraceParams {
	TraceValue value;
}
enum TraceValue { off, messages, verbose }

enum Language { c, crow, java }
immutable struct SyntaxTranslateParams {
	string source;
	Language from;
	Language to;
}
immutable struct SyntaxTranslateResult {
	string output;
	Pos[] diagnostics;
}

// Parameter to "custom/readFileResult"
immutable struct ReadFileResultParams {
	Uri uri;
	ReadFileResultType type;
	ubyte[] content;
}
enum ReadFileResultType { ok, notFound, error }
// Parameter to "custom/build-js-script"
immutable struct BuildJsScriptParams {
	Uri uri;
	Opt!(Uri[]) diagnosticsOnlyForUris;
}
immutable struct BuildJsScriptResult {
	string diagnostics;
	Opt!string script;
}
// Parameter to "custom/run"
immutable struct RunParams {
	Uri uri;
	Opt!(Uri[]) diagnosticsOnlyForUris;
}
immutable struct RunResult {
	ExitCodeOrSignal exit;
	Write[] writes;
}
immutable struct Write {
	Pipe pipe;
	string text;
}
enum Pipe { stdout, stderr }

// Parameter to "custom/unloadedUris"
immutable struct UnloadedUrisParams {}
immutable struct UnloadedUris {
	Uri[] unloadedUris;
}

immutable struct CancelRequestParams {
	uint id;
}

immutable struct ExitParams {}

immutable struct InitializeParams {
	InitializationOptions initializationOptions;
	TraceValue trace;
}
immutable struct InitializationOptions {
	bool unknownUris;
}
immutable struct InitializedParams {}

immutable struct ShutdownParams {}

immutable struct CodeLensParams {
	TextDocumentIdentifier textDocument;
}

immutable struct CodeLens {
	LineAndCharacterRange range;
	Command command;
}
immutable struct Command {
	string title;
	Opt!string tooltip;
	// This also determines 'command'.
	// Arguments must be represented as an array.
	Opt!ExecuteCommandParams arguments;
}

immutable struct ExecuteCommandParams {
	immutable struct RunTest {
		UriAndLine where;
	}
	mixin Union!(RunTest);
}

immutable struct CompletionParams {
	TextDocumentPositionParams params;
}

immutable struct CompletionList {
	CompletionItem[] items;
}
immutable struct CompletionItem {
	string label;
	string detail; // E.g., the full function signature
	string documentation;
}

immutable struct DefinitionParams {
	TextDocumentPositionParams params;
}

immutable struct ImplementationParams {
	TextDocumentPositionParams params;
}

immutable struct DidChangeTextDocumentParams {
	TextDocumentIdentifier textDocument;
	TextDocumentContentChangeEvent[] contentChanges;
}

immutable struct DidCloseTextDocumentParams {}

immutable struct DidSaveTextDocumentParams {
	TextDocumentIdentifier textDocument;
}

immutable struct DidOpenTextDocumentParams {
	TextDocumentItem textDocument;
}

immutable struct TextDocumentItem {
	Uri uri;
	string text;
}

immutable struct HoverParams {
	TextDocumentPositionParams params;
}
immutable struct Hover {
	MarkupContent contents;
}
immutable struct MarkupContent {
	MarkupKind kind;
	string value;
}
enum MarkupKind {
	plaintext,
	markdown,
}

immutable struct PublishDiagnosticsParams {
	Uri uri;
	LspDiagnostic[] diagnostics;
}

immutable struct TextDocumentContentChangeEvent {
	Opt!LineAndCharacterRange range;
	string text;
}

immutable struct LspDiagnostic {
	Range range;
	LspDiagnosticSeverity severity;
	string message;
}

enum LspDiagnosticSeverity {
	Error = 1,
	Warning = 2,
	Information = 3,
	Hint = 4,
}

immutable struct RenameParams {
	TextDocumentPositionParams textDocumentAndPosition; // This appears in JSON as two separate properties
	string newName;
}

immutable struct ReferenceParams {
	TextDocumentPositionParams params;
}

immutable struct DocumentHighlightParams {
	TextDocumentPositionParams params;
}

// Result for a document highlight can also be Null instead of this
immutable struct DocumentHighlightResult {
	Uri uri;
	DocumentHighlight[] highlights;
}
immutable struct DocumentHighlight {
	Range range;
	DocumentHighlightKind kind;
}
enum DocumentHighlightKind {
	Text = 1,
	Read = 2,
	Write = 3,
}

immutable struct SemanticTokensParams {
	TextDocumentIdentifier textDocument;
}

immutable struct WorkspaceEdit {
	KeyValuePair!(Uri, TextEdit[])[] changes;
}

immutable struct TextEdit {
	Range range;
	string newText;
}

immutable struct SemanticTokens {
	uint[] data;
}

immutable struct SignatureHelpParams {
	TextDocumentPositionParams textDocumentAndPosition;
}

immutable struct SignatureHelp {
	SignatureInformation[] signatures;
	Opt!uint activeSignature;
	Opt!uint activeParameter;
}

immutable struct SignatureInformation {
	string label;
	SmallString documentation;
	ParameterInformation[] parameters;
	Opt!uint activeParameter;
}

immutable struct ParameterInformation {
	// This is actually a range of UTF-16 characters
	Range label;
	SmallString documentation; // omitted if empty
}

immutable struct TypeDefinitionParams {
	TextDocumentPositionParams textDocumentAndPosition;
}

immutable struct InlayHintParams {
	TextDocumentIdentifier textDocument;
	LineAndCharacterRange range;
}

immutable struct InlayHint {
	LineAndCharacter position;
	InlayHintLabel label;
	InlayHintKind kind;
	bool paddingLeft;
}
enum InlayHintKind { none = 0, Type = 1, Parameter = 2 }

immutable struct InlayHintLabel {
	mixin Union!(string, InlayHintLabelPart[]);
}
immutable struct InlayHintLabelPart {
	string value;
	Opt!string tooltip;
	Opt!Location location;
	Opt!Command command;
}

immutable struct FoldingRangeParams {
	TextDocumentIdentifier textDocument;
}
immutable struct FoldingRange {
	uint startLine;
	uint endLine;
	Opt!FoldingRangeKind kind;
}
enum FoldingRangeKind { comment, imports, region }
