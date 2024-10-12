module frontend.ide.getCodeLenses;

@safe @nogc pure nothrow:

import frontend.ide.getReferences : eachImport, UriAndName;
import frontend.showModel : ShowTypeCtx;
import lib.lsp.lspTypes : CodeLensParams, CodeLensResolved, CodeLensUnresolved, Command;
import model.model : AnyDecl, eachDecl, IsImportOrExport, Module, moduleAtUri, Program, Test, Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray;
import util.col.array : isEmpty, map;
import util.col.arrayBuilder : buildArray, Builder;
import util.late : Late, lateGet, lateSet;
import util.opt : force, has, Opt;
import util.sourceRange : LineAndCharacterGetter, Pos, rangeToEndOfLine;
import util.union_ : Union;
import util.uri : relativePathForUri, RelPath, Uri;
import util.writer : makeStringWithWriter, Writer, writeWithCommas;

CodeLensResolved[] resolvedCodeLenses(
	ref Alloc alloc,
	in Program program,
	in ShowTypeCtx showCtx,
	in CodeLensParams params,
) =>
	map(
		alloc,
		unresolvedCodeLenses(alloc, program, showCtx.lineAndCharacterGetters[params.textDocument.uri], params),
		(ref CodeLensUnresolved x) =>
			resolveCodeLens(alloc, program, showCtx, x));

CodeLensUnresolved[] unresolvedCodeLenses(
	ref Alloc alloc,
	in Program program,
	in LineAndCharacterGetter lcg,
	in CodeLensParams params,
) {
	Uri uri = params.textDocument.uri;
	Module* module_ = moduleAtUri(program, uri);
	return buildArray!CodeLensUnresolved(alloc, (scope ref Builder!CodeLensUnresolved out_) {
		eachDecl(*module_, (AnyDecl x) {
			if (!x.isA!(Test*) && x.visibility != Visibility.private_)
				out_ ~= CodeLensUnresolved(rangeToEndOfLine(lcg, x.range.start), uri);
		});
	});
}

CodeLensResolved resolveCodeLens(
	ref Alloc alloc,
	in Program program,
	in ShowTypeCtx showCtx,
	in CodeLensUnresolved codeLens,
) {
	Uri uri = codeLens.data;
	AnyDecl decl = declAtPos(*moduleAtUri(program, uri), showCtx.lineAndCharacterGetters[uri][codeLens.range].start);
	assert(decl.visibility != Visibility.private_);

	string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
		withImportsAndReExportsOf(program, decl, maxUris: 4, cb: (in UrisOrCount imports, in UrisOrCount reExports) {
			writeUrisOrCount(writer, "Used", uri, imports);
			if (!isEmpty(reExports)) {
				if (!isEmpty(imports)) writer ~= "; ";
				writeUrisOrCount(writer, "Exported", uri, reExports);
			}
			if (isEmpty(imports) && isEmpty(reExports)) {
				writer ~= "Used only locally";
			}
		});
	});
	// To find the entity again: Find it at codeLens.data.uri and codeLens.range.start
	return CodeLensResolved(codeLens.range, Command(message));
}

private:

immutable struct UrisOrCount {
	mixin Union!(Uri[], size_t);
}
bool isEmpty(in UrisOrCount a) =>
	a.matchIn!bool(
		(in Uri[] xs) =>
			isEmpty(xs),
		(in size_t x) =>
			x == 0);
void writeUrisOrCount(scope ref Writer writer, in string verb, Uri fromUri, in UrisOrCount a) {
	if (!isEmpty(a)) {
		writer ~= verb;
		writer ~= " by ";
		a.matchIn!void(
			(in Uri[] uris) {
				writeRelativeUris(writer, fromUri, uris);
			},
			(in size_t count) {
				writer ~= count;
				writer ~= " other modules";
			});
	}
}

void writeRelativeUris(scope ref Writer writer, Uri from, in Uri[] uris) {
	writeWithCommas!Uri(writer, uris, (in Uri uri) {
		Opt!RelPath rel = relativePathForUri(from, uri);
		if (has(rel))
			writer ~= force(rel);
		else
			writer ~= uri;
	});
}

void withImportsAndReExportsOf(
	in Program program,
	in AnyDecl decl,
	size_t maxUris,
	in void delegate(in UrisOrCount, in UrisOrCount) @safe @nogc pure nothrow cb,
) =>
	withMaxStackArray!(void, Uri)(maxUris, (scope ref MaxStackArray!Uri imports) {
		withMaxStackArray!(void, Uri)(maxUris, (scope ref MaxStackArray!Uri exports) {
			size_t countImports;
			size_t countExports;
			void addUri(scope ref MaxStackArray!Uri uris, ref size_t count, Uri uri) {
				count++;
				if (!uris.isFull) uris ~= uri;
			}
			eachImport(program, UriAndName(decl.moduleUri, decl.name), (Uri uri, IsImportOrExport x) {
				final switch (x) {
					case IsImportOrExport.import_:
						addUri(imports, countImports, uri);
						break;
					case IsImportOrExport.export_:
						addUri(exports, countExports, uri);
						break;
				}
			});
			UrisOrCount result(size_t count, ref const MaxStackArray!Uri uris) =>
				count > maxUris ? UrisOrCount(maxUris) : UrisOrCount(uris.soFar);
			cb(result(countImports, imports), result(countExports, exports));
		});
	});

AnyDecl declAtPos(in Module module_, Pos pos) {
	Late!AnyDecl res;
	eachDecl(module_, (AnyDecl x) {
		if (x.range.start == pos)
			lateSet(res, x);
	});
	return lateGet(res);
}
