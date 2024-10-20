module frontend.ide.importReferences;

@safe @nogc pure nothrow:

import frontend.ide.ideUtil : ReferenceCb;
import model.ast : ImportOrExportAst, NameAndRange;
import model.model :
	AnyDecl,
	eachImportOrReExport,
	ImportOrExport,
	IsImportOrExport,
	Module,
	moduleAtUri,
	NameReferents,
	Program,
	Visibility;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray;
import util.col.array : isEmpty;
import util.col.tempSet : mustAdd, TempSet, tryAdd, withTempSet;
import util.opt : force, has, Opt;
import util.col.sortUtil : sortInPlace;
import util.sourceRange : UriAndRange;
import util.symbol : Symbol;
import util.uri : compareUriNaturally, Uri;
import util.util : ptrTrustMe;

Out withImportsAndReExportsOfModule(Out)(
	in Program program,
	in Module* module_,
	in Out delegate(in ImportsAndReExports) @safe @nogc pure nothrow cb,
) =>
	withBuildImportsAndReExports!Out(
		(scope ref ImportsAndReExportsBuilder out_) {
			eachModuleReferencing(program, module_, (in Module x, IsImportOrExport kind, in ImportOrExport _) {
				add(out_, x.uri, kind);
			});
		},
		cb);

immutable struct ImportsAndReExports {
	Uri[] imports;
	Uri[] reExports;
}
bool isEmpty(in ImportsAndReExports a) =>
	isEmpty(a.imports) && isEmpty(a.reExports);

public Out withImportsAndReExportsOf(Out)(
	in Program program,
	in AnyDecl decl,
	in Out delegate(in ImportsAndReExports) @safe @nogc pure nothrow cb,
) {
	withBuildImportsAndReExports!Out(
		(scope ref ImportsAndReExportsBuilder out_) {
			if (decl.visibility != Visibility.private_)
				eachImport(program, UriAndName(decl.moduleUri, decl.name), (Uri uri, IsImportOrExport kind) {
					add(out_, uri, kind);
				});
		},
		cb);
}

void eachNamedImport(
	in Program program,
	in Module* exportingModule,
	Symbol name,
	in void delegate(in UriAndRange, IsImportOrExport) @safe @nogc pure nothrow cb,
) {
	eachModuleReferencing(
		program,
		exportingModule,
		(in Module importingModule, IsImportOrExport kind, in ImportOrExport import_) {
			if (!import_.isStd) {
				ImportOrExportAst* source = force(import_.source);
				if (source.kind.isA!(NameAndRange[]))
					foreach (NameAndRange x; source.kind.as!(NameAndRange[]))
						if (x.name == name)
							cb(UriAndRange(importingModule.uri, x.range), kind);
			}
		});
}

immutable struct UriAndName {
	Uri moduleUri;
	Symbol name;
}

void referencesForModule(in Program program, in Module* target, in ReferenceCb cb) {
	eachModuleReferencing(program, target, (in Module importer, IsImportOrExport _, in ImportOrExport ie) {
		if (!ie.isStd)
			cb(UriAndRange(importer.uri, force(ie.source).pathRange));
	});
}

void eachModuleReferencing(
	in Program program,
	in Module* exportingModule,
	in void delegate(in Module, IsImportOrExport, in ImportOrExport) @safe @nogc pure nothrow cb,
) =>
	withExportersSet!void(program, exportingModule, (in TempSet!(Module*) exporters) {
		foreach (immutable Module* importingModule; program.allModules) {
			eachImportOrReExport(*importingModule, (IsImportOrExport kind, ref ImportOrExport x) {
				if (x.modulePtr in exporters)
					cb(*importingModule, kind, x);
			});
		}
	});

private:

Out withBuildImportsAndReExports(Out)(
	in void delegate(scope ref ImportsAndReExportsBuilder) @safe @nogc pure nothrow cbBuild,
	in Out delegate(in ImportsAndReExports) @safe @nogc pure nothrow cb,
) =>
	withMaxStackArray!(Out, Uri)(
		0x100,
		(scope ref MaxStackArray!Uri out_) {
			ImportsAndReExportsBuilder builder = ImportsAndReExportsBuilder(ptrTrustMe(out_));
			cbBuild(builder);
			size_t countExports = builder.countExports;
			Uri[] uris = out_.finish();
			Uri[] reExports = uris[0 .. countExports];
			Uri[] imports = uris[countExports .. $];
			sortInPlace!(Uri, compareUriNaturally)(reExports);
			sortInPlace!(Uri, compareUriNaturally)(imports);
			return cb(ImportsAndReExports(imports: imports, reExports: reExports));
		});

struct ImportsAndReExportsBuilder {
	private:
	MaxStackArray!Uri* out_;
	size_t countExports;
}
void add(scope ref ImportsAndReExportsBuilder a, Uri uri, IsImportOrExport kind) {
	if (a.out_.isFull) return;
	final switch (kind) {
		case IsImportOrExport.import_:
			*a.out_ ~= uri;
			break;
		case IsImportOrExport.export_:
			a.out_.pushLeft(uri);
			a.countExports++;
			break;
	}
}

// Unlike 'eachNamedImport', this works for un-named imports; so it doe snot pass a location to the callback.
void eachImport(
	in Program program,
	in UriAndName imported,
	in void delegate(Uri, IsImportOrExport) @safe @nogc pure nothrow cb,
) {
	eachModuleReferencing(
		program,
		moduleAtUri(program, imported.moduleUri),
		(in Module importingModule, IsImportOrExport kind, in ImportOrExport import_) {
			if (import_.hasImported) {
				Opt!(NameReferents*) refs = import_.imported[imported.name];
				if (has(refs))
					cb(importingModule.uri, kind);
			}
		});
}

// Set of a module and all modules that re-export something from it.
Out withExportersSet(Out)(
	in Program program,
	in Module* exportingModule,
	in Out delegate(in TempSet!(Module*)) @safe @nogc pure nothrow cb,
) {
	withTempSet!(Out, Module*)(0x1000, (scope ref TempSet!(Module*) exporters) {
		mustAdd(exporters, exportingModule);
		bool didAdd = true;
		while (didAdd) {
			didAdd = false;
			foreach (immutable Module* x; program.allModules) {
				foreach (ImportOrExport ex; x.reExports)
					if (ex.modulePtr in exporters)
						if (tryAdd(exporters, x))
							didAdd = true;
			}
		}
		return cb(exporters);
	});
}

