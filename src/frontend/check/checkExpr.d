module frontend.check.checkExpr;

@safe @nogc pure nothrow:

import frontend.check.checkCall.candidates : Candidate, funsInExprScope;
import frontend.check.checkCall.checkCall :
	checkCall,
	checkCallArgAnd2Lambdas,
	checkCallArgAndLambda,
	checkCallIdentifier,
	checkCallNamed,
	checkCallSpecial,
	checkCallSpecialCb1,
	checkCallSpecialCb2,
	checkCallSpecialCbN,
	findFunctionForReturnAndParamTypes;
import frontend.check.checkCall.checkCallSpecs :
	checkSpecSingleSigIgnoreParents2, isPurityAlwaysCompatibleConsideringSpecs, isShared;
import frontend.check.checkCtx : CheckCtx, CommonModule;
import frontend.check.checkUtil : checkExternName, checkLiteralIntegralValue;
import frontend.check.exprCtx :
	addDiag2,
	checkCanDoUnsafe,
	checkDestructure2,
	ClosureFieldBuilder,
	ExprCtx,
	LambdaInfo,
	LocalAccessKind,
	LocalNode,
	LocalsInfo,
	markIsUsedSetOnStack,
	typeFromAst2,
	typeFromDestructure2,
	typeWithContainer,
	withTrusted;
import frontend.check.inferringType :
	bogus,
	check,
	Expected,
	ExpectedLambdaType,
	ExprAndOptionType,
	findExpectedStructForLiteral,
	getExpectedForDiag,
	getExpectedLambda,
	LoopInfo,
	matchTypes,
	nonInferring,
	Pair,
	SingleInferringType,
	tryGetInferred,
	tryGetNonInferringType,
	tryGetNonInferringTypeIncludingLoop,
	tryGetLoop,
	TypeAndContext,
	TypeContext,
	withCopyWithNewExpectedType,
	withExpect,
	withExpectLoop,
	withExpectOption,
	withInfer;
import frontend.check.instantiate :
	instantiateSpec, instantiateStruct, instantiateStructInst, instantiateStructWithOwnTypeParams;
import frontend.check.maps : FunsMap, SpecsMap, StructsAndAliasesMap;
import frontend.check.typeFromAst :
	DestructureKind,
	getSpecFromCommonModule,
	makeTupleType,
	structOrAliasFromName,
	unpackTuple;
import model.ast :
	ArrowAccessAst,
	AsBogusAst,
	AsNameAst,
	AssertOrForbidAst,
	AssignmentAst,
	AssignmentCallAst,
	AsStringAst,
	BogusAst,
	CallAst,
	CallAstStyle,
	CallNamedAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	DestructureAst,
	DoAst,
	EmptyAst,
	ExprAst,
	ExternAst,
	FinallyAst,
	ForAst,
	HighPrecisionFloat,
	IfAst,
	InterpolatedAst,
	LambdaAst,
	LetAst,
	LiteralFloatAndRange,
	LiteralIntegralAndRange,
	LiteralStringAst,
	LoopAst,
	LoopBreakAst,
	LoopContinueAst,
	LoopWhileOrUntilAst,
	MatchAst,
	NameAndRange,
	ParenthesizedAst,
	PtrAst,
	SeqAst,
	SharedAst,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	UnpackOptionAst,
	WithAst;
import model.integralValues : IntegralValue;
import model.model :
	asExtern,
	AssertOrForbidExpr,
	BogusExpr,
	BuiltinFun,
	BuiltinType,
	BuiltinUnary,
	Called,
	CalledBogus,
	CalledSpecSig,
	CallExpr,
	CallExprSource,
	CharType,
	ClosureGetExpr,
	ClosureRef,
	ClosureSetExpr,
	CommonTypes,
	Condition,
	Destructure,
	DestructureIgnore,
	DestructureIgnoreSource,
	DestructureSplit,
	Diag,
	DiagAssertOrForbidMessageIsThrow,
	DiagAssignmentNotAllowed,
	DiagCharLiteralMustBeOneChar,
	DiagDuplicateDeclaration,
	DiagDuplicateDeclarationKind,
	DiagExternIsUnsafe,
	DiagFunPointerExprMustBeName,
	DiagFunPointerNotBare,
	DiagIfThrow,
	DiagLambdaCantBeFunctionPointer,
	DiagLambdaClosurePurity,
	DiagLiteralFloatAccuracy,
	DiagLocalNotMutable,
	DiagLoopDisallowedBody,
	DiagLoopWithoutBreak,
	DiagMatchCaseDuplicate,
	DiagMatchCaseForType,
	DiagMatchCaseNameNotInEnum,
	DiagMatchCaseNoValueForEnumOrSymbol,
	DiagMatchCaseShouldUseIgnore,
	DiagMatchNeedsElse,
	DiagMatchOnNonMatchable,
	DiagMatchSumTypeCantInferTypeArgs,
	DiagMatchSumTypeNoMember,
	DiagMatchUnhandledCases,
	DiagMatchUnnecessaryElse,
	DiagNeedsExpectedType,
	DiagPointerIsNative,
	DiagPointerIsUnsafe,
	DiagPointerMutToConst,
	DiagPointerUnsupported,
	DiagSharedArgIsNotLambda,
	DiagSharedLambdaTypeIsNotShared,
	DiagSharedLambdaTypeIsNotSharedKind,
	DiagSharedLambdaUnused,
	DiagSharedNotExpected,
	DiagStringLiteralInvalid,
	DiagTypeAnnotationUnnecessary,
	DiagUnusedLocal,
	DiagWithHasElse,
	emptySpecs,
	emptyTypeParams,
	Enum,
	EnumMember,
	Expr,
	ExprAndType,
	ExternCondition,
	ExternExpr,
	ExternType,
	FinallyExpr,
	Flags,
	FloatType,
	FunDecl,
	FunFlags,
	FunInst,
	FunKind,
	FunPointerExpr,
	IfExpr,
	IntegralType,
	IntegralTypes,
	isDefinitelyByRef,
	isEmptyType,
	isSigned,
	LambdaExpr,
	LambdaKind,
	LambdaSource,
	LetExpr,
	LiteralExpr,
	LiteralStringLikeExpr,
	LiteralValue,
	Local,
	LocalGetExpr,
	localMustHaveNameRange,
	LocalMutability,
	LocalMutableAllocated,
	LocalMutableOnStack,
	LocalPointerExpr,
	LocalSetExpr,
	LoopExpr,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopWhileOrUntilExpr,
	MatchEnumCase,
	MatchEnumExpr,
	MatchIntegralCase,
	MatchIntegralExpr,
	MatchIntegralKind,
	MatchStringLikeCase,
	MatchStringLikeExpr,
	MatchSumTypeCase,
	MatchSumTypeExpr,
	Mutability,
	paramsArray,
	purityRange,
	Purity,
	Record,
	RecordFieldGet,
	RecordFieldPointerExpr,
	ReturnAndParamTypes,
	SeqExpr,
	SpecDecl,
	StringLiteralKind,
	StructAlias,
	StructBodyBogus,
	StructDecl,
	StructInst,
	StructOrAlias,
	SumType,
	SumTypeKind,
	SumTypeMemberAndMethodImpls,
	SumTypeMembership,
	ThrowExpr,
	toMutability,
	TrustedExpr,
	TryExpr,
	TryLetExpr,
	Type,
	TypeContainer,
	TypeWithContainer,
	TypedExpr,
	UnpackOption,
	VariableRef;
import model.sourceRange : Pos, Range;
import util.alloc.stackAlloc : MaxStackArray, withMapToStackArray, withMaxStackArray, withStackArray;
import util.cell : Cell;
import util.col.array :
	arrayOfSingle,
	contains,
	every,
	exists,
	first,
	indexOf,
	isEmpty,
	map,
	mapOpPointers,
	mustHaveIndexOfPointer,
	only,
	PtrAndSmallNumber,
	small,
	SmallArray,
	zipPtrFirst;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.enumMap : EnumMap, makeEnumMap;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, newExactSizeArrayBuilder, smallFinish;
import util.col.tempSet : TempSet, tryAdd, withTempSet;
import util.conv : powerOf10, safeToUshort, toLongWithOverflow;
import util.memory : allocate, overwriteMemory;
import util.opt : force, has, MutOpt, none, noneMut, Opt, optIf, optOr, optOrDefault, someMut, some;
import util.string : CString, smallString;
import util.symbol : prependSet, prependSetDeref, stringOfSymbol, Symbol, symbol;
import util.symbolSet : buildSymbolSet, SymbolSet, SymbolSetBuilder;
import util.unicode : decodeAsSingleUnicodeChar;
import util.union_ : Union;
import util.util : castImmutable, castNonScope_ref, ptrTrustMe;
import util.writer : withStackWriterCString, Writer;

Expr checkFunctionBody(
	ref CheckCtx checkCtx,
	in StructsAndAliasesMap structsAndAliasesMap,
	in CommonTypes commonTypes,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	FunDecl* fun,
	ExprAst* ast,
) {
	assert(!fun.returnType.isBogus);
	ExprCtx exprCtx = ExprCtx(
		ptrTrustMe(checkCtx),
		structsAndAliasesMap,
		specsMap,
		funsMap,
		ptrTrustMe(commonTypes),
		TypeContainer(fun),
		fun.specs,
		fun.typeParams,
		fun.flags,
		Cell!SymbolSet(fun.externs));
	Expr res = checkWithParamDestructures(
		castNonScope_ref(exprCtx), ast, paramsArray(fun.params),
		(ref LocalsInfo innerLocals) =>
			checkAndExpect(castNonScope_ref(exprCtx), innerLocals, ast, fun.returnType));
	return res;
}

Expr checkTestBody(
	ref CheckCtx checkCtx,
	in StructsAndAliasesMap structsAndAliasesMap,
	ref CommonTypes commonTypes,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	TypeContainer typeContainer,
	FunFlags flags,
	SymbolSet externs,
	ExprAst* ast,
) {
	ExprCtx exprCtx = ExprCtx(
		ptrTrustMe(checkCtx),
		structsAndAliasesMap,
		specsMap,
		funsMap,
		ptrTrustMe(commonTypes),
		typeContainer,
		emptySpecs,
		emptyTypeParams,
		flags,
		Cell!SymbolSet(externs));
	LocalsInfo locals = LocalsInfo(0, noneMut!(LambdaInfo*), noneMut!(LocalNode*));
	return checkAndExpect(castNonScope_ref(exprCtx), locals, ast, Type(commonTypes.void_));
}

private:

Expr checkExpr(ref ExprCtx ctx, ref LocalsInfo locals, ExprAst* ast, ref Expected expected) =>
	ast.matchWithPointers!Expr(
		(ArrowAccessAst _) =>
			checkArrowAccess(ctx, locals, &ast.as!ArrowAccessAst(), expected),
		(AssertOrForbidAst _) =>
			checkAssertOrForbid(ctx, locals, &ast.as!AssertOrForbidAst(), expected),
		(AssignmentAst* a) =>
			checkAssignment(ctx, locals, CallExprSource(a), &a.left, a.keywordRange, expected, (ref Expected rightExpected) =>
				checkExpr(ctx, locals, &a.right, rightExpected)),
		(AssignmentCallAst a) =>
			checkAssignmentCall(ctx, locals, &ast.as!AssignmentCallAst(), expected),
		(BogusAst _) =>
			bogus(expected, ast),
		(CallAst _) =>
			checkCall!checkExpr(ctx, locals, &ast.as!CallAst(), expected),
		(CallNamedAst _) =>
			checkCallNamed!checkExpr(ctx, locals, &ast.as!CallNamedAst(), expected),
		(DoAst a) =>
			checkExpr(ctx, locals, a.body_, expected),
		(EmptyAst a) =>
			checkEmptyNew(ctx, locals, CallExprSource(&ast.as!EmptyAst()), ast.range, expected),
		(ExternAst _) =>
			checkExtern(ctx, locals, &ast.as!ExternAst(), expected),
		(FinallyAst* a) =>
			checkFinally(ctx, locals, a, expected),
		(ForAst* a) =>
			checkFor(ctx, locals, a, expected),
		(NameAndRange _) =>
			checkIdentifier(ctx, locals, &ast.as!NameAndRange(), expected),
		(IfAst _) =>
			checkIf(ctx, locals, &ast.as!IfAst(), expected),
		(InterpolatedAst _) =>
			checkInterpolated(ctx, locals, &ast.as!InterpolatedAst(), expected),
		(LambdaAst* a) =>
			checkLambda(ctx, locals, LambdaSource(a), &a.param, &a.body_, expected),
		(LetAst* a) =>
			checkLet(ctx, locals, a, expected),
		(LiteralFloatAndRange a) =>
			checkLiteralFloat(ctx, ast, a, expected),
		(LiteralIntegralAndRange a) =>
			checkLiteralIntegral(ctx, ast, a, expected),
		(LiteralStringAst a) =>
			checkLiteralString(ctx, ast, a.value, expected),
		(LoopAst* a) =>
			checkLoop(ctx, locals, a, expected),
		(LoopBreakAst* a) =>
			checkLoopBreak(ctx, locals, a, expected),
		(LoopContinueAst _) =>
			checkLoopContinue(ctx, locals, &ast.as!LoopContinueAst(), expected),
		(LoopWhileOrUntilAst* a) =>
			checkLoopWhileOrUntil(ctx, locals, a, expected),
		(MatchAst _) =>
			checkMatch(ctx, locals, &ast.as!MatchAst(), expected),
		(ParenthesizedAst* a) =>
			checkExpr(ctx, locals, &a.inner, expected),
		(PtrAst* a) =>
			checkPointer(ctx, locals, ast, a, expected),
		(SeqAst* a) =>
			checkSeq(ctx, locals, a, expected),
		(SharedAst a) =>
			checkShared(ctx, locals, &ast.as!SharedAst(), expected),
		(ThrowAst _) =>
			checkThrow(ctx, locals, &ast.as!ThrowAst(), expected),
		(TrustedAst _) =>
			checkTrusted(ctx, locals, &ast.as!TrustedAst(), expected),
		(TryAst _) =>
			checkTry(ctx, locals, &ast.as!TryAst(), expected),
		(TryLetAst* a) =>
			checkTryLet(ctx, locals, a, expected),
		(TypedAst* a) =>
			checkTyped(ctx, locals, a, expected),
		(WithAst* a) =>
			checkWith(ctx, locals, a, expected));

Expr checkWithParamDestructures(
	ref ExprCtx ctx,
	ExprAst* ast,
	Destructure[] params,
	in Expr delegate(ref LocalsInfo) @safe @nogc pure nothrow cb,
) {
	LocalsInfo locals = LocalsInfo(0, noneMut!(LambdaInfo*), noneMut!(LocalNode*));
	Opt!Expr res = checkWithParamDestructuresRecur(ctx, locals, params, (ref LocalsInfo innerLocals) =>
		some(cb(innerLocals)));
	return has(res) ? force(res) : Expr(BogusExpr(ast.range, Type.bogus));
}
Opt!Expr checkWithParamDestructuresRecur(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Destructure[] params,
	in Opt!Expr delegate(ref LocalsInfo) @safe @nogc pure nothrow cb,
) =>
	isEmpty(params)
		? cb(locals)
		: checkWithDestructure(ctx, locals, params[0], (ref LocalsInfo innerLocals) =>
			checkWithParamDestructuresRecur(ctx, innerLocals, params[1 .. $], cb));

ExprAndType checkAndInfer(ref ExprCtx ctx, ref LocalsInfo locals, ExprAst* ast) =>
	withInfer((ref Expected e) =>
		checkExpr(ctx, locals, ast, e));

ExprAndType checkAndExpectOrInfer(ref ExprCtx ctx, ref LocalsInfo locals, ExprAst* ast, Opt!Type optExpected) =>
	has(optExpected)
		? ExprAndType(checkAndExpect(ctx, locals, ast, force(optExpected)), force(optExpected))
		: checkAndInfer(ctx, locals, ast);

Expr checkAndExpect(ref ExprCtx ctx, ref LocalsInfo locals, ExprAst* ast, Type expected) =>
	withExpect(expected, (ref Expected e) =>
		checkExpr(ctx, locals, ast, e));

Type voidType(ref const ExprCtx ctx) =>
	Type(ctx.commonTypes.void_);

Expr checkArrowAccess(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ArrowAccessAst* ast,
	ref Expected expected,
) =>
	checkCallSpecialCb1(
		ctx, locals, CallExprSource(ast), ast.arrowRange, ast.name.name, expected,
		(ref Expected argExpected) =>
			checkCallSpecial!checkExpr(
				ctx, locals, CallExprSource(ast), ast.arrowRange, symbol!"*", arrayOfSingle(ast.left), argExpected));

Expr checkIf(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	IfAst* ast,
	ref Expected expected,
) {
	if (isThrow(ast.firstBranch) || (isThrow(ast.secondBranch) && !ast.isElseOfParent))
		addDiag2(ctx, ast.firstKeywordRange, Diag(DiagIfThrow()));
	Condition condition = checkCondition(ctx, locals, ast.condition);
	Opt!Destructure destructure = optDestructure(condition);
	bool isNegated = ast.isConditionNegated;
	Range emptyNewRange = ast.firstKeywordRange;
	Expr firstBranch = withExternFromCondition(ctx, condition, isNegated, () =>
		checkExprWithOptDestructureOrEmptyNew(
			ctx, locals, CallExprSource(ast),
			isNegated ? none!Destructure : destructure,
			ast.firstBranch, emptyNewRange, expected));
	Expr secondBranch = withExternFromCondition(ctx, condition, !isNegated, () =>
		checkExprWithOptDestructureOrEmptyNew(
			ctx, locals, CallExprSource(ast),
			isNegated ? destructure : none!Destructure,
			ast.secondBranch, emptyNewRange, expected));
	return Expr(allocate(ctx.alloc, IfExpr(
		ast,
		condition,
		isNegated ? secondBranch : firstBranch,
		isNegated ? firstBranch : secondBranch)));
}
bool isThrow(Opt!(ExprAst*) a) =>
	has(a) && force(a).isA!ThrowAst;

Opt!Destructure optDestructure(Condition a) =>
	a.match!(Opt!Destructure)(
		(ref Expr _) =>
			none!Destructure,
		(ref UnpackOption x) =>
			some(x.destructure));

Condition checkCondition(ref ExprCtx ctx, ref LocalsInfo locals, ConditionAst ast) =>
	ast.matchWithPointers!Condition(
		(ExprAst* x) =>
			Condition(allocate(ctx.alloc, checkAndExpect(ctx, locals, x, Type(ctx.commonTypes.bool_)))),
		(UnpackOptionAst* x) =>
			Condition(allocate(ctx.alloc, checkUnpackOption(ctx, locals, x))));
UnpackOption checkUnpackOption(ref ExprCtx ctx, ref LocalsInfo locals, UnpackOptionAst* condAst) {
	ExprAndOptionType res = withExpectOption(ctx.instantiateCtx, ctx.commonTypes, (ref Expected expected) =>
		checkExpr(ctx, locals, condAst.option, expected));
	return UnpackOption(
		checkDestructure2(ctx, &condAst.destructure, res.nonOptionType, DestructureKind.local),
		res.option);
}

Expr checkThrow(ref ExprCtx ctx, ref LocalsInfo locals, ThrowAst* ast, ref Expected expected) {
	Opt!Type type = tryGetNonInferringTypeIncludingLoop(ctx.instantiateCtx, expected);
	if (has(type))
		return Expr(allocate(ctx.alloc, ThrowExpr(
			ast,
			checkAndExpect(ctx, locals, ast.thrown, Type(ctx.commonTypes.exception)),
			force(type))));
	else {
		addDiag2(ctx, ast.range, Diag(DiagNeedsExpectedType.throw_));
		return bogus(expected, ast.range);
	}
}

Expr checkTrusted(ref ExprCtx ctx, ref LocalsInfo locals, TrustedAst* ast, ref Expected expected) {
	Expr inner = withTrusted!Expr(ctx, *ast, () => checkExpr(ctx, locals, ast.inner, expected));
	return Expr(allocate(ctx.alloc, TrustedExpr(ast, inner)));
}

Expr checkExtern(ref ExprCtx ctx, ref LocalsInfo locals, ExternAst* ast, ref Expected expected) {
	if (!checkCanDoUnsafe(ctx))
		addDiag2(ctx, ast.range, Diag(DiagExternIsUnsafe()));
	bool ok = true;
	SymbolSet names = buildSymbolSet((scope ref SymbolSetBuilder out_) {
		foreach (NameAndRange nameAst; ast.names) {
			Opt!Symbol name = checkExternName(ctx.checkCtx, nameAst, ctx.externs);
			if (has(name))
				out_ ~= force(name);
			else
				ok = false;
		}
	});
	return ok
		? check(ctx, expected, Type(ctx.commonTypes.bool_), Expr(ExternExpr(ast, names)))
		: bogus(expected, ast.range);
}

Expr checkAssertOrForbid(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	AssertOrForbidAst* ast,
	ref Expected expected,
) {
	Condition condition = checkCondition(ctx, locals, ast.condition);
	Opt!Destructure destructure = optDestructure(condition);
	bool isForbid = ast.isForbid;
	return Expr(allocate(ctx.alloc, AssertOrForbidExpr(
		ast,
		isForbid: isForbid,
		condition: condition,
		thrown: optIf(has(ast.thrown), () {
			ExprAst* thrownAst = &force(ast.thrown).expr;
			if (thrownAst.isA!ThrowAst)
				addDiag2(ctx, thrownAst.as!ThrowAst.keywordRange, Diag(DiagAssertOrForbidMessageIsThrow()));
			return allocate(ctx.alloc, withExpect(Type(ctx.commonTypes.exception), (ref Expected expectThrown) =>
				withExternFromCondition(ctx, condition, !isForbid, () =>
					checkExprWithOptDestructure(
						ctx, locals, ast.isForbid ? destructure : none!Destructure, thrownAst, expectThrown))));
		}),
		after: withExternFromCondition(ctx, condition, isForbid, () =>
			checkExprWithOptDestructure(
				ctx, locals, ast.isForbid ? none!Destructure : destructure, ast.after, expected)))));
}

Expr checkAssignment(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	CallExprSource source,
	ExprAst* left,
	Range keywordRange,
	ref Expected expected,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cbRight,
) {
	if (left.isA!NameAndRange)
		return checkAssignIdentifier(ctx, locals, &left.as!NameAndRange(), keywordRange, left.as!NameAndRange.name, expected, cbRight);
	else if (left.isA!CallAst) {
		CallAst leftCall = left.as!CallAst;
		Opt!Symbol name = () {
			switch (leftCall.style) {
				case CallAstStyle.dot:
					return some(prependSet(leftCall.funName.name));
				case CallAstStyle.prefixOperator:
					return leftCall.funName.name == symbol!"*" ? some(symbol!"set-deref") : none!Symbol;
				case CallAstStyle.subscript:
					return some(symbol!"set-subscript");
				default:
					return none!Symbol;
			}
		}();
		if (has(name))
			return checkCallSpecialCbN(
				ctx, locals, source, keywordRange, force(name), expected, leftCall.args.length + 1,
				(size_t i, ref Expected argExpected) =>
					i == leftCall.args.length
						? cbRight(argExpected)
						: checkExpr(ctx, locals, &leftCall.args[i], argExpected));
		else {
			addDiag2(ctx, left.range, Diag(DiagAssignmentNotAllowed()));
			return bogus(expected, source.range);
		}
	} else if (left.isA!ArrowAccessAst) {
		ArrowAccessAst leftArrow = left.as!ArrowAccessAst;
		return checkCallSpecialCb2(
			ctx, locals, source, keywordRange,
			prependSetDeref(leftArrow.name.name),
			expected,
			(ref Expected argExpected) => checkExpr(ctx, locals, leftArrow.left, argExpected),
			cbRight,
			(scope ref Candidate[]) => true);
	} else {
		addDiag2(ctx, left.range, Diag(DiagAssignmentNotAllowed()));
		return bogus(expected, source.range);
	}
}

Expr checkAssignmentCall(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	AssignmentCallAst* ast,
	ref Expected expected,
) =>
	checkAssignment(ctx, locals, CallExprSource(ast), &ast.left(), ast.keywordRange, expected, (ref Expected argExpected) =>
		checkCallSpecial!checkExpr(
			ctx, locals, CallExprSource(ast), ast.funName.range, ast.funName.name, *ast.leftAndRight, argExpected));

Expr checkEmptyNew(ref ExprCtx ctx, ref LocalsInfo locals, CallExprSource source, in Range range, ref Expected expected) =>
	checkCallSpecial!checkExpr(ctx, locals, source, range, symbol!"new", [], expected);

Expr checkInterpolated(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	InterpolatedAst* ast,
	ref Expected expected,
) =>
	checkCallSpecialCbN(
		ctx, locals, CallExprSource(ast), ast.range[0 .. 1], symbol!"interpolate", expected, ast.parts.length,
		(size_t i, ref Expected argExpected) {
			ExprAst* part = &ast.parts[i];
			return part.isA!LiteralStringAst
				? checkLiteralString(ctx, part, part.as!LiteralStringAst.value, argExpected)
				: checkCallSpecial!checkExpr(
					ctx, locals, CallExprSource(ast), part.range, symbol!"show", arrayOfSingle(part), argExpected);
		});

struct VariableRefAndType {
	@safe @nogc pure nothrow:

	immutable VariableRef variableRef;
	immutable Mutability mutability;
	EnumMap!(LocalAccessKind, bool)* isUsed; // null for Param
	immutable Type type;

	@trusted void setIsUsed(LocalAccessKind kind) {
		if (isUsed != null)
			(*isUsed)[kind] = true;
	}
}

MutOpt!VariableRefAndType getIdentifierNonCall(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Opt!Range diagRange, // If missing, no diags
	Symbol name,
	LocalAccessKind accessKind,
) {
	MutOpt!(LocalNode*) fromLocals = has(locals.locals)
		? getIdentifierInLocals(force(locals.locals), name, accessKind)
		: noneMut!(LocalNode*);
	if (has(fromLocals)) {
		LocalNode* node = force(fromLocals);
		node.isUsed[accessKind] = true;
		return someMut(VariableRefAndType(
			VariableRef(node.local),
			toMutability(node.local.mutability),
			&node.isUsed,
			node.local.type));
	} else if (has(locals.lambda))
		return getIdentifierFromLambda(ctx, diagRange, name, *force(locals.lambda), accessKindInClosure(accessKind));
	else
		return noneMut!VariableRefAndType;
}

MutOpt!(LocalNode*) getIdentifierInLocals(LocalNode* node, Symbol name, LocalAccessKind accessKind) {
	return node.local.name == name
		? someMut(node)
		: has(node.prev)
		? getIdentifierInLocals(force(node.prev), name, accessKind)
		: noneMut!(LocalNode*);
}

MutOpt!VariableRefAndType getIdentifierFromLambda(
	ref ExprCtx ctx,
	Opt!Range diagRange,
	Symbol name,
	ref LambdaInfo info,
	LocalAccessKind accessKind,
) {
	foreach (size_t index, ref ClosureFieldBuilder field; info.closureFields.soFar)
		if (field.name == name) {
			field.setIsUsed(accessKind);
			return someMut(VariableRefAndType(
				VariableRef(ClosureRef(PtrAndSmallNumber!LambdaExpr(info.lambda, safeToUshort(index)))),
				field.mutability,
				field.isUsed,
				field.type));
		}

	MutOpt!VariableRefAndType optOuter = getIdentifierNonCall(ctx, *info.outer, diagRange, name, accessKind);
	if (has(optOuter)) {
		VariableRefAndType outer = force(optOuter);
		size_t closureFieldIndex = info.closureFields.soFar.length;
		if (has(diagRange))
			checkClosureMutability(ctx, force(diagRange), info.lambda.kind, name, outer.mutability, outer.type);
		info.closureFields ~= ClosureFieldBuilder(name, outer.mutability, outer.isUsed, outer.type, outer.variableRef);
		outer.setIsUsed(accessKind);
		return someMut(VariableRefAndType(
			VariableRef(ClosureRef(PtrAndSmallNumber!LambdaExpr(info.lambda, safeToUshort(closureFieldIndex)))),
			outer.mutability,
			outer.isUsed,
			outer.type));
	} else
		return noneMut!VariableRefAndType;
}

void checkClosureMutability(
	ref ExprCtx ctx,
	Range diagRange,
	LambdaKind lambdaKind,
	Symbol name,
	Mutability mutability,
	Type type,
) {
	Purity expectedPurity = () {
		final switch (lambdaKind) {
			case LambdaKind.data:
				return Purity.data;
			case LambdaKind.shared_:
				return Purity.shared_;
			case LambdaKind.mut:
			case LambdaKind.explicitShared:
				return Purity.mut;
		}
	}();
	if (expectedPurity != Purity.mut) {
		if (mutability != Mutability.immut)
			addDiag2(ctx, diagRange, Diag(
				DiagLambdaClosurePurity(lambdaKind, name, Purity.mut, none!TypeWithContainer)));
		else if (!isPurityAlwaysCompatibleConsideringSpecs(ctx.outermostFunSpecs, type, expectedPurity))
			addDiag2(ctx, diagRange, Diag(
				DiagLambdaClosurePurity(
					lambdaKind, name,
					purityRange(type).worstCase,
					some(typeWithContainer(ctx, type)))));
	}
}

LocalAccessKind accessKindInClosure(LocalAccessKind a) {
	final switch (a) {
		case LocalAccessKind.getOnStack:
		case LocalAccessKind.getThroughClosure:
			return LocalAccessKind.getThroughClosure;
		case LocalAccessKind.setOnStack:
		case LocalAccessKind.setThroughClosure:
			return LocalAccessKind.setThroughClosure;
	}
}

bool nameIsParameterOrLocalInScope(ref ExprCtx ctx, ref LocalsInfo locals, Symbol name) =>
	has(getIdentifierNonCall(ctx, locals, none!Range, name, LocalAccessKind.getOnStack));

Expr checkIdentifier(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	NameAndRange* ast,
	ref Expected expected,
) {
	MutOpt!VariableRefAndType res = getIdentifierNonCall(
		ctx, locals, some(ast.range), ast.name, LocalAccessKind.getOnStack);
	return has(res)
		? check(ctx, expected, force(res).type, exprForVariableRef(ast.start, force(res).variableRef))
		: checkCallIdentifier!checkExpr(ctx, locals, ast, expected);
}

Expr exprForVariableRef(Pos start, VariableRef a) =>
	a.matchWithPointers!Expr(
		(Local* x) =>
			Expr(LocalGetExpr(start, x)),
		(ClosureRef x) =>
			Expr(ClosureGetExpr(start, x)));

Expr checkAssignIdentifier(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	NameAndRange* source,
	in Range keywordRange,
	in Symbol left,
	ref Expected expected,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cbRight,
) {
	MutOpt!VariableRefAndType optVar =
		getIdentifierNonCall(ctx, locals, some(source.range), left, LocalAccessKind.setOnStack);
	if (has(optVar)) {
		VariableRefAndType var = force(optVar);
		final switch (var.mutability) {
			case Mutability.immut:
				addDiag2(ctx, source.range, Diag(DiagLocalNotMutable(var.variableRef)));
				return bogus(expected, source.range);
			case Mutability.mut:
				Expr value = withExpect(var.type, cbRight);
				return var.variableRef.matchWithPointers!Expr(
					(Local* local) =>
						check(ctx, expected, voidType(ctx), Expr(LocalSetExpr(source.range, local, allocate(ctx.alloc, value)))),
					(ClosureRef x) =>
						check(ctx, expected, voidType(ctx), Expr(ClosureSetExpr(source.range, x, allocate(ctx.alloc, value)))));
				}
	} else
		return checkCallSpecialCb1(ctx, locals, CallExprSource(source), keywordRange, prependSet(left), expected, cbRight);
}

Expr checkLiteralFloat(ref ExprCtx ctx, ExprAst* source, in LiteralFloatAndRange ast, ref Expected expected) {
	immutable StructInst*[2] allowedTypes = [ctx.commonTypes.float32, ctx.commonTypes.float64];
	Opt!size_t opTypeIndex = findExpectedStructForLiteral(ctx, source, expected, allowedTypes);
	return has(opTypeIndex)
		? asFloat(
			ctx, source.range, floatTypes[force(opTypeIndex)], allowedTypes[force(opTypeIndex)],
			ast.literal.value, ast.literal.overflow, expected)
		: bogus(expected, source);
}

Expr asFloat(
	ref ExprCtx ctx,
	Range range,
	FloatType floatType,
	StructInst* inst,
	HighPrecisionFloat value,
	bool overflow,
	ref Expected expected,
) {
	if (overflow)
		addDiag2(ctx, range, Diag(DiagLiteralFloatAccuracy(floatType, toDouble(value))));
	return check(ctx, expected, Type(inst), Expr(LiteralExpr(range, inst, LiteralValue(toDouble(value)))));
}

double toDouble(HighPrecisionFloat a) {
	// TODO: WebAssembly version is not quite as accurate, gives an imperfect value for 3.14159
	// Since unfortunately 3.14159 !== (314159 * 0.00001)
	version (WebAssembly) {
		return a.longValue * powerOf10(a.exponent);
	} else {
		double res = withStackWriterCString!(0x100, double)(
			(scope ref Writer writer) {
				writer ~= a.longValue;
				writer ~= "e";
				writer ~= a.exponent;
			},
			(in CString s) @trusted {
				double res;
				cast(void) sscanf(s.ptr, "%lf", &res);
				return res;
			});
		return res;
	}
}

version (WebAssembly) {} else {
	extern(C) int sscanf(scope const char*, scope const char*, double*) @system @nogc pure nothrow;
}

immutable IntegralType[4] natTypes = [IntegralType.nat8, IntegralType.nat16, IntegralType.nat32, IntegralType.nat64];
immutable IntegralType[4] intTypes = [IntegralType.int8, IntegralType.int16, IntegralType.int32, IntegralType.int64];
immutable FloatType[2] floatTypes = [FloatType.float32, FloatType.float64];

Expr checkLiteralIntegral(ref ExprCtx ctx, ExprAst* source, in LiteralIntegralAndRange ast, ref Expected expected) {
	IntegralTypes integrals = ctx.commonTypes.integrals;
	immutable StructInst*[10] allowedTypes = [
		integrals.nat8, integrals.nat16, integrals.nat32, integrals.nat64,
		integrals.int8, integrals.int16, integrals.int32, integrals.int64,
		ctx.commonTypes.float32, ctx.commonTypes.float64,
	];
	IntegralType[8] integralTypes;
	integralTypes[0 .. natTypes.length] = natTypes;
	integralTypes[natTypes.length .. integralTypes.length] = intTypes;
	Opt!size_t opTypeIndex = findExpectedStructForLiteral(ctx, source, expected, allowedTypes);
	if (has(opTypeIndex)) {
		size_t typeIndex = force(opTypeIndex);
		StructInst* numberType = allowedTypes[typeIndex];
		if (typeIndex < integralTypes.length)
			return check(
				ctx, expected, Type(numberType),
				Expr(LiteralExpr(ast.range, numberType, LiteralValue(checkLiteralIntegralValue(
					ctx.checkCtx, integralTypes[typeIndex], ast)))));
		else {
			bool overflow = ast.literal.overflow;
			long value = ast.literal.isSigned
				? ast.literal.value.asSigned
				: toLongWithOverflow(ast.literal.value.asUnsigned, overflow);
			return asFloat(
				ctx, source.range,
				floatTypes[typeIndex - integralTypes.length],
				numberType,
				HighPrecisionFloat(value, 0),
				overflow,
				expected);
		}
	} else
		return bogus(expected, source);
}

Expr checkLiteralString(ref ExprCtx ctx, ExprAst* source, string value, ref Expected expected) {
	Range range = source.range;
	immutable StructInst*[8] allowedTypes = [
		ctx.commonTypes.char8,
		ctx.commonTypes.char32,
		ctx.commonTypes.char8Array,
		ctx.commonTypes.char32Array,
		ctx.commonTypes.cString,
		ctx.commonTypes.jsAny,
		ctx.commonTypes.string_,
		ctx.commonTypes.symbol,
	];
	Opt!size_t opTypeIndex = findExpectedStructForLiteral(ctx, source, expected, allowedTypes);
	static immutable StringLiteralKind[allowedTypes.length] kinds = [
		StringLiteralKind.cString, // won't be used
		StringLiteralKind.cString, // won't be used
		StringLiteralKind.char8Array,
		StringLiteralKind.char32Array,
		StringLiteralKind.cString,
		StringLiteralKind.jsAny,
		StringLiteralKind.string_,
		StringLiteralKind.symbol,
	];

	if (has(opTypeIndex)) {
		size_t typeIndex = force(opTypeIndex);
		Opt!Expr expr = () {
			if (typeIndex == 0) // char8
				return some(Expr(LiteralExpr(range, allowedTypes[0], LiteralValue(IntegralValue(char8LiteralValue(ctx, range, value))))));
			else if (typeIndex == 1) // char32
				return some(Expr(LiteralExpr(range, allowedTypes[1], LiteralValue(IntegralValue(char32LiteralValue(ctx, range, value))))));
			else {
				string checkNoNul(DiagStringLiteralInvalid diag) {
					Opt!size_t index = indexOf(value, '\0');
					if (has(index)) {
						addDiag2(ctx, source.range, Diag(diag));
						return value[0 .. force(index)];
					} else
						return value;
				}
				StringLiteralKind kind = kinds[typeIndex];
				Opt!string fixedValue = () {
					final switch (kind) {
						case StringLiteralKind.char8Array:
						case StringLiteralKind.char32Array:
							return some(value);
						case StringLiteralKind.cString:
							return some(checkNoNul(DiagStringLiteralInvalid.cStringContainsNul));
						case StringLiteralKind.string_:
							return some(checkNoNul(DiagStringLiteralInvalid.stringContainsNul));
						case StringLiteralKind.symbol:
							return some(checkNoNul(DiagStringLiteralInvalid.symbolContainsNul));
						case StringLiteralKind.jsAny:
							bool ok = symbol!"js" in ctx.externs;
							if (!ok)
								addDiag2(ctx, source.range, Diag(DiagStringLiteralInvalid.notExternJs));
							return optIf(ok, () => value);
					}
				}();
				return optIf(has(fixedValue), () =>
					Expr(LiteralStringLikeExpr(range, kind, smallString(force(fixedValue)))));
			}
		}();
		return has(expr)
			? check(ctx, expected, Type(allowedTypes[typeIndex]), force(expr))
			: bogus(expected, range);
	} else
		return bogus(expected, range);
}

char char8LiteralValue(ref ExprCtx ctx, Range diagRange, string value) {
	if (value.length != 1) {
		addDiag2(ctx, diagRange, Diag(DiagCharLiteralMustBeOneChar()));
		return 'a';
	} else
		return only(value);
}

dchar char32LiteralValue(ref ExprCtx ctx, Range diagRange, string value) =>
	optOrDefault!dchar(decodeAsSingleUnicodeChar(value), () {
		addDiag2(ctx, diagRange, Diag(DiagCharLiteralMustBeOneChar()));
		return 'a';
	});

Expr checkExprWithOptDestructure(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Opt!Destructure destructure,
	ExprAst* ast,
	ref Expected expected,
) =>
	has(destructure)
		? checkExprWithDestructure(ctx, locals, force(destructure), ast, expected)
		: checkExpr(ctx, locals, ast, expected);

Expr checkExprWithDestructure(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Destructure destructure,
	ExprAst* ast,
	ref Expected expected,
) =>
	optOrDefault!Expr(
		checkWithDestructure(ctx, locals, destructure, (ref LocalsInfo innerLocals) =>
			some(checkExpr(ctx, innerLocals, ast, expected))),
		() => bogus(expected, ast));

Opt!Expr checkWithDestructure(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ref Destructure destructure,
	in Opt!Expr delegate(ref LocalsInfo) @safe @nogc pure nothrow cb,
) =>
	destructure.matchWithPointers!(Opt!Expr)(
		(DestructureIgnore*) =>
			cb(locals),
		(Local* x) =>
			checkWithLocal(ctx, locals, x, cb),
		(DestructureSplit* x) =>
			checkWithDestructureParts(ctx, locals, x.parts, cb));
Opt!Expr checkWithDestructureParts(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Destructure[] parts,
	in Opt!Expr delegate(ref LocalsInfo) @safe @nogc pure nothrow cb,
) {
	switch (parts.length) {
		case 0:
			assert(false);
		case 1:
			return checkWithDestructure(ctx, locals, only(parts), cb);
		default:
			return checkWithDestructure(ctx, locals, parts[0], (ref LocalsInfo innerLocals) =>
				checkWithDestructureParts(ctx, innerLocals, parts[1 .. $], cb));
	}
}

Opt!Expr checkWithLocal(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	Local* local,
	in Opt!Expr delegate(ref LocalsInfo) @safe @nogc pure nothrow cb,
) {
	if (nameIsParameterOrLocalInScope(ctx, locals, local.name))
		addDiag2(ctx, localMustHaveNameRange(*local), Diag(
			DiagDuplicateDeclaration(DiagDuplicateDeclarationKind.paramOrLocal, local.name)));

	LocalNode localNode = LocalNode(
		locals.locals,
		makeEnumMap!(LocalAccessKind, bool)((LocalAccessKind _) => false),
		local);
	LocalsInfo newLocals = LocalsInfo(
		locals.countAllAccessibleLocals + 1,
		locals.lambda,
		someMut(ptrTrustMe(localNode)));
	Opt!Expr res = cb(newLocals);
	if (localNode.local.mutability.isA!LocalMutableOnStack &&
		(localNode.isUsed[LocalAccessKind.getThroughClosure] ||
		 localNode.isUsed[LocalAccessKind.setThroughClosure])) {
		// TODO: Better way than overwriteMemory?
		overwriteMemory(&local.mutability, LocalMutability(LocalMutableAllocated(
			instantiateStruct(ctx.instantiateCtx, ctx.commonTypes.reference, [local.type]))));
	}
	addUnusedLocalDiags(ctx, local, localNode);
	return res;
}

void addUnusedLocalDiags(ref ExprCtx ctx, Local* local, scope ref LocalNode node) {
	bool isGot = node.isUsed[LocalAccessKind.getOnStack] || node.isUsed[LocalAccessKind.getThroughClosure];
	bool isSet = node.isUsed[LocalAccessKind.setOnStack] || node.isUsed[LocalAccessKind.setThroughClosure];
	if (!isGot || (!isSet && local.isMutable))
		addDiag2(ctx, localMustHaveNameRange(*local), Diag(DiagUnusedLocal(local, isGot, isSet)));
}

Expr checkPointer(ref ExprCtx ctx, ref LocalsInfo locals, ExprAst* source, PtrAst* ast, ref Expected expected) =>
	getExpectedPointee(ctx, expected).match!Expr(
		(ExpectedPointeeNone _) {
			addDiag2(ctx, source, Diag(DiagNeedsExpectedType.pointer));
			return bogus(expected, source);
		},
		(ExpectedPointeeFunPointer x) =>
			checkFunPointer(ctx, locals, ast, x, expected),
		(ExpectedPointeePointer x) =>
			checkPointerInner(ctx, locals, source, ast, x.pointer, x.pointee, x.mutability, expected));

immutable struct ExpectedPointee {
	mixin Union!(ExpectedPointeeNone, ExpectedPointeeFunPointer, ExpectedPointeePointer);
}
immutable struct ExpectedPointeeNone {}
immutable struct ExpectedPointeeFunPointer {
	Type returnType;
	Type paramTypes;
}
immutable struct ExpectedPointeePointer {
	StructInst* pointer;
	Type pointee;
	PointerMutability mutability;
}

enum PointerMutability { readOnly, writeable }

ExpectedPointee getExpectedPointee(ref ExprCtx ctx, ref const Expected expected) {
	Opt!Type expectedType = tryGetNonInferringType(ctx.instantiateCtx, expected);
	if (has(expectedType) && force(expectedType).isA!(StructInst*)) {
		StructInst* inst = force(expectedType).as!(StructInst*);
		if (inst.decl == ctx.commonTypes.pointerConst)
			return ExpectedPointee(ExpectedPointeePointer(
				inst, only(inst.typeArgs), PointerMutability.readOnly));
		else if (inst.decl == ctx.commonTypes.pointerMut)
			return ExpectedPointee(ExpectedPointeePointer(
				inst, only(inst.typeArgs), PointerMutability.writeable));
		else if (inst.decl == ctx.commonTypes.funPointerStruct) {
			assert(inst.typeArgs.length == 2);
			return ExpectedPointee(ExpectedPointeeFunPointer(inst.typeArgs[0], inst.typeArgs[1]));
		} else
			return ExpectedPointee(ExpectedPointeeNone());
	} else
		return ExpectedPointee(ExpectedPointeeNone());
}

Expr checkPointerInner(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ExprAst* source,
	PtrAst* ast,
	StructInst* pointerType,
	Type pointeeType,
	PointerMutability expectedMutability,
	ref Expected expected,
) {
	if (symbol!"native" !in ctx.externs) {
		addDiag2(ctx, source, Diag(DiagPointerIsNative()));
		return bogus(expected, source);
	}
	if (!checkCanDoUnsafe(ctx))
		addDiag2(ctx, source, Diag(DiagPointerIsUnsafe()));
	Expr inner = checkAndExpect(ctx, locals, &ast.inner, pointeeType);
	if (inner.isA!LocalGetExpr) {
		Local* local = inner.as!LocalGetExpr.local;
		if (expectedMutability != PointerMutability.readOnly && !local.isMutable)
			addDiag2(ctx, source, Diag(DiagPointerMutToConst.local));
		if (expectedMutability == PointerMutability.writeable)
			markIsUsedSetOnStack(locals, local);
		return check(ctx, expected, Type(pointerType), Expr(LocalPointerExpr(ast, local, pointerType)));
	} else if (inner.isA!CallExpr)
		return checkPointerOfCall(ctx, ast, inner.as!CallExpr, pointerType, expectedMutability, expected);
	else {
		addDiag2(ctx, source, Diag(DiagPointerUnsupported.other));
		return bogus(expected, source);
	}
}

Expr checkPointerOfCall(
	ref ExprCtx ctx,
	PtrAst* ast,
	ref CallExpr call,
	StructInst* pointerType,
	PointerMutability expectedMutability,
	ref Expected expected,
) {
	Range range = ast.range; // TODO: maybe just use the range of the '&' for diagnostics? ---------------------------=-==-=-=-
	Expr fail(DiagPointerUnsupported diag = DiagPointerUnsupported.other) {
		addDiag2(ctx, range, Diag(diag));
		return bogus(expected, range);
	}

	if (call.called.isA!(FunInst*)) {
		FunInst* getFieldFun = call.called.as!(FunInst*);
		if (getFieldFun.decl.body_.isA!RecordFieldGet) {
			RecordFieldGet rfg = getFieldFun.decl.body_.as!RecordFieldGet;
			Expr target = only(call.args);
			StructInst* recordType = only(getFieldFun.paramTypes).as!(StructInst*);
			PointerMutability fieldMutability =
				has(rfg.field.mutability)
					? PointerMutability.writeable
					: PointerMutability.readOnly;
			if (isDefinitelyByRef(*recordType)) {
				if (fieldMutability < expectedMutability)
					addDiag2(ctx, range, Diag(DiagPointerMutToConst.fieldOfByRef));
				return check(ctx, expected, Type(pointerType), Expr(allocate(ctx.alloc,
					RecordFieldPointerExpr(ast, ExprAndType(target, Type(recordType)), rfg.field, pointerType))));
			} else if (target.isA!CallExpr) {
				CallExpr targetCall = target.as!CallExpr;
				Called called = targetCall.called;
				if (called.isA!(FunInst*) && isDerefFunction(ctx, called.as!(FunInst*))) {
					FunInst* derefFun = called.as!(FunInst*);
					Type derefedType = only(derefFun.paramTypes);
					PointerMutability pointerMutability = mutabilityForPtrDecl(ctx, derefedType.as!(StructInst*).decl);
					Expr targetPtr = only(targetCall.args);
					// Ignore fieldMutability -- we'll allow mutating a non-mut field from a mut pointer.
					// But not allow any mutation from a non-mut pointer even for mutable fields.
					if (pointerMutability < expectedMutability) {
						addDiag2(ctx, range, Diag(DiagPointerMutToConst.fieldOfByVal));
						return bogus(expected, range);
					} else
						return check(ctx, expected, Type(pointerType), Expr(allocate(ctx.alloc,
							RecordFieldPointerExpr(ast, ExprAndType(targetPtr, derefedType), rfg.field, pointerType))));
				} else
					return fail();
			} else
				return fail(DiagPointerUnsupported.recordNotByRef);
		} else
			return fail();
	} else
		return fail();
}

bool isDerefFunction(ref ExprCtx ctx, FunInst* a) {
	if (a.decl.body_.isA!BuiltinFun) {
		BuiltinFun builtin = a.decl.body_.as!BuiltinFun;
		return builtin.isA!BuiltinUnary && builtin.as!BuiltinUnary == BuiltinUnary.deref;
	} else
		return false;
}

PointerMutability mutabilityForPtrDecl(in ExprCtx ctx, in StructDecl* a) {
	if (a == ctx.commonTypes.pointerConst)
		return PointerMutability.readOnly;
	else {
		assert(a == ctx.commonTypes.pointerMut);
		return PointerMutability.writeable;
	}
}

Expr checkFunPointer(
	ref ExprCtx ctx,
	in LocalsInfo locals,
	PtrAst* ast,
	ExpectedPointeeFunPointer expectedPointee,
	ref Expected expected,
) {
	Opt!NameAndTypeArg name = getNameAndTypeArg(ast.inner);
	if (has(name))
		return checkFunPointerInner(
			ctx, locals, ast, force(name).name, force(name).typeArg, expectedPointee, expected);
	else {
		addDiag2(ctx, ast.range, Diag(DiagFunPointerExprMustBeName()));
		return bogus(expected, ast.range);
	}
}

immutable struct NameAndTypeArg {
	NameAndRange name;
	Opt!(TypeAst*) typeArg;
}
Opt!NameAndTypeArg getNameAndTypeArg(in ExprAst ast) {
	if (ast.isA!NameAndRange)
		return some(NameAndTypeArg(ast.as!NameAndRange, none!(TypeAst*)));
	else if (ast.isA!CallAst) {
		CallAst call = ast.as!CallAst;
		return optIf(call.style == CallAstStyle.single && isEmpty(call.args), () =>
			NameAndTypeArg(call.funName, call.typeArg));
	} else
		return none!NameAndTypeArg;
}

Expr checkFunPointerInner(
	ref ExprCtx ctx,
	in LocalsInfo locals,
	PtrAst* ast,
	NameAndRange name,
	Opt!(TypeAst*) typeArg,
	ExpectedPointeeFunPointer expectedPointee,
	ref Expected expected,
) {
	Opt!Called optCalled = findFunctionForPointer(ctx, locals, name, typeArg, expectedPointee);
	if (!has(optCalled))
		return bogus(expected, ast.range);
	else {
		Called called = force(optCalled);
		Type paramType = makeTupleType(ctx.checkCtx, ctx.commonTypes, called.paramTypes, () => ast.range);
		StructInst* structInst = instantiateStruct(
			ctx.instantiateCtx, ctx.commonTypes.funPointerStruct, [called.returnType, paramType]);
		if (symbol!"js" !in ctx.externs && !isBareForFunctionPointer(called))
			addDiag2(ctx, ast.range, Diag(DiagFunPointerNotBare()));
		return check(ctx, expected, Type(structInst), Expr(FunPointerExpr(ast, called, structInst)));
	}
}

bool isBareForFunctionPointer(in Called a) =>
	a.matchIn!bool(
		(in CalledBogus _) =>
			true,
		(in FunInst x) =>
			x.decl.isBareOrForceCtx &&
			every!Called(x.specImpls, (in Called x) => isBareForFunctionPointer(x)),
		(in CalledSpecSig _) =>
			false);

Out withReturnAndParamTypes(Out)(
	ref CommonTypes commonTypes,
	ExpectedPointeeFunPointer a,
	in Out delegate(in ReturnAndParamTypes) @safe @nogc pure nothrow cb,
) {
	scope Type[] paramTypes = unpackTuple(commonTypes, &a.paramTypes);
	return withStackArray(
		paramTypes.length + 1,
		(size_t i) => i == 0 ? a.returnType : paramTypes[i - 1],
		(scope Type[] xs) => cb(ReturnAndParamTypes(small!Type(xs))));
}

Opt!Called findFunctionForPointer(
	ref ExprCtx ctx,
	in LocalsInfo locals,
	NameAndRange name,
	Opt!(TypeAst*) typeArgAst,
	ExpectedPointeeFunPointer expected,
) {
	Opt!Type typeArg = optIf(has(typeArgAst), () => typeFromAst2(ctx, *force(typeArgAst)));
	return withReturnAndParamTypes(ctx.commonTypes, expected, (in ReturnAndParamTypes returnAndParamTypes) =>
		findFunctionForReturnAndParamTypes(
			ctx.checkCtx, ctx.commonTypes, ctx.typeContainer, funsInExprScope(ctx), ctx.outermostFunFlags, ctx.externs,
			locals, name.name, name.range, typeArg, returnAndParamTypes,
			() => checkCanDoUnsafe(ctx)));
}

Expr checkShared(ref ExprCtx ctx, ref LocalsInfo locals, SharedAst* ast, ref Expected expected) {
	void diag(Diag diag) {
		addDiag2(ctx, ast.keywordRange, diag);
	}

	if (!ast.inner.isA!(LambdaAst*)) {
		diag(Diag(DiagSharedArgIsNotLambda()));
		return bogus(expected, ast.range);
	}
	LambdaAst* inner = ast.inner.as!(LambdaAst*);

	MutOpt!ExpectedLambdaType opEt = getExpectedLambda(ctx, ast.range, typeFromDestructure2(ctx, inner.param), expected);
	if (!has(opEt))
		return bogus(expected, ast.range);

	ExpectedLambdaType et = force(opEt);
	if (et.funType.kind != FunKind.shared_) {
		diag(Diag(DiagSharedNotExpected(getExpectedForDiag(ctx, expected))));
		return bogus(expected, ast.range);
	}

	LambdaAndReturnType res = checkLambdaInner(
		ctx, locals, LambdaSource(inner), &inner.param, &inner.body_, expected,
		some(instantiateStruct(
			ctx.instantiateCtx, ctx.commonTypes.funStructs[FunKind.mut], et.funType.structInst.typeArgs)),
		et.instantiatedParamType,
		et.funType.returnType,
		et.typeContext,
		et.funType.funStruct,
		LambdaKind.explicitShared);

	if (!isShared(ctx.outermostFunSpecs, et.instantiatedParamType))
		diag(Diag(DiagSharedLambdaTypeIsNotShared(
			DiagSharedLambdaTypeIsNotSharedKind.paramType, typeWithContainer(ctx, et.instantiatedParamType))));
	if (!isShared(ctx.outermostFunSpecs, res.returnType))
		diag(Diag(DiagSharedLambdaTypeIsNotShared(
			DiagSharedLambdaTypeIsNotSharedKind.returnType, typeWithContainer(ctx, res.returnType))));

	bool allShared = every!VariableRef(res.expr.as!(LambdaExpr*).closure, (in VariableRef x) =>
		x.mutability.isImmutable && isShared(ctx.outermostFunSpecs, x.type));
	if (allShared)
		diag(Diag(DiagSharedLambdaUnused()));
	return res.expr;
}

Expr checkLambda(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	LambdaSource source,
	DestructureAst* paramAst,
	ExprAst* bodyAst,
	ref Expected expected,
) {
	Range diagRange = source.range;
	MutOpt!ExpectedLambdaType opEt = getExpectedLambda(ctx, diagRange, typeFromDestructure2(ctx, *paramAst), expected);
	if (!has(opEt))
		return bogus(expected, diagRange);

	ExpectedLambdaType et = force(opEt);
	FunKind kind = et.funType.kind;
	if (kind == FunKind.function_) {
		addDiag2(ctx, diagRange, Diag(DiagLambdaCantBeFunctionPointer()));
		return bogus(expected, diagRange);
	}
	return checkLambdaInner(
		ctx, locals, source, paramAst, bodyAst, expected, none!(StructInst*),
		et.instantiatedParamType,
		et.funType.returnType,
		et.typeContext,
		et.funType.funStruct,
		toLambdaKind(et.funType.kind)).expr;
}

LambdaKind toLambdaKind(FunKind a) {
	final switch (a) {
		case FunKind.data:
			return LambdaKind.data;
		case FunKind.shared_:
			return LambdaKind.shared_;
		case FunKind.mut:
			return LambdaKind.mut;
		case FunKind.function_:
			assert(false);
	}
}

struct LambdaAndReturnType { Expr expr; Type returnType; }
LambdaAndReturnType checkLambdaInner(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	LambdaSource source,
	DestructureAst* paramAst,
	ExprAst* bodyAst,
	ref Expected expected,
	Opt!(StructInst*) mutTypeForExplicitShared,
	Type paramType,
	Type nonInstantiatedReturnType,
	TypeContext returnTypeContext,
	StructDecl* funStruct,
	LambdaKind kind,
) {
	Destructure param = checkDestructure2(ctx, paramAst, paramType, DestructureKind.param);
	LambdaExpr* lambda = allocate(ctx.alloc, LambdaExpr(source, kind, param, mutTypeForExplicitShared));
	return withMaxStackArray!(LambdaAndReturnType, ClosureFieldBuilder)(
		locals.countAllAccessibleLocals,
		(scope ref MaxStackArray!ClosureFieldBuilder xs) {
			LambdaInfo lambdaInfo = LambdaInfo(ptrTrustMe(locals), lambda, xs.move);
			// Checking the body of the lambda may fill in candidate type args
			// if the expected return type contains candidate's type params
			LocalsInfo bodyLocals = LocalsInfo(
				locals.countAllAccessibleLocals,
				someMut(ptrTrustMe(lambdaInfo)),
				noneMut!(LocalNode*));
			Pair!(Expr, Type) bodyAndType = withCopyWithNewExpectedType!Expr(expected,
				nonInstantiatedReturnType,
				returnTypeContext,
				(ref Expected returnTypeInferrer) =>
					checkExprWithDestructure(ctx, bodyLocals, param, bodyAst, returnTypeInferrer));
			StructInst* instFunStruct = instantiateStruct(ctx.instantiateCtx, funStruct, [bodyAndType.b, param.type]);
			lambda.fillLate(
				body_: bodyAndType.a,
				closure: small!VariableRef(
					map!(VariableRef, ClosureFieldBuilder)(
						ctx.alloc,
						lambdaInfo.closureFields.finish,
						(ref const ClosureFieldBuilder x) =>
							x.variableRef)),
				lambdaType: instFunStruct,
				returnType: bodyAndType.b);
			return LambdaAndReturnType(
				//TODO: this check should never fail, so could just set inferred directly with no check
				check(ctx, expected, Type(instFunStruct), Expr(castImmutable(lambda))),
				bodyAndType.b);
		});
}

Expr checkLet(ref ExprCtx ctx, ref LocalsInfo locals, LetAst* ast, ref Expected expected) {
	ExprAndType value = checkAndExpectOrInfer(ctx, locals, &ast.value, typeFromDestructure2(ctx, ast.destructure));
	Destructure destructure = checkDestructure2(ctx, &ast.destructure, value.type, DestructureKind.local);
	Expr then = checkExprWithDestructure(ctx, locals, destructure, &ast.then, expected);
	return Expr(allocate(ctx.alloc, LetExpr(ast, destructure, value.expr, then)));
}

Expr checkLoop(ref ExprCtx ctx, ref LocalsInfo locals, LoopAst* ast, ref Expected expected) {
	Opt!Type expectedType = tryGetNonInferringType(ctx.instantiateCtx, expected);
	if (has(expectedType)) {
		Type type = force(expectedType);
		LoopExpr* loop = allocate(ctx.alloc, LoopExpr(ast, type, Expr(BogusExpr(ast.range, Type.bogus))));
		LoopInfo info = LoopInfo(voidType(ctx), castImmutable(loop), type, false);
		Expr body_ = withExpectLoop(info, (ref Expected bodyExpected) =>
			checkExpr(ctx, locals, &ast.body_, castNonScope_ref(bodyExpected)));
		overwriteMemory(&loop.body_, body_);
		if (!info.hasBreak)
			addDiag2(ctx, ast.keywordRange, Diag(DiagLoopWithoutBreak()));
		return Expr(castImmutable(loop));
	} else {
		addDiag2(ctx, ast.range, Diag(DiagNeedsExpectedType.loop));
		return bogus(expected, ast.range);
	}
}

Expr checkLoopBreak(ref ExprCtx ctx, ref LocalsInfo locals, LoopBreakAst* ast, ref Expected expected) {
	MutOpt!(LoopInfo*) optLoop = tryGetLoop(expected);
	if (!has(optLoop))
		return checkCallSpecial!checkExpr(
			ctx, locals, CallExprSource(ast), ast.keywordRange, symbol!"loop-break", [ast.value], expected);
	else {
		LoopInfo* loop = force(optLoop);
		loop.hasBreak = true;
		Expr value = checkAndExpect(ctx, locals, &ast.value, loop.type);
		return Expr(allocate(ctx.alloc, LoopBreakExpr(ast, loop.loop, value)));
	}
}

Expr checkLoopContinue(ref ExprCtx ctx, ref LocalsInfo locals, LoopContinueAst* ast, ref Expected expected) {
	MutOpt!(LoopInfo*) optLoop = tryGetLoop(expected);
	return has(optLoop)
		? Expr(LoopContinueExpr(ast, force(optLoop).loop))
		: checkCallSpecial!checkExpr(ctx, locals, CallExprSource(ast), ast.keywordRange, symbol!"loop-continue", [], expected);
}

Expr checkLoopWhileOrUntil(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	LoopWhileOrUntilAst* ast,
	ref Expected expected,
) {
	Condition condition = checkCondition(ctx, locals, ast.condition);
	Opt!Destructure destructure = optDestructure(condition);
	return Expr(allocate(ctx.alloc, LoopWhileOrUntilExpr(
		ast,
		condition: condition,
		body_: withExpect(voidType(ctx), (ref Expected bodyExpected) =>
			checkExprWithOptDestructure(
				ctx, locals, ast.isUntil ? none!Destructure : destructure, &ast.body_, bodyExpected)),
		after: checkExprWithOptDestructure(
			ctx, locals, ast.isUntil ? destructure : none!Destructure, &ast.after, expected))));
}

Expr checkMatch(ref ExprCtx ctx, ref LocalsInfo locals, MatchAst* ast, ref Expected expected) {
	ExprAndType matched = checkAndInfer(ctx, locals, ast.matched);
	StructInst* inst = matched.type.isA!(StructInst*)
		? matched.type.as!(StructInst*)
		// Use an arbitrary non-matchable inst as default
		: ctx.commonTypes.void_;
	StructDecl* decl = inst.decl;
	Expr notMatchable() {
		if (!matched.type.isBogus)
			addDiag2(ctx, ast.matched.range, Diag(DiagMatchOnNonMatchable(typeWithContainer(ctx, matched.type))));
		return bogus(expected, ast.matched);
	}
	return decl.body_.match!Expr(
		(StructBodyBogus _) =>
			notMatchable(),
		(BuiltinType x) {
			Opt!CharType charType = optAsCharType(x);
			Opt!IntegralType integral = optAsIntegralType(x);
			Opt!StringLiteralKind stringLike = getMatchableStringLikeFromBuiltin(x);
			return has(charType)
				? checkMatchChar(ctx, locals, ast, expected, matched, force(charType))
				: has(integral)
				? checkMatchIntegral(ctx, locals, ast, expected, matched, force(integral))
				: has(stringLike)
				? checkMatchStringLike(ctx, locals, ast, expected, matched, force(stringLike))
				: notMatchable();
		},
		(ref Enum x) =>
			checkMatchEnum(ctx, locals, ast, expected, matched, decl, x),
		(ExternType _) =>
			notMatchable(),
		(Flags _) =>
			notMatchable(),
		(Record _) {
			Opt!StringLiteralKind stringLike = getMatchableStringLikeFromRecord(ctx.commonTypes, inst);
			return has(stringLike)
				? checkMatchStringLike(ctx, locals, ast, expected, matched, force(stringLike))
				: notMatchable();
		},
		(SumType x) =>
			canMatchSumType(x.kind)
				? checkMatchSumType(ctx, locals, ast, expected, matched, inst)
				: notMatchable());
}

bool canMatchSumType(SumTypeKind a) {
	final switch (a) {
		case SumTypeKind.interface_:
			return false;
		case SumTypeKind.union_:
		case SumTypeKind.variant:
			return true;
	}
}

Expr checkMatchEnum(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	MatchAst* ast,
	ref Expected expected,
	ref ExprAndType matched,
	StructDecl* matchedEnum,
	in Enum body_,
) =>
	withStackArray!(Expr, bool)(body_.members.length, (size_t _) => false, (scope bool[] seen) {
		bool hasCaseDiag = false;
		ExactSizeArrayBuilder!MatchEnumCase cases = newExactSizeArrayBuilder!MatchEnumCase(
			ctx.alloc, ast.cases.length);
		foreach (ref CaseAst caseAst; ast.cases) {
			Opt!(AsNameAst*) asName = nameFromCaseMemberAst(ctx, &caseAst.member);
			Opt!Symbol name = optIf(has(asName), () => force(asName).name.name);
			Opt!(EnumMember*) optMember = has(name) ? body_.membersByName[force(name)] : none!(EnumMember*);
			if (has(optMember)) {
				EnumMember* member = force(optMember);
				size_t index = mustHaveIndexOfPointer(body_.members, member);
				if (seen[index]) {
					hasCaseDiag = true;
					addDiag2(ctx, caseAst.nameRange, Diag(DiagMatchCaseDuplicate(force(name))));
				} else {
					seen[index] = true;
					AsNameAst* nameAst = force(asName);
					if (has(nameAst.destructure))
						addDiag2(ctx, force(nameAst.destructure).range, Diag(
							DiagMatchCaseNoValueForEnumOrSymbol(some(matchedEnum))));
					cases ~= MatchEnumCase(member, checkExpr(ctx, locals, &caseAst.then, expected));
				}
			} else {
				hasCaseDiag = true;
				if (has(name))
					addDiag2(ctx, caseAst.nameRange, Diag(
						DiagMatchCaseNameNotInEnum(force(name), matchedEnum)));
			}
		}
		if (hasCaseDiag) return bogus(expected, ast.range);

		Opt!Expr else_ = () {
				if (every(seen)) {
					if (has(ast.else_))
						addDiag2(ctx, force(ast.else_).keywordRange, Diag(DiagMatchUnnecessaryElse()));
					return none!Expr;
				} else {
					if (has(ast.else_))
						return some(checkExpr(ctx, locals, &force(ast.else_).expr, expected));
					else {
						immutable EnumMember*[] unhandledCases = buildArray!(immutable EnumMember*)(
							ctx.alloc, (scope ref Builder!(immutable EnumMember*) out_) {
								zipPtrFirst(body_.members, seen, (EnumMember* member, ref bool seenIt) {
									if (!seenIt)
										out_ ~= member;
								});
							});
						addDiag2(ctx, ast.keywordRange, Diag(DiagMatchUnhandledCases(unhandledCases)));
						return some(bogus(expected, ast.range));
					}
				}
		}();
		return Expr(allocate(ctx.alloc, MatchEnumExpr(ast, matched, smallFinish(cases), else_)));
	});

Expr checkMatchSumType(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	MatchAst* ast,
	ref Expected expected,
	ref ExprAndType matched,
	StructInst* sumType,
) {
	SmallArray!MatchSumTypeCase cases = checkMatchSumTypeCases(ctx, locals, sumType, ast.cases, expected);
	SumType body_() => sumType.decl.body_.as!SumType;
	bool isUnion = () {
		final switch (body_.kind) {
			case SumTypeKind.interface_:
				assert(false);
			case SumTypeKind.union_:
				return true;
			case SumTypeKind.variant:
				return false;
		}
	}();
	Opt!(Expr*) else_ = () {
		if (isUnion) {
			if (cases.length == body_.listedMembers.length) {
				if (has(ast.else_))
					addDiag2(ctx, force(ast.else_).keywordRange, Diag(DiagMatchUnnecessaryElse()));
				return none!(Expr*);
			} else
				return some(allocate(ctx.alloc, checkMatchElseRequired(ctx, locals, *ast, expected, () =>
					Diag(DiagMatchUnhandledCases(listMissingUnionCases(ctx, sumType, body_, cases))))));
		} else
			return some(allocate(ctx.alloc, checkMatchElseRequired(
				ctx, locals, *ast, expected, DiagMatchNeedsElse.variant)));
	}();
	return Expr(allocate(ctx.alloc, MatchSumTypeExpr(ast, matched, cases, else_)));
}
immutable(StructInst*[]) listMissingUnionCases(
	ref ExprCtx ctx,
	StructInst* sumType,
	SumType body_,
	in MatchSumTypeCase[] cases,
) =>
	buildArray!(immutable StructInst*)(ctx.alloc, (scope ref Builder!(immutable StructInst*) out_) {
		foreach (SumTypeMemberAndMethodImpls member; body_.listedMembers) {
			StructInst* memberInst = instantiateStructInst(ctx.instantiateCtx, *member.member, sumType.typeArgs);
			if (!exists!MatchSumTypeCase(cases, (in MatchSumTypeCase case_) => case_.member == memberInst))
				out_ ~= memberInst;
		}
	});

SmallArray!MatchSumTypeCase checkMatchSumTypeCases(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	StructInst* matchedVariant,
	SmallArray!CaseAst caseAsts,
	ref Expected expected,
) =>
	withTempSet!(SmallArray!MatchSumTypeCase, StructInst*)(
		caseAsts.length, (scope ref TempSet!(StructInst*) seen) =>
			mapOpPointers!(MatchSumTypeCase, CaseAst)(ctx.alloc, caseAsts, (CaseAst* caseAst) {
				Opt!MatchSumTypeCase res = checkMatchSumTypeCase(
					ctx, locals, matchedVariant, &caseAst.member, &caseAst.then, expected);
				if (has(res)) {
					if (tryAdd(seen, force(res).member))
						return res;
					else {
						addDiag2(ctx, caseAst.nameRange, Diag(
							DiagMatchCaseDuplicate(force(res).member.decl.name)));
						return none!MatchSumTypeCase;
					}
				} else
					return none!MatchSumTypeCase;
			}));

Opt!MatchSumTypeCase checkMatchSumTypeCase(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	StructInst* matchedVariant,
	CaseMemberAst* memberAst,
	ExprAst* thenAst,
	ref Expected expected,
) {
	Opt!(AsNameAst*) asName = nameFromCaseMemberAst(ctx, memberAst);
	Opt!Symbol name = optIf(has(asName), () => force(asName).name.name);
	Opt!(StructInst*) optCaseType = has(name)
		? getSumTypeCaseFromName(ctx, matchedVariant, force(name), memberAst.nameRange, () =>
			has(asName) && has(force(asName).destructure)
				? typeFromDestructure2(ctx, force(force(asName).destructure))
				: none!Type)
		: none!(StructInst*);
	if (!has(optCaseType)) return none!MatchSumTypeCase;
	StructInst* caseType = force(optCaseType);

	ref Opt!DestructureAst destructureAst() => memberAst.as!AsNameAst.destructure;
	Destructure destructure = () {
		if (has(destructureAst))
			return checkDestructure2(ctx, &force(destructureAst), Type(caseType), DestructureKind.local);
		else {
			if (!isEmptyType(*caseType))
				addDiag2(ctx, memberAst.nameRange, Diag(DiagMatchCaseShouldUseIgnore(caseType)));
			return Destructure(allocate(ctx.alloc, DestructureIgnore(
				DestructureIgnoreSource(memberAst), memberAst.nameRange.start, Type(caseType))));
		}
	}();
	return optIf(!destructure.type.isBogus, () =>
		MatchSumTypeCase(destructure, checkExprWithDestructure(ctx, locals, destructure, thenAst, expected)));
}

Opt!(StructInst*) getSumTypeCaseFromName(
	ref ExprCtx ctx,
	StructInst* sumType,
	Symbol name,
	Range nameRange,
	in Opt!Type delegate() @safe @nogc pure nothrow expectedMemberType,
) {
	SumTypeMemberAndMethodImpls[] listedMembers = sumType.decl.body_.as!SumType.listedMembers;
	Opt!StructOrAlias op = structOrAliasFromName(ctx.checkCtx, name, nameRange, ctx.structsAndAliasesMap);
	if (!has(op)) return none!(StructInst*);
	return force(op).matchWithPointers!(Opt!(StructInst*))(
		(StructAlias* x) {
			StructInst* target = x.target;
			bool isListed = exists!SumTypeMemberAndMethodImpls(listedMembers, (in SumTypeMemberAndMethodImpls x) =>
				x.member == target);
			bool hasMembership = exists!SumTypeMembership(target.decl.sumTypeMemberships, (in SumTypeMembership x) =>
				x.sumType == sumType);
			if (isListed || hasMembership)
				return some(target);
			else {
				addDiag2(ctx, nameRange, Diag(
					DiagMatchSumTypeNoMember(typeWithContainer(ctx, Type(sumType)), target.decl)));
				return none!(StructInst*);
			}
		},
		(StructDecl* decl) {
			Opt!InstantiatedSumTypeCaseOrBogus res = optOr!InstantiatedSumTypeCaseOrBogus(
				first!(InstantiatedSumTypeCaseOrBogus, SumTypeMemberAndMethodImpls)(
					listedMembers,
					(SumTypeMemberAndMethodImpls x) {
						return optIf(x.member.decl == decl, () =>
							InstantiatedSumTypeCaseOrBogus(
								instantiateStructInst(ctx.instantiateCtx, *x.member, sumType.typeArgs)));
					}),
				() => first!(InstantiatedSumTypeCaseOrBogus, SumTypeMembership)(
					decl.sumTypeMemberships, (SumTypeMembership x) =>
						compareSumTypes(ctx, nameRange, decl, x.sumType, sumType, expectedMemberType)));
			if (has(res))
				return force(res).matchWithPointers!(Opt!(StructInst*))(
					(StructInst* x) => some(x),
					(SumTypeCaseBogus _) => none!(StructInst*));
			else {
				addDiag2(ctx, nameRange, Diag(
					DiagMatchSumTypeNoMember(typeWithContainer(ctx, Type(sumType)), decl)));
				return none!(StructInst*);
			}
		});
}

immutable struct InstantiatedSumTypeCaseOrBogus {
	mixin Union!(StructInst*, SumTypeCaseBogus);
}
immutable struct SumTypeCaseBogus {}

// Returns instantiated case type if the declared sumType matches the actual
Opt!InstantiatedSumTypeCaseOrBogus compareSumTypes(
	ref ExprCtx ctx,
	Range range,
	StructDecl* case_,
	StructInst* declaredSumType,
	StructInst* actualSumType,
	in Opt!Type delegate() @safe @nogc pure nothrow expectedCaseType,
) =>
	declaredSumType.decl != actualSumType.decl ? none!InstantiatedSumTypeCaseOrBogus :
	withInferringTypes(case_.typeParams.length, (scope SingleInferringType[] inferringTypes) {
		TypeContext inferringContext = TypeContext(small!SingleInferringType(inferringTypes));
		TypeAndContext inferringDeclaredSumType = TypeAndContext(Type(declaredSumType), inferringContext);
		return optIf(matchTypes(ctx.instantiateCtx, inferringDeclaredSumType, nonInferring(Type(actualSumType))), () {
			if (!every!SingleInferringType(inferringTypes, (in SingleInferringType x) => has(tryGetInferred(x)))) {
				Opt!Type t = expectedCaseType();
				if (has(t)) {
					// Ignore result, just using this for inference
					matchTypes(
						ctx.instantiateCtx,
						TypeAndContext(
							Type(instantiateStructWithOwnTypeParams(ctx.instantiateCtx, case_)),
							inferringContext),
						nonInferring(force(t)));
				}
			}

			bool anyNotInferred;
			return withMapToStackArray!(InstantiatedSumTypeCaseOrBogus, Type, SingleInferringType)(
				inferringTypes,
				(ref SingleInferringType x) =>
					optOrDefault!Type(tryGetInferred(x), () {
						anyNotInferred = true;
						return Type.bogus;
					}),
				(scope Type[] inferredTypes) {
					if (anyNotInferred) {
						addDiag2(ctx, range, Diag(DiagMatchSumTypeCantInferTypeArgs(case_)));
						return InstantiatedSumTypeCaseOrBogus(SumTypeCaseBogus());
					} else
						return InstantiatedSumTypeCaseOrBogus(
							instantiateStruct(ctx.instantiateCtx, case_, small!Type(inferredTypes)));
				});
		});
	});

Out withInferringTypes(Out)(size_t n, in Out delegate(scope SingleInferringType[]) @safe @nogc pure nothrow cb) =>
	withStackArray!(Out, SingleInferringType)(n, (size_t i) => SingleInferringType(), cb);

Opt!CharType optAsCharType(BuiltinType x) {
	switch (x) {
		case BuiltinType.char8:
			return some(CharType.char8);
		case BuiltinType.char32:
			return some(CharType.char32);
		default:
			return none!CharType;
	}
}

Expr checkMatchChar(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	MatchAst* ast,
	ref Expected expected,
	ref ExprAndType matched,
	CharType charType,
) {
	SmallArray!MatchIntegralCase cases = withTempSet!(SmallArray!MatchIntegralCase, IntegralValue)(
		ast.cases.length, (scope ref TempSet!IntegralValue seen) =>
			mapOpPointers!(MatchIntegralCase, CaseAst)(ctx.alloc, ast.cases, (CaseAst* caseAst) {
				Opt!string stringValue = stringFromCaseAst(ctx, caseAst.member);
				if (has(stringValue)) {
					IntegralValue value = () {
						final switch (charType) {
							case CharType.char8:
								return IntegralValue(
									char8LiteralValue(ctx, caseAst.nameRange, force(stringValue)));
							case CharType.char32:
								return IntegralValue(
									char32LiteralValue(ctx, caseAst.nameRange, force(stringValue)));
						}
					}();
					if (tryAdd(seen, value))
						return some(MatchIntegralCase(value, checkExpr(ctx, locals, &caseAst.then, expected)));
					else {
						addDiag2(ctx, caseAst.nameRange, Diag(DiagMatchCaseDuplicate(force(stringValue))));
						return none!MatchIntegralCase;
					}
				} else
					return none!MatchIntegralCase;
			}));
	Expr else_ = checkMatchElseRequired(ctx, locals, *ast, expected, DiagMatchNeedsElse.integral);
	return Expr(allocate(ctx.alloc,
		MatchIntegralExpr(ast, MatchIntegralKind(charType), matched, cases, else_)));
}

Opt!IntegralType optAsIntegralType(BuiltinType x) {
	switch (x) {
		case BuiltinType.int8:
			return some(IntegralType.int8);
		case BuiltinType.int16:
			return some(IntegralType.int16);
		case BuiltinType.int32:
			return some(IntegralType.int32);
		case BuiltinType.int64:
			return some(IntegralType.int64);
		case BuiltinType.nat8:
			return some(IntegralType.nat8);
		case BuiltinType.nat16:
			return some(IntegralType.nat16);
		case BuiltinType.nat32:
			return some(IntegralType.nat32);
		case BuiltinType.nat64:
			return some(IntegralType.nat64);
		default:
			return none!IntegralType;
	}
}

Expr checkMatchIntegral(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	MatchAst* ast,
	ref Expected expected,
	ref ExprAndType matched,
	IntegralType integralType,
) {
	SmallArray!MatchIntegralCase cases = withTempSet!(SmallArray!MatchIntegralCase, IntegralValue)(
		ast.cases.length, (scope ref TempSet!IntegralValue seen) =>
			mapOpPointers!(MatchIntegralCase, CaseAst)(ctx.alloc, ast.cases, (CaseAst* caseAst) {
				Opt!IntegralValue optValue = caseAst.member.match!(Opt!IntegralValue)(
					(AsNameAst x) {
						addDiag2(ctx, x.name.range, Diag(DiagMatchCaseForType.numeric));
						return none!IntegralValue;
					},
					(LiteralIntegralAndRange x) =>
						some(checkLiteralIntegralValue(ctx.checkCtx, integralType, x)),
					(AsStringAst x) {
						addDiag2(ctx, x.range, Diag(DiagMatchCaseForType.numeric));
						return none!IntegralValue;
					},
					(AsBogusAst _) =>
						none!IntegralValue);
				if (has(optValue)) {
					IntegralValue value = force(optValue);
					if (tryAdd(seen, value))
						return some(MatchIntegralCase(value, checkExpr(ctx, locals, &caseAst.then, expected)));
					else {
						addDiag2(ctx, caseAst.nameRange, Diag(
							isSigned(integralType)
								? DiagMatchCaseDuplicate(value.asSigned())
								: DiagMatchCaseDuplicate(value.asUnsigned())));
						return none!MatchIntegralCase;
					}
				} else
					return none!MatchIntegralCase;
			}));
	Expr else_ = checkMatchElseRequired(ctx, locals, *ast, expected, DiagMatchNeedsElse.integral);
	return Expr(allocate(ctx.alloc, MatchIntegralExpr(ast, MatchIntegralKind(integralType), matched, cases, else_)));
}

Opt!StringLiteralKind getMatchableStringLikeFromBuiltin(BuiltinType a) {
	switch (a) {
		case BuiltinType.string_:
			return some(StringLiteralKind.string_);
		case BuiltinType.symbol:
			return some(StringLiteralKind.symbol);
		default:
			return none!StringLiteralKind;
	}
}
Opt!StringLiteralKind getMatchableStringLikeFromRecord(in CommonTypes commonTypes, in StructInst* inst) =>
	inst == commonTypes.symbol ? some(StringLiteralKind.symbol) :
	inst == commonTypes.char32Array ? some(StringLiteralKind.char32Array) :
	inst == commonTypes.char8Array ? some(StringLiteralKind.char8Array) :
	none!StringLiteralKind;

Expr checkMatchStringLike(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	MatchAst* ast,
	ref Expected expected,
	ref ExprAndType matched,
	StringLiteralKind kind,
) {
	Opt!(SpecDecl*) spec = getSpecFromCommonModule(
		ctx.checkCtx, ctx.specsMap, ast.keywordRange, symbol!"equal", CommonModule.compare);
	if (!has(spec))
		return bogus(expected, ast.range);

	Called equals = checkSpecSingleSigIgnoreParents2(
		ctx.checkCtx,
		ctx.funsMap,
		ast.keywordRange,
		ctx.typeContainer,
		ctx.outermostFunSpecs,
		ctx.outermostFunFlags,
		ctx.externs,
		instantiateSpec(ctx.instantiateCtx, force(spec), [matched.type]));
	SmallArray!MatchStringLikeCase cases = withTempSet!(SmallArray!MatchStringLikeCase, string)(
		ast.cases.length, (scope ref TempSet!string seen) =>
			mapOpPointers!(MatchStringLikeCase, CaseAst)(ctx.alloc, ast.cases, (CaseAst* caseAst) {
				Opt!string optValue = stringFromCaseAst(ctx, caseAst.member);
				if (has(optValue)) {
					string value = force(optValue);
					if (tryAdd(seen, value))
						return some(MatchStringLikeCase(value, checkExpr(ctx, locals, &caseAst.then, expected)));
					else {
						addDiag2(ctx, caseAst.nameRange, Diag(DiagMatchCaseDuplicate(value)));
						return none!MatchStringLikeCase;
					}
				} else
					return none!MatchStringLikeCase;
			}));
	Expr else_ = checkMatchElseRequired(ctx, locals, *ast, expected, DiagMatchNeedsElse.stringLike);
	return Expr(allocate(ctx.alloc, MatchStringLikeExpr(ast, kind, matched, equals, cases, else_)));
}

Expr checkMatchElseRequired(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ref MatchAst ast,
	ref Expected expected,
	DiagMatchNeedsElse kind,
) =>
	checkMatchElseRequired(ctx, locals, ast, expected, () => Diag(DiagMatchNeedsElse(kind)));
Expr checkMatchElseRequired(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	ref MatchAst ast,
	ref Expected expected,
	in Diag delegate() @safe @nogc pure nothrow cbDiag,
) {
	if (has(ast.else_))
		return checkExpr(ctx, locals, &force(ast.else_).expr, expected);
	else {
		addDiag2(ctx, ast.keywordRange, cbDiag());
		return bogus(expected, ast.range);
	}
}

Out withExternFromCondition(Out)(
	ref ExprCtx ctx,
	in Condition condition,
	bool isNegated,
	in Out delegate() @safe @nogc pure nothrow cb,
) {
	Opt!ExternCondition extern_ = asExtern(condition);
	if (has(extern_) && !(isNegated ^ force(extern_).isNegated)) {
		SymbolSet originalExterns = ctx.externs;
		scope (exit) ctx.externs = originalExterns;
		ctx.externs = ctx.externs | force(extern_).requiredExterns;
		return cb();
	} else
		return cb();
}

Expr checkExprWithOptDestructureOrEmptyNew(
	ref ExprCtx ctx,
	ref LocalsInfo locals,
	CallExprSource parent,
	Opt!Destructure destructure,
	Opt!(ExprAst*) ast,
	Range emptyNewRange,
	ref Expected expected,
) =>
	has(ast)
		? checkExprWithOptDestructure(ctx, locals, destructure, force(ast), expected)
		: checkEmptyNew(ctx, locals, parent, emptyNewRange, expected);

Opt!string stringFromCaseAst(ref ExprCtx ctx, CaseMemberAst ast) =>
	ast.match!(Opt!string)(
		(AsNameAst x) {
			if (has(x.destructure))
				addDiag2(ctx, force(x.destructure).range, Diag(
					DiagMatchCaseNoValueForEnumOrSymbol(none!(StructDecl*))));
			return some(stringOfSymbol(ctx.alloc, x.name.name));
		},
		(LiteralIntegralAndRange x) {
			addDiag2(ctx, x.range, Diag(DiagMatchCaseForType.stringLike));
			return none!string;
		},
		(AsStringAst x) =>
			some(x.value),
		(AsBogusAst _) =>
			none!string);

Opt!(AsNameAst*) nameFromCaseMemberAst(ref ExprCtx ctx, CaseMemberAst* ast) {
	Opt!(AsNameAst*) res = ast.isA!AsNameAst
		? some(&ast.as!AsNameAst())
		: none!(AsNameAst*);
	if (!has(res))
		addDiag2(ctx, ast.nameRange, Diag(DiagMatchCaseForType.enumOrUnion));
	return res;
}

Expr checkSeq(ref ExprCtx ctx, ref LocalsInfo locals, SeqAst* ast, ref Expected expected) {
	Expr first = checkAndExpect(ctx, locals, &ast.first, voidType(ctx));
	Expr then = checkExpr(ctx, locals, &ast.then, expected);
	return Expr(allocate(ctx.alloc, SeqExpr(first, then)));
}

bool hasBreakOrContinue(in ExprAst a) =>
	a.matchIn!bool(
		(in ArrowAccessAst _) =>
			false,
		(in AssertOrForbidAst x) =>
			hasBreakOrContinue(*x.after),
		(in AssignmentAst _) =>
			false,
		(in AssignmentCallAst _) =>
			false,
		(in BogusAst _) =>
			false,
		(in CallAst _) =>
			false,
		(in CallNamedAst _) =>
			false,
		(in DoAst x) =>
			hasBreakOrContinue(*x.body_),
		(in EmptyAst _) =>
			false,
		(in ExternAst _) =>
			false,
		(in FinallyAst x) =>
			false,
		(in ForAst _) =>
			false,
		(in NameAndRange _) =>
			false,
		(in IfAst x) =>
			exists!ExprAst(x.allBranches, (in ExprAst y) => hasBreakOrContinue(y)),
		(in InterpolatedAst _) =>
			false,
		(in LambdaAst _) =>
			false,
		(in LetAst x) =>
			hasBreakOrContinue(x.then),
		(in LiteralFloatAndRange _) =>
			false,
		(in LiteralIntegralAndRange _) =>
			false,
		(in LiteralStringAst _) =>
			false,
		(in LoopAst _) =>
			false,
		(in LoopBreakAst _) =>
			true,
		(in LoopContinueAst _) =>
			true,
		(in LoopWhileOrUntilAst x) =>
			hasBreakOrContinue(x.after),
		(in MatchAst x) =>
			exists!CaseAst(x.cases, (in CaseAst case_) =>
				hasBreakOrContinue(case_.then)),
		(in ParenthesizedAst _) =>
			false,
		(in PtrAst _) =>
			false,
		(in SeqAst x) =>
			hasBreakOrContinue(x.then),
		(in SharedAst x) =>
			false,
		(in ThrowAst _) =>
			false,
		(in TrustedAst _) =>
			false,
		(in TryAst x) =>
			false,
		(in TryLetAst x) =>
			hasBreakOrContinue(x.then),
		(in TypedAst _) =>
			false,
		(in WithAst _) =>
			false);

Expr checkFor(ref ExprCtx ctx, ref LocalsInfo locals, ForAst* ast, ref Expected expected) {
	Symbol funName = hasBreakOrContinue(ast.body_) ? symbol!"for-break" : symbol!"for-loop";
	Range keywordRange = ast.forKeywordRange;
	return ast.else_.isA!EmptyAst
		? checkCallArgAndLambda!(checkExpr, checkLambda)(
			ctx, locals, CallExprSource(ast), LambdaSource(ast), keywordRange, funName, &ast.collection, &ast.param, &ast.body_, expected)
		: checkCallArgAnd2Lambdas!(checkExpr, checkLambda)(
			ctx, locals, CallExprSource(ast), LambdaSource(ast), keywordRange, funName, &ast.collection, &ast.param, &ast.body_, &ast.else_, expected);
}

Expr checkWith(ref ExprCtx ctx, ref LocalsInfo locals, WithAst* ast, ref Expected expected) {
	Range keywordRange = ast.withKeywordRange;
	if (!ast.else_.isA!EmptyAst)
		addDiag2(ctx, keywordRange, Diag(DiagWithHasElse()));
	return checkCallArgAndLambda!(checkExpr, checkLambda)(
		ctx, locals, CallExprSource(ast), LambdaSource(ast), keywordRange, symbol!"with-block", &ast.arg, &ast.param, &ast.body_, expected);
}

Expr checkFinally(ref ExprCtx ctx, ref LocalsInfo locals, FinallyAst* ast, ref Expected expected) {
	if (has(tryGetLoop(expected))) {
		addDiag2(ctx, ast.finallyKeywordRange, Diag(DiagLoopDisallowedBody.finally_));
		return bogus(expected, ast.range);
	} else {
		Expr right = checkAndExpect(ctx, locals, &ast.right, Type(ctx.commonTypes.void_));
		Expr below = checkExpr(ctx, locals, &ast.below, expected);
		return Expr(allocate(ctx.alloc, FinallyExpr(ast, right, below)));
	}
}

Expr checkTry(ref ExprCtx ctx, ref LocalsInfo locals, TryAst* ast, ref Expected expected) {
	if (has(tryGetLoop(expected))) {
		addDiag2(ctx, ast.tryKeywordRange, Diag(DiagLoopDisallowedBody.finally_));
		return bogus(expected, ast.range);
	} else {
		Expr body_ = checkExpr(ctx, locals, ast.tried, expected);
		SmallArray!MatchSumTypeCase catches = checkMatchSumTypeCases(
			ctx, locals, ctx.commonTypes.exception, ast.catches, expected);
		return Expr(allocate(ctx.alloc, TryExpr(ast, body_, catches)));
	}
}

Expr checkTryLet(ref ExprCtx ctx, ref LocalsInfo locals, TryLetAst* ast, ref Expected expected) {
	ExprAndType value = checkAndExpectOrInfer(ctx, locals, &ast.value, typeFromDestructure2(ctx, ast.destructure));
	Destructure destructure = checkDestructure2(ctx, &ast.destructure, value.type, DestructureKind.local);
	Opt!MatchSumTypeCase catch_ = checkMatchSumTypeCase(
		ctx, locals, ctx.commonTypes.exception, &ast.catchMember, &ast.catch_, expected);
	if (!has(catch_)) return bogus(expected, ast.range);
	Expr then = checkExprWithDestructure(ctx, locals, destructure, &ast.then, expected);
	return Expr(allocate(ctx.alloc, TryLetExpr(ast, destructure, value.expr, force(catch_), then)));
}

Expr checkTyped(ref ExprCtx ctx, ref LocalsInfo locals, TypedAst* ast, ref Expected expected) {
	Type type = typeFromAst2(ctx, ast.type);
	if (type.isBogus) return bogus(expected, ast.range);
	Opt!Type inferred = tryGetNonInferringType(ctx.instantiateCtx, expected);
	// If inferred != type, we'll fail in 'check'
	if (has(inferred) && force(inferred) == type)
		addDiag2(ctx, ast.keywordAndTypeRange, Diag(DiagTypeAnnotationUnnecessary(typeWithContainer(ctx, type))));
	Expr expr = checkAndExpect(ctx, locals, &ast.expr, type);
	return check(ctx, expected, type, Expr(allocate(ctx.alloc, TypedExpr(ast, expr))));
}
