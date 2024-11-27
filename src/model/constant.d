module model.constant;

@safe @nogc pure nothrow:

import model.concreteModel : ConcreteFun;
import util.col.array : arraysEqual, every, SmallArray;
import util.integralValues : IntegralValue;
import util.union_ : Union;

// WARN: The type of a constant is implicit (given by context).
// This means two constants that look equal may not be the same constant if they have different types
// (e.g., IntegralValue has different sizes.)
// WARN: A Constant.Record is *by value* even if the record usually isn't. Use Constant.Pointer for a pointer.
immutable struct Constant {
	@safe @nogc pure nothrow:

	mixin Union!(
		ConstantArray,
		ConstantCString,
		ConstantFloat,
		ConstantFunPointer,
		IntegralValue,
		ConstantPointer,
		ConstantRecord,
		ConstantUnion*,
		ConstantZero);

	// WARN: Only do this with constants known to have the same type
	bool opEquals(in Constant b) scope {
		if (isA!ConstantZero || b.isA!ConstantZero)
			return isZero(this) && isZero(b);
		else {
			assert(kind == b.kind);
			return matchIn!bool(
				(in ConstantArray x) =>
					b.as!ConstantArray.index == x.index,
				(in ConstantCString x) =>
					b.as!ConstantCString.index == x.index,
				(in ConstantFloat x) =>
					//TODO: handle NaN
					b.as!ConstantFloat.value == x.value,
				(in ConstantFunPointer x) =>
					b.as!ConstantFunPointer.fun == x.fun,
				(in IntegralValue x) =>
					b.as!IntegralValue.value == x.value,
				(in ConstantPointer x) =>
					b.as!ConstantPointer.index == x.index,
				(in ConstantRecord ra) =>
					arraysEqual!Constant(ra.args, b.as!ConstantRecord.args),
				(in ConstantUnion ua) =>
					ua.memberIndex == b.as!(ConstantUnion*).memberIndex && ua.arg == b.as!(ConstantUnion*).arg,
				(in ConstantZero) =>
					true);
		}
	}
}
static assert(Constant.sizeof <= 16);

immutable struct ConstantArray {
	uint typeIndex; // Index of the arr type in AllConstants
	uint index; // Index into AllConstants#arrs for this type.
}
// Nul-terminated string identified only by its begin pointer.
immutable struct ConstantCString {
	uint index; // Index into AllConstants#cStrings
}
// Used for float32 / float64
immutable struct ConstantFloat {
	double value;
}
immutable struct ConstantFunPointer {
	ConcreteFun* fun;
}
// Pointer (or gc-pointer) to another constant
immutable struct ConstantPointer {
	uint typeIndex;
	uint index; // Index into AllConstants#pointers for this type
}
// This is a record by-value.
immutable struct ConstantRecord {
	SmallArray!Constant args;
}
immutable struct ConstantUnion {
	size_t memberIndex;
	Constant arg;
}
// All 0 bits. Good for null, void, or empty value of 'extern' type.
immutable struct ConstantZero {}

private bool isZero(in Constant a) =>
	a.matchIn!bool(
		(in ConstantArray) =>
			// We only create ArrConstant for non-empty arrays
			false,
		(in ConstantCString _) =>
			false,
		(in ConstantFloat x) =>
			x.value == 0,
		(in ConstantFunPointer x) =>
			false,
		(in IntegralValue x) =>
			x.value == 0,
		(in ConstantPointer x) =>
			false,
		(in ConstantRecord x) =>
			every!Constant(x.args, (in Constant arg) => isZero(arg)),
		(in ConstantUnion x) =>
			isZero(x.arg),
		(in ConstantZero _) =>
			true);

Constant constantBool(bool b) =>
	Constant(IntegralValue(b));

bool asBool(Constant a) {
	ulong value = a.as!IntegralValue.asUnsigned;
	assert(value == 0 || value == 1);
	return value == 1;
}

Constant constantZero() =>
	Constant(ConstantZero());

long asInt64(Constant a) =>
	a.isA!(ConstantZero) ? 0 : a.as!IntegralValue.asSigned;
ulong asNat64(Constant a) =>
	a.isA!(ConstantZero) ? 0 : a.as!IntegralValue.asUnsigned;
