module concretize.concretizeFunBody;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : getConstantArray;
import concretize.concretizeAutoFun : concretizeAutoFun, concretizeFlagsFunction;
import concretize.concretizeCtx :
	addConcreteFun,
	ConcretizeCtx,
	getConcreteType,
	getNonTemplateConcreteFun,
	getVarKey,
	ensureSumTypeCase,
	getConcreteType_forStructInst,
	nat64Type,
	voidType;
import concretize.concretizeExpr : ConcretizeExprCtx, concretizeFunBody, withConcretizeExprCtx;
import concretize.generate :
	constantOfBytes,
	fieldIndexFromField,
	genBogus,
	genBogusKind,
	genConstant,
	genCreateRecord,
	genCreateUnion,
	genLocalGet,
	genNone,
	genRecordFieldCall,
	genRecordFieldGet,
	genRecordFieldPointer,
	genRecordFieldSet,
	genSeq,
	genSome,
	genStringLiteralKind,
	genUnionMemberGet,
	unwrapOptionType;
import model.concreteModel :
	CallConcreteExpr,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteFunKey,
	ConcreteFunSource,
	ConcreteGeneratedLocalKind,
	ConcreteLocal,
	ConcreteLocalSource,
	ConcreteType,
	ConcreteVar,
	mustBeByVal,
	pointeeType,
	pointeeTypeIfIsPointer;
import model.constant : Constant, ConstantFunPointer, ConstantUnion, constantZero;
import model.model :
	AutoFun,
	BuiltinFun,
	BuiltinFunAllTests,
	BuiltinFunNewEmptyOption,
	BuiltinFunNewNonEmptyOption,
	eachTest,
	Expr,
	FlagsFunction,
	FunBody,
	FunInst,
	ImportFileContent,
	Test,
	Type,
	VarDecl;
import util.alloc.alloc : Alloc;
import util.col.array : emptySmallArray, isEmpty, mapPointers, newSmallArray, only, onlyPointer;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.hashTable : getOrAdd;
import util.col.mutArr : push;
import util.integralValues : IntegralValue;
import util.memory : allocate;
import util.sourceRange : UriAndRange;
import util.symbol : symbol;

void fillInConcreteFunBody(ref ConcretizeCtx ctx, ConcreteFun* cf) {
	// set to arbitrary temporarily. (But it can't be a constant or something will optimize based on that!)
	cf.body_ = ConcreteFunBody(ConcreteFunBody.Extern(symbol!"bogus"));
	FunBody funBody = cf.source.match!FunBody(
		(ConcreteFunKey x) => x.decl.body_,
		(ref ConcreteFunSource.Lambda x) => FunBody(*x.bodyExpr),
		(ref ConcreteFunSource.Test x) => assert(false),
		(ref ConcreteFunSource.WrapMain x) => assert(false));
	ConcreteLocal[] concreteParams = cf.params;
	ConcreteFunBody body_ = funBody.match!ConcreteFunBody(
		(FunBody.Bogus) =>
			ConcreteFunBody(genBogus(ctx, cf.returnType, cf.range)),
		(AutoFun x) =>
			withConcretizeExprCtx(ctx, cf, (ref ConcretizeExprCtx exprCtx) =>
				ConcreteFunBody(concretizeAutoFun(exprCtx, x))),
		(BuiltinFun x) =>
			concretizeBuiltinFun(ctx, cf, concreteParams, x),
		(FunBody.CreateEnumOrFlags x) =>
			ConcreteFunBody(genConstant(cf.returnType, cf.range, Constant(IntegralValue(x.member.value.value)))),
		(FunBody.CreateExtern) =>
			ConcreteFunBody(genConstant(cf.returnType, cf.range, constantZero)),
		(FunBody.CreateRecord) =>
			isEmpty(concreteParams)
				? ConcreteFunBody(genConstant(cf.returnType, cf.range, constantZero()))
				: ConcreteFunBody(genCreateRecordFromParams(ctx.alloc, cf.returnType, cf.range, concreteParams)),
		(FunBody.CreateRecordAndConvertToSumType x) {
			ConcreteType memberType = getConcreteType(ctx, Type(x.member), cf.source.as!ConcreteFunKey.typeArgs);
			size_t memberIndex = ensureSumTypeCase(ctx, cf.returnType, memberType);
			return isEmpty(concreteParams)
				? ConcreteFunBody(genConstantUnionEmptyMemberType(ctx.alloc, cf.returnType, cf.range, memberIndex))
				: ConcreteFunBody(genCreateUnion(
					ctx.alloc, cf.returnType, cf.range, memberIndex,
					genCreateRecordFromParams(ctx.alloc, memberType, cf.range, concreteParams)));
		},
		(FunBody.CreateSumType x) =>
			createUnionBody(ctx.alloc, cf, ensureSumTypeCase(
				ctx, cf.returnType, isEmpty(concreteParams) ? voidType(ctx) : only(concreteParams).type)),
		(Expr x) =>
			ConcreteFunBody(concretizeFunBody(ctx, cf, x)),
		(FunBody.Extern x) =>
			ConcreteFunBody(ConcreteFunBody.Extern(x.libraryName)),
		(FunBody.FileImport x) =>
			ConcreteFunBody(concretizeFileImport(ctx, cf, x)),
		(FlagsFunction x) =>
			ConcreteFunBody(concretizeFlagsFunction(ctx, cf, x)),
		(FunBody.Method x) {
			push(ctx.alloc, ctx.deferredMethods, cf);
			return ConcreteFunBody(ConcreteFunBody.Deferred());
		},
		(FunBody.RecordFieldCall x) =>
			genRecordFieldCall(ctx, cf, x),
		(FunBody.RecordFieldGet x) =>
			ConcreteFunBody(genRecordFieldGet(
				cf.returnType, cf.range,
				allocate(ctx.alloc, genLocalGet(cf.range, onlyPointer(cf.params))),
				fieldIndexFromField(only(cf.params).type, x.field))),
		(FunBody.RecordFieldPointer x) =>
			ConcreteFunBody(genRecordFieldPointer(
				cf.returnType, cf.range,
				allocate(ctx.alloc, genLocalGet(cf.range, onlyPointer(cf.params))),
				fieldIndexFromField(pointeeType(only(cf.params).type), x.field))),
		(FunBody.RecordFieldSet x) {
			assert(cf.params.length == 2);
			return ConcreteFunBody(genRecordFieldSet(
				ctx,
				cf.range,
				genLocalGet(cf.range, &cf.params[0]),
				fieldIndexFromField(pointeeTypeIfIsPointer(cf.params[0].type), x.field),
				genLocalGet(cf.range, &cf.params[1])));
		},
		(FunBody.SumTypeMemberGet x) =>
			genUnionMemberGet(
				ctx, cf,
				ensureSumTypeCase(ctx, only(concreteParams).type, unwrapOptionType(ctx, cf.returnType))),
		(FunBody.VarGet x) =>
			ConcreteFunBody(ConcreteFunBody.VarGet(getVar(ctx, x.var))),
		(FunBody.VarSet x) =>
			ConcreteFunBody(ConcreteFunBody.VarSet(getVar(ctx, x.var))));
	cf.overwriteBody(body_);
}

ConcreteFun* concreteFunForWrapMain(ref ConcretizeCtx ctx, FunInst* modelMain) {
	ConcreteType stringArrayType = getConcreteType_forStructInst(
		ctx, ctx.commonTypes.stringArray, emptySmallArray!ConcreteType);
	ConcreteFun* innerMain = getNonTemplateConcreteFun(ctx, modelMain);
	/*
	This is like:
		wrapped-main nat(_ string[])
			real-main
			0
	*/
	ConcreteType nat64 = nat64Type(ctx);
	UriAndRange range = modelMain.decl.range;
	ConcreteExpr callMain = ConcreteExpr(voidType(ctx), range, ConcreteExprKind(
		CallConcreteExpr(innerMain, emptySmallArray!ConcreteExpr)));
	ConcreteExpr zero = ConcreteExpr(nat64, range, ConcreteExprKind(constantZero));
	ConcreteExpr body_ = genSeq(ctx.alloc, range, callMain, zero);
	ConcreteFun* res = allocate(ctx.alloc, ConcreteFun(
		ConcreteFunSource(allocate(ctx.alloc, ConcreteFunSource.WrapMain(range))),
		nat64,
		newSmallArray(ctx.alloc, [
			ConcreteLocal(ConcreteLocalSource(ConcreteGeneratedLocalKind.args), stringArrayType),
		])));
	res.body_ = ConcreteFunBody(body_);
	addConcreteFun(ctx, res);
	return res;
}

private:

ConcreteFunBody concretizeBuiltinFun(
	ref ConcretizeCtx ctx,
	ConcreteFun* cf,
	ConcreteLocal[] concreteParams,
	BuiltinFun a,
) =>
	a.isA!BuiltinFunAllTests
		? bodyForAllTests(ctx, cf.returnType)
		: a.isA!BuiltinFunNewEmptyOption
		? ConcreteFunBody(genNone(ctx, cf.returnType, cf.range))
		: a.isA!BuiltinFunNewNonEmptyOption
		? ConcreteFunBody(genSome(ctx, cf.returnType, cf.range, genLocalGet(cf.range, &only(concreteParams))))
		: ConcreteFunBody(ConcreteFunBody.Builtin(a, cf.source.as!ConcreteFunKey.typeArgs));


ConcreteExpr genCreateRecordFromParams(
	ref Alloc alloc,
	ConcreteType recordType,
	UriAndRange range,
	ConcreteLocal[] params,
) =>
	genCreateRecord(recordType, range, mapPointers(alloc, params, (ConcreteLocal* param) =>
		genLocalGet(range, param)));

ConcreteFunBody createUnionBody(ref Alloc alloc, ConcreteFun* cf, size_t memberIndex) =>
	isEmpty(cf.params)
		? ConcreteFunBody(genConstantUnionEmptyMemberType(alloc, cf.returnType, cf.range, memberIndex))
		: ConcreteFunBody(genCreateUnion(
			alloc, cf.returnType, cf.range, memberIndex, genLocalGet(cf.range, onlyPointer(cf.params))));

ConcreteExpr genConstantUnionEmptyMemberType(
	ref Alloc alloc,
	ConcreteType type,
	UriAndRange range,
	size_t memberIndex,
) =>
	genConstant(type, range, Constant(allocate(alloc, ConstantUnion(memberIndex, constantZero()))));

ConcreteExpr concretizeFileImport(ref ConcretizeCtx ctx, ConcreteFun* cf, ref FunBody.FileImport import_) =>
	withConcretizeExprCtx(ctx, cf, (ref ConcretizeExprCtx exprCtx) {
		ConcreteExprKind exprKind = import_.content.match!ConcreteExprKind(
			(immutable ubyte[] x) =>
				ConcreteExprKind(constantOfBytes(ctx, cf.returnType, x)),
			(string x) =>
				genStringLiteralKind(ctx, cf.range, x),
			(ImportFileContent.Bogus) =>
				genBogusKind(exprCtx.concretizeCtx, cf.range));
		return ConcreteExpr(cf.returnType, cf.range, exprKind);
	});

public ConcreteVar* getVar(ref ConcretizeCtx ctx, VarDecl* decl) =>
	getOrAdd!(immutable ConcreteVar*, immutable VarDecl*, getVarKey)(ctx.alloc, ctx.concreteVarLookup, decl, () =>
		allocate(ctx.alloc, ConcreteVar(decl, getConcreteType(ctx, decl.type, emptySmallArray!ConcreteType))));

ConcreteFunBody bodyForAllTests(ref ConcretizeCtx ctx, ConcreteType returnType) =>
	ConcreteFunBody(ConcreteExpr(returnType, UriAndRange.empty, ConcreteExprKind(getConstantArray(
		ctx.alloc,
		ctx.allConstants,
		mustBeByVal(returnType),
		buildArray!Constant(ctx.alloc, (scope ref Builder!Constant out_) {
			size_t testIndex = 0;
			eachTest(ctx.program, ctx.allExterns, ctx.programWithMainPtr.testSelector, (Test* test) {
				out_ ~= Constant(ConstantFunPointer(concreteFunForTest(ctx, test, testIndex++)));
			});
		})))));

ConcreteFun* concreteFunForTest(ref ConcretizeCtx ctx, Test* test, size_t testIndex) {
	ConcreteType voidType = voidType(ctx);
	ConcreteFun* res = allocate(ctx.alloc, ConcreteFun(
		ConcreteFunSource(allocate(ctx.alloc, ConcreteFunSource.Test(test, testIndex))),
		voidType,
		emptySmallArray!ConcreteLocal));
	res.body_ = ConcreteFunBody(concretizeFunBody(ctx, res, test.body_));
	addConcreteFun(ctx, res);
	return res;
}
