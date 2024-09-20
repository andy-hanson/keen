module frontend.check.instantiate;

@safe @nogc pure nothrow:

import frontend.allInsts :
	getAllFutureAndMutArrayImpls, getOrAddFunInst, getOrAddSpecInst, getOrAddStructInst, AllInsts;
import model.model :
	BuiltinType,
	CommonTypes,
	Destructure,
	combineLinkageRange,
	combinePurityRange,
	FunDecl,
	FunInst,
	isOptionType,
	Linkage,
	LinkageRange,
	linkageRange,
	paramsArray,
	Purity,
	PurityRange,
	purityRange,
	RecordField,
	ReturnAndParamTypes,
	SpecDecl,
	Signature,
	SpecImpls,
	SpecInst,
	SpecInstBody,
	StructBody,
	StructDecl,
	StructInst,
	Type,
	TypeArgs,
	TypeParamIndex,
	UnionMember;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withMapToStackArray, withStackArray;
import util.col.array : emptySmallArray, fold, map, small, SmallArray, sum;
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
alias DelayStructInsts = MutArrWithAlloc!(StructInst*);
alias MayDelayStructInsts = MutOpt!(DelayStructInsts*);
MayDelayStructInsts noDelayStructInsts() =>
	noneMut!(DelayStructInsts*);

private Type instantiateType(
	InstantiateCtx ctx,
	Type type,
	in TypeArgs typeArgs,
	scope MayDelayStructInsts delayStructInsts,
) =>
	type.matchWithPointers!Type(
		(Type.Bogus _) =>
			Type.bogus,
		(TypeParamIndex x) =>
			typeArgs[x.index],
		(StructInst* x) =>
			Type(instantiateStructInst(ctx, *x, typeArgs, delayStructInsts)));

private Type instantiateTypeNoDelay(InstantiateCtx ctx, Type type, in TypeArgs typeArgs) =>
	instantiateType(ctx, type, typeArgs, noDelayStructInsts);

FunInst* instantiateFun(InstantiateCtx ctx, FunDecl* decl, in TypeArgs typeArgs, in SpecImpls specImpls) =>
	withMeasure!(FunInst*, () =>
		getOrAddFunInst(ctx.allInsts, decl, typeArgs, specImpls, () =>
			instantiateReturnAndParamTypes(ctx, decl.returnType, paramsArray(decl.params), typeArgs))
	)(ctx.perf, ctx.alloc, PerfMeasure.instantiateFun);

void instantiateStructTypes(InstantiateCtx ctx, StructInst* inst, scope MayDelayStructInsts delayStructInsts) {
	TypeArgs typeArgs = inst.typeArgs;
	inst.instantiatedTypes = inst.decl.body_.match!(SmallArray!Type)(
		(StructBody.Bogus) =>
			emptySmallArray!Type,
		(BuiltinType _) =>
			emptySmallArray!Type,
		(ref StructBody.Enum e) =>
			emptySmallArray!Type,
		(StructBody.Extern e) =>
			emptySmallArray!Type,
		(StructBody.Flags f) =>
			emptySmallArray!Type,
		(StructBody.Record r) =>
			map!(Type, RecordField)(ctx.alloc, r.fields, (ref RecordField field) =>
				instantiateType(ctx, field.type, typeArgs, delayStructInsts)),
		(ref StructBody.Union u) =>
			map!(Type, UnionMember)(ctx.alloc, u.members, (ref UnionMember member) =>
				instantiateType(ctx, member.type, typeArgs, delayStructInsts)),
		(StructBody.Variant x) =>
			buildSmallArrayExact!Type(
				ctx.alloc,
				sum!Signature(x.methods, (in Signature sig) => 1 + sig.params.length),
				(scope ref ExactSizeArrayBuilder!Type out_) {
					foreach (ref Signature sig; x.methods)
						instantiateReturnAndParamTypes(out_, ctx, sig.returnType, sig.params, typeArgs);
				}));
}

// Given a struct decl 'foo[t]', returns a 't foo'
StructInst* instantiateStructWithOwnTypeParams(InstantiateCtx ctx, StructDecl* decl) =>
	withStackArray(
		decl.typeParams.length,
		(size_t i) => Type(TypeParamIndex(safeToUint(i))),
		(scope Type[] typeArgs) =>
			instantiateStructNeverDelay(ctx, decl, typeArgs));

StructInst* instantiateStruct(
	InstantiateCtx ctx,
	StructDecl* decl,
	in TypeArgs typeArgs,
	scope MayDelayStructInsts delayStructInsts,
) =>
	withMeasure!(StructInst*, () {
		ValueAndDidAdd!(StructInst*) res = getOrAddStructInst(
			ctx.allInsts, decl, typeArgs,
			() => combinedLinkageRange(decl.linkage, typeArgs),
			() => combinedPurityRange(decl.purity, typeArgs));
		if (res.didAdd) {
			if (decl.bodyIsSet)
				instantiateStructTypes(ctx, res.value, delayStructInsts);
			else {
				// We should only need to do this in the initial phase of settings struct bodies,
				// which is when delayedStructInst is set.
				push(*force(delayStructInsts), res.value);
			}
		}
		return res.value;
	})(ctx.perf, ctx.alloc, PerfMeasure.instantiateStruct);

private LinkageRange combinedLinkageRange(Linkage declLinkage, in Type[] typeArgs) {
	final switch (declLinkage) {
		case Linkage.internal:
			return LinkageRange(Linkage.internal, Linkage.internal);
		case Linkage.extern_:
			return fold!(LinkageRange, Type)(
				LinkageRange(Linkage.extern_, Linkage.extern_),
				typeArgs,
				(LinkageRange cur, in Type typeArg) => combineLinkageRange(cur, linkageRange(typeArg)));
	}
}

private PurityRange combinedPurityRange(Purity declPurity, in Type[] typeArgs) =>
	fold!(PurityRange, Type)(PurityRange(declPurity, declPurity), typeArgs, (PurityRange cur, in Type typeArg) =>
		combinePurityRange(cur, purityRange(typeArg)));

private StructInst* instantiateStructInst(
	InstantiateCtx ctx,
	ref StructInst structInst,
	in TypeArgs typeArgs,
	scope MayDelayStructInsts delayStructInsts,
) =>
	withMapToStackArray!(StructInst*, Type, Type)(
		structInst.typeArgs,
		(ref Type x) => instantiateType(ctx, x, typeArgs, delayStructInsts),
		(scope Type[] itsTypeArgs) =>
			instantiateStruct(ctx, structInst.decl, small!Type(itsTypeArgs), delayStructInsts));

StructInst* instantiateStructNeverDelay(InstantiateCtx ctx, StructDecl* decl, in Type[] typeArgs) =>
	instantiateStruct(ctx, decl, small!Type(typeArgs), noDelayStructInsts);

StructInst* makeArrayType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type elementType) =>
	instantiateStructNeverDelay(ctx, commonTypes.array, [elementType]);

StructInst* makeOptionType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type innerType) =>
	instantiateStructNeverDelay(ctx, commonTypes.option, [innerType]);

Type makeOptionIfNotAlready(InstantiateCtx ctx, ref CommonTypes commonTypes, Type a) =>
	isOptionType(commonTypes, a) ? a : Type(makeOptionType(ctx, commonTypes, a));

StructInst* makeConstPointerType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type pointeeType) =>
	instantiateStructNeverDelay(ctx, commonTypes.pointerConst, [pointeeType]);

StructInst* makeMutPointerType(InstantiateCtx ctx, ref CommonTypes commonTypes, Type pointeeType) =>
	instantiateStructNeverDelay(ctx, commonTypes.pointerMut, [pointeeType]);

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
		(ref Type x) => instantiateType(ctx, x, typeArgs, noDelayStructInsts),
		(scope Type[] itsTypeArgs) => instantiateSpec(ctx, specInst.decl, small!Type(itsTypeArgs), delaySpecInsts));

Map!(StructInst*, StructInst*) getAllFutureAndMutArrayImpls(
	ref Alloc alloc,
	ref InstantiateCtx ctx,
	StructDecl* futureImpl,
	StructDecl* mutArrayImpl,
) =>
	.getAllFutureAndMutArrayImpls(
		alloc, ctx.allInsts,
		(TypeArgs typeArgs) => instantiateStructNeverDelay(ctx, futureImpl, typeArgs),
		(TypeArgs typeArgs) => instantiateStructNeverDelay(ctx, mutArrayImpl, typeArgs));

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
	out_ ~= instantiateTypeNoDelay(ctx, declReturnType, typeArgs);
	foreach (ref Destructure param; declParams)
		out_ ~= instantiateTypeNoDelay(ctx, param.type, typeArgs);
}
