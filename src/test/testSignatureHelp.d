module test.testSignatureHelp;

@safe @nogc pure nothrow:

import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getSignatureHelp : getSignatureHelpForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfSignatureHelp;
import lib.lsp.lspTypes : SignatureHelp, TextDocumentPositionParams;
import model.model : Program;
import test.testUtil : Test, withIdeTestsAtPositions;
import util.json : jsonNull;
import util.opt : has, force, none, Opt;

void testSignatureHelp(ref Test test) {
	withIdeTestsAtPositions!("signature-help", ["after-comma", "overloads"])(
		test,
		(in ShowModelCtx ctx, in Program program, in TextDocumentPositionParams where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.after);
			Opt!SignatureHelp res = has(position)
				? getSignatureHelpForPosition(test.alloc, ctx, force(position))
				: none!SignatureHelp;
			return has(res) ? jsonOfSignatureHelp(test.alloc, force(res)) : jsonNull;
		});
}
