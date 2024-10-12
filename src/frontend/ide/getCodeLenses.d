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
import util.exitCode : ExitCode;
import util.late : Late, lateGet, lateSet;
import util.opt : force, has, Opt, optIf, some;
import util.sourceRange : LineAndCharacterGetter, Pos, rangeToEndOfLine, UriAndPos;
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
	AnyDecl decl = declAtPos(*moduleAtUri(program, uri), showCtx.lineAndCharacterGetters[uri][codeLens.range].start);
	assert(decl.visibility != Visibility.private_);

	if (decl.isA!(Test*)) {
		Opt!RunResult optResult = testStates[decl.as!(Test*)];
		Command command = () {
			if (has(optResult)) {
				RunResult result = force(optResult);
				return Command(
					result.exitCode == ExitCode.ok ? "Passed" : "Failed",
					tooltipForRunResult(alloc, result));
			} else
				return Command(
					"Run test",
					arguments: some(ExecuteCommandParams(ExecuteCommandParams.RunTest(UriAndPos(uri, decl.range.start)))));
		}();
		return CodeLensResolved(codeLens.range, command);
	} else {
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
}

private:

Opt!string tooltipForRunResult(ref Alloc alloc, RunResult result) => // TODO: UNIT TEST ----------------------------------------------
	optIf(result.exitCode != ExitCode.ok || !isEmpty(result.writes), () =>
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
			
			if (result.exitCode != ExitCode.ok) {
				writer ~= "\nexit code: ";
				writer ~= result.exitCode.value;
			}
		}));

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
