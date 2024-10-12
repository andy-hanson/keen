module test.testReferences;

@safe @nogc pure nothrow:

import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getReferences : getReferencesForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfReferences;
import model.model : moduleAtUri, Program;
import test.testUtil :
	CrowJsonTest, Test, testAtPositions, UriAndContent, withCrowAndJsonFiles, withIdeTestMultipleFiles;
import util.col.array : map;
import util.json : jsonNull;
import util.opt : force, has, Opt;
import util.sourceRange : Pos, LineAndColumn;

void testReferences(ref Test test) {
	withCrowAndJsonFiles!("references", ["variant"])(test, (in CrowJsonTest[] tests) {
		UriAndContent[] files = map(test.alloc, tests, (ref CrowJsonTest x) =>
			UriAndContent(x.uri, x.crow));
		withIdeTestMultipleFiles(test, files, (in ShowModelCtx ctx, in Program program) {
			foreach (CrowJsonTest x; tests)
				singleTest(test, ctx, program, x);
		});
	});
}

private:

void singleTest(ref Test test, in ShowModelCtx ctx, in Program program, in CrowJsonTest testData) {
	testAtPositions(test, testData.uri, testData.json, (LineAndColumn where) {
		Pos pos = ctx.lineAndColumnGetters[testData.uri][where];
		Opt!Position position = getPosition(
			program, moduleAtUri(program, testData.uri), testData.crow, pos, GetPositionKind.exact);
		return has(position)
			? jsonOfReferences(
				test.alloc,
				ctx.lineAndCharacterGetters,
				getReferencesForPosition(test.alloc, program, force(position)))
			: jsonNull;
	});
}
