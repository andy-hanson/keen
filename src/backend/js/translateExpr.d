module backend.js.translateExpr;

@safe @nogc pure nothrow:

import backend.js.allUsed : allUsed, isInlined, FunOrTest, isAsyncCall, isAsyncFun, tryEvalConstantBool;
import backend.js.jsAst :
	exprFunBody,
	exprStatement,
	genArray,
	genArrowFunction,
	genAssign,
	genBlockStatement,
	genBlockStatementStatement,
	genBool,
	genBreak,
	genBreakNoLabel,
	genContinue,
	genGlobal,
	genIdentifier,
	genIf,
	genInstanceMethod,
	genInstanceof,
	genIntegerSigned,
	genIntegerUnsigned,
	genLet,
	genNot,
	genNotEqEq,
	genOr,
	genReturn,
	genString,
	genSwitch,
	genTernary,
	genThis,
	genThrow,
	genTryCatch,
	genTryFinally,
	genTypeof,
	genVarDecl,
	genWhile,
	genWhileTrue,
	JsBlockStatement,
	JsClassMember,
	JsDecl,
	JsDeclKind,
	JsDefaultDestructure,
	JsDestructure,
	JsExpr,
	JsExprOrBlockStatement,
	JsMemberName,
	JsName,
	JsNameKind,
	JsObjectDestructure,
	JsParams,
	JsStatement,
	JsStatementKind,
	JsSwitchCase,
	JsVarDeclConst,
	SyncOrAsync;
import backend.js.jsAstUtil :
	genForceUnionMember,
	genIsUnionMember,
	genOptionForce,
	genOptionHas,
	genOptionNone,
	genOptionSome,
	genThrowBogus,
	genThrowBogusExpr,
	genThrowJsError;
import backend.js.sourceMap : Source;
import backend.js.translateAutoFun : translateAutoFun;
import backend.js.translateExprCtx :
	ExprPos,
	ExprResult,
	forceExpr,
	forceStatement,
	forceStatements,
	makeCall,
	makeCallNoInline,
	makeCallNoInlineWithSpread,
	StatementsCb,
	tempName,
	TranslateCb,
	translateConstant,
	translateEnumValue,
	TranslateExprCtx,
	translateFunToExpr,
	translateCallInline,
	translateLocalGet,
	translateStructReference,
	translateToBlockStatement,
	translateToBogus,
	translateToExpr,
	translateToStatements,
	withTemp;
import backend.js.translateModuleCtx :
	funSource,
	localName,
	makeDecl,
	methodSource,
	sourceAtRange,
	testSource,
	TranslateModuleCtx;
import model.model :
	AnyDecl,
	AssertOrForbidExpr,
	AutoFun,
	BogusCallExpr,
	BogusExpr,
	BogusType,
	BogusWrongTypeExpr,
	BuiltinType,
	Called,
	CallExpr,
	CallOptionExpr,
	caseNameRange,
	ClosureGetExpr,
	ClosureSetExpr,
	Condition,
	defaultAssertOrForbidMessage,
	Destructure,
	eachLocal,
	eachSpecInFunIncludingParents,
	Expr,
	ExprAndType,
	ExternExpr,
	FinallyExpr,
	FunBody,
	FunDecl,
	FunInst,
	FunPointerExpr,
	IfExpr,
	ImportFileContent,
	isSigned,
	isVoid,
	LambdaExpr,
	LetExpr,
	LiteralExpr,
	LiteralStringLikeExpr,
	Local,
	LocalGetExpr,
	LocalPointerExpr,
	LocalSetExpr,
	LoopExpr,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopWhileOrUntilExpr,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchSumTypeCase,
	MatchSumTypeExpr,
	methodCaller,
	paramsArray,
	paramTypeAt,
	RecordField,
	RecordFieldPointerExpr,
	SeqExpr,
	Signature,
	SpecInst,
	StringLiteralKind,
	StructBody,
	StructInst,
	SumTypeKind,
	Test,
	ThrowExpr,
	TrustedExpr,
	TryExpr,
	TryLetExpr,
	Type,
	TypedExpr,
	TypeParamIndex,
	Varargs;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withMapToStackArray;
import util.col.array :
	emptySmallArray,
	exists,
	foldReverseWithIndex,
	map,
	mapWithIndex,
	mapZip,
	newSmallArray,
	only,
	SmallArray;
import util.col.arrayBuilder : add, ArrayBuilder, buildArray, Builder, buildSmallArray, sizeSoFar;
import util.col.map : KeyValuePair;
import util.conv : safeToUshort;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some;
import util.sourceRange : Range, UriAndRange;
import util.symbol : Symbol, symbol;
import util.unicode : mustUnicodeDecode;
import util.util : ptrTrustMe;

private void genAssertTypesForDestructure(
	scope ref ArrayBuilder!JsStatement out_,
	ref TranslateModuleCtx ctx,
	in Source source,
	in Destructure destructure,
) {
	eachLocal(destructure, (Local* x) {
		genAssertType(out_, ctx, source, x.type, translateLocalGet(source, x));
	});
}
void genAssertType(
	scope ref ArrayBuilder!JsStatement out_,
	ref TranslateModuleCtx ctx,
	in Source source,
	in Type type,
	JsExpr get,
) {
	type.matchIn!void(
		(in BogusType _) {},
		(in TypeParamIndex _) {},
		(in StructInst x) {
			genAssertType(out_, ctx, source, x, get);
		});
}
void genAssertType(
	scope ref ArrayBuilder!JsStatement out_,
	ref TranslateModuleCtx ctx,
	in Source source,
	in StructInst a,
	JsExpr get,
) {
	Opt!JsExpr notOk = a.decl.body_.isA!BuiltinType
		? genIsNotBuiltinType(ctx, source, a.decl.body_.as!BuiltinType, get)
		: optIf(!a.decl.body_.isA!(StructBody.Extern) && !isVariantOrInterface(a.decl.body_), () =>
			genNot(
				ctx.alloc, source,
				genInstanceof(ctx.alloc, source, get, translateStructReference(ctx, source, a.decl))));
	if (has(notOk))
		add(ctx.alloc, out_, genIf(
			ctx.alloc,
			source,
			force(notOk),
			genThrowJsError(ctx.alloc, source, "Value did not have expected type")));
}
private bool isVariantOrInterface(in StructBody a) =>
	a.isA!(StructBody.SumType) && () {
		final switch (a.as!(StructBody.SumType).kind) {
			case SumTypeKind.union_:
				return false;
			case SumTypeKind.interface_:
			case SumTypeKind.variant:
				return true;
		}
	}();

private Opt!JsExpr genIsNotBuiltinType(ref TranslateModuleCtx ctx, in Source source, BuiltinType type, JsExpr get) {
	Opt!JsExpr instanceof(Symbol expected) =>
		some(genNot(ctx.alloc, source, genInstanceof(ctx.alloc, source, get, genGlobal(source, expected))));
	Opt!JsExpr typeof_(string expected) =>
		some(genNotEqEq(ctx.alloc, source, genTypeof(ctx.alloc, source, get), genString(source, expected)));
	final switch (type) {
		case BuiltinType.array:
		case BuiltinType.mutArray:
		case BuiltinType.mutSlice: // mutSlice might use a Proxy, but that is still instanceof Array
		case BuiltinType.option:
			return instanceof(symbol!"Array");
		case BuiltinType.bool_:
			return typeof_("boolean");
		case BuiltinType.catchPoint:
		case BuiltinType.pointerConst:
		case BuiltinType.pointerMut:
			return some(genBool(source, true));
		case BuiltinType.char8:
		case BuiltinType.char32:
		case BuiltinType.int8:
		case BuiltinType.int16:
		case BuiltinType.int32:
		case BuiltinType.int64:
		case BuiltinType.nat8:
		case BuiltinType.nat16:
		case BuiltinType.nat32:
		case BuiltinType.nat64:
			return typeof_("bigint");
		case BuiltinType.float32:
		case BuiltinType.float64:
			return typeof_("number");
		case BuiltinType.funPointer:
			return typeof_("function");
		case BuiltinType.future:
			return instanceof(symbol!"Promise");
		case BuiltinType.jsAny:
			return none!JsExpr;
		case BuiltinType.lambdaData:
		case BuiltinType.lambdaShared:
		case BuiltinType.lambdaMut:
			return typeof_("function");
		case BuiltinType.string_:
		case BuiltinType.symbol:
			return typeof_("string");
		case BuiltinType.void_:
			return typeof_("undefined");
	}
}

JsDecl translateTest(ref TranslateModuleCtx ctx, Test* a) {
	TranslateExprCtx exprCtx = TranslateExprCtx(ptrTrustMe(ctx), a.moduleUri, FunOrTest(a));
	return makeDecl(ctx, AnyDecl(a), JsDeclKind(genArrowFunction(
		testSource(ctx, a),
		SyncOrAsync.async,
		JsParams(),
		translateExprToExprOrBlockStatement(exprCtx, a.body_, Type(ctx.commonTypes.void_)))));
}
JsDecl translateFunDecl(ref TranslateModuleCtx ctx, FunDecl* a) {
	TranslateExprCtx exprCtx = TranslateExprCtx(ptrTrustMe(ctx), a.moduleUri, FunOrTest(a));
	JsParams params = translateFunParams(exprCtx, *a);
	JsExpr fun = genArrowFunction(funSource(ctx, a), isAsyncFun(ctx.allUsed, a), params, translateFunBody(exprCtx, a));
	return makeDecl(ctx, AnyDecl(a), JsDeclKind(fun));
}

JsClassMember methodImpl(ref TranslateModuleCtx ctx, Signature* method, in Opt!Called optImpl) {
	Source source = methodSource(ctx, *method);
	Symbol name = method.name;
	FunDecl* caller = methodCaller(ctx.program, method);
	SyncOrAsync async = has(optImpl) ? isAsyncCall(ctx.allUsed, caller, force(optImpl)) : SyncOrAsync.sync;
	if (has(optImpl) && isInlined(force(optImpl))) {
		Called impl = force(optImpl);
		FunDecl* decl = impl.as!(FunInst*).decl;
		TranslateExprCtx exprCtx = TranslateExprCtx(ptrTrustMe(ctx), caller.moduleUri, FunOrTest(caller));
		return genInstanceMethod(
			source,
			async,
			JsMemberName.sumTypeMethod(name),
			translateFunParams(exprCtx, *decl, omitFirst: true),
			translateToBlockStatement(ctx.alloc, (scope ExprPos pos) =>
				translateCallInline(
					exprCtx, source, impl.returnType, pos, decl, impl.paramTypes, impl.arity.as!uint, (size_t i) =>
						i == 0
							? genThis(source)
							: genIdentifier(source, localName(*decl.params.as!(Destructure[])[i].as!(Local*))))));
	} else {
		// foo(...args) { return foo(anySpecs, this, ...args) }
		JsName args = JsName.specialLocal(symbol!"args");
		return genInstanceMethod(
			source,
			async,
			JsMemberName.sumTypeMethod(name),
			JsParams(emptySmallArray!JsDestructure, some(JsDestructure(args))),
			genBlockStatement(ctx.alloc, [
				has(optImpl)
					? genReturn(ctx.alloc, source, makeCallNoInlineWithSpread(
						ctx,
						source,
						async,
						FunOrTest(caller),
						force(optImpl),
						(scope ref Builder!JsExpr out_) { out_ ~= genThis(source); },
						genIdentifier(source, args)))
					: genThrowBogus(ctx.alloc, source)]));
	}
}

private:

JsParams translateFunParams(ref TranslateExprCtx ctx, in FunDecl a, bool omitFirst = false) {
	SmallArray!JsDestructure params = buildSmallArray!JsDestructure(ctx.alloc, (scope ref Builder!JsDestructure out_) {
		translateSpecsToParams(out_, a);
		a.params.match!void(
			(Destructure[] xs) {
				foreach (ref Destructure x; xs[(omitFirst ? 1 : 0) .. $])
					out_ ~= translateDestructure(ctx, x);
			},
			(ref Varargs x) {});
	});
	return JsParams(params, a.params.match!(Opt!JsDestructure)(
		(Destructure[]) => none!JsDestructure,
		(ref Varargs x) =>
			some(translateDestructure(ctx, x.param))));
}
JsDestructure translateDestructure(ref TranslateExprCtx ctx, in Destructure a) =>
	a.matchIn!JsDestructure(
		(in Destructure.Ignore) =>
			JsDestructure(tempName(ctx, symbol!"ignore")),
		(in Local x) =>
			JsDestructure(localName(x)),
		(in Destructure.Split x) =>
			translateDestructureSplit(ctx, exprSource(ctx, a.range), x));
JsDestructure translateDestructureSplit(ref TranslateExprCtx ctx, in Source source, in Destructure.Split x) {
	if (x.isValidDestructure(ctx.commonTypes)) {
		SmallArray!RecordField fields = x.destructuredType.as!(StructInst*).decl.body_.as!(StructBody.Record).fields;
		return JsDestructure(JsObjectDestructure(
			mapZip!(immutable KeyValuePair!(JsMemberName, JsDestructure), RecordField, Destructure)(
				ctx.alloc, fields, x.parts, (ref RecordField field, ref Destructure part) =>
					immutable KeyValuePair!(JsMemberName, JsDestructure)(
						JsMemberName.recordField(field.name),
						translateDestructure(ctx, part)))));
	} else
		return JsDestructure(JsObjectDestructure(
			map(ctx.alloc, x.parts, (ref Destructure part) =>
				immutable KeyValuePair!(JsMemberName, JsDestructure)(
					JsMemberName.special(symbol!"bogus"),
					JsDestructure(allocate(ctx.alloc, JsDefaultDestructure(
						translateDestructure(ctx, part),
						genThrowBogusExpr(ctx.alloc, source))))))));
}
void translateSpecsToParams(scope ref Builder!JsDestructure out_, in FunDecl a) {
	eachSpecInFunIncludingParents(a, (SpecInst* spec) {
		foreach (ref Signature x; spec.decl.sigs)
			out_ ~= JsDestructure(JsName(JsNameKind.specSig, x.name, some(safeToUshort(sizeSoFar(out_)))));
		return false;
	});
}

JsExprOrBlockStatement translateFunBody(ref TranslateExprCtx ctx, FunDecl* fun) {
	Source source = funSource(ctx.ctx, fun);
	if (fun.body_.isA!AutoFun)
		return translateAutoFun(ctx, fun, fun.body_.as!AutoFun);
	else if (fun.body_.isA!Expr)
		return JsExprOrBlockStatement(JsBlockStatement(
			translateToStatements(ctx.alloc, (scope ref ArrayBuilder!JsStatement out_, scope ExprPos pos) {
				foreach (ref Destructure param; paramsArray(fun.params))
					genAssertTypesForDestructure(out_, ctx.ctx, source, param);
				return translateExpr(ctx, fun.body_.as!Expr, fun.returnType, pos);
			})));
	else if (fun.body_.isA!(FunBody.FileImport))
		return fun.body_.as!(FunBody.FileImport).content.match!JsExprOrBlockStatement(
			(immutable ubyte[] bytes) =>
				exprFunBody(ctx.alloc, genArray(source, map(ctx.alloc, bytes, (ref immutable ubyte x) =>
					genIntegerUnsigned(source, x)))),
			(string s) =>
				exprFunBody(ctx.alloc, genString(source, s)),
			(ImportFileContent.Bogus) =>
				JsExprOrBlockStatement(genBlockStatement(ctx.alloc, [genThrowBogus(ctx.alloc, source)])));
	else {
		Destructure[] params = fun.params.as!(Destructure[]);
		return translateToExprOrBlockStatement(ctx.alloc, (scope ExprPos pos) =>
			withMapToStackArray!(ExprResult, Type, Destructure)(
				params,
				(ref Destructure x) => x.type,
				(scope Type[] paramTypes) =>
					translateCallInline(
						ctx, source, fun.returnType, pos, fun, paramTypes, params.length,
						(size_t i) => translateLocalGet(source, params[i].as!(Local*)))));
	}
}

Source exprSource(in TranslateExprCtx ctx, in Expr expr) =>
	exprSource(ctx, expr.range);
Source exprSource(in TranslateExprCtx ctx, in Range range) =>
	sourceAtRange(ctx.ctx, UriAndRange(ctx.curUri, range), ctx.curFun.name);

JsExpr translateExprToExpr(ref TranslateExprCtx ctx, ExprAndType a) =>
	translateExprToExpr(ctx, a.expr, a.type);
JsExpr translateExprToExpr(ref TranslateExprCtx ctx, ref Expr a, Type type) =>
	translateExpr(ctx, a, type, ExprPos(ExprPos.Expression())).as!JsExpr;
JsStatement translateToStatement(ref Alloc alloc, in Source source, in TranslateCb cb) =>
	translateToStatement(alloc, source, (scope ref ArrayBuilder!JsStatement, scope ExprPos pos) => cb(pos));
JsStatement translateToStatement(ref Alloc alloc, in Source source, in StatementsCb cb) {
	JsStatement[] statements = translateToStatements(alloc, cb);
	return statements.length == 1 ? only(statements) : genBlockStatementStatement(source, statements);
}
JsBlockStatement translateToBlockStatement(ref Alloc alloc, in TranslateCb cb) =>
	translateToBlockStatement(alloc, (scope ref ArrayBuilder!JsStatement, scope ExprPos pos) => cb(pos));

JsBlockStatement translateExprToBlockStatement(ref TranslateExprCtx ctx, ref Expr a, Type type) =>
	translateToBlockStatement(ctx.alloc, (scope ExprPos pos) => translateExpr(ctx, a, type, pos));
JsExprOrBlockStatement translateExprToExprOrBlockStatement(ref TranslateExprCtx ctx, ref Expr a, Type type) =>
	toExprOrBlockStatement(ctx.alloc, translateExpr(ctx, a, type, ExprPos(ExprPos.ExpressionOrBlockStatement())));
JsExprOrBlockStatement translateToExprOrBlockStatement(ref Alloc alloc, in TranslateCb cb) =>
	toExprOrBlockStatement(alloc, cb(ExprPos(ExprPos.ExpressionOrBlockStatement())));
JsExprOrBlockStatement toExprOrBlockStatement(ref Alloc alloc, ExprResult result) =>
	result.match!JsExprOrBlockStatement(
		(ExprResult.Done) =>
			assert(false),
		(JsExpr x) =>
			exprFunBody(alloc, x),
		(JsBlockStatement x) =>
			JsExprOrBlockStatement(x));

JsBlockStatement translateExprToSwitchBlockStatement(ref TranslateExprCtx ctx, ref Expr a, Type type) =>
	isVoid(type)
		? translateToBlockStatement(ctx.alloc, (scope ExprPos pos) =>
			forceStatements(
				ctx, exprSource(ctx, a), pos,
				(scope ref ArrayBuilder!JsStatement out_, scope ExprPos inner) {
					ExprResult result = translateExpr(ctx, a, type, inner);
					assert(result.isA!(ExprResult.Done));
					add(ctx.alloc, out_, genBreakNoLabel(exprSource(ctx, a)));
					return result;
				}))
		: translateExprToBlockStatement(ctx, a, type);

ExprResult translateExpr(ref TranslateExprCtx ctx, ref Expr a, Type type, scope ExprPos pos) {
	Source source = exprSource(ctx, a);
	return a.kind.match!ExprResult(
		(ref AssertOrForbidExpr x) =>
			translateAssertOrForbid(ctx, a, source, x, type, pos),
		(BogusCallExpr x) =>
			forceStatement(ctx, pos, genThrowBogus(ctx.alloc, source)),
		(BogusExpr x) =>
			forceStatement(ctx, pos, genThrowBogus(ctx.alloc, source)),
		(BogusWrongTypeExpr x) =>
			forceStatement(ctx, pos, genThrowBogus(ctx.alloc, source)),
		(CallExpr x) =>
			translateCall(ctx, source, x, type, pos),
		(ref CallOptionExpr x) =>
			translateCallOption(ctx, source, x, type, pos),
		(ClosureGetExpr x) =>
			forceExpr(ctx, pos, type, genIdentifier(source, localName(*x.local))),
		(ClosureSetExpr x) =>
			forceStatement(ctx, pos, genAssign(
				ctx.alloc,
				source,
				localName(*x.local),
				translateExprToExpr(ctx, *x.value, x.local.type))),
		(ExternExpr x) =>
			forceExpr(ctx, pos, type, genBool(source, ctx.ctx.allExterns.containsAll(x.names))),
		(ref FinallyExpr x) =>
			translateFinally(ctx, source, x, type, pos),
		(FunPointerExpr x) =>
			forceExpr(ctx, pos, type, translateFunToExpr(ctx, source, x.called)),
		(ref IfExpr x) =>
			translateIf(ctx, source, x, type, pos),
		(ref LambdaExpr x) =>
			translateLambda(ctx, source, x, type, pos),
		(ref LetExpr x) =>
			translateLet(ctx, source, x, type, pos),
		(LiteralExpr x) =>
			forceExpr(ctx, pos, type, translateConstant(ctx.ctx, source, x.value, type)),
		(LiteralStringLikeExpr x) =>
			forceExpr(ctx, pos, type, translateLiteralStringLike(ctx, source, x)),
		(LocalGetExpr x) {
			if (x.local.type.isBogus)
				return translateToBogus(ctx.alloc, source, pos);
			else {
				assert(type == x.local.type);
				return forceExpr(ctx, pos, type, translateLocalGet(source, x.local));
			}
		},
		(LocalPointerExpr x) =>
			assert(false),
		(LocalSetExpr x) =>
			forceStatement(ctx, pos, genAssign(
				ctx.alloc,
				source,
				localName(*x.local),
				translateExprToExpr(ctx, *x.value, x.local.type))),
		(ref LoopExpr x) =>
			forceStatement(ctx, pos, genWhileTrue(
				ctx.alloc,
				source,
				some(JsName.noPrefix(symbol!"loop")),
				translateExprToBlockStatement(ctx, x.body_, type))),
		(ref LoopBreakExpr x) {
			assert(pos.isA!(ExprPos.Statements*));
			ExprResult res = translateExpr(ctx, x.value, type, pos);
			assert(res.isA!(ExprResult.Done));
			if (isVoid(type))
				add(
					ctx.alloc,
					pos.as!(ExprPos.Statements*).statements,
					genBreak(source, JsName.noPrefix(symbol!"loop")));
			return res;
		},
		(LoopContinueExpr x) {
			assert(pos.isA!(ExprPos.Statements*));
			return forceStatement(ctx, pos, genContinue(source));
		},
		(ref LoopWhileOrUntilExpr x) =>
			translateLoopWhileOrUntil(ctx, source, x, type, pos),
		(ref MatchEnumExpr x) =>
			translateMatchEnum(ctx, source, a, x, type, pos),
		(ref MatchIntegralExpr x) =>
			translateMatchIntegral(ctx, source, x, type, pos),
		(ref MatchStringLikeExpr x) =>
			translateMatchStringLike(ctx, source, x, type, pos),
		(ref MatchSumTypeExpr x) =>
			translateMatchSumType(ctx, source, a, x, type, pos),
		(ref RecordFieldPointerExpr x) =>
			assert(false),
		(ref SeqExpr x) =>
			forceStatements(ctx, source, pos, (scope ref ArrayBuilder!JsStatement, scope ExprPos inner) {
				ExprResult first = translateExpr(ctx, x.first, Type(ctx.commonTypes.void_), inner);
				assert(first.isA!(ExprResult.Done));
				return translateExpr(ctx, x.then, type, inner);
			}),
		(ref ThrowExpr x) =>
			forceStatement(ctx, pos, genThrow(
				ctx.alloc,
				source,
				translateExprToExpr(ctx, x.thrown, Type(ctx.commonTypes.exception)))),
		(ref TrustedExpr x) =>
			translateExpr(ctx, x.inner, type, pos),
		(ref TryExpr x) =>
			translateTry(ctx, source, a, x, type, pos),
		(ref TryLetExpr x) =>
			translateTryLet(ctx, source, x, type, pos),
		(ref TypedExpr x) =>
			translateExpr(ctx, x.inner, type, pos));
}

ExprResult translateAssertOrForbid(
	ref TranslateExprCtx ctx,
	ref Expr expr,
	in Source source,
	ref AssertOrForbidExpr a,
	Type type,
	scope ExprPos pos,
) {
	ExprResult throw_(scope ExprPos inner) =>
		forceStatement(ctx, inner, genThrow(ctx.alloc, source, has(a.thrown)
			? translateExprToExpr(ctx, *force(a.thrown), Type(ctx.commonTypes.exception))
			: genNewError(
				ctx,
				source,
				defaultAssertOrForbidMessage(ctx.alloc, ctx.curUri, expr, a, ctx.fileContentGetters))));
	ExprResult after(scope ExprPos inner) =>
		translateExpr(ctx, a.after, type, inner);
	return translateIfCb(
		ctx, source, type, pos, a.condition,
		cbTrueBranch: (scope ExprPos inner) => a.isForbid ? throw_(inner) : after(inner),
		cbFalseBranch: (scope ExprPos inner) => a.isForbid ? after(inner) : throw_(inner));
}

ExprResult translateCall(ref TranslateExprCtx ctx, in Source source, ref CallExpr a, Type type, scope ExprPos pos) {
	assert(type == a.called.returnType);
	return translateCallCommon(ctx, source, a.called, [], a.args, pos);
}
ExprResult translateCallOption(
	ref TranslateExprCtx ctx,
	in Source source,
	ref CallOptionExpr a,
	Type type,
	scope ExprPos pos,
) =>
	/*
	firstArg?.called
	==>
	const option = firstArg
	return "some" in option
		// 'Option.some' will be omitted if 'called' already returns an option
		? Option.some(called(option.some))
		: Option.none
	*/
	withTemp(ctx, symbol!"option", a.firstArg, pos, (JsName option, scope ExprPos inner) {
		JsExpr forceIt = genOptionForce(ctx.alloc, source, genIdentifier(source, option));
		JsExpr call = translateToExpr((scope ExprPos callPos) =>
			translateCallCommon(ctx, source, a.called, [forceIt], a.restArgs, callPos));
		JsExpr then = a.called.returnType == type
			? call
			: genOptionSome(ctx.alloc, source, call);
		return forceExpr(ctx, inner, type, genTernary(
			ctx.alloc,
			source,
			genOptionHas(ctx.alloc, source, genIdentifier(source, option)),
			then,
			genOptionNone(source)));
	});
ExprResult translateCallCommon(
	ref TranslateExprCtx ctx,
	in Source source,
	Called called,
	in JsExpr[] prefixArgs,
	in Expr[] args,
	scope ExprPos pos,
) =>
	isInlined(called)
		? translateCallInline(
			ctx,
			source,
			called.returnType,
			pos,
			called.as!(FunInst*).decl,
			called.as!(FunInst*).paramTypes,
			prefixArgs.length + args.length,
			(size_t argIndex) =>
				argIndex < prefixArgs.length
					? prefixArgs[argIndex]
					: translateExprToExpr(ctx, args[argIndex - prefixArgs.length], paramTypeAt(called, argIndex)))
		: forceExpr(ctx, pos, called.returnType, makeCallNoInline(ctx, source, called, (scope ref Builder!JsExpr out_) {
			out_ ~= prefixArgs;
			foreach (size_t argIndex, ref Expr arg; args)
				out_ ~= translateExprToExpr(ctx, arg, paramTypeAt(called, prefixArgs.length + argIndex));
		}));

ExprResult translateIf(ref TranslateExprCtx ctx, in Source source, ref IfExpr a, Type type, scope ExprPos pos) =>
	translateIfCb(
		ctx, source, type, pos, a.condition,
		(scope ExprPos inner) => translateExpr(ctx, a.trueBranch, type, inner),
		(scope ExprPos inner) => translateExpr(ctx, a.falseBranch, type, inner));
ExprResult translateIfCb(
	ref TranslateExprCtx ctx,
	in Source source,
	Type type,
	scope ExprPos pos,
	in Condition condition,
	in TranslateCb cbTrueBranch,
	in TranslateCb cbFalseBranch,
) {
	Opt!bool constant = tryEvalConstantBool(ctx.ctx.version_, ctx.ctx.allExterns, condition);
	return has(constant)
		? (force(constant) ? cbTrueBranch : cbFalseBranch)(pos)
		: pos.isA!(ExprPos.Expression) && condition.isA!(Expr*)
		? ExprResult(genTernary(
			ctx.alloc,
			source,
			translateExprToExpr(ctx, *condition.as!(Expr*), Type(ctx.commonTypes.bool_)),
			translateToExpr(cbTrueBranch),
			translateToExpr(cbFalseBranch)))
		: condition.match!ExprResult(
			(ref Expr cond) =>
				forceStatement(ctx, pos, genIf(
					ctx.alloc,
					source,
					translateExprToExpr(ctx, cond, Type(ctx.commonTypes.bool_)),
					translateToStatement(ctx.alloc, source, cbTrueBranch),
					translateToStatement(ctx.alloc, source, cbFalseBranch))),
			(ref Condition.UnpackOption x) =>
				translateUnpackOption(ctx, source,type, pos, x, cbTrueBranch, cbFalseBranch));
}
ExprResult translateUnpackOption(
	ref TranslateExprCtx ctx,
	in Source source,
	Type type,
	scope ExprPos pos,
	ref Condition.UnpackOption unpack,
	in TranslateCb cbTrueBranch,
	in TranslateCb cbFalseBranch,
) =>
	/*
	const option = <<option>>
	if ('some' in option) {
		const <<destructure>> = option.some
		<<true branch>>
	} else {
		<<false branch>>
	}
	*/
	withTemp(ctx, symbol!"option", unpack.option, pos, (JsName option, scope ExprPos inner) =>
		forceStatement(ctx, inner, genIf(
			ctx.alloc,
			source,
			genOptionHas(ctx.alloc, source, genIdentifier(source, option)),
			translateToStatement(ctx.alloc, source, (scope ExprPos inner2) =>
				translateLetLikeCb(
					ctx, source, unpack.destructure,
					genOptionForce(ctx.alloc, source, genIdentifier(source, option)),
					inner2,
					(scope ref ArrayBuilder!JsStatement, scope ExprPos inner3) =>
						cbTrueBranch(inner3))),
			translateToStatement(ctx.alloc, source, cbFalseBranch))));

ExprResult translateLambda(
	ref TranslateExprCtx ctx,
	in Source source,
	ref LambdaExpr a,
	Type type,
	scope ExprPos pos,
) =>
	forceExpr(ctx, pos, type, genArrowFunction(
		source,
		SyncOrAsync.async,
		JsParams(newSmallArray(ctx.alloc, [translateDestructure(ctx, a.param)])),
		translateExprToExprOrBlockStatement(ctx, a.body_, a.returnType)));

ExprResult translateLet(ref TranslateExprCtx ctx, in Source source, ref LetExpr a, Type type, scope ExprPos pos) =>
	translateLetLike(
		ctx, source, a.destructure, translateExprToExpr(ctx, a.value, a.destructure.type), a.then, type, pos);
ExprResult translateLetLike(
	ref TranslateExprCtx ctx,
	in Source source,
	ref Destructure destructure,
	JsExpr value,
	ref Expr then,
	Type type,
	scope ExprPos pos,
) =>
	translateLetLikeCb(
		ctx, source, destructure, value, pos,
		(scope ref ArrayBuilder!JsStatement, scope ExprPos inner) =>
			translateExpr(ctx, then, type, inner));
ExprResult translateLetLikeCb(
	ref TranslateExprCtx ctx,
	in Source source,
	in Destructure destructure,
	JsExpr value,
	scope ExprPos pos,
	in StatementsCb cb,
) =>
	forceStatements(ctx, source, pos, (scope ref ArrayBuilder!JsStatement out_, scope ExprPos inner) {
		if (destructure.isA!(Destructure.Ignore*)) {
			if (!value.kind.isA!JsName)
				add(ctx.alloc, out_, exprStatement(value));
		} else
			add(ctx.alloc, out_, genVarDecl(
				source,
				hasAnyMutable(destructure) ? JsVarDeclConst.let : JsVarDeclConst.const_,
				translateDestructure(ctx, destructure),
				some(allocate(ctx.alloc, value))));
		return cb(out_, inner);
	});

JsExpr translateLiteralStringLike(ref TranslateExprCtx ctx, in Source source, ref LiteralStringLikeExpr a) {
	final switch (a.kind) {
		case StringLiteralKind.char8Array:
			return genArray(source, map(ctx.alloc, a.value, (ref immutable char x) =>
				genIntegerUnsigned(source, x)));
		case StringLiteralKind.char32Array:
			return genArray(source, buildArray!JsExpr(ctx.alloc, (scope ref Builder!JsExpr out_) {
				mustUnicodeDecode(a.value, (dchar x) {
					out_ ~= genIntegerUnsigned(source, x);
				});
			}));
		case StringLiteralKind.cString:
			assert(false);
		case StringLiteralKind.jsAny:
		case StringLiteralKind.string_:
		case StringLiteralKind.symbol:
			return genString(source, a.value);
	}
}

ExprResult translateLoopWhileOrUntil(
	ref TranslateExprCtx ctx,
	in Source source,
	ref LoopWhileOrUntilExpr a,
	Type type,
	scope ExprPos pos,
) =>
	a.condition.match!ExprResult(
		(ref Expr cond) {
			JsExpr condition = translateExprToExpr(ctx, cond, Type(ctx.commonTypes.bool_));
			JsExpr condition2 = a.isUntil ? genNot(ctx.alloc, source, condition) : condition;
			return forceStatements(ctx, source, pos, (scope ref ArrayBuilder!JsStatement res, scope ExprPos inner) {
				add(ctx.alloc, res, genWhile(
					ctx.alloc,
					source,
					condition2,
					translateExprToBlockStatement(ctx, a.body_, Type(ctx.commonTypes.void_))));
				return translateExpr(ctx, a.after, type, inner);
			});
		},
		(ref Condition.UnpackOption unpack) =>
			forceStatements(ctx, source, pos, (scope ref ArrayBuilder!JsStatement outerOut, scope ExprPos outerPos) {
				if (a.isUntil) {
					/*
					let option
					while (true) {
						option = <<option>>
						if ("some" in option) break
						<<body>>
					}
					const <<destructure>> = option.some
					<<after>>
					*/
					JsName option = tempName(ctx, symbol!"option");
					add(ctx.alloc, outerOut, genLet(source, option));
					JsBlockStatement body_ = translateToBlockStatement(
						ctx.alloc,
						(scope ref ArrayBuilder!JsStatement out_, scope ExprPos bodyPos) {
							add(ctx.alloc, out_, genAssign(
								ctx.alloc, source, option, translateExprToExpr(ctx, unpack.option)));
							add(ctx.alloc, out_, genIf(
								ctx.alloc,
								source,
								genOptionHas(ctx.alloc, source, genIdentifier(source, option)),
								genBreakNoLabel(source)));
							return translateExpr(ctx, a.body_, Type(ctx.commonTypes.void_), bodyPos);
						});
					add(ctx.alloc, outerOut, genWhileTrue(ctx.alloc, source, body_));
					return translateLetLike(
						ctx, source, unpack.destructure,
						genOptionForce(ctx.alloc, source, genIdentifier(source, option)),
						a.after, type, outerPos);
				} else {
					/*
					while (true) {
						const option = <<option>>
						if ("some" in option) {
							const <<destructure>> = option.some
							<<body>>
						} else
							break
					}
					<<after>>
					*/
					JsBlockStatement body_ = translateToBlockStatement(
						ctx.alloc,
						(scope ref ArrayBuilder!JsStatement out_, scope ExprPos bodyPos) =>
							translateUnpackOption(
								ctx, source, Type(ctx.commonTypes.void_), bodyPos, unpack,
								(scope ExprPos thenPos) =>
									translateExpr(ctx, a.body_, Type(ctx.commonTypes.void_), thenPos),
								(scope ExprPos elsePos) =>
									forceStatement(ctx, elsePos, genBreakNoLabel(source))));
					add(ctx.alloc, outerOut, genWhileTrue(ctx.alloc, source, body_));
					return translateExpr(ctx, a.after, type, outerPos);
				}
			}));

ExprResult translateMatchEnum(
	ref TranslateExprCtx ctx,
	in Source source,
	in Expr expr,
	ref MatchEnumExpr a,
	Type type,
	scope ExprPos pos,
) =>
	forceStatement(ctx, pos, genSwitch(
		source,
		allocate(ctx.alloc, translateExprToExpr(ctx, a.matched)),
		mapWithIndex!(JsSwitchCase, MatchEnumExpr.Case)(
			ctx.alloc, a.cases,
			(size_t caseIndex, ref MatchEnumExpr.Case case_) =>
				JsSwitchCase(
					translateEnumValue(ctx.ctx, exprSource(ctx, caseNameRange(expr, caseIndex)), *case_.member),
					translateExprToSwitchBlockStatement(ctx, case_.then, type))),
		translateSwitchDefault(ctx, source, a.else_, type, "Invalid enum value")));

ExprResult translateMatchIntegral(
	ref TranslateExprCtx ctx,
	in Source source,
	ref MatchIntegralExpr a,
	Type type,
	scope ExprPos pos,
) =>
	forceStatement(ctx, pos, genSwitch(
		source,
		allocate(ctx.alloc, translateExprToExpr(ctx, a.matched)),
		map(ctx.alloc, a.cases, (ref MatchIntegralExpr.Case case_) =>
			JsSwitchCase(
				a.kind.isSigned
					? genIntegerSigned(source, case_.value.asSigned)
					: genIntegerUnsigned(source, case_.value.asUnsigned),
				translateExprToSwitchBlockStatement(ctx, case_.then, type))),
		translateExprToSwitchBlockStatement(ctx, a.else_, type)));

ExprResult translateMatchStringLike(
	ref TranslateExprCtx ctx,
	in Source source,
	ref MatchStringLikeExpr a,
	Type type,
	scope ExprPos pos,
) =>
	forceStatement(ctx, pos, genSwitch(
		source,
		allocate(ctx.alloc, translateExprToExpr(ctx, a.matched)),
		map(ctx.alloc, a.cases, (ref MatchStringLikeExpr.Case case_) =>
			JsSwitchCase(
				genString(source, case_.value),
				translateExprToSwitchBlockStatement(ctx, case_.then, type))),
		translateExprToSwitchBlockStatement(ctx, a.else_, type)));

ExprResult translateMatchSumType(
	ref TranslateExprCtx ctx,
	in Source source,
	in Expr expr,
	ref MatchSumTypeExpr a,
	Type type,
	scope ExprPos pos,
) =>
	withTemp(ctx, symbol!"matched", a.matched, pos, (JsName matched, scope ExprPos inner) =>
		translateMatchSumType(
			ctx, source, matched, expr, a.isUnion, a.cases,
			translateSwitchDefault(
				ctx, source, optIf(has(a.else_), () => *force(a.else_)), type, "Invalid union value"),
			type, inner));
ExprResult translateMatchSumType(
	ref TranslateExprCtx ctx,
	in Source source,
	JsName matched,
	in Expr expr,
	bool isUnion,
	MatchSumTypeCase[] cases,
	JsBlockStatement default_,
	Type type,
	scope ExprPos pos,
) =>
	forceStatement(
		ctx, pos,
		foldReverseWithIndex!(JsStatement, MatchSumTypeCase)(
			JsStatement(source, JsStatementKind(default_)),
			cases,
			(JsStatement else_, size_t caseIndex, ref MatchSumTypeCase case_) {
				Source caseSource = exprSource(ctx, caseNameRange(expr, caseIndex));
				JsExpr matchedExpr = genIdentifier(source, matched);
				JsExpr isMatch = isUnion
					? genIsUnionMember(ctx.alloc, caseSource, matchedExpr, case_.member)
					: genInstanceof(
							ctx.alloc, caseSource, matchedExpr,
							translateStructReference(ctx, caseSource, case_.member.decl));
				JsExpr destructured = isUnion
					? genForceUnionMember(ctx.alloc, source, matchedExpr, case_.member)
					: matchedExpr;
				JsStatement then = translateToStatement(ctx.alloc, source, (scope ExprPos pos) =>
					translateLetLike(ctx, source, case_.destructure, destructured, case_.then, type, pos));
				return genIf(ctx.alloc, source, isMatch, then, else_);
			}));

ExprResult withTemp(
	ref TranslateExprCtx ctx,
	Symbol name,
	ExprAndType value,
	scope ExprPos pos,
	in ExprResult delegate(JsName temp, scope ExprPos inner) @safe @nogc pure nothrow cb,
) =>
	withTemp(ctx, name, translateExprToExpr(ctx, value), pos ,cb);

JsExpr genNewError(ref TranslateExprCtx ctx, in Source source, string message) =>
	makeCall(ctx, source, Called(ctx.ctx.program.commonFuns.createError), [genString(source, message)]);

JsBlockStatement translateSwitchDefault(
	ref TranslateExprCtx ctx,
	in Source source,
	Opt!Expr else_,
	Type type,
	string error,
) =>
	has(else_)
		? translateExprToSwitchBlockStatement(ctx, force(else_), type)
		: genBlockStatement(ctx.alloc, [genThrowJsError(ctx.alloc, source, error)]);

ExprResult translateFinally(
	ref TranslateExprCtx ctx,
	in Source source,
	ref FinallyExpr a,
	Type type,
	scope ExprPos pos,
) =>
	/*
	finally right
	below
	==>
	try {
		below
	} finally {
		right
	}
	*/
	forceStatement(ctx, pos, genTryFinally(
		source,
		translateExprToBlockStatement(ctx, a.below, type),
		translateExprToBlockStatement(ctx, a.right, Type(ctx.commonTypes.void_))));

ExprResult translateTry(
	ref TranslateExprCtx ctx,
	in Source source,
	in Expr expr,
	ref TryExpr a,
	Type type,
	scope ExprPos pos,
) {
	JsName exceptionName = JsName.specialLocal(symbol!"exception");
	return forceStatement(ctx, pos, genTryCatch(
		ctx.alloc,
		source,
		translateExprToBlockStatement(ctx, a.tried, type),
		exceptionName,
		translateToBlockStatement(ctx.alloc, (scope ExprPos inner) =>
			translateMatchSumType(
				ctx, source, exceptionName, expr, isUnion: false, a.catches,
				genBlockStatement(ctx.alloc, [genThrow(ctx.alloc, source, genIdentifier(source, exceptionName))]),
				type, inner))));
}

ExprResult translateTryLet(
	ref TranslateExprCtx ctx,
	in Source source,
	ref TryLetExpr a,
	Type type,
	scope ExprPos pos,
) =>
	/*
	try destructure = value catch foo f : handler
	then
	==>
	let catching = true
	try {
		const destructure = value
		catching = false
		then
	} catch (exception) {
		if (!catching || !(exception instanceof Foo)) throw exception
		const f = exception
		handler
	}
	*/
	forceStatements(ctx, source, pos, (scope ref ArrayBuilder!JsStatement out_, scope ExprPos inner) {
		JsName catching = tempName(ctx, symbol!"catching");
		add(ctx.alloc, out_, genLet(ctx.alloc, source, JsDestructure(catching), genBool(source, true)));
		JsBlockStatement tryBlock = translateToBlockStatement(ctx.alloc, (scope ExprPos tryPos) =>
			translateLetLikeCb(
				ctx,
				source,
				a.destructure,
				translateExprToExpr(ctx, a.value, a.destructure.type),
				tryPos,
				(scope ref ArrayBuilder!JsStatement tryOut, scope ExprPos tryInner) {
					add(ctx.alloc, tryOut, genAssign(ctx.alloc, source, catching, genBool(source, false)));
					return translateExpr(ctx, a.then, type, tryInner);
				}));
		JsName exceptionName = tempName(ctx, symbol!"exception");
		JsBlockStatement catchBlock = translateToBlockStatement(
			ctx.alloc,
			(scope ref ArrayBuilder!JsStatement catchOut, scope ExprPos catchPos) {
				JsExpr cond = genOr(
					ctx.alloc,
					source,
					genNot(ctx.alloc, source, genIdentifier(source, catching)),
					genNot(
						ctx.alloc,
						source,
						genInstanceof(ctx.alloc, source, genIdentifier(source, exceptionName),
						translateStructReference(ctx, source, a.catch_.member.decl))));
				add(ctx.alloc, catchOut, genIf(
					ctx.alloc, source, cond,
					genThrow(ctx.alloc, source, genIdentifier(source, exceptionName))));
				return translateLetLike(
					ctx, source, a.catch_.destructure,
					genIdentifier(source, exceptionName),
					a.catch_.then, type, catchPos);
			});
		add(ctx.alloc, out_, genTryCatch(ctx.alloc, source, tryBlock, exceptionName, catchBlock));
		return ExprResult.done;
	});

bool hasAnyMutable(in Destructure a) =>
	a.matchIn!bool(
		(in Destructure.Ignore) =>
			false,
		(in Local x) =>
			!x.mutability.isImmutable,
		(in Destructure.Split x) =>
			exists!Destructure(x.parts, (in Destructure part) => hasAnyMutable(part)));
