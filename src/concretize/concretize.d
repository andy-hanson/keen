module concretize.concretize;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : finishAllConstants;
import concretize.checkConcreteModel : checkConcreteProgram, ConcreteCommonTypes;
import concretize.concretizeCtx :
	boolType,
	char8Type,
	concreteFunForWrapMain,
	ConcreteLambdaImpl,
	ConcreteVariantMemberAndMethodImpls,
	ConcretizeCtx,
	deferredFillRecordAndUnionBodies,
	exceptionType,
	finishConcreteVars,
	getConcreteFun,
	getNonTemplateConcreteFun,
	getVar,
	nat64Type,
	symbolType,
	symbolArrayType,
	voidType;
import concretize.gatherInfo : getYieldingFuns;
import concretize.generate : generateCallLambda, generateCallVariantMethod;
import frontend.showModel : ShowCtx;
import model.concreteModel :
	ConcreteCommonFuns,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteFunKey,
	ConcreteProgram,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructInfo,
	ConcreteStructSource,
	ConcreteType,
	mustBeByVal;
import model.model :
	allExterns,
	BuildTarget,
	BuiltinFun,
	CommonFuns,
	FunBody,
	FunInst,
	IntegralType,
	MainFun,
	ProgramWithMain,
	StructBody,
	TestSelector;
import util.alloc.alloc : Alloc;
import util.col.array : map, mustHaveIndexOfPointer, small;
import util.col.arrayBuilder : asTemporaryArray, finish;
import util.col.enumMap : EnumMap, enumMapMapValues;
import util.col.mutArr : asTemporaryArray, MutArr, push;
import util.col.mutMap : mustGet;
import util.late : late, lateSet;
import util.perf : Perf, PerfMeasure, withMeasure;
import util.util : castNonScope_ref, ptrTrustMe;
import versionInfo : VersionInfo;

ConcreteProgram concretize(
	scope ref Perf perf,
	ref Alloc alloc,
	in ShowCtx showCtx,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) =>
	withMeasure!(ConcreteProgram, () =>
		concretizeInner(&alloc, showCtx, versionInfo, program)
	)(perf, alloc, PerfMeasure.concretize);

private:

ConcreteProgram concretizeInner(
	Alloc* allocPtr,
	in ShowCtx showCtx,
	in VersionInfo versionInfo,
	ref ProgramWithMain program,
) {
	ref Alloc alloc() =>
		*allocPtr;
	ConcretizeCtx ctx = ConcretizeCtx(
		allocPtr,
		versionInfo,
		ptrTrustMe(program),
		castNonScope_ref(showCtx.fileContentGetters),
		allExterns(program, BuildTarget.native(versionInfo.os)));
	CommonFuns commonFuns = program.program.commonFuns;
	lateSet(ctx.createErrorFunction_, getNonTemplateConcreteFun(ctx, commonFuns.createError));
	lateSet!(EnumMap!(IntegralType, ConcreteFun*))(
		ctx.equalIntegralFunctions_,
		enumMapMapValues(commonFuns.equalIntegralFunctions, (const FunInst* x) =>
			getNonTemplateConcreteFun(ctx, x)));
	lateSet(ctx.equalSymbolFunction_, getConcreteFun(ctx, commonFuns.equalConstPointers, [char8Type(ctx)], []));
	lateSet(ctx.lessIntegralFunctions_, enumMapMapValues(commonFuns.lessIntegralFunctions, (const FunInst* x) => // Why even do this? Just use e.g. BuiltinBinary.lessInt8
		getNonTemplateConcreteFun(ctx, x)));
	lateSet(ctx.newJsonFromPairsFunction_, getNonTemplateConcreteFun(ctx, commonFuns.newJsonFromPairs));
	lateSet(ctx.toJsonFromStringFunction_, getNonTemplateConcreteFun(ctx, commonFuns.toJsonFromString));
	lateSet(ctx.concatSymbolArrayFunction_, getConcreteFun(ctx, commonFuns.concatArrays, [symbolType(ctx)], []));
	ConcreteCommonFuns concreteCommonFuns = ConcreteCommonFuns(
		alloc: getNonTemplateConcreteFun(ctx, commonFuns.allocate),
		curCatchPoint: getNonTemplateConcreteFun(ctx, commonFuns.curCatchPoint),
		setCurCatchPoint: getNonTemplateConcreteFun(ctx, commonFuns.setCurCatchPoint),
		curThrown: getVar(ctx, commonFuns.curThrown),
		mark: getNonTemplateConcreteFun(ctx, commonFuns.mark),
		rethrowCurrentException: getNonTemplateConcreteFun(ctx, commonFuns.rethrowCurrentException),
		runFiber: getNonTemplateConcreteFun(ctx, commonFuns.runFiber),
		rtMain: getNonTemplateConcreteFun(ctx, commonFuns.rtMain),
		throwImpl: getNonTemplateConcreteFun(ctx, commonFuns.throwImpl),
		userMain: concretizeMainFun(ctx, commonFuns, program.mainFun),
		gcRoot: getNonTemplateConcreteFun(ctx, commonFuns.gcRoot),
		setGcRoot: getNonTemplateConcreteFun(ctx, commonFuns.setGcRoot),
		popGcRoot: getNonTemplateConcreteFun(ctx, commonFuns.popGcRoot));

	finishLambdas(ctx);
	finishVariants(ctx);

	immutable ConcreteFun*[] allConcreteFuns = finish(alloc, ctx.allConcreteFuns);

	deferredFillRecordAndUnionBodies(ctx);

	ConcreteProgram res = ConcreteProgram(
		versionInfo,
		finishAllConstants(alloc, ctx.allConstants, symbolArrayType(ctx)),
		finish(alloc, ctx.allConcreteStructs),
		finishConcreteVars(ctx),
		allConcreteFuns,
		getYieldingFuns(alloc, concreteCommonFuns, allConcreteFuns),
		concreteCommonFuns);
	checkConcreteProgram(
		showCtx,
		ConcreteCommonTypes(
			bool_: boolType(ctx),
			exception: exceptionType(ctx),
			nat64: nat64Type(ctx),
			symbol: symbolType(ctx),
			void_: voidType(ctx)),
		res);
	return res;
}

ConcreteFun* concretizeMainFun(ref ConcretizeCtx ctx, ref CommonFuns commonFuns, MainFun main) =>
	main.match!(ConcreteFun*)(
		(MainFun.Nat64OfArgs x) =>
			getNonTemplateConcreteFun(ctx, x.fun),
		(MainFun.Void x) =>
			concreteFunForWrapMain(ctx, x.fun),
		(TestSelector x) =>
			concreteFunForWrapMain(ctx, commonFuns.runAllTests));

void finishLambdas(ref ConcretizeCtx ctx) {
	foreach (ConcreteStruct* struct_, MutArr!ConcreteLambdaImpl impls; ctx.lambdaStructToImpls) {
		ConcreteType[] memberTypes = map(ctx.alloc, asTemporaryArray(impls), (ref ConcreteLambdaImpl x) =>
			x.closureType);
		struct_.info = ConcreteStructInfo(
			body_: ConcreteStructBody(ConcreteStructBody.Union(late(small!ConcreteType(memberTypes)))),
			isSelfMutable: false);
		push(ctx.alloc, ctx.deferredTypeSize, struct_);
	}

	foreach (ConcreteFun* fun; asTemporaryArray(ctx.allConcreteFuns)) {
		if (fun.body_.isA!(ConcreteFunBody.Builtin)) {
			ConcreteFunBody.Builtin builtin = fun.body_.as!(ConcreteFunBody.Builtin);
			if (builtin.kind.isA!(BuiltinFun.CallLambda)) {
				ConcreteStruct* lambda = mustBeByVal(fun.params[0].type);
				fun.overwriteBody(generateCallLambda(
					ctx, fun, lambda.body_.as!(ConcreteStructBody.Union).members,
					asTemporaryArray(mustGet(ctx.lambdaStructToImpls, lambda))));
			}
		}
	}
}

void finishVariants(ref ConcretizeCtx ctx) {
	foreach (ConcreteStruct* variant, MutArr!ConcreteVariantMemberAndMethodImpls x; ctx.variantStructToMembers)
		variant.body_.as!(ConcreteStructBody.Union).members =
			small!ConcreteType(map(ctx.alloc, asTemporaryArray(x), (ref ConcreteVariantMemberAndMethodImpls x) =>
				x.memberType));

	foreach (ConcreteFun* fun; ctx.deferredVariantMethods) {
		ConcreteStruct* variant = mustBeByVal(fun.params[0].type);
		size_t methodIndex = mustHaveIndexOfPointer(
			variant.source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Variant).methods,
			fun.source.as!ConcreteFunKey.decl.body_.as!(FunBody.VariantMethod).method);
		MutArr!ConcreteVariantMemberAndMethodImpls impls = mustGet(ctx.variantStructToMembers, variant);
		fun.overwriteBody(generateCallVariantMethod(ctx, fun, variant, asTemporaryArray(impls), methodIndex));
	}
}
