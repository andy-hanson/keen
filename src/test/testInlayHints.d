module test.testInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.getInlayHints : getInlayHints;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfInlayHints;
import lib.lsp.lspTypes : RunResult;
import model.model : Module, Program;
import test.testUtil : assertEqual, CrowJsonTest, Test, testWithCrowAndJsonFiles, withIdeTest;
import util.alloc.alloc : Alloc;
import util.col.mutMap : MutMap;
import util.json : Json;
import util.sourceRange : UriAndLine;
import util.writer : Writer;

void testInlayHints(ref Test test) {
	testWithCrowAndJsonFiles!("inlay-hints", ["basic"])(test, (in CrowJsonTest testData) {
		withIdeTest(test, testData.uri, testData.crow, (in ShowModelCtx ctx, in Program program, in Module* module_) {
			assertEqual(inlayResult(test.alloc, program, ctx, *module_), testData.json, (scope ref Writer writer) {
				writer ~= "For ";
				writer ~= testData.uri;
				writer ~= ":\n";
			});
		});
	});
}

private:

Json inlayResult(ref Alloc alloc, in Program program, in ShowModelCtx ctx, in Module module_) =>
	jsonOfInlayHints(alloc, getInlayHints(alloc, program, ctx, MutMap!(UriAndLine, RunResult)(), module_)); // inline????????????????/
