module test.testFoldingRanges;

@safe @nogc pure nothrow:

import frontend.ide.getFoldingRanges : foldingRangesOfAst;
import frontend.storage : CrowFileInfo;
import lib.lsp.lspToJson : jsonOfFoldingRanges;
import test.testUtil : assertEqual, CrowJsonTest, Test, testWithCrowAndJsonFiles, withAstTest;

void testFoldingRanges(ref Test test) {
	testWithCrowAndJsonFiles!("folding-ranges", ["basic"])(test, (in CrowJsonTest testData) {
		withAstTest(test, testData.uri, testData.crow, (in CrowFileInfo file) {
			assertEqual(jsonOfFoldingRanges(test.alloc, foldingRangesOfAst(test.alloc, file)), testData.json);
		});
	});
}
