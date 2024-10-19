module test.testImplementation;

@safe @nogc pure nothrow:

import frontend.ide.getImplementation : getImplementationForPosition;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfReferences;
import lib.lsp.lspTypes : TextDocumentPositionParams;
import model.model : Program;
import test.testUtil : Test, withIdeTestsAtPositions;
import util.opt : force, Opt;
import util.sourceRange : UriAndRange;

void testImplementation(ref Test test) {
	withIdeTestsAtPositions!("implementation", ["a"])(
		test,
		(in ShowModelCtx ctx, in Program program, in TextDocumentPositionParams where) {
			Opt!Position position = getPosition(program, ctx, where, GetPositionKind.exact);
			UriAndRange[] res = getImplementationForPosition(test.alloc, program, force(position));
			return jsonOfReferences(test.alloc, ctx.lineAndCharacterGetters, res);
		});
}
