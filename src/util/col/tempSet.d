module util.col.tempSet;

@safe @nogc nothrow:

import util.alloc.stackAlloc : withStackArrayUninitialized, withStackArrayUninitialized_impure;
import util.col.array : contains;
import util.memory : initMemory;

@trusted Out withTempSetImpure(Out, Elem)(
	size_t maxSize,
	in Out delegate(scope ref TempSet!Elem) @safe @nogc nothrow cb,
) =>
	withStackArrayUninitialized_impure!(Out, Elem)(maxSize, (scope Elem[] storage) {
		TempSet!Elem set = TempSet!Elem(0, storage);
		return cb(set);
	});

pure:

struct TempSet(T) {
	@safe @nogc pure nothrow:
	private size_t size;
	private T[] storage;

	bool opBinaryRight(string op)(in T value) scope const if (op == "in") =>
		contains(storage[0 .. size], value);
}

bool tryAdd(T)(scope ref TempSet!T a, T value) {
	if (value in a)
		return false;
	else {
		mustAdd(a, value);
		return true;
	}
}

void mustAdd(T)(scope ref TempSet!T a, T value) {
	assert(value !in a);
	assert(a.size <= a.storage.length);
	initMemory(&a.storage[a.size], value);
	a.size++;
}

@trusted Out withTempSet(Out, Elem)(
	size_t maxSize,
	in Out delegate(scope ref TempSet!Elem) @safe @nogc pure nothrow cb,
) =>
	withStackArrayUninitialized!(Out, Elem)(maxSize, (scope Elem[] storage) {
		TempSet!Elem set = TempSet!Elem(0, storage);
		return cb(set);
	});

void eachUnique(Key, In)(
	in In[] xs,
	in Key delegate(in In) @safe @nogc pure nothrow cbKey,
	in void delegate(in Key) @safe @nogc pure nothrow cb,
) {
	withTempSet(xs.length, (scope ref TempSet!Key seen) {
		foreach (ref const In x; xs) {
			Key key = cbKey(x);
			if (tryAdd(seen, key)) {
				cb(key);
			}
		}
	});
}
