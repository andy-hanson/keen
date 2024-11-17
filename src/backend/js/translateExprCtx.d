module backend.js.translateExprCtx;

@safe @nogc pure nothrow:

import backend.js.allUsed : allUsed, bodyIsInlined, FunOrTest, isAsyncCall, isAsyncFun, isInlined;
import backend.js.jsAst :
	exprFunBody,
	exprStatement,
	genAnd,
	genArray,
	genArrowFunction,
	genAssign,
	genAwait,
	genBinary,
	genBitwiseNot,
	genBlockStatement,
	genBool,
	genCall,
	genCallAwait,
	genCallPropertySync,
	genCallSync,
	genCallWithSpread,
	genConst,
	genEqEqEq,
	genGlobal,
	genIdentifier,
	genIife,
	genIn,
	genInstanceof,
	genIntegerSigned,
	genIntegerUnsigned,
	genNew,
	genNot,
	genNotNot,
	genNull,
	genNumber,
	genOr,
	genPropertyAccess,
	genPropertyAccessComputed,
	genReturn,
	genString,
	genTernary,
	genThrowBogus,
	genThrowBogusExpr,
	genTimes,
	genUnary,
	genUndefined,
	JsBinaryExpr,
	JsBlockStatement,
	JsDestructure,
	JsExpr,
	JsMemberName,
	JsName,
	JsParams,
	JsStatement,
	JsUnaryExpr,
	SyncOrAsync;
import backend.js.sourceMap : Source;
import backend.js.translateModuleCtx :
	localName,
	TranslateModuleCtx,
	translateFunReference,
	translateStructReference,
	translateTestReference,
	translateVarReference;
import frontend.storage : FileContentGetters;
import model.constant : asBool, asInt64, asNat64, Constant;
import model.model :
	AutoFun,
	Builtin4ary,
	BuiltinBinary,
	BuiltinBinaryLazy,
	BuiltinBinaryMath,
	BuiltinFun,
	BuiltinTernary,
	BuiltinType,
	BuiltinUnary,
	BuiltinUnaryMath,
	Called,
	CalledSpecSig,
	CommonTypes,
	eachSpecInFunIncludingParents,
	eachTest,
	EnumOrFlagsMember,
	Expr,
	FlagsFunction,
	FunBody,
	FunDecl,
	FunInst,
	FunKind,
	isVoid,
	JsFun,
	Local,
	mustUnwrapOptionType,
	RecordField,
	SpecInst,
	StructBody,
	StructDecl,
	StructInst,
	Test,
	Type,
	TypeParamIndex,
	SumTypeKind;
import util.alloc.alloc : Alloc;
import util.col.array : emptySmallArray, isEmpty, makeArray, map, newArray, only;
import util.col.arrayBuilder : add, ArrayBuilder, buildArray, Builder, finish;
import util.conv : safeToUshort;
import util.memory : allocate;
import util.opt : force, none, some;
import util.symbol : Symbol, symbol;
import util.union_ : TaggedUnion, Union;
import util.uri : Uri;
import versionInfo : isVersion, VersionFun;

struct TranslateExprCtx {
	@safe @nogc pure nothrow:
	TranslateModuleCtx* ctxPtr;
	Uri curUri;
	FunOrTest curFun;
	private uint nextTempIndex;

	ref inout(TranslateModuleCtx) ctx() return scope inout =>
		*ctxPtr;
	ref Alloc alloc() =>
		ctx.alloc;
	ref CommonTypes commonTypes() =>
		ctx.commonTypes;
	FileContentGetters fileContentGetters() =>
		ctx.ctx.showCtx.fileContentGetters;
}

JsName tempName(ref TranslateExprCtx ctx, Symbol base) =>
	JsName.temp(base, safeToUshort(ctx.nextTempIndex++));

JsExpr translateStructReference(in TranslateExprCtx ctx, in Source source, in StructDecl* a) =>
	translateStructReference(ctx.ctx, source, a);

struct ExprPos {
	immutable struct Expression {}
	// Used for return from a function (since an arrow function can be an expression or a block)
	immutable struct ExpressionOrBlockStatement {}
	// If the expression is non-void, the statement should 'return'
	struct Statements { ArrayBuilder!JsStatement statements; }
	mixin TaggedUnion!(Expression, ExpressionOrBlockStatement, Statements*);
}
immutable struct ExprResult {
	@safe @nogc pure nothrow:

	immutable struct Done {}
	mixin Union!(Done, JsExpr, JsBlockStatement);

	static ExprResult done() =>
		ExprResult(ExprResult.Done());
}

private SyncOrAsync isCurFunAsync(in TranslateExprCtx ctx) =>
	ctx.curFun.matchWithPointers!SyncOrAsync(
		(FunDecl* x) => isAsyncFun(ctx.ctx.allUsed, x),
		(Test*) => SyncOrAsync.async);
SyncOrAsync isAsyncCall(in TranslateExprCtx ctx, in Called called) =>
	isAsyncCall(ctx.ctx.allUsed, ctx.curFun, called);

alias StatementsCb = ExprResult delegate(scope ref ArrayBuilder!JsStatement, scope ExprPos) @safe @nogc pure nothrow;
alias TranslateCb = ExprResult delegate(scope ExprPos) @safe @nogc pure nothrow;

JsExpr translateToExpr(in TranslateCb cb) =>
	cb(ExprPos(ExprPos.Expression())).as!JsExpr;

JsBlockStatement translateToBlockStatement(ref Alloc alloc, in StatementsCb cb) =>
	JsBlockStatement(translateToStatements(alloc, cb));

JsStatement[] translateToStatements(ref Alloc alloc, in StatementsCb cb) {
	ExprPos.Statements pos;
	ExprResult res = cb(pos.statements, ExprPos(&pos));
	assert(res.isA!(ExprResult.Done));
	JsStatement[] statements = finish(alloc, pos.statements);
	assert(!isEmpty(statements));
	return statements;
}

ExprResult forceExpr(ref TranslateExprCtx ctx, scope ExprPos pos, Type type, JsExpr expr) =>
	forceExpr(ctx.alloc, pos, type, expr);
ExprResult forceExpr(ref Alloc alloc, scope ExprPos pos, Type type, JsExpr expr) =>
	pos.match!ExprResult(
		(ExprPos.Expression) =>
			ExprResult(expr),
		(ExprPos.ExpressionOrBlockStatement) =>
			ExprResult(expr),
		(ref ExprPos.Statements x) {
			add(alloc, x.statements, isVoid(type) ? exprStatement(expr) : genReturn(alloc, expr.source, expr));
			return ExprResult.done;
		});
ExprResult forceStatements(ref TranslateExprCtx ctx, in Source source, scope ExprPos pos, in StatementsCb cb) =>
	pos.match!ExprResult(
		(ExprPos.Expression) =>
			ExprResult(genIife(ctx.alloc, source, isCurFunAsync(ctx), makeBlockStatement(ctx.alloc, cb))),
		(ExprPos.ExpressionOrBlockStatement) =>
			ExprResult(makeBlockStatement(ctx.alloc, cb)),
		(ref ExprPos.Statements x) =>
			cb(x.statements, pos));
private JsBlockStatement makeBlockStatement(
	ref Alloc alloc,
	in ExprResult delegate(scope ref ArrayBuilder!JsStatement, scope ExprPos) @safe @nogc pure nothrow cb,
) {
	ExprPos.Statements res;
	ExprResult inner = cb(res.statements, ExprPos(&res));
	assert(inner.isA!(ExprResult.Done));
	return JsBlockStatement(finish(alloc, res.statements));
}

ExprResult forceStatement(ref TranslateExprCtx ctx, scope ExprPos pos, JsStatement statement) =>
	forceStatement(ctx.alloc, isCurFunAsync(ctx), pos, statement);
ExprResult forceStatement(ref Alloc alloc, SyncOrAsync curFunAsync, scope ExprPos pos, JsStatement statement) =>
	pos.match!ExprResult(
		(ExprPos.Expression) =>
			ExprResult(genIife(alloc, statement.source, curFunAsync, genBlockStatement(alloc, [statement]))),
		(ExprPos.ExpressionOrBlockStatement) =>
			ExprResult(genBlockStatement(alloc, [statement])),
		(ref ExprPos.Statements x) {
			add(alloc, x.statements, statement);
			return ExprResult.done;
		});

JsExpr translateLocalGet(in Source source, in Local* local) =>
	genIdentifier(source, localName(*local));
JsExpr genOptionHas(ref Alloc alloc, in Source source, JsExpr option) =>
	// !!option.length
	genNotNot(alloc, source, genPropertyAccess(alloc, source, option, JsMemberName.noPrefix(symbol!"length")));
JsExpr genOptionForce(ref Alloc alloc, in Source source, JsExpr option) =>
	// option[0]
	genPropertyAccessComputed(alloc, source, option, genNumber(source, 0));
JsExpr genOptionSome(ref Alloc alloc, in Source source, JsExpr arg) =>
	// [option]
	genArray(alloc, source, [arg]);
JsExpr genOptionNone(in Source source) =>
	genArray(source, []);

JsExpr translateEnumValue(ref TranslateModuleCtx ctx, in Source source, in EnumOrFlagsMember a) =>
	genPropertyAccess(
		ctx.alloc, source,
		translateStructReference(ctx, source, a.containingEnum),
		JsMemberName.enumMember(a.name));

ExprResult withTemp(
	ref TranslateExprCtx ctx,
	Symbol name,
	JsExpr value,
	scope ExprPos pos,
	in ExprResult delegate(JsName temp, scope ExprPos inner) @safe @nogc pure nothrow cb,
) =>
	forceStatements(ctx, value.source, pos, (scope ref ArrayBuilder!JsStatement out_, scope ExprPos inner) {
		JsName jsName = tempName(ctx, name);
		add(ctx.alloc, out_, genConst(ctx.alloc, value.source, jsName, value));
		return cb(jsName, inner);
	});

JsExpr makeCall(ref TranslateExprCtx ctx, in Source source, Called called, in JsExpr[] args) =>
	isInlined(called)
		? translateToExpr((scope ExprPos pos) =>
			translateInlineCall(
				ctx,
				source,
				called.returnType,
				pos,
				called.as!(FunInst*).decl,
				called.paramTypes,
				args.length,
				(size_t i) => args[i]))
		: makeCallNoInline(ctx, source, called, (scope ref Builder!JsExpr out_) { out_ ~= args; });
JsExpr makeCallNoInlineWithSpread(
	ref TranslateModuleCtx ctx,
	in Source source,
	SyncOrAsync await,
	in FunOrTest caller,
	in Called called,
	in void delegate(scope ref Builder!JsExpr) @safe @nogc pure nothrow cbArgs,
	JsExpr spreadArg,
) =>
	genCallWithSpread(
		ctx.alloc,
		source,
		await,
		translateFunOrSpecReference(ctx, source, caller, called),
		withSpecImpls(ctx, source, caller, called, cbArgs),
		spreadArg);
JsExpr makeCallNoInline(
	ref TranslateExprCtx ctx,
	in Source source,
	Called called,
	in void delegate(scope ref Builder!JsExpr) @safe @nogc pure nothrow cbArgs,
) =>
	genCall(
		ctx.alloc,
		source,
		isAsyncCall(ctx, called),
		allocate(ctx.alloc, translateFunOrSpecReference(ctx, source, called)),
		withSpecImpls(ctx, source, called, cbArgs));

private JsExpr[] withSpecImpls(
	ref TranslateExprCtx ctx,
	in Source source,
	in Called a,
	in void delegate(scope ref Builder!JsExpr) @safe @nogc pure nothrow cb,
) =>
	withSpecImpls(ctx.ctx, source, ctx.curFun, a, cb);
private JsExpr[] withSpecImpls(ref TranslateExprCtx ctx, in Source source, in Called a, in JsExpr[] args) =>
	withSpecImpls(ctx.ctx, source, ctx.curFun, a, args);
private JsExpr[] withSpecImpls(
	ref TranslateModuleCtx ctx,
	in Source source,
	in FunOrTest caller,
	in Called called,
	in JsExpr[] args,
) =>
	withSpecImpls(ctx, source, caller, called, (scope ref Builder!JsExpr out_) {
		out_ ~= args;
	});
private JsExpr[] withSpecImpls(
	ref TranslateModuleCtx ctx,
	in Source source,
	in FunOrTest caller,
	in Called called,
	in void delegate(scope ref Builder!JsExpr) @safe @nogc pure nothrow cb,
) =>
	buildArray!JsExpr(ctx.alloc, (scope ref Builder!JsExpr out_) {
		writeSpecArgs(out_, ctx, source, caller, called);
		cb(out_);
	});

private void writeSpecArgs(
	scope ref Builder!JsExpr out_,
	ref TranslateModuleCtx ctx,
	in Source source,
	in FunOrTest caller,
	in Called called,
) {
	called.match!void(
		(ref Called.Bogus x) {},
		(ref FunInst x) {
			foreach (ref Called impl; x.specImpls)
				out_ ~= translateFunToExpr(ctx, source, caller, impl);
		},
		(CalledSpecSig x) {});
}

// Just translates the function name -- does not include spec impls
private JsExpr translateFunOrSpecReference(ref TranslateExprCtx ctx, in Source source, in Called called) =>
	translateFunOrSpecReference(ctx.ctx, source, ctx.curFun, called);
private JsExpr translateFunOrSpecReference(
	ref TranslateModuleCtx ctx,
	in Source source,
	in FunOrTest caller,
	in Called called,
) =>
	called.match!JsExpr(
		(ref Called.Bogus x) =>
			genThrowBogusExpr(ctx.alloc, source),
		(ref FunInst x) =>
			translateFunReference(ctx, source, x.decl),
		(CalledSpecSig x) =>
			genIdentifier(source, JsName(
				JsName.Kind.specSig,
				x.nonInstantiatedSig.name,
				some(safeToUshort(findSigIndex(*caller.as!(FunDecl*), x))))));

// This partially applies any spec impls
JsExpr translateFunToExpr(ref TranslateExprCtx ctx, in Source source, in Called a) =>
	translateFunToExpr(ctx.ctx, source, ctx.curFun, a);
JsExpr translateFunToExpr(ref TranslateModuleCtx ctx, in Source source, in FunOrTest caller, in Called a) {
	JsExpr f = translateFunOrSpecReference(ctx, source, caller, a);
	JsExpr[] specImpls = withSpecImpls(ctx, source, caller, a, []);
	if (isEmpty(specImpls))
		return f;
	else {
		// (...args) => f(spec_impl, ...args)
		JsName args = JsName.specialLocal(symbol!"args");
		// 'f' can be async, but there's no point in making an async function that does nothing but await it
		return genArrowFunction(
			source,
			SyncOrAsync.sync,
			JsParams(emptySmallArray!JsDestructure, some(JsDestructure(args))),
			exprFunBody(ctx.alloc, genCallWithSpread(
				ctx.alloc, source, SyncOrAsync.sync, f, specImpls, genIdentifier(source, args))));
	}
}

private size_t findSigIndex(in FunDecl curFun, in CalledSpecSig called) {
	size_t res = 0;
	bool foundIt = eachSpecInFunIncludingParents(curFun, (SpecInst* spec) {
		if (spec == called.specInst) {
			res += called.sigIndex;
			return true;
		} else {
			res += spec.sigTypes.length;
			return false;
		}
	});
	assert(foundIt);
	return res;
}

ExprResult translateInlineCall(
	ref TranslateExprCtx ctx,
	in Source source,
	Type returnType,
	scope ExprPos pos,
	in FunDecl* called,
	in Type[] paramTypes,
	size_t nArgs,
	in JsExpr delegate(size_t) @safe @nogc pure nothrow getArg,
) {
	StructDecl* returnStruct() =>
		returnType.as!(StructInst*).decl;
	ExprResult expr(JsExpr value) =>
		forceExpr(ctx.alloc, pos, returnType, value);
	JsExpr onlyArg() {
		assert(nArgs == 1);
		return getArg(0);
	}
	JsExpr[] args(size_t skip = 0) {
		assert(nArgs >= skip);
		return makeArray(ctx.alloc, nArgs - skip, (size_t i) => getArg(i + skip));
	}
	JsExpr createRecord(StructDecl* record) =>
		genNew(ctx.alloc, source, translateStructReference(ctx, source, record), args());
	JsExpr returnTypeRef() =>
		translateStructReference(ctx, source, returnStruct);
	JsExpr recordField(RecordField* field) =>
		genPropertyAccess(ctx.alloc, source, getArg(0), JsMemberName.recordField(field.name));
	return called.body_.matchIn!ExprResult(
		(in FunBody.Bogus) =>
			translateToBogus(ctx.alloc, source, pos),
		(in AutoFun x) =>
			assert(false),
		(in BuiltinFun x) =>
			translateCallBuiltin(ctx, source, returnType, pos, x, nArgs, getArg),
		(in FunBody.CreateEnumOrFlags x) =>
			expr(genPropertyAccess(ctx.alloc, source, returnTypeRef, JsMemberName.enumMember(x.member.name))),
		(in FunBody.CreateExtern) =>
			assert(false),
		(in FunBody.CreateRecord) =>
			expr(createRecord(returnStruct)),
		(in FunBody.CreateRecordAndConvertToSumType x) =>
			expr(createSumType(ctx, source, returnStruct, createRecord(x.member.decl), x.member.decl.name)),
		(in FunBody.CreateSumType x) =>
			expr(createSumType(ctx, source, returnStruct, onlyArg(), only(paramTypes).as!(StructInst*).decl.name)),
		(in Expr _) =>
			assert(false),
		(in FunBody.Extern) =>
			assert(false),
		(in FunBody.FileImport) =>
			assert(false),
		(in FlagsFunction x) =>
			expr(translateFlagsFunction(ctx, source, returnType, paramTypes, x, nArgs, getArg)),
		(in FunBody.Method x) =>
			expr(genCall(
				ctx.alloc,
				source,
				isAsyncFun(ctx.ctx.allUsed, called),
				allocate(ctx.alloc, genPropertyAccess(
					ctx.alloc, source, getArg(0), JsMemberName.variantMethod(x.method.name))),
				args(skip: 1))),
		(in FunBody.RecordFieldCall x) {
			assert(nArgs >= 1);
			return expr(genCallAwait(
				ctx.alloc,
				source,
				allocate(ctx.alloc, recordField(x.field)),
				x.funKind == FunKind.function_
					? args(skip: 1)
					: newArray(ctx.alloc, [genTuple(ctx, source, nArgs - 1, (size_t i) => getArg(i + 1))])));
		},
		(in FunBody.RecordFieldGet x) =>
			expr(recordField(x.field)),
		(in FunBody.RecordFieldPointer) =>
			assert(false),
		(in FunBody.RecordFieldSet x) {
			assert(nArgs == 2);
			return forceStatement(ctx, pos, genAssign(ctx.alloc, source, recordField(x.field), getArg(1)));
		},
		(in FunBody.SumTypeMemberGet) {
			assert(!bodyIsInlined(*called));
			JsExpr arg = onlyArg();
			StructInst* member = mustUnwrapOptionType(returnType).as!(StructInst*);
			StructDecl* variant = only(paramTypes).as!(StructInst*).decl;
			return variant.body_.as!(StructBody.SumType).kind == SumTypeKind.union_
				? expr(genTernary(
					ctx.alloc,
					source,
					genIsUnionMember(ctx.alloc, source, arg, member),
					genOptionSome(ctx.alloc, source, genForceUnionMember(ctx.alloc, source, arg, member)),
					genOptionNone(source)))
				// x instanceof Foo ? Option.some(x) : Option.none
				: expr(genTernary(
					ctx.alloc,
					source,
					genInstanceof(ctx.alloc, source, arg, translateStructReference(ctx, source, member.decl)),
					genOptionSome(ctx.alloc, source, arg),
					genOptionNone(source)));
		},
		(in FunBody.VarGet x) =>
			expr(translateVarReference(ctx.ctx, source, x.var)),
		(in FunBody.VarSet x) =>
			forceStatement(
				ctx, pos,
				genAssign(ctx.alloc, source, translateVarReference(ctx.ctx, source, x.var), onlyArg())));
}

private JsExpr createSumType(ref TranslateExprCtx ctx, in Source source, StructDecl* variant, JsExpr arg, Symbol memberName) {
	if (variant.body_.as!(StructBody.SumType).kind == SumTypeKind.union_) {
		JsExpr member = genPropertyAccess(
			ctx.alloc, source, translateStructReference(ctx, source, variant),
			JsMemberName.unionConstructor(memberName));
		return genCallSync(ctx.alloc, source, member, [arg]);
	} else
		return arg;
}

private ExprResult translateCallBuiltin(
	ref TranslateExprCtx ctx,
	in Source source,
	Type returnType,
	scope ExprPos pos,
	in BuiltinFun a,
	size_t nArgs,
	in JsExpr delegate(size_t) @safe @nogc pure nothrow getArg,
) {
	ExprResult expr(JsExpr value) =>
		forceExpr(ctx.alloc, pos, returnType, value);
	return a.matchIn!ExprResult(
		(in BuiltinFun.AllTests) {
			assert(nArgs == 0);
			return expr(translateAllTests(ctx.ctx, source));
		},
		(in BuiltinUnary x) {
			assert(nArgs == 1);
			return expr(translateBuiltinUnary(ctx.alloc, source, x, getArg(0)));
		},
		(in BuiltinUnaryMath x) {
			assert(nArgs == 1);
			return expr(translateBuiltinUnaryMath(ctx.alloc, source, x, getArg(0)));
		},
		(in BuiltinBinary x) {
			assert(nArgs == 2);
			return translateBuiltinBinary(ctx, source, returnType, pos, x, getArg(0), getArg(1));
		},
		(in BuiltinBinaryLazy x) {
			assert(nArgs == 2);
			return translateBuiltinBinaryLazy(ctx, source, returnType, pos, x, getArg(0), getArg(1));
		},
		(in BuiltinBinaryMath x) {
			assert(nArgs == 2);
			return expr(translateBuiltinBinaryMath(ctx, source, x, getArg(0), getArg(1)));
		},
		(in BuiltinTernary x) =>
			assert(false),
		(in Builtin4ary x) =>
			assert(false),
		(in BuiltinFun.CallLambda) =>
			expr(genCallAwait(ctx.alloc, source, getArg(0), [
				genTuple(ctx, source, nArgs - 1, (size_t i) => getArg(i + 1))])),
		(in BuiltinFun.CallFunPointer) =>
			expr(genCallAwait(
				ctx.alloc,
				source,
				allocate(ctx.alloc, getArg(0)),
				makeArray(ctx.alloc, nArgs - 1, (size_t i) => getArg(i + 1)))),
		(in Constant x) {
			assert(nArgs == 0);
			return expr(translateConstant(ctx.ctx, source, x, returnType));
		},
		(in BuiltinFun.GcSafeValue) {
			assert(nArgs == 0);
			return expr(genNull(source));
		},
		(in BuiltinFun.Init) =>
			assert(false),
		(in JsFun x) =>
			translateCallJsFun(ctx.ctx, source, returnType, pos, x, nArgs, getArg),
		(in BuiltinFun.MarkRoot) =>
			assert(false),
		(in BuiltinFun.MarkVisit) =>
			assert(false),
		(in BuiltinFun.NewEmptyOption) {
			assert(nArgs == 0);
			return expr(genOptionNone(source));
		},
		(in BuiltinFun.NewNonEmptyOption) {
			assert(nArgs == 1);
			return expr(genOptionSome(ctx.alloc, source, getArg(0)));
		},
		(in BuiltinFun.PointerCast) =>
			assert(false),
		(in BuiltinFun.SizeOf) =>
			assert(false),
		(in BuiltinFun.StaticSymbols) =>
			assert(false),
		(in VersionFun x) {
			assert(nArgs == 0);
			return expr(genBool(source, isVersion(ctx.ctx.version_, x)));
		});
}

JsExpr translateConstant(ref TranslateModuleCtx ctx, in Source source, in Constant value, in Type type) {
	if (type.isA!TypeParamIndex) {
		assert(value.isA!(Constant.Zero));
		return genNull(source);
	} else {
		switch (type.as!(StructInst*).decl.body_.as!BuiltinType) {
			case BuiltinType.bool_:
				return genBool(source, asBool(value));
			case BuiltinType.float32:
				return toFloat32(ctx.alloc, source, genNumber(source, value.as!(Constant.Float).value));
			case BuiltinType.float64:
				return genNumber(source, value.as!(Constant.Float).value);
			case BuiltinType.int8:
			case BuiltinType.int16:
			case BuiltinType.int32:
			case BuiltinType.int64:
				return genIntegerSigned(source, asInt64(value));
			case BuiltinType.char8:
			case BuiltinType.char32:
			case BuiltinType.nat8:
			case BuiltinType.nat16:
			case BuiltinType.nat32:
			case BuiltinType.nat64:
				return genIntegerUnsigned(source, asNat64(value));
			case BuiltinType.void_:
				return genUndefined(ctx.alloc, source);
			default:
				assert(false);
		}
	}
}

private JsExpr genTuple(
	ref TranslateExprCtx ctx,
	in Source source,
	size_t nArgs,
	in JsExpr delegate(size_t) @safe @nogc pure nothrow cbArg,
) {
	switch (nArgs) {
		case 0:
			return genNull(source);
		case 1:
			return cbArg(0);
		default:
			return genNew(
				ctx.alloc,
				source,
				translateStructReference(ctx, source, force(ctx.commonTypes.tuple(nArgs))),
				makeArray(ctx.alloc, nArgs, cbArg));
	}
}

private JsExpr translateFlagsFunction(
	ref TranslateExprCtx ctx,
	in Source source,
	Type returnType,
	in Type[] paramTypes,
	FlagsFunction a,
	size_t nArgs,
	in JsExpr delegate(size_t) @safe @nogc pure nothrow getArg,
) {
	JsExpr call(Symbol name) {
		assert(nArgs == 1 || nArgs == 2);
		return nArgs == 1
			? genCallPropertySync(ctx.alloc, source, getArg(0), JsMemberName.special(name), [])
			: genCallPropertySync(ctx.alloc, source, getArg(0), JsMemberName.special(name), [getArg(1)]);
	}
	JsExpr staticProperty(Type enumOrFlags, Symbol name) =>
		genPropertyAccess(
			ctx.alloc,
			source,
			translateStructReference(ctx, source, enumOrFlags.as!(StructInst*).decl),
			JsMemberName.special(name));
	final switch (a) {
		case FlagsFunction.in_:
			return call(symbol!"in");
		case FlagsFunction.intersect:
			return call(symbol!"intersect");
		case FlagsFunction.negate:
			return call(symbol!"negate");
		case FlagsFunction.none:
			return staticProperty(returnType, symbol!"none");
		case FlagsFunction.union_:
			return call(symbol!"union");
	}
}

private JsExpr translateAllTests(ref TranslateModuleCtx ctx, in Source source) =>
	genArray(source, buildArray!JsExpr(ctx.alloc, (scope ref Builder!JsExpr out_) {
		eachTest(ctx.program, ctx.allExterns, ctx.ctx.programWithMainPtr.testSelector, (Test* test) {
			out_ ~= translateTestReference(ctx, source, test);
		});
	}));

private JsExpr translateBuiltinUnary(ref Alloc alloc, in Source source, BuiltinUnary a, JsExpr arg) {
	JsExpr Array = genGlobal(source, symbol!"Array");
	JsExpr BigInt = genGlobal(source, symbol!"BigInt");
	JsExpr Number = genGlobal(source, symbol!"Number");
	JsExpr bitwiseNot() => genBitwiseNot(alloc, source, arg);

	final switch (a) {
		case BuiltinUnary.asFuture:
		case BuiltinUnary.asFutureImpl:
		case BuiltinUnary.asMutArray:
		case BuiltinUnary.asMutArrayImpl:
		case BuiltinUnary.arrayPointer:
		case BuiltinUnary.asAnyPointer:
		case BuiltinUnary.cStringOfSymbol:
		case BuiltinUnary.deref:
		case BuiltinUnary.drop:
		case BuiltinUnary.jumpToCatch:
		case BuiltinUnary.referenceFromPointer:
		case BuiltinUnary.setupCatch:
		case BuiltinUnary.symbolOfCString:
		case BuiltinUnary.toNat64FromPtr:
		case BuiltinUnary.toPtrFromNat64:
			// These are 'native extern'
			assert(false);
		case BuiltinUnary.arraySize:
			return genCallSync(
				alloc, source, BigInt,
				[genPropertyAccess(alloc, source, arg, JsMemberName.noPrefix(symbol!"length"))]);
		case BuiltinUnary.bitsOfFloat32:
			return genCallSync(alloc, source, BigInt, [
				genConvert(alloc, source, 4, symbol!"Float32Array", symbol!"Uint32Array", arg)]);
		case BuiltinUnary.bitsOfFloat64:
			return genConvert(alloc, source, 8, symbol!"Float64Array", symbol!"BigInt64Array", arg);
		case BuiltinUnary.bitwiseNotNat8:
			return genAsNat8(alloc, source, bitwiseNot());
		case BuiltinUnary.bitwiseNotNat16:
			return genAsNat16(alloc, source, bitwiseNot());
		case BuiltinUnary.bitwiseNotNat32:
			return genAsNat32(alloc, source, bitwiseNot());
		case BuiltinUnary.bitwiseNotNat64:
			return genAsNat64(alloc, source, bitwiseNot());
		case BuiltinUnary.countOnesNat64:
			// Array.from(n.toString(2))
			JsExpr digits = genCallPropertySync(alloc, source, Array, JsMemberName.noPrefix(symbol!"from"), [
				genCallPropertySync(
					alloc, source, arg,
					JsMemberName.noPrefix(symbol!"toString"),
					[genNumber(source, 2)])]);
			JsName x = JsName.specialLocal(symbol!"x");
			// x => x === "1"
			JsExpr fn = genArrowFunction(
				alloc, source, SyncOrAsync.sync, [JsDestructure(x)],
				genEqEqEq(alloc, source, genIdentifier(source, x), genString(source, "1")));
			// BigInt(Array.from(n.toString(2)).filter(x => x === "1").length)
			return genCallSync(alloc, source, BigInt, [
				genPropertyAccess(
					alloc,
					source,
					genCallPropertySync(alloc, source, digits, JsMemberName.noPrefix(symbol!"filter"), [fn]),
					JsMemberName.noPrefix(symbol!"length"))]);
		case BuiltinUnary.float32FromBits:
			return genConvert(
				alloc, source, 4, symbol!"Uint32Array", symbol!"Float32Array",
				genCallSync(alloc, source, Number, [arg]));
		case BuiltinUnary.float64FromBits:
			return genConvert(alloc, source, 8, symbol!"BigInt64Array", symbol!"Float64Array", arg);
		case BuiltinUnary.isNanFloat32:
		case BuiltinUnary.isNanFloat64:
			return genCallPropertySync(alloc, source, Number, JsMemberName.noPrefix(symbol!"isNaN"), [arg]);
		case BuiltinUnary.not:
			return genNot(alloc, source, arg);
		case BuiltinUnary.toChar8FromNat8:
		case BuiltinUnary.toInt64FromInt8:
		case BuiltinUnary.toInt64FromInt16:
		case BuiltinUnary.toInt64FromInt32:
		case BuiltinUnary.toNat8FromChar8:
		case BuiltinUnary.toNat32FromChar32:
		case BuiltinUnary.toNat64FromNat8:
		case BuiltinUnary.toNat64FromNat16:
		case BuiltinUnary.toNat64FromNat32:
		case BuiltinUnary.unsafeToChar32FromChar8:
		case BuiltinUnary.unsafeToChar32FromNat32:
		case BuiltinUnary.unsafeToNat32FromInt32:
		case BuiltinUnary.unsafeToInt8FromInt64:
		case BuiltinUnary.unsafeToInt16FromInt64:
		case BuiltinUnary.unsafeToInt32FromInt64:
		case BuiltinUnary.unsafeToNat64FromInt64:
		case BuiltinUnary.unsafeToInt64FromNat64:
		case BuiltinUnary.unsafeToNat8FromNat64:
		case BuiltinUnary.unsafeToNat16FromNat64:
		case BuiltinUnary.unsafeToNat32FromNat64:
		case BuiltinUnary.toFloat32FromFloat64:
		case BuiltinUnary.toFloat64FromFloat32:
			// These are all conversions between types that are represented the same in JS
			return arg;
		case BuiltinUnary.toFloat64FromInt64:
		case BuiltinUnary.toFloat64FromNat64:
			return genCallSync(alloc, source, Number, [arg]);
		case BuiltinUnary.toChar8ArrayFromString:
			// Array.from(new TextEncoder().encode(arg)).map(BigInt)
			return genCallPropertySync(
				alloc,
				source,
				genArrayFrom(
					alloc,
					source,
					genCallPropertySync(
						alloc,
						source,
						genNew(alloc, source, genGlobal(source, symbol!"TextEncoder"), []),
						JsMemberName.noPrefix(symbol!"encode"),
						[arg])),
				JsMemberName.noPrefix(symbol!"map"),
				[BigInt]);
		case BuiltinUnary.truncateToInt64FromFloat64:
			return genCallSync(alloc, source, BigInt, [callMath(alloc, source, symbol!"trunc", [arg])]);
		case BuiltinUnary.trustAsString:
			// new TextDecoder().decode(new Uint8Array(arg.map(Number)))
			return genCallPropertySync(
				alloc,
				source,
				genNew(alloc, source, genGlobal(source, symbol!"TextDecoder"), []),
				JsMemberName.noPrefix(symbol!"decode"),
				[
					genNew(alloc, source, genGlobal(source, symbol!"Uint8Array"), [
						genCallPropertySync(alloc, source, arg, JsMemberName.noPrefix(symbol!"map"), [Number])])]);
	}
}
private JsExpr genArrayFrom(ref Alloc alloc, in Source source, JsExpr arg) =>
	genCallPropertySync(alloc, source, genGlobal(source, symbol!"Array"), JsMemberName.noPrefix(symbol!"from"), [arg]);
private JsExpr genConvert(
	ref Alloc alloc,
	in Source source,
	double size,
	Symbol inputArrayType,
	Symbol outputArrayType,
	JsExpr arg,
) {
	JsName bufName = JsName.specialLocal(symbol!"buf");
	return genIife(alloc, source, SyncOrAsync.sync, genBlockStatement(alloc, [
		genConst(
			alloc, source, bufName,
			genNew(alloc, source, genGlobal(source, symbol!"ArrayBuffer"), [genNumber(source, size)])),
		genAssign(
			alloc, source,
			genSubscriptZero(
				alloc, source,
				genNew(alloc, source, genGlobal(source, inputArrayType), [genIdentifier(source, bufName)])),
			arg),
		genReturn(alloc, source, genSubscriptZero(
			alloc, source,
			genNew(alloc, source, genGlobal(source, outputArrayType), [genIdentifier(source, bufName)]))),
	]));
}
private JsExpr genSubscriptZero(ref Alloc alloc, in Source source, JsExpr arg) =>
	genPropertyAccessComputed(alloc, source, arg, genNumber(source, 0));

private JsExpr translateBuiltinUnaryMath(ref Alloc alloc, in Source source, BuiltinUnaryMath a, JsExpr arg) {
	JsExpr f32(Symbol name) =>
		toFloat32(alloc, source, callMath(alloc, source, name, [arg]));
	JsExpr f64(Symbol name) =>
		callMath(alloc, source, name, [arg]);
	JsExpr round() =>
		// JS round gives wrong results for negative numbers, so fix by only rounding positive
		// Math.sign(arg) * Math.round(Math.abs(arg))
		genTimes(
			alloc,
			source,
			callMath(alloc, source, symbol!"sign", [arg]),
			callMath(alloc, source, symbol!"round", [callMath(alloc, source, symbol!"abs", [arg])]));

	final switch (a) {
		case BuiltinUnaryMath.acosFloat32:
			return f32(symbol!"acos");
		case BuiltinUnaryMath.acoshFloat32:
			return f32(symbol!"acosh");
		case BuiltinUnaryMath.asinFloat32:
			return f32(symbol!"asin");
		case BuiltinUnaryMath.asinhFloat32:
			return f32(symbol!"asinh");
		case BuiltinUnaryMath.atanFloat32:
			return f32(symbol!"atan");
		case BuiltinUnaryMath.atanhFloat32:
			return f32(symbol!"atanh");
		case BuiltinUnaryMath.cosFloat32:
			return f32(symbol!"cos");
		case BuiltinUnaryMath.coshFloat32:
			return f32(symbol!"cosh");
		case BuiltinUnaryMath.roundDownFloat32:
			return f32(symbol!"floor");
		case BuiltinUnaryMath.roundFloat32:
			return toFloat32(alloc, source, round());
		case BuiltinUnaryMath.roundUpFloat32:
			return f32(symbol!"ceil");
		case BuiltinUnaryMath.sinFloat32:
			return f32(symbol!"sin");
		case BuiltinUnaryMath.sinhFloat32:
			return f32(symbol!"sinh");
		case BuiltinUnaryMath.sqrtFloat32:
			return f32(symbol!"sqrt");
		case BuiltinUnaryMath.tanFloat32:
			return f32(symbol!"tan");
		case BuiltinUnaryMath.tanhFloat32:
			return f32(symbol!"tanh");
		case BuiltinUnaryMath.unsafeLogFloat32:
			return f32(symbol!"log");

		case BuiltinUnaryMath.acosFloat64:
			return f64(symbol!"acos");
		case BuiltinUnaryMath.acoshFloat64:
			return f64(symbol!"acosh");
		case BuiltinUnaryMath.asinFloat64:
			return f64(symbol!"asin");
		case BuiltinUnaryMath.asinhFloat64:
			return f64(symbol!"asinh");
		case BuiltinUnaryMath.atanFloat64:
			return f64(symbol!"atan");
		case BuiltinUnaryMath.atanhFloat64:
			return f64(symbol!"atanh");
		case BuiltinUnaryMath.cosFloat64:
			return f64(symbol!"cos");
		case BuiltinUnaryMath.coshFloat64:
			return f64(symbol!"cosh");
		case BuiltinUnaryMath.roundDownFloat64:
			return f64(symbol!"floor");
		case BuiltinUnaryMath.roundFloat64:
			return round();
		case BuiltinUnaryMath.roundUpFloat64:
			return f64(symbol!"ceil");
		case BuiltinUnaryMath.sinFloat64:
			return f64(symbol!"sin");
		case BuiltinUnaryMath.sinhFloat64:
			return f64(symbol!"sinh");
		case BuiltinUnaryMath.sqrtFloat64:
			return f64(symbol!"sqrt");
		case BuiltinUnaryMath.tanFloat64:
			return f64(symbol!"tan");
		case BuiltinUnaryMath.tanhFloat64:
			return f64(symbol!"tanh");
		case BuiltinUnaryMath.unsafeLogFloat64:
			return f64(symbol!"log");
	}
}
private JsExpr callMath(ref Alloc alloc, in Source source, Symbol name, in JsExpr[] args) =>
	genCallPropertySync(alloc, source, genGlobal(source, symbol!"Math"), JsMemberName.noPrefix(name), args);
private JsExpr toFloat32(ref Alloc alloc, in Source source, JsExpr arg) =>
	callMath(alloc, source, symbol!"fround", [arg]);

private JsExpr genAsNat(ref Alloc alloc, in Source source, uint bits, JsExpr arg) =>
	genCallPropertySync(
		alloc,
		source,
		genGlobal(source, symbol!"BigInt"),
		JsMemberName.noPrefix(symbol!"asUintN"),
		[genNumber(source, bits), arg]);
private JsExpr genAsNat8(ref Alloc alloc, in Source source, JsExpr arg) =>
	genAsNat(alloc, source, 8, arg);
private JsExpr genAsNat16(ref Alloc alloc, in Source source, JsExpr arg) =>
	genAsNat(alloc, source, 16, arg);
private JsExpr genAsNat32(ref Alloc alloc, in Source source, JsExpr arg) =>
	genAsNat(alloc, source, 32, arg);
private JsExpr genAsNat64(ref Alloc alloc, in Source source, JsExpr arg) =>
	genAsNat(alloc, source, 64, arg);

private ExprResult translateBuiltinBinary(
	ref TranslateExprCtx ctx,
	in Source source,
	Type type,
	scope ExprPos pos,
	BuiltinBinary a,
	JsExpr left,
	JsExpr right,
) {
	ExprResult expr(JsExpr value) =>
		forceExpr(ctx.alloc, pos, type, value);
	JsExpr binary(JsBinaryExpr.Kind kind) =>
		genBinary(ctx.alloc, source, kind, left, right);
	JsExpr add() =>
		binary(JsBinaryExpr.Kind.plus);
	JsExpr sub() =>
		binary(JsBinaryExpr.Kind.minus);
	JsExpr mul() =>
		binary(JsBinaryExpr.Kind.times);
	JsExpr div() =>
		binary(JsBinaryExpr.Kind.divide);
	final switch (a) {
		case BuiltinBinary.addFloat32:
			return expr(toFloat32(ctx.alloc, source, add()));
		case BuiltinBinary.addFloat64:
		case BuiltinBinary.unsafeAddInt8:
		case BuiltinBinary.unsafeAddInt16:
		case BuiltinBinary.unsafeAddInt32:
		case BuiltinBinary.unsafeAddInt64:
		case BuiltinBinary.unsafeAddNat8:
		case BuiltinBinary.unsafeAddNat16:
		case BuiltinBinary.unsafeAddNat32:
		case BuiltinBinary.unsafeAddNat64:
			return expr(add());
		case BuiltinBinary.bitwiseAndInt8:
		case BuiltinBinary.bitwiseAndInt16:
		case BuiltinBinary.bitwiseAndInt32:
		case BuiltinBinary.bitwiseAndInt64:
		case BuiltinBinary.bitwiseAndNat8:
		case BuiltinBinary.bitwiseAndNat16:
		case BuiltinBinary.bitwiseAndNat32:
		case BuiltinBinary.bitwiseAndNat64:
			return expr(binary(JsBinaryExpr.Kind.bitwiseAnd));
		case BuiltinBinary.bitwiseOrInt8:
		case BuiltinBinary.bitwiseOrInt16:
		case BuiltinBinary.bitwiseOrInt32:
		case BuiltinBinary.bitwiseOrInt64:
		case BuiltinBinary.bitwiseOrNat8:
		case BuiltinBinary.bitwiseOrNat16:
		case BuiltinBinary.bitwiseOrNat32:
		case BuiltinBinary.bitwiseOrNat64:
			return expr(binary(JsBinaryExpr.Kind.bitwiseOr));
		case BuiltinBinary.bitwiseXorInt8:
		case BuiltinBinary.bitwiseXorInt16:
		case BuiltinBinary.bitwiseXorInt32:
		case BuiltinBinary.bitwiseXorInt64:
		case BuiltinBinary.bitwiseXorNat8:
		case BuiltinBinary.bitwiseXorNat16:
		case BuiltinBinary.bitwiseXorNat32:
		case BuiltinBinary.bitwiseXorNat64:
			return expr(binary(JsBinaryExpr.Kind.bitwiseXor));
		case BuiltinBinary.equalChar8:
		case BuiltinBinary.equalChar32:
		case BuiltinBinary.equalFloat32:
		case BuiltinBinary.equalFloat64:
		case BuiltinBinary.equalInt8:
		case BuiltinBinary.equalInt16:
		case BuiltinBinary.equalInt32:
		case BuiltinBinary.equalInt64:
		case BuiltinBinary.equalNat8:
		case BuiltinBinary.equalNat16:
		case BuiltinBinary.equalNat32:
		case BuiltinBinary.equalNat64:
		case BuiltinBinary.referenceEqual:
			return expr(binary(JsBinaryExpr.Kind.eqEqEq));
		case BuiltinBinary.lessChar8:
		case BuiltinBinary.lessFloat32:
		case BuiltinBinary.lessFloat64:
		case BuiltinBinary.lessInt8:
		case BuiltinBinary.lessInt16:
		case BuiltinBinary.lessInt32:
		case BuiltinBinary.lessInt64:
		case BuiltinBinary.lessNat8:
		case BuiltinBinary.lessNat16:
		case BuiltinBinary.lessNat32:
		case BuiltinBinary.lessNat64:
			return expr(binary(JsBinaryExpr.Kind.less));
		case BuiltinBinary.mulFloat32:
			return expr(toFloat32(ctx.alloc, source, mul()));
		case BuiltinBinary.mulFloat64:
		case BuiltinBinary.unsafeMulInt8:
		case BuiltinBinary.unsafeMulInt16:
		case BuiltinBinary.unsafeMulInt32:
		case BuiltinBinary.unsafeMulInt64:
		case BuiltinBinary.unsafeMulNat8:
		case BuiltinBinary.unsafeMulNat16:
		case BuiltinBinary.unsafeMulNat32:
		case BuiltinBinary.unsafeMulNat64:
			return expr(mul());
		case BuiltinBinary.subFloat32:
			return expr(toFloat32(ctx.alloc, source, sub()));
		case BuiltinBinary.subFloat64:
		case BuiltinBinary.unsafeSubInt8:
		case BuiltinBinary.unsafeSubInt16:
		case BuiltinBinary.unsafeSubInt32:
		case BuiltinBinary.unsafeSubInt64:
		case BuiltinBinary.unsafeSubNat8:
		case BuiltinBinary.unsafeSubNat16:
		case BuiltinBinary.unsafeSubNat32:
		case BuiltinBinary.unsafeSubNat64:
			return expr(sub());
		case BuiltinBinary.unsafeBitShiftLeftNat64:
			return expr(genAsNat64(ctx.alloc, source, binary(JsBinaryExpr.Kind.bitShiftLeft)));
		case BuiltinBinary.unsafeBitShiftRightNat64:
			return expr(genAsNat64(ctx.alloc, source, binary(JsBinaryExpr.Kind.bitShiftRight)));
		case BuiltinBinary.unsafeDivFloat32:
			return expr(toFloat32(ctx.alloc, source, div()));
		case BuiltinBinary.unsafeDivFloat64:
		case BuiltinBinary.unsafeDivInt8:
		case BuiltinBinary.unsafeDivInt16:
		case BuiltinBinary.unsafeDivInt32:
		case BuiltinBinary.unsafeDivInt64:
		case BuiltinBinary.unsafeDivNat8:
		case BuiltinBinary.unsafeDivNat16:
		case BuiltinBinary.unsafeDivNat32:
		case BuiltinBinary.unsafeDivNat64:
			return expr(div());
		case BuiltinBinary.unsafeModNat64:
			return expr(binary(JsBinaryExpr.Kind.modulo));
		case BuiltinBinary.wrapAddNat8:
			return expr(genAsNat8(ctx.alloc, source, add()));
		case BuiltinBinary.wrapAddNat16:
			return expr(genAsNat16(ctx.alloc, source, add()));
		case BuiltinBinary.wrapAddNat32:
			return expr(genAsNat32(ctx.alloc, source, add()));
		case BuiltinBinary.wrapAddNat64:
			return expr(genAsNat64(ctx.alloc, source, add()));
		case BuiltinBinary.wrapMulNat8:
			return expr(genAsNat8(ctx.alloc, source, mul()));
		case BuiltinBinary.wrapMulNat16:
			return expr(genAsNat16(ctx.alloc, source, mul()));
		case BuiltinBinary.wrapMulNat32:
			return expr(genAsNat32(ctx.alloc, source, mul()));
		case BuiltinBinary.wrapMulNat64:
			return expr(genAsNat64(ctx.alloc, source, mul()));
		case BuiltinBinary.wrapSubNat8:
			return expr(genAsNat8(ctx.alloc, source, sub()));
		case BuiltinBinary.wrapSubNat16:
			return expr(genAsNat16(ctx.alloc, source, sub()));
		case BuiltinBinary.wrapSubNat32:
			return expr(genAsNat32(ctx.alloc, source, sub()));
		case BuiltinBinary.wrapSubNat64:
			return expr(genAsNat64(ctx.alloc, source, sub()));
		case BuiltinBinary.addPointerAndNat64:
		case BuiltinBinary.equalPointer:
		case BuiltinBinary.lessPointer:
		case BuiltinBinary.newArray:
		case BuiltinBinary.seq:
		case BuiltinBinary.subPointerAndNat64:
		case BuiltinBinary.switchFiber:
		case BuiltinBinary.writeToPointer:
			assert(false);
	}
}
private ExprResult translateBuiltinBinaryLazy(
	ref TranslateExprCtx ctx,
	in Source source,
	Type type,
	scope ExprPos pos,
	BuiltinBinaryLazy kind,
	JsExpr left,
	JsExpr right,
) {
	final switch (kind) {
		case BuiltinBinaryLazy.boolAnd:
			return forceExpr(ctx.alloc, pos, type, genAnd(ctx.alloc, source, left, right));
		case BuiltinBinaryLazy.boolOr:
			return forceExpr(ctx.alloc, pos, type, genOr(ctx.alloc, source, left, right));
		case BuiltinBinaryLazy.optionOr:
			// const option = x
			// return option.length ? option : right
			return withTemp(ctx, symbol!"option", left, pos, (JsName option, scope ExprPos inner) =>
				forceExpr(ctx.alloc, inner, type, genTernary(
					ctx.alloc,
					source,
					genOptionHas(ctx.alloc, source, genIdentifier(source, option)),
					genIdentifier(source, option),
					right)));
		case BuiltinBinaryLazy.optionQuestion2:
			// const option = left
			// return option.length ? option.some : right
			return withTemp(ctx, symbol!"option", left, pos, (JsName option, scope ExprPos inner) =>
				forceExpr(ctx.alloc, inner, type, genTernary(
					ctx.alloc,
					source,
					genOptionHas(ctx.alloc, source, genIdentifier(source, option)),
					genOptionForce(ctx.alloc, source, genIdentifier(source, option)),
					right)));
	}
}

private JsExpr translateBuiltinBinaryMath(
	ref TranslateExprCtx ctx,
	in Source source,
	BuiltinBinaryMath kind,
	JsExpr left,
	JsExpr right,
) {
	JsExpr atan2() =>
		callMath(ctx.alloc, source, symbol!"atan2", [left, right]);
	JsExpr mod() =>
		genBinary(ctx.alloc, source, JsBinaryExpr.Kind.modulo, left, right);
	JsExpr pow() =>
		callMath(ctx.alloc, source, symbol!"pow", [left, right]);
	final switch (kind) {
		case BuiltinBinaryMath.atan2Float32:
			return toFloat32(ctx.alloc, source, atan2());
		case BuiltinBinaryMath.atan2Float64:
			return atan2();
		case BuiltinBinaryMath.fmodFloat32:
			return toFloat32(ctx.alloc, source, mod());
		case BuiltinBinaryMath.fmodFloat64:
			return mod();
		case BuiltinBinaryMath.unsafePowFloat32:
			return toFloat32(ctx.alloc, source, pow());
		case BuiltinBinaryMath.unsafePowFloat64:
			return pow();
	}
}

private ExprResult translateCallJsFun(
	ref TranslateModuleCtx ctx,
	in Source source,
	Type returnType,
	scope ExprPos pos,
	JsFun fun,
	size_t nArgs,
	in JsExpr delegate(size_t) @safe @nogc pure nothrow getArg,
) {
	ExprResult expr(JsExpr value) =>
		forceExpr(ctx.alloc, pos, returnType, value);
	ExprResult unary(JsUnaryExpr.Kind kind) {
		assert(nArgs == 1);
		return expr(genUnary(ctx.alloc, source, kind, getArg(0)));
	}
	ExprResult binary(JsBinaryExpr.Kind kind) {
		assert(nArgs == 2);
		return expr(genBinary(ctx.alloc, source, kind, getArg(0), getArg(1)));
	}
	final switch (fun) {
		case JsFun.asJsAny:
		case JsFun.cast_:
			assert(nArgs == 1);
			return expr(getArg(0));
		case JsFun.await:
			assert(nArgs == 1);
			return expr(genAwait(ctx.alloc, source, getArg(0)));
		case JsFun.call:
			return expr(genCallSync(
				source,
				allocate(ctx.alloc, getArg(0)),
				makeArray(ctx.alloc, nArgs - 1, (size_t i) => getArg(i + 1))));
		case JsFun.callNew:
			return expr(genNew(
				source,
				allocate(ctx.alloc, getArg(0)),
				makeArray(ctx.alloc, nArgs - 1, (size_t i) => getArg(i + 1))));
		case JsFun.callProperty:
			assert(nArgs >= 2);
			return expr(genCallSync(
				source,
				allocate(ctx.alloc, genPropertyAccessComputed(ctx.alloc, source, getArg(0), getArg(1))),
				makeArray(ctx.alloc, nArgs - 2, (size_t i) => getArg(i + 2))));
		case JsFun.callPropertySpread:
			assert(nArgs == 3);
			return expr(genCallWithSpread(
				ctx.alloc,
				source,
				SyncOrAsync.sync,
				genPropertyAccessComputed(ctx.alloc, source, getArg(0), getArg(1)),
				[],
				getArg(2)));
		case JsFun.eqEqEq:
			return binary(JsBinaryExpr.Kind.eqEqEq);
		case JsFun.get:
			assert(nArgs == 2);
			return expr(genPropertyAccessComputed(ctx.alloc, source, getArg(0), getArg(1)));
		case JsFun.instanceof:
			return binary(JsBinaryExpr.Kind.instanceof);
		case JsFun.jsGlobal:
			assert(nArgs == 0);
			return expr(genGlobal(source, ctx.isBrowser ? symbol!"window" : symbol!"global"));
		case JsFun.less:
			return binary(JsBinaryExpr.Kind.less);
		case JsFun.plus:
			return binary(JsBinaryExpr.Kind.plus);
		case JsFun.set:
			assert(nArgs == 3);
			return forceStatement(ctx.alloc, SyncOrAsync.sync, pos, genAssign(
				ctx.alloc,
				source,
				genPropertyAccessComputed(ctx.alloc, source, getArg(0), getArg(1)),
				getArg(2)));
		case JsFun.typeof_:
			return unary(JsUnaryExpr.Kind.typeof_);
	}
}

ExprResult translateToBogus(ref Alloc alloc, in Source source, scope ExprPos pos) =>
	forceStatement(alloc, SyncOrAsync.sync, pos, genThrowBogus(alloc, source));

//TODO:MOVE?  -----------------------------------------------------------------------------------------------------------------------
public JsExpr genIsUnionMember(ref Alloc alloc, in Source source, JsExpr a, StructInst* member) =>
	genIn(alloc, source, JsMemberName.unionMember(member.decl.name), a);
public JsExpr genForceUnionMember(ref Alloc alloc, in Source source, JsExpr a, StructInst* member) =>
	genPropertyAccess(alloc, source, a, JsMemberName.unionMember(member.decl.name));
