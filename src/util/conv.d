module util.conv;

@safe @nogc pure nothrow:

import util.opt : Opt, optIf;

int safeIntFromUint(uint u) {
	assert(u <= int.max);
	return cast(int) u;
}

ushort safeToUshort(size_t a) {
	assert(a <= ushort.max);
	return cast(ushort) a;
}

int safeToInt(size_t a) {
	assert(a <= int.max);
	return cast(int) a;
}

bool isUint(ulong a) =>
	a <= uint.max;

static if (!is(uint == size_t))
	uint safeToUint()(uint a) { static assert(false); }
uint safeToUint(ulong a) {
	assert(isUint(a));
	return cast(uint) a;
}

long safeToLong(ulong a) {
	assert(a <= long.max);
	return cast(long) a;
}
Opt!long tryToLong(ulong a) =>
	optIf(a <= long.max, () => cast(long) a);

ulong safeToUlong(long a) {
	assert(a >= 0);
	return cast(ulong) a;
}

size_t safeToSizeT(ulong a) {
	assert(a <= size_t.max);
	return cast(size_t) a;
}

size_t safeMul(size_t a, size_t b) {
	size_t res = a * b;
	assert(b == 0 || res / b == a);
	return res;
}

uint bitsOfFloat32(float value) =>
	Converter32(asFloat32: value).asUint;

float float32OfBits(ulong value) =>
	Converter32(asUint: cast(uint) value).asFloat32;

ulong bitsOfFloat64(double value) =>
	Converter64(asFloat64: value).asUlong;

double float64OfBits(ulong value) =>
	Converter64(asUlong: value).asFloat64;

extern(C) double round(double x);

uint uintOfUshorts(ushort[2] a) =>
	((cast(uint) a[0]) << 16) | a[1];
ushort[2] ushortsOfUint(uint a) =>
	[a >> 16, a & 0xffff];

static assert(uintOfUshorts([0x1234, 0x5678]) == 0x12345678);
static assert(ushortsOfUint(0x12345678) == [0x1234, 0x5678], ushortsOfUint(0x12345678));

ulong bitsOfByte(byte a) =>
	cast(ulong) (cast(ubyte) a);

ulong bitsOfShort(short a) =>
	cast(ulong) (cast(ushort) a);

ulong bitsOfInt(int a) =>
	cast(ulong) (cast(uint) a);

ulong bitsOfLong(long a) =>
	cast(ulong) a;
double powerOf10(long power) {
	switch (power) {
		case -20:
			return 0.000_000_000_000_000_000_01;
		case -19:
			return 0.000_000_000_000_000_000_1;
		case -18:
			return 0.000_000_000_000_000_001;
		case -17:
			return 0.000_000_000_000_000_01;
		case -16:
			return 0.000_000_000_000_000_1;
		case -15:
			return 0.000_000_000_000_001;
		case -14:
			return 0.000_000_000_000_01;
		case -13:
			return 0.000_000_000_000_1;
		case -12:
			return 0.000_000_000_001;
		case -11:
			return 0.000_000_000_01;
		case -10:
			return 0.000_000_000_1;
		case -9:
			return 0.000_000_001;
		case -8:
			return 0.000_000_01;
		case -7:
			return 0.000_000_1;
		case -6:
			return 0.000_001;
		case -5:
			return 0.000_01;
		case -4:
			return 0.000_1;
		case -3:
			return 0.001;
		case -2:
			return 0.01;
		case -1:
			return 0.1;
		case 0:
			return 1;
		case 1:
			return 10;
		case 2:
			return 100;
		case 3:
			return 1_000;
		case 4:
			return 10_000;
		case 5:
			return 100_000;
		case 6:
			return 1_000_000;
		case 7:
			return 10_000_000;
		case 8:
			return 100_000_000;
		case 9:
			return 1_000_000_000;
		case 10:
			return 10_000_000_000;
		case 11:
			return 100_000_000_000;
		case 12:
			return 1_000_000_000_000;
		case 13:
			return 10_000_000_000_000;
		case 14:
			return 100_000_000_000_000;
		case 15:
			return 1_000_000_000_000_000;
		case 16:
			return 10_000_000_000_000_000;
		case 17:
			return 100_000_000_000_000_000;
		case 18:
			return 1_000_000_000_000_000_000;
		case 19:
			return 10_000_000_000_000_000_000;
		case 20:
			return 100_000_000_000_000_000_000.0;
		default:
			return powerOf10(power / 2) * powerOf10(power / 2) * (power % 2 == 0 ? 1 : power < 0 ? 0.1 : 10);
	}
}

private:

union Converter32 {
	uint asUint;
	float asFloat32;
}

union Converter64 {
	ulong asUlong;
	double asFloat64;
}
