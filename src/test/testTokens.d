module test.testTokens;

@safe @nogc pure nothrow:

import frontend.ide.getTokens : jsonOfDecodedTokens, tokensOfAst;
import frontend.storage : CrowFileInfo;
import test.testUtil : Test, withAstTests;

void testTokens(ref Test test) {
	withAstTests!("tokens", ["basic"])(test, (in CrowFileInfo file) =>
		jsonOfDecodedTokens(test.alloc, tokensOfAst(test.alloc, file)));
}
