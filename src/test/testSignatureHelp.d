module test.testSignatureHelp;

@safe @nogc nothrow: // not pure

import app.parseCommand : parseLineAndColumn;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getSignatureHelp : getSignatureHelpForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfSignatureHelp;
import lib.lsp.lspTypes : SignatureHelp;
import model.model : Module, Program;
import test.test : Test;
import test.testUtil : assertEqual, testWithCrowAndJsonFiles, withIdeTest;
import util.json : Json;
import util.opt : force, Opt;
import util.sourceRange : LineAndColumn, Pos;
import util.symbol : cStringOfSymbol;
import util.uri : Uri;

void testSignatureHelp(ref Test test) {
	testWithCrowAndJsonFiles!("signature-help", ["after-comma", "overloads"])(test, (Uri uri, in string crow, in Json json) {
		singleTest(test, uri, crow, json);
	});
}

private:
pure:

void singleTest(ref Test test, Uri uri, in string crow, in Json json) {
	withIdeTest(test, uri, crow, (in ShowModelCtx ctx, in Program program, in Module* module_) {
		foreach (Json.ObjectField field; json.as!(Json.Object)) {
			LineAndColumn where = force(parseLineAndColumn(cStringOfSymbol(test.alloc, field.key)));
			Pos pos = ctx.lineAndColumnGetters[module_.uri][where];
			Opt!Position position = getPosition(program, module_, crow, pos, GetPositionKind.after);
			Opt!SignatureHelp res = getSignatureHelpForPosition(test.alloc, ctx, force(position));
			assertEqual(jsonOfSignatureHelp(test.alloc, force(res)), field.value);
		}
	});
}
