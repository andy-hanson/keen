module test.testWriter;

@safe @nogc pure nothrow:

import test.testUtil : assertEqual, Test;
import util.writer : withStackWriter, writeFloatLiteralForC, writeFloatLiteralForJS, writeQuotedString, Writer;

void testWriter(ref Test test) {
	testFloatLiteral();
	testQuotedString();
}

private:

void testFloatLiteral() {
	void writes(double value, string expectedCLiteral, string expectedJSLiteral = "<<") {
		withStackWriter!0x1000(
			(scope ref Writer writer) {
				writeFloatLiteralForC(writer, value);
			},
			(in string actual) {
				assertEqual(actual, expectedCLiteral);
			});


		withStackWriter!0x1000(
			(scope ref Writer writer) {
				writeFloatLiteralForJS(writer, value);
			},
			(in string actual) {
				assertEqual(actual, expectedJSLiteral == "<<" ? expectedCLiteral : expectedJSLiteral);
			});
	}

	writes(double.nan, "NAN", "Number.NaN");
	writes(double.infinity, "INFINITY", "Number.POSITIVE_INFINITY");
	writes(-double.infinity, "-INFINITY", "-Number.POSITIVE_INFINITY");
	writes(-0.0, "-0");
	writes(0.0, "0");
	writes(123, "123");
	writes(-123, "-123");
	writes(1.2, "1.2");
	writes(-1.2, "-1.2");
	writes(1.23, "0x1.3ae147ae147aep0", "1.23");
	writes(-1.23, "-0x1.3ae147ae147aep0", "-1.23");
	writes(0.75, "0x1.8000000000000p-1", "0.75");
	writes(0.001, "0x1.0624dd2f1a9fcp-10", "0.001");
	writes(0.000_001, "0x1.0c6f7a0b5ed8dp-20", "0.000001");
	writes(3.141592653589793239, "0x1.921fb54442d18p1", "3.141592653589793");
}

void testQuotedString() {
	void writes(string value, string expected) {
		withStackWriter!0x1000(
			(scope ref Writer writer) {
				writeQuotedString(writer, value);
			},
			(in string actual) {
				assertEqual(actual, expected);
			});
	}

	writes("$¥₿𝄮", "\"$¥₿𝄮\"");
}
