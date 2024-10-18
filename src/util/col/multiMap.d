module util.col.multiMap;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.col.map : Map, values;
import util.col.mutMap : getOrAdd, mapToMap, MutMap, MutMapValues;
import util.opt : force, has, Opt;

immutable struct MultiMap(K, V) {
	@safe @nogc pure nothrow:

	private Map!(K, V[]) inner;

	immutable(V[]) opIndex(in K key) immutable {
		Opt!(V[]) res = inner[key];
		return has(res) ? force(res) : [];
	}

	int opApply(in int delegate(immutable K, immutable V[]) @safe @nogc pure nothrow cb) scope =>
		inner.opApply((immutable K key, ref immutable V[] value) => cb(key, value));
}

immutable(MutMapValues!(K, V[])) values(K, V)(ref MultiMap!(K, V) a) =>
	.values(a.inner);

alias MultiMapCb(K, V) = void delegate(K, V) @safe @nogc pure nothrow;

MultiMap!(K, V) makeMultiMap(K, V)(
	ref Alloc alloc,
	in void delegate(in MultiMapCb!(K, V) add) @safe @nogc pure nothrow cb,
) {
	MutMap!(K, ArrayBuilder!(immutable V)) builder;
	cb((K key, V value) {
		add(alloc, getOrAdd(alloc, builder, key, () => ArrayBuilder!(immutable V)()), value);
	});
	return toMultiMap!(K, V)(alloc, builder);
}

private MultiMap!(K, V) toMultiMap(K, V)(ref Alloc alloc, ref MutMap!(K, ArrayBuilder!V) builder) =>
	MultiMap!(K, V)(
		mapToMap!(K, V[], ArrayBuilder!(immutable V))(alloc, builder, (ref ArrayBuilder!(immutable V) arr) =>
			finish!V(alloc, arr)));
