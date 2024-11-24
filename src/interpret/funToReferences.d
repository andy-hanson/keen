module interpret.funToReferences;

@safe @nogc pure nothrow:

import interpret.bytecode : ByteCodeIndex, TextIndex;
import interpret.extern_ : DynCallSig;
import model.lowModel : LowFunIndex, LowFunPointerTypeIndex;
import util.alloc.alloc : TempAlloc;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.col.fullIndexMap : FullIndexMap, fullIndexMapEach_const, makeFullIndexMap_mut;
import util.memory : allocate;
import util.opt : force, has, MutOpt, none, some, someMut;
import util.util : castNonScope_ref;

struct FunToReferences {
	immutable FunPointerTypeToDynCallSig funPtrTypeToDynCallSig;
	private:
	FullIndexMap!(LowFunIndex, FunReferencesBuilder) inner;
}

alias FunPointerTypeToDynCallSig = immutable FullIndexMap!(LowFunPointerTypeIndex, DynCallSig);

void eachFunPointer(
	in FunToReferences a,
	in void delegate(LowFunIndex, DynCallSig) @safe @nogc pure nothrow cb,
) {
	fullIndexMapEach_const!(LowFunIndex, FunReferencesBuilder)(
		a.inner,
		(LowFunIndex index, ref const FunReferencesBuilder b) {
			if (has(b.ptrRefs))
				cb(index, force(b.ptrRefs).sig);
		});
}

immutable struct FunReferences {
	ByteCodeIndex[] calls;
	MutOpt!FunPointerReferences ptrRefs;
}
immutable struct FunPointerReferences {
	DynCallSig sig;
	ByteCodeIndex[] funPtrRefs;
	TextIndex[] textRefs;
}

FunToReferences initFunToReferences(
	ref TempAlloc tempAlloc,
	return scope FunPointerTypeToDynCallSig funPtrTypeToDynCallSig,
	size_t nLowFuns,
) =>
	FunToReferences(
		funPtrTypeToDynCallSig,
		makeFullIndexMap_mut!(LowFunIndex, FunReferencesBuilder)(tempAlloc, nLowFuns, (LowFunIndex _) =>
			FunReferencesBuilder()));

FunReferences finishAt(ref TempAlloc tempAlloc, ref FunToReferences a, LowFunIndex index) {
	ref FunReferencesBuilder builder() { return a.inner[index]; }
	ByteCodeIndex[] calls = finish(tempAlloc, builder.calls);
	if (has(builder.ptrRefs)) {
		FunPointerReferencesBuilder* ptrs = force(builder.ptrRefs);
		return FunReferences(
			calls,
			some(FunPointerReferences(
				ptrs.sig,
				finish(tempAlloc, ptrs.funPtrRefs),
				finish(tempAlloc, ptrs.textReferences))));
	} else
		return FunReferences(calls, none!FunPointerReferences);
}

void registerCall(ref TempAlloc tempAlloc, ref FunToReferences a, LowFunIndex callee, ByteCodeIndex caller) {
	add(tempAlloc, a.inner[callee].calls, caller);
}

void registerTextReference(
	ref TempAlloc tempAlloc,
	ref FunToReferences a,
	LowFunPointerTypeIndex type,
	LowFunIndex fun,
	TextIndex reference,
) {
	add(tempAlloc, funPointerReferences(tempAlloc, a, type, fun).textReferences, reference);
}

void registerFunPointerReference(
	ref TempAlloc tempAlloc,
	scope ref FunToReferences a,
	in LowFunPointerTypeIndex type,
	LowFunIndex fun,
	ByteCodeIndex reference,
) {
	add(tempAlloc, funPointerReferences(tempAlloc, a, type, fun).funPtrRefs, reference);
}

private:

ref FunPointerReferencesBuilder funPointerReferences(
	ref TempAlloc tempAlloc,
	return scope ref FunToReferences a,
	in LowFunPointerTypeIndex type,
	LowFunIndex fun,
) {
	if (!has(a.inner[fun].ptrRefs))
		a.inner[fun].ptrRefs = someMut(allocate(tempAlloc, FunPointerReferencesBuilder(
			castNonScope_ref(a).funPtrTypeToDynCallSig[type])));
	return *force(a.inner[fun].ptrRefs);
}

struct FunReferencesBuilder {
	ArrayBuilder!ByteCodeIndex calls;
	MutOpt!(FunPointerReferencesBuilder*) ptrRefs;
}

struct FunPointerReferencesBuilder {
	immutable DynCallSig sig;
	ArrayBuilder!ByteCodeIndex funPtrRefs; // appearing as a fun-pointer directly in code
	ArrayBuilder!TextIndex textReferences; // these are fun ptrs too, that appear in text
}
