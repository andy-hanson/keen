module test.testInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.getInlayHints : getInlayHints;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspTypes : InlayHint;
import lib.lsp.lspToJson : jsonOfInlayHints;
import model.model : Module, Program;
import test.testUtil : assertEqual, Test, testWithCrowAndJsonFiles, withIdeTest;
import util.alloc.alloc : Alloc;
import util.json : field, Json, jsonList, jsonObject, optionalArrayField;
import util.uri : Uri;
import util.writer : Writer;

void testInlayHints(ref Test test) {
	testWithCrowAndJsonFiles!("inlay-hints", ["basic"])(test, (Uri uri, in string crow, in Json json) {
		withIdeTest(test, uri, crow, (in ShowModelCtx ctx, in Program program, in Module* module_) {
			assertEqual(inlayResult(test.alloc, ctx, *module_), json, (scope ref Writer writer) {
				writer ~= "For ";
				writer ~= uri;
				writer ~= ":\n";
			});
		});
	});
}

private:

Json inlayResult(ref Alloc alloc, in ShowModelCtx ctx, in Module module_) =>
	jsonOfInlayHints(alloc, ctx.lineAndCharacterGetters[module_.uri], getInlayHints(alloc, ctx, module_));
