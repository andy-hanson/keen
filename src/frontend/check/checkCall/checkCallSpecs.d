module frontend.check.checkCall.checkCallSpecs;

@safe @nogc pure nothrow:

import frontend.check.checkCall.candidates :
	Candidate, candidateBogusCalled, eachCandidate, FunsInScope, testCandidateForSpecSig;
import frontend.check.checkCtx : addDiag, CheckCtx, markUsed;
import frontend.check.exprCtx : allowsUnsafe, isInDataLambda, isInLambda, LocalsInfo;
import frontend.check.inferringType : SingleInferringType, tryGetInferred, TypeContext;
import frontend.check.instantiate :
	InstantiateCtx, instantiateFun, instantiateSpecInst, noDelaySpecInsts;
import frontend.check.maps : FunsMap;
import frontend.lang : maxSpecDepth;
import model.model :
	BuiltinSpec,
	Called,
	CalledDecl,
	CalledSpecSig,
	CommonTypes,
	countSigs,
	Diag,
	FunDecl,
	FunDeclAndTypeArgs,
	FunInst,
	FunFlags,
	isPurityAlwaysCompatible,
	isPurityCompatible,
	Purity,
	PurityRange,
	purityRange,
	ReturnAndParamTypes,
	SpecDecl,
	Signature,
	SpecInst,
	Specs,
	StructInst,
	Type,
	TypeArgs,
	TypeContainer;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withExactStackArray, withMapOrNoneToStackArray, withMaxStackArray;
import util.cell : Cell, cellGet, cellSet;
import util.col.array : every, exists, first, firstZipPointerFirst, newArray, only, small, sum;
import util.col.arrayBuilder : add, ArrayBuilder, arrayBuilderIsEmpty, finish;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish, smallFinish;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, optOr, some;
import util.sourceRange : Range;
import util.symbol : Symbol;
import util.symbolSet : SymbolSet;
import util.union_ : Union;
import util.util : castNonScope_ref;

bool isShared(in immutable SpecInst*[] funSpecs, Type type) =>
	isPurityAlwaysCompatibleConsideringSpecs(funSpecs, type, Purity.shared_);

bool isPurityAlwaysCompatibleConsideringSpecs(in immutable SpecInst*[] funSpecs, Type type, Purity expected) {
	PurityRange typePurity = purityRange(type);
	return isPurityAlwaysCompatible(referencer: expected, referenced: typePurity) ||
		exists!(SpecInst*)(funSpecs, (in SpecInst* inst) =>
			specProvidesPurity(*inst, type, expected)) ||
		(type.isA!(StructInst*) &&
			isPurityCompatible(expected, typePurity.bestCase) &&
			every!Type(type.as!(StructInst*).typeArgs, (in Type typeArg) =>
				isPurityAlwaysCompatibleConsideringSpecs(funSpecs, typeArg, expected)));
}

Called checkCallSpecs(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	FunsInScope funsInScope,
	Range diagRange,
	ref const Candidate candidate,
) {
	CheckSpecsCtx checkSpecsCtx = CheckSpecsCtx(ctx.allocPtr, ctx.instantiateCtx, funsInScope);
	return getCalledFromCandidateAfterTypeChecks!DummyTrace(checkSpecsCtx, candidate, DummyTrace()).match!Called(
		(Called x) =>
			checkSpecsCtx.hasErrors
				? checkCallSpecsWithRealTrace(ctx, commonTypes, typeContainer, funsInScope, diagRange, candidate)
				: x,
		(DummyTrace.NoMatch _) =>
			checkCallSpecsWithRealTrace(ctx, commonTypes, typeContainer, funsInScope, diagRange, candidate));
}

Called checkSpecSingleSigIgnoreParents(ref CheckCtx ctx, in FunsMap funsMap, FunDecl* decl, SpecInst* spec) =>
	checkSpecSingleSigIgnoreParents2(
		ctx, funsMap, decl.nameRange.range, TypeContainer(decl), decl.specs, decl.flags, decl.externs, spec);
Called checkSpecSingleSigIgnoreParents2(
	ref CheckCtx ctx,
	in FunsMap funsMap,
	Range diagRange,
	TypeContainer caller,
	Specs callerSpecs,
	FunFlags callerFlags,
	SymbolSet callerExterns,
	SpecInst* spec,
) {
	FunsInScope funsInScope = FunsInScope(callerSpecs, funsMap, ctx.importsAndReExports);
	CheckSpecsCtx checkSpecsCtx = CheckSpecsCtx(ctx.allocPtr, ctx.instantiateCtx, castNonScope_ref(funsInScope));
	return withRealTrace!Called(ctx, caller, diagRange, (scope RealTrace* trace) =>
		withExactStackArray!(Called, Called)(countSigs(*spec), (scope ref SpecImpls specImpls) {
			Opt!(Diag.SpecNoMatch) diag = checkSpecImplInner!(RealTrace*)(specImpls, checkSpecsCtx, trace, *spec);
			assert(spec.sigTypes.length == 1);
			if (has(diag)) {
				addDiag(ctx, diagRange, Diag(force(diag)));
				CalledSpecSig sig = CalledSpecSig(spec, 0);
				return Called(allocate(ctx.alloc, Called.Bogus(CalledDecl(sig), sig.returnType, sig.paramTypes)));
			} else {
				Called res = finish(specImpls)[$ - 1];
				LocalsInfo locals;
				bool ok = checkCalled(ctx, diagRange, res, callerFlags, callerExterns, locals, ArgsKind.nonEmpty, () =>
					allowsUnsafe(callerFlags.safety));
				return ok
					? res
					: Called(allocate(ctx.alloc, Called.Bogus(toCalledDecl(res), res.returnType, res.paramTypes)));
			}
		}));
}
private CalledDecl toCalledDecl(Called a) =>
	a.match!CalledDecl(
		(ref Called.Bogus x) =>
			x.decl,
		(ref FunInst x) =>
			CalledDecl(x.decl),
		(CalledSpecSig x) =>
			CalledDecl(x));

// Additional checks on a call after the overload and spec impls have been chosen.
bool checkCalled(
	ref CheckCtx ctx,
	Range diagRange,
	in Called called,
	FunFlags funFlags,
	SymbolSet externs,
	in LocalsInfo locals,
	ArgsKind argsKind,
	in bool delegate() @safe @nogc pure nothrow canDoUnsafe,
) =>
	called.match!bool(
		(ref Called.Bogus) =>
			true,
		(ref FunInst x) {
			markUsed(ctx, x.decl);
			checkCallFlags(ctx, diagRange, x.decl, funFlags, locals, argsKind, canDoUnsafe);
			return checkCallExterns(ctx, diagRange, x.decl, externs) && every!Called(x.specImpls, (in Called impl) =>
				checkCalled(ctx, diagRange, impl, funFlags, externs, locals, argsKind, canDoUnsafe));
		},
		(CalledSpecSig _) =>
			// For a spec, we do checks when providing the spec impl
			true);

enum ArgsKind { empty, nonEmpty }

private:

bool checkCallExterns(ref CheckCtx ctx, Range diagRange, FunDecl* called, SymbolSet externs) {
	bool ok = externs.containsAll(called.externs);
	if (!ok) {
		foreach (Symbol x; called.externs)
			if (x !in externs)
				addDiag(ctx, diagRange, Diag(Diag.CallMissingExtern(called, x)));
	}
	return ok;
}

void checkCallFlags(
	ref CheckCtx ctx,
	Range diagRange,
	FunDecl* called,
	FunFlags caller,
	in LocalsInfo locals,
	ArgsKind argsKind,
	in bool delegate() @safe @nogc pure nothrow canDoUnsafe,
) {
	void diag(Diag.CantCall.Reason reason) {
		addDiag(ctx, diagRange, Diag(Diag.CantCall(reason, called)));
	}
	if (!called.flags.bare && caller.bare && !called.flags.forceCtx && !isInLambda(locals))
		// TODO: need to explain this better in the case where 'bare' is due to the lambda
		diag(Diag.CantCall.Reason.nonBare);
	if (called.flags.summon && (!caller.summon || isInDataLambda(locals)))
		diag(!caller.summon ? Diag.CantCall.Reason.summon : Diag.CantCall.Reason.summonInDataLambda);
	if (called.flags.safety == FunFlags.Safety.unsafe && !canDoUnsafe())
		diag(Diag.CantCall.Reason.unsafe);
	if (called.isVariadic && argsKind == ArgsKind.nonEmpty && caller.bare)
		diag(Diag.CantCall.Reason.variadicFromBare);
}

Called checkCallSpecsWithRealTrace(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	FunsInScope funsInScope,
	Range range,
	ref const Candidate candidate,
) {
	CheckSpecsCtx checkSpecsCtx = CheckSpecsCtx(ctx.allocPtr, ctx.instantiateCtx, funsInScope);
	return withRealTrace!Called(ctx, typeContainer, range, (scope RealTrace* trace) =>
		getCalledFromCandidateAfterTypeChecks!(RealTrace*)(checkSpecsCtx, candidate, trace).match!Called(
			(Called x) => x,
			(Diag.SpecNoMatch x) {
				addDiag(ctx, range, Diag(x));
				return candidateBogusCalled(ctx.alloc, ctx.instantiateCtx, commonTypes, candidate);
			}));
}

struct CheckSpecsCtx {
	@safe @nogc pure nothrow:

	Alloc* allocPtr;
	InstantiateCtx instantiateCtx;
	FunsInScope funsInScope;
	bool hasErrors;

	ref Alloc alloc() =>
		*allocPtr;
}

alias SpecImpls = ExactSizeArrayBuilder!Called;

immutable struct SpecResult(NoMatch) {
	mixin Union!(Called, NoMatch);
}

// Avoid allocating trace for SpecNotFound errors (which will be ignored if another candidate succeeds)
struct DummyTrace {
	immutable struct NoMatch {}
	alias Result = SpecResult!NoMatch;
	uint depth;

	alias MultipleMatches = bool;
}
struct RealTrace {
	@safe @nogc pure nothrow:

	alias NoMatch = Diag.SpecNoMatch;
	alias Result = SpecResult!NoMatch;
	CheckCtx* ctx;
	TypeContainer typeContainer;
	Range range;
	MaxStackArray!FunDeclAndTypeArgs trace;

	alias MultipleMatches = ArrayBuilder!Called;
}
T withRealTrace(T)(
	ref CheckCtx ctx,
	TypeContainer typeContainer,
	Range range,
	in T delegate(scope RealTrace*) @safe @nogc pure nothrow cb,
) =>
	withMaxStackArray!(T, FunDeclAndTypeArgs)(
		maxSpecDepth,
		(scope ref MaxStackArray!FunDeclAndTypeArgs stack) @trusted {
			RealTrace trace = RealTrace(&ctx, typeContainer, range, stack.move());
			return cb(&trace);
		});

T withTrace(T)(
	DummyTrace trace,
	FunDeclAndTypeArgs,
	in T delegate(scope DummyTrace) @safe @nogc pure nothrow cb,
) =>
	cb(DummyTrace(trace.depth + 1));
T withTrace(T)(
	scope RealTrace* trace,
	FunDeclAndTypeArgs called,
	in T delegate(scope RealTrace*) @safe @nogc pure nothrow cb,
) {
	trace.trace ~= called;
	T res = cb(trace);
	trace.trace.mustPop;
	return res;
}

void specMatchError(ref CheckSpecsCtx ctx, scope DummyTrace, Diag.SpecMatchError.Reason) {
	ctx.hasErrors = true;
}
void specMatchError(ref CheckSpecsCtx ctx, scope RealTrace* a, Diag.SpecMatchError.Reason reason) {
	ctx.hasErrors = true;
	addDiag(*a.ctx, a.range, Diag(Diag.SpecMatchError(a.typeContainer, reason, newArray(a.ctx.alloc, a.trace.soFar))));
}

DummyTrace.NoMatch specNoMatch(scope DummyTrace, Diag.SpecNoMatch.Reason) =>
	DummyTrace.NoMatch();
RealTrace.NoMatch specNoMatch(scope RealTrace* a, Diag.SpecNoMatch.Reason reason) =>
	Diag.SpecNoMatch(a.typeContainer, reason, newArray(a.ctx.alloc, a.trace.soFar));
bool isFull(DummyTrace trace) {
	assert(trace.depth <= maxSpecDepth);
	return trace.depth == maxSpecDepth;
}
bool isFull(in RealTrace* trace) =>
	trace.trace.isFull;

Trace.Result checkCandidate(Trace)(
	ref CheckSpecsCtx ctx,
	Signature* sigDecl,
	ReturnAndParamTypes sigType,
	ref Candidate candidate,
	scope Trace trace,
) =>
	testCandidateForSpecSig(ctx.instantiateCtx, candidate, sigType, TypeContext.nonInferring)
		? getCalledFromCandidateAfterTypeChecks(ctx, candidate, trace)
		: Trace.Result(specNoMatch(trace, Diag.SpecNoMatch.Reason(
			Diag.SpecNoMatch.Reason.SpecImplNotFound(sigDecl, sigType))));

Trace.Result getCalledFromCandidateAfterTypeChecks(Trace)(
	ref CheckSpecsCtx ctx,
	ref const Candidate candidate,
	scope Trace trace,
) =>
	withMapOrNoneToStackArray!(Trace.Result, Type, SingleInferringType)(
		candidate.typeArgs,
		(ref const SingleInferringType x) =>
			tryGetInferred(x),
		(scope Type[] candidateTypeArgs) =>
			candidate.called.matchWithPointers!(Trace.Result)(
				(FunDecl* f) =>
					isFull(trace)
						? Trace.Result(specNoMatch(trace, Diag.SpecNoMatch.Reason(Diag.SpecNoMatch.Reason.TooDeep())))
						: withExactStackArray!(Trace.Result, Called)(countSpecSigs(*f), (scope ref SpecImpls out_) {
							Opt!(Trace.NoMatch) diag = checkSpecImpls!Trace(
								out_, ctx, f, small!Type(candidateTypeArgs), trace);
							return has(diag)
								? Trace.Result(force(diag))
								: Trace.Result(Called(instantiateFun(
									ctx.instantiateCtx, f,
									small!Type(candidateTypeArgs),
									smallFinish(out_))));
						}),
				(CalledSpecSig s) =>
					Trace.Result(Called(s))),
		() =>
			Trace.Result(specNoMatch(trace, Diag.SpecNoMatch.Reason(
				Diag.SpecNoMatch.Reason.CantInferTypeArguments(candidate.called.as!(FunDecl*))))));

size_t countSpecSigs(in FunDecl a) =>
	sum(a.specs, (in SpecInst* x) =>
		countSigs(*x));

bool deeper(DummyTrace.NoMatch, DummyTrace.NoMatch) =>
	false;
bool deeper(Diag.SpecNoMatch a, Diag.SpecNoMatch b) =>
	a.trace.length > b.trace.length;

void addMultipleMatch(ref CheckSpecsCtx, DummyTrace, ref bool b, Called) {
	b = true;
}
bool hasMultipleMatches(DummyTrace, bool b) =>
	b;
Called[] finishMultipleMatches(ref CheckSpecsCtx ctx, scope DummyTrace, bool) =>
	[];

void addMultipleMatch(ref CheckSpecsCtx ctx, scope RealTrace* trace, ref ArrayBuilder!Called builder, Called match) {
	add(ctx.alloc, builder, match);
}
bool hasMultipleMatches(scope RealTrace*, in ArrayBuilder!Called builder) =>
	!arrayBuilderIsEmpty(builder);
Called[] finishMultipleMatches(ref CheckSpecsCtx ctx, scope RealTrace*, ref ArrayBuilder!Called builder) =>
	finish(ctx.alloc, builder);

Trace.Result findSpecSigImplementation(Trace)(
	ref CheckSpecsCtx ctx,
	Signature* sigDecl,
	ReturnAndParamTypes sigType,
	scope Trace trace,
) {
	Cell!(Opt!Called) res;
	Trace.MultipleMatches multipleMatches;
	Cell!(Opt!(Trace.NoMatch)) deepestNoMatch = Cell!(Opt!(Trace.NoMatch))();
	eachCandidate(ctx.funsInScope, sigDecl.name, sigType.paramTypes.length, (ref Candidate candidate) {
		checkCandidate(ctx, sigDecl, sigType, candidate, trace).match!void(
			(Called x) {
				if (has(cellGet(res)))
					addMultipleMatch(ctx, trace, multipleMatches, x);
				else
					cellSet(res, some(x));
			},
			(Trace.NoMatch x) {
				if (!has(cellGet(deepestNoMatch)) || deeper(x, force(cellGet(deepestNoMatch))))
					cellSet(deepestNoMatch, some(x));
			});
	});
	if (has(cellGet(res))) {
		if (hasMultipleMatches(trace, multipleMatches)) {
			addMultipleMatch(ctx, trace, multipleMatches, force(cellGet(res)));
			specMatchError(ctx, trace, Diag.SpecMatchError.Reason(Diag.SpecMatchError.Reason.MultipleMatches(
				sigDecl.name, finishMultipleMatches(ctx, trace, multipleMatches))));
		}
		return Trace.Result(force(cellGet(res)));
	} else
		return Trace.Result(has(cellGet(deepestNoMatch))
			? force(cellGet(deepestNoMatch))
			: specNoMatch(trace, Diag.SpecNoMatch.Reason(Diag.SpecNoMatch.Reason.SpecImplNotFound(sigDecl, sigType))));
}

bool checkBuiltinSpec(ref CheckSpecsCtx ctx, BuiltinSpec kind, Type typeArg) {
	final switch (kind) {
		case BuiltinSpec.data:
			return isPurityAlwaysCompatibleConsideringSpecs(ctx.funsInScope.outermostFunSpecs, typeArg, Purity.data);
		case BuiltinSpec.shared_:
			return isPurityAlwaysCompatibleConsideringSpecs(ctx.funsInScope.outermostFunSpecs, typeArg, Purity.shared_);
	}
}

bool someSpecIncludingParents(in SpecInst inst, in bool delegate(in SpecInst) @safe @nogc pure nothrow cb) =>
	cb(inst) ||
	exists(inst.parents, (in SpecInst* parent) =>
		someSpecIncludingParents(*parent, cb));

Purity purityOfBuiltinSpec(BuiltinSpec kind) {
	final switch (kind) {
		case BuiltinSpec.data:
			return Purity.data;
		case BuiltinSpec.shared_:
			return Purity.shared_;
	}
}

// Whether 'inst' tells us that 'type' has purity at least 'expected'
bool specProvidesPurity(in SpecInst inst, in Type type, Purity expected) =>
	someSpecIncludingParents(inst, (in SpecInst x) =>
		has(x.decl.builtin) &&
		only(x.typeArgs) == type &&
		builtinSpecProvidesPurity(force(x.decl.builtin), expected));

bool builtinSpecProvidesPurity(BuiltinSpec kind, Purity expected) =>
	isPurityCompatible(expected, purityOfBuiltinSpec(kind));

Opt!(Trace.NoMatch) checkSpecImpls(Trace)(
	scope ref SpecImpls res,
	ref CheckSpecsCtx ctx,
	FunDecl* called,
	in TypeArgs calledTypeArgs,
	scope Trace trace,
) =>
	first!(Trace.NoMatch, immutable SpecInst*)(called.specs, (SpecInst* specInst) =>
		// specInst was instantiated potentially based on f's params.
		// Meed to instantiate it again.
		checkSpecImpl!Trace(res, ctx, called, trace, *instantiateSpecInst(
			ctx.instantiateCtx, specInst, calledTypeArgs, noDelaySpecInsts)));

Opt!(Trace.NoMatch) checkSpecImpl(Trace)(
	scope ref SpecImpls res,
	ref CheckSpecsCtx ctx,
	FunDecl* called,
	scope Trace outerTrace,
	in SpecInst specInstInstantiated,
) =>
	withTrace!(Opt!(Trace.NoMatch))(
		outerTrace, FunDeclAndTypeArgs(called, specInstInstantiated.typeArgs), (scope Trace trace) =>
			checkSpecImplInner(res, ctx, trace, specInstInstantiated));

Opt!(Trace.NoMatch) checkSpecImplInner(Trace)(
	scope ref SpecImpls res,
	ref CheckSpecsCtx ctx,
	scope Trace trace,
	in SpecInst specInstInstantiated,
) {
	SpecDecl* decl = specInstInstantiated.decl;
	TypeArgs typeArgs = specInstInstantiated.typeArgs;
	return optOr!(Trace.NoMatch)(
		optIf(has(decl.builtin) && !checkBuiltinSpec(ctx, force(decl.builtin), only(typeArgs)),
			() => specNoMatch(trace, Diag.SpecNoMatch.Reason(
				Diag.SpecNoMatch.Reason.BuiltinNotSatisfied(force(decl.builtin), only(typeArgs))))),
		() => first!(Trace.NoMatch, immutable SpecInst*)(
			specInstInstantiated.parents, (SpecInst* parent) =>
				checkSpecImplInner!Trace(res, ctx, trace, *parent)),
		() => firstZipPointerFirst!(Trace.NoMatch, Signature, ReturnAndParamTypes)(
			decl.sigs, specInstInstantiated.sigTypes,
			(Signature* sigDecl, ReturnAndParamTypes sigType) =>
				findSpecSigImplementation(ctx, sigDecl, sigType, trace).match!(Opt!(Trace.NoMatch))(
					(Called x) {
						res ~= x;
						return none!(Trace.NoMatch);
					},
					(Trace.NoMatch x) =>
						some(x))));
}
