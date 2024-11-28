module model.integralValues;

@safe @nogc nothrow:

import util.alloc.alloc : Alloc, AllocKind, MetaAlloc, newAlloc;
import util.alloc.stackAlloc : withExactStackArray, withMapToStackArray, withStackArray;
import util.comparison : compareUlong, Comparison;
import util.col.array : arraysEqual, arraysIdentical, copyArray, fold, isEmpty, only, small, SmallArray;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish;
import util.col.mutSet : getOrAddLazyAlloc, MutSet;
import util.col.sortUtil : assertSortedAndUnique, sortedArrayContains, sortedArrayIsSuperset, sortInPlace;
import util.conv : safeToUint;
import util.hash : HashCode, Hasher;
import util.memory : initMemory;

// A value of some contextually-known integral type.
immutable struct IntegralValue {
	@safe @nogc pure nothrow:

	// Large nat64 are represented as wrapped to negative values.
	ulong value;

	long asSigned() =>
		cast(long) value;
	ulong asUnsigned() =>
		value;

	IntegralValue opBinary(string op : "|")(IntegralValue b) =>
		IntegralValue(value | b.value);
}

// Set of IntegralValue, in sorted order with no repeats.
immutable struct IntegralValues {
	@safe @nogc pure nothrow:
	// These are sorted by the unsigned value
	SmallArray!IntegralValue values;

	private this(IntegralValue[] v) {
		values = v;
	}

	alias values this;

	bool isRange0ToN() scope =>
		isEmpty(values) || values[$ - 1].asUnsigned == values.length - 1;

	bool opEquals(in IntegralValues rhs) scope =>
		arraysIdentical(this, rhs);

	IntegralValue opIndex(size_t i) scope const =>
		values[i];

	bool opBinaryRight(string op)(IntegralValue x) scope const if (op == "in") =>
		sortedArrayContains!(IntegralValue, compareIntegralValue)(values, x);
	bool containsAll(IntegralValues xs) scope const =>
		sortedArrayIsSuperset!(IntegralValue, compareIntegralValue)(values, xs.values);

	IntegralValues opBinary(string op)(IntegralValue x) const if (op == "|") =>
		x in this ? this : add(this, x);
	IntegralValues opBinary(string op)(IntegralValues xs) const if (op == "|") =>
		fold!(IntegralValues, IntegralValue)(this, xs, (IntegralValues acc, in IntegralValue x) =>
			acc | x);
}

pure IntegralValues emptyIntegralValues() =>
	integralValuesRange(0);

pure IntegralValue only(in IntegralValues a) =>
	only(a.values);

@trusted void initIntegralValues(MetaAlloc* metaAlloc) {
	integralValuesAlloc = newAlloc(AllocKind.integralValues, metaAlloc);
	foreach (size_t i; 0 .. linear.length)
		initMemory(&linear[i], IntegralValue(i));
	// Make sure single and linear IntegralValues are in the map
	foreach (size_t i; 0 .. linear.length) {
		cast(void) getOrAddIntegralValues(singleIntegralValue(IntegralValue(i)).values);
		cast(void) getOrAddIntegralValues(linear[0 .. i]);
	}
}

// This is different from IntegralValues so it can do 'opEquals' by content
private immutable struct CacheEntry {
	@safe @nogc pure nothrow:
	SmallArray!IntegralValue values;

	bool opEquals(in CacheEntry b) scope =>
		arraysEqual(values, b.values);

	HashCode hash() scope {
		Hasher hasher;
		foreach (IntegralValue value; values)
			hasher ~= value.asUnsigned;
		return hasher.finish();
	}
}

private __gshared Alloc* integralValuesAlloc;
private __gshared MutSet!CacheEntry cache;
private immutable IntegralValue[0x100] linear;

@trusted pure IntegralValues integralValuesRange(size_t n) {
	if (n <= linear.length) {
		IntegralValues res = IntegralValues(linear[0 .. n]);
		assert(res.isRange0ToN);
		return res;
	} else
		return withStackArray!(IntegralValues, IntegralValue)(
			n,
			(size_t x) => IntegralValue(x),
			(scope IntegralValue[] xs) => getOrAddIntegralValues(xs));
}

pure IntegralValues singleIntegralValue(in IntegralValue a) {
	ulong x = a.asUnsigned;
	return x < linear.length
		? IntegralValues(linear[safeToUint(x) .. safeToUint(x) + 1])
		: getOrAddIntegralValues([IntegralValue(x)]);
}

@trusted pure IntegralValues mapToIntegralValues(T)(
	in T[] xs,
	in IntegralValue delegate(ref const T) @safe @nogc pure nothrow cb,
) {
	switch (xs.length) {
		case 0:
			return emptyIntegralValues;
		case 1:
			return singleIntegralValue(cb(only(xs)));
		default:
			return withMapToStackArray!(IntegralValues, IntegralValue, const T)(xs, cb, (scope IntegralValue[] values) {
				sortInPlace!(IntegralValue, compareIntegralValue)(values);
				assertSortedAndUnique!(IntegralValue, compareIntegralValue)(values);
				return values[$ - 1].asUnsigned == values.length - 1
					? integralValuesRange(xs.length)
					: getOrAddIntegralValues(values);
			});
	}
}

private:

pure IntegralValues add(IntegralValues a, IntegralValue value) {
	assert(value !in a);
	return withExactStackArray!(IntegralValues, IntegralValue)(
		a.length + 1,
		(scope ref ExactSizeArrayBuilder!IntegralValue out_) {
			bool didAdd = false;
			foreach (IntegralValue x; a.values) {
				if (didAdd || x.value < value.value)
					out_ ~= x;
				else {
					out_ ~= value;
					out_ ~= x;
					didAdd = true;
				}
			}
			if (!didAdd)
				out_ ~= value;
			return getOrAddIntegralValues(finish(out_));
		});
}

@trusted pure IntegralValues getOrAddIntegralValues(in IntegralValue[] values) =>
	(cast(IntegralValues function(in IntegralValue[]) @safe @nogc pure nothrow) &getOrAddIntegralValues_impure)(values);

@system IntegralValues getOrAddIntegralValues_impure(
	in IntegralValue[] values,
) {
	assertSortedAndUnique!(IntegralValue, compareIntegralValue)(values);
	CacheEntry res = getOrAddLazyAlloc!CacheEntry(
		*integralValuesAlloc, cache, CacheEntry(small!IntegralValue(values)),
		cast(CacheEntry delegate() @safe @nogc pure nothrow) () =>
			CacheEntry(small!IntegralValue(copyArray(*integralValuesAlloc, values))));
	return IntegralValues(res.values);
}

pure Comparison compareIntegralValue(in IntegralValue a, in IntegralValue b) =>
	compareUlong(a.value, b.value);
