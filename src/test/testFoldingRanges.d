module test.testFoldingRanges;

@safe @nogc pure nothrow:

import frontend.ide.getFoldingRanges : foldingRangesOfAst;
import frontend.storage : CrowFileInfo;
import lib.lsp.lspToJson : jsonOfFoldingRanges;
import test.testUtil : Test, withAstTests;

void testFoldingRanges(ref Test test) {
	withAstTests!("folding-ranges", ["basic"])(test, (in CrowFileInfo file) =>
		jsonOfFoldingRanges(test.alloc, foldingRangesOfAst(test.alloc, file)));
}
