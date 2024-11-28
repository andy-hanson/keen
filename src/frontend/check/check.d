module frontend.check.check;

@safe @nogc pure nothrow:

import frontend.allInsts : AllInsts;
import frontend.check.checkDocComments : checkDocCommentReferences, checkDocComments;
import frontend.check.checkFuns : checkFuns;
import frontend.check.checkCtx :
	addDiag,
	addDiagAssertSameUri,
	CheckCtx,
	checkForUnused,
	checkNoTypeParams,
	CommonUris,
	finishDiagnostics,
	finishImports,
	ImportAndReExportModules,
	visibilityFromExplicitTopLevel;
import frontend.check.checkStructBodies :
	checkSignatures, checkStructBodies, checkStructsInitial, modifierTypeArgInvalid;
import frontend.check.checkUtil : getExternsFromModifier;
import frontend.check.getCommonTypes : getCommonTypes;
import frontend.check.maps :
	FunsAndMap,
	FunsMap,
	ImportOrExportFile,
	specDeclName,
	SpecsMap,
	structOrAliasName,
	StructsAndAliasesMap;
import frontend.check.instantiate : DelaySpecInsts, InstantiateCtx, instantiateSpecBody;
import frontend.check.typeFromAst :
	AliasAllowed, checkTypeParams, specFromAst, typeFromAst, typeFromAstNoTypeParams;
import frontend.lang : maxSpecDepth;
import model.ast :
	FileAst,
	ImportFileAst,
	ImportWholeModuleAst,
	ModifierAst,
	ModifierKeyword,
	ModifierKeywordAst,
	ImportsOrExportsAst,
	ImportOrExportAst,
	NameAndRange,
	SpecDeclAst,
	SpecUseAst,
	StructAliasAst,
	VarDeclAst;
import model.model :
	BuiltinSpec,
	CommonTypes,
	Config,
	DeclKind,
	Diag,
	DiagBuiltinUnsupported,
	DiagBuiltinUnsupportedKind,
	DiagDuplicateDeclaration,
	DiagDuplicateDeclarationKind,
	DiagDuplicateExports,
	DiagDuplicateExportsKind,
	DiagDuplicateImportName,
	DiagExternBodyMultiple,
	DiagImportFile,
	DiagImportRefersToNothing,
	DiagModifierDuplicate,
	DiagModifierInvalid,
	DiagSpecRecursion,
	DiagSpecUseInvalid,
	Diagnostic,
	DocCommentReferences,
	emptySpecs,
	emptyTypeParams,
	ExportVisibility,
	FunDecl,
	importCanSee,
	ImportedReferents,
	ImportOrExport,
	Module,
	nameFromNameReferents,
	nameFromNameReferentsPointer,
	NameReferents,
	SpecDecl,
	SpecDeclBody,
	Signature,
	SignatureContainer,
	SpecInst,
	StructAlias,
	StructDecl,
	StructInst,
	StructOrAlias,
	Type,
	TypeParams,
	VarDecl,
	VarKind,
	Visibility;
import model.sourceRange : Range, UriAndRange;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray;
import util.cell : Cell, cellGet, cellSet;
import util.col.array :
	concatenate,
	exists,
	filter,
	first,
	isEmpty,
	mapOp,
	mapPointers,
	mapWithResultPointer,
	newArray,
	only,
	small,
	SmallArray,
	zip,
	zipPointers;
import util.col.arrayBuilder : add, ArrayBuilder, mustPeek, smallFinish;
import util.col.hashTable :
	buildHashTable, getPointer, HashTable, insertOrUpdate, mayAdd, moveToImmutable, MutHashTable;
import util.col.mutArr : mustPop, mutArrIsEmpty;
import util.memory : allocate;
import util.opt : force, has, none, Opt, someMut, some;
import util.perf : Perf, PerfMeasure, withMeasure;
import util.symbol : Symbol, symbol;
import util.symbolSet : SymbolSet;
import util.unicode : FileContent;
import util.union_ : TaggedUnion;
import util.uri : Path, RelPath, Uri;
import util.util : enumConvert, ptrTrustMe;

immutable struct UriAndAst {
	Uri uri;
	Config* config;
	FileAst* ast;
}

immutable struct ResolvedImport {
	// FileContent is for a file import
	mixin TaggedUnion!(Module*, FileContent*, DiagImportFile*);
}

immutable struct BootstrapCheck {
	Module* module_;
	CommonTypes* commonTypes;
}

BootstrapCheck checkBootstrap(
	scope ref Perf perf,
	ref Alloc alloc,
	ref AllInsts allInsts,
	in CommonUris commonUris,
	ref UriAndAst uriAndAst,
) =>
	checkWorker(
		alloc, perf, allInsts, commonUris, [], uriAndAst,
		(ref CheckCtx ctx, in StructsAndAliasesMap structsAndAliasesMap) =>
			getCommonTypes(ctx.alloc, ctx.curUri, ctx.instantiateCtx, ctx.diagnosticsBuilder, structsAndAliasesMap));

Module* check(
	scope ref Perf perf,
	ref Alloc alloc,
	ref AllInsts allInsts,
	in CommonUris commonUris,
	ref UriAndAst uriAndAst,
	in ResolvedImport[] imports,
	CommonTypes* commonTypes,
) =>
	checkWorker(
		alloc, perf, allInsts, commonUris, imports, uriAndAst,
		(ref CheckCtx _, in StructsAndAliasesMap _2) => commonTypes,
	).module_;

private:

Opt!BuiltinSpec getBuiltinSpec(ref CheckCtx ctx, in Range range, Symbol name) {
	switch (name.value) {
		case symbol!"data".value:
			return some(BuiltinSpec.data);
		case symbol!"shared".value:
			return some(BuiltinSpec.shared_);
		default:
			addDiag(ctx, range, Diag(DiagBuiltinUnsupported(DiagBuiltinUnsupportedKind.spec, name)));
			return none!BuiltinSpec;
	}
}

SpecDeclBody checkSpecDeclBody(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	SpecDecl* spec,
	TypeParams typeParams,
	ref DelaySpecInsts delaySpecInsts,
	ref SpecDeclAst ast,
) {
	SpecFlagsAndParents modifiers = checkSpecModifiers(
		ctx, commonTypes, structsAndAliasesMap, specsMap, delaySpecInsts, ast.typeParams, ast.modifiers);
	Opt!BuiltinSpec builtin = modifiers.isBuiltin
		? getBuiltinSpec(ctx, ast.nameRange, ast.name.name)
		: none!BuiltinSpec;
	SmallArray!Signature sigs = checkSignatures(
		ctx, commonTypes, structsAndAliasesMap, SignatureContainer(spec), typeParams, ast.sigs);
	return SpecDeclBody(builtin, small!(immutable SpecInst*)(modifiers.parents), sigs);
}

@trusted SpecDecl[] checkSpecDeclsInitial(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	SpecDeclAst[] asts,
) =>
	mapWithResultPointer!(SpecDecl, SpecDeclAst)(ctx.alloc, asts, (SpecDeclAst* ast, SpecDecl* out_) {
		checkTypeParams(ctx, ast.typeParams);
		return SpecDecl(ctx.curUri, ast, visibilityFromExplicitTopLevel(ast.visibility));
	});

void checkSpecBodies(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	ref SpecsMap specsMap,
	in SpecDeclAst[] asts,
	SpecDecl[] specs,
) {
	DelaySpecInsts delaySpecInsts = DelaySpecInsts(ctx.allocPtr);

	zipPointers!(SpecDeclAst, SpecDecl)(asts, specs, (SpecDeclAst* ast, SpecDecl* spec) {
		spec.body_ = checkSpecDeclBody(
			ctx, commonTypes, structsAndAliasesMap, specsMap,
			spec, ast.typeParams, delaySpecInsts, *ast);
	});

	foreach (ref SpecDecl decl; specs)
		detectAndFixSpecRecursion(ctx, &decl);

	while (!mutArrIsEmpty(delaySpecInsts))
		instantiateSpecBody(ctx.instantiateCtx, mustPop(delaySpecInsts), someMut(&delaySpecInsts));
}

void detectAndFixSpecRecursion(ref CheckCtx ctx, SpecDecl* decl) =>
	withMaxStackArray(maxSpecDepth, (scope ref MaxStackArray!(immutable SpecDecl*) trace) {
		if (recurDetectSpecRecursion(decl, trace)) {
			addDiagAssertSameUri(ctx, decl.range, Diag(DiagSpecRecursion(newArray(ctx.alloc, trace.finish))));
			decl.overwriteParentsToEmpty();
		}
	});
bool recurDetectSpecRecursion(SpecDecl* cur, scope ref MaxStackArray!(immutable SpecDecl*) trace) {
	if (!isEmpty(cur.parents) && trace.isFull)
		return true;
	foreach (SpecInst* parent; cur.parents) {
		trace ~= parent.decl;
		if (recurDetectSpecRecursion(parent.decl, trace))
			return true;
		else
			trace.mustPop();
	}
	return false;
}

StructAlias[] checkStructAliasesInitial(ref CheckCtx ctx, scope StructAliasAst[] asts) =>
	mapPointers!(StructAlias, StructAliasAst)(ctx.alloc, asts, (StructAliasAst* ast) {
		checkNoTypeParams(ctx, ast.typeParams, DeclKind.alias_);
		return StructAlias(ast, ctx.curUri, visibilityFromExplicitTopLevel(ast.visibility));
	});

void checkStructAliasTargets(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	StructAlias[] aliases,
	in StructAliasAst[] asts,
) {
	zip!(StructAlias, StructAliasAst)(aliases, asts, (ref StructAlias structAlias, ref StructAliasAst ast) {
		Type type = typeFromAst(
			ctx, commonTypes, structsAndAliasesMap, ast.target, ast.typeParams, AliasAllowed.differentModule);
		assert(type.isA!(StructInst*) || type.isBogus); // since type aliases can't have type parameters
		structAlias.target = type.isA!(StructInst*)
			? type.as!(StructInst*)
			: commonTypes.void_;
	});
}

StructsAndAliasesMap buildStructsAndAliasesMap(ref CheckCtx ctx, StructDecl[] structs, StructAlias[] aliases) {
	MutHashTable!(StructOrAlias, Symbol, structOrAliasName) builder;
	void add(StructOrAlias sa) {
		addToDeclsMap!StructOrAlias(
			ctx, builder, sa, DiagDuplicateDeclarationKind.structOrAlias, (in StructOrAlias x) =>
				x.nameRange);
	}
	foreach (ref StructDecl decl; structs)
		add(StructOrAlias(&decl));
	foreach (ref StructAlias alias_; aliases)
		add(StructOrAlias(&alias_));
	return moveToImmutable(builder);
}

VarDecl checkVarDecl(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	VarDeclAst* ast,
) {
	checkNoTypeParams(ctx, ast.typeParams, enumConvert!DeclKind(ast.kind));
	return VarDecl(
		ast,
		ctx.curUri,
		visibilityFromExplicitTopLevel(ast.visibility),
		typeFromAstNoTypeParams(ctx, commonTypes, structsAndAliasesMap, ast.type),
		checkVarModifiers(ctx, ast.kind, ast.modifiers));
}

Opt!Symbol checkVarModifiers(ref CheckCtx ctx, VarKind kind, in ModifierAst[] modifiers) {
	Cell!(Opt!Symbol) externLibraryName;
	foreach (ref ModifierAst modifier; modifiers)
		modifier.matchIn!void(
			(in ModifierKeywordAst x) {
				if (x.keyword == ModifierKeyword.extern_) {
					SymbolSet names = getExternsFromModifier(ctx, x, required: true);
					if (has(cellGet(externLibraryName)))
						addDiag(ctx, x.keywordRange, Diag(DiagModifierDuplicate(ModifierKeyword.extern_)));
					else {
						Opt!Symbol name = names.asSingle;
						if (has(name)) {
							final switch (kind) {
								case VarKind.global:
									cellSet(externLibraryName, name);
									break;
								case VarKind.threadLocal:
									addDiag(ctx, x.keywordRange, Diag(
										DiagModifierInvalid(ModifierKeyword.extern_, DeclKind.threadLocal)));
									break;
							}
						} else
							addDiag(ctx, x.range, Diag(DiagExternBodyMultiple()));
					}
				} else
					addDiag(ctx, x.keywordRange, Diag(DiagModifierInvalid(x.keyword, declKind(kind))));
			},
			(in SpecUseAst x) {
				addDiag(ctx, x.range, Diag(DiagSpecUseInvalid(declKind(kind))));
			});
	return cellGet(externLibraryName);
}

DeclKind declKind(VarKind a) =>
	enumConvert!DeclKind(a);

void addToDeclsMap(T, alias getName)(
	ref CheckCtx ctx,
	scope ref MutHashTable!(T, Symbol, getName) builder,
	T added,
	DiagDuplicateDeclarationKind kind,
	in UriAndRange delegate(in T) @safe @nogc pure nothrow cbNameRange,
) {
	if (!mayAdd(ctx.alloc, builder, added))
		addDiagAssertSameUri(ctx, cbNameRange(added), Diag(DiagDuplicateDeclaration(kind, getName(added))));
}

immutable struct SpecFlagsAndParents {
	bool isBuiltin;
	SpecInst*[] parents;
}

SpecFlagsAndParents checkSpecModifiers(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	ref DelaySpecInsts delaySpecInsts,
	in TypeParams typeParamsScope,
	in ModifierAst[] asts,
) {
	bool builtin = false;
	immutable SpecInst*[] parents = mapOp!(immutable SpecInst*, ModifierAst)(ctx.alloc, asts, (ref ModifierAst ast) =>
		ast.matchIn!(Opt!(SpecInst*))(
			(in ModifierKeywordAst x) {
				switch (x.keyword) {
					case ModifierKeyword.builtin:
						if (builtin)
							addDiag(ctx, x.keywordRange, Diag(DiagModifierDuplicate(x.keyword)));
						modifierTypeArgInvalid(ctx, x);
						builtin = true;
						break;
					default:
						addDiag(ctx, x.keywordRange, Diag(DiagModifierInvalid(x.keyword, DeclKind.spec)));
						break;
				}
				return none!(SpecInst*);
			},
			(in SpecUseAst x) =>
				specFromAst(
					ctx, commonTypes, structsAndAliasesMap, specsMap, typeParamsScope, x,
					someMut(ptrTrustMe(delaySpecInsts)))));
	return SpecFlagsAndParents(builtin, parents);
}

SpecsMap buildSpecsMap(ref CheckCtx ctx, SpecDecl[] specs) {
	MutHashTable!(immutable SpecDecl*, Symbol, specDeclName) builder;
	foreach (ref SpecDecl spec; specs)
		addToDeclsMap!(immutable SpecDecl*)(
			ctx, builder, &spec, DiagDuplicateDeclarationKind.spec, (in SpecDecl* x) =>
				x.nameRange);
	return moveToImmutable(builder);
}

Module* checkWorkerAfterCommonTypes(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	StructAlias[] structAliases,
	StructDecl[] structs,
	Uri uri,
	Config* config,
	ref ImportsAndReExports importsAndReExports,
	FileAst* ast,
) {
	checkStructBodies(ctx, commonTypes, structsAndAliasesMap, structs, ast.structs);

	VarDecl[] vars = mapPointers(ctx.alloc, ast.vars, (VarDeclAst* ast) =>
		checkVarDecl(ctx, commonTypes, structsAndAliasesMap, ast));
	SpecDecl[] specs = checkSpecDeclsInitial(ctx, commonTypes, structsAndAliasesMap, ast.specs);
	SpecsMap specsMap = buildSpecsMap(ctx, specs);
	checkSpecBodies(ctx, commonTypes, structsAndAliasesMap, specsMap, ast.specs, specs);
	FunsAndMap funsAndMap = checkFuns(
		ctx,
		commonTypes,
		specsMap,
		structs,
		structsAndAliasesMap,
		vars,
		importsAndReExports.fileImports,
		importsAndReExports.fileExports,
		ast.funs,
		ast.tests);
	checkDocComments(
		ctx, commonTypes,
		structsAndAliasesMap, specsMap, funsAndMap.funsMap,
		structAliases, structs, specs, vars, funsAndMap.funs, funsAndMap.tests);
	DocCommentReferences moduleDocCommentReferences = checkDocCommentReferences(
		ctx, commonTypes, structsAndAliasesMap, specsMap, funsAndMap.funsMap,
		emptyTypeParams, emptySpecs, ast.docComment);
	SmallArray!ImportOrExport imports = finishImports(ctx);
	checkForUnused(ctx, structAliases, structs, specs, funsAndMap.funs);
	return allocate(ctx.alloc, Module(
		uri,
		config,
		ast,
		finishDiagnostics(ctx),
		imports,
		importsAndReExports.moduleReExports,
		small!StructAlias(structAliases),
		small!StructDecl(structs),
		small!VarDecl(vars),
		small!SpecDecl(specs),
		funsAndMap.funs,
		funsAndMap.tests,
		getAllExports(ctx, importsAndReExports.moduleReExports, structsAndAliasesMap, specsMap, funsAndMap.funsMap),
		moduleDocCommentReferences));
}

HashTable!(NameReferents, Symbol, nameFromNameReferents) getAllExports(
	ref CheckCtx ctx,
	in ImportOrExport[] reExports,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	in FunsMap funsMap,
) {
	MutHashTable!(NameReferents, Symbol, nameFromNameReferents) res;

	void addExport(NameReferents toAdd, Range delegate() @safe @nogc pure nothrow range) {
		insertOrUpdate!(NameReferents, Symbol, nameFromNameReferents)(
			ctx.alloc,
			res,
			toAdd.name,
			() => toAdd,
			(ref NameReferents prev) {
				Opt!(DiagDuplicateExportsKind) kind = has(prev.structOrAlias) && has(toAdd.structOrAlias)
					? some(DiagDuplicateExportsKind.type)
					: has(prev.spec) && has(toAdd.spec)
					? some(DiagDuplicateExportsKind.spec)
					: none!DiagDuplicateExportsKind;
				if (has(kind))
					addDiag(ctx, range(), Diag(DiagDuplicateExports(force(kind), nameFromNameReferents(toAdd))));
				return NameReferents(
					has(prev.structOrAlias) ? prev.structOrAlias : toAdd.structOrAlias,
					has(prev.spec) ? prev.spec : toAdd.spec,
					concatenate(ctx.alloc, prev.funs, toAdd.funs));
			});
	}

	foreach (ref ImportOrExport e; reExports)
		force(e.source).kind.matchIn!void(
			(in ImportWholeModuleAst m) {
				// TODO: if this is a re-export of another library, only re-export the public members
				foreach (NameReferents referents; e.module_.exports)
					addExport(referents, () => force(e.source).pathRange);
			},
			(in NameAndRange[]) {
				foreach (ref immutable NameReferents* x; e.imported)
					addExport(*x, () => force(e.source).pathRange);
			},
			(in ImportFileAst _) {
				assert(false);
			});
	foreach (StructOrAlias x; structsAndAliasesMap)
		final switch (x.visibility) {
			case Visibility.private_:
				break;
			case Visibility.internal:
			case Visibility.public_:
				addExport(NameReferents(some(x), none!(SpecDecl*), []), () => x.range.range);
				break;
		}
	foreach (immutable SpecDecl* x; specsMap)
		final switch (x.visibility) {
			case Visibility.private_:
				break;
			case Visibility.internal:
			case Visibility.public_:
				addExport(NameReferents(none!StructOrAlias, some(x), []), () => x.range.range);
				break;
		}
	foreach (immutable FunDecl*[] funs; funsMap) {
		immutable FunDecl*[] funDecls = filter!(immutable FunDecl*)(ctx.alloc, funs, (in immutable FunDecl* x) =>
			x.visibility != Visibility.private_);
		if (!isEmpty(funDecls))
			// Last argument doesn't matter because a function never results in a duplicate export error
			addExport(NameReferents(none!StructOrAlias, none!(SpecDecl*), funDecls), () => Range.empty);
	}

	return moveToImmutable(res);
}

BootstrapCheck checkWorker(
	ref Alloc alloc,
	scope ref Perf perf,
	ref AllInsts allInsts,
	in CommonUris commonUris,
	in ResolvedImport[] resolvedImports,
	ref UriAndAst uriAndAst,
	in CommonTypes* delegate(ref CheckCtx, in StructsAndAliasesMap) @safe @nogc pure nothrow getCommonTypes,
) =>
	withMeasure!(BootstrapCheck, () {
		ArrayBuilder!Diagnostic diagsBuilder;
		ImportsAndReExports importsAndReExports = checkImportsAndReExports(
			alloc, diagsBuilder, uriAndAst.ast, resolvedImports);
		FileAst* ast = uriAndAst.ast;
		CheckCtx ctx = CheckCtx(
			ptrTrustMe(alloc),
			InstantiateCtx(ptrTrustMe(perf), ptrTrustMe(allInsts)),
			ptrTrustMe(commonUris),
			uriAndAst.uri,
			uriAndAst.config,
			importsAndReExports.modules,
			ptrTrustMe(diagsBuilder));

		// Since structs may refer to each other, first get a structsAndAliasesMap, *then* fill in bodies
		StructDecl[] structs = checkStructsInitial(ctx, ast.structs);
		StructAlias[] structAliases = checkStructAliasesInitial(ctx, ast.structAliases);
		StructsAndAliasesMap structsAndAliasesMap = buildStructsAndAliasesMap(ctx, structs, structAliases);

		CommonTypes* commonTypes = getCommonTypes(ctx, structsAndAliasesMap);

		checkStructAliasTargets(ctx, *commonTypes, structsAndAliasesMap, structAliases, ast.structAliases);

		Module* res = checkWorkerAfterCommonTypes(
			ctx,
			*commonTypes,
			structsAndAliasesMap,
			structAliases,
			structs,
			uriAndAst.uri,
			uriAndAst.config,
			importsAndReExports,
			ast);
		return BootstrapCheck(res, commonTypes);
	})(perf, alloc, PerfMeasure.check);

immutable struct ImportsAndReExports {
	@safe @nogc pure nothrow:

	SmallArray!ImportOrExport moduleImports;
	SmallArray!ImportOrExport moduleReExports;
	SmallArray!ImportOrExportFile fileImports;
	SmallArray!ImportOrExportFile fileExports;

	ImportAndReExportModules modules() =>
		ImportAndReExportModules(moduleImports, moduleReExports);
}

ImportsAndReExports checkImportsAndReExports(
	ref Alloc alloc,
	scope ref ArrayBuilder!Diagnostic diagsBuilder,
	FileAst* ast,
	in ResolvedImport[] resolvedImports,
) {
	scope ResolvedImport[] resolvedImportsLeft = resolvedImports;
	ImportsOrReExports imports = checkImportsOrReExports(
		alloc, diagsBuilder, ast.imports, resolvedImportsLeft, !ast.noStd);
	ImportsOrReExports reExports = checkImportsOrReExports(
		alloc, diagsBuilder, ast.reExports, resolvedImportsLeft, false);
	assert(isEmpty(resolvedImportsLeft));
	return ImportsAndReExports(imports.modules, reExports.modules, imports.files, reExports.files);
}

immutable struct ImportsOrReExports {
	SmallArray!ImportOrExport modules;
	SmallArray!ImportOrExportFile files;
}
ImportsOrReExports checkImportsOrReExports(
	ref Alloc alloc,
	scope ref ArrayBuilder!Diagnostic diagsBuilder,
	in Opt!ImportsOrExportsAst ast,
	scope ref ResolvedImport[] resolvedImports,
	bool includeStd,
) {
	ArrayBuilder!ImportOrExport imports;
	ArrayBuilder!ImportOrExportFile fileImports;

	ResolvedImport nextResolvedImport() {
		ResolvedImport res = resolvedImports[0];
		resolvedImports = resolvedImports[1 .. $];
		return res;
	}

	void handleModuleImport(
		Opt!(ImportOrExportAst*) source,
		ExportVisibility minVisibility,
		in void delegate(ref ImportOrExport) @safe @nogc pure nothrow cbInitImported,
	) {
		nextResolvedImport().matchWithPointers!void(
			(Module* x) {
				add(alloc, imports, ImportOrExport(source, x, minVisibility));
				cbInitImported(mustPeek!ImportOrExport(imports));
			},
			(FileContent*) {
				assert(false);
			},
			(DiagImportFile* x) {
				add(alloc, diagsBuilder, Diagnostic(has(source) ? force(source).pathRange : Range.empty, Diag(x)));
			});
	}

	if (includeStd)
		handleModuleImport(none!(ImportOrExportAst*), ExportVisibility.public_, (ref ImportOrExport _) {});

	if (has(ast))
		foreach (ref ImportOrExportAst importAst; force(ast).paths) {
			ExportVisibility importVisibility = importMinVisibility(importAst);
			importAst.kind.match!void(
				(ImportWholeModuleAst _) {
					handleModuleImport(some(&importAst), importVisibility, (ref ImportOrExport) {});
				},
				(NameAndRange[] names) {
					handleModuleImport(some(&importAst), importVisibility, (ref ImportOrExport x) {
						x.imported = checkNamedImports(alloc, diagsBuilder, importVisibility, x.modulePtr, names);
					});
				},
				(ref ImportFileAst x) {
					nextResolvedImport().matchWithPointers!void(
						(Module*) {
							assert(false);
						},
						(FileContent* x) {
							add(alloc, fileImports, ImportOrExportFile(&importAst, x));
						},
						(DiagImportFile* x) {
							add(alloc, diagsBuilder, Diagnostic(importAst.pathRange, Diag(x)));
						});
				});
		}
	return ImportsOrReExports(smallFinish(alloc, imports), smallFinish(alloc, fileImports));
}

ExportVisibility importMinVisibility(in ImportOrExportAst a) =>
	a.path.matchIn!ExportVisibility(
		(in Path _) => ExportVisibility.public_,
		(in RelPath _) => ExportVisibility.internal);

ImportedReferents checkNamedImports(
	ref Alloc alloc,
	scope ref ArrayBuilder!Diagnostic diagsBuilder,
	ExportVisibility importVisibility,
	Module* module_,
	in NameAndRange[] names,
) =>
	buildHashTable((scope ref MutHashTable!(NameReferents*, Symbol, nameFromNameReferentsPointer) res) {
		foreach (ref NameAndRange name; names) {
			Opt!(NameReferents*) referents = getPointer!(NameReferents, Symbol, nameFromNameReferents)(
				module_.exports, name.name);
			if (!has(referents) || !hasVisibility(*force(referents), importVisibility))
				add(alloc, diagsBuilder, Diagnostic(name.range, Diag(DiagImportRefersToNothing(name.name))));
			else if (!mayAdd(alloc, res, force(referents)))
				add(alloc, diagsBuilder, Diagnostic(name.range, Diag(DiagDuplicateImportName(name.name))));
		}
	});

bool hasVisibility(in NameReferents a, ExportVisibility visibility) =>
	(has(a.structOrAlias) && importCanSee(visibility, force(a.structOrAlias).visibility)) ||
	(has(a.spec) && importCanSee(visibility, force(a.spec).visibility)) ||
	exists(a.funs, (in FunDecl* x) =>
		importCanSee(visibility, x.visibility));
