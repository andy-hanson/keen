module backend.js.allUsed;

@safe @nogc pure nothrow:

import backend.js.jsAst : SyncOrAsync;
import model.constant : Constant;
import model.model :
	AnyDecl,
	asExtern,
	AssertOrForbidExpr,
	AutoFun,
	BogusCallExpr,
	BogusExpr,
	BogusWrongTypeExpr,
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
	CallOptionExpr,
	CalledSpecSig,
	CallExpr,
	ClosureGetExpr,
	ClosureSetExpr,
	CommonTypes,
	Condition,
	Destructure,
	eachDirectChildExpr,
	eachImportOrReExport,
	eachSpecSigAndImpl,
	eachLocal,
	eachTest,
	evalExternCondition,
	Expr,
	ExprRef,
	ExternCondition,
	ExternExpr,
	FinallyExpr,
	FlagsFunction,
	FunBody,
	funBodyExprRef,
	FunDecl,
	FunInst,
	FunKind,
	FunPointerExpr,
	getCalledAtExpr,
	IfExpr,
	ImportOrExport,
	isBuiltinType,
	JsFun,
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
	MainFun,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchSumTypeCase,
	MatchSumTypeExpr,
	methodCaller,
	Module,
	moduleAtUri,
	mustUnwrapOptionType,
	nameFromNameReferentsPointer,
	NameReferents,
	paramsArray,
	Program,
	ProgramWithMain,
	RecordField,
	RecordFieldPointerExpr,
	SeqExpr,
	Signature,
	SpecInst,
	StructAlias,
	StructBody,
	StructDecl,
	StructInst,
	StructOrAlias,
	SumTypeMembership,
	SumTypeKind,
	SumTypeMemberAndMethodImpls,
	Test,
	testBodyExprRef,
	TestSelector,
	ThrowExpr,
	TryExpr,
	TryLetExpr,
	Type,
	TypedExpr,
	TypeParamIndex;
import util.alloc.alloc : Alloc;
import util.col.array : exists, zipPointers;
import util.col.hashTable : existsInHashTable;
import util.col.map : Map;
import util.col.mutArr : mustPop, MutArr, mutArrIsEmpty, push;
import util.col.mutMap : getOrAdd, mapToMap, MutMap;
import util.col.mutMultiMap : add, eachValueForKey, MutMultiMap;
import util.col.mutSet : mayAddToMutSet, MutSet;
import util.col.set : moveToSet, Set;
import util.hash : HashCode, hashPointers;
import util.opt : force, has, none, Opt, optIf, some;
import util.symbol : Symbol;
import util.symbolSet : SymbolSet;
import util.union_ : TaggedUnion;
import util.uri : Uri;
import util.util : ptrTrustMe;
import versionInfo : isVersion, VersionInfo, VersionFun;

immutable struct FunOrTest {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(FunDecl*, Test*);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in FunDecl x) =>
				x.moduleUri,
			(in Test x) =>
				x.moduleUri);

	Symbol name() scope =>
		matchIn!Symbol(
			(in FunDecl x) =>
				x.name,
			(in Test x) =>
				x.name);
}

// This does not include FunDecl if the body would be inlined
immutable struct AllUsed {
	// Maps a module to decls it uses.
	Map!(Uri, Set!AnyDecl) usedByModule;
	Set!AnyDecl usedDecls;
	private AsyncSets async;
}
bool isUsedAnywhere(in AllUsed a, in AnyDecl x) =>
	x in a.usedDecls;
bool isModuleUsed(in AllUsed a, Module* module_) {
	// TODO: PERF
	foreach (AnyDecl x; a.usedDecls) {
		if (x.moduleUri == module_.uri)
			return true;
	}
	return exists!ImportOrExport(module_.reExports, (in ImportOrExport reExport) =>
		reExport.hasImported &&
		existsInHashTable!(NameReferents*, Symbol, nameFromNameReferentsPointer)(
			reExport.imported,
			(in NameReferents* refs) =>
				existsNameReferent(*refs, (AnyDecl decl) => isUsedAnywhere(a, decl))));
}

bool isUsedInModule(in AllUsed a, Uri module_, in AnyDecl x) {
	Opt!(Set!AnyDecl) set = a.usedByModule[module_];
	return has(set) && x in force(set);
}

private immutable struct AsyncSets {
	Set!(FunDecl*) asyncFuns;
	Set!(FunAndSpecSig) asyncSpecSigs;
}
SyncOrAsync isAsyncFun(in AllUsed a, FunDecl* fun) =>
	fun in a.async.asyncFuns ? SyncOrAsync.async : SyncOrAsync.sync;
SyncOrAsync isAsyncCall(in AllUsed a, in FunDecl* caller, in Called called) =>
	isAsyncCall(a, FunOrTest(caller), called);
SyncOrAsync isAsyncCall(in AllUsed a, in FunOrTest caller, in Called called) =>
	called.matchIn!SyncOrAsync(
		(in Called.Bogus) =>
			SyncOrAsync.sync,
		(in FunInst x) =>
			isAsyncFun(a, x.decl),
		(in CalledSpecSig x) =>
			FunAndSpecSig(caller.as!(FunDecl*), x.nonInstantiatedSig) in a.async.asyncSpecSigs
				? SyncOrAsync.async
				: SyncOrAsync.sync);

AllUsed allUsed(ref Alloc alloc, ref ProgramWithMain program, VersionInfo version_, SymbolSet allExterns) {
	AllUsedBuilder res = AllUsedBuilder(
		ptrTrustMe(alloc), ptrTrustMe(program.program), program.testSelector, version_, allExterns);
	trackAllUsedInMain(res, program);

	// Add used aliases
	foreach (Uri moduleUri, ref MutSet!AnyDecl used; res.usedByModule) {
		eachStructAliasInImports(*moduleAtUri(program.program, moduleUri), (StructAlias* alias_, StructDecl* target) {
			if (AnyDecl(target) in res.usedDecls) {
				mayAddToMutSet(alloc, used, AnyDecl(alias_));
				mayAddToMutSet(alloc, res.usedDecls, AnyDecl(alias_));
			}
		});
	}

	return AllUsed(
		mapToMap!(Uri, Set!AnyDecl, MutSet!AnyDecl)(alloc, res.usedByModule, (ref MutSet!AnyDecl x) =>
			moveToSet(x)),
		moveToSet(res.usedDecls),
		allAsyncFuns(res));
}


void eachStructAliasInImports(
	in Module module_,
	in void delegate(StructAlias*, StructDecl*) @safe @nogc pure nothrow cb,
) {
	eachNameReferentInImports(module_, (AnyDecl decl) {
		if (decl.isA!(StructAlias*))
			cb(decl.as!(StructAlias*), decl.as!(StructAlias*).target.decl);
	});
}

private void eachNameReferentInImports(in Module module_, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	eachImportOrReExport(module_, (ref ImportOrExport x) {
		if (!x.hasImported) return;
		foreach (ref immutable NameReferents* refs; x.imported)
			eachNameReferent(*refs, cb);
	});
}

bool isInlined(in Called a) =>
	a.isA!(FunInst*) && bodyIsInlined(*a.as!(FunInst*).decl);
bool bodyIsInlined(in FunDecl a) =>
	!bodyIsNotInlined(a.body_);
private bool bodyIsNotInlined(in FunBody a) =>
	a.isA!AutoFun ||
	a.isA!Expr ||
	a.isA!(FunBody.FileImport) ||
	a.isA!(FunBody.SumTypeMemberGet) ||
	(a.isA!BuiltinFun && !isInlinedBuiltinFun(a.as!BuiltinFun));
private bool isInlinedBuiltinFun(in BuiltinFun a) =>
	a.matchIn!bool(
		(in BuiltinFun.AllTests) =>
			false,
		(in BuiltinUnary _) =>
			true,
		(in BuiltinUnaryMath x) {
			switch (x) {
				case BuiltinUnaryMath.roundFloat32:
				case BuiltinUnaryMath.roundFloat64:
					return false;
				default:
					return true;
			}
		},
		(in BuiltinBinary _) =>
			true,
		(in BuiltinBinaryLazy _) =>
			true,
		(in BuiltinBinaryMath _) =>
			true,
		(in BuiltinTernary _) =>
			true,
		(in Builtin4ary _) =>
			true,
		(in BuiltinFun.CallLambda) =>
			true,
		(in BuiltinFun.CallFunPointer) =>
			true,
		(in Constant _) =>
			true,
		(in BuiltinFun.GcSafeValue) =>
			true,
		(in BuiltinFun.Init) =>
			true,
		(in JsFun _) =>
			true,
		(in BuiltinFun.MarkRoot) =>
			assert(false),
		(in BuiltinFun.MarkVisit) =>
			assert(false),
		(in BuiltinFun.NewEmptyOption) =>
			true,
		(in BuiltinFun.NewNonEmptyOption) =>
			true,
		(in BuiltinFun.PointerCast) =>
			assert(false),
		(in BuiltinFun.SizeOf) =>
			assert(false),
		(in BuiltinFun.StaticSymbols) =>
			assert(false),
		(in VersionFun _) =>
			assert(false));

Opt!bool tryEvalConstantBool(in VersionInfo version_, in SymbolSet allExterns, in Condition a) {
	if (a.isA!(Expr*)) {
		Expr* x = a.as!(Expr*);
		if (x.kind.isA!CallExpr) {
			Called y = x.kind.as!CallExpr.called;
			if (y.isA!(FunInst*)) {
				FunDecl* decl = y.as!(FunInst*).decl;
				if (decl.body_.isA!BuiltinFun) {
					BuiltinFun bf = decl.body_.as!BuiltinFun;
					if (bf.isA!VersionFun)
						return some(isVersion(version_, bf.as!VersionFun));
				}
			}
		}
	}

	Opt!ExternCondition extern_ = asExtern(a);
	return optIf(has(extern_), () => evalExternCondition(force(extern_), allExterns));
}

void eachNameReferent(NameReferents a, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	cast(void) existsNameReferent(a, (AnyDecl x) {
		cb(x);
		return false;
	});
}
private bool existsNameReferent(NameReferents a, in bool delegate(AnyDecl) @safe @nogc pure nothrow cb) =>
	(has(a.structOrAlias) && cb(toAnyDecl(force(a.structOrAlias)))) ||
	(has(a.spec) && cb(AnyDecl(force(a.spec)))) ||
	exists!(immutable FunDecl*)(a.funs, (in FunDecl* x) => cb(AnyDecl(x)));

private:

AnyDecl toAnyDecl(StructOrAlias a) =>
	a.matchWithPointers!AnyDecl(
		(StructAlias* x) => AnyDecl(x),
		(StructDecl* x) => AnyDecl(x));

AsyncSets allAsyncFuns(ref AllUsedBuilder builder) {
	MutSet!(FunDecl*) asyncFuns;
	MutSet!(FunAndSpecSig) asyncSpecSigs;
	MutArr!(FunDecl*) funsToProcess;

	bool addFun(FunDecl* x) {
		bool res = mayAddToMutSet(builder.alloc, asyncFuns, x);
		if (res)
			push(builder.alloc, funsToProcess, x);
		return res;
	}

	addFun(builder.program.commonFuns.jsAwait.decl);
	foreach (FunKind _, ref immutable FunDecl* f; builder.program.commonFuns.lambdaSubscript)
		addFun(f);

	void recurFunAndSpecSig(FunAndSpecSig x) @safe @nogc nothrow {
		addFun(x.fun);
		if (mayAddToMutSet(builder.alloc, asyncSpecSigs, x)) {
			eachValueForKey(builder.specSigToUsedAsSpecImpl, x, (FunAndSpecSig y) {
				recurFunAndSpecSig(y);
			});
		}
	}

	while (!mutArrIsEmpty(funsToProcess)) {
		FunDecl* fun = mustPop(funsToProcess);
		eachValueForKey(builder.funToCallers, fun, (FunDecl* caller) {
			addFun(caller);
		});
		eachValueForKey(builder.funToUsedAsSpecImpl, fun, (FunAndSpecSig x) {
			recurFunAndSpecSig(x);
		});
	}

	return AsyncSets(moveToSet(asyncFuns), moveToSet(asyncSpecSigs));
}

struct AllUsedBuilder {
	@safe @nogc pure nothrow:

	Alloc* allocPtr;
	immutable Program* program;
	immutable TestSelector testSelector;
	immutable VersionInfo version_;
	immutable SymbolSet allExterns;
	MutMap!(Uri, MutSet!AnyDecl) usedByModule;
	MutSet!AnyDecl usedDecls;

	// Map from each function to all functions that directly call it.
	MutMultiMap!(FunDecl*, FunDecl*) funToCallers;
	// Maps a function to where it is used as a spec implementation.
	MutMultiMap!(FunDecl*, FunAndSpecSig) funToUsedAsSpecImpl;
	// Maps a spec signature in a function to spec signagures in other functions that are used to implement it.
	MutMultiMap!(FunAndSpecSig, FunAndSpecSig) specSigToUsedAsSpecImpl;

	ref Alloc alloc() =>
		*allocPtr;
	ref CommonTypes commonTypes() =>
		program.commonTypes;
}
immutable struct FunAndSpecSig {
	@safe @nogc pure nothrow:

	FunDecl* fun;
	Signature* specSig;

	HashCode hash() scope =>
		hashPointers(fun, specSig);
}

bool addDecl(ref AllUsedBuilder res, Uri from, AnyDecl used) {
	if (used.isA!(StructDecl*) && used.as!(StructDecl*).body_.isA!BuiltinType) {
		assert(false); // 0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
	}

	MutSet!AnyDecl* perModule = &getOrAdd(res.alloc, res.usedByModule, from, () => MutSet!AnyDecl());
	return mayAddToMutSet(res.alloc, *perModule, used) && mayAddToMutSet(res.alloc, res.usedDecls, used);
}

void trackAllUsedInType(ref AllUsedBuilder res, Uri from, Type a) {
	a.match!void(
		(Type.Bogus) {},
		(TypeParamIndex _) {},
		(ref StructInst x) {
			if (!x.decl.body_.isA!BuiltinType)
				// Don't need to track type args since they are erased
				trackAllUsedInStruct(res, from, x.decl);
		});
}
void trackAllUsedInStruct(ref AllUsedBuilder res, Uri from, StructDecl* a) {
	if (!isBuiltinType(*a) && addDecl(res, from, AnyDecl(a))) {
		trackAllUsedInStructBody(res, a.moduleUri, a.body_);
		foreach (SumTypeMembership x; a.sumTypeMemberships) {
			trackAllUsedInStruct(res, a.moduleUri, x.sumType.decl);
			zipPointers(x.sumTypeDeclMethods, x.methodImpls, (Signature* method, Opt!Called* impl) {
				if (has(*impl))
					trackAllUsedInCalled(
						res, a.moduleUri,
						FunOrTest(methodCaller(*res.program, method)),
						force(*impl), FunUse.regular);
			});
		}
	}
}

void trackAllUsedInStructBody(ref AllUsedBuilder res, Uri from, in StructBody a) {
	a.match!void(
		(StructBody.Bogus) {},
		(BuiltinType _) {},
		(ref StructBody.Enum) {
			// 'members' constructs pairs
			trackAllUsedInStruct(res, from, res.program.commonTypes.pair);
		},
		(StructBody.Extern) {},
		(StructBody.Flags) {
			// 'members' constructs pairs
			trackAllUsedInStruct(res, from, res.program.commonTypes.pair);
		},
		(StructBody.Record record) {
			foreach (RecordField field; record.fields)
				trackAllUsedInType(res, from, field.type);
		},
		(StructBody.SumType x) {
			if (x.kind == SumTypeKind.union_) {
				foreach (SumTypeMemberAndMethodImpls member; x.listedMembers)
					trackAllUsedInStruct(res, from, member.member.decl);
			}
		});
}

void trackAllUsedInMain(ref AllUsedBuilder res, ref ProgramWithMain a) {
	FunDecl* fun = actualMainFun(a);
	trackAllUsedInFun(res, fun.moduleUri, fun, FunUse.noInline);
}

public FunDecl* actualMainFun(ref ProgramWithMain a) =>
	a.mainFun.matchIn!(FunDecl*)(
		(in MainFun.Nat64OfArgs x) =>
			x.fun.decl,
		(in MainFun.Void x) =>
			x.fun.decl,
		(in TestSelector _) =>
			a.program.commonFuns.runAllTests.decl);

enum FunUse { regular, noInline }
void trackAllUsedInFun(ref AllUsedBuilder res, Uri from, FunDecl* a, FunUse use) {
	// An inlined function isn't considered 'used', but its type is
	bool inlined = () {
		final switch (use) {
			case FunUse.regular:
				return bodyIsInlined(*a);
			case FunUse.noInline:
				return false;
		}
	}();
	if (inlined || addDecl(res, from, AnyDecl(a))) {
		Uri typesUsedAt = inlined ? from : a.moduleUri;

		foreach (ref Destructure param; paramsArray(a.params))
			eachLocal(param, (Local* x) {
				trackAllUsedInType(res, typesUsedAt, x.type);
			});

		void usedReturnType() {
			trackAllUsedInType(res, typesUsedAt, a.returnType);
		}
		a.body_.match!void(
			(FunBody.Bogus) {},
			(AutoFun x) {
				final switch (x.kind) {
					case AutoFun.Kind.equals:
					case AutoFun.Kind.enumOrFlagsMembers:
					case AutoFun.Kind.enumOrFlagsToIntegral:
					case AutoFun.Kind.enumToSymbol:
					case AutoFun.Kind.flagsToSymbolArray:
					case AutoFun.Kind.compare:
					case AutoFun.Kind.symbolToOptEnumOrFlags:
						break;
					case AutoFun.Kind.toJson:
						trackAllUsedInCalled(
							res, a.moduleUri, FunOrTest(a),
							Called(res.program.commonFuns.newJsonFromPairs),
							FunUse.regular);
						break;
				}
				usedReturnType();
				foreach (Called called; x.members)
					trackAllUsedInCalled(res, a.moduleUri, FunOrTest(a), called, FunUse.regular);
			},
			(BuiltinFun x) {
				if (x.isA!(BuiltinFun.AllTests)) {
					eachTest(*res.program, res.allExterns, res.testSelector, (Test* test) {
						trackAllUsedInTest(res, from, test);
					});
				} else if (x.isA!(BuiltinFun.CallLambda))
					usedTuple(res, from, a.arity.as!uint - 1);
			},
			(FunBody.CreateEnumOrFlags) {
				usedReturnType();
			},
			(FunBody.CreateExtern) {
				assert(false);
			},
			(FunBody.CreateRecord) {
				usedReturnType();
			},
			(FunBody.CreateRecordAndConvertToSumType x) {
				usedReturnType();
				trackAllUsedInStruct(res, from, x.member.decl);
			},
			(FunBody.CreateSumType) {
				usedReturnType();
			},
			(Expr _) {
				trackAllUsedInExprRef(res, FunOrTest(a), funBodyExprRef(a));
			},
			(FunBody.Extern _) {
				assert(false);
			},
			(FunBody.FileImport _) {},
			(FlagsFunction _) {
				usedReturnType();
			},
			(FunBody.Method) {},
			(FunBody.RecordFieldCall) {
				usedTuple(res, from, a.arity.as!uint - 1);
			},
			(FunBody.RecordFieldGet) {},
			(FunBody.RecordFieldPointer) { assert(false); },
			(FunBody.RecordFieldSet) {},
			(FunBody.SumTypeMemberGet) {
				// Needs the unwrapped option type for 'instanceof',
				// and the option type to return 'option.some' or 'option.none'
				usedReturnType();
				trackAllUsedInType(res, from, mustUnwrapOptionType(a.returnType));
			},
			(FunBody.VarGet x) {
				cast(void) addDecl(res, from, AnyDecl(x.var));
			},
			(FunBody.VarSet x) {
				cast(void) addDecl(res, from, AnyDecl(x.var));
			});
	}
}
void trackAllUsedInTest(ref AllUsedBuilder res, Uri from, Test* test) {
	if (addDecl(res, from, AnyDecl(test)))
		trackAllUsedInExprRef(res, FunOrTest(test), testBodyExprRef(res.commonTypes, test));
}
void trackAllUsedInDestructure(ref AllUsedBuilder res, Uri from, Destructure a) {
	a.match!void(
		(ref Destructure.Ignore x) {
			trackAllUsedInType(res, from, x.type);
		},
		(ref Local x) {
			trackAllUsedInType(res, from, x.type);
		},
		(ref Destructure.Split x) {
			trackAllUsedInType(res, from, x.destructuredType);
			foreach (Destructure part; x.parts)
				trackAllUsedInDestructure(res, from, part);
		});
}

// 'from' may differ from 'caller' for a variant method.
// 'called' is used from the variant member, but the caller is the variant method.
void trackAllUsedInCalled(ref AllUsedBuilder res, Uri from, FunOrTest caller, Called called, FunUse funUse) {
	called.match!void(
		(ref Called.Bogus) {},
		(ref FunInst calledInst) {
			trackAllUsedInCalledFunInst(res, from, caller, calledInst, funUse);
		},
		(CalledSpecSig x) {
			// Functions are presumed to call their specs, so nothing to do here.
		});
}
void trackAllUsedInCalledFunInst(
	ref AllUsedBuilder res,
	Uri from,
	FunOrTest caller,
	ref FunInst calledInst,
	FunUse funUse,
) {
	FunDecl* calledDecl = calledInst.decl;
	trackAllUsedInFun(res, from, calledDecl, funUse);
	caller.matchWithPointers!void(
		(FunDecl* x) {
			add(res.alloc, res.funToCallers, calledDecl, x);
		},
		(Test*) {
			// Do nothing for tests since they are all assumed async anyway
		});
	eachSpecSigAndImpl(*calledDecl, calledInst.specImpls, (SpecInst* spec, Signature* sig, Called impl) {
		trackAllUsedInSpecImpl(res, caller, calledDecl, spec, sig, impl);
		trackAllUsedInCalled(res, from, caller, impl, FunUse.noInline);
	});
}
void trackAllUsedInSpecImpl(
	ref AllUsedBuilder res,
	FunOrTest caller,
	FunDecl* calledDecl,
	SpecInst* spec,
	Signature* sig,
	Called impl,
) {
	impl.match!void(
		(ref Called.Bogus) {},
		(ref FunInst x) {
			add(res.alloc, res.funToUsedAsSpecImpl, x.decl, FunAndSpecSig(calledDecl, sig));
			eachSpecSigAndImpl(*x.decl, x.specImpls, (SpecInst* spec2, Signature* sig2, Called impl2) {
				trackAllUsedInSpecImpl(res, caller, x.decl, spec2, sig2, impl2);
			});
		},
		(CalledSpecSig x) {
			add(
				res.alloc,
				res.specSigToUsedAsSpecImpl,
				FunAndSpecSig(caller.as!(FunDecl*), x.nonInstantiatedSig),
				FunAndSpecSig(calledDecl, sig));
		});
}

void usedTuple(ref AllUsedBuilder res, Uri from, uint tupleSize) {
	if (tupleSize >= 2)
		trackAllUsedInStruct(res, from, force(res.commonTypes.tuple(tupleSize)));
}

void trackAllUsedInExprRef(ref AllUsedBuilder res, FunOrTest curFunc, ExprRef a) {
	Uri from = curFunc.moduleUri;
	Opt!Called called = getCalledAtExpr(a.expr.kind);
	if (has(called))
		trackAllUsedInCalled(
			res, from, curFunc, force(called),
			a.expr.kind.isA!FunPointerExpr ? FunUse.noInline : FunUse.regular);

	void trackChildren() {
		eachDirectChildExpr(res.commonTypes, a, (ExprRef x) {
			trackAllUsedInExprRef(res, curFunc, x);
		});
	}

	if (a.expr.kind.isA!(IfExpr*)) {
		IfExpr* if_ = a.expr.kind.as!(IfExpr*);
		Opt!bool constant = tryEvalConstantBool(res.version_, res.allExterns, if_.condition);
		if (has(constant))
			trackAllUsedInExprRef(res, curFunc, ExprRef(force(constant) ? &if_.trueBranch : &if_.falseBranch, a.type));
		else
			trackChildren();
	} else {
		a.expr.kind.match!void(
			(ref AssertOrForbidExpr x) {
				if (!has(x.thrown))
					trackAllUsedInFun(res, from, res.program.commonFuns.createError.decl, FunUse.regular);
			},
			(BogusCallExpr _) {},
			(BogusExpr _) {},
			(BogusWrongTypeExpr _) {},
			(CallExpr _) {},
			(ref CallOptionExpr x) {
				trackAllUsedInType(res, from, a.type);
			},
			(ClosureGetExpr _) {},
			(ClosureSetExpr _) {},
			(ExternExpr _) {},
			(ref FinallyExpr _) {},
			(FunPointerExpr _) {},
			(ref IfExpr _) {},
			(ref LambdaExpr _) {},
			(ref LetExpr _) {},
			(LiteralExpr _) {},
			(LiteralStringLikeExpr x) {},
			(LocalGetExpr _) {},
			(LocalPointerExpr _) {},
			(LocalSetExpr _) {},
			(ref LoopExpr _) {},
			(ref LoopBreakExpr _) {},
			(LoopContinueExpr _) {},
			(ref LoopWhileOrUntilExpr _) {},
			(ref MatchEnumExpr x) {
				trackAllUsedInStruct(res, from, x.enum_);
			},
			(ref MatchIntegralExpr _) {},
			(ref MatchStringLikeExpr _) {},
			(ref MatchSumTypeExpr x) {
				trackAllUsedInMatchSumTypeCases(res, from, x.cases);
			},
			(ref RecordFieldPointerExpr _) {},
			(ref SeqExpr _) {},
			(ref ThrowExpr _) {},
			(ref TrustedExpr) {},
			(ref TryExpr x) {
				trackAllUsedInMatchSumTypeCases(res, from, x.catches);
			},
			(ref TryLetExpr x) {
				trackAllUsedInMatchSumTypeCase(res, from, x.catch_);
			},
			(ref TypedExpr _) {});
		trackChildren();
	}
}

void trackAllUsedInMatchSumTypeCases(ref AllUsedBuilder res, Uri from, in MatchSumTypeCase[] cases) {
	foreach (MatchSumTypeCase case_; cases)
		trackAllUsedInMatchSumTypeCase(res, from, case_);
}
void trackAllUsedInMatchSumTypeCase(ref AllUsedBuilder res, Uri from, in MatchSumTypeCase case_) {
	trackAllUsedInStruct(res, from, case_.member.decl);
}
