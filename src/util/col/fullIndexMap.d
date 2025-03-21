module util.col.fullIndexMap;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.conv : safeToUint, safeToUshort;
import util.col.array : endPtr, makeArray, mapWithIndex;
import util.memory : overwriteMemory;
import util.util : castImmutable;

struct FullIndexMap(K, V) {
	@disable this();
	this(inout V[] vs) inout { values = vs; }

	ref inout(V) opIndex(K key) inout =>
		values[key.index];

	static if ( __traits(isCopyable, V)) {
		void opIndexAssign(V value, K key) {
			overwriteMemory!V(&values[key.index], value);
		}
	}

	int opApply(in int delegate(ref immutable V) @safe @nogc pure nothrow cb) scope immutable {
		foreach (ref immutable V value; values) {
			int res = cb(value);
			if (res != 0)
				return res;
		}
		return 0;
	}

	uint length() scope const =>
		safeToUint(values.length);

	//TODO: private:
	V[] values;
}

@trusted K indexOfPointer(K, V)(in FullIndexMap!(K, V) a, in V* pointer) {
	assert(a.values.ptr <= pointer && pointer < endPtr(a.values));
	uint res = safeToUint(pointer - a.values.ptr);
	assert(res < a.values.length);
	return K(res);
}

immutable(FullIndexMap!(K, V)) fullIndexMapCastImmutable(K, V)(const FullIndexMap!(K, V) a) =>
	immutable FullIndexMap!(K, V)(castImmutable(a.values));
immutable(FullIndexMap!(K, V)) fullIndexMapCastImmutable2(K, V)(const FullIndexMap!(K, immutable V) a) =>
	immutable FullIndexMap!(K, V)(castImmutable(a.values));

immutable(FullIndexMap!(K, V)) emptyFullIndexMap(K, V)() =>
	fullIndexMapOfArr!(K, V)([]);

immutable(FullIndexMap!(K, V)) fullIndexMapOfArr(K, V)(return scope immutable V[] values) =>
	immutable FullIndexMap!(K, V)(values);
private FullIndexMap!(K, V) fullIndexMapOfArr_mut(K, V)(V[] values) =>
	FullIndexMap!(K, V)(values);

FullIndexMap!(K, V) makeFullIndexMap_mut(K, V)(
	ref Alloc alloc,
	immutable size_t size,
	in V delegate(K) @safe @nogc pure nothrow cb,
) =>
	fullIndexMapOfArr_mut!(K, V)(makeArray(alloc, size, (size_t i) =>
		cb(K(safeToUint(i)))));

void fullIndexMapEach(K, V)(
	in immutable FullIndexMap!(K, V) a,
	in void delegate(K, ref immutable V) @safe @nogc pure nothrow cb,
) {
	foreach (size_t key, ref immutable V value; a.values)
		cb(K(safeToUint(key)), value);
}

void fullIndexMapEach_const(K, V)(
	scope const FullIndexMap!(K, V) a,
	in void delegate(K, ref const V) @safe @nogc pure nothrow cb,
) {
	foreach (size_t key, ref const V value; a.values)
		cb(K(key), value);
}

void fullIndexMapEachPointer(K, V)(
	in immutable FullIndexMap!(K, V) a,
	in void delegate(K, immutable V*) @safe @nogc pure nothrow cb,
) {
	foreach (size_t key, ref immutable V value; a.values)
		cb(K(safeToUint(key)), &value);
}

void fullIndexMapZip(K, V0, V1)(
	immutable FullIndexMap!(K, V0) a,
	ref FullIndexMap!(K, V1) b,
	in void delegate(K, ref immutable V0, ref V1) @safe @nogc pure nothrow cb,
) {
	assert(a.length == b.length);
	foreach (size_t i; 0 .. a.length)
		cb(K(i), a.values[i], b.values[i]);
}

void fullIndexMapZip3(K, V0, V1, V2)(
	immutable FullIndexMap!(K, V0) a,
	immutable FullIndexMap!(K, V1) b,
	immutable FullIndexMap!(K, V2) c,
	in void delegate(K, ref immutable V0, ref immutable V1, ref immutable V2) @safe @nogc pure nothrow cb,
) {
	assert(a.length == b.length);
	assert(b.length == c.length);
	foreach (uint i; 0 .. a.length)
		cb(K(i), a.values[i], b.values[i], c.values[i]);
}

immutable(FullIndexMap!(K, VOut)) mapFullIndexMap(K, VOut, VIn)(
	ref Alloc alloc,
	in immutable FullIndexMap!(K, VIn) a,
	in immutable(VOut) delegate(K, ref immutable VIn) @safe @nogc pure nothrow cb,
) =>
	fullIndexMapOfArr!(K, VOut)(
		mapWithIndex!(immutable VOut, immutable VIn)(alloc, a.values, (size_t index, scope ref immutable VIn v) =>
			cb(K(K.sizeof == 8 ? index : K.sizeof == 4 ? safeToUint(index) : safeToUshort(index)), v)));

FullIndexMap!(K, VOut) mapFullIndexMap_mut(K, VOut, VIn)(
	ref Alloc alloc,
	immutable FullIndexMap!(K, VIn) a,
	in VOut delegate(K, in immutable VIn) @safe @nogc pure nothrow cb,
) =>
	fullIndexMapOfArr_mut!(K, VOut)(
		mapWithIndex!(VOut, VIn)(alloc, a.values, (size_t index, scope ref immutable VIn v) =>
			cb(K(K.sizeof == 8 ? index : K.sizeof == 4 ? safeToUint(index) : safeToUshort(index)), v)));
