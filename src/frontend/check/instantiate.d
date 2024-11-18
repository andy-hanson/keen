module frontend.check.instantiate;

@safe @nogc pure nothrow:

import frontend.allInsts :
	getAllFutureAndMutArrayImpls, getOrAddFunInst, getOrAddSpecInst, getOrAddStructInst, AllInsts;
import model.model :
	CommonTypes,
	Destructure,
	FunDecl,
	FunInst,
	isOptionType,
	paramsArray,
	ReturnAndParamTypes,
	SpecDecl,
	Signature,
	SpecImpls,
	SpecInst,
	SpecInstBody,
	StructDecl,
	StructInst,
	Type,
	TypeArgs,
	TypeParamIndex;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withMapToStackArray, withStackArray;
import util.col.array : map, small;
import util.col.exactSizeArrayBuilder : buildSmallArrayExact, ExactSizeArrayBuilder;
import util.col.hashTable : ValueAndDidAdd;
import util.col.map : Map;
import util.col.mutArr : MutArrWithAlloc, push;
import util.conv : safeToUint;
import util.opt : force, MutOpt, noneMut;
import util.perf : Perf, PerfMeasure, withMeasure;

// This is a copyable type
struct InstantiateCtx {
	@safe @nogc pure nothrow:

	Perf* perfPtr;
	AllInsts* allInstsPtr;

	ref Perf perf() return scope =>
		*perfPtr;
	ref Alloc alloc() =>
		allInsts.alloc;
	ref AllInsts allInsts() return scope =>
		*allInstsPtr;
}

alias DelaySpecInsts = MutArrWithAlloc!(SpecInst*);
alias MayDelaySpecInsts = MutOpt!(DelaySpecInsts*); // delayed due to 'parents' referencing other specs
MayDelaySpecInsts noDelaySpecInsts() =>
	noneMut!(DelaySpecInsts*);

Type instantiateType(InstantiateCtx ctx, Type type, in TypeArgs typeArgs) =>
	type.matchWithPointers!Type(
		(Type.Bogus _) =>
			Type.bogus,
		(TypeParamIndex x) =>
			typeArgs[x.index],
		(StructInst* x) =>
			Type(instantiateStructInst(ctx, *x, typeArgs)));

FunInst* instantiateFun(InstantiateCtx ctx, FunDecl* decl, in TypeArgs typeArgs, in SpecImpls specImpls) =>
	withMeasure!(FunInst*, () =>
		getOrAddFunInst(ctx.allInsts, decl, typeArgs, specImpls, () =>
			instantiateReturnAndParamTypes(ctx, decl.returnType, paramsArray(decl.params), typeArgs))
	)(ctx.perf, ctx.alloc, PerfMeasure.instantiateFun);

// Given a struct decl 'foo[t]', returns a 't foo'
StructInst* instantiateStructWithOwnTypeParams(InstantiateCtx ctx, StructDecl* decl) =>
	withStackArray(
		decl.typeParams.length,
		(size_t i) =>
			Type(TypeParamIndex(safeToUint(i))),
		(scope Type[] typeArgs) =>
			instantiateStruct(ctx, decl, typeArgs));

SpecInst* instantiateSpecWithOwnTypeParams(InstantiateCtx ctx, SpecDecl* decl) =>
	withStackArray(
		decl.typeParams.length,
		(size_t i) =>
			Type(TypeParamIndex(safeToUint(i))),
		(scope Type[] typeArgs) =>
			instantiateSpec(ctx, decl, typeArgs));

StructInst* instantiateStruct(InstantiateCtx ctx, StructDecl* decl, in Type[] typeArgs) =>
	instantiateStruct(ctx, decl, small!Type(typeArgs));
StructInst* instantiateStruct(InstantiateCtx ctx, StructDecl* decl, in TypeArgs typeArgs) =>
	withMeasure!(StructInst*, () =>
		getOrAddStructInst(ctx.allInsts, decl, typeArgs).value
	)(ctx.perf, ctx.alloc, PerfMeasure.instantiateStruct);

StructInst* instantiateStructInst(InstantiateCtx ctx, ref StructInst structInst, in TypeArgs typeArgs) =>
	withMapToStackArray!(StructInst*, Type, Type)(
		structInst.typeArgs,
		(ref Type x) => instantiateType(ctx, x, typeArgs),
		(scope Type[] itsTypeArgs) =>
			instantiateStruct(ctx, structInst.decl, small!Type(itsTypeArgs)));

StructInst* makeArrayType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type elementType) =>
	instantiateStruct(ctx, commonTypes.array, [elementType]);

StructInst* makeOptionType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type innerType) =>
	instantiateStruct(ctx, commonTypes.option, [innerType]);

Type makeOptionIfNotAlready(InstantiateCtx ctx, ref CommonTypes commonTypes, Type a) =>
	isOptionType(a) ? a : Type(makeOptionType(ctx, commonTypes, a));

StructInst* makeConstPointerType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type pointeeType) =>
	instantiateStruct(ctx, commonTypes.pointerConst, [pointeeType]);

StructInst* makeMutPointerType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type pointeeType) =>
	instantiateStruct(ctx, commonTypes.pointerMut, [pointeeType]);

SpecInst* instantiateSpec(InstantiateCtx ctx, SpecDecl* decl, in Type[] typeArgs) =>
	instantiateSpec(ctx, decl, small!Type(typeArgs), noneMut!(DelaySpecInsts*));
SpecInst* instantiateSpec(
	InstantiateCtx ctx,
	SpecDecl* decl,
	in TypeArgs typeArgs,
	scope MayDelaySpecInsts delaySpecInsts,
) =>
	withMeasure!(SpecInst*, () {
		ValueAndDidAdd!(SpecInst*) res = getOrAddSpecInst(ctx.allInsts, decl, typeArgs);
		if (res.didAdd) {
			if (decl.bodyIsSet)
				instantiateSpecBody(ctx, res.value, delaySpecInsts);
			else
				push(*force(delaySpecInsts), res.value);
		}
		return res.value;
	})(ctx.perf, ctx.alloc, PerfMeasure.instantiateSpec);

void instantiateSpecBody(InstantiateCtx ctx, SpecInst* a, scope MayDelaySpecInsts delaySpecInsts) {
	a.body_ = SpecInstBody(
		map!(immutable SpecInst*, immutable SpecInst*)(
			ctx.alloc, a.decl.parents, (ref immutable SpecInst* parent) =>
				instantiateSpecInst(ctx, parent, a.typeArgs, delaySpecInsts)),
		map!(ReturnAndParamTypes, Signature)(ctx.alloc, a.decl.sigs, (ref Signature sig) =>
			instantiateReturnAndParamTypes(ctx, sig.returnType, sig.params, a.typeArgs)));
}

SpecInst* instantiateSpecInst(
	InstantiateCtx ctx,
	SpecInst* specInst,
	in TypeArgs typeArgs,
	scope MayDelaySpecInsts delaySpecInsts,
) =>
	withMapToStackArray!(SpecInst*, Type, Type)(
		specInst.typeArgs,
		(ref Type x) => instantiateType(ctx, x, typeArgs),
		(scope Type[] itsTypeArgs) => instantiateSpec(ctx, specInst.decl, small!Type(itsTypeArgs), delaySpecInsts));

Map!(StructInst*, StructInst*) getAllFutureAndMutArrayImpls(
	ref Alloc alloc,
	ref InstantiateCtx ctx,
	StructDecl* futureImpl,
	StructDecl* mutArrayImpl,
) =>
	.getAllFutureAndMutArrayImpls(
		alloc, ctx.allInsts,
		(TypeArgs typeArgs) => instantiateStruct(ctx, futureImpl, typeArgs),
		(TypeArgs typeArgs) => instantiateStruct(ctx, mutArrayImpl, typeArgs));

private:

ReturnAndParamTypes instantiateReturnAndParamTypes(
	InstantiateCtx ctx,
	Type declReturnType,
	Destructure[] declParams,
	in TypeArgs typeArgs,
) =>
	ReturnAndParamTypes(buildSmallArrayExact!Type(
		ctx.alloc, 1 + declParams.length,
		(scope ref ExactSizeArrayBuilder!Type out_) {
			instantiateReturnAndParamTypes(out_, ctx, declReturnType, declParams, typeArgs);
		}));

void instantiateReturnAndParamTypes(
	scope ref ExactSizeArrayBuilder!Type out_,
	InstantiateCtx ctx,
	Type declReturnType,
	Destructure[] declParams,
	in TypeArgs typeArgs,
) {
	out_ ~= instantiateType(ctx, declReturnType, typeArgs);
	foreach (ref Destructure param; declParams)
		out_ ~= instantiateType(ctx, param.type, typeArgs);
}
