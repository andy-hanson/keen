module test.testInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.getInlayHints : getInlayHints;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfInlayHints;
import lib.lsp.lspTypes : InlayHintParams, RunResult, TextDocumentIdentifier;
import model.model : Program;
import test.testUtil : ideTestWithCrowAndJsonFiles, Test;
import util.col.mutMap : MutMap;
import util.sourceRange : UriAndLine;
import util.uri : Uri;

void testInlayHints(ref Test test) {
	ideTestWithCrowAndJsonFiles!("inlay-hints", ["a", "b", "c"])(
		test,
		(in ShowModelCtx ctx, in Program program, Uri uri) =>
			jsonOfInlayHints(
				test.alloc,
				getInlayHints(
					test.alloc, program, ctx, MutMap!(UriAndLine, RunResult)(),
					InlayHintParams(TextDocumentIdentifier(uri)))));
}
