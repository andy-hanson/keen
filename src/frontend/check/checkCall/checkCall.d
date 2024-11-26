module frontend.check.checkCall.checkCall;

@safe @nogc pure nothrow:

import frontend.check.checkCall.candidates :
	Candidate,
	candidatesForDiag,
	eachFunInScope,
	funsInExprScope,
	FunsInScope,
	getAllCandidatesAsCalledDecls,
	getCandidateExpectedParameterType,
	testCandidateForSpecSig,
	testCandidateParamType,
	typeContextForCandidate,
	withCandidates;
import frontend.check.checkCall.checkCallSpecs : ArgsKind, checkCalled, checkCallSpecs;
import frontend.check.checkCtx : addDiag, CheckCtx;
import frontend.check.exprCtx : addDiag2, checkCanDoUnsafe, ExprCtx, LocalsInfo, typeFromAst2, typeFromDestructure2;
import frontend.check.inferringType :
	bogus,
	check,
	checkWithModifyExpected,
	Expected,
	getExpectedForDiag,
	inferred,
	inferTypeArgsFrom,
	inferTypeArgsFromLambdaParameterType,
	matchExpectedVsReturnTypeNoDiagnostic,
	nonInferring,
	setToBogusIfInferring,
	SingleInferringType,
	tryGetInferred,
	TypeAndContext,
	TypeContext,
	withExpectCandidates;
import frontend.check.instantiate : InstantiateCtx, makeOptionIfNotAlready, makeOptionType;
import frontend.check.typeFromAst : getNTypeArgsForDiagnostic, tryUnpackOptionType, unpackTupleIfNeeded;
import model.ast : CallAst, CallNamedAst, DestructureAst, ExprAst, LambdaAst, NameAndRange, VoidDestructureAst;
import model.model :
	BogusCallExpr,
	Called,
	CalledDecl,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	CommonTypes,
	Destructure,
	Diag,
	DiagCallMultipleMatches,
	DiagCallNoMatch,
	DiagCallShouldUseSyntax,
	DiagCallShouldUseSyntaxKind,
	DiagFunctionWithSignatureNotFound,
	Expr,
	ExprAndType,
	ExprKind,
	FunDecl,
	FunFlags,
	Local,
	ReturnAndParamTypes,
	Signature,
	SpecInst,
	Type,
	TypeContainer,
	Varargs;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray;
import util.col.array :
	arraysCorrespond,
	copyArray,
	emptySmallArray,
	every,
	everyWithIndex,
	exists,
	filterUnordered,
	filterUnorderedButDontRemoveAll,
	isEmpty,
	map,
	mapZip,
	newArray,
	newSmallArray,
	only,
	small,
	SmallArray,
	zipEvery;
import util.col.arrayBuilder : Builder, buildSmallArray, finish;
import util.col.exactSizeArrayBuilder :
	ExactSizeArrayBuilder, newExactSizeArrayBuilder, finishAllowSmaller, smallFinish;
import util.late : Late, late, lateGet, lateSet;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some, some;
import util.perf : endMeasure, PerfMeasure, PerfMeasurer, pauseMeasure, resumeMeasure, startMeasure;
import util.sourceRange : Range;
import util.symbol : Symbol, symbol;
import util.symbolSet : SymbolSet;
import util.union_ : Union;
import util.util : typeAs;

Expr checkCall(alias checkExpr)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	ref CallAst ast,
	ref Expected expected,
) {
	checkCallShouldUseSyntax(ctx, ast);
	return ast.style == CallAst.Style.questionSubscript || ast.style == CallAst.Style.questionDot
		? checkOptionCall!checkExpr(ctx, locals, source, ast, expected)
		: checkCallCommon!checkExpr(
			ctx, expected, source, locals,
			// Show diags at the function name and not at the whole call ast
			ast.nameRange(source),
			ast.funName.name,
			has(ast.typeArg) ? some(typeFromAst2(ctx, *force(ast.typeArg))) : none!Type,
			ast.args,
			(in CalledDecl _) => true);
}

Expr checkCallNamed(alias checkExpr)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	ref CallNamedAst ast,
	ref Expected expected,
) =>
	checkCallCommon!checkExpr(
		ctx, expected, source, locals, source.range, symbol!"new", none!Type, ast.args,
		(in CalledDecl x) => parameterNamesAre(x, ast.names));

private bool parameterNamesAre(in CalledDecl a, in NameAndRange[] names) {
	assert(!isEmpty(names));
	Destructure[] actual = a.match!(Destructure[])(
		(ref FunDecl x) =>
			x.params.match!(Destructure[])(
				(Destructure[] y) => y,
				// will always fail because 'names' is always non-empty
				(ref Varargs _) => typeAs!(Destructure[])([])),
		(CalledSpecSig x) =>
			typeAs!(Destructure[])(x.nonInstantiatedSig.params));
	return arraysCorrespond!(Destructure, NameAndRange)(actual, names, (ref Destructure x, ref NameAndRange name) =>
		x.isA!(Local*) && x.as!(Local*).name == name.name);
}

Expr checkCallSpecial(alias checkExpr)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range range,
	Symbol funName,
	in ExprAst[] args,
	ref Expected expected,
) =>
	checkCallCommon!checkExpr(
		ctx, expected, source, locals, range, funName, none!Type, newArray(ctx.alloc, args),
		(in CalledDecl _) => true);

private Expr checkCallCommon(alias checkExpr)(
	ref ExprCtx ctx,
	ref Expected expected,
	ExprAst* source,
	ref LocalsInfo locals,
	Range diagRange,
	Symbol funName,
	Opt!Type typeArg,
	ExprAst[] argAsts,
	in bool delegate(in CalledDecl) @safe @nogc pure nothrow cbAdditionalFilter,
) =>
	checkCallSpecialCbN(
		ctx,
		locals,
		source,
		diagRange,
		funName,
		expected,
		typeArg,
		argAsts.length,
		cbCheckArg: (size_t i, ref Expected argExpected) =>
			checkExpr(ctx, locals, &argAsts[i], argExpected),
		cbAdditionalFilter: cbAdditionalFilter,
		cbBeforeCheck: (scope ref Candidate[] candidates) =>
			everyWithIndex!ExprAst(argAsts, (size_t argIdx, ref ExprAst arg) =>
				inferCandidateTypeArgsFromExplicitlyTypedArgument(
					ctx, candidates, argIdx, arg
				) == ContinueOrAbort.continue_));

Expr checkCallArgAndLambda(alias checkExpr, alias checkLambda)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range diagRange,
	Symbol funName,
	ExprAst* argAst,
	DestructureAst* paramAst,
	ExprAst* bodyAst,
	ref Expected expected,
) =>
	checkCallSpecialCb2(
		ctx, locals, source, diagRange, funName, expected,
		(ref Expected argExpected) =>
			checkExpr(ctx, locals, argAst, argExpected),
		(ref Expected argExpected) =>
			checkLambda(ctx, locals, source, paramAst, bodyAst, argExpected),
		(scope ref Candidate[] candidates) =>
			inferCandidateTypeArgsFromLambdaParameter(ctx, candidates, 1, *paramAst) == ContinueOrAbort.continue_);

Expr checkCallArgAnd2Lambdas(alias checkExpr, alias checkLambda)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range diagRange,
	Symbol funName,
	ExprAst* argAst,
	DestructureAst* paramAst,
	ExprAst* bodyAst,
	ExprAst* body2Ast, // second lambda has no param
	ref Expected expected,
) =>
	checkCallSpecialCbN(
		ctx, locals, source, diagRange, funName, expected,
		typeArg: none!Type,
		nArgs: 3,
		cbCheckArg: (size_t i, ref Expected argExpected) {
			final switch (i) {
				case 0:
					return checkExpr(ctx, locals, argAst, argExpected);
				case 1:
					return checkLambda(ctx, locals, source, paramAst, bodyAst, argExpected);
				case 2:
					return checkLambda(ctx, locals, source, &voidDestructure, body2Ast, argExpected);
			}
		},
		cbAdditionalFilter: (in CalledDecl _) => true,
		cbBeforeCheck: (scope ref Candidate[] candidates) =>
			inferCandidateTypeArgsFromLambdaParameter(ctx, candidates, 1, *paramAst) == ContinueOrAbort.continue_);

private immutable DestructureAst voidDestructure = DestructureAst(VoidDestructureAst(Range.empty));

Expr checkCallSpecialCb1(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range diagRange,
	Symbol funName,
	ref Expected expected,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cbArg,
) =>
	checkCallSpecialCbN(
		ctx, locals, source, diagRange, funName, expected, 1,
		(size_t i, ref Expected argExpected) {
			assert(i == 0);
			return cbArg(argExpected);
		});

Expr checkCallSpecialCb2(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range diagRange,
	Symbol funName,
	ref Expected expected,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cbArg0,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cbArg1,
	in bool delegate(scope ref Candidate[]) @safe @nogc pure nothrow cbBeforeCheck,
) =>
	checkCallSpecialCbN(
		ctx, locals, source, diagRange, funName, expected,
		typeArg: none!Type,
		nArgs: 2,
		cbCheckArg: (size_t i, ref Expected argExpected) {
			final switch (i) {
				case 0:
					return cbArg0(argExpected);
				case 1:
					return cbArg1(argExpected);
			}
		},
		cbAdditionalFilter: (in CalledDecl _) => true,
		cbBeforeCheck: cbBeforeCheck);

Expr checkCallSpecialCbN(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range diagRange,
	Symbol funName,
	ref Expected expected,
	size_t nArgs,
	in Expr delegate(size_t, ref Expected) @safe @nogc pure nothrow cbCheckArg,
) =>
	checkCallSpecialCbN(
		ctx, locals, source, diagRange, funName, expected, none!Type, nArgs, cbCheckArg,
		(in CalledDecl _) => true,
		(scope ref Candidate[]) => true);
private Expr checkCallSpecialCbN(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Range diagRange,
	Symbol funName,
	ref Expected expected,
	Opt!Type typeArg,
	size_t nArgs,
	in Expr delegate(size_t, ref Expected) @safe @nogc pure nothrow cbCheckArg,
	in bool delegate(in CalledDecl) @safe @nogc pure nothrow cbAdditionalFilter,
	in bool delegate(scope ref Candidate[]) @safe @nogc pure nothrow cbBeforeCheck,
) {
	ExactSizeArrayBuilder!Expr argsBuilder = newExactSizeArrayBuilder!Expr(ctx.alloc, nArgs);
	CallInnerResult innerResult = checkCallCb(
		ctx, locals, diagRange, funName, typeArg, nArgs, expected,
		(size_t i, ref Expected argExpected) {
			argsBuilder ~= cbCheckArg(i, argExpected);
		},
		cbAdditionalFilter,
		cbBeforeCheck);
	SmallArray!Expr args = small!Expr(finishAllowSmaller(argsBuilder));
	return innerResult.match!Expr(
		(Called called) =>
			// Check should always succeed, but we need it to set the inferred type
			check(ctx, expected, called.returnType, source, ExprKind(CallExpr(called, args))),
		(CallInnerResult.Failure failure) {
			SmallArray!CalledDecl candidates = getCandidateDeclsForBogus(ctx, funName);
			if (isEmpty(candidates))
				return bogus(expected, source);
			else {
				setToBogusIfInferring(expected);
				return Expr(source, ExprKind(BogusCallExpr(
					candidates,
					exprsAndTypes(ctx.alloc, args, failure.argTypes))));
			}
 		});
}
private SmallArray!ExprAndType exprsAndTypes(ref Alloc alloc, SmallArray!Expr args, SmallArray!Type types) =>
	mapZip!(ExprAndType, Expr, Type)(alloc, args, types, (ref Expr x, ref Type y) => ExprAndType(x, y));
private SmallArray!CalledDecl getCandidateDeclsForBogus(ref ExprCtx ctx, Symbol funName) =>
	buildSmallArray!CalledDecl(ctx.alloc, (scope ref Builder!CalledDecl res) {
		eachFunInScope(funsInExprScope(ctx), funName, (CalledDecl called) {
			res ~= called;
		});
	});

private alias CbCheckArg = void delegate(size_t argIndex, ref Expected) @safe @nogc pure nothrow;
private CallInnerResult checkCallCb(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Range diagRange,
	Symbol funName,
	Opt!Type typeArg,
	size_t nArgs,
	ref Expected expected,
	in CbCheckArg cbCheckArg,
	in bool delegate(in CalledDecl) @safe @nogc pure nothrow cbAdditionalFilter,
	in bool delegate(scope ref Candidate[]) @safe @nogc pure nothrow cbBeforeCheck,
) {
	PerfMeasurer perfMeasurer = startMeasure(ctx.perf, ctx.alloc, PerfMeasure.checkCall);
	scope(exit) endMeasure(ctx.perf, ctx.alloc, perfMeasurer);
	return withCandidates!CallInnerResult(
		funsInExprScope(ctx), funName, nArgs,
		(ref Candidate candidate) =>
			(!has(typeArg) || filterCandidateByExplicitTypeArg(ctx.commonTypes, candidate, force(typeArg))) &&
			matchExpectedVsReturnTypeNoDiagnostic(
				ctx.instantiateCtx, expected,
				TypeAndContext(candidate.called.returnType, typeContextForCandidate(candidate))) &&
			cbAdditionalFilter(candidate.called),
		(scope Candidate[] candidates) =>
			cbBeforeCheck(candidates)
				? checkCallInner(
					ctx, locals, diagRange, funName, typeArg,
					perfMeasurer, candidates, expected, nArgs, cbCheckArg)
				: CallInnerResult(CallInnerResult.Failure(emptySmallArray!Type)));
}

Expr checkCallIdentifier(alias checkExpr)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	Symbol name,
	ref Expected expected,
) {
	if (name == symbol!"new")
		addDiag2(ctx, source.range, Diag(DiagCallShouldUseSyntax(0, DiagCallShouldUseSyntaxKind.new_)));
	return checkCallSpecial!checkExpr(ctx, locals, source, source.range, name, [], expected);
}

Opt!Called findFunctionForReturnAndParamTypes(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	FunsInScope funsInScope,
	FunFlags outermostFunFlags,
	SymbolSet externs,
	in LocalsInfo locals,
	Symbol name,
	Range diagRange,
	Opt!Type typeArg,
	in ReturnAndParamTypes returnAndParamTypes,
	in bool delegate() @safe @nogc pure nothrow canDoUnsafe,
) {
	size_t arity = returnAndParamTypes.paramTypes.length;
	return withCandidates!(Opt!Called)(
		funsInScope,
		name,
		arity,
		(scope ref Candidate x) =>
			(!has(typeArg) || filterCandidateByExplicitTypeArg(commonTypes, x, force(typeArg))) &&
			testCandidateForSpecSig(ctx.instantiateCtx, x, returnAndParamTypes, TypeContext.nonInferring),
		(scope Candidate[] candidates) {
			if (candidates.length != 1) {
				// TODO: If there is a function with the name, at least indicate that in the diag
				addDiag(ctx, diagRange, candidates.length == 0
					? Diag(DiagFunctionWithSignatureNotFound(
						name, typeContainer,
						ReturnAndParamTypes(copyArray!Type(ctx.alloc, returnAndParamTypes.returnAndParamTypes))))
					: Diag(DiagCallMultipleMatches(name, typeContainer,
						map(ctx.alloc, candidates, (ref Candidate x) => x.called))));
				return none!Called;
			} else
				return some(checkCallAfterChoosingOverload(
					ctx, commonTypes, typeContainer, funsInScope, outermostFunFlags, externs, locals,
					only(candidates), diagRange, arity, canDoUnsafe));
		});
}

private:

Expr checkOptionCall(alias checkExpr)(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	ref CallAst ast,
	ref Expected outerExpected,
) =>
	checkWithModifyExpected!2(
		ctx, outerExpected,
		// For the return type:
		// The whole expression should be expected to be an option, and the call's return type is the non-optional type.
		(Type option) {
			Opt!Type res = tryUnpackOptionType(ctx.commonTypes, option);
			return has(res) ? some!(Type[2])([force(res), option]) : none!(Type[2]);
		},
		(ref Expected innerExpected) {
			Late!ExprAndType firstArg = late!ExprAndType;
			assert(ast.args.length != 0);
			ExactSizeArrayBuilder!Expr restArgs = newExactSizeArrayBuilder!Expr(ctx.alloc, ast.args.length - 1);
			CallInnerResult res = checkCallCb(
				ctx, locals, ast.funName.range, ast.funName.name, none!Type, ast.args.length, innerExpected,
				(size_t index, ref Expected argExpected) {
					ExprAst* argAst = &ast.args[index];
					if (index == 0) {
						// For the first argument: It's opposite of for the return type.
						// The call is expecting a non-option, but change that to be expecting an option.
						checkWithModifyExpected!1(
							ctx, argExpected,
							(Type x) => some!(Type[1])([Type(makeOptionType(ctx.instantiateCtx, ctx.commonTypes, x))]),
							(ref Expected optionalArgExpected) {
								Expr expr = checkExpr(ctx, locals, argAst, optionalArgExpected);
								Type option = inferred(optionalArgExpected);
								lateSet(firstArg, ExprAndType(expr, option));
								// We wrapped expected types in diagnostics, so it must unpack to an option
								Type nonOption = force(tryUnpackOptionType(ctx.commonTypes, option));
								return ExprAndType(expr, nonOption);
							});
					} else
						restArgs ~= checkExpr(ctx, locals, argAst, argExpected);
				},
				(in CalledDecl _) => true,
				(scope ref Candidate[] _) => true);
			return res.match!ExprAndType(
				(Called called) =>
					ExprAndType(
						Expr(source, ExprKind(allocate(ctx.alloc,
							CallOptionExpr(called, lateGet(firstArg), smallFinish(restArgs))))),
						makeOptionIfNotAlready(ctx.instantiateCtx, ctx.commonTypes, called.returnType)),
				(CallInnerResult.Failure) =>
					ExprAndType(bogus(innerExpected, source), Type.bogus));
		}).expr;


immutable struct CallInnerResult {
	immutable struct Failure { SmallArray!Type argTypes; }
	mixin Union!(Called, Failure);
}
CallInnerResult checkCallInner(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	in Range diagRange,
	Symbol funName,
	in Opt!Type explicitTypeArg,
	scope ref PerfMeasurer perfMeasurer,
	scope ref Candidate[] candidates,
	ref Expected expected,
	size_t nArgs,
	in CbCheckArg cbCheckArg,
) =>
	withMaxStackArray!(CallInnerResult, Type)(nArgs, (scope ref MaxStackArray!Type actualArgTypesBuilder) {
		bool someArgIsBogus = false;
		foreach (size_t argIdx; 0 .. nArgs) {
			if (isEmpty(candidates))
				break;

			filterUnorderedButDontRemoveAll(candidates, (ref Candidate x) =>
				preCheckCandidateSpecs(ctx, x));

			Type argType = withParamExpected(ctx.instantiateCtx, candidates, argIdx, (ref Expected argExpected) {
				pauseMeasure(ctx.perf, ctx.alloc, perfMeasurer);
				cbCheckArg(argIdx, argExpected);
				resumeMeasure(ctx.perf, ctx.alloc, perfMeasurer);
			});
			actualArgTypesBuilder ~= argType;
			// If it failed to check, don't continue, just stop there.
			if (argType.isBogus) {
				someArgIsBogus = true;
				candidates = [];
				break;
			}
			filterUnordered(candidates, (ref Candidate candidate) =>
				testCandidateParamType(ctx.instantiateCtx, candidate, argIdx, nonInferring(argType)));
		}
		scope SmallArray!Type actualArgTypes = small!Type(actualArgTypesBuilder.finish);

		if (someArgIsBogus)
			return CallInnerResult(CallInnerResult.Failure(newSmallArray(ctx.alloc, actualArgTypes)));

		filterUnorderedButDontRemoveAll(candidates, (ref Candidate x) =>
			preCheckCandidateSpecs(ctx, x));

		if (candidates.length != 1) {
			SmallArray!Type allocatedArgTypes = newSmallArray(ctx.alloc, actualArgTypes);
			if (isEmpty(candidates)) {
				CalledDecl[] allCandidates = getAllCandidatesAsCalledDecls(ctx, funName);
				addDiag2(ctx, diagRange, Diag(DiagCallNoMatch(
					ctx.typeContainer,
					funName,
					getExpectedForDiag(ctx, expected),
					getNTypeArgsForDiagnostic(ctx.commonTypes, explicitTypeArg),
					nArgs,
					allocatedArgTypes,
					allCandidates)));
			} else
				addDiag2(ctx, diagRange, Diag(
					DiagCallMultipleMatches(funName, ctx.typeContainer, candidatesForDiag(ctx.alloc, candidates))));
			return CallInnerResult(CallInnerResult.Failure(allocatedArgTypes));
		} else
			return CallInnerResult(checkCallAfterChoosingOverload(
				ctx.checkCtx, ctx.commonTypes, ctx.typeContainer, funsInExprScope(ctx),
				ctx.outermostFunFlags, ctx.externs, locals, only(candidates), diagRange, nArgs,
				() => checkCanDoUnsafe(ctx)));
	});

void checkCallShouldUseSyntax(ref ExprCtx ctx, in CallAst ast) {
	switch (ast.style) {
		case CallAst.Style.dot:
		case CallAst.Style.infix:
			Opt!DiagCallShouldUseSyntaxKind kind = shouldUseSyntaxKind(ast);
			if (has(kind))
				addDiag2(ctx, ast.funName.range, Diag(DiagCallShouldUseSyntax(ast.args.length, force(kind))));
			break;
		default:
			break;
	}
}

Opt!DiagCallShouldUseSyntaxKind shouldUseSyntaxKind(in CallAst ast) {
	switch (ast.funName.name.value) {
		case symbol!"for-break".value:
			return optIf(secondArgIsLambda(ast), () => DiagCallShouldUseSyntaxKind.for_break);
		case symbol!"force".value:
			return some(DiagCallShouldUseSyntaxKind.force);
		case symbol!"for-loop".value:
			return optIf(secondArgIsLambda(ast), () => DiagCallShouldUseSyntaxKind.for_loop);
		case symbol!"new".value:
			return some(DiagCallShouldUseSyntaxKind.new_);
		case symbol!"not".value:
			return some(DiagCallShouldUseSyntaxKind.not);
		case symbol!"set-subscript".value:
			return some(DiagCallShouldUseSyntaxKind.set_subscript);
		case symbol!"subscript".value:
			return some(DiagCallShouldUseSyntaxKind.subscript);
		case symbol!"with-block".value:
			return optIf(secondArgIsLambda(ast), () => DiagCallShouldUseSyntaxKind.with_block);
		default:
			return none!DiagCallShouldUseSyntaxKind;
	}
}
bool secondArgIsLambda(in CallAst ast) =>
	ast.args.length == 2 && ast.args[1].kind.isA!(LambdaAst*);

bool filterCandidateByExplicitTypeArg(ref CommonTypes commonTypes, scope ref Candidate candidate, Type typeArg) {
	size_t nTypeParams = candidate.typeArgs.length;
	Type[] args = unpackTupleIfNeeded(commonTypes, nTypeParams, &typeArg);
	bool ok = args.length == nTypeParams;
	if (ok)
		foreach (size_t i, ref SingleInferringType x; candidate.typeArgs)
			x.setAndIgnoreExisting(args[i]);
	return ok;
}

Type withParamExpected(
	InstantiateCtx ctx,
	scope ref Candidate[] candidates,
	size_t argIdx,
	in void delegate(ref Expected) @safe @nogc pure nothrow cb,
) =>
	withMaxStackArray!(Type, TypeAndContext)(candidates.length, (ref MaxStackArray!TypeAndContext out_) {
		foreach (ref Candidate candidate; candidates) {
			TypeAndContext expected = getCandidateExpectedParameterType(ctx, candidate, argIdx);
			bool isDuplicate = !expected.context.isInferring &&
				exists!TypeAndContext(out_.soFar, (in TypeAndContext x) =>
					!x.context.isInferring && x.type == expected.type);
			if (!isDuplicate)
				out_ ~= expected;
		}
		return withExpectCandidates(out_.finish, cb);
	});

void inferCandidateTypeArgsFromCheckedSpecSig(
	InstantiateCtx ctx,
	ref const Candidate specCandidate,
	in Signature specSig,
	in ReturnAndParamTypes sigTypes,
	scope TypeContext callInferringTypeArgs,
) {
	inferTypeArgsFrom(
		ctx, sigTypes.returnType, callInferringTypeArgs,
		const TypeAndContext(specCandidate.called.returnType, typeContextForCandidate(specCandidate)));
	foreach (size_t argIdx; 0 .. specSig.params.length)
		inferTypeArgsFrom(
			ctx, sigTypes.paramTypes[argIdx], callInferringTypeArgs,
			getCandidateExpectedParameterType(ctx, specCandidate, argIdx));
}

enum TypeArgsInferenceState { none, partial, all }
TypeArgsInferenceState getInferenceState(in SingleInferringType[] typeArgs) {
	bool hasInferred = false;
	bool hasUninferred = true;
	foreach (ref const SingleInferringType x; typeArgs) {
		if (has(tryGetInferred(x)))
			hasInferred = true;
		else
			hasUninferred = true;
	}
	return hasInferred
		? hasUninferred ? TypeArgsInferenceState.partial : TypeArgsInferenceState.all
		: TypeArgsInferenceState.none;
}

enum ContinueOrAbort { continue_, abort }

ContinueOrAbort inferCandidateTypeArgsFromExplicitlyTypedArgument(
	ref ExprCtx ctx,
	scope ref Candidate[] candidates,
	size_t argIndex,
	in ExprAst arg,
) =>
	arg.kind.isA!(LambdaAst*)
		? inferCandidateTypeArgsFromLambdaParameter(ctx, candidates, argIndex, arg.kind.as!(LambdaAst*).param)
		: ContinueOrAbort.continue_;

ContinueOrAbort inferCandidateTypeArgsFromLambdaParameter(
	ref ExprCtx ctx,
	scope ref Candidate[] candidates,
	size_t argIndex,
	ref DestructureAst paramAst,
) {
	// TODO: this means we may do 'typeFromDestructure' twice, once here and once when checking,
	// leading to duplicate diagnostics
	Opt!Type optLambdaParamType = typeFromDestructure2(ctx, paramAst);
	if (has(optLambdaParamType)) {
		Type lambdaParamType = force(optLambdaParamType);
		if (lambdaParamType.isBogus)
			return ContinueOrAbort.abort;
		else {
			foreach (ref Candidate candidate; candidates) {
				TypeAndContext paramType = getCandidateExpectedParameterType(
					ctx.instantiateCtx, candidate, argIndex);
				inferTypeArgsFromLambdaParameterType(
					ctx.instantiateCtx, paramType.type, typeContextForCandidate(candidate), lambdaParamType);
			}
			return ContinueOrAbort.continue_;
		}
	} else
		return ContinueOrAbort.continue_;
}

// This is not the final check, but we do filter out some candidates or infer type arguments early based on specs.
bool preCheckCandidateSpecs(ref ExprCtx ctx, ref Candidate candidate) {
	// For performance, don't bother unless we have something to infer from already
	TypeArgsInferenceState state = getInferenceState(candidate.typeArgs);
	return state == TypeArgsInferenceState.none || candidate.called.match!bool(
		(ref FunDecl called) =>
			every!(immutable SpecInst*)(called.specs, (in immutable SpecInst* spec) =>
				preCheckCandidateSpec(ctx, candidate, called, *spec, state)),
		(CalledSpecSig _) => true);
}

bool preCheckCandidateSpec(
	ref ExprCtx ctx,
	ref Candidate callCandidate,
	in FunDecl called,
	in SpecInst spec,
	TypeArgsInferenceState state,
) =>
	every!(immutable SpecInst*)(spec.parents, (in immutable SpecInst* parent) =>
		preCheckCandidateSpec(ctx, callCandidate, called, *parent, state)
	) &&
	// For a builtin spec, we'll leave it for the end.
	(state != TypeArgsInferenceState.partial || zipEvery!(Signature, ReturnAndParamTypes)(
		spec.decl.sigs, spec.sigTypes, (ref Signature sig, ref ReturnAndParamTypes returnAndParamTypes) =>
			inferCandidateTypeArgsFromSpecSig(ctx, callCandidate, called, sig, returnAndParamTypes)));

bool inferCandidateTypeArgsFromSpecSig(
	ref ExprCtx ctx,
	ref Candidate callCandidate,
	in FunDecl called,
	in Signature specSig,
	in ReturnAndParamTypes returnAndParamTypes,
) {
	TypeContext callContext = typeContextForCandidate(callCandidate);
	return withCandidates!bool(
		funsInExprScope(ctx),
		specSig.name,
		specSig.params.length,
		(ref Candidate x) =>
			testCandidateForSpecSig(ctx.instantiateCtx, x, returnAndParamTypes, callContext),
		(scope Candidate[] specCandidates) {
			switch (specCandidates.length) {
				case 0:
					return false;
				case 1:
					inferCandidateTypeArgsFromCheckedSpecSig(
						ctx.instantiateCtx, only(specCandidates), specSig, returnAndParamTypes, callContext);
					return true;
				default:
					return true;
			}
		});
}

Called checkCallAfterChoosingOverload(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	FunsInScope funsInScope,
	in FunFlags outermostFunFlags,
	SymbolSet externs,
	in LocalsInfo locals,
	ref const Candidate candidate,
	in Range diagRange,
	size_t nArgs,
	in bool delegate() @safe @nogc pure nothrow canDoUnsafe,
) {
	Called called = checkCallSpecs(ctx, commonTypes, typeContainer, funsInScope, diagRange, candidate);
	checkCalled(
		ctx, diagRange, called, outermostFunFlags, externs, locals,
		nArgs == 0 ? ArgsKind.empty : ArgsKind.nonEmpty, canDoUnsafe);
	return called;
}
