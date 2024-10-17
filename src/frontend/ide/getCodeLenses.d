module frontend.ide.getCodeLenses;

@safe @nogc pure nothrow:

import frontend.ide.getReferences : eachImport, UriAndName;
import frontend.showModel : ShowTypeCtx;
import lib.lsp.lspTypes :
	CodeLensParams, CodeLensResolved, CodeLensUnresolved, Command, ExecuteCommandParams, Pipe, RunResult, Write;
import lib.server : TestStates; // TODO: CIRCULAR IMPORT ---------------------------------------------------------------------------
import model.model : AnyDecl, eachDecl, IsImportOrExport, Module, moduleAtUri, Program, Test, Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray;
import util.col.array : every, isEmpty, map;
import util.col.arrayBuilder : buildArray, Builder;
import util.exitCode : ExitCode, isOk, Signal;
import util.late : Late, lateGet, lateSet;
import util.opt : force, has, Opt, optIf, some;
import util.sourceRange : LineAndCharacterGetter, Pos, rangeToEndOfLine, UriAndLine, UriAndPos;
import util.union_ : Union;
import util.uri : relativePathForUri, RelPath, Uri;
import util.util : stringOfEnum;
import util.writer : makeStringWithWriter, Writer, writeWithCommas, writeWithNewlines;

CodeLensResolved[] resolvedCodeLenses(
	ref Alloc alloc,
	in Program program,
	in ShowTypeCtx showCtx,
	in TestStates testStates,
	in CodeLensParams params,
) =>
	map(
		alloc,
		unresolvedCodeLenses(alloc, program, showCtx.lineAndCharacterGetters[params.textDocument.uri], params),
		(ref CodeLensUnresolved x) =>
			resolveCodeLens(alloc, program, showCtx, testStates, x));

CodeLensUnresolved[] unresolvedCodeLenses(
	ref Alloc alloc,
	in Program program,
	in LineAndCharacterGetter lcg,
	in CodeLensParams params,
) {
	return [];
	Uri uri = params.textDocument.uri;
	Module* module_ = moduleAtUri(program, uri);
	return buildArray!CodeLensUnresolved(alloc, (scope ref Builder!CodeLensUnresolved out_) {
		eachDecl(*module_, (AnyDecl x) {
			if (x.visibility != Visibility.private_)
				out_ ~= CodeLensUnresolved(rangeToEndOfLine(lcg, x.range.start), uri);
		});
	});
}

CodeLensResolved resolveCodeLens(
	ref Alloc alloc,
	in Program program,
	in ShowTypeCtx showCtx,
	in TestStates testStates,
	in CodeLensUnresolved codeLens,
) {
	Uri uri = codeLens.data;
	uint line = codeLens.range.start.line;
	UriAndLine uriAndLine = UriAndLine(uri, line);
	AnyDecl decl = declAtPos(*moduleAtUri(program, uri), showCtx.lineAndCharacterGetters[uri][codeLens.range].start);
	assert(decl.visibility != Visibility.private_);

	if (decl.isA!(Test*)) {
		Opt!RunResult optResult = testStates[uriAndLine];
		Command command = () {
			if (has(optResult)) {
				RunResult result = force(optResult);
				return Command(
					isOk(result.exit) ? "Passed" : "Failed",
					tooltipForRunResult(alloc, result));
			} else
				return Command(
					"Run test",
					tooltip: some("this is a dummy tooltip to test if they even work"), // --------------------------------------------
					arguments: some(ExecuteCommandParams(ExecuteCommandParams.RunTest(uriAndLine))));
		}();
		return CodeLensResolved(codeLens.range, command);
	} else {
		string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
			withImportsAndReExportsOf(program, decl, maxUris: 4, cb: (in UrisOrCount imports, in UrisOrCount reExports) {
				writeUrisOrCount(writer, "Exported by ", uri, reExports);
				if (!isEmpty(imports)) {
					if (!isEmpty(reExports)) writer ~= "; ";
					writeUrisOrCount(writer, "Used by ", uri, imports);
				}
				if (isEmpty(imports) && isEmpty(reExports))
					writer ~= "Used only locally";
			});
		});
		// To find the entity again: Find it at codeLens.data.uri and codeLens.range.start
		return CodeLensResolved(codeLens.range, Command(message));
	}
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

public immutable struct UrisOrCount {
	mixin Union!(Uri[], size_t);
}
public bool isEmpty(in UrisOrCount a) =>
	a.matchIn!bool(
		(in Uri[] xs) =>
			isEmpty(xs),
		(in size_t x) =>
			x == 0);
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

public void withImportsAndReExportsOf(
	in Program program,
	in AnyDecl decl,
	size_t maxUris,
	in void delegate(in UrisOrCount, in UrisOrCount) @safe @nogc pure nothrow cb,
) {
	if (decl.visibility == Visibility.private_)
		cb(UrisOrCount(0), UrisOrCount(0));
	else {
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
	}
}

AnyDecl declAtPos(in Module module_, Pos pos) {
	Late!AnyDecl res;
	eachDecl(module_, (AnyDecl x) {
		if (x.range.start == pos)
			lateSet(res, x);
	});
	return lateGet(res);
}
