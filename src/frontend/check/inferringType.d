module frontend.check.inferringType;

@safe @nogc pure nothrow:

import frontend.check.exprCtx : addDiag2, ExprCtx, typeWithContainer;
import frontend.check.instantiate : InstantiateCtx, instantiateStructNeverDelay;
import frontend.showModel : ShowCtx, ShowTypeCtx, ShowOptions, writeTypeUnquoted;
import frontend.storage : FileContentGetters, LineAndColumnGetters;
import model.ast : ExprAst;
import model.diag : Diag, ExpectedForDiag;
import model.model :
	BogusExpr,
	BogusWrongTypeExpr,
	CommonTypes,
	Expr,
	ExprAndType,
	ExprKind,
	ExprRef,
	FunKind,
	LoopExpr,
	StructDecl,
	StructInst,
	Type,
	TypeContainer,
	TypeParamIndex,
	TypeWithContainer;
import util.alloc.stackAlloc :
	MaxStackArray, withMapOrNoneToStackArray, withMapToStackArray, withMaxStackArray, withStackArray;
import util.cell : Cell, cellGet, cellSet;
import util.col.array :
	contains,
	emptyMutSmallArray,
	indexOf,
	isEmpty,
	map,
	mapStatic,
	MutSmallArray,
	newArray,
	NoneOneOrMany,
	noneOneOrMany,
	only,
	only2,
	small,
	zip,
	zipEvery;
import util.col.arrayBuilder : add, ArrayBuilder, arrayBuilderIsEmpty, asTemporaryArray, finish;
import util.col.enumMap : enumMapFindKey;
import util.memory : allocate;
import util.opt : has, force, MutOpt, none, noneMut, Opt, optOrDefault, some, someInout, someMut;
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
	immutable Type voidType;
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
	mixin TaggedUnion!(Infer, Type.Bogus, TypeParamIndex, StructInst*, MutSmallArray!TypeAndContext, LoopInfo*);

	T matchCombineType(T)(
		in T delegate(Infer) @safe @nogc pure nothrow cbInfer,
		in T delegate(Type) @safe @nogc pure nothrow cbType,
		in T delegate(TypeAndContext[]) @safe @nogc pure nothrow cbTypeAndContext,
		in T delegate(LoopInfo*) @safe @nogc pure nothrow cbLoopInfo,
	) =>
		matchWithPointers!T(
			cbInfer,
			(Type.Bogus x) => cbType(Type(x)),
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
			(Type.Bogus x) => cbType(Type(x)),
			(TypeParamIndex x) => cbType(Type(x)),
			(StructInst* x) => cbType(Type(x)),
			cbTypeAndContext,
			cbLoopInfo);
}

ExprAndType withInfer(in Expr delegate(ref Expected) @safe @nogc pure nothrow cb) {
	Expected expected = Expected(Expected.Infer());
	Expr expr = cb(expected);
	return ExprAndType(expr, inferred(expected));
}

ExprAndType checkWithModifyExpected(size_t n)(
	ref ExprCtx ctx,
	ref Expected outer,
	// If this returns 'none', the expected type can't be satisfied.
	in Opt!(Type[n]) delegate(Type) @safe @nogc pure nothrow cbModifyExpectedType,
	// This can return a modified type. E.g., if expecting a non-option, it would return the option.
	in ExprAndType delegate(ref Expected) @safe @nogc pure nothrow cbInner,
) =>
	outer.matchCombineType!ExprAndType(
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
			withMaxStackArray!(ExprAndType, TypeAndContext)(
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
			cbInner(outer));

Expr withExpect(Type type, in Expr delegate(ref Expected) @safe @nogc pure nothrow cb) {
	Expected expected = type.matchWithPointers!Expected(
			(Type.Bogus x) =>
				Expected(x),
			(TypeParamIndex x) =>
				Expected(x),
			(StructInst* x) =>
				Expected(x));
	return cb(expected);
}

struct ExprAndOptionType {
	ExprAndType option;
	Type nonOptionType;
}
ExprAndOptionType withExpectOption(
	InstantiateCtx instantiateCtx,
	in CommonTypes commonTypes,
	in Expr delegate(ref Expected) @safe @nogc pure nothrow cb,
) {
	Type[1] typeArgs = [Type(TypeParamIndex(0))];
	Type optionT = instantiateStructNeverDelay(instantiateCtx, commonTypes.option, small!Type(typeArgs));
	SingleInferringType[1] inferringTypes = [SingleInferringType()];
	TypeAndContext[1] expectedTypes = [TypeAndContext(optionT, TypeContext(small!SingleInferringType(inferringTypes)))];
	Expected expected = Expected(expectedTypes);
	Expr option = cb(expected);
	Type optionType = inferred(expected);
	Type innerType = optOrDefault!Type(tryGetInferred(inferringTypes[0]), () => Type.bogus);
	return ExprAndOptionType(ExprAndType(option, optionType), innerType);
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
			LineAndColumnGetters(null), // not used
			FileContentGetters(null),
			UrisInfo(),
			ShowOptions(color: false)),
		ctx.commonTypesPtr);

	a.matchConst!void(
		(const Expected.Infer) {
			writer ~= "<<infer>>";
		},
		(const Type.Bogus x) {
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
		(in Type.Bogus) {
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
	ExprAst* source,
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
			(Type.Bogus) {
				ambiguous = true;
			},
			(TypeParamIndex index) {
				Opt!Type inferred = tryGetInferred(choice.context, index);
				if (has(inferred))
					force(inferred).matchWithPointers!void(
						(Type.Bogus) {
							ambiguous = true;
						},
						(TypeParamIndex) {},
						(StructInst* x) { handleStruct(x); });
				else {
					ambiguous = true;
				}
			},
			(StructInst* x) { handleStruct(x); });
	});

	if (ambiguous || !has(cellGet(rslt))) {
		addDiag2(ctx, source, Diag(Diag.LiteralNotExpected(getExpectedForDiag(ctx, expected))));
		return none!size_t;
	} else if (!arrayBuilderIsEmpty(multiple)) {
		addDiag2(ctx, source, Diag(Diag.LiteralMultipleMatch(ctx.typeContainer, finish(ctx.alloc, multiple))));
		return none!size_t;
	} else
		return cellGet(rslt);
}

private @trusted void setToType(ref Expected expected, Type type) {
	type.matchWithPointers!void(
		(Type.Bogus x) { expected = x; },
		(TypeParamIndex x) { expected = x; },
		(StructInst* x) { expected = x; });
}
void setToBogus(ref Expected expected) {
	expected = Type.Bogus();
}
private void setToBogusIfInferring(ref Expected expected) {
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

struct Pair(T, U) {
	T a;
	U b;
}
Pair!(T, Type) withCopyWithNewExpectedType(T)(
	ref Expected expected,
	Type newExpectedType,
	TypeContext newTypeContext,
	in T delegate(ref Expected) @safe @nogc pure nothrow cb,
) {
	TypeAndContext[1] t = [TypeAndContext(newExpectedType, newTypeContext)];
	Expected newExpected = Expected(small!TypeAndContext(castNonScope_ref(t)));
	T res = cb(newExpected);
	return Pair!(T, Type)(castNonScope_ref(res), inferred(newExpected));
}

struct ExpectedLambdaType {
	TypeContext typeContext;
	FunType funType;
	Type instantiatedParamType;
}

MutOpt!ExpectedLambdaType getExpectedLambda(
	ref ExprCtx ctx,
	ExprAst* source,
	Opt!Type declaredParamType,
	ref Expected expected,
) {
	if (has(declaredParamType) && force(declaredParamType).isBogus)
		return noneMut!ExpectedLambdaType;

	Cell!(MutOpt!ExpectedLambdaType) res = Cell!(MutOpt!ExpectedLambdaType)();
	ArrayBuilder!Type multiple;
	bool anyDiag = false;
	eachChoice(expected, (TypeAndContext choice) {
		Opt!FunType optFunType = getExpectedFunType(ctx, source, choice);
		if (has(optFunType)) {
			FunType funType = force(optFunType);
			Opt!Type actualParamType = getExpectedParamTypeFromFunType(
				ctx, source, choice.context, declaredParamType, funType, anyDiag);
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
			addDiag2(ctx, source, Diag(
				Diag.LambdaMultipleMatch(ExpectedForDiag.Choices(finish(ctx.alloc, multiple), ctx.typeContainer))));
		return noneMut!ExpectedLambdaType;
	} else {
		if (!has(cellGet(res)))
			addDiag2(ctx, source, Diag(Diag.LambdaNotExpected(getExpectedForDiag(ctx, expected))));
		return cellGet(res);
	}
}

private Opt!FunType getExpectedFunType(ref ExprCtx ctx, ExprAst* source, TypeAndContext choice) {
	Opt!Type t = choice.type.isA!TypeParamIndex
		? tryGetInferred(choice.context, choice.type.as!TypeParamIndex)
		: some(choice.type);
	if (has(t))
		return getFunType(ctx.commonTypes, force(t));
	else {
		addDiag2(ctx, source, Diag(Diag.LambdaCantInferParamType()));
		return none!FunType;
	}
}

private Opt!Type getExpectedParamTypeFromFunType(
	ref ExprCtx ctx,
	ExprAst* source,
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
		addDiag2(ctx, source, Diag(Diag.LambdaCantInferParamType()));
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


// True if there is an unambiguous, non-inferring expected type.
bool hasInferredType(InstantiateCtx ctx, ref const Expected expected) =>
	has(tryGetNonInferringType(ctx, expected)) || expected.isA!(LoopInfo*);

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
				(in NoneOneOrMany.None) =>
					false,
				(in NoneOneOrMany.One x) =>
					matchTypes(ctx, candidateReturnType, choices[x.index]),
				(in NoneOneOrMany.Many) =>
					// Else don't infer any type args; multiple candidates and multiple possible return types.
					true),
		(const LoopInfo*) =>
			false);

Expr bogus(ref Expected expected, ExprAst* ast) {
	setToBogusIfInferring(expected);
	return Expr(ast, ExprKind(BogusExpr()));
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

Expr check(ref ExprCtx ctx, ref Expected expected, Type exprType, ExprAst* source, ExprKind exprKind) =>
	check(ctx, expected, ExprAndType(Expr(source, exprKind), exprType)).expr;
private ExprAndType check(ref ExprCtx ctx, ref Expected expected, ExprAndType a) {
	if (setTypeNoDiagnostic(ctx.instantiateCtx, expected, a.type))
		return a;
	else {
		addDiag2(ctx, a.expr.range, Diag(
			Diag.TypeConflict(getExpectedForDiag(ctx, expected), typeWithContainer(ctx, a.type))));
		setToBogusIfInferring(expected);
		return ExprAndType(
			Expr(a.expr.ast, ExprKind(BogusWrongTypeExpr(ExprRef(allocate(ctx.alloc, a.expr), a.type)))),
			Type.bogus);
	}
}

ExpectedForDiag getExpectedForDiag(ref ExprCtx ctx, ref const Expected expected) =>
	expected.matchCombineTypeConst!ExpectedForDiag(
		(Expected.Infer) =>
			ExpectedForDiag(ExpectedForDiag.Infer()),
		(Type x) =>
			ExpectedForDiag(ExpectedForDiag.Choices(newArray!Type(ctx.alloc, [x]), ctx.typeContainer)),
		(const TypeAndContext[] choices) =>
			ExpectedForDiag(ExpectedForDiag.Choices(
				map(ctx.alloc, choices, (ref const TypeAndContext x) => applyInferred(ctx.instantiateCtx, x)),
				ctx.typeContainer)),
		(const LoopInfo*) =>
			ExpectedForDiag(ExpectedForDiag.Loop()));

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
		(Type.Bogus) =>
			some(Type.bogus),
		(TypeParamIndex x) {
			const MutOpt!(SingleInferringType*) ta = tryGetInferring(a.context, x);
			return has(ta) ? tryGetInferred(*force(ta)) : some(a.type);
		},
		(StructInst* i) =>
			withMapOrNoneToStackArray!(Type, Type, Type)(
				i.typeArgs,
				(ref Type x) => tryGetNonInferringType(ctx, const TypeAndContext(x, a.context)),
				(scope Type[] newTypeArgs) => Type(instantiateStructNeverDelay(ctx, i.decl, newTypeArgs))));

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

Opt!FunType getFunType(in CommonTypes commonTypes, Type a) {
	if (a.isA!(StructInst*)) {
		StructInst* structInst = a.as!(StructInst*);
		Opt!FunKind kind = enumMapFindKey!(FunKind, StructDecl*)(commonTypes.funStructs, (in StructDecl* x) =>
			x == structInst.decl);
		return has(kind)
			? some(FunType(force(kind), structInst))
			: none!FunType;
	} else
		return none!FunType;
}

private:

// For diagnostics. Applies types that have been inferred, otherwise uses Bogus.
// This is like 'tryGetNonInferringType' but returns a type with Boguses in it instead of `none`.
Type applyInferred(InstantiateCtx ctx, in TypeAndContext a) =>
	a.type.match!Type(
		(Type.Bogus) =>
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
				(scope Type[] newTypeArgs) => Type(instantiateStructNeverDelay(ctx, i.decl, newTypeArgs))));

/*
Tries to find a way for 'a' and 'b' to be the same type.
It can fill in type arguments for 'a'. But unknown types in 'b' it will assume compatibility.
Returns true if it succeeds.
*/
public bool matchTypes(InstantiateCtx ctx, TypeAndContext a, const TypeAndContext b) =>
	a.type.matchWithPointers!bool(
		(Type.Bogus) =>
			// TODO: make sure to infer type params in this case!
			true,
		(TypeParamIndex pa) =>
			matchTypes_TypeParam(ctx, pa, a.context, b),
		(StructInst* ai) =>
			b.type.matchWithPointers!bool(
				(Type.Bogus) =>
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
			(Type.Bogus) =>
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
	in CommonTypes commonTypes,
	Type a,
	scope TypeContext aContext,
	Type lambdaParameterType,
) {
	Opt!FunType funType = getFunType(commonTypes, a);
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
		(Type.Bogus) {},
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
