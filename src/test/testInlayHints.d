module test.testInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.getInlayHints : getInlayHints;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfInlayHints;
import model.model : Module, Program;
import test.testUtil : assertEqual, CrowJsonTest, Test, testWithCrowAndJsonFiles, withIdeTest;
import util.alloc.alloc : Alloc;
import util.json : Json;
import util.writer : Writer;

void testInlayHints(ref Test test) {
	testWithCrowAndJsonFiles!("inlay-hints", ["basic"])(test, (in CrowJsonTest testData) {
		withIdeTest(test, testData.uri, testData.crow, (in ShowModelCtx ctx, in Program program, in Module* module_) {
			assertEqual(inlayResult(test.alloc, ctx, *module_), testData.json, (scope ref Writer writer) {
				writer ~= "For ";
				writer ~= testData.uri;
				writer ~= ":\n";
			});
		});
	});
}

private:

Json inlayResult(ref Alloc alloc, in ShowModelCtx ctx, in Module module_) =>
	jsonOfInlayHints(alloc, ctx.lineAndCharacterGetters[module_.uri], getInlayHints(alloc, ctx, module_));
