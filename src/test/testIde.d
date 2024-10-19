module test.testIde;

@safe @nogc pure nothrow:

import app.parseCommand : parseLineAndColumn;
import frontend.ide.getCodeLenses : getCodeLenses;
import frontend.ide.getCompletion : getCompletionForPosition;
import frontend.ide.getDefinition : getDefinitionForPosition, getTypeDefinitionForPosition;
import frontend.ide.getFoldingRanges : foldingRangesOfAst;
import frontend.ide.getHover : getHover;
import frontend.ide.getImplementation : getImplementationForPosition;
import frontend.ide.getInlayHints : getInlayHints;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getReferences : getReferencesForPosition;
import frontend.ide.getRename : getRenameForPosition;
import frontend.ide.getSignatureHelp : getSignatureHelpForPosition;
import frontend.ide.getTokens : jsonOfDecodedTokens, tokensOfAst;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import frontend.storage : CrowFileInfo, setFileAssumeUtf8, Storage;
import lib.lsp.lspToJson :
	jsonOfCodeLenses,
	jsonOfCompletionList,
	jsonOfFoldingRanges,
	jsonOfInlayHints,
	jsonOfReferences,
	jsonOfSignatureHelp,
	jsonOfWorkspaceEdit;
import lib.lsp.lspTypes :
	CodeLensParams,
	CompletionList,
	Hover,
	InlayHintParams,
	RunResult,
	SignatureHelp,
	WorkspaceEdit;
import lib.server : getProgram, getShowDiagCtx, Server;
import model.model : Program;
import frontend.showModel : ShowModelCtx;
import test.testUtil : assertEqual, setupTestServer, Test, UriAndContent, withTestServer;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withMapToStackArray;
import util.col.array : arraysEqual, isEmpty, mapCompileTime;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.mutMap : MutMap;
import util.json : field, Json, jsonList, jsonNull, jsonObject, optionalArrayField;
import util.jsonParse : mustParseJson;
import util.opt : force, has, none, Opt, optIf;
import util.sourceRange :
	endOfFile,
	jsonOfLineAndCharacterRange,
	jsonOfUriAndLineAndCharacterRange,
	LineAndColumn,
	LineAndCharacterGetter,
	Pos,
	PosKind,
	Range,
	toLineAndCharacter,
	UriAndLine,
	UriAndRange,
	UriLineAndCharacter;
import util.string : CString;
import util.symbol : cStringOfSymbol, Extension, symbolOfString;
import util.uri : addExtension, mustParseUri, Uri;
import util.writer : Writer;

void testCodeLens(ref Test test) {
	ideTestWithCrowAndJsonFiles!("code-lens", ["a", "b"])(
		test,
		(in ShowModelCtx ctx, in Program program, Uri uri) =>
			jsonOfCodeLenses(test.alloc, getCodeLenses(test.alloc, program, CodeLensParams(uri))));
}

void testCompletion(ref Test test) {
	withIdeTestsAtPositions!("completion", ["after-dot"])(
		test,
		(in ShowModelCtx ctx, in Program program, in UriLineAndCharacter where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.after);
			Opt!CompletionList res = getCompletionForPosition(test.alloc, ctx, force(position));
			return jsonOfCompletionList(test.alloc, force(res));
		});
}

void testFoldingRanges(ref Test test) {
	withAstTests!("folding-ranges", ["basic"])(test, (in CrowFileInfo file) =>
		jsonOfFoldingRanges(test.alloc, foldingRangesOfAst(test.alloc, file)));
}

void testHover(ref Test test) {
	ideTestWithCrowAndJsonFiles!("hover", ["basic", "function"])(
		test,
		(in ShowModelCtx ctx, in Program program, Uri uri) =>
			hoverResult(test.alloc, ctx, program, uri));
}
private struct InfoAtPos {
	@safe @nogc pure nothrow:

	string hover;
	UriAndRange[] definition;
	UriAndRange[] typeDefinition;

	bool isEmpty() scope =>
		.isEmpty(hover) && .isEmpty(definition) && .isEmpty(typeDefinition);

	bool opEquals(in InfoAtPos b) scope =>
		hover == b.hover && arraysEqual(definition, b.definition) && arraysEqual(typeDefinition, b.typeDefinition);
}
private Json hoverResult(ref Alloc alloc, in ShowModelCtx ctx, in Program program, Uri uri) =>
	jsonList(buildArray!Json(alloc, (scope ref Builder!Json res) {
		// Combine ranges that have the same info
		Pos curRangeStart = 0;
		InfoAtPos curInfo = InfoAtPos("", [], []);
		LineAndCharacterGetter lcg = ctx.lineAndCharacterGetters[uri];

		void endRange(Pos end) {
			if (!curInfo.isEmpty)
				res ~= jsonObject(alloc, [
					field!"range"(jsonOfLineAndCharacterRange(alloc, lcg[Range(curRangeStart, end)])),
					field!"hover"(curInfo.hover),
					optionalArrayField!("definition", UriAndRange)(alloc, curInfo.definition, (in UriAndRange x) =>
						jsonOfUriAndLineAndCharacterRange(alloc, ctx.lineAndCharacterGetters[x])),
					optionalArrayField!("type-definition", UriAndRange)(
						alloc, curInfo.typeDefinition, (in UriAndRange x) =>
							jsonOfUriAndLineAndCharacterRange(alloc, ctx.lineAndCharacterGetters[x])),
				]);
		}

		foreach (Pos pos; 0 .. endOfFile(lcg) + 1) {
			Opt!Position position = getPosition(
				program, ctx, UriLineAndCharacter(uri, lcg[pos, PosKind.startOfRange]), GetPositionKind.exact);
			Opt!Hover hover = optIf(has(position), () => getHover(alloc, ctx, force(position)));
			InfoAtPos here = InfoAtPos(
				has(hover) ? force(hover).contents.value : "",
				has(position) ? getDefinitionForPosition(alloc, program.commonTypes, force(position)) : [],
				has(position) ? getTypeDefinitionForPosition(alloc, program.commonTypes, force(position)) : []);
			if (here != curInfo) {
				endRange(pos);
				curRangeStart = pos;
				curInfo = here;
			}
		}
		endRange(endOfFile(lcg));
	}));

void testImplementation(ref Test test) {
	withIdeTestsAtPositions!("implementation", ["a"])(
		test,
		(in ShowModelCtx ctx, in Program program, in UriLineAndCharacter where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.exact);
			UriAndRange[] res = getImplementationForPosition(test.alloc, program, force(position));
			return jsonOfReferences(test.alloc, ctx.lineAndCharacterGetters, res);
		});
}

void testInlayHints(ref Test test) {
	ideTestWithCrowAndJsonFiles!("inlay-hints", ["a", "b", "c"])(
		test,
		(in ShowModelCtx ctx, in Program program, Uri uri) =>
			jsonOfInlayHints(
				test.alloc,
				getInlayHints(
					test.alloc, program, ctx, MutMap!(UriAndLine, RunResult)(),
					InlayHintParams(uri))));
}

void testReferences(ref Test test) {
	withIdeTestsAtPositions!("references", ["variant"])(
		test,
		(in ShowModelCtx ctx, in Program program, in UriLineAndCharacter where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.exact);
			return has(position)
				? jsonOfReferences(
					test.alloc,
					ctx.lineAndCharacterGetters,
					getReferencesForPosition(test.alloc, program, force(position)))
				: jsonNull;
		});
}

void testRename(ref Test test) {
	withIdeTestsAtPositions!("rename", ["a", "b"])(
		test,
		(in ShowModelCtx ctx, in Program program, in UriLineAndCharacter where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.exact);
			Opt!WorkspaceEdit rename = has(position)
				? getRenameForPosition(test.alloc, program, force(position), "new-name")
				: none!WorkspaceEdit;
			return has(rename) ? jsonOfWorkspaceEdit(test.alloc, ctx.lineAndCharacterGetters, force(rename)) : jsonNull;
		});
}

void testSignatureHelp(ref Test test) {
	withIdeTestsAtPositions!("signature-help", ["after-comma", "overloads"])(
		test,
		(in ShowModelCtx ctx, in Program program, in UriLineAndCharacter where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.after);
			Opt!SignatureHelp res = has(position)
				? getSignatureHelpForPosition(test.alloc, ctx, force(position))
				: none!SignatureHelp;
			return has(res) ? jsonOfSignatureHelp(test.alloc, force(res)) : jsonNull;
		});
}

void testTokens(ref Test test) {
	withAstTests!("tokens", ["basic"])(test, (in CrowFileInfo file) =>
		jsonOfDecodedTokens(test.alloc, tokensOfAst(test.alloc, file)));
}

private:

void withAstTests(string dir, string[] fileNames)(
	ref Test test,
	in Json delegate(in CrowFileInfo) @safe @nogc pure nothrow cb,
) {
	withCrowAndJsonFiles!(dir, fileNames)(test, (in CrowJsonTest[] tests) {
		foreach (CrowJsonTest testData; tests)
			withAstTest(test, testData.uri, testData.crow, (in CrowFileInfo file) {
				assertEqual(cb(file), testData.json);
			});
	});
}

private void withAstTest(
	ref Test test,
	Uri uri,
	in string content,
	in void delegate(in CrowFileInfo) @safe @nogc pure nothrow cb,
) {
	Storage storage = Storage(test.metaAlloc);
	return cb(*setFileAssumeUtf8(test.perf, storage, uri, content).as!(CrowFileInfo*));
}

void withIdeTestsAtPositions(string dir, string[] fileNames)(
	ref Test test,
	in Json delegate(in ShowModelCtx, in Program, in UriLineAndCharacter) @safe @nogc pure nothrow cb,
) {
	withIdeTestsForCrowAndJsonFiles!(dir, fileNames)(
		test,
		(in ShowModelCtx ctx, in Program program, in CrowJsonTest[] tests) {
			foreach (CrowJsonTest x; tests)
				testAtPositions(test, x.uri, x.json, (LineAndColumn where) =>
					cb(
						ctx, program,
						UriLineAndCharacter(x.uri, toLineAndCharacter(ctx.lineAndColumnGetters[x.uri], where))));
		});
}

void ideTestWithCrowAndJsonFiles(string dir, string[] fileNames)(
	ref Test test,
	in Json delegate(in ShowModelCtx, in Program, Uri) @safe @nogc pure nothrow cb,
) {
	withIdeTestsForCrowAndJsonFiles!(dir, fileNames)(
		test,
		(in ShowModelCtx ctx, in Program program, in CrowJsonTest[] tests) {
			foreach (CrowJsonTest x; tests)
				assertEqual(cb(ctx, program, x.uri), x.json, (scope ref Writer writer) {
					writer ~= "For ";
					writer ~= x.uri;
					writer ~= ":\n";
				});
		});
}

private void withIdeTestsForCrowAndJsonFiles(string dir, string[] fileNames)(
	ref Test test,
	in void delegate(in ShowModelCtx, in Program, in CrowJsonTest[]) @safe @nogc pure nothrow cb,
) {
	withCrowAndJsonFiles!(dir, fileNames)(test, (in CrowJsonTest[] tests) {
		withTestServer(test, (ref Server server) {
			withMapToStackArray!(void, UriAndContent, CrowJsonTest)(
				tests,
				(ref CrowJsonTest x) =>
					UriAndContent(x.uri, x.crow),
				(scope UriAndContent[] files) {
					setupTestServer(test, server, files);
				});
			Program program = getProgram(test.perf, test.alloc, server);
			cb(getShowDiagCtx(server, program), program, tests);
		});
	});
}

private void testAtPositions(
	ref Test test,
	Uri uri,
	in Json json,
	in Json delegate(LineAndColumn) @safe @nogc pure nothrow cb,
) {
	foreach (Json.ObjectField field; json.as!(Json.Object)) {
		LineAndColumn where = force(parseLineAndColumn(cStringOfSymbol(test.alloc, field.key)));
		Json res = cb(where);
		assertEqual(res, field.value, (scope ref Writer writer) {
			writer ~= "For ";
			writer ~= uri;
			writer ~= " ";
			writer ~= where;
			writer ~= ":\n";
		});
	}
}

private void withCrowAndJsonFiles(string dirName, string[] names)(
	ref Test test,
	in void delegate(in CrowJsonTest[]) @safe @nogc pure nothrow cb,
) {
	CrowJsonTestStatic[names.length] tests =
		mapCompileTime!(names.length, CrowJsonTestStatic, names, importCrowTest!dirName);
	withMapToStackArray!(void, CrowJsonTest, CrowJsonTestStatic)(
		tests,
		(ref CrowJsonTestStatic x) =>
			CrowJsonTest(
				mustParseUri("test:") / symbolOfString(dirName) / addExtension(symbolOfString(x.name), Extension.crow),
				x.crow,
				mustParseJson(test.alloc, (() @trusted => CString(x.json))())),
		(scope CrowJsonTest[] x) => cb(x));
}

private immutable struct CrowJsonTest {
	Uri uri;
	string crow;
	Json json;
}

private immutable struct CrowJsonTestStatic {
	string name;
	string crow;
	immutable char* json;
}

private template importCrowTest(string dirName) {
	CrowJsonTestStatic importCrowTest(string name)() =>
		CrowJsonTestStatic(name, import(dirName ~ "/" ~ name ~ ".crow"), import(dirName ~ "/" ~ name ~ ".json"));
}
