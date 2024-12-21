module lib.lsp.lspToJson;

@safe @nogc pure nothrow:

import frontend.ide.getTokens : getTokensLegend;
import lib.lsp.lspTypes :
	BuildJsScriptResult,
	CodeLens,
	CodeLensResult,
	Command,
	CompletionItem,
	CompletionList,
	DocumentHighlight,
	DocumentHighlightResult,
	ExecuteCommandParams,
	FoldingRange,
	FoldingRangeKind,
	FoldingRangeResult,
	Hover,
	InitializeResult,
	InlayHint,
	InlayHintLabel,
	InlayHintLabelPart,
	InlayHintRefresh,
	InlayHintResult,
	LspDiagnostic,
	LspOutAction,
	LspOutMessage,
	LspOutNotification,
	LspOutRequest,
	LspOutResponse,
	LspOutResult,
	MarkupContent,
	NullLspOutResult,
	ParameterInformation,
	PublishDiagnosticsParams,
	RangesResult,
	RegisterCapability,
	RunResult,
	SemanticTokens,
	SignatureHelp,
	SignatureInformation,
	SyntaxTranslateResult,
	TextEdit,
	UnknownUris,
	UnloadedUris,
	WorkspaceEdit,
	Write;
import model.sourceRange :
	jsonOfLineAndCharacter,
	jsonOfLineAndCharacterRange,
	jsonOfUriAndLine,
	jsonOfUriAndLineAndCharacterRange,
	Pos,
	UriAndLineAndCharacterRange;
import util.alloc.alloc : Alloc;
import util.col.array : map;
import util.col.map : KeyValuePair;
import util.exitCode : ExitCode, Signal;
import util.json : field, Json, jsonBool, jsonList, jsonNull, jsonObject, jsonString, optionalField, optionalFlagField;
import util.opt : force, has, Opt;
import util.uri : stringOfUri, symbolOfUri, Uri;
import util.util : stringOfEnum;

Json jsonOfLspOutAction(ref Alloc alloc, in LspOutAction a) =>
	jsonObject(alloc, [
		field!"messages"(jsonList(map(alloc, a.outMessages, (ref LspOutMessage x) =>
			jsonOfLspOutMessage(alloc, x)))),
		optionalField!("exit-code", ExitCode)(a.exitCode, (ExitCode x) =>
			Json(x.value))]);

Json jsonOfLspOutMessage(ref Alloc alloc, ref LspOutMessage a) =>
	a.match!Json(
		(LspOutNotification x) =>
			jsonOfLspOutNotification(alloc, x),
		(LspOutRequest x) =>
			jsonOfLspOutRequest(alloc, x),
		(LspOutResponse x) =>
			jsonObject(alloc, [
				field!"id"(x.id),
				field!"result"(jsonOfLspOutResult(alloc, x.result))]));

private:

Json jsonOfLspOutRequest(ref Alloc alloc, in LspOutRequest a) =>
	a.params.matchIn!Json(
		(in InlayHintRefresh x) =>
			jsonObject(alloc, [
				field!"id"(a.id),
				field!"method"("workspace/inlayHint/refresh")]));

Json jsonOfLspOutNotification(ref Alloc alloc, ref LspOutNotification a) {
	Json res(string method, Json params) =>
		jsonObject(alloc, [field!"method"(method), field!"params"(params)]);
	return a.match!Json(
		(PublishDiagnosticsParams x) =>
			res("textDocument/publishDiagnostics", jsonOfPublishDiagnosticsParams(alloc, x)),
		(RegisterCapability x) =>
			res("client/registerCapability", jsonObject(alloc, [
				field!"id"(x.id),
				field!"method"(x.method)])),
		(UnknownUris x) =>
			res("custom/unknownUris", jsonObject(alloc, [
				field!"unknownUris"(jsonList!Uri(alloc, x.unknownUris, (in Uri x) =>
					Json(stringOfUri(alloc, x))))])));
}

Json jsonOfLspOutResult(ref Alloc alloc, ref LspOutResult a) =>
	a.match!Json(
		(BuildJsScriptResult x) =>
			jsonObject(alloc, [field!"diagnostics"(x.diagnostics), optionalField!"script"(x.script)]),
		(CodeLensResult x) =>
			jsonOfCodeLensResult(alloc, x),
		(CompletionList x) =>
			jsonOfCompletionList(alloc, x),
		(DocumentHighlightResult x) =>
			jsonOfDocumentHighlight(alloc, x),
		(FoldingRangeResult x) =>
			jsonOfFoldingRangeResult(alloc, x),
		(InitializeResult _) =>
			jsonObject(alloc, [field!"capabilities"(initializeCapabilities(alloc))]),
		(InlayHint x) =>
			jsonOfInlayHint(alloc, x),
		(InlayHintResult x) =>
			jsonOfInlayHintResult(alloc, x),
		(Hover x) =>
			jsonOfHover(alloc, x),
		(RangesResult x) =>
			jsonOfReferences(alloc, x.ranges),
		(RunResult x) =>
			jsonOfRunResult(alloc, x),
		(SemanticTokens x) =>
			jsonObject(alloc, [field!"data"(jsonList(alloc, x.data, (in uint i) => Json(i)))]),
		(SignatureHelp x) =>
			jsonOfSignatureHelp(alloc, x),
		(SyntaxTranslateResult x) =>
			jsonObject(alloc, [
				field!"output"(x.output),
				field!"diagnostics"(jsonList(alloc, x.diagnostics, (in Pos x) => Json(x)))]),
		(UnloadedUris x) =>
			jsonObject(alloc, [field!"unloadedUris"(jsonList!Uri(alloc, x.unloadedUris, (in Uri x) =>
				Json(stringOfUri(alloc, x))))]),
		(WorkspaceEdit x) =>
			jsonOfWorkspaceEdit(alloc, x),
		(NullLspOutResult _) =>
			jsonNull);

Json jsonOfRunResult(ref Alloc alloc, in RunResult a) =>
	jsonObject(alloc, [
		field!"exit"(a.exit.match!Json(
			(ExitCode x) =>
				jsonObject(alloc, [field!"exit-code"(x.value)]),
			(Signal x) =>
				jsonObject(alloc, [field!"signal"(x.signal)]))),
		field!"writes"(jsonList(map(alloc, a.writes, (ref Write x) =>
			jsonOfWrite(alloc, x))))]);

Json jsonOfWrite(ref Alloc alloc, Write a) =>
	jsonObject(alloc, [
		field!"pipe"(stringOfEnum(a.pipe)),
		field!"text"(a.text)]);

Json initializeCapabilities(ref Alloc alloc) =>
	jsonObject(alloc, [
		field!"textDocumentSync"(2), // incremental
		field!"codeLensProvider"(jsonObject(alloc, [])),
		field!"completionProvider"(jsonObject(alloc, [
			field!"triggerCharacters"(jsonList(alloc, [jsonString(".")]))])),
		field!"definitionProvider"(jsonObject([])),
		field!"documentHighlightProvider"(jsonObject([])),
		field!"executeCommandProvider"(jsonObject(alloc, [
			field!"commands"(jsonList(alloc, [jsonString("run-test")]))])),
		field!"foldingRangeProvider"(jsonObject([])),
		field!"hoverProvider"(jsonObject([])),
		field!"implementationProvider"(jsonObject([])),
		field!"inlayHintProvider"(jsonObject(alloc, [])),
		field!"referencesProvider"(jsonObject([])),
		field!"renameProvider"(jsonObject([])),
		field!"semanticTokensProvider"(jsonObject(alloc, [
			field!"full"(jsonBool(true)),
			field!"legend"(getTokensLegend(alloc))])),
		field!"signatureHelpProvider"(jsonObject(alloc, [
			field!"triggerCharacters"(jsonList(alloc, [jsonString(",")]))])),
		field!"typeDefinitionProvider"(jsonObject([]))]);

Json jsonOfPublishDiagnosticsParams(ref Alloc alloc, in PublishDiagnosticsParams a) =>
	jsonObject(alloc, [
		field!"uri"(stringOfUri(alloc, a.uri)),
		field!"diagnostics"(jsonList(map(alloc, a.diagnostics, (ref LspDiagnostic x) =>
			jsonOfDiagnostic(alloc, x))))]);

public Json jsonOfHover(ref Alloc alloc, in Hover a) =>
	jsonObject(alloc, [field!"contents"(jsonOfMarkupContent(alloc, a.contents))]);

public Json jsonOfCodeLensResult(ref Alloc alloc, in CodeLensResult a) =>
	jsonList(map(alloc, a.lenses, (ref CodeLens x) =>
		jsonOfCodeLens(alloc, x)));
Json jsonOfCodeLens(ref Alloc alloc, ref CodeLens a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndCharacterRange(alloc, a.range)),
		field!"command"(jsonOfCommand(alloc, a.command))]);
Json jsonOfCommand(ref Alloc alloc, ref Command a) =>
	has(a.arguments)
		? force(a.arguments).matchIn!Json(
			(in ExecuteCommandParams.RunTest x) =>
				jsonObject(alloc, [
					field!"title"(a.title),
					optionalField!"tooltip"(a.tooltip),
					field!"command"("run-test"),
					field!"arguments"(jsonList(alloc, [jsonOfUriAndLine(alloc, x.where)]))]))
		: jsonObject(alloc, [
			field!"title"(a.title),
			optionalField!"tooltip"(a.tooltip)]);

public Json jsonOfCompletionList(ref Alloc alloc, in CompletionList a) =>
	jsonObject(alloc, [
		field!"items"(jsonList(map(alloc, a.items, (ref CompletionItem x) =>
			jsonOfCompletionItem(alloc, x))))]);
Json jsonOfCompletionItem(ref Alloc alloc, ref CompletionItem a) =>
	jsonObject(alloc, [
		field!"label"(a.label),
		field!"detail"(a.detail),
		field!"documentation"(a.documentation)]);

public Json jsonOfDocumentHighlight(ref Alloc alloc, in DocumentHighlightResult a) =>
	jsonList!DocumentHighlight(alloc, a.highlights, (in DocumentHighlight x) =>
		jsonObject(alloc, [
			field!"range"(jsonOfLineAndCharacterRange(alloc, x.range)),
			field!"kind"(uint(x.kind))]));

public Json jsonOfInlayHintResult(ref Alloc alloc, in InlayHintResult a) =>
	jsonList(map(alloc, a.hints, (ref InlayHint x) =>
		jsonOfInlayHint(alloc, x)));
Json jsonOfInlayHint(ref Alloc alloc, ref InlayHint a) =>
	jsonObject(alloc, [
		field!"position"(jsonOfLineAndCharacter(alloc, a.position)),
		field!"label"(jsonOfInlayHintLabel(alloc, a.label)),
		optionalFlagField!"paddingLeft"(a.paddingLeft)]);

Json jsonOfInlayHintLabel(ref Alloc alloc, ref InlayHintLabel a) =>
	a.match!Json(
		(string x) =>
			jsonString(x),
		(InlayHintLabelPart[] xs) =>
			jsonList(map(alloc, xs, (ref InlayHintLabelPart x) =>
				jsonOfInlayHintLabelPart(alloc, x))));
Json jsonOfInlayHintLabelPart(ref Alloc alloc, ref InlayHintLabelPart a) =>
	jsonObject(alloc, [
		field!"value"(a.value),
		optionalField!"tooltip"(a.tooltip),
		optionalField!("location", UriAndLineAndCharacterRange)(a.location, (in UriAndLineAndCharacterRange x) =>
			jsonOfUriAndLineAndCharacterRange(alloc, x)),
		optionalField!("command", Command)(a.command, (Command x) =>
			jsonOfCommand(alloc, x))]);

public Json jsonOfReferences(ref Alloc alloc, in UriAndLineAndCharacterRange[] references) =>
	jsonList!UriAndLineAndCharacterRange(alloc, references, (in UriAndLineAndCharacterRange x) =>
		jsonOfUriAndLineAndCharacterRange(alloc, x));

Json jsonOfDiagnostic(ref Alloc alloc, LspDiagnostic a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndCharacterRange(alloc, a.range)),
		field!"severity"(cast(uint) a.severity),
		field!"message"(a.message)]);

public Json jsonOfWorkspaceEdit(ref Alloc alloc, in WorkspaceEdit a) =>
	jsonObject(alloc, [field!"changes"(jsonOfWorkspaceEditChanges(alloc, a.changes))]);

Json jsonOfWorkspaceEditChanges(ref Alloc alloc, in KeyValuePair!(Uri, TextEdit[])[] a) =>
	Json(map(alloc, a, (ref const KeyValuePair!(Uri, TextEdit[]) x) =>
		Json.ObjectField(symbolOfUri(x.key), jsonOfTextEdits(alloc, x.value))));

Json jsonOfTextEdits(ref Alloc alloc, in TextEdit[] a) =>
	jsonList(map!(Json, TextEdit)(alloc, a, (ref TextEdit x) =>
		jsonOfTextEdit(alloc, x)));

Json jsonOfTextEdit(ref Alloc alloc, ref TextEdit a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndCharacterRange(alloc, a.range)),
		field!"newText"(a.newText)]);

Json jsonOfMarkupContent(ref Alloc alloc, in MarkupContent a) =>
	jsonObject(alloc, [
		field!"kind"(stringOfEnum(a.kind)),
		field!"value"(jsonString(alloc, a.value))]);

public Json jsonOfSignatureHelp(ref Alloc alloc, in SignatureHelp a) =>
	jsonObject(alloc, [
		field!"signatures"(jsonList(map(alloc, a.signatures, (ref SignatureInformation x) =>
			jsonOfSignatureInformation(alloc, x)))),
		optionalField!"activeSignature"(a.activeSignature),
		optionalField!"activeParameter"(a.activeParameter)]);

Json jsonOfSignatureInformation(ref Alloc alloc, ref SignatureInformation a) =>
	jsonObject(alloc, [
		field!"label"(a.label),
		field!"documentation"(a.documentation),
		field!"parameters"(jsonList(map(alloc, a.parameters, (ref ParameterInformation x) =>
			jsonOfParameterInformation(alloc, x)))),
		optionalField!"activeParameter"(a.activeParameter)]);

Json jsonOfParameterInformation(ref Alloc alloc, ref ParameterInformation a) =>
	jsonObject(alloc, [
		field!"label"(jsonList(alloc, [Json(a.label.start), Json(a.label.end)]))]);

public Json jsonOfFoldingRangeResult(ref Alloc alloc, in FoldingRangeResult a) =>
	jsonList!FoldingRange(alloc, a.ranges, (in FoldingRange x) =>
		jsonOfFoldingRange(alloc, x));
Json jsonOfFoldingRange(ref Alloc alloc, in FoldingRange a) =>
	jsonObject(alloc, [
		field!"startLine"(a.startLine),
		field!"endLine"(a.endLine),
		optionalField!("kind", FoldingRangeKind)(a.kind, (FoldingRangeKind x) => jsonString(stringOfEnum(x)))]);
