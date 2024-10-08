module frontend.ide.getCodeLenses;

@safe @nogc pure nothrow:

import frontend.ide.getReferences : eachImport, IsImportOrExport, referencesForFunDecl;
import frontend.showModel : ShowTypeCtx, writeDestructureName;
import frontend.storage : LineAndCharacterGetters;
import lib.lsp.lspTypes : CodeLensParams, CodeLensResolved, CodeLensUnresolved, Command;
import model.ast : ImportOrExportAst;
import model.diag : TypeContainer;
import model.model :
	bestCasePurity, Destructure, FunDecl, FunDeclSource, Module, moduleAtUri, paramsArray, Program, Purity, Type, Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : TwoStackArraysBuilder, withBuild2StackArrays;
import util.col.array : isEmpty, map, mustFindPointer, newArray;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, none, Opt;
import util.sourceRange :
	LineAndCharacter,
	LineAndCharacterGetter,
	LineAndCharacterRange,
	Pos,
	rangeToEndOfLine,
	UriAndLineAndCharacterRange,
	UriAndRange;
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
		// TODO: Support all kinds of declaration -------------------------------------------------------------------------------------
		foreach (ref FunDecl fun; module_.funs)
			if (fun.visibility != Visibility.private_ && fun.source.isA!(FunDeclSource.Ast))
				out_ ~= CodeLensUnresolved(rangeToEndOfLine(lcg, fun.range.start), uri);
	});
}

CodeLensResolved resolveCodeLens(
	ref Alloc alloc,
	in Program program,
	in ShowTypeCtx showCtx,
	in CodeLensUnresolved codeLens,
) {
	Uri uri = codeLens.data;
	FunDecl* fun = findFunDeclAtPos(
		*moduleAtUri(program, uri),
		showCtx.lineAndCharacterGetters[uri][codeLens.range].start);
	assert(fun.visibility != Visibility.private_);

	string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
		withImportsAndReExports!void(program, fun, (in Uri[] imports, in Uri[] reExports) {
			if (imports.length > 4) {
				writer ~= "Imported by ";
				writer ~= imports.length;
				writer ~= " other modules";
			} else if (!isEmpty(imports)) {
				writer ~= "Imported by ";
				writeRelativeUris(writer, fun.moduleUri, imports);
			}

			if (!isEmpty(reExports)) {
				if (!isEmpty(imports)) writer ~= "; ";
				writer ~= "Exported by ";
				writeRelativeUris(writer, fun.moduleUri, reExports);
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

Out withImportsAndReExports(Out)(
	in Program program,
	in FunDecl* fun,
	in Out delegate(in Uri[], in Uri[]) @safe @nogc pure nothrow cb,
) =>
	withBuild2StackArrays!(Out, Uri)(
		(scope ref TwoStackArraysBuilder!Uri out_) {
			eachImport(program, fun, (Uri uri, IsImportOrExport x, ImportOrExportAst*) {
				if (x == IsImportOrExport.import_)
					out_.writeFirst(uri);
				else
					out_.writeSecond(uri);
			});
		},
		cb);


FunDecl* findFunDeclAtPos(in Module module_, Pos pos) =>
	mustFindPointer!FunDecl(module_.funs, (ref FunDecl x) =>
		x.range.start == pos);
