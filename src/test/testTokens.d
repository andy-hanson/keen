module test.testTokens;

@safe @nogc pure nothrow:

import frontend.ide.getTokens : jsonOfDecodedTokens, tokensOfAst;
import frontend.storage : CrowFileInfo;
import test.testUtil : assertEqual, Test, testWithCrowAndJsonFiles, withAstTest;
import util.json : Json;
import util.uri : Uri;

void testTokens(ref Test test) {
	testWithCrowAndJsonFiles!("tokens", ["basic"])(test, (Uri uri, in string crow, in Json json) {
		withAstTest(test, uri, crow, (in CrowFileInfo file) {
			assertEqual(jsonOfDecodedTokens(test.alloc, tokensOfAst(test.alloc, file)), json);
		});
	});
}
