module concretize.allConstantsBuilder;

@safe @nogc pure nothrow:

import model.concreteModel :
	AllConstantsConcrete,
	ArrTypeAndConstantsConcrete,
	ConcreteStruct,
	ConcreteStructSource,
	ConcreteType,
	PointerTypeAndConstantsConcrete;
import model.constant : Constant, constantZero;
import util.alloc.alloc : Alloc;
import util.col.array : arraysEqual, fillArray, findIndex, isEmpty, map, only;
import util.col.mutArr : asTemporaryArray, moveToArray, MutArr, mutArrSize, push;
import util.col.mutMap : getOrAdd, mapToArray, MutMap, size, values;
import util.conv : safeToUint;
import util.integralValues : IntegralValue;
import util.memory : initMemory;
import util.opt : force, has, Opt;
import util.string : copyToCString, CString;
import util.symbol : stringOfSymbol, Symbol;
import util.util : ptrTrustMe;

struct AllConstantsBuilder {
	private:
	@disable this(ref const AllConstantsBuilder);
	MutMap!(immutable string, Constant.CString) cStrings;
	MutMap!(Symbol, Constant.CString) symbols;
	MutArr!CString cStringValues;
	MutMap!(ConcreteType, ArrTypeAndConstants) arrs;
	MutMap!(ConcreteStruct*, PointerTypeAndConstants) pointers;
}

private struct ArrTypeAndConstants {
	immutable ConcreteStruct* arrType;
	immutable ConcreteType elementType;
	immutable uint typeIndex; // order this was inserted into 'arrs'
	MutArr!(immutable Constant[]) constants;
}

private struct PointerTypeAndConstants {
	immutable uint typeIndex;
	MutArr!Constant constants;
}

AllConstantsConcrete finishAllConstants(
	ref Alloc alloc,
	scope ref AllConstantsBuilder a,
	ConcreteStruct* symbolArrayStruct,
) {
	Constant staticSymbols = getConstantArray(
		alloc, a, symbolArrayStruct,
		mapToArray!(Constant, Symbol, Constant.CString)(alloc, a.symbols, (Symbol _, ref Constant.CString v) =>
			Constant(v)));

	ArrTypeAndConstantsConcrete[] arrays = fillArray!ArrTypeAndConstantsConcrete(
		alloc, size(a.arrs), ArrTypeAndConstantsConcrete(null));
	foreach (ref ArrTypeAndConstants x; values(a.arrs))
		initMemory(&arrays[x.typeIndex], ArrTypeAndConstantsConcrete(
			x.arrType,
			x.elementType,
			moveToArray!(immutable Constant[])(alloc, x.constants)));

	PointerTypeAndConstantsConcrete[] pointers = fillArray!PointerTypeAndConstantsConcrete(
		alloc, size(a.pointers), PointerTypeAndConstantsConcrete(null));
	foreach (ConcreteStruct* pointerType, ref PointerTypeAndConstants x; a.pointers)
		initMemory(
			&pointers[x.typeIndex],
			PointerTypeAndConstantsConcrete(pointerType, moveToArray(alloc, x.constants)));

	return AllConstantsConcrete(moveToArray(alloc, a.cStringValues), staticSymbols, arrays, pointers);
}

// TODO: this will be used when creating constant records by-ref.
Constant getConstantPointer(
	ref Alloc alloc,
	ref AllConstantsBuilder constants,
	ConcreteStruct* pointee,
	Constant value,
) {
	PointerTypeAndConstants* d = ptrTrustMe(getOrAdd(alloc, constants.pointers, pointee, () =>
		PointerTypeAndConstants(safeToUint(size(constants.pointers)), MutArr!(immutable Constant)())));
	return Constant(Constant.Pointer(
		d.typeIndex,
		findOrPush!Constant(alloc, d.constants, (in Constant a) => a == value, () => value)));
}

Constant getConstantArray(
	ref Alloc alloc,
	scope ref AllConstantsBuilder allConstants,
	ConcreteStruct* arrStruct,
	// TODO:PERF take this 'in', only allocate if necessary.
	Constant[] elements,
) {
	if (isEmpty(elements))
		return constantZero;
	else {
		ConcreteType elementType = only(arrStruct.source.as!(ConcreteStructSource.Inst).typeArgs);
		ArrTypeAndConstants* d = ptrTrustMe(getOrAdd(alloc, allConstants.arrs, elementType, () =>
			ArrTypeAndConstants(
				arrStruct,
				elementType,
				safeToUint(size(allConstants.arrs)),
				MutArr!(immutable Constant[])())));
		uint index = findOrPush!(immutable Constant[])(
			alloc,
			d.constants,
			(in Constant[] x) => arraysEqual!Constant(x, elements),
			() => elements);
		return Constant(Constant.ArrConstant(d.typeIndex, index));
	}
}

Constant getConstantCString(ref Alloc alloc, ref AllConstantsBuilder allConstants, string value) =>
	Constant(getConstantCStringInner(alloc, allConstants, value));

private Constant.CString getConstantCStringInner(ref Alloc alloc, ref AllConstantsBuilder allConstants, string value) =>
	getOrAdd!(immutable string, Constant.CString)(
		alloc,
		allConstants.cStrings,
		value,
		() {
			uint index = safeToUint(mutArrSize(allConstants.cStringValues));
			assert(size(allConstants.cStrings) == index);
			push(alloc, allConstants.cStringValues, copyToCString(alloc, value));
			return Constant.CString(index);
		});

Constant getConstantString(ref Alloc alloc, ref AllConstantsBuilder allConstants, ConcreteStruct* stringStruct, Symbol value) =>
	getConstantArray(
		alloc, allConstants, stringStruct,
		map(alloc, cast(immutable ubyte[]) stringOfSymbol(alloc, value), (ref immutable ubyte x) =>
			Constant(IntegralValue(x))));

Constant getConstantSymbol(ref Alloc alloc, ref AllConstantsBuilder allConstants, Symbol value) =>
	Constant(getOrAdd!(Symbol, Constant.CString)(alloc, allConstants.symbols, value, () =>
		getConstantCStringInner(alloc, allConstants, stringOfSymbol(alloc, value))));

private:

uint findOrPush(T)(
	ref Alloc alloc,
	ref MutArr!T a,
	in bool delegate(in T) @safe @nogc pure nothrow cbFind,
	in T delegate() @safe @nogc pure nothrow cbPush,
) {
	Opt!size_t res = findIndex!T(asTemporaryArray(a), cbFind);
	if (has(res))
		return safeToUint(force(res));
	else {
		push(alloc, a, cbPush());
		return safeToUint(mutArrSize(a)) - 1;
	}
}
