module test.testTokens;

@safe @nogc pure nothrow:

import frontend.ide.getTokens : jsonOfDecodedTokens, tokensOfAst;
import frontend.storage : CrowFileInfo;
import test.testUtil : assertEqual, CrowJsonTest, Test, testWithCrowAndJsonFiles, withAstTest;

void testTokens(ref Test test) {
	testWithCrowAndJsonFiles!("tokens", ["basic"])(test, (in CrowJsonTest testData) {
		withAstTest(test, testData.uri, testData.crow, (in CrowFileInfo file) {
			assertEqual(jsonOfDecodedTokens(test.alloc, tokensOfAst(test.alloc, file)), testData.json);
		});
	});
}
