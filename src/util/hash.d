module util.hash;

@safe @nogc pure nothrow:

import util.opt : force, has, MutOpt, noneMut, someMut;
import util.string : SmallString;

HashCode getHash(T)(in T a) {
	static if (is(T == P*, P))
		return hashPointer(a);
	else static if (is(T == immutable string) || is(T == SmallString))
		return hashString(a);
	else static if (is(T == uint))
		return hashUlong(a);
	else static if (__traits(hasMember, T, "taggedPointerValueForHash"))
		return hashUlong(a.taggedPointerValueForHash);
	else
		return a.hash();
}

HashCode getHashOfPair(T, U)(in T a, in U b) =>
	hashUlongs([getHashableUlong!T(a), getHashableUlong!U(b)]);

private ulong getHashableUlong(T)(in T a) {
	static if (is(T == P*, P))
		return cast(ulong) a;
	else static if (is(T == uint))
		return a;
	else static if (__traits(hasMember, T, "taggedPointerValueForHash"))
		return a.taggedPointerValueForHash;
	else
		return a.hash().hashCode;
}

struct HashCode {
	ulong hashCode;
}

struct Hasher {
	@safe @nogc pure nothrow:

	private:
	// based on https://github.com/PeterScott/murmur3/blob/master/murmur3.c
	// but designed to take things one at a time instead of a single buffer
	MurmurState h = murmurInit;
	// murmur wants to take it 128 bits at a time but 'mix' only takes 64 bits.
	MutOpt!ulong firstHalf;

	public void opOpAssign(string op : "~", T)(in T a) scope{
		static if (is(T == P*, P))
			mix(cast(size_t) a);
		else
			mix(a);
	}

	void mix(ulong a) {
		if (has(firstHalf)) {
			h = murmurStep(h, force(firstHalf), a);
			firstHalf = noneMut!ulong;
		} else
			firstHalf = someMut(a);
	}

	public HashCode finish() {
		if (has(firstHalf))
			mix(0);
		assert(!has(firstHalf));
		return murmurFinish(h);
	}
}

HashCode hashTaggedPointer(T)(in T taggedPointer) =>
	hashUlong(taggedPointer.taggedPointerValueForHash);

HashCode hashPointers(T, U)(in T* a, in U* b) =>
	hashUlongs([cast(ulong) a, cast(ulong) b]);

HashCode hashPointerAndTaggedPointers(T, U)(in T* pointer, in U[] taggedPointers) {
	Hasher hasher;
	hasher ~= pointer;
	foreach (U x; taggedPointers)
		hasher ~= x.taggedPointerValueForHash;
	return hasher.finish();
}

HashCode hashPointerAndTaggedPointersX2(T, U, V)(in T* pointer, in U[] taggedPointers, in V[] taggedPointers2) {
	Hasher hasher;
	hasher ~= pointer;
	foreach (U x; taggedPointers)
		hasher ~= x.taggedPointerValueForHash;
	foreach (V x; taggedPointers2)
		hasher ~= x.taggedPointerValueForHash;
	return hasher.finish();
}

HashCode hashUints(uint a, uint b) =>
	HashCode(fmix64((ulong(a) << 32) | b));

HashCode hashUlong(ulong a) =>
	HashCode(fmix64(a));

private HashCode hashUlongs(ulong[2] a) =>
	murmurFinish(a);

HashCode hashPointer(T)(T* a) =>
	hashUlong(cast(size_t) a);

@trusted HashCode hashString(in string data) {
	const ulong* blocks = cast(const ulong *) data.ptr;
	const size_t nBlocks = data.length / 16;
	MurmurState h = murmurInit;
	foreach (size_t i; 0 .. nBlocks)
		h = murmurStep(h, blocks[i * 2], blocks[i * 2 + 1]);
	return murmurFinish(murmurStepTail(h, cast(immutable ubyte[]) data[nBlocks * 16 .. $]));
}

private:

alias MurmurState = ulong[2];

MurmurState murmurInit() =>
	[0, 0];

MurmurState murmurStep(MurmurState h, ulong k1, ulong k2) {
	ulong h1 = h[0];
	ulong h2 = h[1];
	k1 *= c1; k1 = rotl64(k1, 31); k1 *= c2; h1 ^= k1;
	h1 = rotl64(h1, 27); h1 += h2; h1 = h1 * 5 + 0x52dce729;
	k2 *= c2; k2 = rotl64(k2,33); k2 *= c1; h2 ^= k2;
	h2 = rotl64(h2, 31); h2 += h1; h2 = h2 * 5 + 0x38495ab5;
	return [h1, h2];
}

MurmurState murmurStepTail(MurmurState h, in ubyte[] tail) {
	assert(tail.length < 16);

	ulong k1 = 0;
	ulong k2 = 0;

	final switch (tail.length & 15) {
		case 15: k2 ^= ulong(tail[14]) << 48; goto case 14;
		case 14: k2 ^= ulong(tail[13]) << 40; goto case 13;
		case 13: k2 ^= ulong(tail[12]) << 32; goto case 12;
		case 12: k2 ^= ulong(tail[11]) << 24; goto case 11;
		case 11: k2 ^= ulong(tail[10]) << 16; goto case 10;
		case 10: k2 ^= ulong(tail[9]) << 8; goto case 8;
		case 9:
			k2 ^= ulong(tail[8]) << 0;
			k2 *= c2;
			k2 = rotl64(k2, 33);
			k2 *= c1;
			h[1] ^= k2;
			goto case 8;
		case 8: k1 ^= ulong(tail[7]) << 56; goto case 7;
		case 7: k1 ^= ulong(tail[6]) << 48; goto case 6;
		case 6: k1 ^= ulong(tail[5]) << 40; goto case 5;
		case 5: k1 ^= ulong(tail[4]) << 32; goto case 4;
		case 4: k1 ^= ulong(tail[3]) << 24; goto case 3;
		case 3: k1 ^= ulong(tail[2]) << 16; goto case 2;
		case 2: k1 ^= ulong(tail[1]) << 8; goto case 1;
		case 1:
			k1 ^= ulong(tail[ 0]) << 0;
			k1 *= c1;
			k1 = rotl64(k1, 31);
			k1 *= c2;
			h[0] ^= k1;
			break;
		case 0:
	}

	return h;
}

ulong c1() => 0x87c37b91114253d5;
ulong c2() => 0x4cf5ad432745937f;

HashCode murmurFinish(MurmurState h) {
	ulong h1 = h[0];
	ulong h2 = h[1];

	// h1 ^= len; h2 ^= len;

	h1 += h2;
	h2 += h1;

	h1 = fmix64(h1);
	h2 = fmix64(h2);

	h1 += h2;
	h2 += h1;

	return HashCode(h1 ^ h2);
}

ulong fmix64(ulong k) {
	k ^= k >> 33;
	k *= 0xff51afd7ed558ccd;
	k ^= k >> 33;
	k *= 0xc4ceb9fe1a85ec53;
	k ^= k >> 33;
	return k;
}

static ulong rotl64(ulong x, byte r) =>
	(x << r) | (x >> (64 - r));
