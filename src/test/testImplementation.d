module test.testImplementation;

@safe @nogc pure nothrow:

import frontend.ide.getImplementation : getImplementationForPosition;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfReferences;
import model.model : Module, Program;
import test.testUtil : CrowJsonTest, Test, ideTestAtPositions, testWithCrowAndJsonFiles;
import util.opt : force, Opt;
import util.sourceRange : Pos, UriAndRange;

void testImplementation(ref Test test) {
	testWithCrowAndJsonFiles!("implementation", ["a"])(test, (in CrowJsonTest x) {
		singleTest(test, x);
	});
}

private:

void singleTest(ref Test test, in CrowJsonTest testData) {
	ideTestAtPositions(test, testData, (in ShowModelCtx ctx, in Program program, in Module* module_, Pos pos) {
		Opt!Position position = getPosition(program, module_, testData.crow, pos, GetPositionKind.exact);
		UriAndRange[] res = getImplementationForPosition(test.alloc, program, force(position));
		return jsonOfReferences(test.alloc, ctx.lineAndCharacterGetters, res);
	});
}
