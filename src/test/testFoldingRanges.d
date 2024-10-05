module test.testFoldingRanges;

@safe @nogc pure nothrow:

import frontend.ide.getFoldingRanges : foldingRangesOfAst;
import frontend.storage : CrowFileInfo;
import lib.lsp.lspToJson : jsonOfFoldingRanges;
import test.testUtil : assertEqual, Test, testWithCrowAndJsonFiles, withAstTest;
import util.json : Json;
import util.uri : Uri;

void testFoldingRanges(ref Test test) {
	testWithCrowAndJsonFiles!("folding-ranges", ["basic"])(test, (Uri uri, in string crow, in Json json) {
		withAstTest(test, uri, crow, (in CrowFileInfo file) {
			assertEqual(jsonOfFoldingRanges(test.alloc, foldingRangesOfAst(test.alloc, file)), json);
		});
	});
}
