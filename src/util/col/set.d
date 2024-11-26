module util.col.set;

@safe @nogc pure nothrow:

import util.col.mutSet : MutSet;

immutable struct Set(T) {
	@safe @nogc pure nothrow:

	private MutSet!T inner;

	bool opBinaryRight(string op)(in T x) scope if (op == "in") =>
		x in inner;

	int opApply(in int delegate(ref immutable T) @safe @nogc pure nothrow cb) scope =>
		inner.opApply(cb);
}

@trusted Set!T moveToSet(T)(ref MutSet!T a) =>
	Set!T(cast(immutable) a.move());
