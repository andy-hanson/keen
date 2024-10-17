module test.testCodeLens;

@safe @nogc pure nothrow:

import frontend.ide.getCodeLenses : getCodeLenses;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfCodeLenses;
import lib.lsp.lspTypes : CodeLens, CodeLensParams, RunResult, TextDocumentIdentifier;
import model.model : Program;
import test.testUtil : assertEqual, CrowJsonTest, Test, UriAndContent, withCrowAndJsonFiles, withIdeTestMultipleFiles;
import util.col.array : map;
import util.col.mutMap : MutMap;
import util.json : jsonList;
import util.sourceRange : UriAndLine;
import util.writer : Writer;

void testCodeLens(ref Test test) {
	withCrowAndJsonFiles!("code-lens", ["a", "b"])(test, (in CrowJsonTest[] tests) {
		UriAndContent[] files = map(test.alloc, tests, (ref CrowJsonTest x) =>
			UriAndContent(x.uri, x.crow));
		withIdeTestMultipleFiles(test, files, (in ShowModelCtx ctx, in Program program) {
			foreach (CrowJsonTest x; tests)
				singleTest(test, ctx, program, x);
		});
	});
}

private:

void singleTest(ref Test test, in ShowModelCtx ctx, in Program program, in CrowJsonTest testData) {
	assertEqual(
		jsonOfCodeLenses(test.alloc, getCodeLenses(test.alloc, program, ctx, CodeLensParams(TextDocumentIdentifier(testData.uri)))),
		testData.json,
		(scope ref Writer writer) {
			writer ~= "For ";
			writer ~= testData.uri;
			writer ~= ":\n";
		});
}
