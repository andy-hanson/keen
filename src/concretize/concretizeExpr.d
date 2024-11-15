module concretize.concretizeExpr;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : AllConstantsBuilder, getConstantArray, getConstantPointer;
import concretize.concretizeCtx :
	boolType,
	ConcreteLambdaImpl,
	concreteTypeFromClosure,
	ConcreteVariantMemberAndMethodImpls,
	ConcretizeCtx,
	concretizeLambdaParams,
	constantCString,
	constantSymbol,
	exceptionType,
	getConcreteType_fromConcretizeCtx = getConcreteType,
	getConcreteFunForLambda,
	getConcreteFun,
	getReferencedType,
	SpecsScope,
	specsScopeForFun,
	typeArgsScopeForFun,
	TypeArgsScope,
	variantMethodImplsInner,
	voidType,
	withConcreteTypes;
import concretize.constantsOrExprs : asConstantsOrExprs, ConstantsOrExprs;
import concretize.generate :
	genAnd,
	genBreak,
	genCall,
	genCallNoAllocArgs,
	genCallKindNoAllocArgs,
	genChar8Array,
	genChar32Array,
	genConstant,
	genContinue,
	genCreateRecord,
	genCreateUnion,
	genDoAndContinue,
	genDropThen,
	genError,
	genLet,
	genLocalGet,
	genLocalPointer,
	genLoop,
	genMatchEnumOrIntegral,
	genNone,
	genOr,
	genStringLiteral,
	genLocalSet,
	genParamGet,
	genRecordFieldGet,
	genRecordFieldPointer,
	genReferenceCreate, genReferenceRead, genReferenceWrite,
	genSome,
	genThrow,
	genThrowStringKind,
	genVoid,
	unwrapOptionType;
import model.concreteModel :
	arrayElementType,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteFunKey,
	ConcreteLocal,
	ConcreteLocalSource,
	ConcreteMutability,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructSource,
	ConcreteType,
	isBogus,
	isEmptyType,
	isSummon,
	isVariadic,
	isVoid,
	mustBeByVal,
	name,
	purity,
	returnType;
import model.constant : asBool, asNat64, Constant, constantBool, constantZero;
import model.model :
	AssertOrForbidExpr,
	BogusCallExpr,
	BogusExpr,
	BogusWrongTypeExpr,
	BuiltinBinary,
	BuiltinBinaryLazy,
	BuiltinFun,
	BuiltinUnary,
	Called,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	ClosureGetExpr,
	ClosureRef,
	ClosureReferenceKind,
	ClosureSetExpr,
	Condition,
	defaultAssertOrForbidMessage,
	Destructure,
	Expr,
	ExprAndType,
	ExternExpr,
	FinallyExpr,
	FunBody,
	FunInst,
	FunPointerExpr,
	IfExpr,
	LambdaExpr,
	LetExpr,
	LiteralExpr,
	LiteralStringLikeExpr,
	Local,
	LocalGetExpr,
	LocalMutability,
	LocalPointerExpr,
	LocalSetExpr,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopExpr,
	LoopWhileOrUntilExpr,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchUnionExpr,
	MatchVariantExpr,
	Purity,
	RecordFieldPointerExpr,
	SeqExpr,
	SpecInst,
	ThrowExpr,
	TrustedExpr,
	TryExpr,
	TryLetExpr,
	Type,
	TypedExpr,
	VariableRef,
	VariantAndMethodImpls;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withMapOrNoneToStackArray;
import util.col.array :
	indexOf,
	isEmpty,
	map,
	mapWithFirst,
	mapZip,
	mustFind,
	mustFindOnly,
	mustFindPointer,
	newArray,
	newSmallArray,
	only,
	only2,
	sizeEq,
	small,
	SmallArray;
import util.col.mutArr : findIndexOrPush, MutArr, mutArrSize, push;
import util.col.mutMap : mustGet;
import util.col.stackMap : StackMap, stackMapAdd, stackMapMustGet, withStackMap;
import util.integralValues : IntegralValue, IntegralValues, integralValuesRange, mapToIntegralValues;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some;
import util.sourceRange : Range, UriAndRange;
import util.symbol : symbol, symbolOfString;
import util.union_ : Union;
import util.uri : Uri;
import util.util : castNonScope_ref, ptrTrustMe;
import versionInfo : isVersion, VersionFun, VersionInfo;

ConcreteExpr concretizeFunBody(ref ConcretizeCtx ctx, ConcreteFun* cf, in Destructure[] params, ref Expr e) =>
	withConcretizeExprCtx(ctx, cf, (ref ConcretizeExprCtx exprCtx) =>
		withStackMap!(ConcreteExpr, Local*, LocalOrConstant)((ref Locals locals) {
			// Ignore closure param, which is never destructured.
			ConcreteLocal[] paramsToDestructure =
				cf.params[params.length + 1 == cf.params.length ? 1 : 0 .. $];
			return concretizeWithParamDestructures(exprCtx, cf.returnType, locals, params, paramsToDestructure, e);
		}));

Out withConcretizeExprCtx(Out)(
	ref ConcretizeCtx ctx,
	ConcreteFun* fun,
	in Out delegate(ref ConcretizeExprCtx) @safe @nogc pure nothrow cb,
) {
	ConcretizeExprCtx exprCtx = ConcretizeExprCtx(ptrTrustMe(ctx), fun);
	return cb(exprCtx);
}

ConcreteExpr concretizeBogus(ref ConcretizeExprCtx ctx, ConcreteType type, UriAndRange range) =>
	concretizeBogus(ctx.concretizeCtx, type, range);
ConcreteExpr concretizeBogus(ref ConcretizeCtx ctx, ConcreteType type, UriAndRange range) =>
	ConcreteExpr(type, range, concretizeBogusKind(ctx, range));
ConcreteExprKind concretizeBogusKind(ref ConcretizeCtx ctx, in UriAndRange range) =>
	genThrowStringKind(ctx, range, "Reached compile error");

private:

ConcreteExpr concretizeWithParamDestructures(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in Locals locals,
	in Destructure[] params,
	ConcreteLocal[] concreteParams,
	ref Expr expr,
) {
	assert(sizeEq(params, concreteParams));
	if (isEmpty(params))
		return concretizeExpr(ctx, type, locals, expr);
	else {
		ConcreteExpr rest(in Locals innerLocals) {
			return concretizeWithParamDestructures(
				ctx, type, innerLocals, params[1 .. $], concreteParams[1 .. $], expr);
		}
		return params[0].matchWithPointers!ConcreteExpr(
			(Destructure.Ignore*) =>
				rest(locals),
			(Local* local) =>
				rest(addLocal(locals, local, LocalOrConstant(&concreteParams[0]))),
			(Destructure.Split* x) =>
				concretizeWithDestructureSplit(
					ctx, type, toUriAndRange(ctx, params[0].range), locals, *x, &concreteParams[0],
					(in Locals innerLocals) => rest(innerLocals)));
	}
}

public struct ConcretizeExprCtx {
	@safe @nogc pure nothrow:

	ConcretizeCtx* concretizeCtxPtr;
	immutable ConcreteFun* curFun; // This is the ConcreteFun* for a lambda, not its containing fun.
	size_t nextLambdaIndex = 0;

	Uri curUri() scope const =>
		curFun.moduleUri;

	ref Alloc alloc() return scope =>
		concretizeCtx.alloc;

	ref inout(ConcretizeCtx) concretizeCtx() return scope inout =>
		*concretizeCtxPtr;

	ref ConcreteFun currentConcreteFun() return scope const =>
		*curFun;

	ref inout(AllConstantsBuilder) allConstants() return scope inout =>
		concretizeCtx.allConstants;
}

ConcreteType boolType(ref ConcretizeExprCtx ctx) =>
	.boolType(ctx.concretizeCtx);
ConcreteType voidType(ref ConcretizeExprCtx ctx) =>
	.voidType(ctx.concretizeCtx);

UriAndRange toUriAndRange(in ConcretizeExprCtx ctx, in Range a) =>
	UriAndRange(ctx.curUri, a);

immutable struct TypedConstant {
	ConcreteType type;
	Constant value;
}

immutable struct LocalOrConstant {
	mixin Union!(ConcreteLocal*, TypedConstant);
}

ConcreteType type(in LocalOrConstant a) =>
	a.matchIn!ConcreteType(
		(in ConcreteLocal x) =>
			x.type,
		(in TypedConstant x) =>
			x.type);

public ConcreteType getConcreteType(ref ConcretizeExprCtx ctx, Type t) =>
	getConcreteType_fromConcretizeCtx(ctx.concretizeCtx, t, typeScope(ctx));

TypeArgsScope typeScope(ref const ConcretizeExprCtx ctx) =>
	typeArgsScopeForFun(ctx.curFun);

SpecsScope specsScope(ref const ConcretizeExprCtx ctx) =>
	specsScopeForFun(ctx.curFun);

ConcreteExpr concretizeCall(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref CallExpr a,
) {
	Opt!BuiltinBinaryLazy binaryLazy = asBuiltinBinaryLazy(a.called);
	if (has(binaryLazy))
		return concretizeBuiltinBinaryLazy(ctx, type, range, locals, a.called.as!(FunInst*), force(binaryLazy), a.args);
	else {
		Opt!(ConcreteFun*) optConcreteCalled = getConcreteFunFromCalled(ctx, a.called);
		return !has(optConcreteCalled) || isBogus(force(optConcreteCalled).returnType)
			? concretizeBogus(ctx, type, range)
			: concretizeCallInner(ctx, type, range, locals, force(optConcreteCalled), a.args);
	}
}

Opt!BuiltinBinaryLazy asBuiltinBinaryLazy(Called a) {
	if (a.isA!(FunInst*)) {
		FunBody body_ = a.as!(FunInst*).decl.body_;
		return optIf(body_.isA!BuiltinFun && body_.as!BuiltinFun.isA!BuiltinBinaryLazy, () =>
			body_.as!BuiltinFun.as!BuiltinBinaryLazy);
	} else
		return none!BuiltinBinaryLazy;
}

ConcreteExpr concretizeCallInner(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ConcreteFun* concreteCalled,
	SmallArray!Expr args,
) {
	assert(concreteCalled.returnType == type);
	bool argsMayBeConstants =
		isEmpty(args) || (!isSummon(*concreteCalled) && purity(concreteCalled.returnType) == Purity.data);
	ConstantsOrExprs concreteArgs = () {
		if (isVariadic(*concreteCalled)) {
			ConcreteType arrayType = only(concreteCalled.params).type;
			ConcreteType elementType = arrayElementType(arrayType);
			return constantsOrExprsArr(
				ctx, range, arrayType,
				asConstantsOrExprsIf(ctx.alloc, argsMayBeConstants, map(ctx.alloc, args, (ref Expr arg) =>
					concretizeExpr(ctx, elementType, locals, arg))));
		} else
			return asConstantsOrExprsIf(
				ctx.alloc, argsMayBeConstants,
				mapZip!(ConcreteExpr, ConcreteLocal, Expr)(
					ctx.alloc, concreteCalled.params, args,
					(ref ConcreteLocal param, ref Expr arg) =>
						concretizeExpr(ctx, param.type, locals, arg)));
	}();
	ConcreteExprKind kind = concreteArgs.match!ConcreteExprKind(
		(Constant[] constants) {
			Opt!Constant constant = tryEvalConstant(*concreteCalled, constants, ctx.concretizeCtx.versionInfo);
			return has(constant)
				? ConcreteExprKind(force(constant))
				: genCallKindNoAllocArgs(concreteCalled, mapZip!(ConcreteExpr, ConcreteLocal, Constant)(
					ctx.alloc,
					concreteCalled.params,
					small!Constant(constants),
					(ref ConcreteLocal p, ref Constant x) =>
						ConcreteExpr(p.type, UriAndRange.empty, ConcreteExprKind(x))));
		},
		(ConcreteExpr[] exprs) =>
			genCallKindNoAllocArgs(concreteCalled, exprs));
	return ConcreteExpr(type, range, kind);
}

ConcreteExpr concretizeBuiltinBinaryLazy(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	FunInst* called,
	BuiltinBinaryLazy kind,
	Expr[] args,
) {
	assert(args.length == 2);
	ConcreteExpr arg0(ConcreteType argType = type) =>
		concretizeExpr(ctx, argType, locals, args[0]);
	ConcreteExpr arg1(ConcreteType argType = type) =>
		concretizeExpr(ctx, argType, locals, args[1]);
	final switch (kind) {
		case BuiltinBinaryLazy.boolAnd:
			return genAnd(ctx.concretizeCtx, range, arg0, arg1);
		case BuiltinBinaryLazy.boolOr:
			return genOr(ctx.concretizeCtx, range, arg0, arg1);
		case BuiltinBinaryLazy.optionOr:
			return genIfOption(ctx.alloc, range, arg0, RootLocalAndExpr(none!(ConcreteLocal*), arg0), arg1);
		case BuiltinBinaryLazy.optionQuestion2:
			ConcreteLocal* local = allocate(ctx.alloc,
				ConcreteLocal(ConcreteLocalSource(ConcreteLocalSource.Generated.member), type));
			ConcreteType optionType = getConcreteType(ctx, called.paramTypes[0]);
			assert(unwrapOptionType(ctx.concretizeCtx, optionType) == type);
			return genIfOption(
				ctx.alloc, range, arg0(optionType), RootLocalAndExpr(some(local), genLocalGet(range, local)), arg1);
	}
}

ConcreteExpr concretizeCallOption(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref CallOptionExpr a,
) {
	// `a?.b` ==> `x ?= a ? (x.b,) : ()`
	// But `x.b` may already be an option and might not need to be wrapped
	Opt!(ConcreteFun*) optCalled = getConcreteFunFromCalled(ctx, a.called);
	if (!has(optCalled) || isBogus(force(optCalled).returnType))
		return concretizeBogus(ctx, type, range);
	ConcreteFun* called = force(optCalled);

	ConcreteExpr option = concretizeExpr(ctx, locals, a.firstArg);
	ConcreteLocal* local = allocate(ctx.alloc, ConcreteLocal(
		ConcreteLocalSource(ConcreteLocalSource.Generated.destruct),
		called.params[0].type));
	assert(a.restArgs.length + 1 == called.params.length);
	SmallArray!ConcreteExpr allArgs = mapWithFirst!(ConcreteExpr, Expr)(
		ctx.alloc,
		genLocalGet(range, local),
		a.restArgs,
		(size_t i, ref Expr x) => concretizeExpr(ctx, called.params[i + 1].type, locals, x));
	ConcreteExpr call = genCallNoAllocArgs(range, called, allArgs);
	ConcreteExpr someCall = call.type == type ? call : genSome(ctx.concretizeCtx, type, range, call);
	assert(someCall.type == type);
	return genIfOption(
		ctx.alloc, range, option,
		RootLocalAndExpr(some(local), someCall),
		genNone(ctx.concretizeCtx, type, range));
}

ConstantsOrExprs asConstantsOrExprsIf(ref Alloc alloc, bool mayBeConstants, ConcreteExpr[] exprs) =>
	mayBeConstants
		? asConstantsOrExprs(alloc, exprs)
		: ConstantsOrExprs(exprs);

// TODO: this doesn't really belong in concretizeExpr either -------------------------------------------------------------------------
public Opt!(ConcreteFun*) getConcreteFunFromCalled(ref ConcretizeExprCtx ctx, Called called) =>
	getConcreteFunFromCalled(ctx.concretizeCtx, typeScope(ctx), specsScope(ctx), called);
public Opt!(ConcreteFun*) getConcreteFunFromCalled(
	ref ConcretizeCtx ctx,
	in TypeArgsScope typeScope,
	in SpecsScope specsScope,
	Called called,
) =>
	called.matchWithPointers!(Opt!(ConcreteFun*))(
		(Called.Bogus*) =>
			none!(ConcreteFun*),
		(FunInst* funInst) =>
			getConcreteFunFromFunInst(ctx, typeScope, specsScope, funInst),
		(CalledSpecSig specSig) =>
			some(getSpecSigImplementation(ctx, typeScope, specsScope, specSig)));

ConcreteFun* getSpecSigImplementation(
	in ConcretizeCtx ctx,
	in TypeArgsScope typeScope,
	in SpecsScope specsScope,
	CalledSpecSig specSig,
) {
	size_t index = 0;
	foreach (SpecInst* x; specsScope.specs)
		if (searchSpecSigIndexRecur(index, x, specSig.specInst))
			return specsScope.specImpls[index + specSig.sigIndex];
	assert(false);
}
bool searchSpecSigIndexRecur(ref size_t index, in SpecInst* inst, in SpecInst* search) {
	foreach (SpecInst* parent; inst.parents) {
		if (searchSpecSigIndexRecur(index, parent, search))
			return true;
	}
	if (inst == search)
		return true;
	index += inst.decl.sigs.length;
	return false;
}

Opt!(ConcreteFun*) getConcreteFunFromFunInst(
	ref ConcretizeCtx ctx,
	in TypeArgsScope typeScope,
	in SpecsScope specsScope,
	FunInst* funInst,
) =>
	withMapOrNoneToStackArray!(ConcreteFun*, immutable ConcreteFun*, Called)(
		funInst.specImpls,
		(ref Called x) => getConcreteFunFromCalled(ctx, typeScope, specsScope, x),
		(scope immutable ConcreteFun*[] specImpls) =>
			withConcreteTypes(ctx, funInst.typeArgs, typeScope, (scope ConcreteType[] typeArgs) =>
				getConcreteFun(ctx, funInst.decl, typeArgs, specImpls)));

ConcreteExpr concretizeClosureGet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in ClosureGetExpr a,
) {
	ClosureFieldInfo info = getClosureFieldInfo(ctx, range, a.closureRef);
	ConcreteExpr getField = getClosureField(ctx, range, a.closureRef);
	final switch (info.referenceKind) {
		case ClosureReferenceKind.direct:
			assert(info.fieldType == info.referencedType);
			assert(info.fieldType == type);
			return getField;
		case ClosureReferenceKind.allocated:
			assert(info.referencedType == type);
			return genReferenceRead(ctx.concretizeCtx, range, getField);
	}
}

// This does not dereference it if allocated; 'concretizeClosureGet' does that.
ConcreteExpr getClosureField(ref ConcretizeExprCtx ctx, in UriAndRange range, in ClosureRef a) {
	ClosureFieldInfo info = getClosureFieldInfo(ctx, range, a);
	return genRecordFieldGet(
		info.fieldType, range, allocate(ctx.alloc, genParamGet(range, info.closureParam)), info.fieldIndex);
}

ConcreteExpr concretizeClosureSet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	in ClosureSetExpr a,
) {
	assert(a.closureRef.closureReferenceKind == ClosureReferenceKind.allocated);
	ClosureFieldInfo info = getClosureFieldInfo(ctx, range, a.closureRef);
	assert(info.referenceKind == ClosureReferenceKind.allocated);
	ConcreteExpr field = getClosureField(ctx, range, a.closureRef);
	ConcreteExpr value = concretizeExpr(ctx, info.referencedType, locals, *a.value);
	assert(isVoid(type));
	return genReferenceWrite(ctx.concretizeCtx, range, field, value);
}

immutable struct ClosureFieldInfo {
	ConcreteLocal* closureParam;
	uint fieldIndex;
	ConcreteType fieldType; // This may be wrapped in a 'reference'.
	ConcreteType referencedType; // If field is a reference, this is the type of its value.
	ClosureReferenceKind referenceKind;
}
ClosureFieldInfo getClosureFieldInfo(ref ConcretizeExprCtx ctx, in UriAndRange range, in ClosureRef a) {
	ConcreteLocal* closureParam = &ctx.currentConcreteFun.params[0];
	ConcreteType closureType = closureParam.type;
	ConcreteStructBody.Record record = closureType.struct_.body_.as!(ConcreteStructBody.Record);
	ClosureReferenceKind referenceKind = a.closureReferenceKind;
	ConcreteType fieldType = record.fields[a.index].type;
	ConcreteType pointeeType = () {
		final switch (referenceKind) {
			case ClosureReferenceKind.direct:
				return fieldType;
			case ClosureReferenceKind.allocated:
				return getReferencedType(ctx.concretizeCtx, fieldType);
		}
	}();
	return ClosureFieldInfo(closureParam, a.index, fieldType, pointeeType, referenceKind);
}

SmallArray!ConcreteField concretizeClosureFields(ref ConcretizeExprCtx ctx, SmallArray!VariableRef closure) =>
	map!(ConcreteField, VariableRef)(ctx.alloc, closure, (ref VariableRef x) {
		ConcreteType baseType = getConcreteType(ctx, x.type);
		ConcreteType type = () {
			final switch (x.closureReferenceKind) {
				case ClosureReferenceKind.direct:
					return baseType;
				case ClosureReferenceKind.allocated:
					return getConcreteType(
						ctx, Type(x.local.mutability.as!(LocalMutability.MutableAllocated).referenceType));
			}
		}();
		// Even if the variable is mutable, it's a const field holding a mut pointer
		return ConcreteField(x.name, ConcreteMutability.const_, type);
	});

ConcreteExpr concretizeFunPointer(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	FunPointerExpr a,
) {
	Opt!(ConcreteFun*) called = getConcreteFunFromCalled(ctx, a.called);
	return has(called)
		? ConcreteExpr(type, range, ConcreteExprKind(Constant(Constant.FunPointer(force(called)))))
		: concretizeBogus(ctx, type, range);
}

ConcreteExpr concretizeLambda(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	LambdaExpr* e,
) {
	if (e.kind == LambdaExpr.Kind.explicitShared) {
		ConcreteType innerType = getConcreteType(ctx, Type(force(e.mutTypeForExplicitShared)));
		ConcreteExpr inner = concretizeLambdaInner(ctx, innerType, range, locals, e);
		ConcreteType[2] lambdaTypeArgs = only2(innerType.struct_.source.as!(ConcreteStructSource.Inst).typeArgs);
		ConcreteFun* sharedOfMutLambda = getConcreteFun(
			ctx.concretizeCtx, ctx.concretizeCtx.program.commonFuns.sharedOfMutLambda, lambdaTypeArgs, []);
		return genCall(ctx.alloc, range, sharedOfMutLambda, [inner]);
	} else
		return concretizeLambdaInner(ctx, type, range, locals, e);
}

ConcreteExpr concretizeLambdaInner(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	LambdaExpr* e,
) {
	// TODO: handle constants in closure
	// (do *not* include in the closure type, instead remember them for when compiling the lambda fn)

	size_t lambdaIndex = ctx.nextLambdaIndex;
	ctx.nextLambdaIndex++;

	SmallArray!ConcreteField closureFields = concretizeClosureFields(ctx, e.closure);
	ConcreteType closureType = concreteTypeFromClosure(
		ctx.concretizeCtx,
		closureFields,
		ConcreteStructSource(ConcreteStructSource.Lambda(ctx.curFun, lambdaIndex)));
	SmallArray!ConcreteLocal params = concretizeLambdaParams(ctx.concretizeCtx, closureType, e.param, typeScope(ctx));

	ConcreteStruct* lambdaStruct = mustBeByVal(type);

	ConcreteExpr[] closureArgs = map(ctx.alloc, e.closure, (ref VariableRef x) =>
		concretizeVariableRefForClosure(ctx, range, locals, x));
	ConcreteExpr closure = isEmpty(closureArgs)
		? genVoid(ctx.concretizeCtx, range)
		: genCreateRecord(closureType, range, closureArgs);

	ConcreteType returnType = getConcreteType(ctx, e.returnType);
	if (isBogus(returnType))
		return concretizeBogus(ctx, type, range);

	ConcreteFun* fun = getConcreteFunForLambda(
		ctx.concretizeCtx,
		ctx.curFun,
		lambdaIndex,
		returnType,
		e.param,
		params,
		&e.body_());
	ConcreteLambdaImpl impl = ConcreteLambdaImpl(closureType, fun);
	return genCreateUnion(ctx.alloc, type, range, nextLambdaImplId(ctx.concretizeCtx, lambdaStruct, impl), closure);
}

size_t nextLambdaImplId(ref ConcretizeCtx ctx, ConcreteStruct* lambdaStruct, ConcreteLambdaImpl impl) =>
	nextLambdaImplIdInner(ctx.alloc, impl, mustGet(ctx.lambdaStructToImpls, lambdaStruct));
size_t nextLambdaImplIdInner(ref Alloc alloc, ConcreteLambdaImpl impl, ref MutArr!ConcreteLambdaImpl impls) {
	size_t res = mutArrSize(impls);
	push(alloc, impls, impl);
	return res;
}

// TODO: this doesn't really belong in concretizeExpr ............................................................................... put near variantMethodImplsInner?
public size_t ensureVariantMember(
	ref ConcretizeCtx ctx,
	ConcreteType variantType,
	ConcreteType memberType,
) {
	ref ConcreteStructBody.Union body_() => mustBeByVal(variantType).body_.as!(ConcreteStructBody.Union);
	return body_.hasMembers
		? force(indexOf!ConcreteType(body_.members, memberType))
		: findIndexOrPush!ConcreteVariantMemberAndMethodImpls(
			ctx.alloc,
			mustGet(ctx.variantStructToMembers, mustBeByVal(variantType)),
			(in ConcreteVariantMemberAndMethodImpls member) => member.memberType == memberType,
			() => ConcreteVariantMemberAndMethodImpls(memberType),
			(ref ConcreteVariantMemberAndMethodImpls x) {
				x.methodImpls = variantMethodImpls(ctx, variantType, memberType);
			});
}

SmallArray!(Opt!(ConcreteFun*)) variantMethodImpls( // NOTE: This is only for types with 'variant-member', not variant listed types.
	ref ConcretizeCtx ctx,
	ConcreteType variantType,
	ConcreteType memberType,
) {
	ConcreteStructSource.Inst variantSource = mustBeByVal(variantType).source.as!(ConcreteStructSource.Inst);
	ConcreteStructSource.Inst memberSource = memberType.struct_.source.as!(ConcreteStructSource.Inst);
	VariantAndMethodImpls variantMember = mustFindOnly!VariantAndMethodImpls(
		memberSource.decl.variants, (ref VariantAndMethodImpls x) =>
			x.variant.decl == variantSource.decl);
	return variantMethodImplsInner(ctx, variantMember.methodImpls, memberSource.typeArgs);
}

alias Locals = StackMap!(Local*, LocalOrConstant);
alias addLocal = stackMapAdd!(Local*, LocalOrConstant);
alias getLocal = stackMapMustGet!(Local*, LocalOrConstant);

ConcreteExpr concretizeLet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref LetExpr e,
) {
	ConcreteType localType = getConcreteType(ctx, e.destructure.type);
	return concretizeWithDestructureAndLet(
		ctx, type, range, locals, e.destructure,
		concretizeExpr(ctx, localType, locals, e.value),
		(in Locals innerLocals) =>
			concretizeExpr(ctx, type, innerLocals, e.then));
}

RootLocalAndExpr concretizeExprWithDestructure(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref Destructure destructure,
	ref Expr expr,
) =>
	concretizeWithDestructure(ctx, type, range, locals, destructure, (in Locals innerLocals) =>
		concretizeExpr(ctx, type, innerLocals, expr));

struct RootLocalAndExpr {
	Opt!(ConcreteLocal*) rootLocal;
	ConcreteExpr expr;
}

ConcreteExpr concretizeWithDestructureAndLet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref Destructure destructure,
	ConcreteExpr value,
	in ConcreteExpr delegate(in Locals) @safe @nogc pure nothrow cb,
) {
	RootLocalAndExpr then = concretizeWithDestructure(ctx, type, range, locals, destructure, cb);
	return has(then.rootLocal)
		? genLet(ctx.alloc, type, range, force(then.rootLocal), value, then.expr)
		: value.kind.isA!Constant
		? then.expr
		: genDropThen(ctx.concretizeCtx, range, value, then.expr);
}

RootLocalAndExpr concretizeWithDestructure(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref Destructure destructure,
	in ConcreteExpr delegate(in Locals) @safe @nogc pure nothrow cb,
) =>
	destructure.matchWithPointers!RootLocalAndExpr(
		(Destructure.Ignore*) {
			ConcreteExpr then = cb(locals);
			return RootLocalAndExpr(none!(ConcreteLocal*), then);
		},
		(Local* local) {
			ConcreteLocal* rootLocal = allocate(ctx.alloc,
				ConcreteLocal(ConcreteLocalSource(local), getConcreteType(ctx, local.type)));
			ConcreteExpr expr = () {
				if (local.isAllocated) {
					ConcreteType referenceType = getConcreteType(
						ctx, Type(local.mutability.as!(LocalMutability.MutableAllocated).referenceType));
					ConcreteLocal* referenceLocal = allocate(ctx.alloc,
						ConcreteLocal(ConcreteLocalSource(ConcreteLocalSource.Generated.reference), referenceType));
					ConcreteExpr then = cb(addLocal(locals, local, LocalOrConstant(referenceLocal)));
					return genLet(
						ctx.alloc, type, range, referenceLocal,
						genReferenceCreate(ctx.concretizeCtx, referenceType, range, genLocalGet(range, rootLocal)),
						then);
				} else
					return cb(addLocal(locals, local, LocalOrConstant(rootLocal)));
			}();
			return RootLocalAndExpr(some(rootLocal), expr);
		},
		(Destructure.Split* x) {
			if (x.isValidDestructure(ctx.concretizeCtx.commonTypes)) {
				ConcreteLocal* temp = allocate(ctx.alloc, ConcreteLocal(
					ConcreteLocalSource(ConcreteLocalSource.Generated.destruct),
					getConcreteType(ctx, destructure.type)));
				return RootLocalAndExpr(
					some(temp),
					concretizeWithDestructureSplit(ctx, type, range, locals, *x, temp, cb));
			} else
				return RootLocalAndExpr(none!(ConcreteLocal*), concretizeBogus(ctx, type, range));
		});

ConcreteExpr concretizeWithDestructureSplit(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	in Destructure.Split split,
	ConcreteLocal* destructured,
	in ConcreteExpr delegate(in Locals) @safe @nogc pure nothrow cb,
) =>
	concretizeWithDestructurePartsRecur(
		ctx, type, locals, allocate(ctx.alloc, genLocalGet(range, destructured)), split.parts, 0, cb);
ConcreteExpr concretizeWithDestructurePartsRecur(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in Locals locals,
	ConcreteExpr* getTemp,
	in Destructure[] parts,
	size_t partIndex,
	in ConcreteExpr delegate(in Locals) @safe @nogc pure nothrow cb,
) {
	if (partIndex == parts.length)
		return cb(locals);
	else {
		Destructure part = parts[partIndex];
		UriAndRange range = toUriAndRange(ctx, part.range);
		ConcreteType valueType = mustBeByVal(getTemp.type).body_.as!(ConcreteStructBody.Record).fields[partIndex].type;
		ConcreteType expectedType = getConcreteType(ctx, part.type);
		if (expectedType == valueType) {
			ConcreteExpr value = ConcreteExpr(valueType, range, isVoid(valueType)
				? ConcreteExprKind(constantZero)
				: ConcreteExprKind(ConcreteExprKind.RecordFieldGet(getTemp, partIndex)));
			return concretizeWithDestructureAndLet(ctx, type, range, locals, part, value, (in Locals innerLocals) =>
				concretizeWithDestructurePartsRecur(ctx, type, innerLocals, getTemp, parts, partIndex + 1, cb));
		} else
			return concretizeBogus(ctx, type, range);
	}
}

ConcreteExpr concretizeIf(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref IfExpr a,
) =>
	a.condition.match!ConcreteExpr(
		(ref Expr x) {
			ConcreteExpr cond = concretizeExpr(ctx, boolType(ctx), locals, x);
			return cond.kind.isA!Constant
				? concretizeExpr(ctx, type, locals, asBool(cond.kind.as!Constant) ? a.trueBranch : a.falseBranch)
				: ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc,
					ConcreteExprKind.If(
						cond,
						concretizeExpr(ctx, type, locals, a.trueBranch),
						concretizeExpr(ctx, type, locals, a.falseBranch)))));
		},
		(ref Condition.UnpackOption x) =>
			genIfOption(
				ctx.alloc, range, concretizeExpr(ctx, locals, x.option),
				concretizeExprWithDestructure(ctx, type, range, locals, x.destructure, a.trueBranch),
				concretizeExpr(ctx, type, locals, a.falseBranch)));

ConcreteExpr genIfOption(
	ref Alloc alloc,
	in UriAndRange range,
	ConcreteExpr option,
	RootLocalAndExpr then,
	ConcreteExpr else_,
) =>
	ConcreteExpr(else_.type, range, ConcreteExprKind(
		allocate(alloc, ConcreteExprKind.MatchUnion(
			option,
			integralValuesRange(2),
			newSmallArray!(ConcreteExprKind.MatchUnion.Case)(alloc, [
				ConcreteExprKind.MatchUnion.Case(none!(ConcreteLocal*), else_),
				ConcreteExprKind.MatchUnion.Case(then.rootLocal, then.expr)]),
			none!(ConcreteExpr*)))));

ConcreteExpr concretizeLiteralStringLike(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	LiteralStringLikeExpr.Kind kind,
	string value,
) {
	final switch (kind) {
		case LiteralStringLikeExpr.Kind.char8Array:
			return genChar8Array(ctx.concretizeCtx, range, value);
		case LiteralStringLikeExpr.Kind.char32Array:
			return genChar32Array(ctx.concretizeCtx, range, value);
		case LiteralStringLikeExpr.Kind.cString:
			return ConcreteExpr(type, range, ConcreteExprKind(constantCString(ctx.concretizeCtx, value)));
		case LiteralStringLikeExpr.Kind.jsAny:
			assert(false);
		case LiteralStringLikeExpr.Kind.string_:
			return genStringLiteral(ctx.concretizeCtx, range, value);
		case LiteralStringLikeExpr.Kind.symbol:
			return ConcreteExpr(type, range, ConcreteExprKind(
				constantSymbol(ctx.concretizeCtx, symbolOfString(value))));
	}
}

ConcreteExpr concretizeLocalGet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	Local* local,
) {
	LocalOrConstant concrete = castNonScope_ref(getLocal(locals, local));
	return concrete.matchWithPointers!ConcreteExpr(
		(ConcreteLocal* x) {
			ConcreteExpr get = genLocalGet(range, x);
			return isBogus(x.type)
				? concretizeBogus(ctx, type, range)
				: local.isAllocated
				? genReferenceRead(ctx.concretizeCtx, range, get)
				: get;
		},
		(TypedConstant x) =>
			ConcreteExpr(type, range, ConcreteExprKind(x.value)));
}

ConcreteExpr concretizePtrToLocal(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	in LocalPointerExpr a,
) =>
	castNonScope_ref(getLocal(locals, a.local)).matchWithPointers!ConcreteExpr(
		(ConcreteLocal* local) =>
			a.local.isAllocated
				? genRecordFieldPointer(type, range, allocate(ctx.alloc, genLocalGet(range, local)), 0)
				: genLocalPointer(type, range, local),
		(TypedConstant x) =>
			//TODO: what if pointee is a reference?
			genConstant(type, range, getConstantPointer(ctx.alloc, ctx.allConstants, mustBeByVal(x.type), x.value)));

ConcreteExpr concretizeLocalSet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	LocalSetExpr a,
) {
	ConcreteLocal* local = getLocal(locals, a.local).as!(ConcreteLocal*);
	ConcreteType valueType = a.local.isAllocated ? getReferencedType(ctx.concretizeCtx, local.type) : local.type;
	ConcreteExpr value = concretizeExpr(ctx, valueType, locals, *a.value);
	return a.local.isAllocated
		? genReferenceWrite(ctx.concretizeCtx, range, genLocalGet(range, local), value)
		: genLocalSet(ctx.concretizeCtx, range, local, value);
}

ConcreteExpr concretizeLoopWhileOrUntil(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref LoopWhileOrUntilExpr expr,
) {
	ConcreteExpr doAndContinue(ConcreteExpr x) =>
		genDoAndContinue(ctx.alloc, type, range, x);
	ConcreteExpr breakWith(ConcreteExpr x) =>
		genBreak(ctx.alloc, range, x);
	return expr.condition.match!ConcreteExpr(
		(ref Expr x) {
			/*
			while cond
				body
			after
			==>
			loop
				if cond
					body
					continue
				else
					break after
			*/
			ConcreteExpr condition = concretizeExpr(ctx, boolType(ctx), locals, x);
			ConcreteExpr doAndContinue = doAndContinue(concretizeExpr(ctx, voidType(ctx), locals, expr.body_));
			ConcreteExpr break_ = breakWith(concretizeExpr(ctx, type, locals, expr.after));
			ConcreteExprKind.If if_ = expr.isUntil
				? ConcreteExprKind.If(condition, break_, doAndContinue)
				: ConcreteExprKind.If(condition, doAndContinue, break_);
			return genLoop(ctx, type, range, ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc, if_))));
		},
		(ref Condition.UnpackOption unpack) {
			IfOptionBranches branches = () {
				if (expr.isUntil) {
					/*
					until x ?= xs
						body
					after
					==>
					loop
						if x ?= xs
							break after
						else
							body
							continue
					*/
					RootLocalAndExpr after = concretizeExprWithDestructure(
						ctx, type, range, locals, unpack.destructure, expr.after);
					return IfOptionBranches(
						after.rootLocal, breakWith(after.expr),
						doAndContinue(concretizeExpr(ctx, voidType(ctx), locals, expr.body_)));
				} else {
					/*
					while x ?= xs
						body
					after
					==>
					loop
						if x ?= xs
							body
							continue
						else
							break after
					*/
					RootLocalAndExpr body_ = concretizeExprWithDestructure(
						ctx, voidType(ctx), range, locals, unpack.destructure, expr.body_);
					return IfOptionBranches(
						body_.rootLocal, doAndContinue(body_.expr),
						breakWith(concretizeExpr(ctx, type, locals, expr.after)));
				}
			}();
			return genLoop(ctx, type, range, genIfOption(
				ctx.alloc, range,
				concretizeExpr(ctx, locals, unpack.option),
				RootLocalAndExpr(branches.rootLocal, branches.some),
				branches.none));
		});
}
immutable struct IfOptionBranches {
	Opt!(ConcreteLocal*) rootLocal;
	ConcreteExpr some;
	ConcreteExpr none;
}

ConcreteExpr concretizeMatchEnum(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref MatchEnumExpr a,
) {
	if (isEmpty(a.cases)) return concretizeBogus(ctx, type, range);
	ConcreteExpr matched = concretizeExpr(ctx, locals, a.matched);
	IntegralValues values = mapToIntegralValues!(MatchEnumExpr.Case)(a.cases, (ref MatchEnumExpr.Case x) =>
		x.member.value);
	// TODO: If matched is a constant, just compile the relevant case
	ConcreteExpr[] cases = map(ctx.alloc, values, (ref IntegralValue value) =>
		concretizeExpr(
			ctx, type, locals,
			mustFind!(MatchEnumExpr.Case)(a.cases, (ref MatchEnumExpr.Case x) => x.member.value == value).then));
	Opt!(ConcreteExpr*) else_ = optIf(has(a.else_), () =>
		allocate(ctx.alloc, concretizeExpr(ctx, type, locals, force(a.else_))));
	return genMatchEnumOrIntegral(ctx.alloc, type, range, matched, values, cases, else_);
}

ConcreteExpr concretizeMatchIntegral(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref MatchIntegralExpr a,
) {
	ConcreteExpr matched = concretizeExpr(ctx, locals, a.matched);
	IntegralValues values = mapToIntegralValues!(MatchIntegralExpr.Case)(a.cases, (ref MatchIntegralExpr.Case x) =>
		x.value);
	// TODO: If matched is a constant, just compile the relevant case
	ConcreteExpr[] cases = map(ctx.alloc, values, (ref IntegralValue value) =>
		concretizeExpr(
			ctx, type, locals,
			mustFind!(MatchIntegralExpr.Case)(a.cases, (ref MatchIntegralExpr.Case x) => x.value == value).then));
	Opt!(ConcreteExpr*) else_ = some(allocate(ctx.alloc, concretizeExpr(ctx, type, locals, a.else_)));
	return genMatchEnumOrIntegral(ctx.alloc, type, range, matched, values, cases, else_);
}

ConcreteExpr concretizeMatchStringLike(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref MatchStringLikeExpr a,
) {
	Opt!(ConcreteFun*) equals = getConcreteFunFromCalled(ctx, a.equals);
	if (!has(equals)) return concretizeBogus(ctx, type, range);

	ConcreteExpr matched = concretizeExpr(ctx, locals, a.matched);
	SmallArray!(ConcreteExprKind.MatchStringLike.Case) cases = map(
		ctx.alloc, a.cases, (ref MatchStringLikeExpr.Case case_) =>
			ConcreteExprKind.MatchStringLike.Case(
				concretizeLiteralStringLike(ctx, matched.type, range, a.kind, case_.value),
				concretizeExpr(ctx, type, locals, case_.then)));
	return ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc,
		ConcreteExprKind.MatchStringLike(matched, force(equals), cases, concretizeExpr(ctx, type, locals, a.else_)))));
}

ConcreteExpr concretizeMatchUnion(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref MatchUnionExpr a,
) {
	if (isEmpty(a.cases)) return concretizeBogus(ctx, type, range);
	ConcreteExpr matched = concretizeExpr(ctx, locals, a.matched);
	IntegralValues values = mapToIntegralValues!(MatchUnionExpr.Case)(a.cases, (ref MatchUnionExpr.Case x) =>
		IntegralValue(x.member.memberIndex));
	SmallArray!(ConcreteExprKind.MatchUnion.Case) cases = map(ctx.alloc, values, (ref IntegralValue value) {
		MatchUnionExpr.Case case_ = mustFind!(MatchUnionExpr.Case)(a.cases, (ref MatchUnionExpr.Case x) =>
			IntegralValue(x.member.memberIndex) == value);
		return toMatchUnionCase(concretizeExprWithDestructure(ctx, type, range, locals, case_.destructure, case_.then));
	});
	Opt!(ConcreteExpr*) else_ = optIf(has(a.else_), () =>
		allocate(ctx.alloc, concretizeExpr(ctx, type, locals, *force(a.else_))));
	return ConcreteExpr(type, range, ConcreteExprKind(
		allocate(ctx.alloc, ConcreteExprKind.MatchUnion(matched, values, cases, else_))));
}

ConcreteExpr concretizeMatchVariant(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref MatchVariantExpr a,
) {
	if (isEmpty(a.cases)) return concretizeBogus(ctx, type, range);
	ConcreteExpr matched = concretizeExpr(ctx, locals, a.matched);
	ValuesAndCases vc = concretizeMatchVariantCases(ctx, type, range, locals, matched.type, a.cases);
	Opt!(ConcreteExpr*) else_ = optIf(has(a.else_), () => allocate(ctx.alloc, concretizeExpr(ctx, type, locals, force(a.else_))));
	return ConcreteExpr(type, range, ConcreteExprKind(
		allocate(ctx.alloc, ConcreteExprKind.MatchUnion(matched, vc.values, vc.cases, else_))));
}

immutable struct ValuesAndCases {
	IntegralValues values;
	SmallArray!(ConcreteExprKind.MatchUnion.Case) cases;
}
ValuesAndCases concretizeMatchVariantCases(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ConcreteType variantType,
	in MatchVariantExpr.Case[] cases,
) {
	IntegralValues values = mapToIntegralValues!(MatchVariantExpr.Case)(cases, (ref MatchVariantExpr.Case x) =>
		memberIndexForMatchVariantCase(ctx, variantType, x));
	SmallArray!(ConcreteExprKind.MatchUnion.Case) concreteCases = map(ctx.alloc, values, (ref IntegralValue value) {
		MatchVariantExpr.Case* case_ = mustFindPointer!(MatchVariantExpr.Case)(cases, (ref MatchVariantExpr.Case x) =>
			memberIndexForMatchVariantCase(ctx, variantType, x) == value);
		return toMatchUnionCase(concretizeExprWithDestructure(ctx, type, range, locals, case_.destructure, case_.then));
	});
	return ValuesAndCases(values, concreteCases);
}

ConcreteExprKind.MatchUnion.Case toMatchUnionCase(RootLocalAndExpr x) =>
	ConcreteExprKind.MatchUnion.Case(x.rootLocal, x.expr);

IntegralValue memberIndexForMatchVariantCase(
	ref ConcretizeExprCtx ctx,
	ConcreteType variantType,
	ref MatchVariantExpr.Case a,
) =>
	IntegralValue(ensureVariantMember(ctx.concretizeCtx, variantType, getConcreteType(ctx, a.destructure.type)));

ConcreteExpr concretizeVariableRefForClosure(
	ref ConcretizeExprCtx ctx,
	in UriAndRange range,
	in Locals locals,
	VariableRef a,
) =>
	a.matchWithPointers!ConcreteExpr(
		(Local* x) =>
			getLocal(locals, x).matchWithPointers!ConcreteExpr(
				(ConcreteLocal* local) =>
					// If it's a ref, leave it that way
					genLocalGet(range, local),
				(TypedConstant constant) =>
					genConstant(constant.type, range, constant.value)),
		(ClosureRef x) =>
			getClosureField(ctx, range, x));

ConcreteExpr concretizeAssertOrForbid(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	in Expr expr,
	ref AssertOrForbidExpr a,
) {
	ConcreteExpr defaultThrown() =>
		genError(
			ctx.concretizeCtx,
			range,
			defaultAssertOrForbidMessage(ctx.alloc, ctx.curUri, expr, a, ctx.concretizeCtx.fileContentGetters));
	ConcreteExpr throwNoDestructure() =>
		genThrow(ctx.alloc, type, range, has(a.thrown)
			? concretizeExpr(ctx, exceptionType(ctx.concretizeCtx), locals, *force(a.thrown))
			: defaultThrown());

	return a.condition.match!ConcreteExpr(
		(ref Expr x) {
			ConcreteExpr condition = concretizeExpr(ctx, boolType(ctx), locals, x);
			ConcreteExpr throw_ = throwNoDestructure();
			ConcreteExpr after = concretizeExpr(ctx, type, locals, a.after);
			return ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc, a.isForbid
				? ConcreteExprKind.If(condition, throw_, after)
				: ConcreteExprKind.If(condition, after, throw_))));
		},
		(ref Condition.UnpackOption x) {
			ConcreteExpr option = concretizeExpr(ctx, locals, x.option);
			if (a.isForbid) {
				RootLocalAndExpr thrown = has(a.thrown)
					? concretizeExprWithDestructure(
						ctx, exceptionType(ctx.concretizeCtx), range, locals, x.destructure, *force(a.thrown))
					: RootLocalAndExpr(none!(ConcreteLocal*), defaultThrown());
				ConcreteExpr after = concretizeExpr(ctx, type, locals, a.after);
				return genIfOption(
					ctx.alloc, range, option,
					RootLocalAndExpr(thrown.rootLocal, genThrow(ctx.alloc, type, range, thrown.expr)),
					after);
			} else {
				return genIfOption(
					ctx.alloc, range, option,
					concretizeExprWithDestructure(ctx, type, range, locals, x.destructure, a.after),
					throwNoDestructure());
			}
		});
}

ConcreteExpr concretizeExpr(ref ConcretizeExprCtx ctx, in Locals locals, ref ExprAndType a) =>
	concretizeExpr(ctx, getConcreteType(ctx, a.type), locals, a.expr);

ConcreteExpr concretizeExpr(ref ConcretizeExprCtx ctx, ConcreteType type, in Locals locals, ref Expr a) {
	UriAndRange range = UriAndRange(ctx.curUri, a.range);
	if (isBogus(type))
		return concretizeBogus(ctx, type, range);
	return a.kind.matchWithPointers!ConcreteExpr(
		(AssertOrForbidExpr* x) =>
			concretizeAssertOrForbid(ctx, type, range, locals, a, *x),
		(BogusCallExpr _) =>
			concretizeBogus(ctx, type, range),
		(BogusExpr _) =>
			concretizeBogus(ctx, type, range),
		(BogusWrongTypeExpr _) =>
			concretizeBogus(ctx, type, range),
		(CallExpr x) =>
			concretizeCall(ctx, type, range, locals, x),
		(CallOptionExpr* x) =>
			concretizeCallOption(ctx, type, range, locals, *x),
		(ClosureGetExpr x) =>
			concretizeClosureGet(ctx, type, range, x),
		(ClosureSetExpr x) =>
			concretizeClosureSet(ctx, type, range, locals, x),
		(ExternExpr x) =>
			ConcreteExpr(type, range, ConcreteExprKind(
				constantBool(ctx.concretizeCtx.allExterns.containsAll(x.names)))),
		(FinallyExpr* x) =>
			concretizeFinally(ctx, type, range, locals, *x),
		(FunPointerExpr x) =>
			concretizeFunPointer(ctx, type, range, x),
		(IfExpr* x) =>
			concretizeIf(ctx, type, range, locals, *x),
		(LambdaExpr* x) =>
			concretizeLambda(ctx, type, range, locals, x),
		(LetExpr* x) =>
			concretizeLet(ctx, type, range, locals, *x),
		(LiteralExpr x) =>
			ConcreteExpr(type, range, ConcreteExprKind(x.value)),
		(LiteralStringLikeExpr x) =>
			concretizeLiteralStringLike(ctx, type, range, x.kind, x.value),
		(LocalGetExpr x) =>
			concretizeLocalGet(ctx, type, range, locals, x.local),
		(LocalPointerExpr x) =>
			concretizePtrToLocal(ctx, type, range, locals, x),
		(LocalSetExpr x) =>
			concretizeLocalSet(ctx, type, range, locals, x),
		(LoopExpr* x) =>
			genLoop(ctx, type, range, concretizeExpr(ctx, type, locals, x.body_)),
		(LoopBreakExpr* x) =>
			genBreak(ctx.alloc, range, concretizeExpr(ctx, type, locals, x.value)),
		(LoopContinueExpr) =>
			genContinue(type, range),
		(LoopWhileOrUntilExpr* x) =>
			concretizeLoopWhileOrUntil(ctx, type, range, locals, *x),
		(MatchEnumExpr* x) =>
			concretizeMatchEnum(ctx, type, range, locals, *x),
		(MatchIntegralExpr* x) =>
			concretizeMatchIntegral(ctx, type, range, locals, *x),
		(MatchStringLikeExpr* x) =>
			concretizeMatchStringLike(ctx, type, range, locals, *x),
		(MatchUnionExpr* x) =>
			concretizeMatchUnion(ctx, type, range, locals, *x),
		(MatchVariantExpr* x) =>
			concretizeMatchVariant(ctx, type, range, locals, *x),
		(RecordFieldPointerExpr* x) =>
			genRecordFieldPointer(
				type, range, allocate(ctx.alloc, concretizeExpr(ctx, locals, x.target)), x.fieldIndex),
		(SeqExpr* x) {
			ConcreteExpr first = concretizeExpr(ctx, voidType(ctx), locals, x.first);
			ConcreteExpr then = concretizeExpr(ctx, type, locals, x.then);
			return first.kind.isA!Constant
				? then
				: ConcreteExpr(type, range, ConcreteExprKind(
					allocate(ctx.alloc, ConcreteExprKind.Seq(first, then))));
		},
		(ThrowExpr* x) =>
			ConcreteExpr(type, range, ConcreteExprKind(
				allocate(ctx.alloc, ConcreteExprKind.Throw(
					concretizeExpr(ctx, exceptionType(ctx.concretizeCtx), locals, x.thrown))))),
		(TrustedExpr* x) =>
			concretizeExpr(ctx, type, locals, x.inner),
		(TryExpr* x) =>
			concretizeTry(ctx, type, range, locals, *x),
		(TryLetExpr* x) =>
			concretizeTryLet(ctx, type, range, locals, *x),
		(TypedExpr* x) =>
			concretizeExpr(ctx, type, locals, x.inner));
}

ConstantsOrExprs constantsOrExprsArr(
	ref ConcretizeExprCtx ctx,
	in UriAndRange range,
	ConcreteType arrayType,
	ConstantsOrExprs args,
) =>
	args.match!ConstantsOrExprs(
		(Constant[] constants) =>
			ConstantsOrExprs(newArray!Constant(ctx.alloc, [
				getConstantArray(ctx.alloc, ctx.allConstants, mustBeByVal(arrayType), constants)])),
		(ConcreteExpr[] exprs) =>
			ConstantsOrExprs(newArray!ConcreteExpr(ctx.alloc, [
				ConcreteExpr(arrayType, range, ConcreteExprKind(ConcreteExprKind.CreateArray(exprs)))])));

Opt!Constant tryEvalConstant(
	in ConcreteFun fn,
	in Constant[] args,
	in VersionInfo versionInfo,
) =>
	fn.body_.matchIn!(Opt!Constant)(
		(in ConcreteFunBody.Builtin x) {
			if (x.kind.isA!VersionFun) {
				assert(isEmpty(args));
				return some(constantBool(isVersion(versionInfo, x.kind.as!VersionFun)));
			} else if (x.kind.isA!BuiltinBinary) {
				assert(args.length == 2);
				return tryEvalConstantBinary(x.kind.as!BuiltinBinary, args[0], args[1]);
			} else if (x.kind.isA!BuiltinUnary) {
				return tryEvalConstantUnary(x.kind.as!BuiltinUnary, only(args));
			} else if (x.kind.isA!(BuiltinFun.SizeOf)) {
				assert(isEmpty(args));
				return isKnownEmptyType(only(fn.source.as!ConcreteFunKey.typeArgs))
					? some(constantZero())
					: none!Constant;
			} else if (x.kind.isA!(BuiltinFun.GcSafeValue)) {
				assert(isEmpty(args));
				return some(constantZero());
			} else
				return none!Constant;
		},
		(in ConcreteFunBody.Extern) => none!Constant,
		(in ConcreteExpr x) =>
			x.kind.isA!Constant
				? some(x.kind.as!Constant)
				: none!Constant,
		(in ConcreteFunBody.VarGet) => none!Constant,
		(in ConcreteFunBody.VarSet) => none!Constant,
		(in ConcreteFunBody.Deferred) => none!Constant);

bool isKnownEmptyType(in ConcreteType a) =>
	a.struct_.typeSizeIsSet && isEmptyType(a);

Opt!Constant tryEvalConstantBinary(BuiltinBinary fn, Constant arg0, Constant arg1) {
	switch (fn) {
		case BuiltinBinary.equalNat64:
			return some(constantBool(asNat64(arg0) == asNat64(arg1)));
		default:
			return none!Constant;
	}
}
Opt!Constant tryEvalConstantUnary(BuiltinUnary fn, Constant arg) {
	switch (fn) {
		case BuiltinUnary.not:
			return some(constantBool(!asBool(arg)));
		default:
			return none!Constant;
	}
}

ConcreteExpr concretizeFinally(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref FinallyExpr a,
) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc,
		ConcreteExprKind.Finally(
			concretizeExpr(ctx, voidType(ctx), locals, a.right),
			concretizeExpr(ctx, type, locals, a.below)))));

ConcreteExpr concretizeTry(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref TryExpr a,
) {
	ConcreteExpr tried = concretizeExpr(ctx, type, locals, a.tried);
	ValuesAndCases vc = concretizeMatchVariantCases(
		ctx, type, range, locals, exceptionType(ctx.concretizeCtx), a.catches);
	return ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc,
		ConcreteExprKind.Try(tried, vc.values, vc.cases))));
}

ConcreteExpr concretizeTryLet(
	ref ConcretizeExprCtx ctx,
	ConcreteType type,
	in UriAndRange range,
	in Locals locals,
	ref TryLetExpr a,
) {
	/*
	try x, y = some-pair catch foo : caught
	then
	==>
	try pair = some-pair catch foo : caught
	x, y = pair
	then
	*/
	ConcreteType localType = getConcreteType(ctx, a.destructure.type);
	ConcreteExpr value = concretizeExpr(ctx, localType, locals, a.value);
	IntegralValue catchMemberIndex = memberIndexForMatchVariantCase(ctx, exceptionType(ctx.concretizeCtx), a.catch_);
	ConcreteExprKind.MatchUnion.Case catchExpr = toMatchUnionCase(
		concretizeExprWithDestructure(ctx, type, range, locals, a.catch_.destructure, a.catch_.then));
	RootLocalAndExpr then = concretizeExprWithDestructure(
		ctx, type, range, locals, a.destructure, a.then);
	return ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc,
		ConcreteExprKind.TryLet(then.rootLocal, value, catchMemberIndex, catchExpr, then.expr))));
}
