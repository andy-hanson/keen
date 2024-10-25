module frontend.check.checkFuns;

@safe @nogc pure nothrow:

import frontend.check.checkCall.checkCallSpecs : checkSpecSingleSigIgnoreParents;
import frontend.check.checkCtx :
	addDiag,
	addDiagAssertSameUri,
	CheckCtx,
	checkNoTypeParams,
	CommonModule,
	visibilityFromExplicitTopLevel;
import frontend.check.checkExpr : checkExternNameOrBogus, checkFunctionBody, checkTestBody;
import frontend.check.checkStructBodies : checkVariantMethodImpls, modifierTypeArgInvalid;
import frontend.check.getBuiltinFun : getBuiltinFun;
import frontend.check.maps :
	funDeclsName, FunsAndMap, FunsMap, ImportOrExportFile, SpecsMap, StructsAndAliasesMap;
import frontend.check.funsForStruct : addFunsForStruct, addFunsForVar, countFunsForStructs, countFunsForVars;
import frontend.check.instantiate : MayDelayStructInsts, instantiateSpec, noDelaySpecInsts, noDelayStructInsts;
import frontend.check.typeFromAst :
	AliasAllowed, checkDestructure, checkTypeParams, DestructureKind, getSpecFromCommonModule, specFromAst, typeFromAst;
import model.ast :
	DestructureAst,
	EmptyAst,
	FunDeclAst,
	ImportFileType,
	ModifierAst,
	ModifierKeyword,
	ImportOrExportAstKind,
	NameAndRange,
	ParamsAst,
	SpecUseAst,
	TestAst,
	TypeAst;
import model.diag : DeclKind, Diag;
import model.model :
	AutoFun,
	CommonTypes,
	Destructure,
	emptySpecs,
	Expr,
	FunBody,
	FunDecl,
	FunDeclSource,
	FunFlags,
	ImportFileContent,
	isLinkageAlwaysCompatible,
	Linkage,
	linkageRange,
	Params,
	RecordField,
	SpecDecl,
	Signature,
	SpecInst,
	StructBody,
	StructDecl,
	StructInst,
	Test,
	Type,
	TypeContainer,
	TypeParamIndex,
	TypeParams,
	VarDecl,
	Visibility;
import model.parseDiag : ParseDiag;
import util.alloc.alloc : Alloc;
import util.cell : Cell, cellGet, cellSet;
import util.col.array :
	allSame,
	every,
	isEmpty,
	map,
	mapOp,
	mapPointers,
	mapWithResultPointer,
	mustFind,
	only,
	small,
	SmallArray,
	zipPointers;
import util.col.arrayBuilder : add, ArrayBuilder, asTemporaryArray, finish;
import util.col.exactSizeArrayBuilder : buildArrayExact, ExactSizeArrayBuilder, pushUninitialized;
import util.col.hashTable : insertOrUpdate, mapAndMovePreservingKeys, MutHashTable;
import util.memory : allocate, initMemory;
import util.opt : force, has, none, Opt, optIf, optOrDefault, some;
import util.sourceRange : Range;
import util.string : CStringAndLength;
import util.symbol : Symbol, symbol;
import util.symbolSet : buildSymbolSet, emptySymbolSet, SymbolSet, symbolSet, SymbolSetBuilder;
import util.unicode : unicodeValidate;
import util.util : optEnumConvert;

FunsAndMap checkFuns(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in SpecsMap specsMap,
	StructDecl[] structs,
	in StructsAndAliasesMap structsAndAliasesMap,
	VarDecl[] vars,
	ImportOrExportFile[] fileImports,
	ImportOrExportFile[] fileExports,
	FunDeclAst[] asts,
	TestAst[] testAsts,
) {
	FunDecl[] funs = checkFunsInitial(
		ctx, commonTypes, specsMap, structs, structsAndAliasesMap, vars, fileImports, fileExports, asts);
	FunsMap funsMap = buildFunsMap(ctx.alloc, funs);
	checkVariantMethodImpls(ctx, commonTypes, funsMap, structs);
	checkFunsWithAsts(ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, funs[0 .. asts.length], asts);
	foreach (size_t i, ref ImportOrExportFile f; fileImports)
		setFileImportFunctionBody(ctx, &funs[asts.length + i], f);
	foreach (size_t i, ref ImportOrExportFile f; fileExports)
		setFileImportFunctionBody(ctx, &funs[asts.length + fileImports.length + i], f);
	return FunsAndMap(
		small!FunDecl(funs), checkTests(ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, testAsts), funsMap);
}

immutable struct ReturnTypeAndParams {
	Type returnType;
	Params params;
}
ReturnTypeAndParams checkReturnTypeAndParams(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	in TypeAst returnTypeAst,
	in ParamsAst paramsAst,
	TypeParams typeParams,
	in StructsAndAliasesMap structsAndAliasesMap,
	MayDelayStructInsts delayStructInsts
) =>
	ReturnTypeAndParams(
		typeFromAst(
			ctx, commonTypes, structsAndAliasesMap, returnTypeAst, typeParams, delayStructInsts, AliasAllowed.yes),
		checkParams(ctx, commonTypes, typeContainer, paramsAst, structsAndAliasesMap, typeParams, delayStructInsts));

SymbolSet getExternsFromModifier(ref CheckCtx ctx, in ModifierAst.Keyword modifier, bool required) {
	assert(modifier.keyword == ModifierKeyword.extern_);
	if (has(modifier.typeArg))
		return optOrDefault!SymbolSet(tryGetExternsFromTypeArg(ctx, force(modifier.typeArg)), () =>
			required ? symbolSet(symbol!"bogus") : emptySymbolSet);
	else if (required) {
		addDiag(ctx, modifier.keywordRange, Diag(Diag.ExternMissingLibraryName()));
		return symbolSet(symbol!"bogus");
	} else
		return emptySymbolSet;
}

private:

Opt!SymbolSet tryGetExternsFromTypeArg(ref CheckCtx ctx, in TypeAst arg) {
	if (arg.isA!NameAndRange) {
		return some(symbolSet(checkExternNameOrBogus(ctx, arg.as!NameAndRange, emptySymbolSet)));
	} else if (arg.isA!(TypeAst.Tuple*)) {
		bool ok = true;
		SymbolSet res = buildSymbolSet((scope ref SymbolSetBuilder out_) {
			foreach (TypeAst member; arg.as!(TypeAst.Tuple*).members) {
				if (member.isA!NameAndRange)
					out_ ~= checkExternNameOrBogus(ctx, member.as!NameAndRange, emptySymbolSet);
				else
					ok = false;
			}
		});
		return optIf(ok, () => res);
	} else
		return none!SymbolSet;
}

FunDecl[] checkFunsInitial(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in SpecsMap specsMap,
	StructDecl[] structs,
	in StructsAndAliasesMap structsAndAliasesMap,
	VarDecl[] vars,
	ImportOrExportFile[] fileImports,
	ImportOrExportFile[] fileExports,
	FunDeclAst[] asts,
) =>
	buildArrayExact!FunDecl(
		ctx.alloc,
		asts.length +
			fileImports.length +
			fileExports.length +
			countFunsForStructs(commonTypes, structs) +
			countFunsForVars(vars),
		(scope ref ExactSizeArrayBuilder!FunDecl funsBuilder) @trusted {
			foreach (ref FunDeclAst funAst; asts) {
				FunDecl* fun = pushUninitialized(funsBuilder);
				checkTypeParams(ctx, funAst.typeParams);
				ReturnTypeAndParams rp = checkReturnTypeAndParams(
					ctx,
					commonTypes,
					TypeContainer(fun),
					funAst.returnType,
					funAst.params,
					funAst.typeParams,
					structsAndAliasesMap,
					noDelayStructInsts);
				bool hasBody = !funAst.body_.kind.isA!EmptyAst;
				FunModifiers flagsAndSpecs = checkFunModifiers(
					ctx, commonTypes, structsAndAliasesMap, specsMap,
					funAst.typeParams, funAst.nameRange, hasBody, funAst.modifiers);
				initMemory(fun, FunDecl(
					FunDeclSource(FunDeclSource.Ast(ctx.curUri, &funAst)),
					visibilityFromExplicitTopLevel(funAst.visibility),
					funAst.name.name,
					rp.returnType,
					rp.params,
					flagsAndSpecs.flags,
					flagsAndSpecs.externs,
					flagsAndSpecs.specs));
				if (flagsAndSpecs.isBuiltin) {
					if (hasBody)
						addDiag(ctx, funAst.nameRange, Diag(Diag.BuiltinFunCantHaveBody()));
					fun.body_ = getBuiltinFun(ctx, commonTypes, fun);
				}
				else if (!hasBody && !flagsAndSpecs.externs.isEmpty)
					fun.body_ = checkExternBody(ctx, fun);
			}
			foreach (ref ImportOrExportFile f; fileImports)
				funsBuilder ~= funDeclForFileImportOrExport(ctx, commonTypes, f, Visibility.private_);
			foreach (ref ImportOrExportFile f; fileExports)
				funsBuilder ~= funDeclForFileImportOrExport(ctx, commonTypes, f, Visibility.public_);

			foreach (ref StructDecl struct_; structs)
				addFunsForStruct(ctx, funsBuilder, commonTypes, &struct_);
			foreach (ref VarDecl var; vars)
				addFunsForVar(ctx, funsBuilder, commonTypes, &var);
		});

Params checkParams(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	in ParamsAst ast,
	in StructsAndAliasesMap structsAndAliasesMap,
	TypeParams typeParamsScope,
	MayDelayStructInsts delayStructInsts,
) =>
	ast.matchWithPointers!Params(
		(DestructureAst[] asts) =>
			Params(mapPointers!(Destructure, DestructureAst)(ctx.alloc, asts, (DestructureAst* ast) =>
				checkDestructure(
					ctx, commonTypes, structsAndAliasesMap, typeContainer, typeParamsScope, delayStructInsts,
					ast, none!Type, DestructureKind.param))),
		(ParamsAst.Varargs* varargs) {
			Destructure param = checkDestructure(
				ctx, commonTypes, structsAndAliasesMap, typeContainer, typeParamsScope,
				delayStructInsts, &varargs.param, none!Type, DestructureKind.param);
			Opt!Type elementType = param.type.matchIn!(Opt!Type)(
				(in Type.Bogus _) =>
					some(Type.bogus),
				(in TypeParamIndex _) =>
					none!Type,
				(in StructInst x) =>
					x.decl == commonTypes.array
					? some(only(x.typeArgs))
					: none!Type);
			if (!has(elementType))
				addDiag(ctx, varargs.param.range, Diag(Diag.VarargsParamMustBeArray()));
			return Params(allocate(ctx.alloc,
				Params.Varargs(param, has(elementType) ? force(elementType) : Type.bogus)));
		});

void setFileImportFunctionBody(ref CheckCtx ctx, FunDecl* fun, in ImportOrExportFile a) {
	fun.body_ = getFileImportFunctionBody(ctx, fun.range.range, a);
}

FunBody getFileImportFunctionBody(ref CheckCtx ctx, Range range, in ImportOrExportFile a) {
	ImportFileContent content = () {
		final switch (a.source.kind.as!(ImportOrExportAstKind.File*).type) {
			case ImportFileType.nat8Array:
				return ImportFileContent(a.content.asBytes);
			case ImportFileType.string:
				Opt!CStringAndLength x = unicodeValidate(*a.content);
				if (has(x))
					return ImportFileContent(force(x).asString);
				else {
					addDiag(ctx, range, Diag(ParseDiag(ParseDiag.FileNotUtf8())));
					return ImportFileContent("");
				}
		}
	}();
	return FunBody(FunBody.FileImport(content));
}

FunDecl funDeclForFileImportOrExport(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref ImportOrExportFile a,
	Visibility visibility,
) {
	ImportOrExportAstKind.File* ast = a.source.kind.as!(ImportOrExportAstKind.File*);
	return FunDecl(
		FunDeclSource(FunDeclSource.FileImport(ctx.curUri, a.source)),
		visibility,
		ast.name.name,
		typeForFileImport(commonTypes, ast.type),
		Params([]),
		FunFlags.generatedBare,
		emptySymbolSet,
		emptySpecs);
}

Type typeForFileImport(ref CommonTypes commonTypes, ImportFileType type) {
	final switch (type) {
		case ImportFileType.nat8Array:
			return Type(commonTypes.nat8Array);
		case ImportFileType.string:
			return Type(commonTypes.string_);
	}
}

FunBody checkExternBody(ref CheckCtx ctx, FunDecl* fun) {
	Linkage funLinkage = Linkage.extern_;

	checkNoTypeParams(ctx, fun.typeParams, DeclKind.externFunction);
	if (!isEmpty(fun.specs)) {
		Range range = mustFind!ModifierAst(
			fun.source.as!(FunDeclSource.Ast).ast.modifiers,
			(ref ModifierAst x) => x.isA!SpecUseAst,
		).range;
		addDiag(ctx, range, Diag(Diag.SpecUseInvalid(DeclKind.externFunction)));
	}

	if (!isLinkageAlwaysCompatible(funLinkage, linkageRange(fun.returnType)))
		addDiagAssertSameUri(ctx, fun.range, Diag(
			Diag.LinkageWorseThanContainingFun(fun, fun.returnType, none!(Destructure*))));
	fun.params.match!void(
		(Destructure[] params) {
			foreach (ref Destructure param; params)
				if (!isLinkageAlwaysCompatible(funLinkage, linkageRange(param.type)))
					addDiag(ctx, param.range, Diag(Diag.LinkageWorseThanContainingFun(fun, param.type, some(&param))));
		},
		(ref Params.Varargs x) {
			addDiag(ctx, x.param.range, Diag(Diag.ExternFunVariadic()));
		});

	Opt!Symbol single = fun.externs.asSingle;
	if (has(single))
		return FunBody(FunBody.Extern(force(single)));
	else {
		addDiag(ctx, fun.nameRange.range, Diag(Diag.ExternBodyMultiple()));
		return FunBody(FunBody.Bogus());
	}
}

FunsMap buildFunsMap(ref Alloc alloc, in immutable FunDecl[] funs) {
	MutHashTable!(ArrayBuilder!(immutable FunDecl*), Symbol, funDeclsBuilderName) res;
	foreach (ref FunDecl fun; funs) {
		insertOrUpdate(
			alloc,
			res,
			fun.name,
			() {
				ArrayBuilder!(immutable FunDecl*) builder;
				add(alloc, builder, &fun);
				return builder;
			},
			(ref ArrayBuilder!(immutable FunDecl*) builder) {
				add(alloc, builder, &fun);
				return builder;
			});
	}
	return mapAndMovePreservingKeys!(
		immutable FunDecl*[], funDeclsName, ArrayBuilder!(immutable FunDecl*), Symbol, funDeclsBuilderName,
	)(alloc, res, (ref ArrayBuilder!(immutable FunDecl*) x) =>
		finish(alloc, x));
}
Symbol funDeclsBuilderName(in ArrayBuilder!(immutable FunDecl*) a) =>
	asTemporaryArray(a)[0].name;

immutable struct FunModifiers {
	FunFlags flags;
	bool isBuiltin;
	SymbolSet externs;
	SmallArray!(immutable SpecInst*) specs;
}

FunModifiers checkFunModifiers(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	TypeParams typeParamsScope,
	in Range range,
	bool hasBody,
	in SmallArray!ModifierAst asts,
) {
	CollectedFunFlags allFlags = CollectedFunFlags.none;
	Cell!SymbolSet externs;
	SmallArray!(immutable SpecInst*) specs =
		mapOp!(immutable SpecInst*, ModifierAst)(ctx.alloc, asts, (ref ModifierAst ast) =>
			ast.matchIn!(Opt!(SpecInst*))(
				(in ModifierAst.Keyword x) {
					if (x.keyword == ModifierKeyword.extern_) {
						if (cellGet(externs).isEmpty)
							cellSet(externs, getExternsFromModifier(ctx, x, required: true));
						else
							addDiag(ctx, x.range, Diag(Diag.ModifierDuplicate(ModifierKeyword.extern_)));
					} else {
						CollectedFunFlags flag = tryGetFunFlag(x.keyword);
						if (flag == CollectedFunFlags.none)
							addDiag(ctx, x.keywordRange, Diag(Diag.ModifierInvalid(x.keyword, DeclKind.function_)));
						if (allFlags & flag)
							addDiag(ctx, x.keywordRange, Diag(Diag.ModifierDuplicate(x.keyword)));
						modifierTypeArgInvalid(ctx, x);
						allFlags |= flag;
					}
					return none!(SpecInst*);
				},
				(in SpecUseAst x) =>
					specFromAst(
						ctx, commonTypes, structsAndAliasesMap, specsMap, typeParamsScope, x, noDelaySpecInsts)));
	return FunModifiers(
		checkFunFlags(ctx, range, allFlags, isExternBody: !hasBody && !cellGet(externs).isEmpty, isTest: false),
		(allFlags & CollectedFunFlags.builtin) != 0,
		cellGet(externs), specs);
}

@trusted SmallArray!Test checkTests(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	TestAst[] testAsts,
) =>
	small!Test(mapWithResultPointer!(Test, TestAst)(ctx.alloc, testAsts, (TestAst* ast, Test* out_) {
		TestModifiers modifiers = checkTestModifiers(ctx, *ast);
		if (ast.body_.kind.isA!EmptyAst)
			addDiag(ctx, ast.range, Diag(Diag.TestMissingBody()));
		Expr body_ = checkTestBody(
			ctx, structsAndAliasesMap, commonTypes, specsMap, funsMap,
			TypeContainer(out_), modifiers.flags, modifiers.externs, &ast.body_);
		return Test(ast, ctx.curUri, modifiers.flags, modifiers.externs, body_);
	}));

immutable struct TestModifiers {
	FunFlags flags;
	SymbolSet externs;
}
TestModifiers checkTestModifiers(ref CheckCtx ctx, in TestAst ast) {
	CollectedFunFlags allFlags = CollectedFunFlags.none;
	Cell!SymbolSet externs;
	foreach (ModifierAst modifier; ast.modifiers) {
		modifier.matchIn!void(
			(in ModifierAst.Keyword x) {
				CollectedFunFlags flag = tryGetFunFlag(x.keyword);
				if (isAllowedTestFlag(flag)) {
					modifierTypeArgInvalid(ctx, x);
					allFlags |= flag;
				} else if (x.keyword == ModifierKeyword.extern_) {
					if (cellGet(externs).isEmpty)
						cellSet(externs, getExternsFromModifier(ctx, x, required: true));
					else
						addDiag(ctx, x.range, Diag(Diag.ModifierDuplicate(ModifierKeyword.extern_)));
				} else
					addDiag(ctx, x.keywordRange, Diag(Diag.ModifierInvalid(x.keyword, DeclKind.test)));
			},
			(in SpecUseAst x) {
				addDiag(ctx, x.range, Diag(Diag.SpecUseInvalid(DeclKind.test)));
			});
	}
	return TestModifiers(
		checkFunFlags(ctx, ast.keywordRange, allFlags, isExternBody: false, isTest: true),
		cellGet(externs));
}

bool isAllowedTestFlag(CollectedFunFlags flag) {
	switch (flag) {
		case CollectedFunFlags.bare:
		case CollectedFunFlags.summon:
		case CollectedFunFlags.trusted:
			return true;
		default:
			return false;
	}
}

enum CollectedFunFlags {
	none = 0,
	bare = 1,
	builtin = 0b10,
	forceCtx = 0b100,
	pure_ = 0b1000,
	summon = 0b1_0000,
	trusted = 0b10_0000,
	unsafe = 0b100_0000,
}

CollectedFunFlags tryGetFunFlag(ModifierKeyword kind) =>
	optEnumConvert!CollectedFunFlags(kind, () => CollectedFunFlags.none);

FunFlags checkFunFlags(ref CheckCtx ctx, in Range range, CollectedFunFlags flags, bool isExternBody, bool isTest) {
	void warnRedundant(ModifierKeyword modifier, ModifierKeyword redundantModifier) {
		addDiag(ctx, range, Diag(Diag.ModifierRedundantDueToModifier(modifier, redundantModifier)));
	}

	bool builtin = (flags & CollectedFunFlags.builtin) != 0;
	bool explicitBare = (flags & CollectedFunFlags.bare) != 0;
	bool forceCtx = (flags & CollectedFunFlags.forceCtx) != 0;
	bool pure_ = (flags & CollectedFunFlags.pure_) != 0;
	bool summon = (flags & CollectedFunFlags.summon) != 0;
	bool trusted = (flags & CollectedFunFlags.trusted) != 0;
	bool explicitUnsafe = (flags & CollectedFunFlags.unsafe) != 0;

	bool implicitUnsafe = isExternBody && !builtin;
	bool unsafe = explicitUnsafe || implicitUnsafe;
	bool implicitBare = isExternBody && !builtin;
	bool bare = explicitBare || implicitBare;

	ModifierKeyword bodyModifier() =>
		builtin
			? ModifierKeyword.builtin
			: isExternBody
			? ModifierKeyword.extern_
			: assert(false);

	FunFlags.Safety safety = trusted
		? FunFlags.Safety.trusted
		: unsafe
		? FunFlags.Safety.unsafe
		: FunFlags.Safety.safe;
	if (implicitBare && explicitBare)
		warnRedundant(bodyModifier(), ModifierKeyword.bare);
	if (implicitUnsafe && explicitUnsafe)
		warnRedundant(bodyModifier(), ModifierKeyword.unsafe);
	if (explicitUnsafe && trusted)
		addDiag(ctx, range, Diag(Diag.ModifierConflict(ModifierKeyword.unsafe, ModifierKeyword.trusted)));

	if (pure_ && summon)
		addDiag(ctx, range, Diag(Diag.ModifierConflict(ModifierKeyword.pure_, ModifierKeyword.summon)));
	else if (pure_ && !isExternBody)
		addDiag(ctx, range, Diag(Diag.ModifierRedundantDueToDeclKind(ModifierKeyword.pure_, DeclKind.function_)));
	else if (summon && isExternBody)
		warnRedundant(ModifierKeyword.extern_, ModifierKeyword.summon);

	bool isSummon = !pure_ && (summon || (isExternBody && !builtin));
	return FunFlags.regular(bare, isSummon, safety, forceCtx);
}

void checkFunsWithAsts(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	FunDecl[] funsWithAsts,
	FunDeclAst[] asts,
) {
	zipPointers!(FunDecl, FunDeclAst)(funsWithAsts, asts, (FunDecl* fun, FunDeclAst* funAst) {
		if (!fun.bodyIsSet)
			fun.body_ = funAst.body_.kind.isA!EmptyAst
				? checkAutoFun(ctx, specsMap, funsMap, fun)
				: fun.returnType.isBogus
				? FunBody(FunBody.Bogus())
				: FunBody(checkFunctionBody(
					ctx, structsAndAliasesMap, commonTypes, specsMap, funsMap, fun, &funAst.body_));
	});
}

FunBody checkAutoFun(ref CheckCtx ctx, in SpecsMap specsMap, in FunsMap funsMap, FunDecl* fun) {
	switch (fun.name.value) {
		case symbol!"==".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"equal", CommonModule.compare);
			return has(spec)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, AutoFun.Kind.equals, force(spec),
					returnTypeOk: none!bool,
					countParams: 2,
					allowBare: true)
				: FunBody(FunBody.Bogus());
		case symbol!"<=>".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"compare", CommonModule.compare);
			return has(spec)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, AutoFun.Kind.compare, force(spec),
					returnTypeOk: none!bool,
					countParams: 2,
					allowBare: true)
				: FunBody(FunBody.Bogus());
		case symbol!"to".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"to", CommonModule.misc);
			return has(spec)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, AutoFun.Kind.toJson, force(spec),
					returnTypeOk: some(isJson(ctx, fun.returnType)),
					countParams: 1,
					allowBare: false,
					extraTypeArg: some(fun.returnType))
				: FunBody(FunBody.Bogus());
		default:
			addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.WrongName())));
			return FunBody(FunBody.Bogus());
	}
}

FunBody checkAutoFunWithSpec(
	ref CheckCtx ctx,
	in FunsMap funsMap,
	FunDecl* fun,
	AutoFun.Kind funKind,
	SpecDecl* spec,
	Opt!bool returnTypeOk, // if none, use sig
	size_t countParams,
	bool allowBare,
	Opt!Type extraTypeArg = none!Type,
) {
	FunBody diag(Diag.AutoFunError x) {
		addDiag(ctx, fun.nameRange.range, Diag(x));
		return FunBody(FunBody.Bogus());
	}
	Signature* sig = &only(spec.sigs);
	Opt!Type paramType = getAutoFunParamType(fun, countParams);
	return !has(paramType)
		? diag(Diag.AutoFunError(Diag.AutoFunError.WrongParams(funKind)))
		: !optOrDefault!bool(returnTypeOk, () => fun.returnType == sig.returnType)
		? diag(Diag.AutoFunError(Diag.AutoFunError.WrongReturnType(funKind)))
		: !isRecordOrUnion(force(paramType))
		? diag(Diag.AutoFunError(Diag.AutoFunError.WrongParamType()))
		: !isFullyVisible(ctx, force(paramType))
		? diag(Diag.AutoFunError(Diag.AutoFunError.TypeNotFullyVisible()))
		: !allowBare && fun.flags.bare
		? diag(Diag.AutoFunError(Diag.AutoFunError.Bare()))
		: FunBody(AutoFun(funKind, map(ctx.alloc, force(paramType).as!(StructInst*).instantiatedTypes, (ref Type type) {
			SpecInst* inst = has(extraTypeArg)
				? instantiateSpec(ctx.instantiateCtx, spec, [force(extraTypeArg), type])
				: instantiateSpec(ctx.instantiateCtx, spec, [type]);
			return checkSpecSingleSigIgnoreParents(ctx, funsMap, fun, inst);
		})));
}

Opt!Type getAutoFunParamType(FunDecl* fun, size_t countParams) =>
	fun.params.matchIn!(Opt!Type)(
		(in Destructure[] params) =>
			params.length == countParams && allSame!(Type, Destructure)(params, (in Destructure x) => x.type)
				? some(params[0].type)
				: none!Type,
		(in Params.Varargs) =>
			none!Type);

bool isRecordOrUnion(in Type a) =>
	a.isA!(StructInst*) && (
		a.as!(StructInst*).decl.body_.isA!(StructBody.Record) || a.as!(StructInst*).decl.body_.isA!(StructBody.Union*));

bool isFullyVisible(in CheckCtx ctx, in Type a) {
	StructDecl* decl = a.as!(StructInst*).decl;
	return decl.moduleUri == ctx.curUri ||
		decl.body_.isA!(StructBody.Union*) ||
		every!RecordField(decl.body_.as!(StructBody.Record).fields, (in RecordField x) =>
			x.visibility == decl.visibility);
}

bool isJson(in CheckCtx ctx, in Type a) =>
	a.isA!(StructInst*) &&
	a.as!(StructInst*).decl.moduleUri == ctx.commonUris[CommonModule.json] &&
	a.as!(StructInst*).decl.name == symbol!"json";
