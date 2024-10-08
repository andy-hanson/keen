module lib.lsp.lspTypes;

@safe @nogc pure nothrow:

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/

import util.exitCode : ExitCode;
import util.col.multiMap : MultiMap;
import util.opt : Opt;
import util.sourceRange : LineAndCharacter, LineAndCharacterRange, Pos, Range, UriAndRange;
import util.string : SmallString;
import util.union_ : Union;
import util.uri : Uri;

// Types and their properties are a subset of what's in the LSP.
// For output types, they also use Range instead of LineAndCharacterRange. Use LineAndColumnGetters to convert.
// (This makes it easier to use a LineAndColumnRange instead for text output.)

alias Position = LineAndCharacter;

immutable struct LspInMessage {
	mixin Union!(LspInNotification, LspInRequest);
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
		CodeLensUnresolved,
		CompletionParams,
		DefinitionParams,
		DocumentHighlightParams,
		FoldingRangeParams,
		HoverParams,
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

immutable struct LspOutAction {
	LspOutMessage[] outMessages;
	Opt!ExitCode exitCode;
}

immutable struct LspOutMessage {
	mixin Union!(LspOutNotification, LspOutResponse);
}
immutable struct LspOutNotification {
	mixin Union!(
		PublishDiagnosticsParams,
		RegisterCapability,
		UnknownUris);
}
immutable struct LspOutResponse {
	uint id;
	LspOutResult result;
}
immutable struct LspOutResult {
	immutable struct Null {}
	mixin Union!(
		BuildJsScriptResult,
		CodeLensResolved,
		CodeLensUnresolved[],
		CompletionList,
		DocumentHighlightResult,
		FoldingRange[],
		InitializeResult,
		InlayHintResult,
		Opt!Hover,
		RunResult,
		SemanticTokens,
		SignatureHelp,
		SyntaxTranslateResult,
		UnloadedUris,
		UriAndRange[], // for definition or references
		Opt!WorkspaceEdit, // for rename
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
	ExitCode exitCode;
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
// LSP has these as a single type 'CodeLens'
immutable struct CodeLensUnresolved {
	LineAndCharacterRange range;
	// This could be any type. I need the URI to combine with the range to see what it was a code lens for.
	Uri data;
}

immutable struct CodeLensResolved {
	LineAndCharacterRange range;
	Command command;
}
immutable struct Command {
	string title;
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

immutable struct TextDocumentPositionParams {
	TextDocumentIdentifier textDocument;
	Position position;
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

immutable struct TextDocumentIdentifier {
	Uri uri;
}

immutable struct WorkspaceEdit {
	MultiMap!(Uri, TextEdit) changes;
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
// JSON output is just an array, but we need the URI to help translate it
immutable struct InlayHintResult {
	Uri uri;
	InlayHint[] hints;
}
immutable struct InlayHint {
	Pos position;
	string label;
	InlayHintKind kind;
	bool paddingLeft;
	bool paddingRight;
}
enum InlayHintKind { none = 0, Type = 1, Parameter = 2 }

immutable struct FoldingRangeParams {
	TextDocumentIdentifier textDocument;
}
immutable struct FoldingRange {
	uint startLine;
	uint endLine;
	Opt!FoldingRangeKind kind;
}
enum FoldingRangeKind { comment, imports, region }
