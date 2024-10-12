module frontend.ide.getInlayHints;

@safe @nogc pure nothrow:

import frontend.showModel : ShowModelCtx, writeTypeUnquoted;
import lib.lsp.lspTypes : InlayHint, InlayHintKind;
import model.ast : DestructureAst;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	bestCasePurity,
	Destructure,
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
	Purity,
	Type;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : has, none;
import util.writer : makeStringWithWriter, Writer;
import util.util : stringOfEnum;

InlayHint[] getInlayHints(ref Alloc alloc, in ShowModelCtx showCtx, in Module module_) =>
	buildArray!InlayHint(alloc, (scope ref Builder!InlayHint out_) {
		foreach (ref FunDecl x; module_.funs)
			if (x.source.isA!(FunDeclSource.Ast))
				getInlayHintsForFun(alloc, out_, showCtx, x);
	});

private:

void getInlayHintsForFun(ref Alloc alloc, scope ref Builder!InlayHint out_, in ShowModelCtx showCtx, ref FunDecl fun) {
	scope TypeContainer typeContainer = TypeContainer(&fun);
	foreach (ref Destructure param; paramsArray(fun.params))
		getInlayHintsForDestructure(alloc, out_, showCtx, typeContainer, param);
	if (fun.body_.isA!Expr)
		eachDescendentExprIncluding(showCtx.commonTypes, funBodyExprRef(&fun), (ExprRef expr) {
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
	a.matchIn!void(
		(in Destructure.Ignore x) {},
		(in Local x) {
			if (x.source.isA!(DestructureAst.Single*)) {
				DestructureAst.Single* ast = x.source.as!(DestructureAst.Single*);
				if (!has(ast.type)) {
					out_ ~= InlayHint(
						ast.name.range.end,
						makeStringWithWriter(alloc, (scope ref Writer writer) {
							writeTypeUnquoted(writer, showCtx, TypeWithContainer(x.type, typeContainer));
						}),
						InlayHintKind.Type,
						paddingLeft: true,
						paddingRight: false);
				}
				Purity purity = bestCasePurity(x.type);
				if (purity != Purity.data)
					out_ ~= InlayHint(
						ast.range.end,
						stringOfEnum(purity),
						InlayHintKind.none,
						paddingLeft: true,
						paddingRight: false);
			}
		},
		(in Destructure.Split x) {
			foreach (Destructure part; x.parts)
				getInlayHintsForDestructure(alloc, out_, showCtx, typeContainer, part);
		});
}
