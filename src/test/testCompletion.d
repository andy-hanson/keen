module test.testCompletions;

@safe @nogc pure nothrow:

import frontend.ide.getCompletion : getCompletionForPosition;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfCompletionList;
import lib.lsp.lspTypes : CompletionList;
import model.model : Module, Program;
import test.testUtil : CrowJsonTest, Test, ideTestAtPositions, testWithCrowAndJsonFiles;
import util.opt : force, Opt;
import util.sourceRange : Pos;

void testCompletion(ref Test test) {
	testWithCrowAndJsonFiles!("completion", ["after-dot"])(test, (in CrowJsonTest x) {
		singleTest(test, x);
	});
}

private:

void singleTest(ref Test test, in CrowJsonTest testData) {
	ideTestAtPositions(test, testData, (in ShowModelCtx ctx, in Program program, in Module* module_, Pos pos) {
		Opt!Position position = getPosition(program, module_, testData.crow, pos, GetPositionKind.after);
		Opt!CompletionList res = getCompletionForPosition(test.alloc, ctx, force(position));
		return jsonOfCompletionList(test.alloc, force(res));
	});
}
