module frontend.allInsts;

@safe @nogc pure nothrow:

import model.model :
	Called,
	CalledSpecSig,
	FunDecl,
	FunInst,
	isFuture,
	isMutArray,
	LinkageRange,
	Module,
	PurityRange,
	ReturnAndParamTypes,
	SpecDecl,
	SpecImpls,
	SpecInst,
	StructDecl,
	StructInst,
	Type,
	TypeArgs;
import util.alloc.alloc : Alloc, free;
import util.col.array : arraysEqual, copyArray;
import util.col.hashTable :
	getOrAdd, getOrAddAndDidAdd, hashTableToArray, mayDeleteValue, MutHashTable, size, ValueAndDidAdd;
import util.col.map : Map;
import util.col.mutMap : getOrAdd, getOrAddAndDidAdd, keys, moveToMap, mustAdd, mustGet, MutMap;
import util.col.mutMaxSet : has, mayAdd, mustAdd, MutMaxSet, popArbitrary;
import util.col.mutMultiMap : add, countKeys, countPairs, mayDeleteKey, mayDeletePair, MutMultiMap;
import util.hash : HashCode, hashTaggedPointer, hashPointerAndTaggedPointers, hashPointerAndTaggedPointersX2;
import util.json : field, Json, jsonObject;
import util.memory : allocate;
import util.opt : force, has, MutOpt;
import util.union_ : TaggedUnion;

struct AllInsts {
	@safe @nogc pure nothrow:
	private:
	Alloc* allocPtr;

	MutHashTable!(StructInst*, StructArgs, getStructArgs) structInsts;
	MutHashTable!(SpecInst*, SpecArgs, getSpecArgs) specInsts;
	MutHashTable!(FunInst*, FunArgs, getFunArgs) funInsts;
	MutMultiMap!(AnyDeclOrInst, AnyInst) referencedBy;

	public ref inout(Alloc) alloc() return scope inout =>
		*allocPtr;
}

Json perfStats(ref Alloc alloc, in AllInsts a) =>
	jsonObject(alloc, [
		field!"structInsts"(size(a.structInsts)),
		field!"specInsts"(size(a.specInsts)),
		field!"funInsts"(size(a.funInsts)),
		field!"refKeys"(countKeys(a.referencedBy)),
		field!"refPairs"(countPairs(a.referencedBy))]);

ValueAndDidAdd!(StructInst*) getOrAddStructInst(ref AllInsts a, StructDecl* decl, in TypeArgs typeArgs) =>
	getOrAddAndDidAdd!(StructInst*, StructArgs, getStructArgs)(a.alloc, a.structInsts, StructArgs(decl, typeArgs), () {
		StructInst* res = allocate(a.alloc, StructInst(decl, copyArray!Type(a.alloc, typeArgs)));
		addEachReferenced(a, res);
		return res;
	});

ValueAndDidAdd!(SpecInst*) getOrAddSpecInst(ref AllInsts a, SpecDecl* decl, in TypeArgs typeArgs) =>
	getOrAddAndDidAdd(a.alloc, a.specInsts, SpecArgs(decl, typeArgs), () {
		SpecInst* res = allocate(a.alloc, SpecInst(decl, copyArray!Type(a.alloc, typeArgs)));
		addEachReferenced(a, res);
		return res;
	});

FunInst* getOrAddFunInst(
	ref AllInsts a,
	FunDecl* decl,
	in TypeArgs typeArgs,
	in SpecImpls specImpls,
	in ReturnAndParamTypes delegate() @safe @nogc pure nothrow cbReturnAndParamTypes,
) =>
	getOrAdd(a.alloc, a.funInsts, FunArgs(decl, typeArgs, specImpls), () {
		FunInst* res = allocate(a.alloc, FunInst(
			decl, copyArray!Type(a.alloc, typeArgs), copyArray!Called(a.alloc, specImpls), cbReturnAndParamTypes()));
		addEachReferenced(a, res);
		return res;
	});

// Free all instantiations of structs/specs/funs from the module, as well as anything referencing them.
void freeInstantiationsForModule(ref AllInsts a, in Module module_) {
	ToProcess toProcess;
	// Done processing these, will free at the end.
	getInstsToProcessFromModule(a, toProcess, module_);
	Processed processed;
	while (true) {
		MutOpt!AnyInst opt = popArbitrary(toProcess);
		if (has(opt)) {
			AnyInst inst = force(opt);
			mustAdd(processed, inst);
			deleteAnyInstFromTable(a, inst);
			mayDeleteKey(a.referencedBy, inst.asVoidPointer, (AnyInst reference) {
				if (!has(processed, reference))
					mayAdd(toProcess, reference);
			});
			eachReferenced(inst, (AnyDeclOrInst x) {
				mayDeletePair(a.referencedBy, x, inst);
			});
		} else
			break;
	}

	foreach (AnyInst inst; processed) {
		() @trusted	 {
			freeAnyInst(a.alloc, inst);
		}();
	}
}

immutable struct AllInstsArrays {
	StructInst*[] structs;
	SpecInst*[] specs;
	FunInst*[] funs;
}
AllInstsArrays TEST_getAllInstsArrays(ref Alloc alloc, in AllInsts a) =>
	AllInstsArrays(
		hashTableToArray(alloc, a.structInsts),
		hashTableToArray(alloc, a.specInsts),
		hashTableToArray(alloc, a.funInsts));

const(MutMultiMap!(AnyDeclOrInst, AnyInst)) TEST_getReferencedBy(ref const AllInsts a) =>
	a.referencedBy;

Map!(StructInst*, StructInst*) getAllFutureAndMutArrayImpls(
	ref Alloc alloc,
	ref const AllInsts a,
	in StructInst* delegate(TypeArgs) @safe @nogc pure nothrow cbMakeFutureImpl,
	in StructInst* delegate(TypeArgs) @safe @nogc pure nothrow cbMakeMutArrayImpl,
) {
	MutMap!(StructInst*, StructInst*) res;
	foreach (ref const StructInst* x; a.structInsts)
		if (isFuture(*x) || isMutArray(*x))
			mustAdd(alloc, res, x, null);
	foreach (ref const StructInst* x; keys(res))
		mustGet(res, x) = isFuture(*x)
			? cbMakeFutureImpl(x.typeArgs)
			: isMutArray(*x)
			? cbMakeMutArrayImpl(x.typeArgs)
			: assert(false);
	return moveToMap(alloc, res);
}

private:

alias ToProcess = MutMaxSet!(0x4000, AnyInst);
alias Processed = MutMaxSet!(0x4000, AnyInst);

// public for tests
public alias AnyDeclOrInst = immutable void*;

// public for tests
public immutable struct AnyInst {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(StructInst*, SpecInst*, FunInst*);
	HashCode hash() scope =>
		hashTaggedPointer!AnyInst(this);
}
static assert(MutOpt!AnyInst.sizeof == ulong.sizeof); // Used by MutMaxSet

void getInstsToProcessFromModule(ref AllInsts a, ref ToProcess out_, in Module module_) {
	getInstsToProcessFromDecls!StructDecl(a, out_, module_.structs);
	getInstsToProcessFromDecls!SpecDecl(a, out_, module_.specs);
	getInstsToProcessFromDecls!FunDecl(a, out_, module_.funs);
}

void getInstsToProcessFromDecls(Decl)(ref AllInsts a, ref ToProcess out_, in Decl[] decls) {
	foreach (ref Decl decl; decls)
		mayDeleteKey!(AnyDeclOrInst, AnyInst)(a.referencedBy, &decl, (AnyInst inst) {
			mustAdd(out_, inst);
		});
}

void deleteAnyInstFromTable(scope ref AllInsts a, AnyInst inst) {
	inst.matchWithPointers!void(
		(StructInst* x) {
			mayDeleteValue(a.structInsts, x);
		},
		(SpecInst* x) {
			mayDeleteValue(a.specInsts, x);
		},
		(FunInst* x) {
			mayDeleteValue(a.funInsts, x);
		});
}

@system void freeAnyInst(ref Alloc alloc, AnyInst inst) {
	inst.matchWithPointers!void(
		(StructInst* x) @trusted {
			free(alloc, x);
		},
		(SpecInst* x) @trusted {
			free(alloc, x);
		},
		(FunInst* x) @trusted {
			free(alloc, x);
		});
}

void addEachReferenced(T)(ref AllInsts a, T* referenced) {
	eachReferenced(*referenced, (AnyDeclOrInst x) {
		add!(AnyDeclOrInst, AnyInst)(a.alloc, a.referencedBy, x, AnyInst(referenced));
	});
}

alias ReferenceCb = void delegate(AnyDeclOrInst) @safe @nogc pure nothrow;
/*
We're not concerned about references in the *body* of the struct/spec/fun here, only type/spec arguments.
We're concerned about the case where a module is freed, but another module *not dependent on it* was not freed,
but a struct/spec/fun from that other module has an *instantiation* referencing the freed module.
The *body* of a struct/spec/fun can't reference something in a module it doesn't depend on,
except through a type arg or spec impl.

(In addition, we use this same table to track all insts for a given decl.)

(SO TODO: As an optimization, we could avoid adding a reference A -> B to referencedBy
if the module of 'A' depends on the module of 'B'.)
*/
void eachReferenced(in AnyInst referencer, in ReferenceCb cb) {
	referencer.matchIn!void(
		(in StructInst x) {
			eachReferenced(x, cb);
		},
		(in SpecInst x) {
			eachReferenced(x, cb);
		},
		(in FunInst x) {
			eachReferenced(x, cb);
		});
}
void eachReferenced(in StructInst x, in ReferenceCb cb) {
	cb(x.decl);
	eachReferenceInTypeArgs(x.typeArgs, cb);
}
void eachReferenced(in SpecInst x, in ReferenceCb cb) {
	cb(x.decl);
	eachReferenceInTypeArgs(x.typeArgs, cb);
}
void eachReferenced(in FunInst x, in ReferenceCb cb) {
	cb(x.decl);
	eachReferenceInTypeArgs(x.typeArgs, cb);
	eachReferenceInSpecImpls(x.specImpls, cb);
}

void eachReferenceInTypeArgs(in TypeArgs typeArgs, in ReferenceCb cb) {
	foreach (Type x; typeArgs)
		eachReferenceInType(x, cb);
}

void eachReferenceInType(in Type type, in ReferenceCb cb) {
	if (type.isA!(StructInst*))
		cb(type.as!(StructInst*));
}

void eachReferenceInSpecImpls(in SpecImpls specImpls, in ReferenceCb cb) {
	foreach (Called called; specImpls)
		called.matchWithPointers!void(
			(Called.Bogus* x) {
				eachReferenceInType(x.returnType, cb);
				foreach (Type t; x.paramTypes)
					eachReferenceInType(t, cb);
			},
			(FunInst* x) {
				cb(x);
			},
			(CalledSpecSig x) {
				cb(x.specInst);
			});
}

immutable struct StructArgs {
	@safe @nogc pure nothrow:
	StructDecl* decl;
	TypeArgs typeArgs;
	bool opEquals(in StructArgs b) scope =>
		decl == b.decl && arraysEqual!Type(typeArgs, b.typeArgs);
	HashCode hash() scope =>
		hashPointerAndTaggedPointers!(StructDecl, Type)(decl, typeArgs);
}
StructArgs getStructArgs(in StructInst* a) =>
	StructArgs(a.decl, a.typeArgs);

immutable struct SpecArgs {
	@safe @nogc pure nothrow:
	SpecDecl* decl;
	TypeArgs typeArgs;
	bool opEquals(in SpecArgs b) scope =>
		decl == b.decl && arraysEqual!Type(typeArgs, b.typeArgs);
	HashCode hash() scope =>
		hashPointerAndTaggedPointers!(SpecDecl, Type)(decl, typeArgs);
}
SpecArgs getSpecArgs(in SpecInst* a) =>
	SpecArgs(a.decl, a.typeArgs);

immutable struct FunArgs {
	@safe @nogc pure nothrow:
	FunDecl* decl;
	TypeArgs typeArgs;
	SpecImpls specImpls;
	bool opEquals(in FunArgs b) scope =>
		decl == b.decl && arraysEqual!Type(typeArgs, b.typeArgs) && arraysEqual!Called(specImpls, b.specImpls);
	HashCode hash() scope =>
		hashPointerAndTaggedPointersX2!(FunDecl, Type, Called)(decl, typeArgs, specImpls);
}
FunArgs getFunArgs(in FunInst* a) =>
	FunArgs(a.decl, a.typeArgs, a.specImpls);
