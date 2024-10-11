module util.alloc.stackAlloc;

@safe @nogc nothrow:

import util.col.array : arrayOfRange, endPtr;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish;
import util.memory : initMemory, overwriteMemory;
import util.opt : force, has, none, Opt, some;
import util.util : ptrTrustMe, roundUp;

private ulong[0x20000] stackArrayStorage = void;
private bool isBuildingStackArray;
private ulong* stackArrayNext;

void ensureStackAllocInitialized() {
	if (stackArrayNext == null) stackArrayNext = stackArrayStorage.ptr;
}

@system pure Out withStackArrayUninitialized(Out, Elem)(
	size_t size,
	in Out delegate(scope Elem[]) @safe @nogc pure nothrow cb,
) =>
	(cast(Out function(
		size_t,
		Out delegate(scope Elem[]) @safe @nogc pure nothrow,
	) @safe @nogc pure nothrow) &withStackArrayUninitialized_impure!(Out, Elem))(size, cb);
@system Out withStackArrayUninitialized_impure(Out, Elem)(
	size_t size,
	in Out delegate(scope Elem[]) @safe @nogc nothrow cb,
) {
	scope Elem[] array = pushStackArrayUninitialized_impure!Elem(size);
	scope(exit) stackArrayNext = cast(ulong*) array.ptr;
	return cb(array);
}

private @system Elem[] pushStackArrayUninitialized(Elem)(size_t size) =>
	(cast(Elem[] function(size_t) @system @nogc pure nothrow) &pushStackArrayUninitialized_impure!Elem)(size);
// Unlike 'withStackArray', this does not automatically restore. But it will happen when doing an outer restore.
private @system Elem[] pushStackArrayUninitialized_impure(Elem)(size_t size) {
	assert(!isBuildingStackArray);
	assert((cast(ulong) stackArrayNext) % ulong.sizeof == 0);
	Elem* begin = cast(Elem*) stackArrayNext;
	stackArrayNext = roundUpToWord(begin + size);
	assert(stackArrayNext <= endPtr(stackArrayStorage));
	assert((cast(ulong) stackArrayNext) % ulong.sizeof == 0);

	return begin[0 .. size];
}

private @system pure ulong* roundUpToWord(Elem)(Elem* a) {
	static if (Elem.sizeof % ulong.sizeof == 0) {
		assert((cast(ulong) a) % ulong.sizeof == 0);
		return cast(ulong*) a;
	} else
		return cast(ulong*) roundUp(cast(ulong) a, ulong.sizeof);
}

@trusted pure Out withRestoreStack(Out)(in Out delegate() @safe @nogc pure nothrow cb) =>
	(cast(Out function(
		in Out delegate() @safe @nogc pure nothrow
	) @safe @nogc pure nothrow) &withRestoreStack_impure!Out)(cb);
private Out withRestoreStack_impure(Out)(in Out delegate() @safe @nogc pure nothrow cb) {
	ulong* begin = stackArrayNext;
	scope(exit) stackArrayNext = begin;
	return cb();
}

@trusted Elem[] pushStackArray(Elem)(size_t size, in Elem delegate(size_t) @safe @nogc pure nothrow cb) {
	scope Elem[] res = pushStackArrayUninitialized!Elem(size);
	foreach (size_t i; 0 .. size)
		initMemory(&res[i], cb(i));
	return res;
}

// WARN: Since the size is unknown until 'cbBuild' finishes,
// you can't do anything else with the stack during it.
@trusted pure Out withBuildStackArray(Out, Elem)(
	in void delegate(ref StackArrayBuilder!Elem) @safe @nogc pure nothrow cbBuild,
	in Out delegate(scope Elem[]) @safe @nogc pure nothrow cb,
) =>
	(cast(Out function(
		in void delegate(ref StackArrayBuilder!Elem) @safe @nogc pure nothrow,
		in Out delegate(scope Elem[]) @safe @nogc pure nothrow,
	) @safe @nogc pure nothrow) &withBuildStackArrayImpure!(Out, Elem))(cbBuild, cb);

@trusted Out withExactStackArray(Out, Elem)(
	size_t size,
	in Out delegate(scope ref ExactSizeArrayBuilder!Elem) @safe @nogc pure nothrow cb,
) =>
	withStackArrayUninitialized!(Out, Elem)(size, (scope Elem[] storage) @trusted {
		ExactSizeArrayBuilder!Elem builder = ExactSizeArrayBuilder!Elem(storage, storage.ptr);
		return cb(builder);
	});
@trusted Out withExactStackArrayImpure(Out, Elem)(
	size_t size,
	in Out delegate(scope ref ExactSizeArrayBuilder!Elem) @safe @nogc nothrow cb,
) =>
	withStackArrayUninitialized_impure!(Out, Elem)(size, (scope Elem[] storage) @trusted {
		ExactSizeArrayBuilder!Elem builder = ExactSizeArrayBuilder!Elem(storage, storage.ptr);
		return cb(builder);
	});

@trusted Out withBuildStackArrayImpure(Out, Elem)(
	in void delegate(ref StackArrayBuilder!Elem) @safe @nogc pure nothrow cbBuild,
	in Out delegate(scope Elem[]) @safe @nogc nothrow cb,
) {
	assert((cast(ulong) stackArrayNext) % ulong.sizeof == 0);

	assert(!isBuildingStackArray);
	isBuildingStackArray = true;
	Elem* begin = cast(Elem*) stackArrayNext;
	StackArrayBuilder!Elem builder = StackArrayBuilder!Elem(begin, begin);
	cbBuild(builder);
	isBuildingStackArray = false;
	stackArrayNext = roundUpToWord(builder.cur);

	scope(exit) stackArrayNext = cast(ulong*) begin;
	return cb(arrayOfRange(begin, builder.cur));
}

struct StackArrayBuilder(T) {
	@safe @nogc pure nothrow:

	private T* begin;
	private T* cur;

	@trusted void opOpAssign(string op : "~")(T value) {
		debug assert(cast(ulong*) (cur + 1) <= endPtr(stackArrayStorage));
		initMemory(cur, value);
		cur++;
	}
	@trusted void opOpAssign(string op : "~")(in T[] values) {
		foreach (T value; values)
			this ~= value;
	}

	size_t sizeSoFar() =>
		cur - begin;

	@system void pop() {
		assert(cur > begin);
		cur--;
	}

	@trusted T[] asTemporaryArray() =>
		arrayOfRange(begin, cur);

	@trusted void insertAt()(size_t index, T value) {
		assert(index <= sizeSoFar);
		cur++;
		foreach_reverse (size_t i; index .. sizeSoFar)
			overwriteMemory(&begin[i + 1], begin[i]);
		initMemory(&begin[index], value);
	}
}

Out withBuild2StackArrays(Out, Elem)(
	in void delegate(scope ref TwoStackArraysBuilder!Elem) @safe @nogc pure nothrow cbBuild,
	in Out delegate(in Elem[], in Elem[]) @safe @nogc pure nothrow cb,
) {
	size_t nFirst;
	return withBuildStackArray!(Out, Elem)(
		(ref StackArrayBuilder!Elem inner) {
			TwoStackArraysBuilder!Elem out_ = TwoStackArraysBuilder!Elem(ptrTrustMe(inner));
			cbBuild(out_);
			nFirst = out_.nFirst;
		},
		(scope Elem[] res) =>
			cb(res[0 .. nFirst], res[nFirst .. $]));
}

struct TwoStackArraysBuilder(T) {
	StackArrayBuilder!T* inner;
	size_t nFirst;

	void writeFirst(T value) {
		inner.insertAt(nFirst, value);
		nFirst++;
	}

	void writeSecond(T value) {
		(*inner) ~= value;
	}
}

@trusted pure Out withMaxStackArray(Out, Elem)(
	size_t maxSize,
	in Out delegate(scope ref MaxStackArray!Elem) @safe @nogc pure nothrow cb,
) =>
	withStackArrayUninitialized!(Out, Elem)(maxSize, (scope Elem[] storage) @trusted {
		MaxStackArray!Elem array = MaxStackArray!Elem(storage.ptr, storage.ptr, endPtr(storage));
		return cb(array);
	});

struct MaxStackArray(T) {
	@safe @nogc pure nothrow:
	T* begin;
	T* cur;
	T* end;

	@disable this(ref const MaxStackArray!T);

	MaxStackArray!T move() {
		scope(exit) {
			begin = null;
			cur = null;
			end = null;
		}
		return MaxStackArray!T(begin, cur, end);
	}

	@trusted void opOpAssign(string op : "~")(T value) {
		initMemory(cur, value);
		cur++;
		assert(cur <= end);
	}
	void opOpAssign(string op : "~")(scope T[] values) {
		foreach (T value; values)
			this ~= value;
	}

	bool isEmpty() scope const =>
		cur == begin;

	bool isFull() scope const =>
		cur == end;

	@trusted void mustPop() {
		assert(cur > begin);
		cur--;
	}

	@trusted T[] soFar() =>
		arrayOfRange(begin, cur);

	T[] finish() =>
		soFar;
}


@trusted pure Out withStackArray(Out, Elem)(
	size_t size,
	in Elem delegate(size_t) @safe @nogc pure nothrow init,
	in Out delegate(scope Elem[]) @safe @nogc pure nothrow cb,
) =>
	withStackArrayUninitialized!(Out, Elem)(size, (scope Elem[] xs) {
		foreach (size_t i, ref Elem x; xs)
			initMemory(&x, init(i));
		return cb(xs);
	});

pure Out withMapToStackArray(Out, Elem, InElem)(
	scope InElem[] in_,
	in Elem delegate(ref InElem) @safe @nogc pure nothrow cbMap,
	in Out delegate(scope Elem[]) @safe @nogc pure nothrow cb,
) =>
	withStackArray!(Out, Elem)(in_.length, (size_t i) => cbMap(in_[i]), cb);

pure Opt!Out withMapOrNoneToStackArray(Out, Elem, InElem)(
	in InElem[] in_,
	in Opt!Elem delegate(ref const InElem) @safe @nogc pure nothrow cbMap,
	in Out delegate(scope Elem[]) @safe @nogc pure nothrow cbOk,
) =>
	.withMapOrNoneToStackArray!(Opt!Out, Elem, InElem)(in_, cbMap, (scope Elem[] xs) => some(cbOk(xs)), () => none!Out);

pure Out withMapOrNoneToStackArray(Out, Elem, InElem)(
	in InElem[] in_,
	in Opt!Elem delegate(ref const InElem) @safe @nogc pure nothrow cbMap,
	in Out delegate(scope Elem[]) @safe @nogc pure nothrow cbOk,
	in Out delegate() @safe @nogc pure nothrow cbFail,
) =>
	withExactStackArray!(Out, Elem)(in_.length, (scope ref ExactSizeArrayBuilder!Elem elems) {
		foreach (ref const InElem x; in_) {
			Opt!Elem opt = cbMap(x);
			if (has(opt))
				elems ~= force(opt);
			else
				return cbFail();
		}
		return cbOk(finish(elems));
	});

Out withConcatImpure(Out, Elem)(in Elem[] a, in Elem[] b, in Out delegate(in Elem[]) @safe @nogc nothrow cb) =>
	withExactStackArrayImpure!(Out, Elem)(a.length + b.length, (scope ref ExactSizeArrayBuilder!Elem elems) {
		foreach (Elem x; a)
			elems ~= x;
		foreach (Elem x; b)
			elems ~= x;
		return cb(finish(elems));
	});
