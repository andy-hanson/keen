module util.col.exactSizeArrayBuilder;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc, allocateElements;
import util.col.array : endPtr, small, SmallArray;
import util.string : eachChar, CString, cStringSize;
import util.memory : initMemory, memset;

struct ExactSizeArrayBuilder(T) {
	private:
	T[] inner;
	T* cur;

	@trusted void opOpAssign(string op : "~")(T value) scope {
		initMemory!T(pushUninitialized(this), value);
	}
}

T[] buildArrayExact(T)(
	ref Alloc alloc,
	size_t size,
	in void delegate(scope ref ExactSizeArrayBuilder!T) @safe @nogc pure nothrow cb,
) {
	ExactSizeArrayBuilder!T builder = newExactSizeArrayBuilder!T(alloc, size);
	cb(builder);
	return finish(builder);
}
SmallArray!T buildSmallArrayExact(T)(
	ref Alloc alloc,
	size_t size,
	in void delegate(scope ref ExactSizeArrayBuilder!T) @safe @nogc pure nothrow cb,
) =>
	small!T(buildArrayExact!T(alloc, size, cb));

T* pushUninitialized(T)(ref ExactSizeArrayBuilder!T a) @trusted {
	assert(a.cur < endPtr(a.inner));
	T* res = a.cur;
	a.cur++;
	return res;
}

@trusted T[] finish(T)(return scope ref ExactSizeArrayBuilder!T a) {
	assert(a.cur == endPtr(a.inner));
	return finishAllowSmaller!T(a);
}

@trusted T[] finishAllowSmaller(T)(return scope ref ExactSizeArrayBuilder!T a) {
	T[] res = a.inner[0 .. (a.cur - a.inner.ptr)];
	a.inner = [];
	a.cur = a.inner.ptr;
	return res;
}

SmallArray!T smallFinish(T)(ref ExactSizeArrayBuilder!T a) =>
	small!T(finish(a));

@trusted size_t exactSizeArrBuilderCurSize(T)(ref const ExactSizeArrayBuilder!T a) =>
	a.cur - a.inner.ptr;

@trusted ExactSizeArrayBuilder!T newExactSizeArrayBuilder(T)(ref Alloc alloc, size_t size) {
	T[] inner = allocateElements!T(alloc, size);
	return ExactSizeArrayBuilder!T(inner, inner.ptr);
}

void add16(scope ref ExactSizeArrayBuilder!ubyte a, ushort value) {
	addT(a, value);
}

void add32(scope ref ExactSizeArrayBuilder!ubyte a, uint value) {
	addT(a, value);
}

void add64(scope ref ExactSizeArrayBuilder!ubyte a, ulong value) {
	addT(a, value);
}

@trusted private void addT(T)(scope ref ExactSizeArrayBuilder!ubyte a, T value) {
	assert(a.cur + T.sizeof <= endPtr(a.inner));
	T* ptr = cast(T*) a.cur;
	*ptr = value;
	a.cur = cast(ubyte*) (ptr + 1);
}

void padTo(scope ref ExactSizeArrayBuilder!ubyte a, size_t desiredSize) {
	if (exactSizeArrBuilderCurSize(a) < desiredSize)
		add0Bytes(a, desiredSize - exactSizeArrBuilderCurSize(a));
	assert(exactSizeArrBuilderCurSize(a) == desiredSize);
}

@trusted void add0Bytes(scope ref ExactSizeArrayBuilder!ubyte a, size_t nBytes) {
	assert(a.cur + nBytes <= endPtr(a.inner));
	memset(a.cur, 0, nBytes);
	a.cur += nBytes;
}

@trusted void add64TextPtr(scope ref ExactSizeArrayBuilder!ubyte a, size_t textIndex) {
	add64(a, cast(immutable ulong) &a.inner[textIndex]);
}

@trusted void addStringAndNulTerminate(scope ref ExactSizeArrayBuilder!ubyte a, CString value) {
	assert(a.cur + cStringSize(value) < endPtr(a.inner));
	eachChar(value, (char c) @trusted {
		*a.cur = c;
		a.cur++;
	});
	*a.cur = '\0';
	a.cur++;
}
