module frontend.check.checkCtx;

@safe @nogc pure nothrow:

import frontend.check.instantiate : InstantiateCtx;
import model.ast : ImportFileAst, ImportWholeModuleAst, NameAndRange, typeParamsRange, VisibilityAndRange;
import model.model :
	Config,
	DeclKind,
	Diag,
	Diagnostic,
	DiagUnusedImport,
	DiagUnusedPrivateDecl,
	DiagVisibilityWarning,
	DiagTypeParamsUnsupported,
	ExportVisibility,
	FunDecl,
	importCanSee,
	ImportOrExport,
	nameFromNameReferents,
	nameFromNameReferentsPointer,
	NameReferents,
	SpecDecl,
	StructAlias,
	StructDecl,
	StructOrAlias,
	SumTypeMembership,
	sumTypeMemberGetter,
	TypeParams,
	Visibility;
import util.alloc.alloc : Alloc;
import util.col.array : exists, isEmpty, mustFind, SmallArray;
import util.col.arrayBuilder : add, ArrayBuilder, smallFinish;
import util.col.enumMap : EnumMap;
import util.col.hashTable : getPointer, HashTable, isEmpty, moveToImmutable, mustAdd, MutHashTable;
import util.col.mutSet : mayAddToMutSet, MutSet;
import util.opt : force, has, none, Opt, some;
import util.perf : Perf;
import util.sourceRange : Range, UriAndRange;
import util.symbol : Symbol;
import util.uri : Uri;

struct CheckCtx {
	@safe @nogc pure nothrow:

	Alloc* allocPtr;
	InstantiateCtx instantiateCtx;
	immutable CommonUris* commonUrisPtr;
	immutable Uri curUri;
	immutable Config* config;
	ImportAndReExportModules importsAndReExports;
	ArrayBuilder!Diagnostic* diagnosticsBuilderPtr;
	UsedSet used;

	ref Perf perf() return scope =>
		instantiateCtx.perf;

	@trusted ref Alloc alloc() return scope =>
		*allocPtr;

	ref CommonUris commonUris() return scope const =>
		*commonUrisPtr;

	ref ArrayBuilder!Diagnostic diagnosticsBuilder() return scope =>
		*diagnosticsBuilderPtr;
}

enum CommonModule {
	array,
	bootstrap,
	alloc,
	boolLowLevel,
	compare,
	exceptionLowLevel,
	futureLowLevel,
	js,
	json,
	misc,
	mutArray,
	numberLowLevel,
	pointer,
	runtime,
	runtimeMain,
	std,
	string_,
	symbolLowLevel,
	testRunner,
}
alias CommonUris = immutable EnumMap!(CommonModule, Uri);

private struct UsedSet {
	private MutSet!(immutable void*) used;
}

private bool isUsed(in UsedSet a, in immutable void* value) =>
	value in a.used;

private void markUsed(ref Alloc alloc, scope ref UsedSet a, immutable void* value) {
	mayAddToMutSet(alloc, a.used, value);
}

void markUsed(ref CheckCtx ctx, immutable void* a) {
	markUsed(ctx.alloc, ctx.used, a);
}
void markUsed(ref CheckCtx ctx, StructOrAlias a) {
	markUsed(ctx, a.asVoidPointer);
}

void checkForUnused(ref CheckCtx ctx, StructAlias[] aliases, StructDecl[] structs, SpecDecl[] specs, FunDecl[] funs) {
	void checkUnusedDecl(T)(T* decl, in bool delegate() @safe @nogc pure nothrow cbAltIsUsed) {
		if (decl.visibility == Visibility.private_ && !(isUsed(ctx.used, decl) || cbAltIsUsed()))
			addDiagAssertSameUri(ctx, decl.nameRange, Diag(DiagUnusedPrivateDecl(decl.name)));
	}
	foreach (ref StructAlias alias_; aliases)
		checkUnusedDecl(&alias_, () => false);
	foreach (ref StructDecl struct_; structs)
		checkUnusedDecl(&struct_, () =>
			// Even if the struct is not used as a type, it's used if it's accessed as a sumtype member
			exists!SumTypeMembership(struct_.sumTypeMemberships, (in SumTypeMembership x) =>
				isUsed(ctx.used, sumTypeMemberGetter(funs, &struct_, x))));
	foreach (ref SpecDecl spec; specs)
		checkUnusedDecl(&spec, () => false);
	foreach (ref FunDecl fun; funs)
		if (!fun.okIfUnused)
			checkUnusedDecl(&fun, () => false);
}

SmallArray!ImportOrExport finishImports(ref CheckCtx ctx) {
	foreach (ref ImportOrExport import_; ctx.importsAndReExports.imports) {
		if (import_.isStd) {
			import_.imported = collectImported(ctx, import_);
			continue;
		}

		void addDiagUnused(Range range, Opt!Symbol name) {
			addDiag(ctx, range, Diag(DiagUnusedImport(import_.modulePtr, name)));
		}
		force(import_.source).kind.match!void(
			(ImportWholeModuleAst x) {
				import_.imported = collectImported(ctx, import_);
				if (isEmpty(import_.imported))
					addDiagUnused(force(import_.source).pathRange, none!Symbol);
			},
			(NameAndRange[] names) {
				foreach (const NameReferents* x; import_.imported)
					if (!containsUsed(*x, import_.importVisibility, ctx.used))
						addDiagUnused(
							mustFind!NameAndRange(names, (ref NameAndRange nr) => nr.name == x.name).range,
							some(x.name));
			},
			(ref ImportFileAst _) {
				assert(false);
			});
	}
	return ctx.importsAndReExports.imports;
}
private HashTable!(NameReferents*, Symbol, nameFromNameReferentsPointer) collectImported(
	ref CheckCtx ctx,
	ref ImportOrExport import_,
) {
	MutHashTable!(NameReferents*, Symbol, nameFromNameReferentsPointer) res;
	foreach (ref NameReferents nr; import_.module_.exports) {
		if (containsUsed(nr, import_.importVisibility, ctx.used))
			mustAdd(ctx.alloc, res, &nr);
	}
	return moveToImmutable(res);
}

private bool containsUsed(in NameReferents a, ExportVisibility importVisibility, in UsedSet used) =>
	(has(a.structOrAlias) &&
		importCanSee(importVisibility, force(a.structOrAlias).visibility) &&
		isUsed(used, force(a.structOrAlias).asVoidPointer)) ||
	(has(a.spec) && importCanSee(importVisibility, force(a.spec).visibility) && isUsed(used, force(a.spec))) ||
	exists!(immutable FunDecl*)(a.funs, (in FunDecl* x) =>
		importCanSee(importVisibility, x.visibility) && isUsed(used, x));

immutable struct ImportAndReExportModules {
	SmallArray!ImportOrExport imports;
	SmallArray!ImportOrExport reExports;
}

void eachImportAndReExport(
	ref ImportAndReExportModules a,
	Symbol name,
	// Caller is responsible for filtering by visibility
	in void delegate(ExportVisibility, in NameReferents) @safe @nogc pure nothrow cb,
) {
	void inner(ref ImportOrExport import_) {
		if (import_.isStd) {
			Opt!NameReferents x = import_.modulePtr.exports[name];
			if (has(x)) cb(import_.importVisibility, force(x));
		} else {
			Opt!(NameReferents*) res = force(import_.source).kind.match!(Opt!(NameReferents*))(
				(ImportWholeModuleAst _) =>
					getPointer!(NameReferents, Symbol, nameFromNameReferents)(import_.modulePtr.exports, name),
				(NameAndRange[]) =>
					import_.imported[name],
				(ref ImportFileAst _) =>
					assert(false));
			if (has(res))
				cb(import_.importVisibility, *force(res));
		}
	}

	foreach (ref ImportOrExport x; a.imports)
		inner(x);
	foreach (ref ImportOrExport x; a.reExports)
		inner(x);
}

void addDiagAssertSameUri(ref CheckCtx ctx, in UriAndRange range, Diag diag) {
	assert(range.uri == ctx.curUri);
	addDiag(ctx, range.range, diag);
}

void addDiag(ref CheckCtx ctx, in Range range, Diag diag) {
	add(ctx.alloc, ctx.diagnosticsBuilder, Diagnostic(range, diag));
}

SmallArray!Diagnostic finishDiagnostics(ref CheckCtx ctx) =>
	smallFinish(ctx.alloc, ctx.diagnosticsBuilder);

Visibility visibilityFromDefaultWithDiag(
	scope ref CheckCtx ctx,
	Visibility default_,
	in Opt!VisibilityAndRange explicit,
	DiagVisibilityWarning.Kind kind,
) {
	if (has(explicit)) {
		Visibility actual = force(explicit).visibility;
		if (actual < default_)
			return actual;
		else {
			addDiag(ctx, force(explicit).range, Diag(DiagVisibilityWarning(kind, default_, actual)));
			return default_;
		}
	} else
		return default_;
}

Visibility visibilityFromExplicitTopLevel(Opt!VisibilityAndRange a) =>
	has(a)
		? force(a).visibility
		: Visibility.internal;

void checkNoTypeParams(ref CheckCtx ctx, in TypeParams typeParams, DeclKind declKind) {
	if (!isEmpty(typeParams))
		addDiag(ctx, typeParamsRange(typeParams), Diag(DiagTypeParamsUnsupported(declKind)));
}
