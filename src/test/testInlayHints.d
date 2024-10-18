module test.testInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.getInlayHints : getInlayHints;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfInlayHints;
import lib.lsp.lspTypes : RunResult;
import model.model : Module, moduleAtUri, Program;
import test.testUtil : assertEqual, CrowJsonTest, Test, UriAndContent, withCrowAndJsonFiles, withIdeTestMultipleFiles;
import util.alloc.alloc : Alloc;
import util.col.array : map;
import util.col.mutMap : MutMap;
import util.json : Json;
import util.sourceRange : UriAndLine;
import util.writer : Writer;

void testInlayHints(ref Test test) {
	withCrowAndJsonFiles!("inlay-hints", ["a", "b", "c"])(test, (in CrowJsonTest[] tests) {
		UriAndContent[] files = map(test.alloc, tests, (ref CrowJsonTest x) => // TODO: dup code in testCodeLens.d ----------------------
			UriAndContent(x.uri, x.crow));
		withIdeTestMultipleFiles(test, files, (in ShowModelCtx ctx, in Program program) {
			foreach (CrowJsonTest x; tests)
				singleTest(test, ctx, program, x);
		});
	});
}

private:

void singleTest(ref Test test, in ShowModelCtx ctx, in Program program, in CrowJsonTest testData) {
	assertEqual(inlayResult(test.alloc, program, ctx, *moduleAtUri(program, testData.uri)), testData.json, (scope ref Writer writer) {
		writer ~= "For ";
		writer ~= testData.uri;
		writer ~= ":\n";
	});
}

Json inlayResult(ref Alloc alloc, in Program program, in ShowModelCtx ctx, in Module module_) =>
	jsonOfInlayHints(alloc, getInlayHints(alloc, program, ctx, MutMap!(UriAndLine, RunResult)(), module_)); // inline????????????????/
