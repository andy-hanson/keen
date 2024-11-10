module util.col.array;

import util.alloc.alloc : Alloc, allocateElements, freeElements;
import util.alloc.stackAlloc : withStackArray;
import util.conv : safeToUshort;
import util.memory : copyToFrom, initMemory, overwriteMemory;
import util.opt : force, has, none, MutOpt, Opt, optIf, some, someMut;
import util.union_ : TaggedUnion, Union;
import util.util : castImmutable, max, typeAs;

@safe @nogc nothrow:

@trusted Out[] mapImpure(Out, In)(ref Alloc alloc, in In[] a, in Out delegate(in In) @safe @nogc nothrow cb) {
	Out[] res = allocateElements!Out(alloc, a.length);
	foreach (size_t i, ref In x; a)
		initMemory(&res[i], cb(x));
	return res;
}

pure:

// Like SmallArray but without implying that it's an array
struct PtrAndSmallNumber(T) {
	@safe @nogc pure nothrow:

	version (WebAssembly) {
		T* ptr;
		ushort number;
		static assert((T*).sizeof == uint.sizeof);

		@system ulong asTaggable() const =>
			((cast(ulong) ptr) << 32) | ((cast(ulong) number) << 16);
		@system static PtrAndSmallNumber!T fromTagged(ulong x) =>
			PtrAndSmallNumber!T(cast(T*) (x >> 32), cast(ushort) (x >> 16));
	} else {
		static assert((T*).sizeof == ulong.sizeof);
		union {
			private T* pointerValue; // Not a valid pointer! Here so 'scope' works.
			private ulong value;
		}

		private this(ulong v) inout {
			value = v;
		}
		@trusted this(return scope inout T* ptr, ushort number) inout {
			static assert(ushort.max == 0xffff);
			ulong val = cast(ulong) ptr;
			assert((val & 0xffff_0000_0000_0000) == 0);
			value = ((cast(ulong) number) << 48) | val;
		}

		@system ulong asTaggable() inout =>
			value;
		@system static PtrAndSmallNumber!T fromTagged(ulong x) =>
			PtrAndSmallNumber!T(x);

		@trusted inout(T*) ptr() inout =>
			cast(inout T*) (value & 0x0000_ffff_ffff_ffff);

		ushort number() const =>
			(value & 0xffff_0000_0000_0000) >> 48;
	}
}

struct MutSmallArray(T) {
	@safe @nogc pure nothrow:
	alias toArray this;

	this(inout PtrAndSmallNumber!T v) inout {
		sizeAndBegin = v;
	}

	@system ulong asTaggable() const =>
		sizeAndBegin.asTaggable;
	@system static MutSmallArray!T fromTagged(ulong x) =>
		MutSmallArray!T(PtrAndSmallNumber!T.fromTagged(x));

	@trusted this(return scope inout T[] values) inout {
		sizeAndBegin = inout PtrAndSmallNumber!T(values.ptr, safeToUshort(values.length));
	}

	@trusted inout(T[]) toArray() inout {
		size_t length = sizeAndBegin.number;
		assert(length < 0xffff); // sanity check
		return sizeAndBegin.ptr[0 .. length];
	}

	@disable bool opEquals(in MutSmallArray!T rhs) scope const;

	PtrAndSmallNumber!T sizeAndBegin;
}
alias SmallArray(T) = immutable MutSmallArray!T;

template small(T) {
	static if (is(T == immutable)) {
		@disable void small(T)(in MutSmallArray!T);
		SmallArray!T small(T)(return scope T[] values) =>
			SmallArray!T(values);
	} else {
		@disable void small(T)(in MutSmallArray!T);
		inout(MutSmallArray!T) small(T)(return scope inout T[] values) =>
			inout MutSmallArray!T(values);
	}
}

MutSmallArray!T emptyMutSmallArray(T)() =>
	MutSmallArray!T(PtrAndSmallNumber!T(typeAs!(T*)(null), 0));

SmallArray!T emptySmallArray(T)() =>
	// Don't use `SmallArray!T([])` because that can't be evaluated at compile time
	SmallArray!T(immutable PtrAndSmallNumber!T(typeAs!(immutable T*)(null), 0));

@system inout(T[]) arrayOfRange(T)(inout T* begin, inout T* end) {
	assert(begin <= end);
	return begin[0 .. end - begin];
}

bool sizeEq(T, U)(in T[] a, in U[] b) =>
	a.length == b.length;

bool sizeEq3(T, U, V)(in T[] a, in U[] b, in V[] c) =>
	a.length == b.length && b.length == c.length;

bool isEmpty(T)(in T[] a) =>
	a.length == 0;

Opt!T optOnly(T)(in T[] a) =>
	optIf(a.length == 1, () => only(a));

ref inout(T) only(T)(scope inout T[] a) {
	assert(a.length == 1);
	return a[0];
}

T* onlyPointer(T)(T[] a) {
	assert(a.length == 1);
	return &a[0];
}

ref inout(T[2]) only2(T)(return scope inout T[] a) {
	assert(a.length == 2);
	return a[0 .. 2];
}

@trusted T[] arrayOfSingle(T)(T* a) =>
	a[0 .. 1];

@system T* endPtr(T)(T[] a) =>
	a.ptr + a.length;

@system bool isPointerInRange(T)(in T[] xs, in T* x) =>
	xs.ptr <= x && x < endPtr(xs);

@trusted T[] newArray(T)(ref Alloc alloc, scope T[] values) {
	T[] res = allocateElements!T(alloc, values.length);
	foreach (size_t i, ref T x; values)
		initMemory!T(&res[i], x);
	return res;
}

SmallArray!T newSmallArray(T)(ref Alloc alloc, scope T[] values) =>
	small!T(newArray(alloc, values));

@trusted Out[] makeArray(Out)(ref Alloc alloc, size_t size, in Out delegate(size_t) @safe @nogc pure nothrow cb) {
	Out[] res = allocateElements!Out(alloc, size);
	foreach (size_t i; 0 .. size)
		initMemory(&res[i], cb(i));
	return res;
}

@trusted T[] fillArray(T)(ref Alloc alloc, size_t size, T value) =>
	makeArray(alloc, size, (size_t _) => value);

bool exists(T)(in T[] arr, in bool delegate(in T) @safe @nogc pure nothrow cb) =>
	.exists!T(arr, (ref const T x) => cb(x));
bool exists(T)(in T[] arr, in bool delegate(ref const T) @safe @nogc pure nothrow cb) {
	foreach (ref const T x; arr)
		if (cb(x))
			return true;
	return false;
}

bool every(T)(in T[] arr, in bool delegate(in T) @safe @nogc pure nothrow cb) =>
	everyWithIndex!T(arr, (size_t _, ref const T x) => cb(x));
bool every(in bool[] a) =>
	every(a, (in bool x) => x);

bool everyWithIndex(T)(in T[] arr, in bool delegate(size_t, ref const T) @safe @nogc pure nothrow cb) {
	foreach (size_t i, ref const T x; arr)
		if (!cb(i, x))
			return false;
	return true;
}

bool allSame(Out, T)(in T[] arr, in Out delegate(in T) @safe @nogc pure nothrow cb) {
	if (isEmpty(arr))
		return true;
	else {
		Out value = cb(arr[0]);
		foreach (ref const T x; arr[1 .. $])
			if (cb(x) != value)
				return false;
		return true;
	}
}

bool contains(T)(in T[] xs, in T value) =>
	exists!T(xs, (in T x) => x == value);

ref const(T) mustFind(T)(return in T[] a, in bool delegate(ref T) @safe @nogc pure nothrow cb) {
	foreach (ref const T x; a)
		if (cb(x))
			return x;
	assert(false);
}

ref const(T) mustFindOnly(T)(return in T[] a, in bool delegate(ref T) @safe @nogc pure nothrow cb) {
	foreach (size_t i, ref const T x; a)
		if (cb(x)) {
			foreach (ref const T y; a[i + 1 .. $])
				assert(!cb(y));
			return x;
		}
	assert(false);
}

Opt!T find(T)(in T[] a, in bool delegate(in T) @safe @nogc pure nothrow cb) {
	foreach (ref const T x; a)
		if (cb(x))
			return some(x);
	return none!T;
}

Opt!(T*) findPointer(T)(T[] a, in bool delegate(in T) @safe @nogc pure nothrow cb) {
	foreach (ref T x; a)
		if (cb(x))
			return some(&x);
	return none!(T*);
}

T* mustFindPointer(T)(T[] a, in bool delegate(ref const T) @safe @nogc pure nothrow cb) {
	foreach (ref T x; a)
		if (cb(x))
			return &x;
	assert(false);
}

Opt!size_t findIndex(T)(in T[] a, in bool delegate(in T) @safe @nogc pure nothrow cb) {
	foreach (size_t i, ref const T x; a)
		if (cb(x))
			return some(i);
	return none!size_t;
}

Opt!size_t indexOf(T)(in T[] xs, in T value) =>
	findIndex!T(xs, (in T x) => x == value);

Opt!size_t lastIndexOf(T)(in T[] xs, in T value) {
	foreach_reverse (size_t i, T x; xs)
		if (x == value)
			return some(i);
	return none!size_t;
}

Opt!size_t indexOfStartingAt(T)(in T[] xs, in T value, size_t start) {
	Opt!size_t indexFromStart = indexOf(xs[start .. $], value);
	return has(indexFromStart) ? some(force(indexFromStart) + start) : none!size_t;
}

size_t mustHaveIndexOfPointer(T)(in T[] xs, in T* pointer) {
	Opt!size_t res = indexOfPointer(xs, pointer);
	return force(res);
}

@trusted Opt!size_t indexOfPointer(T)(in T[] xs, in T* pointer) {
	size_t res = pointer - xs.ptr;
	return 0 <= res && res < xs.length ? some(res) : none!size_t;
}

Opt!Out firstWithIndex(Out, In)(in In[] a, in Opt!Out delegate(size_t, In) @safe @nogc pure nothrow cb) {
	foreach (size_t index, In x; a) {
		Opt!Out res = cb(index, x);
		if (has(res))
			return res;
	}
	return none!Out;
}

Opt!Out first(Out, In)(in In[] a, in Opt!Out delegate(In) @safe @nogc pure nothrow cb) =>
	firstWithIndex!(Out, In)(a, (size_t _, In x) => cb(x));

Opt!Out firstPointer(Out, In)(In[] a, in Opt!Out delegate(In*) @safe @nogc pure nothrow cb) {
	foreach (ref In x; a) {
		Opt!Out res = cb(&x);
		if (has(res))
			return res;
	}
	return none!Out;
}

Opt!Out firstZipIfSizeEq(Out, In0, In1)(
	in In0[] a,
	in In1[] b,
	in Opt!Out delegate(In0, In1) @safe @nogc pure nothrow cb,
) =>
	sizeEq(a, b) ? firstZip!(Out, In0, In1)(a, b, cb) : none!Out;

Opt!Out firstZip(Out, In0, In1)(in In0[] a, in In1[] b, in Opt!Out delegate(In0, In1) @safe @nogc pure nothrow cb) {
	assert(sizeEq(a, b));
	return firstWithIndex!(Out, In0)(a, (size_t i, In0 x) => cb(x, b[i]));
}

Opt!Out firstZipPointerFirst(Out, In0, In1)(
	In0[] a,
	in In1[] b,
	in Opt!Out delegate(In0*, In1) @safe @nogc pure nothrow cb,
) {
	assert(sizeEq(a, b));
	return firstWithIndex!(Out, In1)(b, (size_t i, In1 x) => cb(&a[i], x));
}

SmallArray!T copyArray(T)(ref Alloc alloc, scope SmallArray!T a) =>
	small!T(copyArray(alloc, a.toArray));
T[] copyArray(T)(ref Alloc alloc, scope T[] a) =>
	map!(T, T)(alloc, a, (ref T x) => x);

SmallArray!Out map(Out, In)(ref Alloc alloc, in SmallArray!In a, in Out delegate(ref In) @safe @nogc pure nothrow cb) =>
	small!Out(map!(Out, In)(alloc, a.toArray, cb));
@trusted Out[] map(Out, In)(
	ref Alloc alloc,
	scope In[] a,
	in Out delegate(ref In) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.length);
	foreach (size_t i, ref In x; a)
		initMemory(&res[i], cb(x));
	return res;
}

@trusted Out[] mapWithFirst(Out, In)(
	ref Alloc alloc,
	Out first,
	in In[] a,
	in Out delegate(size_t, ref In) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, 1 + a.length);
	initMemory!Out(&res[0], first);
	foreach (size_t i, ref In x; a)
		initMemory!Out(&res[1 + i], cb(i, x));
	return res;
}

Out[n] mapStatic(size_t n, Out, In)(ref In[n] a, in Out delegate(In) @safe @nogc pure nothrow cb) {
	static if (n == 0)
		return [];
	else static if (n == 1)
		return [cb(a[0])];
	else static if (n == 2)
		return [cb(a[0]), cb(a[1])];
	else static if (n == 3)
		return [cb(a[0]), cb(a[1]), cb(a[2])];
	else static if (n == 4)
		return [cb(a[0]), cb(a[1]), cb(a[2]), cb(a[3])];
	else
		static assert(false, "TODO");
}
Out[n] mapCompileTime(size_t n, Out, alias a, alias cb)() { // TODO: merge with mapStatic? ------------------------
	static if (n == 0)
		return [];
	else static if (n == 1)
		return [cb!(a[0])];
	else static if (n == 2)
		return [cb!(a[0]), cb!(a[1])];
	else static if (n == 3)
		return [cb!(a[0]), cb!(a[1]), cb!(a[2])];
	else static if (n == 4)
		return [cb!(a[0]), cb!(a[1]), cb!(a[2]), cb!(a[3])];
	else
		static assert(false, "TODO");
}

size_t count(T)(in T[] a, in bool delegate(in T) @safe @nogc pure nothrow cb) {
	size_t res = 0;
	foreach (ref const T x; a)
		if (cb(x))
			res++;
	return res;
}

immutable struct NoneOneOrMany {
	immutable struct None {}
	immutable struct One {
		size_t index;
		private size_t _padding; // Avoid suggestion to use TaggedUnion
	}
	immutable struct Many {}
	mixin Union!(None, One, Many);
}
NoneOneOrMany noneOneOrMany(T)(in T[] a, in bool delegate(in T) @safe @nogc pure nothrow cb) {
	MutOpt!size_t res;
	foreach (size_t index, ref const T x; a)
		if (cb(x)) {
			if (has(res))
				return NoneOneOrMany(NoneOneOrMany.Many());
			else
				res = someMut(index);
		}

	return has(res)
		? NoneOneOrMany(NoneOneOrMany.One(force(res)))
		: NoneOneOrMany(NoneOneOrMany.None());
}

@trusted T[] filter(T)(ref Alloc alloc, in T[] a, in bool delegate(in T) @safe @nogc pure nothrow cb) =>
	mapOp!(T, T)(alloc, a, (ref T x) =>
		cb(x) ? some(x) : none!T);

@trusted void filterUnordered(T)(
	scope ref T[] a,
	in bool delegate(ref T) @safe @nogc pure nothrow pred,
) {
	T* newEnd = filterUnorderedRecur!T(a.ptr, endPtr(a), pred);
	a = a[0 .. newEnd - a.ptr];
}
private @system T* filterUnorderedRecur(T)(
	T* begin,
	T* end,
	in bool delegate(ref T) @safe @nogc pure nothrow pred,
) {
	assert(begin <= end);
	return begin == end
		? end
		: pred(*begin)
		? filterUnorderedRecur!T(begin + 1, end, pred)
		: filterUnorderedFillHole!T(begin, end, pred);
}
// 'pred' is false for 'begin', so fill the hole
private @system T* filterUnorderedFillHole(T)(
	T* begin,
	T* end,
	in bool delegate(ref T) @safe @nogc pure nothrow pred,
) {
	if (begin + 1 == end)
		return begin;
	else if (pred(*(end - 1))) {
		overwriteMemory(begin, *(end - 1));
		return filterUnorderedRecur!T(begin + 1, end - 1, pred);
	} else
		return filterUnorderedFillHole!T(begin, end - 1, pred);
}

void filterUnorderedButDontRemoveAll(T)(
	scope ref T[] a,
	in bool delegate(ref T) @safe @nogc pure nothrow pred,
) {
	withStackArray!(void, size_t)(
		a.length,
		(size_t i) => 0,
		(scope size_t[] keep) {
			size_t nToKeep;
			foreach (size_t i, ref T x; a)
				if (pred(x)) {
					keep[nToKeep] = i;
					nToKeep++;
				}
			if (nToKeep != 0) {
				foreach (size_t outI, size_t inI; keep)
					if (inI != outI)
						overwriteMemory(&a[outI], a[inI]);
				a = a[0 .. nToKeep];
			}
		});
}

@trusted Out[] mapOp(Out, In)(
	ref Alloc alloc,
	in In[] a,
	in Opt!Out delegate(ref In) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.length);
	size_t outI = 0;
	foreach (ref const In x; a) {
		Opt!Out o = cb(x);
		if (has(o)) {
			initMemory(&res[outI], force(o));
			outI++;
		}
	}
	freeElements(alloc, res[outI .. $]);
	return res[0 .. outI];
}

SmallArray!Out mapWithIndex(Out, In)(
	ref Alloc alloc,
	in SmallArray!In a,
	in Out delegate(size_t, ref In) @safe @nogc pure nothrow cb,
) =>
	small!Out(mapWithIndex!(Out, In)(alloc, a.toArray, cb));
Out[] mapWithIndex(Out, In)(
	ref Alloc alloc,
	in In[] a,
	in Out delegate(size_t, ref In) @safe @nogc pure nothrow cb,
) =>
	mapPointers!(Out, In)(alloc, a, (In* x) @trusted =>
		cb(x - a.ptr, *x));

SmallArray!Out mapPointers(Out, In)(
	ref Alloc alloc,
	SmallArray!In a,
	in Out delegate(In*) @safe @nogc pure nothrow cb,
) =>
	small!Out(mapPointers!(Out, In)(alloc, a.toArray, cb));
@trusted Out[] mapPointers(Out, In)(
	ref Alloc alloc,
	In[] a,
	in Out delegate(In*) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.length);
	foreach (size_t i; 0 .. a.length)
		initMemory(&res[i], cb(&a[i]));
	return res[0 .. a.length];
}

@trusted SmallArray!Out mapOpPointers(Out, In)(
	ref Alloc alloc,
	SmallArray!In a,
	in Opt!Out delegate(In*) @safe @nogc pure nothrow cb,
) =>
	mapOpPointersWithSoFar!(Out, In)(alloc, a, (In* x, in Out[]) => cb(x));

@trusted SmallArray!Out mapOpPointersWithSoFar(Out, In)(
	ref Alloc alloc,
	SmallArray!In a,
	in Opt!Out delegate(In*, in Out[]) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.length);
	size_t outI = 0;
	foreach (size_t i; 0 .. a.length) {
		Opt!Out o = cb(&a[i], res[0 .. outI]);
		if (has(o)) {
			initMemory(&res[outI], force(o));
			outI++;
		}
	}
	freeElements(alloc, res[outI .. $]);
	return small!Out(res[0 .. outI]);
}

@system Out[] mapWithResultPointer(Out, In)(
	ref Alloc alloc,
	scope In[] a,
	in Out delegate(In*, Out*) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.length);
	foreach (size_t i; 0 .. a.length)
		initMemory(&res[i], cb(&a[i], &res[i]));
	return res[0 .. a.length];
}

Out[] mapPointersWithIndex(Out, In)(
	ref Alloc alloc,
	In[] a,
	in Out delegate(size_t, In*) @safe @nogc pure nothrow cb,
) =>
	mapPointers!(Out, In)(alloc, a, (In* x) @trusted => cb(x - a.ptr, x));

T[] concatenate(T)(ref Alloc alloc, T[] a, T[] b) =>
	isEmpty(a)
		? b
		: isEmpty(b)
		? a
		: concatenateIn!T(alloc, a, b);

@trusted immutable(T[]) concatenateIn(T)(ref Alloc alloc, in T[] a, in T[] b) {
	T[] res = allocateElements!T(alloc, a.length + b.length);
	copyToFrom!T(res[0 .. a.length], a);
	copyToFrom!T(res[a.length .. $], b);
	return castImmutable(res);
}

SmallArray!T append(T)(scope ref Alloc alloc, in T[] a, T b) =>
	small!T(concatenateIn!T(alloc, a, [b]));

SmallArray!T prepend(T)(scope ref Alloc alloc, T a, in T[] b) =>
	small!T(concatenateIn!T(alloc, [a], b));

bool zipEvery(T, U)(in T[] a, in U[] b, in bool delegate(ref const T, ref const U) @safe @nogc pure nothrow cb) {
	assert(sizeEq(a, b));
	foreach (size_t i; 0 .. a.length)
		if (!cb(a[i], b[i]))
			return false;
	return true;
}

void zip(T, U)(scope T[] a, scope U[] b, in void delegate(ref T, ref U) @safe @nogc pure nothrow cb) {
	assert(sizeEq(a, b));
	foreach (size_t i; 0 .. a.length)
		cb(a[i], b[i]);
}

void zipIfSizeEq(T, U)(in T[] a, in U[] b, in void delegate(ref T, ref U) @safe @nogc pure nothrow cb) {
	if (sizeEq(a, b))
		zip(a, b, cb);
}

void zipIfSizeEqFilterFirst(T, U)(
	in T[] a,
	in U[] b,
	in bool delegate(in T) @safe @nogc pure nothrow cbFilter,
	in void delegate(in T, in U) @safe @nogc pure nothrow cbZip,
) {
	size_t count = 0;
	foreach (ref const T x; a) {
		if (cbFilter(x))
			count++;
	}
	if (count == b.length) {
		size_t i = 0;
		foreach (ref const T x; a) {
			if (cbFilter(x)) {
				cbZip(x, b[i]);
				i++;
			}
		}
		assert(i == count);
	}
}

void zipPointers(T, U)(T[] a, U[] b, in void delegate(T*, U*) @safe @nogc pure nothrow cb) {
	assert(sizeEq(a, b));
	foreach (size_t i; 0 .. a.length)
		cb(&a[i], &b[i]);
}

void zipPtrFirst(T, U)(T[] a, scope U[] b, in void delegate(T*, ref U) @safe @nogc pure nothrow cb) {
	assert(sizeEq(a, b));
	foreach (size_t i; 0 .. a.length)
		cb(&a[i], b[i]);
}

SmallArray!Out mapZip(Out, In0, In1)(
	ref Alloc alloc,
	in SmallArray!In0 in0,
	in SmallArray!In1 in1,
	in Out delegate(ref In0, ref In1) @safe @nogc pure nothrow cb,
) {
	assert(sizeEq(in0, in1));
	return small!Out(makeArray!Out(alloc, in0.length, (size_t i) =>
		cb(in0[i], in1[i])));
}

@trusted Out[] mapZipWithIndex(Out, In0, In1)(
	ref Alloc alloc,
	scope In0[] in0,
	scope In1[] in1,
	in Out delegate(size_t, ref In0, ref In1) @safe @nogc pure nothrow cb,
) {
	assert(sizeEq(in0, in1));
	return makeArray(alloc, in0.length, (size_t i) =>
		cb(i, in0[i], in1[i]));
}

@trusted SmallArray!Out mapZipPtrFirst(Out, In0, In1)(
	ref Alloc alloc,
	In0[] in0,
	in In1[] in1,
	in Out delegate(In0*, In1) @safe @nogc pure nothrow cb,
) {
	assert(sizeEq(in0, in1));
	return small!Out(makeArray(alloc, in0.length, (size_t i) =>
		cb(&in0[i], in1[i])));
}

bool arraysCorrespond(T, U)(
	in T[] a,
	in U[] b,
	in bool delegate(ref const T, ref const U) @safe @nogc pure nothrow cb,
) =>
	sizeEq(a, b) && zipEvery!(T, U)(a, b, cb);

bool arraysIdentical(T)(in T[] a, in T[] b) =>
	a.ptr == b.ptr && a.length == b.length;

bool arraysEqual(T)(in T[] a, in T[] b) =>
	arraysCorrespond!(T, T)(a, b, (ref const T x, ref const T y) => x == y);

T applyNTimes(T)(T start, size_t times, in T delegate(T) @safe @nogc pure nothrow cb) =>
	times == 0 ? start : applyNTimes(cb(start), times - 1, cb);

T foldRange(T)(
	size_t length,
	in T delegate(size_t) @safe @nogc pure nothrow cbGet,
	in T delegate(T, T) @safe @nogc pure nothrow cbCombine,
) {
	assert(length != 0);
	T recur(T acc, size_t i) =>
		i == length ? acc : cbCombine(acc, cbGet(i));
	return recur(cbGet(0), 1);
}

T fold(T, U)(T start, in U[] arr, in T delegate(T, in U) @safe @nogc pure nothrow cb) =>
	isEmpty(arr)
		? start
		: fold!(T, U)(cb(start, arr[0]), arr[1 .. $], cb);

T foldWithIndex(T, U)(T start, in U[] arr, in T delegate(T, size_t, ref U) @safe @nogc pure nothrow cb) {
	T recur(T acc, size_t index) {
		return index == arr.length
			? acc
			: recur(cb(acc, index, arr[index]), index + 1);
	}
	return recur(start, 0);
}

T foldReverse(T, U)(T start, in U[] arr, in T delegate(T, ref U) @safe @nogc pure nothrow cb) =>
	isEmpty(arr)
		? start
		: foldReverse!(T, U)(cb(start, arr[$ - 1]), arr[0 .. $ - 1], cb);

T foldReverseWithIndex(T, U)(T start, in U[] arr, in T delegate(T, size_t, ref U) @safe @nogc pure nothrow cb) =>
	isEmpty(arr)
		? start
		: foldReverseWithIndex!(T, U)(cb(start, arr.length - 1, arr[$ - 1]), arr[0 .. $ - 1], cb);

Out mapReduce(Out, In)(
	in In[] in_,
	in Out delegate(ref In) @safe @nogc pure nothrow cbMap,
	in Out delegate(Out, Out) @safe @nogc pure nothrow cbReduce,
) {
	assert(!isEmpty(in_));
	Out recur(Out acc, size_t i) =>
		i == in_.length ? acc : recur(cbReduce(acc, cbMap(in_[i])), i + 1);
	return recur(cbMap(in_[0]), 1);
}

Out mapReduceReverse(Out, In)(
	in In[] in_,
	in Out delegate(ref In) @safe @nogc pure nothrow cbMap,
	in Out delegate(Out, Out) @safe @nogc pure nothrow cbReduce,
) {
	assert(!isEmpty(in_));
	Out recur(Out acc, size_t i) =>
		i == 0 ? acc : recur(cbReduce(acc, cbMap(in_[i - 1])), i - 1);
	return recur(cbMap(in_[$ - 1]), in_.length - 1);
}

N maxBy(N, T)(N start, in T[] a, in N delegate(in T) @safe @nogc pure nothrow cb) =>
	fold!(N, T)(start, a, (N curMax, in T x) => .max(curMax, cb(x)));

size_t sum(T)(in T[] a, in size_t delegate(in T) @safe @nogc pure nothrow cb) =>
	fold!(size_t, T)(0, a, (size_t l, in T t) =>
		size_t(l + cb(t)));

void eachPair(T)(in T[] a, in void delegate(in T, in T) @safe @nogc pure nothrow cb) {
	foreach (size_t i; 0 .. a.length)
		foreach (size_t j; i + 1 .. a.length)
			cb(a[i], a[j]);
}

void reverseInPlace(T)(scope T[] a) {
	foreach (size_t i; 0 .. a.length / 2) {
		size_t j = a.length - 1 - i;
		T temp = a[i];
		overwriteMemory(&a[i], a[j]);
		overwriteMemory(&a[j], temp);
	}
}
