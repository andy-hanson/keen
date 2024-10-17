module frontend.ide.getInlayHints;

@safe @nogc pure nothrow:

import frontend.ide.getCodeLenses : ImportsAndReExports, isEmpty, tooltipForRunResult, UrisOrCount, withImportsAndReExportsOf, writeUrisOrCount;
import frontend.showModel : ShowModelCtx, writeTypeUnquoted;
import lib.lsp.lspTypes :
	Command,
	ExecuteCommandParams,
	InlayHint,
	InlayHintKind,
	InlayHintLabel,
	InlayHintLabelPart,
	RunResult;
import lib.server : TestStates; // TODO: CIRCULAR IMPORT ---------------------------------------------------------------------------
import model.ast : DestructureAst;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	AnyDecl,
	bestCasePurity,
	Destructure,
	eachDecl,
	eachDescendentExprIncluding,
	Expr,
	ExprRef,
	funBodyExprRef,
	FunDecl,
	FunDeclSource,
	LambdaExpr,
	LetExpr,
	Local,
	MatchUnionExpr,
	Module,
	paramsArray,
	Program,
	Purity,
	Test,
	Type,
	Visibility;
import util.alloc.alloc : Alloc;
import util.col.array : isEmpty, newArray;
import util.col.arrayBuilder : buildSortedArray, Builder;
import util.comparison : Comparison;
import util.exitCode : isOk;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : compareLineAndCharacter, endOfLine, LineAndCharacter, lineOfPos, Pos, PosKind, UriAndLine, UriAndPos;
import util.uri : Uri;
import util.util : stringOfEnum;
import util.writer : makeStringWithWriter, Writer;

InlayHint[] getInlayHints(ref Alloc alloc, in Program program, in ShowModelCtx showCtx, in TestStates testStates, in Module module_) =>
	buildSortedArray!(InlayHint, compareInlayHints)(alloc, (scope ref Builder!InlayHint out_) {
		eachDecl(module_, (AnyDecl x) {
			getInlayHintsForDecl(alloc, out_, program, showCtx, testStates, x);
		});
	});

//InlayHint resolveInlayHint(ref Alloc alloc, in Program program, in ShowModelCtx showCtx, in TestStates testStates, in InlayHint unresolved) => // KILL
//	has(unresolved.data)
//		? resolveInlayHintForTest(alloc, showCtx, testStates, unresolved)
//		: copyInlayHint(alloc, unresolved);

private:

Comparison compareInlayHints(in InlayHint a, in InlayHint b) =>
	compareLineAndCharacter(a.position, b.position);

void getInlayHintsForDecl(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in Program program,
	in ShowModelCtx showCtx,
	in TestStates testStates,
	AnyDecl decl,
) {
	Uri uri = decl.moduleUri;
	withImportsAndReExportsOf!void(program, decl, maxUris: 4, cb: (in ImportsAndReExports x) {
		if (!isEmpty(x)) {
			string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
				writeUrisOrCount(writer, "Exported by", uri, x.reExports); // TODO: there is some pretty similar code in getCodeLenses
				if (!isEmpty(x.imports)) {
					if (!isEmpty(x.reExports)) writer ~= "; ";
					writeUrisOrCount(writer, "Used by", uri, x.imports);
				}
			});
			out_ ~= InlayHint(endOfLineForDecl(showCtx, decl), InlayHintLabel(message), InlayHintKind.none, paddingLeft: true);
		}
	});

	if (decl.isA!(FunDecl*))
		getInlayHintsForFun(alloc, out_, showCtx, decl.as!(FunDecl*));
	else if (decl.isA!(Test*))
		getInlayHintsForTest(alloc, out_, showCtx, testStates, decl.as!(Test*));
}

void getInlayHintsForFun(ref Alloc alloc, scope ref Builder!InlayHint out_, in ShowModelCtx showCtx, FunDecl* fun) {
	if (!fun.source.isA!(FunDeclSource.Ast)) return;
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
	if (a.kind.isA!(LambdaExpr*))
		cb(a.kind.as!(LambdaExpr*).param);
	else if (a.kind.isA!(LetExpr*))
		cb(a.kind.as!(LetExpr*).destructure);
	// Ignore MatchVariantExpr, since the type is explicit
	else if (a.kind.isA!(MatchUnionExpr*)) {
		foreach (MatchUnionExpr.Case case_; a.kind.as!(MatchUnionExpr*).cases)
			cb(case_.destructure);
	}
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
		(in Destructure.Ignore x) {},
		(in Local x) {
			if (x.source.isA!(DestructureAst.Single*)) {
				DestructureAst.Single* ast = x.source.as!(DestructureAst.Single*);
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
		(in Destructure.Split x) {
			foreach (Destructure part; x.parts)
				getInlayHintsForDestructure(alloc, out_, showCtx, typeContainer, part);
		});
}

LineAndCharacter endOfLineForDecl(in ShowModelCtx showCtx, in AnyDecl decl) =>
	endOfLine(showCtx.lineAndCharacterGetters[decl.moduleUri], decl.range.range.start);

void getInlayHintsForTest(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in ShowModelCtx showCtx,
	in TestStates testStates,
	in Test* test,
) {
	Uri uri = test.moduleUri;
	UriAndLine where = UriAndLine(uri, lineOfPos(showCtx.lineAndCharacterGetters[uri], test.range.start));
	Opt!RunResult optResult = testStates[where];
	LineAndCharacter position = endOfLineForDecl(showCtx, AnyDecl(test));
	if (has(optResult)) {
		out_ ~= InlayHint(position, labelForTestResult(alloc, force(optResult)), paddingLeft: true);
	} else {
		out_ ~= InlayHint(position, labelForRunTest(alloc, where), paddingLeft: true);
	}
}

//InlayHint resolveInlayHintForTest(ref Alloc alloc, in ShowModelCtx showCtx, in TestStates testStates, in InlayHint unresolved) {
//	UriAndLine where = UriAndLine(force(unresolved.data), unresolved.position.line);
//	Opt!RunResult optResult = testStates[where];
//	assert(!has(optResult));
//	return InlayHint(unresolved.position, some(labelForRunTest(alloc, where)), paddingLeft: true);
//}

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
