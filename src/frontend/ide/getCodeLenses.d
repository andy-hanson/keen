module frontend.ide.getCodeLenses;

@safe @nogc pure nothrow:

import frontend.ide.getReferences : eachImport, IsImportOrExport;
import frontend.showModel : ShowTypeCtx;
import lib.lsp.lspTypes : CodeLensParams, CodeLensResolved, CodeLensUnresolved, Command;
import model.ast : ImportOrExportAst;
import model.model : AnyDecl, eachDecl, Module, moduleAtUri, Program, Test, Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : TwoStackArraysBuilder, withBuild2StackArrays;
import util.col.array : isEmpty, map;
import util.col.arrayBuilder : buildArray, Builder;
import util.late : Late, lateGet, lateSet;
import util.opt : force, has, Opt;
import util.sourceRange : LineAndCharacterGetter, Pos, rangeToEndOfLine;
import util.uri : relativePathForUri, RelPath, Uri;
import util.writer : makeStringWithWriter, Writer, writeWithCommas;

CodeLensResolved[] resolvedCodeLenses(ref Alloc alloc, in Program program, in ShowTypeCtx showCtx, in CodeLensParams params) =>
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
		withImportsAndReExportsOf!void(program, decl, (in Uri[] imports, in Uri[] reExports) {
			if (imports.length > 4) {
				writer ~= "Imported by ";
				writer ~= imports.length;
				writer ~= " other modules";
			} else if (!isEmpty(imports)) {
				writer ~= "Imported by ";
				writeRelativeUris(writer, decl.moduleUri, imports);
			}

			if (!isEmpty(reExports)) {
				if (!isEmpty(imports)) writer ~= "; ";
				writer ~= "Exported by ";
				writeRelativeUris(writer, decl.moduleUri, reExports);
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

void writeRelativeUris(scope ref Writer writer, Uri from, in Uri[] uris) {
	writeWithCommas!Uri(writer, uris, (in Uri uri) {
		Opt!RelPath rel = relativePathForUri(from, uri);
		if (has(rel))
			writer ~= force(rel);
		else
			writer ~= uri;
	});
}

Out withImportsAndReExportsOf(Out)(
	in Program program,
	in AnyDecl decl,
	in Out delegate(in Uri[], in Uri[]) @safe @nogc pure nothrow cb,
) =>
	withBuild2StackArrays!(Out, Uri)(
		(scope ref TwoStackArraysBuilder!Uri out_) {
			eachImport(program, decl, (Uri uri, IsImportOrExport x, ImportOrExportAst*) {
				if (x == IsImportOrExport.import_)
					out_.writeFirst(uri);
				else
					out_.writeSecond(uri);
			});
		},
		cb);

AnyDecl declAtPos(in Module module_, Pos pos) {
	Late!AnyDecl res;
	eachDecl(module_, (AnyDecl x) {
		if (x.range.start == pos)
			lateSet(res, x);
	});
	return lateGet(res);
}
