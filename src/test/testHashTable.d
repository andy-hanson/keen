module test.testHashTable;

@safe @nogc pure nothrow:

import test.testUtil : assertEqual, Test;
import util.col.hashTable :
clear,
	deleteWhere,
	getOrAddAndDidAdd,
	HashTable,
	isEmpty,
	mustAdd,
	moveToImmutable,
	MutHashTable,
	size,
	ValueAndDidAdd,
	withSortedKeys;
import util.comparison : compareUint;
import util.opt : has;
import util.writer : Writer, writeWithCommas;

void testHashTable(scope ref Test test) {
	MutHashTable!(uint, uint, getKey) a;
	assert(isEmpty(a));
	assert(size(a) == 0);
	assert(!has(a[0]));
	assertKeys(a, []);

	{
		ValueAndDidAdd!uint x = getOrAddAndDidAdd!(uint, uint, getKey)(test.alloc, a, 4u, () => 4u);
		assert(x.didAdd);
		assert(x.value == 4);
		assertKeys(a, [4]);
	}
	{
		ValueAndDidAdd!uint x = getOrAddAndDidAdd!(uint, uint, getKey)(test.alloc, a, 4, () => assert(false));
		assert(!x.didAdd);
		assert(x.value == 4);
		assertKeys(a, [4]);
	}

	mustAdd!(uint, uint, getKey)(test.alloc, a, 5);
	mustAdd!(uint, uint, getKey)(test.alloc, a, 3);
	assertKeys(a, [3, 4, 5]);

	deleteWhere!(uint, uint, getKey)(a, (in uint x) => x % 2 == 0);
	assertKeys(a, [3, 5]);

	HashTable!(uint, uint, getKey) b = moveToImmutable!(uint, uint, getKey)(a);
	assertKeys(a, []);
	assertKeys(b, [3, 5]);

	mustAdd!(uint, uint, getKey)(test.alloc, a, 1);
	assertKeys(a, [1]);
	clear(a);
	assertKeys(a, []);
}

private:

void assertKeys(in MutHashTable!(uint, uint, getKey) a, in uint[] expected) {
	withSortedKeys!(void, uint, uint, getKey)(a, (in uint x, in uint y) => compareUint(x, y), (in uint[] keys) {
		assertEqual(keys, expected, (scope ref Writer writer, in uint[] xs) {
			writeWithCommas!uint(writer, xs);
		});
	});
}

uint getKey(uint i) =>
	i;
