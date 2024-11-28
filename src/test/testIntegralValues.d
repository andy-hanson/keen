module test.testIntegralValues;

@safe @nogc pure nothrow:

import model.integralValues :
	IntegralValue, IntegralValues, integralValuesRange, mapToIntegralValues, singleIntegralValue;
import test.testUtil : Test;
import util.col.array : arraysEqual, arraysIdentical;

void testIntegralValues(ref Test test) {
	assertSingle(singleIntegralValue(IntegralValue(5)), 5);
	assertSingle(singleIntegralValue(IntegralValue(big)), big);

	assertRange(integralValuesRange(5), 5);
	assertRange(integralValuesRange(big), big);

	assertSingle(mapToIntegralValues!uint([5], (ref const uint x) => IntegralValue(x)), 5);
	assertSingle(mapToIntegralValues!uint([big], (ref const uint x) => IntegralValue(x)), big);

	assertRange(mapToIntegralValues!uint([3, 1, 0, 2], (ref const uint x) => IntegralValue(x)), 4);
	uint[big] bigRangeReverse;
	foreach (uint i; 0 .. big)
		bigRangeReverse[i] = big - 1 - i;
	assertRange(mapToIntegralValues!uint(bigRangeReverse, (ref const uint x) => IntegralValue(x)), big);

	assert(arraysEqual(
		mapToIntegralValues!uint([0, 1], (ref const uint x) => IntegralValue(x)),
		integralValuesRange(2)));
	assert(arraysEqual(
		mapToIntegralValues!uint([1, 2], (ref const uint x) => IntegralValue(x)),
		[IntegralValue(1), IntegralValue(2)]));

	IntegralValues withHoles = mapToIntegralValues!uint([7, 1, 3], (ref const uint x) => IntegralValue(x));
	assert(arraysEqual(withHoles.values, [IntegralValue(1), IntegralValue(3), IntegralValue(7)]));
	IntegralValues withHoles2 = mapToIntegralValues!uint([3, 1, 7], (ref const uint x) => IntegralValue(x));
	assert(arraysIdentical(withHoles, withHoles2));
}

private:

// Value that should be too big for the default IntegralValues
uint big() =>
	0x101;

void assertSingle(IntegralValues a, ulong value) {
	assert(a.length && 1 && a[0].asUnsigned == value);
}

void assertRange(IntegralValues a, ulong n) {
	assert(a.length == n);
	foreach (size_t i; 0 .. a.length)
		assert(a[i].asUnsigned == i);
}
