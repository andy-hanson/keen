module frontend.frontendCompile;

@safe @nogc pure nothrow:

import frontend.check.check : BootstrapCheck, check, checkBootstrap, UriAndAst, ResolvedImport;
import frontend.check.checkCtx : CommonModule, CommonUris;
import frontend.check.getCommonFuns : getCommonFuns, getMainFunAndDiagnostics;
import frontend.check.instantiate : getAllFutureAndMutArrayImpls, InstantiateCtx;
import frontend.lang : crowConfigBaseName, FileType, fileType, MainKind;
import frontend.allInsts : AllInsts, freeInstantiationsForModule, perfStats;
import frontend.storage :
	CrowConfigFileInfo,
	CrowFileInfo,
	FileContentGetters,
	FileInfo,
	FileInfoOrDiag,
	fileOrDiag,
	FilesState,
	filesState,
	LineAndColumnGetters,
	markUnknownIfNotExist,
	OtherFileInfo,
	Storage;
import model.ast : FileAst, fileAstForDiag, ImportFileAst, ImportOrExportAst, ImportWholeModuleAst, NameAndRange;
import model.model :
	BuildTarget,
	CommonFunsAndDiagnostics,
	CommonTypes,
	Config,
	Diag,
	emptyConfig,
	getConfigUri,
	getModuleUri,
	Module,
	OtherTypes,
	Program,
	ProgramWithMain,
	StructDecl;
import model.parseDiag : ParseDiag, ReadFileDiag, ReadFileDiag_;
import util.alloc.alloc :
	Alloc, AllocAndValue, allocateUninitialized, AllocKind, freeAllocAndValue, MetaAlloc, newAlloc, withAlloc;
import util.col.arrayBuilder : asTemporaryArray, Builder, smallFinish;
import util.col.array :
	concatenateIn,
	contains,
	emptyMutSmallArray,
	exists,
	every,
	findIndex,
	indexOf,
	map,
	mustFindPointer,
	MutSmallArray,
	small,
	SmallArray;
import util.col.exactSizeArrayBuilder : buildArrayExact, ExactSizeArrayBuilder;
import util.col.hashTable : getOrAdd, HashTable, mapPreservingKeys, moveToImmutable, mustGet, MutHashTable;
import util.col.enumMap : EnumMap, enumMapMapValues, makeEnumMap_mut;
import util.col.mutMaxSet : clear, mayDelete, mustAdd, MutMaxSet, popArbitrary;
import util.col.mutSet : mayAddToMutSet, MutSet, mutSetMayDelete;
import util.json : field, Json, jsonObject;
import util.memory : allocate, initMemory;
import util.opt : ConstOpt, force, has, MutOpt, Opt, noneMut, some, someMut;
import util.perf : Perf, PerfMeasure, withMeasure;
import util.symbol : Extension, Symbol, symbol;
import util.unicode : FileContent;
import util.union_ : TaggedUnion;
import util.uri :
	addExtension,
	concatUriAndPath,
	firstAndRest,
	parent,
	parentOrEmpty,
	Path,
	Uri,
	Uri,
	PathFirstAndRest,
	RelPath,
	resolveUri;
import util.util : castImmutable, ptrTrustMe, todo;

struct Frontend {
	@safe @nogc pure nothrow:
	private:
	MetaAlloc* metaAlloc;
	Alloc* allocPtr;
	Storage* storagePtr;
	Uri crowIncludeDir;
	CommonUris commonUris;
	EnumMap!(CommonModule, CrowFile*) commonFiles;
	AllInsts allInsts;
	// Set after 'bootstrap' is compiled
	MutOpt!(CommonTypes*) commonTypes;
	MutHashTable!(CrowFile*, Uri, getCrowFileUri) crowFiles;
	size_t countUncompiledCrowFiles; // Number of crowFiles without 'module_'
	MutHashTable!(OtherFile*, Uri, getOtherFileUri) otherFiles;
	// Set of files which are ready to compile immediately.
	// (Parsing and resolving imports is always done immediately.)
	// This doesn't include files whose imports are not yet compiled.
	// If all Uris are resolved but nothing is workable, there must be a circular import.
	MutMaxSet!(0x100, CrowFile*) workable;

	ref inout(Alloc) alloc() return scope inout =>
		*allocPtr;
	ref Storage storage() return scope =>
		*storagePtr;
}

Frontend* initFrontend(MetaAlloc* metaAlloc, Storage* storage, Uri crowIncludeDir) {
	return () @trusted {
		Alloc* alloc = newAlloc(AllocKind.frontend, metaAlloc);
		Frontend* res = allocateUninitialized!Frontend(*alloc);
		initMemory(res, Frontend(
			metaAlloc, alloc, storage, crowIncludeDir,
			commonUris(crowIncludeDir),
			makeEnumMap_mut!(CommonModule, CrowFile*)((CommonModule _) => null),
			AllInsts(newAlloc(AllocKind.allInsts, metaAlloc))));
		res.commonFiles = enumMapMapValues!(CommonModule, CrowFile*, Uri)(res.commonUris, (Uri uri) =>
			ensureCrowFile(*res, uri));
		return res;
	}();
}

Json perfStats(ref Alloc alloc, in Frontend a) =>
	jsonObject(alloc, [
		field!"allInsts"(perfStats(alloc, a.allInsts))]);

private struct CrowFile {
	@safe @nogc pure nothrow:

	immutable Uri uri;
	// This needs to be filled in in 3 steps: ast/config, resolvedImports/referencedBy, module

	// Ast is allocated by Storage, just referenced from here
	AstOrDiag astOrDiag;
	MutOpt!(Config*) config; // This will be some(defaultConfig) if there is no config file on the path

	MutOpt!(MutSmallArray!MostlyResolvedImport) resolvedImports; // Also includes re-exports. Set once we have config.
	MutSet!(CrowFile*) referencedBy;

	// This will be compiled only after all imports are compiled
	MutOpt!(AllocAndValue!(Module*)) moduleAndAlloc;

	bool hasModule() scope const =>
		has(moduleAndAlloc);

	Module* mustHaveModule() return scope const =>
		force(moduleAndAlloc).value;
}
private Uri getCrowFileUri(in CrowFile* a) =>
	a.uri;

private struct AstOrDiag {
	mixin TaggedUnion!(FileAst*, ReadFileDiag_);
}

private struct OtherFile {
	immutable Uri uri;
	MutOpt!(FileContent*) content; // Same reference as in OtherFileInfo
	MutSet!(CrowFile*) referencedBy;
}
private Uri getOtherFileUri(in OtherFile* a) =>
	a.uri;

ProgramWithMain makeProgramWithMain(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Frontend a,
	in MainKind main,
	in BuildTarget[] targets,
) {
	Program program = makeProgram(perf, alloc, a);
	return programWithMainFromProgram(perf, alloc, a, program, main, targets);
}

ProgramWithMain programWithMainFromProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	ref Frontend a,
	ref Program program,
	in MainKind main,
	in BuildTarget[] targets,
) =>
	ProgramWithMain(
		program,
		getMainFunAndDiagnostics(
			alloc,
			InstantiateCtx(ptrTrustMe(perf), ptrTrustMe(a.allInsts)),
			program, main, targets));

Program makeProgram(scope ref Perf perf, ref Alloc alloc, ref Frontend a) {
	assert(filesState(a.storage) == FilesState.allLoaded);
	EnumMap!(CommonModule, Module*) commonModules = enumMapMapValues!(CommonModule, Module*, CrowFile*)(
		a.commonFiles, (const CrowFile* x) => x.mustHaveModule);
	InstantiateCtx ctx = InstantiateCtx(ptrTrustMe(perf), ptrTrustMe(a.allInsts));
	CommonFunsAndDiagnostics commonFuns = getCommonFuns(a.alloc, ctx, *force(a.commonTypes), commonModules);
	StructDecl* futureImpl = mustFindPointer!StructDecl(
		commonModules[CommonModule.futureLowLevel].structs,
		(ref const StructDecl x) => x.name == symbol!"future-impl");
	StructDecl* mutArrayImpl = mustFindPointer!StructDecl(
		commonModules[CommonModule.mutArray].structs,
		(ref const StructDecl x) => x.name == symbol!"mut-array-impl");
	return Program(
		allConfigs: getAllConfigs(alloc, a),
		allModules: mapPreservingKeys!(immutable Module*, getModuleUri, CrowFile*, Uri, getCrowFileUri)(
			alloc, a.crowFiles, (ref const CrowFile* file) => file.mustHaveModule),
		fileContentGetters: castImmutable(FileContentGetters(a.storagePtr)),
		lineAndColumnGetters: castImmutable(LineAndColumnGetters(a.storagePtr)),
		commonFunsAndDiagnostics: commonFuns,
		commonTypesPtr: force(a.commonTypes),
		otherTypes: OtherTypes(getAllFutureAndMutArrayImpls(alloc, ctx, futureImpl, mutArrayImpl)));
}

void onFileChanged(scope ref Perf perf, ref Frontend a, Uri uri, FileInfoOrDiag info) {
	withMeasure!(void, () {
		final switch (fileType(uri)) {
			case FileType.crow:
				CrowFile* file = ensureCrowFile(a, uri);
				file.astOrDiag = info.match!AstOrDiag(
					(FileInfo x) =>
						AstOrDiag(&x.as!(CrowFileInfo*).ast),
					(ReadFileDiag x) {
						// Files don't change *to* unknown, only change out of that state
						assert(x != ReadFileDiag.unknown);
						return AstOrDiag(x);
					});
				updatedAstOrConfig(a, file);
				break;
			case FileType.crowConfig:
				foreach (CrowFile* file; a.crowFiles)
					updateFileOnConfigChange(a, file);
				break;
			case FileType.other:
				bool isLoading = info.matchIn!bool(
					(in FileInfo _) => false,
					(in ReadFileDiag x) {
						assert(x != ReadFileDiag.unknown);
						return x == ReadFileDiag.loading;
					});
				OtherFile* file = ensureOtherFile(a, uri);
				if (!isLoading) {
					file.content = someMut(info.match!(FileContent*)(
						(FileInfo x) =>
							&x.as!(OtherFileInfo*).content,
						(ReadFileDiag x) =>
							&FileContent.empty));
					foreach (CrowFile* x; file.referencedBy)
						addToWorkableIfSo(a, x);
				}
				break;
		}
		doDirtyWork(perf, a);
	})(perf, a.alloc, PerfMeasure.onFileChanged);
}

private:

HashTable!(immutable Config*, Uri, getConfigUri) getAllConfigs(ref Alloc alloc, in Frontend a) {
	MutHashTable!(immutable Config*, Uri, getConfigUri) res;
	foreach (const CrowFile* file; a.crowFiles) {
		Config* config = force(file.config);
		if (has(config.configUri))
			getOrAdd!(immutable Config*, Uri, getConfigUri)(alloc, res, force(config.configUri), () => config);
	}
	return moveToImmutable(res);
}

CrowFile* ensureCrowFile(ref Frontend a, Uri uri) {
	assert(fileType(uri) == FileType.crow);
	return getOrAdd!(CrowFile*, Uri, getCrowFileUri)(a.alloc, a.crowFiles, uri, () {
		markUnknownIfNotExist(a.storage, uri);
		a.countUncompiledCrowFiles++;
		return allocate(a.alloc, CrowFile(
			uri,
			AstOrDiag(ReadFileDiag.unknown),
			tryFindConfig(a.storage, parentOrEmpty(uri))));
	});
}

OtherFile* ensureOtherFile(ref Frontend a, Uri uri) {
	assert(fileType(uri) != FileType.crow);
	return getOrAdd!(OtherFile*, Uri, getOtherFileUri)(a.alloc, a.otherFiles, uri, () {
		markUnknownIfNotExist(a.storage, uri);
		return allocate(a.alloc, OtherFile(uri));
	});
}

FileAst* toAst(ref Alloc alloc, AstOrDiag x) =>
	x.matchConst!(FileAst*)(
		(const FileAst* x) => x,
		(const ReadFileDiag_ x) {
			assert(!isUnknownOrLoading(x));
			return allocate(alloc, fileAstForDiag(alloc, ParseDiag(x)));
		});

void doDirtyWork(scope ref Perf perf, ref Frontend a) {
	CrowFile* bootstrap = a.commonFiles[CommonModule.bootstrap];
	if (mayDelete(a.workable, bootstrap)) {
		bootstrap.moduleAndAlloc = someMut(withAlloc!(Module*)(AllocKind.module_, a.metaAlloc, (ref Alloc alloc) {
			UriAndAst fa = UriAndAst(bootstrap.uri, force(bootstrap.config), toAst(alloc, bootstrap.astOrDiag));
			BootstrapCheck bs = checkBootstrap(perf, alloc, a.allInsts, a.commonUris, fa);
			a.commonTypes = someMut(bs.commonTypes);
			return bs.module_;
		}));
		assert(a.countUncompiledCrowFiles > 0);
		a.countUncompiledCrowFiles--;
		markAllNonBootstrapModulesDirty(a, bootstrap); // Since they all use commonTypes
	}

	if (has(a.commonTypes)) {
		while (true) {
			MutOpt!(CrowFile*) opt = popArbitrary(a.workable);
			if (has(opt)) {
				CrowFile* file = force(opt);
				file.moduleAndAlloc = someMut(withAlloc(AllocKind.module_, a.metaAlloc, (ref Alloc alloc) =>
					compileNonBootstrapModule(perf, alloc, a, file)));
				assert(a.countUncompiledCrowFiles > 0);
				a.countUncompiledCrowFiles--;
				foreach (CrowFile* importer; file.referencedBy)
					addToWorkableIfSo(a, importer);
			} else if (filesState(a.storage) == FilesState.allLoaded && a.countUncompiledCrowFiles != 0)
				fixCircularImports(a);
			else
				break;
		}
	}
}

// This may not fix all circular imports, but it's run in a loop
void fixCircularImports(ref Frontend a) {
	foreach (CrowFile* x; a.crowFiles)
		if (!x.hasModule) {
			Builder!Uri cycleBuilder = Builder!Uri(a.allocPtr);
			fixCircularImportsRecur(a, cycleBuilder, x);
			return;
		}
}
Uri[] fixCircularImportsRecur(ref Frontend a, ref Builder!Uri cycleBuilder, CrowFile* file) {
	assert(!file.hasModule);
	cycleBuilder ~= file.uri;
	Opt!size_t optImportIndex = findIndex!MostlyResolvedImport(
		force(file.resolvedImports), (in MostlyResolvedImport x) =>
			!isImportWorkable(x));
	size_t importIndex = force(optImportIndex);
	CrowFile* next = force(file.resolvedImports)[importIndex].asInout!(CrowFile*);
	SmallArray!Uri cycle = contains(asTemporaryArray(cycleBuilder), next.uri)
		? smallFinish(cycleBuilder)
		: fixCircularImportsRecur(a, cycleBuilder, next);
	force(file.resolvedImports)[importIndex] = MostlyResolvedImport(
		allocate(a.alloc, Diag.ImportFileDiag(
			Diag.ImportFileDiag.CircularImport(small!Uri(rotateToFirst!Uri(a.alloc, cycle, file.uri))))));
	mutSetMayDelete(next.referencedBy, file);
	addToWorkableIfSo(a, file);
	return cycle;
}

T[] rotateToFirst(T)(ref Alloc alloc, in T[] values, in T firstValue) {
	Opt!size_t index = indexOf(values, firstValue);
	return concatenateIn(alloc, values[force(index) .. $], values[0 .. force(index)]);
}

Module* compileNonBootstrapModule(scope ref Perf perf, ref Alloc alloc, ref Frontend a, CrowFile* file) {
	assert(isWorkable(*file));
	assert(has(a.commonTypes)); // bootstrap is always compiled first
	UriAndAst ast = UriAndAst(file.uri, force(file.config), toAst(alloc, file.astOrDiag));
	return check(
		perf, alloc, a.allInsts, a.commonUris, ast,
		fullyResolveImports(a, force(file.resolvedImports)),
		force(a.commonTypes));
}

void updateFileOnConfigChange(ref Frontend a, CrowFile* file) {
	MutOpt!(Config*) bestConfig = tryFindConfig(a.storage, parentOrEmpty(file.uri));
	if (has(bestConfig)) {
		if (!has(file.config) || force(bestConfig) != force(file.config)) {
			file.config = bestConfig;
			updatedAstOrConfig(a, file);
		}
	}
}

void updatedAstOrConfig(ref Frontend a, CrowFile* file) {
	if (!isUnknownOrLoading(*file) && has(file.config))
		recomputeResolvedImports(a, file);
	else
		assert(!has(file.resolvedImports) && !file.hasModule);
}

bool isUnknownOrLoading(in CrowFile a) =>
	a.astOrDiag.isA!ReadFileDiag_ && isUnknownOrLoading(a.astOrDiag.asConst!ReadFileDiag_);

void recomputeResolvedImports(ref Frontend a, CrowFile* file) {
	markModuleDirty(a, *file);

	MutOpt!(MutSmallArray!Uri) circularImport = has(file.resolvedImports)
		? clearResolvedImports(file)
		: noneMut!(MutSmallArray!Uri);

	file.resolvedImports = someMut(resolveImports(a, file.astOrDiag, *force(file.config), file.uri));
	foreach (MostlyResolvedImport x; force(file.resolvedImports)) {
		MutOpt!(MutSet!(CrowFile*)*) rb = getReferencedBy(x);
		if (has(rb))
			// Not 'mustAdd' because it could be imported twice by the same module
			mayAddToMutSet(a.alloc, *force(rb), file);
	}

	if (has(circularImport) && !hasCircularImport(force(file.resolvedImports)))
		foreach (Uri uri; force(circularImport))
			if (uri != file.uri) {
				CrowFile* other = mustGet(a.crowFiles, uri);
				MutOpt!(MutSmallArray!Uri) ci = clearResolvedImports(other);
				assert(has(ci)); // But ignore it since we've already handled it
				recomputeResolvedImports(a, other);
			}

	addToWorkableIfSo(a, file);
}

MutOpt!(MutSmallArray!Uri) clearResolvedImports(CrowFile* file) {
	MutOpt!(MutSmallArray!Uri) circularImport = noneMut!(MutSmallArray!Uri);
	foreach (ref MostlyResolvedImport import_; force(file.resolvedImports)) {
		MutOpt!(MutSet!(CrowFile*)*) rb = getReferencedBy(import_);
		if (has(rb))
			// Not mustDelete because file may have the same import multiple times
			mutSetMayDelete(*force(rb), file);
		else
			circularImport = asCircularImport(import_);
	}
	file.resolvedImports = noneMut!(MutSmallArray!MostlyResolvedImport); // TODO: free old resolvedImports
	return circularImport;
}

bool hasCircularImport(in MostlyResolvedImport[] a) =>
	exists!MostlyResolvedImport(a, (in MostlyResolvedImport x) => isCircularImport(x));
bool isCircularImport(in MostlyResolvedImport a) =>
	a.isA!(Diag.ImportFileDiag*) && a.asConst!(Diag.ImportFileDiag*).isA!(Diag.ImportFileDiag.CircularImport);
MutOpt!(MutSmallArray!Uri) asCircularImport(MostlyResolvedImport a) =>
	isCircularImport(a)
		? someMut!(MutSmallArray!Uri)(a.as!(Diag.ImportFileDiag*).as!(Diag.ImportFileDiag.CircularImport).cycle)
		: noneMut!(MutSmallArray!Uri);

void addToWorkableIfSo(ref Frontend a, CrowFile* file) {
	if (isWorkable(*file))
		mustAdd(a.workable, file);
}

// Note: File won't actually be worked on until 'CommonTypes' is set, but it still gets marked here.
bool isWorkable(in CrowFile a) {
	assert(!a.hasModule);
	return !isUnknownOrLoading(a) &&
		has(a.config) &&
		every!MostlyResolvedImport(force(a.resolvedImports), (in MostlyResolvedImport x) =>
			isImportWorkable(x));
}

bool isImportWorkable(in MostlyResolvedImport a) =>
	a.matchConst!bool(
		(const CrowFile* x) =>
			x.hasModule,
		(const OtherFile* x) =>
			has(x.content),
		(Diag.ImportFileDiag* x) {
			if (x.isA!(Diag.ImportFileDiag.ReadError)) {
				Diag.ImportFileDiag.ReadError read = x.as!(Diag.ImportFileDiag.ReadError);
				// Unknown/loading files still have a CrowFile*, Config*, or OtherFile*
				assert(!isUnknownOrLoading(read.diag));
			}
			return true;
		});

bool isUnknownOrLoading(ReadFileDiag a) {
	final switch (a) {
		case ReadFileDiag.unknown:
		case ReadFileDiag.loading:
			return true;
		case ReadFileDiag.notFound:
		case ReadFileDiag.error:
			return false;
	}
}

MutSmallArray!MostlyResolvedImport resolveImports(ref Frontend a, in AstOrDiag astOrDiag, in Config config, Uri uri) =>
	astOrDiag.matchConst!(MutSmallArray!MostlyResolvedImport)(
		(const FileAst* x) =>
			resolveImportsForAst(a, *x, config, uri),
		(const ReadFileDiag_ _) =>
			emptyMutSmallArray!MostlyResolvedImport);

MutSmallArray!MostlyResolvedImport resolveImportsForAst(ref Frontend a, in FileAst ast, in Config config, Uri uri) =>
	small!MostlyResolvedImport(buildArrayExact!MostlyResolvedImport(
		a.alloc,
		countImportsAndReExports(ast),
		(scope ref ExactSizeArrayBuilder!MostlyResolvedImport res) {
			if (!ast.noStd)
				res ~= MostlyResolvedImport(a.commonFiles[CommonModule.std]);
			if (has(ast.imports))
				foreach (ImportOrExportAst x; force(ast.imports).paths)
					res ~= tryResolveImport(a, config, uri, x);
			if (has(ast.reExports))
				foreach (ImportOrExportAst x; force(ast.reExports).paths)
					res ~= tryResolveImport(a, config, uri, x);
		}));

size_t countImportsAndReExports(in FileAst a) =>
	(a.noStd ? 0 : 1) +
	(has(a.imports) ? force(a.imports).paths.length : 0) +
	(has(a.reExports) ? force(a.reExports).paths.length : 0);

void markAllNonBootstrapModulesDirty(ref Frontend a, CrowFile* bootstrap) {
	foreach (CrowFile* x; a.crowFiles)
		if (x != bootstrap)
			markModuleDirty(a, *x);
	clear(a.workable);
	foreach (CrowFile* x; a.crowFiles)
		if (x != bootstrap)
			addToWorkableIfSo(a, x);
}

void markModuleDirty(scope ref Frontend a, scope ref CrowFile file) {
	if (file.hasModule) {
		freeInstantiationsForModule(a.allInsts, *file.mustHaveModule);
		() @trusted {
			freeAllocAndValue(force(file.moduleAndAlloc));
		}();
		file.moduleAndAlloc = noneMut!(AllocAndValue!(Module*));
		a.countUncompiledCrowFiles++;
		foreach (CrowFile* x; file.referencedBy)
			markModuleDirty(a, *x);
	}
}

ResolvedImport[] fullyResolveImports(ref Frontend a, in MostlyResolvedImport[] imports) =>
	map(a.alloc, imports, (ref const MostlyResolvedImport x) =>
		x.matchConst!ResolvedImport(
			(const CrowFile* x) =>
				x.astOrDiag.isA!ReadFileDiag_
					? ResolvedImport(allocate(a.alloc, Diag.ImportFileDiag(
						Diag.ImportFileDiag.ReadError(x.uri, x.astOrDiag.asConst!ReadFileDiag_))))
					: ResolvedImport(x.mustHaveModule),
			(const OtherFile* file) =>
				fileOrDiag(a.storage, file.uri).match!ResolvedImport(
					(FileInfo _) =>
						ResolvedImport(force(file.content)),
					(ReadFileDiag diag) =>
						ResolvedImport(allocate(a.alloc, Diag.ImportFileDiag(
							Diag.ImportFileDiag.ReadError(file.uri, diag))))),
			(Diag.ImportFileDiag* x) =>
				ResolvedImport(x)));

MutOpt!(Config*) tryFindConfig(ref Storage storage, Uri configDir) =>
	fileOrDiag(storage, configDir / crowConfigBaseName).match!(MutOpt!(Config*))(
		(FileInfo x) =>
			someMut(&x.as!(CrowConfigFileInfo*).config),
		(ReadFileDiag x) {
			final switch (x) {
				case ReadFileDiag.notFound:
					Opt!Uri par = parent(configDir);
					return has(par) ? tryFindConfig(storage, force(par)) : someMut(&emptyConfig);
				case ReadFileDiag.error:
					// We want Config* to be unique, so can't alloc here. Storage should do that?
					return todo!(MutOpt!(Config*))("!!!");
				case ReadFileDiag.loading:
				case ReadFileDiag.unknown:
					// Query all possible configs to ensure they are loaded early
					Opt!Uri par = parent(configDir);
					if (has(par))
						tryFindConfig(storage, force(par));
					return noneMut!(Config*);
			}
		});

CommonUris commonUris(Uri includeDir) {
	Uri includeCrow = includeDir / symbol!"crow";
	Uri col = includeCrow / symbol!"col";
	Uri private_ = includeCrow / symbol!"private";
	Uri testUtil = includeCrow / symbol!"test-util";
	return enumMapMapValues!(CommonModule, Uri, Uri)(CommonUris([
		col / symbol!"array",
		private_ / symbol!"bootstrap",
		private_ / symbol!"alloc",
		private_ / symbol!"bool-low-level",
		includeCrow / symbol!"compare",
		private_ / symbol!"exception-low-level",
		private_ / symbol!"future-low-level",
		includeCrow / symbol!"js",
		includeCrow / symbol!"json",
		includeCrow / symbol!"misc",
		col / symbol!"mut-array",
		private_ / symbol!"number-low-level",
		includeCrow / symbol!"pointer",
		private_ / symbol!"runtime",
		private_ / symbol!"rt-main",
		includeCrow / symbol!"std",
		includeCrow / symbol!"string",
		private_ / symbol!"symbol-low-level",
		testUtil / symbol!"test-runner",
	]), (Uri x) => addExtension(x, Extension.crow));
}

immutable struct UriOrDiag {
	mixin TaggedUnion!(Uri, Diag.ImportFileDiag*);
}

struct MostlyResolvedImport {
	// For unknown/loading file, this will still be a CrowFile* or OtherFile*
	mixin TaggedUnion!(CrowFile*, OtherFile*, Diag.ImportFileDiag*);
}

MutOpt!(MutSet!(CrowFile*)*) getReferencedBy(ref MostlyResolvedImport import_) =>
	import_.matchWithPointers!(MutOpt!(MutSet!(CrowFile*)*))(
		(CrowFile* x) =>
			someMut(&x.referencedBy),
		(OtherFile* x) =>
			someMut(&x.referencedBy),
		(Diag.ImportFileDiag*) =>
			noneMut!(MutSet!(CrowFile*)*));
@trusted ConstOpt!(MutSet!(CrowFile*)*) getReferencedBy(ref const MostlyResolvedImport import_) =>
	getReferencedBy(cast(MostlyResolvedImport) import_);

MostlyResolvedImport tryResolveImport(ref Frontend a, in Config config, Uri fromUri, in ImportOrExportAst ast) {
	UriOrDiag base = ast.path.matchIn!UriOrDiag(
		(in Path path) {
			PathFirstAndRest fr = firstAndRest(path);
			Symbol libraryName = fr.first;
			if (libraryName == symbol!"crow" || libraryName == symbol!"system")
				return UriOrDiag(concatUriAndPath(a.crowIncludeDir, path));
			else {
				Opt!Uri fromConfig = config.include[libraryName];
				return has(fromConfig)
					? UriOrDiag(has(fr.rest)
						? concatUriAndPath(force(fromConfig), force(fr.rest))
						: force(fromConfig))
					: UriOrDiag(allocate(a.alloc, Diag.ImportFileDiag(
						Diag.ImportFileDiag.LibraryNotConfigured(libraryName))));
			}
		},
		(in RelPath relPath) {
			Opt!Uri rel = resolveUri(parentOrEmpty(fromUri), relPath);
			return has(rel)
				? UriOrDiag(force(rel))
				: UriOrDiag(allocate(a.alloc, Diag.ImportFileDiag(
					Diag.ImportFileDiag.RelativeImportReachesPastRoot(relPath))));
		});
	return base.matchWithPointers!MostlyResolvedImport(
		(Uri uri) {
			MostlyResolvedImport crowFile() =>
				MostlyResolvedImport(ensureCrowFile(a, addExtension(uri, Extension.crow)));
			return ast.kind.match!MostlyResolvedImport(
				(ImportWholeModuleAst _) =>
					crowFile(),
				(NameAndRange[]) =>
					crowFile(),
				(ref ImportFileAst) =>
					fileType(uri) == FileType.crow
						? MostlyResolvedImport(allocate(a.alloc, Diag.ImportFileDiag(
							Diag.ImportFileDiag.CantImportCrowAsText())))
						: MostlyResolvedImport(ensureOtherFile(a, uri)));
		},
		(Diag.ImportFileDiag* x) =>
			MostlyResolvedImport(x));
}
