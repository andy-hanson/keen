module test.testArrayBuilder;

@safe @nogc pure nothrow:

import test.testUtil : assertEqual, Test;
import util.col.arrayBuilder : buildGroupedAndSorted, GroupedSortedBuilder;
import util.col.map : KeyValuePair;
import util.comparison : compareUint;
import util.symbol : compareSymbolsNaturally, Symbol, symbol;
import util.writer : Writer, writeWithCommas;

void testArrayBuilder(ref Test test) {
	Result[] res = buildGroupedAndSorted!(Symbol, immutable uint, compareSymbolsNaturally, compareUint)(
		test.alloc,
		(scope ref GroupedSortedBuilder!(Symbol, immutable uint) x) {
			x.add(symbol!"green", 4);
			x.add(symbol!"blue", 1);
			x.add(symbol!"green", 2);
		});
	assertEqual!(Result[])(res, expected, (scope ref Writer writer, in Result[] results) {
		writeWithCommas!Result(writer, results, (in Result x) {
			write(writer, x);
		});
	});
}

private:

alias Result = immutable KeyValuePair!(Symbol, immutable(uint)[]);

immutable Result[] expected = [
	Result(symbol!"blue", [1]),
	Result(symbol!"green", [2, 4]),
];

void write(scope ref Writer writer, in Result a) {
	writer ~= a.key;
	writer ~= "{";
	writeWithCommas!uint(writer, a.value);
	writer ~= "}";
}

