module test.testStackAlloc;

@safe @nogc pure nothrow:

import util.alloc.stackAlloc : TwoStackArraysBuilder, withBuild2StackArrays;
import test.testUtil : assertEqual, Test;

void testStackAlloc(ref Test test) {
	size_t res = withBuild2StackArrays!(size_t, uint)(
		(scope ref TwoStackArraysBuilder!uint out_) {
			out_.writeFirst(1);
			out_.writeSecond(2);
			out_.writeFirst(3);
			out_.writeSecond(4);
		},
		(in uint[] x, in uint[] y) {
			assertEqual(x, [1, 3]);
			assertEqual(y, [2, 4]);
			return x.length + y.length;
		});
	assertEqual(res, 4);
}
