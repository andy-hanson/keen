module util.col.arrayBuilder;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.col.array : contains, small, SmallArray;
import util.col.mutArr : asTemporaryArray, moveToArray, MutArr, mutArrIsEmpty, mutArrSize, mustPop, push, pushAll;
import util.col.sortUtil : sortInPlace;
import util.conv : safeToUint;

struct ArrayBuilder(T) {
	private MutArr!(immutable T) data;
}

struct Builder(T) {
	private Alloc* allocPtr;
	private ArrayBuilder!T inner;

	ref Alloc alloc() return scope =>
		*allocPtr;

	void opOpAssign(string op)(in T x) scope if (op == "~") {
		add!T(alloc, inner, x);
	}
	void opOpAssign(string op)(in T[] xs) scope if (op == "~") {
		addAll!T(alloc, inner, xs);
	}
}

void addIfNotContains(T)(scope ref Builder!T a, T value) {
	if (!contains(asTemporaryArray(a), value))
		a ~= value;
}

immutable(SmallArray!T) smallFinish(T)(scope ref Builder!T a) =>
	smallFinish(a.alloc, a.inner);

immutable(T[]) finish(T)(ref Builder!T a) =>
	finish(a.alloc, a.inner);

T[] buildArray(T)(ref Alloc alloc, in void delegate(scope ref Builder!T) @safe @nogc pure nothrow cb) {
	Builder!T res = Builder!T(&alloc);
	cb(res);
	return finish(res);
}
T[] buildSortedArray(T, alias compare)(
	ref Alloc alloc,
	in void delegate(scope ref Builder!T) @safe @nogc pure nothrow cb
) {
	Builder!T res = Builder!T(&alloc);
	cb(res);
	arrayBuilderSort!(T, compare)(res);
	return finish(res);
}

SmallArray!T buildSmallArray(T)(ref Alloc alloc, in void delegate(scope ref Builder!T) @safe @nogc pure nothrow cb) {
	Builder!T res = Builder!T(&alloc);
	cb(res);
	return smallFinish(res);
}

size_t sizeSoFar(T)(in Builder!T a) =>
	mutArrSize(a.inner.data);

void add(T)(scope ref Alloc alloc, ref ArrayBuilder!T a, immutable T value) {
	push(alloc, a.data, value);
}

uint addAndGetIndex(T)(ref Alloc alloc, scope ref ArrayBuilder!T a, T value) {
	uint res = safeToUint(mutArrSize(a.data));
	add(alloc, a, value);
	return res;
}

ref T mustPeek(T)(ref ArrayBuilder!T a) =>
	a.data[$ - 1];

void backUp(T)(ref ArrayBuilder!T a) {
	mustPop(a.data);
}

void addAll(T)(ref Alloc alloc, ref ArrayBuilder!(immutable T) a, in immutable T[] value) {
	pushAll(alloc, a.data, value);
}

const(T[]) asTemporaryArray(T)(ref const ArrayBuilder!T a) =>
	.asTemporaryArray(a.data);
const(T[]) asTemporaryArray(T)(ref const Builder!T a) =>
	.asTemporaryArray(a.inner);

void arrayBuilderSort(T, alias compare)(scope ref ArrayBuilder!T a) {
	sortInPlace!(immutable T, compare)(asTemporaryArray(a));
}
void arrayBuilderSort(T, alias compare)(scope ref Builder!T a) {
	arrayBuilderSort!(T, compare)(a.inner);
}

immutable(SmallArray!T) smallFinish(T)(ref Alloc alloc, scope ref ArrayBuilder!T a) =>
	small!T(finish(alloc, a));

immutable(T[]) finish(T)(ref Alloc alloc, scope ref ArrayBuilder!T a) =>
	moveToArray(alloc, a.data);

bool arrayBuilderIsEmpty(T)(in ArrayBuilder!T a) =>
	mutArrIsEmpty(a.data);
