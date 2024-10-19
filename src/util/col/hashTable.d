module util.col.hashTable;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc, allocateElements, freeElements;
import util.alloc.stackAlloc : withExactStackArray;
import util.col.array : arrayOfRange, endPtr, fillArray, isEmpty, map;
import util.comparison : Comparison;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish;
import util.col.sortUtil : sortInPlace;
import util.hash : getHash;
import util.memory : initMemory, overwriteMemory;
import util.opt : ConstOpt, force, has, MutOpt, none, noneMut, Opt, some, someConst, someMut;
import util.string : SmallString, stringsEqual;

alias HashTable(T, K, alias getKey) = immutable MutHashTable!(T, K, getKey);

// Intended for implementing other collections. Don't use directly.
// 'K' is be a subset of 'T' used for comparisons.
struct MutHashTable(T, K, alias getKey) {
	@safe @nogc pure nothrow:

	private:
	size_t size_;
	MutOpt!T[] values;

	// TODO: @disable this(ref const MutHashTable);

	public:
	Opt!T opIndex(in K key) immutable {
		Opt!size_t i = getIndex(this, key);
		return has(i) ? some!T(force(values[force(i)])) : none!T;
	}
	ConstOpt!T opIndex(in K key) const {
		Opt!size_t i = getIndex(this, key);
		return has(i) ? someConst!T(force(values[force(i)])) : noneMut!T;
	}
	MutOpt!T opIndex(in K key) {
		Opt!size_t i = getIndex(this, key);
		return has(i) ? someMut!T(force(values[force(i)])) : noneMut!T;
	}

	bool opBinaryRight(string op)(in K key) scope const if (op == "in") =>
		has(getIndex(this, key));

	int opApply(in int delegate(ref immutable T) @safe @nogc pure nothrow cb) scope immutable {
		foreach (ref immutable MutOpt!T value; values)
			if (has(value)) {
				int res = cb(force(value));
				if (res != 0)
					return res;
			}
		return 0;
	}
	int opApply(in int delegate(ref const T) @safe @nogc pure nothrow cb) scope const {
		foreach (ref const MutOpt!T value; values)
			if (has(value)) {
				int res = cb(force(value));
				if (res != 0)
					return res;
			}
		return 0;
	}
	int opApply(in int delegate(ref T) @safe @nogc pure nothrow cb) scope {
		foreach (ref MutOpt!T value; values)
			if (has(value)) {
				int res = cb(force(value));
				if (res != 0)
					return res;
			}
		return 0;
	}
}

@trusted HashTable!(T*, K, getKey) makeHashTable(T, K, alias getKey)(
	ref Alloc alloc,
	T[] values,
	in void delegate(T*) @safe @nogc pure nothrow cbDuplicate,
) {
	MutHashTable!(T*, K, getKey) res;
	foreach (ref T x; values)
		if (!mayAdd(alloc, res, &x))
			cbDuplicate(&x);
	return cast(immutable) res;
}

Opt!(T*) getPointer(T, K, alias getKey)(ref HashTable!(T, K, getKey) a, in K key) {
	Opt!size_t i = getIndex(a, key);
	return has(i) ? some(&force(a.values[force(i)])) : none!(T*);
}

bool isEmpty(T, K, alias getKey)(in MutHashTable!(T, K, getKey) a) =>
	size(a) == 0;

size_t size(T, K, alias getKey)(in MutHashTable!(T, K, getKey) a) =>
	a.size_;

void clear(T, K, alias getKey)(scope ref MutHashTable!(T, K, getKey) a) {
	foreach (ref MutOpt!T value; a.values)
		overwriteMemory(&value, noneMut!T);
	a.size_ = 0;
}

ref inout(T) mustGet(T, K, alias getKey)(ref inout MutHashTable!(T, K, getKey) a, in K key) =>
	force(a.values[mustGetIndex(a, key)]);

struct ValueAndDidAdd(T) {
	T value;
	bool didAdd;
}

ValueAndDidAdd!T getOrAddAndDidAdd(T, K, alias getKey)(
	ref Alloc alloc,
	ref MutHashTable!(T, K, getKey) a,
	in K key,
	in T delegate() @safe @nogc pure nothrow cb,
) {
	size_t sizeBefore = a.size_;
	T res = getOrAdd(alloc, a, key, cb);
	return ValueAndDidAdd!T(res, a.size_ != sizeBefore);
}

bool mayAdd(T, K, alias getKey)(ref Alloc alloc, scope ref MutHashTable!(T, K, getKey) a, T value) =>
	getOrAddAndDidAdd(alloc, a, getKey(value), () => value).didAdd;

ref T mustAdd(T, K, alias getKey)(ref Alloc alloc, return scope ref MutHashTable!(T, K, getKey) a, T value) {
	if (shouldExpandBeforeAdd(a))
		doExpand(alloc, a);
	assert(a.size_ < a.values.length);
	a.size_++;
	return mustAddToHashTableNoAlloc!(T, K, getKey)(a.values, value);
}

// Exported for use by 'MutMaxSet'
ref T mustAddToHashTableNoAlloc(T, K, alias getKey)(MutOpt!T[] values, T value) {
	K key = getKey(value);
	size_t i = getHash!K(key).hashCode % values.length;
	while (true) {
		if (!has(values[i])) {
			overwriteMemory(&values[i], someMut!T(value));
			return force(values[i]);
		} else {
			assert(!eq!K(key, getKey(force(values[i]))), "mustAddToHashTable but key is already in table");
			i = nextI!T(values, i);
		}
	}
}

ref T getOrAdd(T, K, alias getKey)(
	ref Alloc alloc,
	return scope ref MutHashTable!(T, K, getKey) a,
	in K key,
	in T delegate() @safe @nogc pure nothrow cb,
) {
	Opt!size_t i = getIndex(a, key);
	if (has(i))
		return force(a.values[force(i)]);
	else {
		T value = cb();
		assert(getKey(value) == key);
		return mustAdd(alloc, a, value);
	}
}

ref T addOrChange(T, K, alias getKey)(
	ref Alloc alloc,
	ref MutHashTable!(T, K, getKey) a,
	in K key,
	in T delegate() @safe @nogc pure nothrow cbAdd,
	in void delegate(ref T) @safe @nogc pure nothrow cbChange,
) {
	Opt!size_t i = getIndex(a, key);
	if (has(i)) {
		cbChange(force(a.values[force(i)]));
		assert(getKey(force(a.values[force(i)])) == key);
		return force(a.values[force(i)]);
	} else {
		T value = cbAdd();
		assert(getKey(value) == key);
		return mustAdd(alloc, a, value);
	}
}

ref T insertOrUpdate(T, K, alias getKey)(
	ref Alloc alloc,
	ref MutHashTable!(T, K, getKey) a,
	in K key,
	in T delegate() @safe @nogc pure nothrow cbInsert,
	in T delegate(ref T) @safe @nogc pure nothrow cbUpdate,
) =>
	addOrChange(alloc, a, key, cbInsert, (ref T x) {
		overwriteMemory(&x, cbUpdate(x));
	});

MutOpt!T mayDelete(T, K, alias getKey)(ref MutHashTable!(T, K, getKey) a, in K key) {
	MutOpt!T res = mayDeleteFromHashTable!(T, K, getKey)(a.values, key);
	if (has(res))
		a.size_--;
	return res;
}

void mayDeleteValue(T, K, alias getKey)(ref MutHashTable!(T, K, getKey) a, T value) {
	mayDelete(a, getKey(value));
}

MutOpt!T mayDeleteFromHashTable(T, K, alias getKey)(scope MutOpt!T[] values, in K key) {
	Opt!size_t index = getIndexInHashTable!(T, K, getKey)(values, key);
	return has(index) ? someMut!T(deleteFromHashTableAtIndex!(T, K, getKey)(values, force(index))) : noneMut!T;
}

T mustDelete(T, K, alias getKey)(ref MutHashTable!(T, K, getKey) a, in K key) {
	a.size_--;
	return mustDeleteFromHashTable!(T, K, getKey)(a.values, key);
}

private T mustDeleteFromHashTable(T, K, alias getKey)(scope MutOpt!T[] values, in K key) {
	Opt!size_t index = getIndexInHashTable!(T, K, getKey)(values, key);
	return deleteFromHashTableAtIndex!(T, K, getKey)(values, force(index));
}

HashTable!(T, K, getKey) buildHashTable(T, K, alias getKey)(
	in void delegate(scope ref MutHashTable!(T, K, getKey)) @safe @nogc pure nothrow cb,
) {
	MutHashTable!(T, K, getKey) res;
	cb(res);
	return moveToImmutable(res);
}

@trusted HashTable!(T, K, getKey) moveToImmutable(T, K, alias getKey)(ref MutHashTable!(T, K, getKey) a) {
	HashTable!(T, K, getKey) res = HashTable!(T, K, getKey)(a.size_, cast(immutable) a.values);
	a.size_ = 0;
	a.values = [];
	return res;
}

@trusted T[] moveToArray(T, K, alias getKey)(ref Alloc alloc, ref MutHashTable!(T, K, getKey) a) {
	// Cleverly reuse the space in 'values'
	T* out_ = cast(T*) a.values;
	foreach (ref MutOpt!T x; a.values) {
		if (has(x)) {
			initMemory(out_, force(x));
			out_++;
		}
	}
	assert(out_ <= cast(T*) endPtr(a.values));
	T[] res = arrayOfRange(cast(T*) a.values, out_);
	T[] remaining = arrayOfRange(out_, cast(T*) endPtr(a.values));
	freeElements(alloc, remaining);
	a.size_ = 0;
	a.values = [];
	return res;
}

immutable(T[]) hashTableToArray(T, K, alias getKey)(ref Alloc alloc, in MutHashTable!(T, K, getKey) a) =>
	hashTableMapToArray!(immutable T, T, K, getKey)(alloc, a, (ref const T x) => x);

@trusted Out[] hashTableMapToArray(Out, T, K, alias getKey)(
	ref Alloc alloc,
	scope ref immutable HashTable!(T, K, getKey) a,
	in Out delegate(ref immutable T) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.size_);
	size_t i = 0;
	foreach (ref immutable T x; a) {
		initMemory(&res[i], cb(x));
		i++;
	}
	assert(i == res.length);
	return res;
}
@trusted Out[] hashTableMapToArray(Out, T, K, alias getKey)(
	ref Alloc alloc,
	scope ref const MutHashTable!(T, K, getKey) a,
	in Out delegate(ref const T) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.size_);
	size_t i = 0;
	foreach (ref const T x; a) {
		initMemory(&res[i], cb(x));
		i++;
	}
	assert(i == res.length);
	return res;
}
@trusted Out[] hashTableMapToArray(Out, T, K, alias getKey)(
	ref Alloc alloc,
	scope ref MutHashTable!(T, K, getKey) a,
	in Out delegate(ref T) @safe @nogc pure nothrow cb,
) {
	Out[] res = allocateElements!Out(alloc, a.size_);
	size_t i = 0;
	foreach (ref T x; a) {
		initMemory(&res[i], cb(x));
		i++;
	}
	assert(i == res.length);
	return res;
}

HashTable!(Out, K, getKeyOut) mapPreservingKeys(Out, alias getKeyOut, In, K, alias getKey)(
	ref Alloc alloc,
	scope ref MutHashTable!(In, K, getKey) a,
	in Out delegate(ref In) @safe @nogc pure nothrow cb,
) {
	immutable MutOpt!Out[] outValues = map!(immutable MutOpt!Out, MutOpt!In)(alloc, a.values, (ref MutOpt!In value) {
		if (has(value)) {
			Out out_ = cb(force(value));
			assert(eq!K(getKeyOut(out_), getKey(force(value))));
			return cast(immutable) someMut!Out(out_);
		} else
			return cast(immutable) noneMut!Out;
	});
	return HashTable!(Out, K, getKeyOut)(a.size_, outValues);
}

@trusted HashTable!(Out, K, getKeyOut) mapAndMovePreservingKeys(Out, alias getKeyOut, In, K, alias getKey)(
	ref Alloc alloc,
	ref MutHashTable!(In, K, getKey) a,
	in Out delegate(ref In) @safe @nogc pure nothrow cb,
) {
	static assert(Out.sizeof <= In.sizeof);
	MutOpt!Out* out_ = cast(MutOpt!Out*) a.values.ptr;
	foreach (MutOpt!In x; a.values) {
		initMemory(out_, has(x) ? someMut!Out(cb(force(x))) : noneMut!Out);
		out_++;
	}
	HashTable!(Out, K, getKeyOut) res = HashTable!(Out, K, getKeyOut)(
		a.size_,
		cast(immutable) arrayOfRange!(MutOpt!Out)(cast(MutOpt!Out*) a.values.ptr, out_));
	MutOpt!In[] remaining = arrayOfRange(cast(MutOpt!In*) out_, endPtr(a.values));
	freeElements(alloc, remaining);
	a.size_ = 0;
	a.values = [];
	return res;
}

bool existsInHashTable(T, K, alias getKey)(
	in MutHashTable!(T, K, getKey) a,
	in bool delegate(in T) @safe @nogc pure nothrow cb,
) {
	foreach (ref const T x; a)
		if (cb(x))
			return true;
	return false;
}

Out withSortedKeys(Out, T, K, alias getKey)(
	in MutHashTable!(T, K, getKey) a,
	in Comparison delegate(in K, in K) @safe @nogc pure nothrow cbCompare,
	in Out delegate(in K[]) @safe @nogc pure nothrow cb,
) =>
	withExactStackArray(size(a), (scope ref ExactSizeArrayBuilder!K builder) {
		foreach (ref const T value; a)
			builder ~= getKey(value);
		K[] keys = finish(builder);
		sortInPlace!(K, cbCompare)(keys);
		return cb(keys);
	});

private:

string typeName(T)() {
	static if (is(T == P*, P)) {
		static immutable string res = typeName!P ~ "*";
		return res;
	} else static if (is(T == immutable void))
		return "void";
	else static if (is(T == immutable string))
		return "string";
	else static if (is(T == ulong))
		return "ulong";
	else
		return __traits(identifier, T);
}

size_t mustGetIndex(T, K, alias getKey)(in MutHashTable!(T, K, getKey) a, in K key) {
	Opt!size_t res = getIndex(a, key);
	return force(res);
}

Opt!size_t getIndex(T, K, alias getKey)(in MutHashTable!(T, K, getKey) a, in K key) =>
	getIndexInHashTable!(T, K, getKey)(a.values, key);

// For use by 'mutMaxSet.d'
public Opt!size_t getIndexInHashTable(T, K, alias getKey)(in MutOpt!T[] values, in K key) {
	if (isEmpty(values))
		return none!size_t;

	size_t startI = getHash!K(key).hashCode % values.length;
	size_t i = startI;
	while (true) {
		if (!has(values[i]))
			return none!size_t;
		else if (eq!K(key, getKey(force(values[i]))))
			return some(i);
		else {
			i = nextI!T(values, i);
			if (i == startI)
				return none!size_t;
		}
	}
}

bool shouldExpandBeforeAdd(T, K, alias getKey)(in MutHashTable!(T, K, getKey) a) =>
	// For small maps, only expand if there is no empty space.
	// For large maps, aim to be 3/4 full.
	a.size_ <= 8
		? a.size_ == a.values.length
		: a.size_ * 4 / 3 >= a.values.length;

@trusted void doExpand(T, K, alias getKey)(ref Alloc alloc, scope ref MutHashTable!(T, K, getKey) a) {
	immutable size_t newCapacity = a.values.length < 2 ? 2 : a.values.length * 2;
	MutHashTable!(T, K, getKey) bigger = MutHashTable!(T, K, getKey)(
		0, fillArray!(MutOpt!T)(alloc, newCapacity, noneMut!T));
	foreach (ref T x; a)
		mustAdd(alloc, bigger, x);
	freeElements(alloc, a.values);
	a.values = bigger.values;
}

// WARN: To keep the implementation simple, it's possible that this will call 'cb' twice on the same value.
public void deleteWhere(T, K, alias getKey)(
	scope ref MutHashTable!(T, K, getKey) a,
	in bool delegate(in T) @safe @nogc pure nothrow cb,
) {
	size_t i = 0;
	while (i != a.values.length) {
		MutOpt!T* value = &a.values[i];
		if (has(*value) && cb(force(*value))) {
			deleteFromHashTableAtIndex!(T, K, getKey)(a.values, i);
			a.size_--;
			// This may move values from later to here. So repeat again with the same 'i'.
		} else {
			i++;
		}
	}
}

public T deleteFromHashTableAtIndex(T, K, alias getKey)(scope MutOpt!T[] values, size_t i) {
	T res = force(values[i]);

	// When there is a hole, move values closer to where they should be.
	size_t holeI = i;
	overwriteMemory(&values[holeI], noneMut!T);
	size_t fromI = nextI!T(values, i);
	while (has(values[fromI])) {
		size_t desiredI = getHash!K(getKey(force(values[fromI]))).hashCode % values.length;
		if (walkDistance!T(values, desiredI, holeI) < walkDistance!T(values, desiredI, fromI)) {
			overwriteMemory(&values[holeI], values[fromI]);
			overwriteMemory(&values[fromI], noneMut!T);
			holeI = fromI;
		}
		fromI = nextI!T(values, fromI);
	}

	return res;
}

size_t nextI(T)(in MutOpt!T[] values, size_t i) {
	size_t res = i + 1;
	return res == values.length ? 0 : res;
}

size_t walkDistance(T)(in MutOpt!T[] values, size_t i0, size_t i1) =>
	i0 <= i1
		? i1 - i0
		: values.length + i1 - i0;

bool eq(K)(in K a, in K b) {
	static if (is(K == string) || is(K == SmallString))
		return stringsEqual(a, b);
	else
		return a == b;
}
