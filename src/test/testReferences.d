module test.testReferences;

@safe @nogc pure nothrow:

import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getReferences : getReferencesForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfReferences;
import lib.lsp.lspTypes : TextDocumentPositionParams;
import model.model : Program;
import test.testUtil : Test, withIdeTestsAtPositions;
import util.json : jsonNull;
import util.opt : force, has, Opt;

void testReferences(ref Test test) {
	withIdeTestsAtPositions!("references", ["variant"])(
		test,
		(in ShowModelCtx ctx, in Program program, in TextDocumentPositionParams where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.exact);
			return has(position)
				? jsonOfReferences(
					test.alloc,
					ctx.lineAndCharacterGetters,
					getReferencesForPosition(test.alloc, program, force(position)))
				: jsonNull;
		});
}
