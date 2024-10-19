module test.testCompletions;

@safe @nogc pure nothrow:

import frontend.ide.getCompletion : getCompletionForPosition;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfCompletionList;
import lib.lsp.lspTypes : CompletionList, TextDocumentPositionParams;
import model.model : Program;
import test.testUtil : Test, withIdeTestsAtPositions;
import util.opt : force, Opt;

void testCompletion(ref Test test) {
	withIdeTestsAtPositions!("completion", ["after-dot"])(
		test,
		(in ShowModelCtx ctx, in Program program, in TextDocumentPositionParams where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.after);
			Opt!CompletionList res = getCompletionForPosition(test.alloc, ctx, force(position));
			return jsonOfCompletionList(test.alloc, force(res));
		});
}
