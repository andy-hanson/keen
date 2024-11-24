module interpret.extern_;

@safe @nogc nothrow: // not pure

import interpret.bytecode : Operation;
import interpret.stacks : loadStacks, saveStacks, Stacks;
import model.lowModel : ExternLibraries, LowFunIndex, PrimitiveType;
import util.col.array : SmallArray, sum;
import util.col.map : Map;
import util.hash : HashCode, hashPointer;
import util.opt : Opt;
import util.symbol : Symbol;
import util.union_ : TaggedUnion;

immutable struct Extern {
	// 'none' if anything failed to load
	Opt!ExternPointersForAllLibraries delegate(
		in ExternLibraries libraries,
		scope WriteError writeError,
	) @safe @nogc nothrow loadExternPointers;
	MakeSyntheticFunPointers makeSyntheticFunPointers;
	AggregateCbs aggregateCbs;
	DoDynCall doDynCall;
}

immutable struct FunPointerInputs {
	LowFunIndex funIndex;
	DynCallSig sig;
	Operation* operationPtr;
}

alias MakeSyntheticFunPointers = FunPointer[] delegate(in FunPointerInputs[] inputs) @safe @nogc pure nothrow;
immutable struct AggregateCbs {
	DCaggr* function(size_t countFields, size_t sizeBytes) @system @nogc pure nothrow newAggregate;
	void function(DCaggr* aggr, size_t fieldOffset, DynCallType fieldType) @system @nogc pure nothrow addField;
	void function(DCaggr*) @system @nogc pure nothrow close;
}
/*
For some reason, trying to pass 'Stacks' into here leads to stack overflow issues
in optimized builds where 'opCallFunPointerExtern' isn't tail recursive.
So instead, the caller will 'saveStacks' before calling this, then this should 'saveStacks' before returning.
*/
alias DoDynCall = void delegate(FunPointer, in DynCallSig) @system @nogc nothrow;

@system void doDynCall(DoDynCall cb, ref Stacks stacks, DynCallSig sig, FunPointer funPtr) {
	saveStacks(stacks);
	cb(funPtr, sig);
	stacks = loadStacks();
}

alias WriteError = void delegate(in string) @safe @nogc nothrow;

alias ExternPointersForAllLibraries = Map!(Symbol, ExternPointersForLibrary);
alias ExternPointersForLibrary = Map!(Symbol, ExternPointer);

immutable struct FunPointer {
	@safe @nogc pure nothrow:

	void* pointer;

	HashCode hash() scope =>
		hashPointer(pointer);

	ulong asUlong() =>
		cast(ulong) pointer;

	@system static FunPointer fromUlong(ulong value) =>
		FunPointer(cast(immutable void*) value);

	ExternPointer asExternPointer() =>
		ExternPointer(pointer);
}

// May be a function or variable pointer
immutable struct ExternPointer {
	@safe @nogc pure nothrow:

	void* pointer;

	HashCode hash() scope =>
		hashPointer(pointer);

	ulong asUlong() =>
		cast(ulong) pointer;

	FunPointer asFunPointer() =>
		FunPointer(pointer);
}

immutable struct DynCallSig {
	@safe @nogc pure nothrow:

	SmallArray!DynCallType returnTypeAndParameterTypes;

	@system static DynCallSig fromOperation(Operation a) =>
		DynCallSig(SmallArray!DynCallType.fromTagged(a.ulong_));

	@trusted Operation toOperation() =>
		Operation(returnTypeAndParameterTypes.asTaggable);

	DynCallType returnType() scope =>
		returnTypeAndParameterTypes[0];

	DynCallType[] parameterTypes() return scope =>
		returnTypeAndParameterTypes[1 .. $];
}

pure size_t countParameterEntries(in DynCallSig a) =>
	sum!DynCallType(a.parameterTypes, (in DynCallType x) =>
		sizeWords(x));

// Declaring this here since 'dyncall.d' is excluded from WASM builds
extern(C) struct DCaggr;

immutable struct DynCallType {
	immutable struct Pointer {}
	immutable struct Aggregate {
		size_t sizeWords;
		// This is a DCaggr, but avoiding the dependency on dyncall here
		DCaggr* dcAggr;
	}
	mixin TaggedUnion!(PrimitiveType, Pointer, Aggregate*);

	@safe @nogc pure nothrow:

	static DynCallType pointer() =>
		DynCallType(DynCallType.Pointer());
}

pure size_t sizeWords(in DynCallType a) =>
	a.matchIn!size_t(
		(in PrimitiveType x) {
			final switch (x) {
				case PrimitiveType.bool_:
				case PrimitiveType.char8:
				case PrimitiveType.char32:
				case PrimitiveType.float32:
				case PrimitiveType.float64:
				case PrimitiveType.int8:
				case PrimitiveType.int16:
				case PrimitiveType.int32:
				case PrimitiveType.int64:
				case PrimitiveType.nat8:
				case PrimitiveType.nat16:
				case PrimitiveType.nat32:
				case PrimitiveType.nat64:
					return 1;
				case PrimitiveType.void_:
					return 0;
			}
		},
		(in DynCallType.Pointer) =>
			1,
		(in DynCallType.Aggregate x) =>
			x.sizeWords);
