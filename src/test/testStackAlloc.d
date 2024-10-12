module test.testStackAlloc;

@safe @nogc pure nothrow:

import util.alloc.stackAlloc : withMapToStackArray;
import test.testUtil : assertEqual, Test;

void testStackAlloc(ref Test test) {
	uint res = withMapToStackArray!(uint, uint, uint)(
		[1, 2, 3],
		(ref uint x) => x + 1,
		(scope uint[] results) {
			assertEqual(results, [2, 3, 4]);
			return 42;
		});
	assertEqual(res, 42);
}
