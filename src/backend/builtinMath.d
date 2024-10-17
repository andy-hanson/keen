module backend.builtinMath;

@safe @nogc pure nothrow:

import model.model : BuiltinBinaryMath, BuiltinUnaryMath;

// https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html
enum BuiltinFunction {
	acos,
	acosf,
	acosh,
	acoshf,
	asin,
	asinf,
	asinh,
	asinhf,
	atan,
	atanf,
	atan2,
	atan2f,
	atanh,
	atanhf,
	__builtin_isnan,
	__builtin_popcountl,
	ceil,
	ceilf,
	cos,
	cosf,
	cosh,
	coshf,
	floor,
	floorf,
	fmod,
	fmodf,
	log,
	logf,
	pow,
	powf,
	round,
	roundf,
	sin,
	sinf,
	sinh,
	sinhf,
	sqrt,
	sqrtf,
	tan,
	tanf,
	tanh,
	tanhf,
}

BuiltinFunction builtinForUnaryMath(BuiltinUnaryMath a) {
	final switch (a) {
		case BuiltinUnaryMath.acosFloat32:
			return BuiltinFunction.acosf;
		case BuiltinUnaryMath.acosFloat64:
			return BuiltinFunction.acos;
		case BuiltinUnaryMath.acoshFloat32:
			return BuiltinFunction.acoshf;
		case BuiltinUnaryMath.acoshFloat64:
			return BuiltinFunction.acosh;
		case BuiltinUnaryMath.asinFloat32:
			return BuiltinFunction.asinf;
		case BuiltinUnaryMath.asinFloat64:
			return BuiltinFunction.asin;
		case BuiltinUnaryMath.asinhFloat32:
			return BuiltinFunction.asinhf;
		case BuiltinUnaryMath.asinhFloat64:
			return BuiltinFunction.asinh;
		case BuiltinUnaryMath.atanFloat32:
			return BuiltinFunction.atanf;
		case BuiltinUnaryMath.atanFloat64:
			return BuiltinFunction.atan;
		case BuiltinUnaryMath.atanhFloat32:
			return BuiltinFunction.atanhf;
		case BuiltinUnaryMath.atanhFloat64:
			return BuiltinFunction.atanh;
		case BuiltinUnaryMath.cosFloat32:
			return BuiltinFunction.cosf;
		case BuiltinUnaryMath.cosFloat64:
			return BuiltinFunction.cos;
		case BuiltinUnaryMath.coshFloat32:
			return BuiltinFunction.coshf;
		case BuiltinUnaryMath.coshFloat64:
			return BuiltinFunction.cosh;
		case BuiltinUnaryMath.sinFloat32:
			return BuiltinFunction.sinf;
		case BuiltinUnaryMath.sinFloat64:
			return BuiltinFunction.sin;
		case BuiltinUnaryMath.sinhFloat32:
			return BuiltinFunction.sinhf;
		case BuiltinUnaryMath.sinhFloat64:
			return BuiltinFunction.sinh;
		case BuiltinUnaryMath.tanFloat32:
			return BuiltinFunction.tanf;
		case BuiltinUnaryMath.tanFloat64:
			return BuiltinFunction.tan;
		case BuiltinUnaryMath.tanhFloat32:
			return BuiltinFunction.tanhf;
		case BuiltinUnaryMath.tanhFloat64:
			return BuiltinFunction.tanh;
		case BuiltinUnaryMath.roundDownFloat32:
			return BuiltinFunction.floorf;
		case BuiltinUnaryMath.roundDownFloat64:
			return BuiltinFunction.floor;
		case BuiltinUnaryMath.roundFloat32:
			return BuiltinFunction.roundf;
		case BuiltinUnaryMath.roundFloat64:
			return BuiltinFunction.round;
		case BuiltinUnaryMath.roundUpFloat32:
			return BuiltinFunction.ceilf;
		case BuiltinUnaryMath.roundUpFloat64:
			return BuiltinFunction.ceil;
		case BuiltinUnaryMath.sqrtFloat32:
			return BuiltinFunction.sqrtf;
		case BuiltinUnaryMath.sqrtFloat64:
			return BuiltinFunction.sqrt;
		case BuiltinUnaryMath.unsafeLogFloat32:
			return BuiltinFunction.logf;
		case BuiltinUnaryMath.unsafeLogFloat64:
			return BuiltinFunction.log;
	}
}

BuiltinFunction builtinForBinaryMath(BuiltinBinaryMath a) {
	final switch (a) {
		case BuiltinBinaryMath.atan2Float32:
			return BuiltinFunction.atan2f;
		case BuiltinBinaryMath.atan2Float64:
			return BuiltinFunction.atan2;
		case BuiltinBinaryMath.fmodFloat32:
			return BuiltinFunction.fmodf;
		case BuiltinBinaryMath.fmodFloat64:
			return BuiltinFunction.fmod;
		case BuiltinBinaryMath.unsafePowFloat32:
			return BuiltinFunction.powf;
		case BuiltinBinaryMath.unsafePowFloat64:
			return BuiltinFunction.pow;
	}
}
