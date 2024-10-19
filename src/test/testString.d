module test.testString;

@safe @nogc pure nothrow:

import test.testUtil : assertEqual, Test;
import util.comparison : Comparison;
import util.string : compareStringsNaturally;
import util.util : stringOfEnum;
import util.writer : writeQuotedString, Writer;

void testString(ref Test test) {
	assertLess("alpha-bet", "alphacat");
	assertLess("alphabet", "alpha-cat");
	assertLess("alphaCat", "alphacat");
	assertLess("nat8", "nat32");
	assertLess("*", "a");
	assertLess("~", "a");
}

private:

void assertLess(in string a, in string b) {
	assertComparisonInner(a, b, Comparison.less);
	assertComparisonInner(b, a, Comparison.greater);
}

void assertComparisonInner(in string a, in string b, Comparison expected) {
	assertEqual(
		compareStringsNaturally(a, b),
		expected,
		(scope ref Writer writer, in Comparison x) {
			writer ~= stringOfEnum(x);
		}, (scope ref Writer writer) {
			writer ~= "Comparing ";
			writeQuotedString(writer, a);
			writer ~= " to ";
			writeQuotedString(writer, b);
			writer ~= ":\n";
		});
}
