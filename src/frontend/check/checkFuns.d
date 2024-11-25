module frontend.check.checkFuns;

@safe @nogc pure nothrow:

import frontend.check.checkAutoFun : checkAutoFun;
import frontend.check.checkCtx :
	addDiag, addDiagAssertSameUri, CheckCtx, checkNoTypeParams, visibilityFromExplicitTopLevel;
import frontend.check.checkExpr : checkFunctionBody, checkTestBody;
import frontend.check.checkStructBodies : checkMethodImpls, modifierTypeArgInvalid;
import frontend.check.checkUtil : checkReturnTypeAndParams, getExternsFromModifier, ReturnTypeAndParams;
import frontend.check.getBuiltinFun : getBuiltinFun;
import frontend.check.maps :
	funDeclsName, FunsAndMap, FunsMap, ImportOrExportFile, SpecsMap, StructsAndAliasesMap;
import frontend.check.funsForStruct : addFunsForStruct, addFunsForVar, countFunsForStructs, countFunsForVars;
import frontend.check.instantiate : noDelaySpecInsts;
import frontend.check.typeFromAst : checkTypeParams, specFromAst;
import model.ast :
	EmptyAst,
	FunDeclAst,
	ImportFileType,
	ModifierAst,
	ModifierKeyword,
	ModifierKeywordAst,
	ImportFileAst,
	SpecUseAst,
	TestAst;
import model.model :
	CommonTypes,
	DeclKind,
	Destructure,
	Diag,
	DiagBuiltinFunCantHaveBody,
	DiagExternBodyMultiple,
	DiagExternFunVariadic,
	DiagLinkageWorseThanContainingFun,
	DiagModifierConflict,
	DiagModifierDuplicate,
	DiagModifierRedundantDueToDeclKind,
	DiagModifierRedundantDueToModifier,
	DiagModifierInvalid,
	DiagSpecUseInvalid,
	DiagTestMissingBody,
	emptySpecs,
	Expr,
	FunBody,
	FunDecl,
	FunDeclSource,
	FunFlags,
	ImportFileContent,
	isEmpty,
	isLinkageAlwaysCompatible,
	Linkage,
	linkageRange,
	Params,
	SpecInst,
	StructDecl,
	Test,
	Type,
	TypeContainer,
	TypeParams,
	VarDecl,
	Visibility;
import model.parseDiag : ParseDiag, ParseDiagFileNotUtf8;
import util.alloc.alloc : Alloc;
import util.cell : Cell, cellGet, cellSet;
import util.col.array : isEmpty, mapOp, mapWithResultPointer, mustFind, small, SmallArray, zipPointers;
import util.col.arrayBuilder : add, ArrayBuilder, asTemporaryArray, finish;
import util.col.exactSizeArrayBuilder : buildArrayExact, ExactSizeArrayBuilder, pushUninitialized;
import util.col.hashTable : insertOrUpdate, mapAndMovePreservingKeys, MutHashTable;
import util.memory : initMemory;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : Range;
import util.string : CStringAndLength;
import util.symbol : Symbol;
import util.symbolSet : emptySymbolSet, SymbolSet;
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
	checkMethodImpls(ctx, commonTypes, funsMap, structs);
	checkFunsWithAsts(ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, funs[0 .. asts.length], asts);
	foreach (size_t i, ref ImportOrExportFile f; fileImports)
		setFileImportFunctionBody(ctx, &funs[asts.length + i], f);
	foreach (size_t i, ref ImportOrExportFile f; fileExports)
		setFileImportFunctionBody(ctx, &funs[asts.length + fileImports.length + i], f);
	return FunsAndMap(
		small!FunDecl(funs), checkTests(ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, testAsts), funsMap);
}

private:

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
		asts.length + fileImports.length + fileExports.length + countFunsForStructs(structs) + countFunsForVars(vars),
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
					structsAndAliasesMap);
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
						addDiag(ctx, funAst.nameRange, Diag(DiagBuiltinFunCantHaveBody()));
					fun.body_ = getBuiltinFun(ctx, fun);
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

void setFileImportFunctionBody(ref CheckCtx ctx, FunDecl* fun, in ImportOrExportFile a) {
	fun.body_ = getFileImportFunctionBody(ctx, fun.range.range, a);
}

FunBody getFileImportFunctionBody(ref CheckCtx ctx, Range range, in ImportOrExportFile a) {
	ImportFileContent content = () {
		final switch (a.source.kind.as!(ImportFileAst*).type) {
			case ImportFileType.nat8Array:
				return ImportFileContent(a.content.asBytes);
			case ImportFileType.string:
				Opt!CStringAndLength x = unicodeValidate(*a.content);
				if (has(x))
					return ImportFileContent(force(x).asString);
				else {
					addDiag(ctx, range, Diag(ParseDiag(ParseDiagFileNotUtf8())));
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
	ImportFileAst* ast = a.source.kind.as!(ImportFileAst*);
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
		addDiag(ctx, range, Diag(DiagSpecUseInvalid(DeclKind.externFunction)));
	}

	if (!isLinkageAlwaysCompatible(funLinkage, linkageRange(fun.returnType)))
		addDiagAssertSameUri(ctx, fun.range, Diag(
			DiagLinkageWorseThanContainingFun(fun, fun.returnType, none!(Destructure*))));
	fun.params.match!void(
		(Destructure[] params) {
			foreach (ref Destructure param; params)
				if (!isLinkageAlwaysCompatible(funLinkage, linkageRange(param.type)))
					addDiag(ctx, param.range, Diag(DiagLinkageWorseThanContainingFun(fun, param.type, some(&param))));
		},
		(ref Params.Varargs x) {
			addDiag(ctx, x.param.range, Diag(DiagExternFunVariadic()));
		});

	Opt!Symbol single = fun.externs.asSingle;
	if (has(single))
		return FunBody(FunBody.Extern(force(single)));
	else {
		addDiag(ctx, fun.nameRange.range, Diag(DiagExternBodyMultiple()));
		return FunBody.bogus;
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
				(in ModifierKeywordAst x) {
					if (x.keyword == ModifierKeyword.extern_) {
						if (cellGet(externs).isEmpty)
							cellSet(externs, getExternsFromModifier(ctx, x, required: true));
						else
							addDiag(ctx, x.range, Diag(DiagModifierDuplicate(ModifierKeyword.extern_)));
					} else {
						CollectedFunFlags flag = tryGetFunFlag(x.keyword);
						if (flag == CollectedFunFlags.none)
							addDiag(ctx, x.keywordRange, Diag(DiagModifierInvalid(x.keyword, DeclKind.function_)));
						if (allFlags & flag)
							addDiag(ctx, x.keywordRange, Diag(DiagModifierDuplicate(x.keyword)));
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
			addDiag(ctx, ast.range, Diag(DiagTestMissingBody()));
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
			(in ModifierKeywordAst x) {
				CollectedFunFlags flag = tryGetFunFlag(x.keyword);
				if (isAllowedTestFlag(flag)) {
					modifierTypeArgInvalid(ctx, x);
					allFlags |= flag;
				} else if (x.keyword == ModifierKeyword.extern_) {
					if (cellGet(externs).isEmpty)
						cellSet(externs, getExternsFromModifier(ctx, x, required: true));
					else
						addDiag(ctx, x.range, Diag(DiagModifierDuplicate(ModifierKeyword.extern_)));
				} else
					addDiag(ctx, x.keywordRange, Diag(DiagModifierInvalid(x.keyword, DeclKind.test)));
			},
			(in SpecUseAst x) {
				addDiag(ctx, x.range, Diag(DiagSpecUseInvalid(DeclKind.test)));
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
		addDiag(ctx, range, Diag(DiagModifierRedundantDueToModifier(modifier, redundantModifier)));
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
		addDiag(ctx, range, Diag(DiagModifierConflict(ModifierKeyword.unsafe, ModifierKeyword.trusted)));

	if (pure_ && summon)
		addDiag(ctx, range, Diag(DiagModifierConflict(ModifierKeyword.pure_, ModifierKeyword.summon)));
	else if (pure_ && !isExternBody)
		addDiag(ctx, range, Diag(DiagModifierRedundantDueToDeclKind(ModifierKeyword.pure_, DeclKind.function_)));
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
				? FunBody.bogus
				: FunBody(checkFunctionBody(
					ctx, structsAndAliasesMap, commonTypes, specsMap, funsMap, fun, &funAst.body_));
	});
}
