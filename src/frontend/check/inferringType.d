module frontend.check.inferringType;

@safe @nogc pure nothrow:

import frontend.check.exprCtx : addDiag2, ExprCtx, typeWithContainer;
import frontend.check.instantiate : InstantiateCtx, instantiateStruct;
import frontend.showModel : ShowCtx, ShowTypeCtx, ShowOptions, writeTypeUnquoted;
import model.ast : ExprAst;
import model.model :
	BogusExpr,
	BogusType,
	BogusWrongTypeExpr,
	BuiltinType,
	CommonTypes,
	Diag,
	DiagLambdaCantInferParamType,
	DiagLambdaMultipleMatch,
	DiagLambdaNotExpected,
	DiagLiteralMultipleMatch,
	DiagLiteralNotExpected,
	DiagTypeConflict,
	ExpectedForDiag,
	ExpectedForDiagChoices,
	ExpectedForDiagInfer,
	ExpectedForDiagLoop,
	Expr,
	FunKind,
	funKindFromBuiltinType,
	LoopExpr,
	StructDecl,
	StructInst,
	Type,
	TypeContainer,
	TypeParamIndex,
	TypeWithContainer;
import model.sourceRange : FileContentGetters, LineAndColumnGetters, Range;
import util.alloc.stackAlloc :
	MaxStackArray, withMapOrNoneToStackArray, withMapToStackArray, withMaxStackArray, withStackArray;
import util.cell : Cell, cellGet, cellSet;
import util.col.array :
	contains,
	emptyMutSmallArray,
	indexOf,
	isEmpty,
	Many,
	map,
	mapStatic,
	MutSmallArray,
	newArray,
	None,
	noneOneOrMany,
	One,
	only,
	only2,
	small,
	zip,
	zipEvery;
import util.col.arrayBuilder : add, ArrayBuilder, arrayBuilderIsEmpty, asTemporaryArray, finish;
import util.memory : allocate;
import util.opt : has, force, MutOpt, none, noneMut, Opt, optIf, optOrDefault, some, someInout, someMut;
import util.union_ : TaggedUnion;
import util.uri : UrisInfo;
import util.util : castNonScope_ref;
import util.writer : Writer, writeWithCommas;

struct SingleInferringType {
	@safe @nogc pure nothrow:

	private Cell!(Opt!Type) type;

	@disable this(ref const SingleInferringType);
	this(Opt!Type t) {
		type = Cell!(Opt!Type)(t);
	}

	void setAndIgnoreExisting(Type t) {
		cellSet(type, some(t));
	}
}

Opt!Type tryGetInferred(ref const SingleInferringType a) =>
	cellGet(a.type);

struct TypeContext {
	@safe @nogc pure nothrow:
	MutSmallArray!SingleInferringType args;
	static TypeContext nonInferring() =>
		TypeContext(emptyMutSmallArray!SingleInferringType);
	bool isInferring() scope const =>
		!isEmpty(args);
}

private @trusted inout(MutOpt!(SingleInferringType*)) tryGetInferring(
	inout TypeContext context,
	TypeParamIndex param,
) =>
	context.isInferring
		? someInout!(SingleInferringType*)(&context.args[param.index])
		: cast(inout) noneMut!(SingleInferringType*);

private Opt!Type tryGetInferred(const TypeContext a, TypeParamIndex param) {
	const MutOpt!(SingleInferringType*) sit = tryGetInferring(a, param);
	return has(sit) ? tryGetInferred(*force(sit)) : none!Type;
}

struct LoopInfo {
	immutable LoopExpr* loop;
	immutable Type type;
	bool hasBreak;
}

struct TypeAndContext {
	immutable Type type;
	TypeContext context;
}

TypeAndContext nonInferring(Type a) =>
	TypeAndContext(a, TypeContext.nonInferring);

struct Expected {
	@safe @nogc pure nothrow:
	private:

	immutable struct Infer {}
	// TypeParamIndex (and type params in type args of StructInst) are in the context of the function being checked
	mixin TaggedUnion!(Infer, BogusType, TypeParamIndex, StructInst*, MutSmallArray!TypeAndContext, LoopInfo*);

	T matchCombineType(T)(
		in T delegate(Infer) @safe @nogc pure nothrow cbInfer,
		in T delegate(Type) @safe @nogc pure nothrow cbType,
		in T delegate(TypeAndContext[]) @safe @nogc pure nothrow cbTypeAndContext,
		in T delegate(LoopInfo*) @safe @nogc pure nothrow cbLoopInfo,
	) =>
		matchWithPointers!T(
			cbInfer,
			(BogusType x) => cbType(Type(x)),
			(TypeParamIndex x) => cbType(Type(x)),
			(StructInst* x) => cbType(Type(x)),
			cbTypeAndContext,
			cbLoopInfo);
	T matchCombineTypeConst(T)(
		in T delegate(Infer) @safe @nogc pure nothrow cbInfer,
		in T delegate(Type) @safe @nogc pure nothrow cbType,
		in T delegate(const TypeAndContext[]) @safe @nogc pure nothrow cbTypeAndContext,
		in T delegate(const LoopInfo*) @safe @nogc pure nothrow cbLoopInfo,
	) const =>
		matchConst!T(
			cbInfer,
			(BogusType x) => cbType(Type(x)),
			(TypeParamIndex x) => cbType(Type(x)),
			(StructInst* x) => cbType(Type(x)),
			cbTypeAndContext,
			cbLoopInfo);
}

// In the type checker, an expression 'type' funciton might not be callable due to late initialization/
// For example, a ClosureGet accesses its type from the lambda, which might not be initialized yet.
// So we instead pass the type explicitly.
immutable struct ExprAndType {
	Expr expr;
	Type type;
}

ExprAndType withInfer(in Expr delegate(ref Expected) @safe @nogc pure nothrow cb) {
	Expected expected = Expected(Expected.Infer());
	Expr expr = cb(expected);
	return ExprAndType(expr, inferred(expected));
}

Expr checkWithModifyExpected(size_t n)(
	ref ExprCtx ctx,
	ref Expected outer,
	// If this returns 'none', the expected type can't be satisfied.
	in Opt!(Type[n]) delegate(Type) @safe @nogc pure nothrow cbModifyExpectedType,
	// This can return a modified type. E.g., if expecting a non-option, it would return the option.
	in ExprAndType delegate(ref Expected) @safe @nogc pure nothrow cbInner,
) =>
	outer.matchCombineType!Expr(
		(Expected.Infer) {
			Expected inner = Expected(Expected.Infer());
			return check(ctx, outer, cbInner(inner));
		},
		(Type x) {
			Opt!(Type[n]) newExpected = cbModifyExpectedType(x);
			if (has(newExpected)) {
				TypeAndContext[n] withContext = mapStatic(force(newExpected), (Type x) => nonInferring(x));
				Expected inner = Expected(withContext);
				return check(ctx, inner, cbInner(inner));
			} else {
				Expected inner = Expected(Expected.Infer());
				return check(ctx, outer, cbInner(inner));
			}
		},
		(TypeAndContext[] outerTypes) =>
			withMaxStackArray!(Expr, TypeAndContext)(
				outerTypes.length * n,
				(scope ref MaxStackArray!TypeAndContext modifiedTypes) {
					foreach (ref TypeAndContext outerType; outerTypes) {
						Opt!(Type[n]) newExpected = cbModifyExpectedType(outerType.type);
						if (has(newExpected))
							modifiedTypes ~= mapStatic!(n, TypeAndContext, Type)(force(newExpected), (Type t) =>
								TypeAndContext(t, outerType.context));
					}
					Expected inner = modifiedTypes.isEmpty
						? Expected(Expected.Infer())
						: Expected(modifiedTypes.finish);
					return check(ctx, outer, cbInner(inner));
				}),
		(LoopInfo*) =>
			cbInner(outer).expr);

Expr withExpect(Type type, in Expr delegate(ref Expected) @safe @nogc pure nothrow cb) {
	Expected expected = type.matchWithPointers!Expected(
			(BogusType x) =>
				Expected(x),
			(TypeParamIndex x) =>
				Expected(x),
			(StructInst* x) =>
				Expected(x));
	return cb(expected);
}
ExprAndType withExpect(Type type, TypeContext context, in Expr delegate(ref Expected) @safe @nogc pure nothrow cb) {
	TypeAndContext[1] t = [TypeAndContext(type, context)];
	Expected expected = Expected(small!TypeAndContext(castNonScope_ref(t)));
	Expr res = cb(expected);
	return ExprAndType(res, inferred(expected));
}

struct ExprAndOptionType {
	Expr option;
	Type nonOptionType;
}
ExprAndOptionType withExpectOption(
	InstantiateCtx instantiateCtx,
	in CommonTypes commonTypes,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cb,
) {
	Type[1] typeArgs = [Type(TypeParamIndex(0))];
	Type optionT = instantiateStruct(instantiateCtx, commonTypes.option, small!Type(typeArgs));
	SingleInferringType[1] inferringTypes = [SingleInferringType()];
	TypeAndContext[1] expectedTypes = [TypeAndContext(optionT, TypeContext(small!SingleInferringType(inferringTypes)))];
	Expected expected = Expected(expectedTypes);
	Expr option = cb(expected);
	Type innerType = optOrDefault!Type(tryGetInferred(inferringTypes[0]), () => Type.bogus);
	return ExprAndOptionType(option, innerType);
}

Type withExpectCandidates(
	scope TypeAndContext[] candidates,
	in void delegate(ref Expected) @safe @nogc pure nothrow cb,
) {
	Expected expected = Expected(small!TypeAndContext(candidates));
	cb(expected);
	return inferred(expected);
}

// Also writes to info.hasBreak
Expr withExpectLoop(ref LoopInfo info, in Expr delegate(ref Expected) @safe @nogc pure nothrow cb) {
	Expected expected = Expected(&info);
	return cb(castNonScope_ref(expected));
}

void debugLogExpected(scope ref Writer writer, ref ExprCtx ctx, in Expected a) {
	ShowTypeCtx showCtx = ShowTypeCtx(
		ShowCtx(
			LineAndColumnGetters(), // not used
			FileContentGetters(),
			UrisInfo(),
			ShowOptions(color: false)),
		ctx.commonTypesPtr);

	a.matchConst!void(
		(const Expected.Infer) {
			writer ~= "<<infer>>";
		},
		(const BogusType x) {
			writer ~= "<<bogus>>";
		},
		(const TypeParamIndex x) {
			writer ~= "local type ";
			writeTypeUnquoted(writer, showCtx, typeWithContainer(ctx, Type(x)));
		},
		(const StructInst* x) {
			writer ~= "local type ";
			writeTypeUnquoted(writer, showCtx, typeWithContainer(ctx, Type(x)));
		},
		(const TypeAndContext[] choices) {
			writer ~= "choices: ";
			writeWithCommas!TypeAndContext(writer, choices, (in TypeAndContext choice) {
				debugLogExpectedChoice(writer, showCtx, ctx.typeContainer, choice);
			});
		},
		(const LoopInfo* x) {
			writer ~= "loop returning ";
			writeTypeUnquoted(writer, showCtx, typeWithContainer(ctx, x.type));
		});
}

private void debugLogExpectedChoice(
	scope ref Writer writer,
	in ShowTypeCtx showCtx,
	in TypeContainer container,
	in TypeAndContext choice,
) {
	choice.type.matchIn!void(
		(in BogusType _) {
			writer ~= "<<bogus>>";
		},
		(in TypeParamIndex x) {
			writer ~= "type param ";
			writer ~= x.index;
			const MutOpt!(SingleInferringType*) ta = tryGetInferring(choice.context, x);
			Opt!Type inferred = tryGetInferred(*force(ta));
			if (has(inferred)) {
				writer ~= " inferred as ";
				writeTypeUnquoted(writer, showCtx, TypeWithContainer(force(inferred), container));
			} else
				writer ~= " with no inference";
		},
		(in StructInst x) {
			if (!isEmpty(x.typeArgs)) {
				writer ~= '(';
				writeWithCommas!Type(writer, x.typeArgs, (in Type typeArg) {
					debugLogExpectedChoice(writer, showCtx, container, const TypeAndContext(typeArg, choice.context));
				});
				writer ~= ") ";
			}
			writer ~= x.decl.name;
		});
}

MutOpt!(LoopInfo*) tryGetLoop(ref Expected expected) =>
	expected.isA!(LoopInfo*) ? someMut(expected.as!(LoopInfo*)) : noneMut!(LoopInfo*);

/**
Returns an index into 'choices' if it is the only allowed choice.
If there is no unambiguous choice, adds a diagnostic and returns 'none'.
*/
Opt!size_t findExpectedStructForLiteral(
	ref ExprCtx ctx,
	Range range,
	ref const Expected expected,
	in immutable StructInst*[] choices,
) {
	Cell!(Opt!size_t) rslt;
	bool ambiguous = false;
	ArrayBuilder!(immutable StructInst*) multiple; // for diag

	void handleStruct(StructInst* struct_) {
		Opt!size_t here = indexOf(choices, struct_);
		if (has(here)) {
			if (has(cellGet(rslt))) {
				StructInst* rsltStruct = choices[force(cellGet(rslt))];
				if (struct_ != rsltStruct) {
					if (arrayBuilderIsEmpty(multiple))
						add(ctx.alloc, multiple, rsltStruct);
					if (!contains(asTemporaryArray(multiple), struct_))
						add(ctx.alloc, multiple, struct_);
				}
			} else
				cellSet(rslt, here);
		}
	}

	eachChoiceConst(expected, (const TypeAndContext choice) {
		choice.type.matchWithPointers!void(
			(BogusType _) {
				ambiguous = true;
			},
			(TypeParamIndex index) {
				Opt!Type inferred = tryGetInferred(choice.context, index);
				if (has(inferred))
					force(inferred).matchWithPointers!void(
						(BogusType _) {
							ambiguous = true;
						},
						(TypeParamIndex _) {},
						(StructInst* x) { handleStruct(x); });
				else {
					ambiguous = true;
				}
			},
			(StructInst* x) { handleStruct(x); });
	});

	if (ambiguous || !has(cellGet(rslt))) {
		addDiag2(ctx, range, Diag(DiagLiteralNotExpected(getExpectedForDiag(ctx, expected))));
		return none!size_t;
	} else if (!arrayBuilderIsEmpty(multiple)) {
		addDiag2(ctx, range, Diag(DiagLiteralMultipleMatch(ctx.typeContainer, finish(ctx.alloc, multiple))));
		return none!size_t;
	} else
		return cellGet(rslt);
}

private @trusted void setToType(ref Expected expected, Type type) {
	type.matchWithPointers!void(
		(BogusType x) { expected = x; },
		(TypeParamIndex x) { expected = x; },
		(StructInst* x) { expected = x; });
}
private void setToBogus(ref Expected expected) {
	expected = BogusType();
}
void setToBogusIfInferring(ref Expected expected) {
	expected.matchCombineType!void(
		(Expected.Infer) {
			setToBogus(expected);
		},
		(Type _) {},
		(TypeAndContext[]) {
			setToBogus(expected);
		},
		(LoopInfo*) {});

}

struct ExpectedLambdaType {
	TypeContext typeContext;
	FunType funType;
	Type instantiatedParamType;
}

MutOpt!ExpectedLambdaType getExpectedLambda(
	ref ExprCtx ctx,
	Range diagRange,
	Opt!Type declaredParamType,
	ref Expected expected,
) {
	if (has(declaredParamType) && force(declaredParamType).isBogus)
		return noneMut!ExpectedLambdaType;

	Cell!(MutOpt!ExpectedLambdaType) res = Cell!(MutOpt!ExpectedLambdaType)();
	ArrayBuilder!Type multiple;
	bool anyDiag = false;
	eachChoice(expected, (TypeAndContext choice) {
		Opt!FunType optFunType = getExpectedFunType(ctx, diagRange, choice);
		if (has(optFunType)) {
			FunType funType = force(optFunType);
			Opt!Type actualParamType = getExpectedParamTypeFromFunType(
				ctx, diagRange, choice.context, declaredParamType, funType, anyDiag);
			if (has(actualParamType)) {
				if (has(cellGet(res))) {
					if (arrayBuilderIsEmpty(multiple)) {
						ExpectedLambdaType prev = force(cellGet(res));
						add(ctx.alloc, multiple, applyInferred(
							ctx.instantiateCtx, TypeAndContext(Type(prev.funType.structInst), prev.typeContext)));
					}
					add(ctx.alloc, multiple, applyInferred(ctx.instantiateCtx, choice));
					anyDiag = true;
				}
				cellSet(res, someMut(ExpectedLambdaType(choice.context, funType, force(actualParamType))));
			}
		}
	});

	if (anyDiag) {
		if (!arrayBuilderIsEmpty(multiple))
			addDiag2(ctx, diagRange, Diag(
				DiagLambdaMultipleMatch(ExpectedForDiagChoices(finish(ctx.alloc, multiple), ctx.typeContainer))));
		return noneMut!ExpectedLambdaType;
	} else {
		if (!has(cellGet(res)))
			addDiag2(ctx, diagRange, Diag(DiagLambdaNotExpected(getExpectedForDiag(ctx, expected))));
		return cellGet(res);
	}
}

private Opt!FunType getExpectedFunType(ref ExprCtx ctx, Range diagRange, TypeAndContext choice) {
	Opt!Type t = choice.type.isA!TypeParamIndex
		? tryGetInferred(choice.context, choice.type.as!TypeParamIndex)
		: some(choice.type);
	if (has(t))
		return getFunType(force(t));
	else {
		addDiag2(ctx, diagRange, Diag(DiagLambdaCantInferParamType()));
		return none!FunType;
	}
}

private Opt!Type getExpectedParamTypeFromFunType(
	ref ExprCtx ctx,
	Range diagRange,
	TypeContext typeContext,
	Opt!Type declaredParamType,
	FunType funType,
	ref bool anyDiag,
) {
	Opt!Type optExpectedParamType = tryGetNonInferringType(
		ctx.instantiateCtx, TypeAndContext(funType.paramType, typeContext));
	if (has(optExpectedParamType))
		return !has(declaredParamType) || force(optExpectedParamType) == force(declaredParamType)
			? optExpectedParamType
			: none!Type;
	else if (has(declaredParamType))
		return some(force(declaredParamType));
	else {
		addDiag2(ctx, diagRange, Diag(DiagLambdaCantInferParamType()));
		anyDiag = true;
		return none!Type;
	}
}

private void eachChoice(ref Expected a, in void delegate(TypeAndContext) @safe @nogc pure nothrow cb) =>
	a.matchCombineType!void(
		(Expected.Infer) {},
		(Type x) {
			cb(nonInferring(x));
		},
		(TypeAndContext[] choices) {
			foreach (TypeAndContext choice; choices)
				cb(choice);
		},
		(LoopInfo*) {});
private void eachChoiceConst(
	ref const Expected a,
	in void delegate(const TypeAndContext) @safe @nogc pure nothrow cb,
) =>
	a.matchCombineTypeConst!void(
		(Expected.Infer) {},
		(Type x) {
			cb(nonInferring(x));
		},
		(const TypeAndContext[] choices) {
			foreach (const TypeAndContext choice; choices)
				cb(choice);
		},
		(const LoopInfo*) {});

Opt!Type tryGetNonInferringTypeIncludingLoop(InstantiateCtx ctx, ref const Expected expected) =>
	expected.isA!(LoopInfo*)
		? some(expected.asConst!(LoopInfo*).type)
		: tryGetNonInferringType(ctx, expected);

// This will return a result if there are no references to inferring type parameters.
// (There may be references to the current function's type parameters.)
private Opt!Type tryGetNonInferringType(InstantiateCtx ctx, ref const Expected expected) =>
	expected.matchCombineTypeConst!(Opt!Type)(
		(Expected.Infer) =>
			none!Type,
		(Type x) =>
			some(x),
		(const TypeAndContext[] choices) =>
			choices.length == 1 ? tryGetNonInferringType(ctx, only(choices)) : none!Type,
		(const LoopInfo*) =>
			none!Type);

bool matchExpectedVsReturnTypeNoDiagnostic(
	InstantiateCtx ctx,
	ref const Expected expected,
	TypeAndContext candidateReturnType,
) =>
	expected.matchCombineTypeConst!bool(
		(Expected.Infer) =>
			true,
		(Type x) =>
			// We have a particular expected type, so infer its type args
			matchTypes(ctx, candidateReturnType, nonInferring(x)),
		(const TypeAndContext[] choices) =>
			noneOneOrMany!TypeAndContext(choices, (in TypeAndContext x) =>
				isTypeMatchPossible(x, candidateReturnType)
			).matchIn!bool(
				(in None _) =>
					false,
				(in One x) =>
					matchTypes(ctx, candidateReturnType, choices[x.index]),
				(in Many _) =>
					// Else don't infer any type args; multiple candidates and multiple possible return types.
					true),
		(const LoopInfo*) =>
			false);

Expr bogus(ref Expected expected, ExprAst* ast) =>
	bogus(expected, ast.range);
Expr bogus(ref Expected expected, Range range) {
	setToBogusIfInferring(expected);
	return Expr(BogusExpr(range, inferred(expected)));
}

Type inferred(ref const Expected expected) =>
	expected.matchCombineTypeConst!Type(
		(Expected.Infer) =>
			assert(false),
		(Type x) =>
			x,
		(const TypeAndContext[] choices) =>
			// If there were multiple, we should have set the expected.
			only(choices).type,
		(const LoopInfo* x) =>
			x.type);

Expr check(ref ExprCtx ctx, ref Expected expected, Type exprType, Expr expr) =>
	check(ctx, expected, ExprAndType(expr, exprType));
private Expr check(ref ExprCtx ctx, ref Expected expected, ExprAndType a) {
	if (setTypeNoDiagnostic(ctx.instantiateCtx, expected, a.type))
		return a.expr;
	else {
		addDiag2(ctx, a.expr.range, Diag(
			DiagTypeConflict(getExpectedForDiag(ctx, expected), typeWithContainer(ctx, a.type))));
		setToBogusIfInferring(expected);
		return Expr(BogusWrongTypeExpr(allocate(ctx.alloc, a.expr), inferred(expected)));
	}
}

ExpectedForDiag getExpectedForDiag(ref ExprCtx ctx, ref const Expected expected) =>
	expected.matchCombineTypeConst!ExpectedForDiag(
		(Expected.Infer) =>
			ExpectedForDiag(ExpectedForDiagInfer()),
		(Type x) =>
			ExpectedForDiag(ExpectedForDiagChoices(newArray!Type(ctx.alloc, [x]), ctx.typeContainer)),
		(const TypeAndContext[] choices) =>
			ExpectedForDiag(ExpectedForDiagChoices(
				map(ctx.alloc, choices, (ref const TypeAndContext x) => applyInferred(ctx.instantiateCtx, x)),
				ctx.typeContainer)),
		(const LoopInfo*) =>
			ExpectedForDiag(ExpectedForDiagLoop()));

// Note: this may infer type parameters
private bool setTypeNoDiagnostic(InstantiateCtx ctx, ref Expected expected, Type actual) =>
	expected.matchCombineType!bool(
		(Expected.Infer) {
			setToType(expected, actual);
			return true;
		},
		(Type x) =>
			matchTypes(ctx, nonInferring(x), nonInferring(actual)),
		(TypeAndContext[] choices) {
			bool anyOk = false;
			foreach (ref TypeAndContext x; choices)
				if (matchTypes(ctx, x, nonInferring(actual)))
					anyOk = true;
			if (anyOk) setToType(expected, actual);
			return anyOk;
		},
		(LoopInfo* loop) =>
			false);

Opt!Type tryGetNonInferringType(InstantiateCtx ctx, const TypeAndContext a) =>
	a.type.matchWithPointers!(Opt!Type)(
		(BogusType _) =>
			some(Type.bogus),
		(TypeParamIndex x) {
			const MutOpt!(SingleInferringType*) ta = tryGetInferring(a.context, x);
			return has(ta) ? tryGetInferred(*force(ta)) : some(a.type);
		},
		(StructInst* i) =>
			withMapOrNoneToStackArray!(Type, Type, Type)(
				i.typeArgs,
				(ref Type x) => tryGetNonInferringType(ctx, const TypeAndContext(x, a.context)),
				(scope Type[] newTypeArgs) => Type(instantiateStruct(ctx, i.decl, newTypeArgs))));

immutable struct FunType {
	@safe @nogc pure nothrow:

	FunKind kind;
	StructInst* structInst;

	StructDecl* funStruct() =>
		structInst.decl;
	Type returnType() =>
		only2(structInst.typeArgs)[0];
	Type paramType() =>
		only2(structInst.typeArgs)[1];
}

Opt!FunType getFunType(Type a) {
	if (a.isA!(StructInst*)) {
		StructInst* structInst = a.as!(StructInst*);
		if (structInst.decl.body_.isA!BuiltinType) {
			BuiltinType x = structInst.decl.body_.as!BuiltinType;
			Opt!FunKind kind = funKindFromBuiltinType(x);
			return optIf(has(kind), () => FunType(force(kind), structInst));
		} else
			return none!FunType;
	} else
		return none!FunType;
}

private:

// For diagnostics. Applies types that have been inferred, otherwise uses Bogus.
// This is like 'tryGetNonInferringType' but returns a type with Boguses in it instead of `none`.
Type applyInferred(InstantiateCtx ctx, in TypeAndContext a) =>
	a.type.match!Type(
		(BogusType _) =>
			Type.bogus,
		(TypeParamIndex x) {
			const MutOpt!(SingleInferringType*) ta = tryGetInferring(a.context, x);
			return has(ta)
				// If not yet inferred, use Bogus to indicate that any type would work.
				? optOrDefault!Type(tryGetInferred(*force(ta)), () => Type.bogus)
				: Type(x);
		},
		(ref StructInst i) =>
			withMapToStackArray!(Type, Type, Type)(
				i.typeArgs,
				(ref Type x) => applyInferred(ctx, const TypeAndContext(x, a.context)),
				(scope Type[] newTypeArgs) => Type(instantiateStruct(ctx, i.decl, newTypeArgs))));

/*
Tries to find a way for 'a' and 'b' to be the same type.
It can fill in type arguments for 'a'. But unknown types in 'b' it will assume compatibility.
Returns true if it succeeds.
*/
public bool matchTypes(InstantiateCtx ctx, TypeAndContext a, const TypeAndContext b) =>
	a.type.matchWithPointers!bool(
		(BogusType _) =>
			// TODO: make sure to infer type params in this case!
			true,
		(TypeParamIndex pa) =>
			matchTypes_TypeParam(ctx, pa, a.context, b),
		(StructInst* ai) =>
			b.type.matchWithPointers!bool(
				(BogusType _) =>
					true,
				(TypeParamIndex pb) =>
					matchTypes_TypeParamB(ctx, a, pb, b.context),
				(StructInst* bi) =>
					ai.decl == bi.decl &&
					zipEvery!(Type, Type)(ai.typeArgs, bi.typeArgs, (ref Type argA, ref Type argB) =>
						matchTypes(
							ctx, TypeAndContext(argA, a.context), const TypeAndContext(argB, b.context)))));

bool matchTypes_TypeParam(InstantiateCtx ctx, TypeParamIndex a, TypeContext aContext, const TypeAndContext b) {
	MutOpt!(SingleInferringType*) aInferring = tryGetInferring(aContext, a);
	if (has(aInferring)) {
		Opt!Type inferred = tryGetInferred(*force(aInferring));
		bool ok = !has(inferred) || matchTypes(ctx, TypeAndContext(force(inferred), TypeContext.nonInferring), b);
		if (ok) {
			Opt!Type bInferred = tryGetNonInferringType(ctx, b);
			if (has(bInferred))
				cellSet(force(aInferring).type, bInferred);
		}
		return ok;
	} else
		// It's an outer type param (not in either inferring).
		return b.type.match!bool(
			(BogusType _) =>
				true,
			(TypeParamIndex bp) {
				const MutOpt!(SingleInferringType*) bInferringB = tryGetInferring(b.context, bp);
				if (has(bInferringB)) {
					Opt!Type inferred = tryGetInferred(*force(bInferringB));
					return !has(inferred) ||
						(force(inferred).isA!TypeParamIndex && force(inferred).as!TypeParamIndex == a);
				} else
					return a == bp;
			},
			(ref StructInst) =>
				false);
}

bool matchTypes_TypeParamB(InstantiateCtx ctx, TypeAndContext a, TypeParamIndex b, in TypeContext bContext) {
	const MutOpt!(SingleInferringType*) bInferred = tryGetInferring(bContext, b);
	if (has(bInferred)) {
		Opt!Type inferred = tryGetInferred(*force(bInferred));
		return !has(inferred) || matchTypes(ctx, a, nonInferring(force(inferred)));
	} else
		return false;
}

public void inferTypeArgsFromLambdaParameterType(
	InstantiateCtx ctx,
	Type a,
	scope TypeContext aContext,
	Type lambdaParameterType,
) {
	Opt!FunType funType = getFunType(a);
	if (has(funType))
		inferTypeArgsFrom(ctx, force(funType).paramType, aContext, nonInferring(lambdaParameterType));
}

public void inferTypeArgsFrom(
	InstantiateCtx ctx,
	Type a,
	scope TypeContext aContext,
	const TypeAndContext b,
) {
	if (isInferringNonInferredTypeParam(b))
		return;
	const TypeAndContext b2 = maybeInferred(b);
	a.matchWithPointers!void(
		(BogusType _) {},
		(TypeParamIndex ap) {
			SingleInferringType* aInferring = &aContext.args[ap.index];
			if (!has(tryGetInferred(*aInferring))) {
				Opt!Type t = tryGetNonInferringType(ctx, b2);
				if (has(t))
					cellSet(aInferring.type, t);
			}
		},
		(StructInst* ai) {
			if (b2.type.isA!(StructInst*)) {
				const StructInst* bi = b2.type.as!(StructInst*);
				if (ai.decl == bi.decl)
					zip(ai.typeArgs, bi.typeArgs, (ref Type ta, ref Type tb) {
						inferTypeArgsFrom(ctx, ta, aContext, const TypeAndContext(tb, b2.context));
					});
			}
		});
}

public bool isTypeMatchPossibleForCompletions(
	in TypeWithContainer paramType,
	in Type actualArgType,
) =>
	withStackArray!(bool, SingleInferringType)(
		paramType.container.typeParams.length,
		(size_t _) => SingleInferringType(),
		(scope SingleInferringType[] inferring) =>
			isTypeMatchPossible(
				TypeAndContext(paramType.type, TypeContext(small!SingleInferringType(inferring))),
				nonInferring(actualArgType)));

bool isTypeMatchPossible(in TypeAndContext a, in TypeAndContext b) {
	if (isInferringNonInferredTypeParam(a) || isInferringNonInferredTypeParam(b))
		return true;
	else {
		const TypeAndContext a2 = maybeInferred(a);
		const TypeAndContext b2 = maybeInferred(b);
		return (a2.type == b2.type && !a2.context.isInferring && !b2.context.isInferring) ||
			a2.type.isBogus ||
			b2.type.isBogus ||
			typesAreCorrespondingStructInsts(a2.type, b2.type, (ref Type x, ref Type y) =>
				isTypeMatchPossible(const TypeAndContext(x, a2.context), const TypeAndContext(y, b2.context)));
	}
}
// True for a type param with no inference yet
bool isInferringNonInferredTypeParam(in TypeAndContext a) {
	if (a.type.isA!TypeParamIndex) {
		const MutOpt!(SingleInferringType*) inferring = tryGetInferring(a.context, a.type.as!TypeParamIndex);
		if (has(inferring)) {
			Opt!Type t = tryGetInferred(*force(inferring));
			return !has(t);
		} else
			return false;
	} else
		return false;
}
const(TypeAndContext) maybeInferred(return scope const TypeAndContext a) {
	if (a.type.isA!TypeParamIndex) {
		const MutOpt!(SingleInferringType*) inferring = tryGetInferring(a.context, a.type.as!TypeParamIndex);
		if (has(inferring)) {
			// force because we tested 'isInferringNonInferredTypeParam' before
			Opt!Type t = tryGetInferred(*force(inferring));
			return nonInferring(force(t));
		} else
			return a;
	} else
		return a;
}

public bool typesAreCorrespondingStructInsts(
	in Type a,
	in Type b,
	in bool delegate(ref Type x, ref Type y) @safe @nogc pure nothrow typesCorrespond,
) {
	if (a.isA!(StructInst*) && b.isA!(StructInst*)) {
		StructInst* sa = a.as!(StructInst*);
		StructInst* sb = b.as!(StructInst*);
		return sa.decl == sb.decl && zipEvery!(Type, Type)(sa.typeArgs, sb.typeArgs, typesCorrespond);
	} else
		return false;
}
