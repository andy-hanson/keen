module test.testSignatureHelp;

@safe @nogc pure nothrow:

import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getSignatureHelp : getSignatureHelpForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfSignatureHelp;
import lib.lsp.lspTypes : SignatureHelp;
import model.model : Module, Program;
import test.testUtil : ideTestAtPositions, Test, testWithCrowAndJsonFiles;
import util.json : Json;
import util.opt : force, Opt;
import util.sourceRange : Pos;
import util.uri : Uri;

void testSignatureHelp(ref Test test) {
	testWithCrowAndJsonFiles!(
		"signature-help",
		["after-comma", "overloads"],
	)(
		test,
		(Uri uri, in string crow, in Json json) {
			singleTest(test, uri, crow, json);
		});
}

private:

void singleTest(ref Test test, Uri uri, in string crow, in Json json) {
	ideTestAtPositions(test, uri, crow, json, (in ShowModelCtx ctx, in Program program, in Module* module_, Pos pos) {
		Opt!Position position = getPosition(program, module_, crow, pos, GetPositionKind.after);
		Opt!SignatureHelp res = getSignatureHelpForPosition(test.alloc, ctx, force(position));
		return jsonOfSignatureHelp(test.alloc, force(res));
	});
}
