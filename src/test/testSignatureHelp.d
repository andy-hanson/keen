module test.testSignatureHelp;

@safe @nogc pure nothrow:

import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getSignatureHelp : getSignatureHelpForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfSignatureHelp;
import lib.lsp.lspTypes : SignatureHelp;
import model.model : Module, Program;
import test.testUtil : CrowJsonTest, ideTestAtPositions, Test, testWithCrowAndJsonFiles;
import util.json : jsonNull;
import util.opt : has, force, none, Opt;
import util.sourceRange : Pos;

void testSignatureHelp(ref Test test) {
	testWithCrowAndJsonFiles!("signature-help", ["after-comma", "overloads"])(
		test,
		(in CrowJsonTest x) {
			singleTest(test, x);
		});
}

private:

void singleTest(ref Test test, in CrowJsonTest testData) {
	ideTestAtPositions(test, testData, (in ShowModelCtx ctx, in Program program, in Module* module_, Pos pos) {
		Opt!Position position = getPosition(program, module_, testData.crow, pos, GetPositionKind.after);
		Opt!SignatureHelp res = has(position) ? getSignatureHelpForPosition(test.alloc, ctx, force(position)) : none!SignatureHelp;
		return has(res) ? jsonOfSignatureHelp(test.alloc, force(res)) : jsonNull;
	});
}
