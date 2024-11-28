module test.testSyntaxTranslate;

@safe @nogc pure nothrow:

import frontend.ide.syntaxTranslate : syntaxTranslate;
import lib.lsp.lspTypes : SyntaxTranslateParams, SyntaxTranslateResult, Language;
import model.sourceRange : Pos;
import test.testUtil : assertEqual, Test;
import util.col.array : arraysEqual;

void testSyntaxTranslate(ref Test test) {
	testAllWays(test, "a", "a", "a");
	testAllWays(test, "a f", "f(a)", "a.f()");
	testAllWays(test, "a.f.g h", "h(g(f(a)))", "a.f().g().h()");
	testAllWays(test, "a f b", "f(a, b)", "a.f(b)");
	testAllWays(test, "a f b, c", "f(a, b, c)", "a.f(b, c)");
	testAllWays(test, "a.g f b, c", "f(g(a), b, c)", "a.g().f(b, c)");
	testAllWays(test, "a.g f b.h, c", "f(g(a), h(b), c)", "a.g().f(b.h(), c)");
	testAllWays(test, "a g b f c, d", "f(g(a, b), c, d)", "a.g(b).f(c, d)");
	testAllWays(test, "a g b, c f d, e", "f(g(a, b, c), d, e)", "a.g(b, c).f(d, e)");
	testAllWays(test, "a g b f (c h d), e.i", "f(g(a, b), h(c, d), i(e))", "a.g(b).f(c.h(d), e.i())");
	testAllWays(test, "a !f b", "not(f(a, b))", "a.f(b).not()");
	testAllWays(test, "a f! b", "force(f(a, b))", "a.f(b).force()");

	testOneWay(test, Language.c, "f(a) x", Language.crow, "a f", [5]);
	testOneWay(test, Language.crow, "x\n", Language.c, "", [0]);
}

private:

void testAllWays(ref Test test, in string crow, in string c, in string java) {
	testOneWay(test, Language.crow, crow, Language.c, c);
	testOneWay(test, Language.crow, crow, Language.java, java);
	testOneWay(test, Language.c, c, Language.crow, crow);
	testOneWay(test, Language.c, c, Language.java, java);
	testOneWay(test, Language.java, java, Language.crow, crow);
	testOneWay(test, Language.java, java, Language.c, c);
}

void testOneWay(
	ref Test test,
	Language from,
	in string source,
	Language to,
	in string expected,
	in Pos[] expectedDiagnostics = [],
) {
	SyntaxTranslateResult result = syntaxTranslate(test.alloc, SyntaxTranslateParams(source, from, to));
	assert(arraysEqual(result.diagnostics, expectedDiagnostics));
	assertEqual(result.output, expected);
}
