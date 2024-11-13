module util.col.mutArr;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc, allocateElements, freeElements;
import util.col.array : findIndex, map;
import util.memory : copyToFrom, initMemory;
import util.opt : optOrDefault;

struct MutArr(T) {
	@safe @nogc nothrow:

	private:
	T[] inner;
	size_t size_;

	public:
	@trusted ref inout(T) opIndex(immutable size_t index) return scope inout {
		assert(index < size_);
		return inner[index];
	}

	@trusted void opIndexAssign(T value, immutable size_t index) {
		assert(index < size_);
		initMemory!T(&inner[index], value);
	}

	size_t opDollar(size_t pos)() scope const {
		static assert(pos == 0);
		return size_;
	}

	int opApply(Cb)(in Cb cb) scope {
		foreach (ref T value; inner[0 .. size_]) {
			int res = cb(value);
			if (res != 0)
				return res;
		}
		return 0;
	}
}

MutArr!Out mapToMutArr(Out, In)(ref Alloc alloc, in In[] inputs, in Out delegate(ref In) @safe @nogc pure nothrow cb) =>
	MutArr!Out(map!(Out, In)(alloc, inputs, cb), inputs.length);

void clearAndDoNotFree(T)(ref MutArr!T a) {
	a.size_ = 0;
}

@trusted void clearAndFree(T)(ref Alloc alloc, ref MutArr!T a) {
	freeElements(alloc, a.inner);
	a.inner = [];
	a.size_ = 0;
}

immutable(size_t) mutArrSize(T)(ref const MutArr!T a) =>
	a.size_;

immutable(bool) mutArrIsEmpty(T)(ref const MutArr!T a) =>
	a.size_ == 0;

@system T* mutArrEnd(T)(ref MutArr!T a) =>
	a.inner.ptr + a.size_;

@trusted void push(T)(scope ref Alloc alloc, scope ref MutArr!T a, T value) {
	if (a.size_ == a.inner.length) {
		immutable size_t newCapacity = a.size_ == 0 ? 2 : a.size_ * 2;
		T[] newInner = allocateElements!T(alloc, newCapacity);
		copyToFrom!T(newInner[0 .. a.size_], a.inner);
		freeElements(alloc, a.inner);
		a.inner = newInner;
	}

	initMemory!T(&a.inner[a.size_], value);
	a.size_++;
	assert(a.size_ <= a.inner.length);
}

size_t findIndexOrPush(T)(
	ref Alloc alloc,
	scope ref MutArr!T a,
	T value
) =>
	findIndexOrPush!T(alloc, a, (in T x) => x == value, () => value, (ref T _) {});

size_t findIndexOrPush(T)(
	ref Alloc alloc,
	scope ref MutArr!T a,
	in bool delegate(in T) @safe @nogc pure nothrow cbSearch,
	in T delegate() @safe @nogc pure nothrow cbValue,
	in void delegate(ref T) @safe @nogc pure nothrow cbAfterPush,
) =>
	optOrDefault!size_t(findIndex!T(asTemporaryArray(a), cbSearch), () {
		size_t res = mutArrSize(a);
		T value = cbValue();
		assert(mutArrSize(a) == res);
		push(alloc, a, value);
		cbAfterPush(a[res]);
		return res;
	});

void pushAll(T)(ref Alloc alloc, ref MutArr!(immutable T) a, scope immutable T[] values) {
	foreach (ref immutable T value; values)
		push(alloc, a, value);
}

@trusted T mustPop(T)(ref MutArr!T a) {
	assert(a.size_ != 0);
	a.size_--;
	return a.inner[a.size_];
}

@trusted immutable(T[]) moveToArray(T)(ref Alloc alloc, scope ref MutArr!(immutable T) a) =>
	cast(immutable) moveToMutArray(alloc, a);
@trusted T[] moveToMutArray(T)(ref Alloc alloc, ref MutArr!T a) {
	T[] res = a.inner[0 .. a.size_];
	freeElements(alloc, a.inner[a.size_ .. $]);
	a.inner = [];
	a.size_ = 0;
	return res;
}

@trusted const(T[]) asTemporaryArray(T)(ref const MutArr!T a) =>
	a.inner[0 .. a.size_];

void filterUnordered(T)(ref MutArr!T a, in bool delegate(ref T) @safe @nogc pure nothrow pred) {
	size_t i = 0;
	while (i < mutArrSize(a)) {
		if (pred(a[i]))
			i++;
		else
			removeUnorderedAt(a, i);
	}
}

private void removeUnorderedAt(T)(ref MutArr!T a, size_t i) {
	assert(i < mutArrSize(a));
	T last = mustPop(a);
	if (i != mutArrSize(a))
		a[i] = last;
}


struct MutArrWithAlloc(T) {
	private:
	Alloc* alloc;
	MutArr!T inner;

	@disable this();
	public this(Alloc* a) {
		alloc = a;
	}
}
void push(T)(ref MutArrWithAlloc!T a, T value) {
	push(*a.alloc, a.inner, value);
}
T mustPop(T)(ref MutArrWithAlloc!T a) =>
	mustPop(a.inner);
bool mutArrIsEmpty(T)(in MutArrWithAlloc!T a) =>
	mutArrIsEmpty(a.inner);
