module frontend.ide.getInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.importReferences : ImportsAndReExports, isEmpty, withImportsAndReExportsOf;
import frontend.showModel : ShowModelCtx, writeTypeUnquoted;
import lib.lsp.lspTypes :
	Command,
	ExecuteCommandParams,
	InlayHint,
	InlayHintKind,
	InlayHintLabel,
	InlayHintLabelPart,
	InlayHintParams,
	Pipe,
	RunResult,
	TestStates,
	Write;
import model.ast : ImportOrExportAst, ImportWholeModuleAst, SingleDestructureAst;
import model.model :
	AnyDecl,
	bestCasePurity,
	Destructure,
	DestructureIgnore,
	DestructureSplit,
	eachDecl,
	eachDescendentExprIncluding,
	Expr,
	ExprRef,
	funBodyExprRef,
	FunDecl,
	FunSourceAst,
	ImportOrExport,
	LambdaExpr,
	LetExpr,
	Local,
	Module,
	moduleAtUri,
	NameReferents,
	paramsArray,
	Program,
	Purity,
	Test,
	Type,
	TypeContainer,
	TypeWithContainer;
import model.sourceRange :
	compareLineAndCharacter,
	endOfLine,
	LineAndCharacter,
	LineAndCharacterGetter,
	LineAndCharacterGetters,
	lineOfPos,
	Pos,
	PosKind,
	UriAndLine,
	UriAndLineAndCharacterRange,
	UriAndRange;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.col.array : every, isEmpty, newArray;
import util.col.arrayBuilder : buildArray, buildSortedArray, Builder;
import util.col.hashTable : mustGet;
import util.col.sortUtil : sortInPlace;
import util.comparison : Comparison;
import util.exitCode : ExitCode, isOk, Signal;
import util.opt : force, has, none, Opt, optIf, some;
import util.symbol : compareSymbolsNaturally, stringOfSymbol, Symbol;
import util.uri : baseName, Uri;
import util.util : stringOfEnum;
import util.writer : makeStringWithWriter, writeWithCommas, Writer, writeWithNewlines;

InlayHint[] getInlayHints(
	ref Alloc alloc,
	in Program program,
	in ShowModelCtx showCtx,
	in TestStates testStates,
	InlayHintParams params,
) =>
	buildSortedArray!(InlayHint, compareInlayHints)(alloc, (scope ref Builder!InlayHint out_) {
		Uri uri = params.textDocument;
		Module* module_ = moduleAtUri(program, uri);
		foreach (ImportOrExport x; module_.imports)
			if (has(x.source))
				getInlayHintsForImport(alloc, out_, showCtx.lineAndCharacterGetters, uri, force(x.source), x);
		eachDecl(*module_, (AnyDecl x) {
			getInlayHintsForDecl(alloc, out_, program, showCtx, testStates, x);
		});
	});

private:

Comparison compareInlayHints(in InlayHint a, in InlayHint b) =>
	compareLineAndCharacter(a.position, b.position);

void getInlayHintsForImport(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in LineAndCharacterGetters lcgs,
	Uri importerUri,
	ImportOrExportAst* ast,
	ImportOrExport a,
) {
	if (ast.kind.isA!ImportWholeModuleAst) {
		InlayHintLabel label = withBuildStackArray!(InlayHintLabel, Symbol)(
			(ref StackArrayBuilder!Symbol out_) {
				foreach (ref immutable NameReferents* x; a.imported)
					out_ ~= x.name;
			},
			(scope Symbol[] names) {
				sortInPlace!(Symbol, compareSymbolsNaturally)(names);
				return InlayHintLabel(buildArray!InlayHintLabelPart(alloc, (scope ref Builder!InlayHintLabelPart out_) {
					if (names.length > 5)
						out_ ~= InlayHintLabelPart(
							value: makeStringWithWriter(alloc, (scope ref Writer writer) {
								writer ~= names.length;
								writer ~= " imported names";
							}),
							tooltip: some(makeStringWithWriter(alloc, (scope ref Writer writer) {
								writeWithCommas!Symbol(writer, names);
							})));
					else
						writeImportedNameLabelParts(alloc, out_, lcgs, a, names);
				}));
			});
		out_ ~= InlayHint(endOfLine(lcgs[importerUri], ast.range.start), label, paddingLeft: true);
	}
}

void writeImportedNameLabelParts(
	ref Alloc alloc,
	scope ref Builder!InlayHintLabelPart out_,
	in LineAndCharacterGetters lcgs,
	in ImportOrExport a,
	in Symbol[] names,
) {
	writeInlayPartsWithCommas!Symbol(out_, names, (in Symbol name) =>
		InlayHintLabelPart(
			stringOfSymbol(alloc, name),
			location: some(lcgs[mainLocationForNameReferents(*mustGet(a.imported, name))])));
}
UriAndRange mainLocationForNameReferents(in NameReferents a) =>
	has(a.structOrAlias)
		? force(a.structOrAlias).nameRange
		: has(a.spec)
		? force(a.spec).nameRange
		: a.funs[0].nameRange;

void getInlayHintsForDecl(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in Program program,
	in ShowModelCtx showCtx,
	in TestStates testStates,
	in AnyDecl decl,
) {
	Uri uri = decl.moduleUri;
	LineAndCharacterGetter lcg = showCtx.lineAndCharacterGetters[uri];
	withImportsAndReExportsOf!void(program, decl, (in ImportsAndReExports x) {
		if (!isEmpty(x)) {
			size_t maxUris = 3;
			InlayHintLabelPart[] parts =
				buildArray!InlayHintLabelPart(alloc, (scope ref Builder!InlayHintLabelPart out_) {
					if (!isEmpty(x.reExports))
						writeUrisOrCountLabelParts(alloc, out_, "Exported by ", x.reExports, maxUris);
					if (!isEmpty(x.imports))
						writeUrisOrCountLabelParts(
							alloc, out_, isEmpty(x.reExports) ? "Used by " : "; Used by ", x.imports, maxUris);
				});
			out_ ~= InlayHint(endOfLineForDecl(lcg, decl), InlayHintLabel(parts), paddingLeft: true);
		}
	});

	if (decl.isA!(FunDecl*))
		getInlayHintsForFun(alloc, out_, showCtx, decl.as!(FunDecl*));
	else if (decl.isA!(Test*))
		getInlayHintsForTest(alloc, out_, lcg, testStates, decl.as!(Test*));
}

void writeUrisOrCountLabelParts(
	ref Alloc alloc,
	scope ref Builder!InlayHintLabelPart out_,
	string description,
	in Uri[] uris,
	size_t maxUris,
) {
	if (uris.length > maxUris)
		out_ ~= InlayHintLabelPart(
			makeStringWithWriter(alloc, (scope ref Writer writer) {
				writer ~= description;
				writer ~= uris.length;
				writer ~= " other modules";
			}),
			tooltip: some(makeStringWithWriter(alloc, (scope ref Writer writer) {
				writeWithCommas!Uri(writer, uris, (in Uri x) {
					writer ~= baseName(x);
				});
			})));
	else {
		out_ ~= InlayHintLabelPart(description);
		writeInlayPartsWithCommas!Uri(out_, uris, (in Uri uri) =>
			InlayHintLabelPart(
				stringOfSymbol(alloc, baseName(uri)),
				location: some(UriAndLineAndCharacterRange.topOfFile(uri))));
	}
}

void writeInlayPartsWithCommas(T)(
	scope ref Builder!InlayHintLabelPart out_,
	in T[] values,
	in InlayHintLabelPart delegate(in T) @safe @nogc pure nothrow cb,
) {
	bool first = true;
	foreach (ref const T x; values) {
		if (first)
			first = false;
		else
			out_ ~= InlayHintLabelPart(", ");
		out_ ~= cb(x);
	}
}

void getInlayHintsForFun(ref Alloc alloc, scope ref Builder!InlayHint out_, in ShowModelCtx showCtx, FunDecl* fun) {
	if (!fun.source.isA!FunSourceAst) return;
	scope TypeContainer typeContainer = TypeContainer(fun);
	foreach (ref Destructure param; paramsArray(fun.params))
		getInlayHintsForDestructure(alloc, out_, showCtx, typeContainer, param);
	if (fun.body_.isA!Expr)
		eachDescendentExprIncluding(showCtx.commonTypes, funBodyExprRef(fun), (ExprRef expr) {
			eachDestructureAtExprForInlay(*expr.expr, (Destructure destructure) {
				getInlayHintsForDestructure(alloc, out_, showCtx, typeContainer, destructure);
			});
		});
}

void eachDestructureAtExprForInlay(in Expr a, in void delegate(Destructure) @safe @nogc pure nothrow cb) {
	if (a.isA!(LambdaExpr*))
		cb(a.as!(LambdaExpr*).param);
	else if (a.isA!(LetExpr*))
		cb(a.as!(LetExpr*).destructure);
	// Ignore MatchSumTypeExpr, since the type is explicit
}

void getInlayHintsForDestructure(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in ShowModelCtx showCtx,
	in TypeContainer typeContainer,
	in Destructure a,
) {
	LineAndCharacter toLineAndCharacter(Pos pos) =>
		showCtx.lineAndCharacterGetters[typeContainer.moduleUri][pos, PosKind.startOfRange];
	a.matchIn!void(
		(in DestructureIgnore x) {},
		(in Local x) {
			if (x.source.isA!(SingleDestructureAst*)) {
				SingleDestructureAst* ast = x.source.as!(SingleDestructureAst*);
				if (!has(ast.type)) {
					out_ ~= InlayHint(
						toLineAndCharacter(ast.name.range.end),
						InlayHintLabel(makeStringWithWriter(alloc, (scope ref Writer writer) {
							writeTypeUnquoted(writer, showCtx, TypeWithContainer(x.type, typeContainer));
						})),
						InlayHintKind.Type,
						paddingLeft: true);
				}
				Purity purity = bestCasePurity(x.type);
				if (purity != Purity.data)
					out_ ~= InlayHint(
						toLineAndCharacter(ast.range.end),
						InlayHintLabel(stringOfEnum(purity)),
						InlayHintKind.none,
						paddingLeft: true);
			}
		},
		(in DestructureSplit x) {
			foreach (Destructure part; x.parts)
				getInlayHintsForDestructure(alloc, out_, showCtx, typeContainer, part);
		});
}

LineAndCharacter endOfLineForDecl(in LineAndCharacterGetter lcg, in AnyDecl decl) =>
	endOfLine(lcg, decl.range.range.start);

void getInlayHintsForTest(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in LineAndCharacterGetter lcg,
	in TestStates testStates,
	in Test* test,
) {
	Uri uri = test.moduleUri;
	UriAndLine where = UriAndLine(uri, lineOfPos(lcg, test.range.start));
	Opt!RunResult optResult = testStates[where];
	LineAndCharacter position = endOfLineForDecl(lcg, AnyDecl(test));
	if (has(optResult)) {
		out_ ~= InlayHint(position, labelForTestResult(alloc, force(optResult)), paddingLeft: true);
	} else {
		out_ ~= InlayHint(position, labelForRunTest(alloc, where), paddingLeft: true);
	}
}

InlayHintLabel labelForTestResult(ref Alloc alloc, RunResult a) =>
	InlayHintLabel(newArray(alloc, [
		InlayHintLabelPart(
			isOk(a.exit) ? "OK" : "Test failed",
			tooltip: tooltipForRunResult(alloc, a))]));

InlayHintLabel labelForRunTest(ref Alloc alloc, UriAndLine where) =>
	InlayHintLabel(newArray(alloc, [
		InlayHintLabelPart(
			"Run test",
			command: some(Command(arguments: some(ExecuteCommandParams(ExecuteCommandParams.RunTest(where))))),
		)]));

Opt!string tooltipForRunResult(ref Alloc alloc, RunResult result) =>
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
