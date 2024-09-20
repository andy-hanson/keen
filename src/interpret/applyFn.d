module interpret.applyFn;

@safe @nogc pure nothrow:

import interpret.bytecode : Operation;
import interpret.runBytecode : opFnBinary, opFnUnary;
import model.model : BuiltinBinaryMath, BuiltinUnaryMath;
import util.conv : bitsOfFloat32, bitsOfFloat64, bitsOfLong, float32OfBits, float64OfBits;
import util.util : isNan;

private alias binaryFloat32s(alias cb) = opFnBinary!((ulong a, ulong b) =>
	bitsOfFloat32(cb(float32OfBits(a), float32OfBits(b))));

private alias binaryFloat64s(alias cb) = opFnBinary!((ulong a, ulong b) =>
	bitsOfFloat64(cb(float64OfBits(a), float64OfBits(b))));

private alias unaryFloat32(alias cb) = opFnUnary!((ulong a) =>
	bitsOfFloat32(cb(float32OfBits(a))));

private alias unaryFloat64(alias cb) = opFnUnary!((ulong a) =>
	bitsOfFloat64(cb(float64OfBits(a))));

Operation.Fn fnForUnaryMath(BuiltinUnaryMath a) {
	final switch (a) {
		case BuiltinUnaryMath.acosFloat32:
			return &unaryFloat32!((float a) => acosf(a));
		case BuiltinUnaryMath.acosFloat64:
			return &unaryFloat64!((double a) => acos(a));
		case BuiltinUnaryMath.acoshFloat32:
			return &unaryFloat32!((float a) => acoshf(a));
		case BuiltinUnaryMath.acoshFloat64:
			return &unaryFloat64!((double a) => acosh(a));
		case BuiltinUnaryMath.asinFloat32:
			return &unaryFloat32!((float a) => asinf(a));
		case BuiltinUnaryMath.asinFloat64:
			return &unaryFloat64!((double a) => asin(a));
		case BuiltinUnaryMath.asinhFloat32:
			return &unaryFloat32!((float a) => asinhf(a));
		case BuiltinUnaryMath.asinhFloat64:
			return &unaryFloat64!((double a) => asinh(a));
		case BuiltinUnaryMath.atanFloat32:
			return &unaryFloat32!((float a) => atanf(a));
		case BuiltinUnaryMath.atanFloat64:
			return &unaryFloat64!((double a) => atan(a));
		case BuiltinUnaryMath.atanhFloat32:
			return &unaryFloat32!((float a) => atanhf(a));
		case BuiltinUnaryMath.atanhFloat64:
			return &unaryFloat64!((double a) => atanh(a));
		case BuiltinUnaryMath.cosFloat32:
			return &unaryFloat32!((float a) => cosf(a));
		case BuiltinUnaryMath.cosFloat64:
			return &unaryFloat64!((double a) => cos(a));
		case BuiltinUnaryMath.coshFloat32:
			return &unaryFloat32!((float a) => coshf(a));
		case BuiltinUnaryMath.coshFloat64:
			return &unaryFloat64!((double a) => cosh(a));
		case BuiltinUnaryMath.roundDownFloat32:
			return &unaryFloat32!((float a) => floorf(a));
		case BuiltinUnaryMath.roundDownFloat64:
			return &unaryFloat64!((double a) => floor(a));
		case BuiltinUnaryMath.roundFloat32:
			return &unaryFloat32!((float a) => roundf(a));
		case BuiltinUnaryMath.roundFloat64:
			return &unaryFloat64!((double a) => round(a));
		case BuiltinUnaryMath.roundUpFloat32:
			return &unaryFloat64!((float a) => ceilf(a));
		case BuiltinUnaryMath.roundUpFloat64:
			return &unaryFloat64!((double a) => ceil(a));
		case BuiltinUnaryMath.sinFloat32:
			return &unaryFloat32!((float a) => sinf(a));
		case BuiltinUnaryMath.sinFloat64:
			return &unaryFloat64!((double a) => sin(a));
		case BuiltinUnaryMath.sinhFloat32:
			return &unaryFloat32!((float a) => sinhf(a));
		case BuiltinUnaryMath.sinhFloat64:
			return &unaryFloat64!((double a) => sinh(a));
		case BuiltinUnaryMath.sqrtFloat32:
			return &unaryFloat32!((float a) => sqrtf(a));
		case BuiltinUnaryMath.sqrtFloat64:
			return &unaryFloat64!((double a) => sqrt(a));
		case BuiltinUnaryMath.tanFloat32:
			return &unaryFloat32!((float a) => tanf(a));
		case BuiltinUnaryMath.tanFloat64:
			return &unaryFloat64!((double a) => tan(a));
		case BuiltinUnaryMath.tanhFloat32:
			return &unaryFloat32!((float a) => tanhf(a));
		case BuiltinUnaryMath.tanhFloat64:
			return &unaryFloat64!((double a) => tanh(a));
		case BuiltinUnaryMath.unsafeLogFloat32:
			return &unaryFloat32!((float a) => logf(a));
		case BuiltinUnaryMath.unsafeLogFloat64:
			return &unaryFloat64!((double a) => log(a));
	}
}

Operation.Fn fnForBinaryMath(BuiltinBinaryMath a) {
	final switch (a) {
		case BuiltinBinaryMath.atan2Float32:
			return &binaryFloat32s!((float a, float b) => atan2f(a, b));
		case BuiltinBinaryMath.atan2Float64:
			return &binaryFloat64s!((double a, double b) => atan2(a, b));
		case BuiltinBinaryMath.unsafePowFloat32:
			return &binaryFloat32s!((float a, float b) => powf(a, b));
		case BuiltinBinaryMath.unsafePowFloat64:
			return &binaryFloat64s!((double a, double b) => pow(a, b));
	}
}

alias fnAddFloat32 = binaryFloat32s!((float a, float b) => a + b);
alias fnAddFloat64 = binaryFloat64s!((double a, double b) => a + b);
alias fnBitwiseNot = opFnUnary!((ulong a) => ~a);
alias fnNot = opFnUnary!((ulong a) => !a);
alias fnBitwiseAnd = opFnBinary!((ulong a, ulong b) => a & b);
alias fnBitwiseOr = opFnBinary!((ulong a, ulong b) => a | b);
alias fnBitwiseXor = opFnBinary!((ulong a, ulong b) => a ^ b);
alias fnCountOnesNat64 = opFnUnary!((ulong a) => popcount(a));
alias fnEq8Bit = opFnBinary!((ulong a, ulong b) => cast(ubyte) a == cast(ubyte) b);
alias fnEq16Bit = opFnBinary!((ulong a, ulong b) => cast(ushort) a == cast(ushort) b);
alias fnEq32Bit = opFnBinary!((ulong a, ulong b) => cast(uint) a == cast(uint) b);
alias fnEq64Bit = opFnBinary!((ulong a, ulong b) => a == b);
alias fnEqFloat32 = opFnBinary!((ulong a, ulong b) =>
	float32OfBits(a) == float32OfBits(b));
alias fnEqFloat64 = opFnBinary!((ulong a, ulong b) =>
	float64OfBits(a) == float64OfBits(b));
alias fnFloat32FromFloat64 = opFnUnary!((ulong a) =>
	bitsOfFloat32(cast(float) float64OfBits(a)));
alias fnFloat64FromFloat32 = opFnUnary!((ulong a) =>
	bitsOfFloat64(cast(double) float32OfBits(a)));
alias fnFloat64FromInt64 = opFnUnary!((ulong a) =>
	bitsOfFloat64(cast(double) (cast(long) a)));
alias fnFloat64FromNat64 = opFnUnary!((ulong a) =>
	bitsOfFloat64(cast(double) a));
alias fnInt64FromInt8 = opFnUnary!((ulong a) =>
	cast(ulong) (cast(long) (cast(byte) a)));
alias fnInt64FromInt16 = opFnUnary!((ulong a) =>
	cast(ulong) (cast(long) (cast(short) a)));
alias fnInt64FromInt32 = opFnUnary!((ulong a) =>
	bitsOfLong(cast(long) (cast(int) a)));
alias fnIsNanFloat32 = opFnUnary!((ulong a) =>
	isNan(float32OfBits(a)));
alias fnIsNanFloat64 = opFnUnary!((ulong a) =>
	isNan(float64OfBits(a)));
alias fnLessFloat32 = opFnBinary!((ulong a, ulong b) =>
	float32OfBits(a) < float32OfBits(b));
alias fnLessFloat64 = opFnBinary!((ulong a, ulong b) =>
	float64OfBits(a) < float64OfBits(b));
private alias fnLessT(T) = opFnBinary!((ulong a, ulong b) =>
	(cast(T) a) < (cast(T) b));
alias fnLessInt8 = fnLessT!byte;
alias fnLessInt16 = fnLessT!short;
alias fnLessInt32 = fnLessT!int;
alias fnLessInt64 = fnLessT!long;
alias fnLessNat8 = fnLessT!ubyte;
alias fnLessNat16 = fnLessT!ushort;
alias fnLessNat32 = fnLessT!uint;
alias fnLessNat64 = fnLessT!ulong;
alias fnMulFloat32 = binaryFloat32s!((float a, float b) => a * b);
alias fnMulFloat64 = binaryFloat64s!((double a, double b) => a * b);
alias fnSubFloat32 = binaryFloat32s!((float a, float b) => a - b);
alias fnSubFloat64 = binaryFloat64s!((double a, double b) => a - b);
alias fnTruncateToInt64FromFloat64 = opFnUnary!((ulong a) =>
	cast(ulong) cast(long) float64OfBits(a));
alias fnUnsafeBitShiftLeftNat64 = opFnBinary!((ulong a, ulong b) {
	assert(b < 64);
	return a << b;
});
alias fnUnsafeBitShiftRightNat64 = opFnBinary!((ulong a, ulong b) {
	assert(b < 64);
	return a >> b;
});
alias fnUnsafeDivFloat32 = binaryFloat32s!((float a, float b) => a / b);
alias fnUnsafeDivFloat64 = binaryFloat64s!((double a, double b) => a / b);
alias fnUnsafeDivInt8 = opFnBinary!((ulong a, ulong b) =>
	cast(byte) a / cast(byte) b);
alias fnUnsafeDivInt16 = opFnBinary!((ulong a, ulong b) =>
	cast(short) a / cast(short) b);
alias fnUnsafeDivInt32 = opFnBinary!((ulong a, ulong b) =>
	cast(int) a / cast(int) b);
alias fnUnsafeDivInt64 = opFnBinary!((ulong a, ulong b) =>
	cast(ulong) ((cast(long) a) / (cast(long) b)));
alias fnUnsafeDivNat8 = opFnBinary!((ulong a, ulong b) =>
	cast(ubyte) a / cast(ubyte) b);
alias fnUnsafeDivNat16 = opFnBinary!((ulong a, ulong b) =>
	cast(ushort) a / cast(ushort) b);
alias fnUnsafeDivNat32 = opFnBinary!((ulong a, ulong b) =>
	cast(uint) a / cast(uint) b);
alias fnUnsafeDivNat64 = opFnBinary!((ulong a, ulong b) =>
	a / b);
alias fnUnsafeModNat64 = opFnBinary!((ulong a, ulong b) =>
	a % b);
alias fnWrapAddIntegral = opFnBinary!((ulong a, ulong b) =>
	a + b);
alias fnWrapMulIntegral = opFnBinary!((ulong a, ulong b) =>
	a * b);
alias fnWrapSubIntegral = opFnBinary!((ulong a, ulong b) =>
	a - b);

private:

//TODO:PERF
long popcount(ulong a) =>
	a == 0
		? 0
		: popcount(a >> 1) + (a % 2 != 0 ? 1 : 0);

// Importing 'core.stdc.math' breaks WASM builds, so declaring here
extern(C) {
	double acos(double x);
	float acosf(float x);
	double acosh(double x);
	float acoshf(float x);
	double asin(double x);
	float asinf(float x);
	double asinh(double x);
	float asinhf(float x);
	double atan(double x);
	float atanf(float x);
	double atanh(double x);
	float atanhf(float x);
	double atan2(double x, double y);
	float atan2f(float x, float y);
	double ceil(double x);
	float ceilf(float x);
	double cos(double x);
	float cosf(float x);
	double cosh(double x);
	float coshf(float x);
	double floor(float x);
	float floorf(float x);
	double log(double x);
	double logf(float x);
	double pow(double x, double y);
	float powf(float x, float y);
	double round(double x);
	float roundf(float x);
	double sin(double x);
	float sinf(float x);
	double sinh(double x);
	float sinhf(float x);
	double sqrt(double x);
	float sqrtf(float x);
	double tan(double x);
	float tanf(float x);
	double tanh(double x);
	float tanhf(float x);
}
