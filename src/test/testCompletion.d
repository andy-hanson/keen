module test.testCompletions;

@safe @nogc pure nothrow:

import app.parseCommand : parseLineAndColumn;
import frontend.ide.getCompletion : getCompletionForPosition;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfCompletionList;
import lib.lsp.lspTypes : CompletionList;
import model.model : Module, Program;
import test.testUtil : assertEqual, Test, testWithCrowAndJsonFiles, withIdeTest;
import util.json : Json;
import util.opt : force, Opt;
import util.sourceRange : LineAndColumn, Pos;
import util.symbol : cStringOfSymbol;
import util.uri : Uri;

void testCompletion(ref Test test) {
	testWithCrowAndJsonFiles!(
		"completion",
		["after-dot"],
	)(
		test,
		(Uri uri, in string crow, in Json json) {
			singleTest(test, uri, crow, json);
		});
}

private:

void singleTest(ref Test test, Uri uri, in string crow, in Json json) {
	withIdeTest(test, uri, crow, (in ShowModelCtx ctx, in Program program, in Module* module_) {
		foreach (Json.ObjectField field; json.as!(Json.Object)) {
			LineAndColumn where = force(parseLineAndColumn(cStringOfSymbol(test.alloc, field.key)));
			Pos pos = ctx.lineAndColumnGetters[module_.uri][where];
			Opt!Position position = getPosition(program, module_, crow, pos, GetPositionKind.after);
			Opt!CompletionList res = getCompletionForPosition(test.alloc, ctx, force(position));
			assertEqual(jsonOfCompletionList(test.alloc, force(res)), field.value);
		}
	});
}
