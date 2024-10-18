module frontend.ide.getCodeLenses;

@safe @nogc pure nothrow:

import frontend.ide.getReferences : eachImport, eachModuleReferencing, UriAndName;
import frontend.showModel : ShowTypeCtx;
import lib.lsp.lspTypes : CodeLens, CodeLensParams, Command, Pipe, RunResult, Write;
import model.model : AnyDecl, ImportOrExport, IsImportOrExport, Module, moduleAtUri, Program, Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray;
import util.col.array : every, isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.exitCode : ExitCode, isOk, Signal;
import util.opt : force, has, Opt, optIf;
import util.sourceRange : LineAndCharacter, LineAndCharacterRange;
import util.union_ : Union;
import util.uri : relativePathForUri, RelPath, Uri;
import util.util : ptrTrustMe, stringOfEnum;
import util.writer : makeStringWithWriter, Writer, writeWithCommas, writeWithNewlines;

CodeLens[] getCodeLenses(
	ref Alloc alloc,
	in Program program,
	in ShowTypeCtx showCtx, // TODO: UNUSED -----------------------------------------------------------------------------------
	in CodeLensParams params,
) {
	Uri uri = params.textDocument.uri;
	Module* module_ = moduleAtUri(program, uri);
	return buildArray!CodeLens(alloc, (scope ref Builder!CodeLens out_) {
		withImportsAndReExportsOfModule!void(
			program,
			module_,
			4,
			(in ImportsAndReExports x) {
				if (!isEmpty(x)) {
					string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
						writeUrisOrCount(writer, "Module re-exported by ", uri, x.reExports);
						if (!isEmpty(x.imports)) {
							if (!isEmpty(x.reExports)) writer ~= "; ";
							writeUrisOrCount(writer, "Module used by ", uri, x.imports);
						}
					});
					// TODO: we could have a tooltip for the full set ...
					out_ ~= CodeLens(LineAndCharacterRange(LineAndCharacter(0, 0), LineAndCharacter(0, 0)), Command(message));
				}
			});
	});
}

private:

public Opt!string tooltipForRunResult(ref Alloc alloc, RunResult result) => // TODO: UNIT TEST ----------------------------------------------
	optIf(isOk(result.exit) || !isEmpty(result.writes), () =>
		makeStringWithWriter(alloc, (scope ref Writer writer) {
			if (every!Write(result.writes, (in Write x) => x.pipe == Pipe.stdout))
				writeWithNewlines!Write(writer, result.writes, (in Write x) {
					writer ~= x.text;
				});
			else
				writeWithNewlines!Write(writer, result.writes, (in Write x) {
					writer ~= stringOfEnum(x.pipe);
					writer ~= ": ";
					writer ~= x.text;
				});
			
			if (!isOk(result.exit)) {
				result.exit.match!void(
					(ExitCode x) {
						writer ~= "\nExit code ";
						writer ~= x.value;
					},
					(Signal x) {
						writer ~= "\nExited with signal ";
						writer ~= x.signal;
					});
			}
		}));

immutable struct UrisOrCount {
	mixin Union!(Uri[], size_t);
}
public bool isEmpty(in UrisOrCount a) =>
	a.matchIn!bool(
		(in Uri[] xs) =>
			isEmpty(xs),
		(in size_t x) =>
			x == 0);
// TODO: If this is used in an InlayHint, we could make the file references clickable. -----------------------------------------------
public void writeUrisOrCount(scope ref Writer writer, in string description, Uri fromUri, in UrisOrCount a) {
	if (!isEmpty(a)) {
		writer ~= description;
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

Out withImportsAndReExportsOfModule(Out)(
	in Program program,
	in Module* module_,
	size_t maxUris,
	in Out delegate(in ImportsAndReExports) @safe @nogc pure nothrow cb,
) =>
	withBuildImportsAndReExports!Out(
		maxUris,
		(scope ref ImportsAndReExportsBuilder out_) {
			eachModuleReferencing(program, module_, (in Module x, IsImportOrExport kind, in ImportOrExport _) {
				add(out_, x.uri, kind);
			});
		},
		cb);

public immutable struct ImportsAndReExports {
	UrisOrCount imports;
	UrisOrCount reExports;	
}
public bool isEmpty(in ImportsAndReExports a) =>
	isEmpty(a.imports) && isEmpty(a.reExports);

public Out withImportsAndReExportsOf(Out)(
	in Program program,
	in AnyDecl decl,
	size_t maxUris,
	in Out delegate(in ImportsAndReExports) @safe @nogc pure nothrow cb,
) {
	withBuildImportsAndReExports!Out(
		maxUris,
		(scope ref ImportsAndReExportsBuilder out_) {
			if (decl.visibility != Visibility.private_)
				eachImport(program, UriAndName(decl.moduleUri, decl.name), (Uri uri, IsImportOrExport kind) {
					add(out_, uri, kind);
				});
		},
		cb);
}

void withBuildImportsAndReExports(Out)(
	size_t maxUris,
	in void delegate(scope ref ImportsAndReExportsBuilder) @safe @nogc pure nothrow cbBuild,
	in Out delegate(in ImportsAndReExports) @safe @nogc pure nothrow cb,
) =>
	withMaxStackArray!(Out, Uri)(maxUris, (scope ref MaxStackArray!Uri imports) =>
		withMaxStackArray!(Out, Uri)(maxUris, (scope ref MaxStackArray!Uri exports) {
			scope ImportsAndReExportsBuilder builder = ImportsAndReExportsBuilder(ptrTrustMe(imports), ptrTrustMe(exports));
			cbBuild(builder);
			return cb(ImportsAndReExports(
				toUrisOrCount(maxUris, builder.countImports, *builder.imports),
				toUrisOrCount(maxUris, builder.countExports, *builder.exports)));
		}));

struct ImportsAndReExportsBuilder {
	MaxStackArray!Uri* imports;
	MaxStackArray!Uri* exports;
	size_t countImports;
	size_t countExports;
}
void add(scope ref ImportsAndReExportsBuilder a, Uri uri, IsImportOrExport kind) {
	final switch (kind) {
		case IsImportOrExport.import_:
			a.countImports++;
			if (!a.imports.isFull) *a.imports ~= uri;
			break;
		case IsImportOrExport.export_:
			a.countExports++;
			if (!a.exports.isFull) *a.exports ~= uri;
			break;
	}
}	

UrisOrCount toUrisOrCount(size_t maxUris, size_t count, ref const MaxStackArray!Uri uris) =>
	count > maxUris ? UrisOrCount(count) : UrisOrCount(uris.soFar);
