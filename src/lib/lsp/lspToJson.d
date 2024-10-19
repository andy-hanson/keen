module lib.lsp.lspToJson;

@safe @nogc pure nothrow:

import frontend.ide.getTokens : getTokensLegend;
import frontend.storage : LineAndCharacterGetters;
import lib.lsp.lspTypes :
	BuildJsScriptResult,
	CodeLens,
	Command,
	CompletionItem,
	CompletionList,
	DocumentHighlight,
	DocumentHighlightResult,
	ExecuteCommandParams,
	FoldingRange,
	FoldingRangeKind,
	Hover,
	InitializeResult,
	InlayHint,
	InlayHintLabel,
	InlayHintLabelPart,
	InlayHintRefresh,
	LspDiagnostic,
	LspOutAction,
	LspOutMessage,
	LspOutNotification,
	LspOutRequest,
	LspOutResponse,
	LspOutResult,
	MarkupContent,
	ParameterInformation,
	PublishDiagnosticsParams,
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
import util.alloc.alloc : Alloc;
import util.col.array : map;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.map : KeyValuePair;
import util.exitCode : ExitCode, Signal;
import util.json : field, Json, jsonBool, jsonList, jsonNull, jsonObject, jsonString, optionalField;
import util.opt : force, has, Opt;
import util.sourceRange :
	jsonOfLineAndCharacter,
	jsonOfLineAndCharacterRange,
	jsonOfUriAndLine,
	jsonOfUriAndLineAndCharacterRange,
	LineAndCharacterGetter,
	Pos,
	UriAndRange;
import util.symbol : symbol;
import util.uri : stringOfUri, symbolOfUri, Uri;
import util.util : stringOfEnum;

Json jsonOfLspOutAction(ref Alloc alloc, in LineAndCharacterGetters lcg, in LspOutAction a) =>
	jsonObject(alloc, [
		field!"messages"(jsonList(map(alloc, a.outMessages, (ref LspOutMessage x) =>
			jsonOfLspOutMessage(alloc, lcg, x)))),
		optionalField!("exit-code", ExitCode)(a.exitCode, (ExitCode x) =>
			Json(x.value))]);

Json jsonOfLspOutMessage(ref Alloc alloc, in LineAndCharacterGetters lcg, ref LspOutMessage a) =>
	a.match!Json(
		(LspOutNotification x) =>
			jsonOfLspOutNotification(alloc, lcg, x),
		(LspOutRequest x) =>
			jsonOfLspOutRequest(alloc, x),
		(LspOutResponse x) =>
			jsonObject(alloc, [
				field!"id"(x.id),
				field!"result"(jsonOfLspOutResult(alloc, lcg, x.result))]));

private:

Json jsonOfLspOutRequest(ref Alloc alloc, in LspOutRequest a) =>
	a.params.matchIn!Json(
		(in InlayHintRefresh x) =>
			jsonObject(alloc, [
				field!"id"(a.id),
				field!"method"("workspace/inlayHint/refresh")]));

Json jsonOfLspOutNotification(ref Alloc alloc, in LineAndCharacterGetters lcg, ref LspOutNotification a) {
	Json res(string method, Json params) =>
		jsonObject(alloc, [field!"method"(method), field!"params"(params)]);
	return a.match!Json(
		(PublishDiagnosticsParams x) =>
			res("textDocument/publishDiagnostics", jsonOfPublishDiagnosticsParams(alloc, lcg[x.uri], x)),
		(RegisterCapability x) =>
			res("client/registerCapability", jsonObject(alloc, [
				field!"id"(x.id),
				field!"method"(x.method)])),
		(UnknownUris x) =>
			res("custom/unknownUris", jsonObject(alloc, [
				field!"unknownUris"(jsonList!Uri(alloc, x.unknownUris, (in Uri x) =>
					Json(stringOfUri(alloc, x))))])));
}

Json jsonOfLspOutResult(ref Alloc alloc, in LineAndCharacterGetters lcgs, ref LspOutResult a) => // TODO: remove lcgs parameter????????
	a.match!Json(
		(BuildJsScriptResult x) =>
			jsonObject(alloc, [field!"diagnostics"(x.diagnostics), optionalField!"script"(x.script)]),
		(CodeLens[] xs) =>
			jsonOfCodeLenses(alloc, xs),
		(CompletionList x) =>
			jsonOfCompletionList(alloc, x),
		(DocumentHighlightResult x) =>
			jsonOfDocumentHighlight(alloc, lcgs[x.uri], x),
		(FoldingRange[] x) =>
			jsonOfFoldingRanges(alloc, x),
		(InitializeResult _) =>
			jsonObject(alloc, [field!"capabilities"(initializeCapabilities(alloc))]),
		(InlayHint x) =>
			jsonOfInlayHint(alloc, x),
		(InlayHint[] x) =>
			jsonOfInlayHints(alloc, x),
		(Opt!Hover x) =>
			jsonOfHover(alloc, x),
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
		(UriAndRange[] x) =>
			jsonOfReferences(alloc, lcgs, x),
		(WorkspaceEdit x) =>
			jsonOfWorkspaceEdit(alloc, lcgs, x),
		(LspOutResult.Null) =>
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

Json jsonOfPublishDiagnosticsParams(ref Alloc alloc, in LineAndCharacterGetter lcg, in PublishDiagnosticsParams a) =>
	jsonObject(alloc, [
		field!"uri"(stringOfUri(alloc, a.uri)),
		field!"diagnostics"(jsonList(map(alloc, a.diagnostics, (ref LspDiagnostic x) =>
			jsonOfDiagnostic(alloc, lcg, x))))]);

public Json jsonOfHover(ref Alloc alloc, in Opt!Hover a) =>
	has(a) ? jsonOfHover(alloc, force(a)) : jsonNull;

Json jsonOfHover(ref Alloc alloc, in Hover a) =>
	jsonObject(alloc, [field!"contents"(jsonOfMarkupContent(alloc, a.contents))]);

public Json jsonOfCodeLenses(ref Alloc alloc, in CodeLens[] a) =>
	jsonList(map(alloc, a, (ref CodeLens x) =>
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

public Json jsonOfDocumentHighlight(ref Alloc alloc, in LineAndCharacterGetter lcg, in DocumentHighlightResult a) =>
	jsonList!DocumentHighlight(alloc, a.highlights, (in DocumentHighlight x) =>
		jsonObject(alloc, [
			field!"range"(jsonOfLineAndCharacterRange(alloc, lcg[x.range])),
			field!"kind"(uint(x.kind))]));

public Json jsonOfInlayHints(ref Alloc alloc, in InlayHint[] a) =>
	jsonList(map(alloc, a, (ref InlayHint x) =>
		jsonOfInlayHint(alloc, x)));
Json jsonOfInlayHint(ref Alloc alloc, ref InlayHint a) =>
	// I'm making extra sure the optional fields are not present ----------------------------------------------------------------------------
	jsonObject(buildArray!(Json.ObjectField)(alloc, (scope ref Builder!(Json.ObjectField) out_) {
		out_ ~= Json.ObjectField(symbol!"position", jsonOfLineAndCharacter(alloc, a.position));
		out_ ~= Json.ObjectField(symbol!"label", jsonOfInlayHintLabel(alloc, a.label));
		if (a.paddingLeft)
			out_ ~= Json.ObjectField(symbol!"paddingLeft", jsonBool(true));
	}));

Json jsonOfInlayHintLabel(ref Alloc alloc, ref InlayHintLabel a) =>
	a.match!Json(
		(string x) =>
			jsonString(x),
		(InlayHintLabelPart[] xs) =>
			jsonList(map(alloc, xs, (ref InlayHintLabelPart x) =>
				jsonOfInlayHintLabelPart(alloc, x))));
Json jsonOfInlayHintLabelPart(ref Alloc alloc, ref InlayHintLabelPart a) =>
	// I'm making extra sure the optional fields are not present ----------------------------------------------------------------------------
	jsonObject(buildArray!(Json.ObjectField)(alloc, (scope ref Builder!(Json.ObjectField) out_) {
		out_ ~= Json.ObjectField(symbol!"value", jsonString(a.value));
		if (has(a.tooltip)) out_ ~= Json.ObjectField(symbol!"tooltip", jsonString(force(a.tooltip)));
		if (has(a.location)) out_ ~= Json.ObjectField(symbol!"location", jsonOfUriAndLineAndCharacterRange(alloc, force(a.location)));
		if (has(a.command)) out_ ~= Json.ObjectField(symbol!"command", jsonOfCommand(alloc, force(a.command)));
	}));

public Json jsonOfReferences(ref Alloc alloc, in LineAndCharacterGetters lcg, in UriAndRange[] references) =>
	jsonList!UriAndRange(alloc, references, (in UriAndRange x) =>
		jsonOfUriAndLineAndCharacterRange(alloc, lcg[x]));

Json jsonOfDiagnostic(ref Alloc alloc, in LineAndCharacterGetter lcg, LspDiagnostic a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndCharacterRange(alloc, lcg[a.range])),
		field!"severity"(cast(uint) a.severity),
		field!"message"(a.message)]);

public Json jsonOfWorkspaceEdit(ref Alloc alloc, in LineAndCharacterGetters lcg, in WorkspaceEdit a) =>
	jsonObject(alloc, [field!"changes"(jsonOfWorkspaceEditChanges(alloc, lcg, a.changes))]);

Json jsonOfWorkspaceEditChanges(ref Alloc alloc, in LineAndCharacterGetters lcg, in KeyValuePair!(Uri, TextEdit[])[] a) =>
	Json(map(alloc, a, (ref const KeyValuePair!(Uri, TextEdit[]) x) =>
		Json.ObjectField(symbolOfUri(x.key), jsonOfTextEdits(alloc, lcg[x.key], x.value))));

Json jsonOfTextEdits(ref Alloc alloc, in LineAndCharacterGetter lcg, in TextEdit[] a) =>
	jsonList(map!(Json, TextEdit)(alloc, a, (ref TextEdit x) =>
		jsonOfTextEdit(alloc, lcg, x)));

Json jsonOfTextEdit(ref Alloc alloc, in LineAndCharacterGetter lcg, ref TextEdit a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndCharacterRange(alloc, lcg[a.range])),
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

public Json jsonOfFoldingRanges(ref Alloc alloc, in FoldingRange[] a) =>
	jsonList!FoldingRange(alloc, a, (in FoldingRange x) =>
		jsonOfFoldingRange(alloc, x));
Json jsonOfFoldingRange(ref Alloc alloc, in FoldingRange a) =>
	jsonObject(alloc, [
		field!"startLine"(a.startLine),
		field!"endLine"(a.endLine),
		optionalField!("kind", FoldingRangeKind)(a.kind, (FoldingRangeKind x) => jsonString(stringOfEnum(x)))]);
