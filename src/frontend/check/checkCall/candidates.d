module frontend.check.checkCall.candidates;

@safe @nogc pure nothrow:

import frontend.check.checkCtx : CheckCtx, eachImportAndReExport, ImportAndReExportModules;
import frontend.check.exprCtx : ExprCtx;
import frontend.check.inferringType :
	matchTypes,
	nonInferring,
	SingleInferringType,
	tryGetNonInferringType,
	TypeAndContext,
	TypeContext;
import frontend.check.instantiate : InstantiateCtx, makeArrayType;
import frontend.check.maps : FunsMap;
import model.model :
	arityMatches,
	Called,
	CalledBogus,
	CalledDecl,
	CalledSpecSig,
	CommonTypes,
	Destructure,
	eachCalledSpecSig,
	ExportVisibility,
	FunDecl,
	importCanSee,
	NameReferents,
	Params,
	ReturnAndParamTypes,
	SpecInst,
	Type,
	Varargs;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : pushStackArray, StackArrayBuilder, withBuildStackArray, withRestoreStack;
import util.col.array : everyWithIndex, filterUnordered, map, makeArray, MutSmallArray, newArray, small;
import util.col.arrayBuilder : buildArray, Builder;
import util.memory : allocate;
import util.opt : force, has, Opt, optOrDefault;
import util.symbol : Symbol;

CalledDecl[] candidatesForDiag(ref Alloc alloc, in Candidate[] candidates) =>
	map(alloc, candidates, (ref const Candidate c) => c.called);

CalledDecl[] getAllCandidatesAsCalledDecls(ref ExprCtx ctx, Symbol funName) =>
	buildArray!CalledDecl(ctx.alloc, (scope ref Builder!CalledDecl res) {
		eachFunInExprScope(ctx, funName, (CalledDecl called) {
			res ~= called;
		});
	});

struct Candidate {
	immutable CalledDecl called;
	// This is always empty if calling a CalledSpecSig
	MutSmallArray!SingleInferringType typeArgs;
}

inout(TypeContext) typeContextForCandidate(ref inout Candidate a) =>
	inout TypeContext(a.typeArgs);

T withCandidates(T)(
	in FunsInScope funs,
	Symbol funName,
	size_t actualArity,
	in bool delegate(ref Candidate) @safe @nogc pure nothrow cbFilterCandidate,
	in T delegate(scope Candidate[]) @safe @nogc pure nothrow cb,
) =>
	withBuildStackArray!(T, Candidate)(
		(ref StackArrayBuilder!Candidate out_) {
			eachFunInScope(funs, funName, (CalledDecl called) {
				if (arityMatches(called.arity, actualArity))
					out_ ~= Candidate(called);
			});
		},
		(scope Candidate[] candidates) {
			foreach (ref Candidate x; candidates)
				initializeCandidateTypeArgs(x);
			filterUnordered(candidates, cbFilterCandidate);
			return cb(candidates);
		});

private void initializeCandidateTypeArgs(ref Candidate a) {
	a.typeArgs = small!SingleInferringType(
		pushStackArray!SingleInferringType(a.called.typeParams.length, (size_t i) => SingleInferringType()));
}

void eachCandidate(
	in FunsInScope funs,
	Symbol funName,
	size_t actualArity,
	in void delegate(ref Candidate) @safe @nogc pure nothrow cb,
) {
	eachFunInScope(funs, funName, (CalledDecl called) {
		if (arityMatches(called.arity, actualArity))
			withRestoreStack(() {
				Candidate candidate = Candidate(called);
				initializeCandidateTypeArgs(candidate);
				cb(candidate);
			});
	});
}

struct FunsInScope {
	immutable SpecInst*[] outermostFunSpecs;
	immutable FunsMap funsMap;
	ImportAndReExportModules importsAndReExports;
}
FunsInScope funsInNonExprScope(ref CheckCtx ctx, FunsMap funsMap) =>
	FunsInScope([], funsMap, ctx.importsAndReExports);
FunsInScope funsInExprScope(ref ExprCtx ctx) =>
	FunsInScope(ctx.outermostFunSpecs, ctx.funsMap, ctx.checkCtx.importsAndReExports);

private void eachFunInExprScope(
	ref ExprCtx ctx,
	Symbol funName,
	in void delegate(CalledDecl) @safe @nogc pure nothrow cb,
) {
	eachFunInScope(funsInExprScope(ctx), funName, cb);
}
void eachFunInScope(
	in FunsInScope a,
	Symbol funName,
	in void delegate(CalledDecl) @safe @nogc pure nothrow cb,
) {
	foreach (SpecInst* specInst; a.outermostFunSpecs)
		eachFunInScopeForSpec(specInst, funName, cb);

	Opt!(immutable FunDecl*[]) funs = a.funsMap[funName];
	if (has(funs))
		foreach (FunDecl* f; force(funs))
			cb(CalledDecl(f));

	eachImportAndReExport(a.importsAndReExports, funName, (ExportVisibility visibility, in NameReferents x) {
		foreach (FunDecl* f; x.funs)
			if (importCanSee(visibility, f.visibility))
				cb(CalledDecl(f));
	});
}

bool testCandidateForSpecSig(
	InstantiateCtx ctx,
	ref Candidate specCandidate,
	in ReturnAndParamTypes returnAndParamTypes,
	const TypeContext callTypeContext,
) {
	bool res = matchTypes(
		ctx,
		TypeAndContext(specCandidate.called.returnType, typeContextForCandidate(specCandidate)),
		const TypeAndContext(returnAndParamTypes.returnType, callTypeContext));
	return res && everyWithIndex!Type(returnAndParamTypes.paramTypes, (size_t argIdx, ref Type paramType) =>
		testCandidateParamType(ctx, specCandidate, argIdx, const TypeAndContext(paramType, callTypeContext)));
}

// Also does type inference on the candidate
bool testCandidateParamType(
	InstantiateCtx ctx,
	ref Candidate candidate,
	size_t argIdx,
	const TypeAndContext actualArgType,
) =>
	matchTypes(ctx, getCandidateExpectedParameterType(ctx, candidate, argIdx), actualArgType);

@trusted inout(TypeAndContext) getCandidateExpectedParameterType(
	InstantiateCtx ctx,
	ref inout Candidate candidate,
	size_t argIndex,
) {
	Type declType = paramTypeAt(candidate.called, argIndex);
	Opt!Type instantiated = tryGetNonInferringType(
		ctx, inout TypeAndContext(declType, typeContextForCandidate(candidate)));
	return has(instantiated)
		? cast(inout) nonInferring(force(instantiated))
		: inout TypeAndContext(declType, typeContextForCandidate(candidate));
}

Called candidateBogusCalled(
	ref Alloc alloc,
	InstantiateCtx instantiateCtx,
	ref CommonTypes commonTypes,
	ref const Candidate candidate,
) {
	Type returnType = getCandidateTypeOrBogus(instantiateCtx, candidate, candidate.called.returnType);
	Type[] paramTypes = candidate.called.isVariadic
		? newArray!Type(alloc, [
			Type(makeArrayType(
				instantiateCtx, commonTypes,
				getCandidateTypeOrBogus(instantiateCtx, candidate, paramTypeAt(candidate.called, 0)))),
		])
		: makeArray(alloc, candidate.called.arity.countParamDecls, (size_t i) =>
			getCandidateTypeOrBogus(instantiateCtx, candidate, paramTypeAt(candidate.called, i)));
	return Called(allocate(alloc, CalledBogus(candidate.called, returnType, paramTypes)));
}

private Type getCandidateTypeOrBogus(InstantiateCtx ctx, ref const Candidate candidate, Type declaredType) {
	Opt!Type res = tryGetNonInferringType(ctx, const TypeAndContext(declaredType, typeContextForCandidate(candidate)));
	return optOrDefault!Type(res, () => Type.bogus);
}

private Type paramTypeAt(CalledDecl called, size_t argIndex) =>
	called.match!Type(
		(ref FunDecl f) =>
			paramTypeAt(f.params, argIndex),
		(CalledSpecSig s) =>
			s.paramTypes[argIndex]);

private Type paramTypeAt(in Params params, size_t argIndex) =>
	params.matchIn!Type(
		(in Destructure[] x) =>
			x[argIndex].type,
		(in Varargs x) =>
			x.elementType);

private void eachFunInScopeForSpec(
	SpecInst* specInst,
	Symbol funName,
	in void delegate(CalledDecl) @safe @nogc pure nothrow cb,
) {
	eachCalledSpecSig(specInst, (CalledSpecSig x) {
		if (x.name == funName)
			cb(CalledDecl(x));
	});
}
