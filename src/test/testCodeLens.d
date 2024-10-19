module test.testCodeLens;

@safe @nogc pure nothrow:

import frontend.ide.getCodeLenses : getCodeLenses;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfCodeLenses;
import lib.lsp.lspTypes : CodeLensParams, TextDocumentIdentifier;
import model.model : Program;
import test.testUtil : ideTestWithCrowAndJsonFiles, Test;
import util.uri : Uri;

void testCodeLens(ref Test test) {
	ideTestWithCrowAndJsonFiles!("code-lens", ["a", "b"])(
		test,
		(in ShowModelCtx ctx, in Program program, Uri uri) =>
			jsonOfCodeLenses(
				test.alloc,
				getCodeLenses(test.alloc, program, ctx, CodeLensParams(TextDocumentIdentifier(uri)))));
}
