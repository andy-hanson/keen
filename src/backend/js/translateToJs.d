module backend.js.translateToJs;

@safe @nogc pure nothrow:

import backend.js.allUsed :
	actualMainFun,
	AllUsed,
	allUsed,
	eachNameReferent,
	eachStructAliasInImports,
	isModuleUsed,
	isUsedAnywhere,
	isUsedInModule;
import backend.js.jsAst :
	compareJsName,
	exprStatement,
	genArray,
	genArrowFunction,
	genAssign,
	genBinary,
	genBitwiseAnd,
	genBitwiseNot,
	genBlockStatement,
	genCall,
	genCallPropertySync,
	genCallSync,
	genConst,
	genEqEqEq,
	genField,
	genGlobal,
	genIdentifier,
	genIf,
	genInstanceMethod,
	genInteger,
	genIntegerUnsigned,
	genNew,
	genNotEqEq,
	genNull,
	genNumber,
	genObject,
	genPlus,
	genPropertyAccess,
	genReturn,
	genStaticMethod,
	genString,
	genThis,
	genThrow,
	JsBinaryExpr,
	JsBlockStatement,
	JsClassDecl,
	JsClassMember,
	JsDecl,
	JsDeclKind,
	JsDestructure,
	JsExpr,
	JsImport,
	JsMemberName,
	JsModuleAst,
	JsName,
	JsParams,
	JsScriptAst,
	JsStatement,
	Shebang,
	SyncOrAsync;
import backend.js.sourceMap : JsAndMap, ModulePaths, Source;
import backend.js.translateExpr : genAssertType, translateFunDecl, translateTest, variantMethodImpl;
import backend.js.translateModuleCtx :
	aliasSource,
	funSource,
	jsNameForDecl,
	makeDecl,
	ModuleExportMangledNames,
	structSource,
	translateFunReference,
	TranslateProgramCtx,
	TranslateModuleCtx,
	translateStructReference;
import backend.js.writeJsAst : writeJsModuleAst, writeJsScriptAst;
import frontend.showModel : ShowTypeCtx;
import model.ast : ImportOrExportAstKind;
import model.model :
	AnyDecl,
	allExterns,
	BuildTarget,
	BuiltinType,
	Called,
	EnumOrFlagsMember,
	FunDecl,
	getAllFlagsValue,
	hasFatalDiagnostics,
	ImportOrExport,
	isSigned,
	isTuple,
	MainFun,
	Module,
	moduleAtUri,
	nameFromNameReferentsPointer,
	NameReferents,
	Program,
	ProgramWithMain,
	RecordField,
	Signature,
	SpecDecl,
	StructAlias,
	StructBody,
	StructDecl,
	Test,
	TestSelector,
	UnionMember,
	VarDecl,
	VariantAndMethodImpls,
	Visibility;
import util.alloc.alloc : Alloc;
import util.cell : Cell, cellGet, cellSet;
import util.col.array :
	emptySmallArray, isEmpty, map, mapOp, newArray, newSmallArray, SmallArray, zipPointers;
import util.col.arrayBuilder : add, addAll, ArrayBuilder, buildArray, Builder, finish;
import util.col.hashTable : mustGet, withSortedKeys;
import util.col.map : Map, mustGet;
import util.col.mutArr : MutArr, push;
import util.col.mutMap : addOrChange, deleteWhere, getOrAdd, moveToMap, mustAdd, mustDelete, mustGet, MutMap;
import util.col.set : Set;
import util.col.sortUtil : sortInPlace;
import util.conv : safeToUshort;
import util.integralValues : IntegralValue;
import util.memory : allocate;
import util.opt : force, has, MutOpt, none, Opt, optIf, optFromMut, some, someMut;
import util.symbol : compareSymbolsNaturally, stringOfSymbol, Symbol, symbol;
import util.symbolSet : SymbolSet;
import util.union_ : Union;
import util.uri :
	asFilePath,
	commonAncestor,
	FilePermissions,
	parsePath,
	Path,
	PathAndContent,
	pathFromAncestor,
	RelPath,
	relativePath,
	Uri;
import util.util : castNonScope_ref, ptrTrustMe, typeAs;
import versionInfo : JsTarget, VersionInfo, versionInfoForBuildToJS;

JsAndMap translateToJsScript(
	ref Alloc alloc,
	ref ProgramWithMain program,
	in ShowTypeCtx showCtx,
	JsTarget jsTarget,
	Opt!Symbol sourceMapName,
) =>
	withTranslateProgram(alloc, program, showCtx, jsTarget, true, (ref TranslateProgramCtx ctx) =>
		writeJsScriptAst(
			alloc, showCtx, modulePaths(alloc, program.program), translateProgramToScript(ctx), sourceMapName));

immutable struct JsModules {
	Path mainJs;
	PathAndContent[] outputFiles;
}
JsModules translateToJsModules(
	ref Alloc alloc,
	ref ProgramWithMain program,
	in ShowTypeCtx showCtx,
	JsTarget jsTarget,
) =>
	withTranslateProgram(alloc, program, showCtx, jsTarget, false, (ref TranslateProgramCtx ctx) {
		ModulePaths modulePaths = modulePaths(alloc, program.program);
		// None for unused modules
		MutMap!(Module*, Opt!JsModuleAst) done;
		doTranslateModule(ctx, modulePaths, done, mainModule(program));
		return JsModules(
			modulePaths.jsPath(mainUri(program)),
			getOutputFiles(alloc, showCtx, modulePaths, done, jsTarget));
	});

private:

Out withTranslateProgram(Out)(
	ref Alloc alloc,
	ref ProgramWithMain program,
	in ShowTypeCtx showCtx,
	JsTarget jsTarget,
	bool isScript,
	in Out delegate(ref TranslateProgramCtx) @safe @nogc pure nothrow cb,
) {
	assert(!hasFatalDiagnostics(program));
	VersionInfo version_ = versionInfoForBuildToJS(jsTarget);
	SymbolSet allExterns = allExterns(program, BuildTarget.js);
	AllUsed allUsed = allUsed(alloc, program, version_, allExterns);
	TranslateProgramCtx ctx = TranslateProgramCtx(
		ptrTrustMe(alloc),
		castNonScope_ref(showCtx),
		ptrTrustMe(program),
		version_,
		jsTarget,
		allExterns,
		allUsed,
		optIf(!isScript, () =>
			moduleExportMangledNames(alloc, program.program, allUsed)));
	return cb(ctx);
}

ModulePaths modulePaths(ref Alloc alloc, in Program program) {
	Opt!Uri commonAncestor = getCommonAncestor(program);
	MutMap!(Uri, Path) res;
	foreach (ref immutable Module* module_; program.allModules)
		mustAdd(
			alloc, res, module_.uri,
			has(commonAncestor)
				? pathFromAncestor(force(commonAncestor), module_.uri)
				: asFilePath(module_.uri).path);
	return ModulePaths(moveToMap(alloc, res));
}
Opt!Uri getCommonAncestor(in Program program) {
	Cell!(Opt!Uri) res;
	foreach (ref immutable Module* module_; program.allModules) {
		if (has(cellGet(res))) {
			Opt!Uri next = commonAncestor(force(cellGet(res)), module_.uri);
			if (!has(next))
				return none!Uri;
			cellSet(res, next);
		} else {
			cellSet(res, some(module_.uri));
		}
	}
	return cellGet(res);
}

PathAndContent[] getOutputFiles(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in ModulePaths modulePaths,
	in MutMap!(Module*, Opt!JsModuleAst) done,
	JsTarget target,
) =>
	buildArray!PathAndContent(alloc, (scope ref Builder!PathAndContent out_) {
		if (target == JsTarget.node)
			out_ ~= PathAndContent(parsePath("package.json"), FilePermissions.regular, "{\"type\":\"module\"}");
		foreach (const Module* module_, ref Opt!JsModuleAst ast; done)
			if (has(ast))
				out_ ~= PathAndContent(
					modulePaths.jsPath(module_.uri),
					force(ast).shebang == Shebang.none ? FilePermissions.regular : FilePermissions.executable,
					writeJsModuleAst(alloc, showCtx, modulePaths, module_.uri, force(ast)));
	});

void doTranslateModule(
	ref TranslateProgramCtx ctx,
	in ModulePaths modulePaths,
	scope ref MutMap!(Module*, Opt!JsModuleAst) done,
	Module* a,
) {
	if (a in done) return;
	foreach (ImportOrExport x; a.imports)
		doTranslateModule(ctx, modulePaths, done, x.modulePtr);
	foreach (ImportOrExport x; a.reExports)
		doTranslateModule(ctx, modulePaths, done, x.modulePtr);
	// Test 'isModuleUsed' last, because an unused module can still have used re-exports
	mustAdd(ctx.alloc, done, a, optIf(isModuleUsed(ctx.allUsed, a), () =>
		translateModule(ctx, modulePaths, *a)));
}

JsModuleAst translateModule(ref TranslateProgramCtx ctx, in ModulePaths modulePaths, ref Module a) {
	MutMap!(StructDecl*, StructAlias*) aliases;
	JsImport[] imports = translateImports(ctx, modulePaths, a, aliases);
	JsImport[] reExports = translateReExports(ctx, modulePaths, a);
	TranslateModuleCtx moduleCtx = TranslateModuleCtx(
		ptrTrustMe(ctx),
		modulePrivateMangledNames(ctx.alloc, a, ctx.exportMangledNames, ctx.allUsed),
		moveToMap(ctx.alloc, aliases));
	JsDecl[] decls = buildArray!JsDecl(ctx.alloc, (scope ref Builder!JsDecl out_) {
		eachDeclInModule(a, (AnyDecl x) {
			if (isUsedAnywhere(ctx.allUsed, x)) {
				out_ ~= translateDecl(moduleCtx, x);
			}
		});
	});
	bool isMain = a.uri == mainUri(*ctx.programWithMainPtr);
	JsStatement[] statements = isMain
		? callMain(moduleCtx)
		: [];
	return JsModuleAst(
		isMain && !moduleCtx.isBrowser ? Shebang.node : Shebang.none,
		a.uri, imports, reExports, decls, statements);
}

Module* mainModule(ref ProgramWithMain a) =>
	moduleAtUri(a.program, mainUri(a));
Uri mainUri(in ProgramWithMain a) =>
	actualMainFun(a).moduleUri;

JsScriptAst translateProgramToScript(ref TranslateProgramCtx ctx) {
	TranslateModuleCtx moduleCtx = TranslateModuleCtx(
		ptrTrustMe(ctx),
		bundlePrivateMangledNames(ctx.alloc, ctx.allUsed),
		Map!(StructDecl*, StructAlias*)());
	JsDecl[] decls = buildArray!JsDecl(ctx.alloc, (scope ref Builder!JsDecl out_) {
		// Emit variants first, because their members need to 'extend' them.
		// Also 'tuple2' since it is used in enum/flags 'members'.
		// Emit aliases last.
		foreach (AnyDecl decl; ctx.allUsed.usedDecls)
			if (isVariantOrTuple(ctx, decl))
				out_ ~= translateDecl(moduleCtx, decl);
		foreach (AnyDecl decl; ctx.allUsed.usedDecls)
			if (!isVariantOrTuple(ctx, decl) && !decl.isA!(StructAlias*))
				out_ ~= translateDecl(moduleCtx, decl);
		foreach (AnyDecl decl; ctx.allUsed.usedDecls)
			if (decl.isA!(StructAlias*))
				out_ ~= translateDecl(moduleCtx, decl);
	});
	JsStatement[] statements = callMain(moduleCtx);
	return JsScriptAst(ctx.isBrowser ? Shebang.none : Shebang.node, decls, statements);
}
bool isVariantOrTuple(in TranslateProgramCtx ctx, in AnyDecl a) =>
	a.isA!(StructDecl*) && (
		a.as!(StructDecl*).body_.isA!(StructBody.Variant) ||
		isTuple(ctx.commonTypes, a.as!(StructDecl*)));

JsStatement[] callMain(ref TranslateModuleCtx ctx) {
	FunDecl* main = actualMainFun(*ctx.ctx.programWithMainPtr);
	Source source = funSource(ctx, main);
	JsExpr mainRef = translateFunReference(ctx, source, main);
	JsStatement[] callPlain() =>
		newArray(ctx.alloc, [exprStatement(genCallSync(ctx.alloc, source, mainRef, []))]);
	return ctx.ctx.programWithMainPtr.mainFun.matchIn!(JsStatement[])(
		(in MainFun.Nat64OfArgs) {
			JsName exitCode = JsName.specialLocal(symbol!"exitCode");
			JsExpr exitCodeNotZero = genNotEqEq(
				ctx.alloc,
				source,
				genIdentifier(source, exitCode),
				genIntegerUnsigned(source, 0));
			if (ctx.isBrowser) {
				/*
				const exit = await main(newList([]))
				if (exit !== 0n)
					throw new Error("Exited with code " + exit)
				*/
				JsExpr callMain = genCall(ctx.alloc, source, SyncOrAsync.async, mainRef, [genArray(source, [])]);
				return newArray(ctx.alloc, [
					genConst(ctx.alloc, source, exitCode, callMain),
					genIf(
						ctx.alloc,
						source,
						exitCodeNotZero,
						genThrow(ctx.alloc, source, genNew(ctx.alloc, source, genGlobal(source, symbol!"Error"), [
							genPlus(
								ctx.alloc, source,
								genString(source, "Exited with code "),
								genIdentifier(source, exitCode))])))]);
			} else {
				/*
				main(newList(process.argv.slice(2))).then(exitCode => {
					if (exitCode !== 0n)
						process.exit(Number(exitCode))
				})
				*/
				JsExpr process = genGlobal(source, symbol!"process");
				// process.argv.slice(2)
				JsExpr args = genCallPropertySync(
					ctx.alloc,
					source,
					genPropertyAccess(ctx.alloc, source, process, JsMemberName.noPrefix(symbol!"argv")),
					JsMemberName.noPrefix(symbol!"slice"),
					[genNumber(source, 2)]);
				JsExpr callMain = genCall(ctx.alloc, source, SyncOrAsync.sync, mainRef, [args]);
				JsExpr arg = genArrowFunction(ctx.alloc, source, SyncOrAsync.sync, [JsDestructure(exitCode)], [
					genIf(
						ctx.alloc,
						source,
						exitCodeNotZero,
						exprStatement(genCallPropertySync(
							ctx.alloc, source, process,
							JsMemberName.noPrefix(symbol!"exit"),
							[
								genCallSync(
									ctx.alloc, source,
									genGlobal(source, symbol!"Number"),
									[genIdentifier(source, exitCode)])])))]);
				return newArray(ctx.alloc, [
					exprStatement(genCallPropertySync(
						ctx.alloc, source, callMain, JsMemberName.noPrefix(symbol!"then"), [arg]))]);
			}
		},
		(in MainFun.Void) =>
			callPlain(),
		(in TestSelector x) =>
			callPlain());
}

ModuleExportMangledNames moduleExportMangledNames(ref Alloc alloc, in Program program, in AllUsed used) {
	MutMap!(Symbol, ushort) lastIndexForName;
	MutMap!(AnyDecl, ushort) res;

	eachExportOrTestInProgram(program, (AnyDecl decl) {
		if (isUsedAnywhere(used, decl)) {
			ushort index = addOrChange!(Symbol, ushort)(
				alloc,
				lastIndexForName,
				decl.name,
				() => ushort(0),
				(ref ushort x) { x++; });
			mustAdd(alloc, res, decl, index);
		}
	});
	// For uniquely identified decls, don't mangle
	eachExportOrTestInProgram(program, (AnyDecl decl) {
		if (isUsedAnywhere(used, decl) && mustGet(lastIndexForName, decl.name) == 0)
			mustDelete(res, decl);
	});

	return ModuleExportMangledNames(moveToMap(alloc, lastIndexForName), moveToMap(alloc, res));
}

Map!(AnyDecl, ushort) bundlePrivateMangledNames(ref Alloc alloc, in AllUsed allUsed) {
	PrivateMangledNamesBuilder builder;
	foreach (AnyDecl decl; allUsed.usedDecls)
		add(alloc, builder, none!ModuleExportMangledNames, decl);
	return finish(alloc, builder);
}

Map!(AnyDecl, ushort) modulePrivateMangledNames(
	ref Alloc alloc,
	in Module module_,
	in Opt!ModuleExportMangledNames exports,
	in AllUsed used,
) {
	PrivateMangledNamesBuilder builder;
	eachPrivateDeclInModule(module_, (AnyDecl decl) {
		if (isUsedInModule(used, module_.uri, decl)) {
			add(alloc, builder, exports, decl);
		}
	});
	return finish(alloc, builder);
}

struct PrivateMangledNamesBuilder {
	MutMap!(Symbol, ushort) lastIndexForName;
	MutMap!(AnyDecl, ushort) res;
}
void add(
	ref Alloc alloc,
	ref PrivateMangledNamesBuilder builder,
	in Opt!ModuleExportMangledNames exports,
	AnyDecl decl,
) {
	ushort index = addOrChange!(Symbol, ushort)(
		alloc, builder.lastIndexForName, decl.name,
		() {
			Opt!ushort x = has(exports) ? force(exports).lastIndexForName[decl.name] : none!ushort;
			return has(x) ? safeToUshort(force(x) + 1) : typeAs!ushort(0);
		},
		(ref ushort x) { x++; });
	mustAdd(alloc, builder.res, decl, index);
}
Map!(AnyDecl, ushort) finish(ref Alloc alloc, ref PrivateMangledNamesBuilder builder) {
	deleteWhere!(AnyDecl, ushort)(builder.res, (in AnyDecl decl, in ushort value) =>
		mustGet(builder.lastIndexForName, decl.name) == 0);
	return moveToMap(alloc, builder.res);
}

void eachExportOrTestInProgram(ref Program a, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	foreach (ref immutable Module* x; a.allModules)
		eachExportOrTestInModule(*x, cb);
}

void eachPrivateDeclInModule(ref Module a, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	eachDeclInModule(a, (AnyDecl x) {
		if (x.visibility == Visibility.private_)
			cb(x);
	});
}
void eachExportOrTestInModule(ref Module a, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	eachDeclInModule(a, (AnyDecl x) {
		if (x.visibility != Visibility.private_)
			cb(x);
	});
}
void eachDeclInModule(ref Module a, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	foreach (ref StructAlias x; a.aliases)
		cb(AnyDecl(&x));
	foreach (ref StructDecl x; a.structs)
		cb(AnyDecl(&x));
	foreach (ref VarDecl x; a.vars)
		cb(AnyDecl(&x));
	foreach (ref SpecDecl x; a.specs)
		cb(AnyDecl(&x));
	foreach (ref FunDecl x; a.funs)
		cb(AnyDecl(&x));
	foreach (ref Test x; a.tests)
		cb(AnyDecl(&x));
}

JsImport[] translateImports(
	ref TranslateProgramCtx ctx,
	in ModulePaths modulePaths,
	in Module module_,
	scope ref MutMap!(StructDecl*, StructAlias*) aliases,
) {
	eachStructAliasInImports(module_, (StructAlias* alias_, StructDecl* target) {
		if (isUsedInModule(ctx.allUsed, module_.uri, AnyDecl(target)))
			// If multiple aliases, just use the first
			getOrAdd!(StructDecl*, StructAlias*)(ctx.alloc, aliases, target, () => alias_);
	});

	Opt!(Set!AnyDecl) opt = ctx.allUsed.usedByModule[module_.uri];
	if (has(opt)) {
		Path importerPath = modulePaths.jsPath(module_.uri);
		MutMap!(Uri, MutArr!AnyDecl) byModule;
		foreach (AnyDecl x; force(opt))
			if (x.moduleUri != module_.uri)
				push(ctx.alloc, getOrAdd(ctx.alloc, byModule, x.moduleUri, () => MutArr!AnyDecl()), x);
		return buildArray!JsImport(ctx.alloc, (scope ref Builder!JsImport outImports) {
			foreach (Uri importedUri, ref MutArr!AnyDecl decls; byModule) {
				JsName[] names = buildArray!JsName(ctx.alloc, (scope ref Builder!JsName out_) {
					foreach (ref const AnyDecl decl; decls)
						out_ ~= jsNameForDecl(decl, force(ctx.exportMangledNames).mangledNames[decl]);
				});
				sortInPlace!(JsName, compareJsName)(names);
				outImports ~= JsImport(some(names), relativePath(importerPath, modulePaths.jsPath(importedUri)));
			}
		});
	} else
		return [];
}

JsImport[] translateReExports(ref TranslateProgramCtx ctx, in ModulePaths modulePaths, in Module module_) {
	Path importerPath = modulePaths.jsPath(module_.uri);
	return mapOp!(JsImport, ImportOrExport)(ctx.alloc, module_.reExports, (ref ImportOrExport x) {
		RelPath relPath() => relativePath(importerPath, modulePaths.jsPath(x.module_.uri));
		if (isImportModuleWhole(x))
			return optIf(isModuleUsed(ctx.allUsed, x.modulePtr), () =>
				JsImport(none!(JsName[]), relPath));
		else {
			JsName[] names = buildArray(ctx.alloc, (scope ref Builder!JsName out_) {
				withSortedKeys!(void, NameReferents*, Symbol, nameFromNameReferentsPointer)(
					x.imported,
					(in Symbol x, in Symbol y) => compareSymbolsNaturally(x, y),
					(in Symbol[] names) {
						foreach (Symbol name; names) {
							eachNameReferent(*mustGet(x.imported, name), (AnyDecl decl) {
								if (isUsedAnywhere(ctx.allUsed, decl))
									out_ ~= jsNameForDecl(decl, force(ctx.exportMangledNames).mangledNames[decl]);
							});
						}
					});
			});
			return optIf(!isEmpty(names), () => JsImport(some(names), relPath));
		}
	});
}
bool isImportModuleWhole(in ImportOrExport x) =>
	!has(x.source) || force(x.source).kind.isA!(ImportOrExportAstKind.ModuleWhole);

JsDecl translateDecl(ref TranslateModuleCtx ctx, AnyDecl x) =>
	x.matchWithPointers!JsDecl(
		(FunDecl* x) =>
			translateFunDecl(ctx, x),
		(SpecDecl* x) =>
			assert(false),
		(StructAlias* x) =>
			translateStructAlias(ctx, x),
		(StructDecl* x) =>
			translateStructDecl(ctx, x),
		(Test* x) =>
			translateTest(ctx, x),
		(VarDecl* x) =>
			translateVarDecl(ctx, x));

JsDecl translateStructAlias(ref TranslateModuleCtx ctx, StructAlias* a) =>
	makeDecl(ctx, AnyDecl(a), JsDeclKind(translateStructReference(ctx, aliasSource(ctx, a), a.target.decl)));

JsDecl translateStructDecl(ref TranslateModuleCtx ctx, StructDecl* a) {
	Source source = structSource(ctx, a);
	// Normally we don't bother to inherit from variants
	// (which is not always doable since there may be more than one variant).
	// However, it's important to inherit from Error so it can set the stack trace.
	MutOpt!(JsExpr*) extends;
	JsClassMember[] members = buildArray!JsClassMember(ctx.alloc, (scope ref Builder!JsClassMember out_) {
		foreach (ref VariantAndMethodImpls v; a.variants) {
			if (v.variant == ctx.commonTypes.exception)
				extends = someMut(allocate(ctx.alloc, translateStructReference(ctx, source, v.variant.decl)));
		}
		Opt!Super super_ = optIf(has(extends), () => Super(emptySmallArray!JsExpr, callFinishConstructor: true));

		a.body_.match!void(
			(StructBody.Bogus) =>
				assert(false),
			(BuiltinType x) =>
				assert(false),
			(ref StructBody.Enum x) {
				translateEnumDecl(ctx, source, out_, super_, x);
			},
			(StructBody.Extern) {},
			(StructBody.Flags x) =>
				translateFlagsDecl(ctx, source, out_, a, super_, x),
			(StructBody.Record x) {
				translateRecordDecl(ctx, source, out_, super_, x);
			},
			(ref StructBody.Union x) {
				translateUnionDecl(ctx, source, out_, super_, x);
			},
			(StructBody.Variant) {
				if (a == ctx.commonTypes.exception.decl) {
					extends = someMut(allocate(ctx.alloc, genGlobal(source, symbol!"Error")));
					translateExceptionClass(ctx, source, out_);
				}
			});

		foreach (ref VariantAndMethodImpls v; a.variants)
			zipPointers(v.variantDeclMethods, v.methodImpls, (Signature* sig, Opt!Called* impl) {
				out_ ~= variantMethodImpl(ctx, sig, *impl);
			});
	});
	return makeDecl(ctx, AnyDecl(a), JsDeclKind(JsClassDecl(optFromMut!(JsExpr*)(extends), members)));
}

void translateExceptionClass(ref TranslateModuleCtx ctx, in Source source, scope ref Builder!JsClassMember out_) {
	// constructor() { super("<<message>>") }
	JsMemberName messageName = JsMemberName.noPrefix(symbol!"message");
	JsExpr messagePlaceholder = genString(source, "<<message>>");
	out_ ~= genConstructor(
		ctx.alloc, source, [],
		some(Super(newSmallArray!JsExpr(ctx.alloc, [messagePlaceholder]))),
		[]);

	/*:
	"finish-constructor"() {
		this.message = this.v_show()
		this.stack = this.stack.replace("<<message>>", this.message)
	}
	*/
	JsExpr this_ = genThis(source);
	JsExpr callDescribe = genCallPropertySync(ctx.alloc, source, this_, JsMemberName.variantMethod(symbol!"show"), []);
	JsExpr this_message = genPropertyAccess(ctx.alloc, source, this_, messageName);
	JsExpr this_stack = genPropertyAccess(ctx.alloc, source, this_, JsMemberName.noPrefix(symbol!"stack"));
	out_ ~= genInstanceMethod(
		ctx.alloc,
		source,
		SyncOrAsync.sync,
		finishConstructorName,
		[],
		[
			genAssign(ctx.alloc, source, this_message, callDescribe),
			genAssign(
				ctx.alloc, source, this_stack,
				genCallPropertySync(
					ctx.alloc,
					source,
					this_stack,
					JsMemberName.noPrefix(symbol!"replace"),
					[messagePlaceholder, this_message])),
		]);
}

JsMemberName finishConstructorName = JsMemberName.special(symbol!"finish-constructor");

void translateEnumDecl(
	ref TranslateModuleCtx ctx,
	in Source source,
	scope ref Builder!JsClassMember out_,
	Opt!Super super_,
	in StructBody.Enum a,
) {
	/*
	class E {
		constructor(name, value) {
			this.name = name
			this.value = value
		}
		static x = new this("x", 0n)
		static _members = [this.x]
	}
	*/
	JsName name = JsName.specialLocal(symbol!"name");
	JsName value = JsName.specialLocal(symbol!"value");
	out_ ~= genConstructor(ctx.alloc, source, [JsDestructure(name), JsDestructure(value)], super_, [
		genAssignToThis(ctx.alloc, source, JsMemberName.special(symbol!"name"), genIdentifier(source, name)),
		genAssignToThis(ctx.alloc, source, JsMemberName.special(symbol!"value"), genIdentifier(source, value))]);
	foreach (ref EnumOrFlagsMember member; a.members)
		out_ ~= genField(
			source,
			JsClassMember.Static.static_,
			JsMemberName.enumMember(member.name),
			genNew(ctx.alloc, source, genThis(source), [
				genString(source, stringOfSymbol(ctx.alloc, member.name)),
				genInteger(source, isSigned(a.storage), member.value)]));
	out_ ~= enumOrFlagsMembers(ctx, source, a.members);
}
JsStatement genAssignToThis(ref Alloc alloc, Source source, JsMemberName name, JsExpr value) =>
	genAssign(alloc, source, genPropertyAccess(alloc, source, genThis(source), name), value);
JsClassMember enumOrFlagsMembers(ref TranslateModuleCtx ctx, in Source source, in EnumOrFlagsMember[] members) =>
	genField(
		source,
		JsClassMember.Static.static_,
		JsMemberName.special(symbol!"members"),
		genArray(source, map(ctx.alloc, members, (ref EnumOrFlagsMember member) =>
			genPropertyAccess(ctx.alloc, source, genThis(source), JsMemberName.enumMember(member.name)))));

void translateFlagsDecl(
	ref TranslateModuleCtx ctx,
	in Source source,
	scope ref Builder!JsClassMember out_,
	in StructDecl* struct_,
	Opt!Super super_,
	in StructBody.Flags a,
) {
	/*
	class F {
		constructor(value) {
			this._value = value
		}
		static x = new this(1n)
		static y = new this(2n)
		static _none = new this(0n)
		static _members = [this.x, this.y]

		_intersect(b) {
			return new F(this._value & b._value)
		}
		_union(b) {
			return new F(this._value | b._value)
		}
		_negate() {
			return new F(~this._value & 3n)
		}
		_in(b) {
			return this._value & b._value == this._value
		}
	}
	*/
	JsName value = JsName.specialLocal(symbol!"value");
	out_ ~= genConstructor(ctx.alloc, source, [JsDestructure(value)], super_, [
		genAssignToThis(ctx.alloc, source, JsMemberName.special(symbol!"value"), genIdentifier(source, value))]);
	foreach (ref EnumOrFlagsMember member; a.members) {
		out_ ~= genField(
			source,
			JsClassMember.Static.static_,
			JsMemberName.enumMember(member.name),
			genNew(ctx.alloc, source, genThis(source), [genIntegerUnsigned(source, member.value.asUnsigned())]));
	}
	out_ ~= genField(
		source,
		JsClassMember.Static.static_,
		JsMemberName.special(symbol!"none"),
		genNew(ctx.alloc, source, genThis(source), [genIntegerUnsigned(source, 0)]));
	out_ ~= enumOrFlagsMembers(ctx, source, a.members);
	out_ ~= intersectOrUnionMethod(
		ctx, source, struct_, JsMemberName.special(symbol!"intersect"), JsBinaryExpr.Kind.bitwiseAnd);
	out_ ~= intersectOrUnionMethod(
		ctx, source, struct_, JsMemberName.special(symbol!"union"), JsBinaryExpr.Kind.bitwiseOr);
	out_ ~= negateMethod(ctx, source, struct_, getAllFlagsValue(a));
	out_ ~= flagsInMethod(ctx, source, struct_);
}
JsClassMember intersectOrUnionMethod(
	ref TranslateModuleCtx ctx,
	in Source source,
	in StructDecl* struct_,
	JsMemberName name,
	JsBinaryExpr.Kind kind,
) {
	JsName b = JsName.specialLocal(symbol!"b");
	return genInstanceMethod(
		ctx.alloc,
		structSource(ctx, struct_),
		SyncOrAsync.sync,
		name,
		[JsDestructure(b)],
		genNew(ctx.alloc, source, translateStructReference(ctx, source, struct_), [
			genBinary(
				ctx.alloc, source, kind,
				getValue(ctx.alloc, genThis(source)),
				getValue(ctx.alloc, genIdentifier(source, b)))]));
}
JsClassMember negateMethod(
	ref TranslateModuleCtx ctx,
	in Source source,
	in StructDecl* struct_,
	IntegralValue allFlagsValue,
) =>
	genInstanceMethod(
		ctx.alloc,
		source,
		SyncOrAsync.sync,
		JsMemberName.special(symbol!"negate"),
		[],
		genNew(ctx.alloc, source, translateStructReference(ctx, source, struct_), [
			genBitwiseAnd(
				ctx.alloc,
				source,
				genBitwiseNot(ctx.alloc, source, getValue(ctx.alloc, genThis(source))),
				genIntegerUnsigned(source, allFlagsValue.asUnsigned))]));
JsClassMember flagsInMethod(ref TranslateModuleCtx ctx, in Source source, in StructDecl* struct_) {
	JsName b = JsName.specialLocal(symbol!"b");
	JsExpr thisValue = getValue(ctx.alloc, genThis(source));
	JsExpr bValue = getValue(ctx.alloc, genIdentifier(source, b));
	return genInstanceMethod(
		ctx.alloc, source, SyncOrAsync.sync, JsMemberName.special(symbol!"in"), [JsDestructure(b)],
		genEqEqEq(ctx.alloc, source, genBitwiseAnd(ctx.alloc, source, thisValue, bValue), thisValue));
}
JsExpr getValue(ref Alloc alloc, JsExpr arg) =>
	genPropertyAccess(alloc, arg.source, arg, JsMemberName.special(symbol!"value"));

void translateRecordDecl(
	ref TranslateModuleCtx ctx,
	in Source source,
	scope ref Builder!JsClassMember out_,
	Opt!Super super_,
	in StructBody.Record a,
) {
	/*
	class R {
		constructor(x, fooBar) {
			this.x = x
			this["foo-bar"] = fooBar
		}
	}
	*/
	out_ ~= genConstructor(
		ctx.alloc,
		source,
		map!(JsDestructure, RecordField)(ctx.alloc, a.fields, (ref RecordField x) =>
			JsDestructure(JsName.local(x.name))),
		super_,
		(scope ref ArrayBuilder!JsStatement out_) {
			foreach (ref RecordField x; a.fields) {
				JsExpr value = genIdentifier(source, JsName.local(x.name));
				genAssertType(out_, ctx, source, x.type, value);
				add(ctx.alloc, out_, genAssignToThis(ctx.alloc, source, JsMemberName.recordField(x.name), value));
			}
		});
}

void translateUnionDecl(
	ref TranslateModuleCtx ctx,
	in Source source,
	scope ref Builder!JsClassMember out_,
	Opt!Super super_,
	in StructBody.Union a,
) {
	/*
	class U {
		constructor(arg) {
			Object.assign(this, arg)
		}
		static foo = new this({foo:null})
		static bar(value) {
			return new this({bar:value})
		}
	}
	*/
	JsName arg = JsName.specialLocal(symbol!"arg");
	out_ ~= genConstructor(ctx.alloc, source, [JsDestructure(arg)], super_, [
		exprStatement(genCallPropertySync(
			ctx.alloc,
			source,
			genGlobal(source, symbol!"Object"),
			JsMemberName.noPrefix(symbol!"assign"),
			[genThis(source), genIdentifier(source, arg)]))]);

	foreach (ref UnionMember member; a.members) {
		out_ ~= () {
			if (member.hasValue) {
				JsName value = JsName.specialLocal(symbol!"value");
				JsParams params = JsParams(newSmallArray!JsDestructure(ctx.alloc, [JsDestructure(value)]));
				ArrayBuilder!JsStatement out_;
				genAssertType(out_, ctx, source, member.type, genIdentifier(source, value));
				add(ctx.alloc, out_, genReturn(
					ctx.alloc,
					source,
					genNew(ctx.alloc, source, genThis(source), [
						genObject(
							ctx.alloc, source,
							JsMemberName.unionMember(member.name),
							genIdentifier(source, value))])));
				return genStaticMethod(
					source,
					SyncOrAsync.sync,
					JsMemberName.unionConstructor(member.name),
					params,
					genBlockStatement(ctx.alloc, finish(ctx.alloc, out_)));
			} else
				return genField(
					source,
					JsClassMember.Static.static_,
					JsMemberName.unionConstructor(member.name),
					genNew(ctx.alloc, source, genThis(source), [
						genObject(ctx.alloc, source, JsMemberName.unionMember(member.name), genNull(source))]));
		}();
	}
}

JsClassMember genConstructor(
	ref Alloc alloc,
	in Source source,
	in JsDestructure[] params,
	Opt!Super super_,
	in JsStatement[] statements,
) =>
	genConstructor(alloc, source, newSmallArray(alloc, params), super_, (scope ref ArrayBuilder!JsStatement out_) {
		addAll(alloc, out_, statements);
	});
JsClassMember genConstructor(
	ref Alloc alloc,
	in Source source,
	SmallArray!JsDestructure params,
	Opt!Super super_,
	in void delegate(scope ref ArrayBuilder!JsStatement) @safe @nogc pure nothrow cb,
) {
	ArrayBuilder!JsStatement out_;
	if (has(super_))
		add(alloc, out_, genSuper(alloc, source, force(super_).args));
	cb(out_);
	if (has(super_) && force(super_).callFinishConstructor)
		add(alloc, out_, exprStatement(genCallPropertySync(alloc, source, genThis(source), finishConstructorName, [])));
	return genInstanceMethod(
		source,
		SyncOrAsync.sync,
		JsMemberName.noPrefix(symbol!"constructor"),
		JsParams(params),
		JsBlockStatement(finish(alloc, out_)));
}

immutable struct Super {
	SmallArray!JsExpr args;
	bool callFinishConstructor;
}
JsStatement genSuper(ref Alloc alloc, in Source source, SmallArray!JsExpr args) =>
	exprStatement(genCallSync(source, allocate(alloc, genGlobal(source, symbol!"super")), args));

JsDecl translateVarDecl(ref TranslateModuleCtx ctx, VarDecl* a) =>
	makeDecl(ctx, AnyDecl(a), JsDeclKind(JsDeclKind.Let()));
