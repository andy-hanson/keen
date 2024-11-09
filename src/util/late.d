module util.late;

@safe @nogc pure nothrow:

import util.memory : initMemory;
import util.opt : force, has, MutOpt, Opt, none, some, someMut;

struct MutLate(T) {
	private MutOpt!T value_;
}

ref inout(T) lateGet(T)(ref inout MutLate!T a) =>
	force(a.value_);

void lateSet(T)(ref MutLate!T a, T value) {
	assert(!has(a.value_));
	a.value_ = someMut(value);
}

immutable struct Late(T) {
	private Opt!T value_;
}

@trusted Late!T late(T)() =>
	Late!T(none!T);

@trusted Late!T late(T)(T value) =>
	Late!T(some(value));

bool lateIsSet(T)(ref Late!T a) =>
	has(a.value_);

@trusted ref immutable(T) lateGet(T)(return scope ref Late!T a) {
	assert(lateIsSet(a));
	return force(a.value_);
}

@trusted void lateSet(T)(ref Late!T a, T value) {
	assert(!lateIsSet(a));
	initMemory(&a.value_, some!T(value));
}

// TODO: we shouldn't do this
@trusted void lateSetOverwrite(T)(ref Late!T a, T value) {
	assert(lateIsSet(a));
	initMemory(&a.value_, some(value));
}

ref immutable(T) lazilySet(T)(ref Late!T a, in immutable(T) delegate() @safe @nogc pure nothrow cb) {
	if (!lateIsSet(a))
		lateSet!T(a, cb());
	return lateGet!T(a);
}
