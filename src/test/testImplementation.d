module test.testImplementation;

@safe @nogc pure nothrow:

import frontend.ide.getImplementation : getImplementationForPosition;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfReferences;
import model.model : Module, Program;
import test.testUtil : Test, ideTestAtPositions, testWithCrowAndJsonFiles;
import util.json : Json;
import util.opt : force, Opt;
import util.sourceRange : Pos, UriAndRange;
import util.uri : Uri;

void testImplementation(ref Test test) {
	testWithCrowAndJsonFiles!(
		"implementation",
		["a"],
	)(
		test,
		(Uri uri, in string crow, in Json json) {
			singleTest(test, uri, crow, json);
		});
}

private:

void singleTest(ref Test test, Uri uri, in string crow, in Json json) {
	ideTestAtPositions(test, uri, crow, json, (in ShowModelCtx ctx, in Program program, in Module* module_, Pos pos) {
		Opt!Position position = getPosition(program, module_, crow, pos, GetPositionKind.exact);
		UriAndRange[] res = getImplementationForPosition(test.alloc, program, force(position));
		return jsonOfReferences(test.alloc, ctx.lineAndCharacterGetters, res);
	});
}
