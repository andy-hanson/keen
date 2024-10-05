module frontend.ide.getInlayHints;

@safe @nogc pure nothrow:

import frontend.showModel : ShowModelCtx, writeTypeUnquoted;
import lib.lsp.lspTypes : InlayHint, InlayHintKind;
import model.ast : DestructureAst;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	Destructure, eachDescendentExprIncluding, Expr, ExprRef, funBodyExprRef, FunDecl, LetExpr, Local, Module, Type;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : has;
import util.writer : makeStringWithWriter, Writer;

InlayHint[] getInlayHints(ref Alloc alloc, in ShowModelCtx showCtx, in Module module_) =>
	buildArray!InlayHint(alloc, (scope ref Builder!InlayHint out_) {
		foreach (ref FunDecl x; module_.funs)
			getInlayHintsForFun(alloc, out_, showCtx, x);
	});

private:

void getInlayHintsForFun(ref Alloc alloc, scope ref Builder!InlayHint out_, in ShowModelCtx showCtx, ref FunDecl fun) {
	if (fun.body_.isA!Expr)
		eachDescendentExprIncluding(showCtx.commonTypes, funBodyExprRef(&fun), (ExprRef x) {
			// TODO: show inlay hints on other things (e.g. variable in a 'match') -----------------------------------------
			if (x.expr.kind.isA!(LetExpr*)) {
				getInlayHintsForDestructure(alloc, out_, showCtx, TypeContainer(&fun), x.expr.kind.as!(LetExpr*).destructure);
			}
		});
}

void getInlayHintsForDestructure(
	ref Alloc alloc,
	scope ref Builder!InlayHint out_,
	in ShowModelCtx showCtx,
	in TypeContainer typeContainer,
	in Destructure a,
) =>
	a.matchIn!void(
		(in Destructure.Ignore x) {
			// todo ---------------------------------------------------------------------------------------------------------
		},
		(in Local x) {
			// todo -------------------------------------------------------------------------------------------------------
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
			}
		},
		(in Destructure.Split x) {
			// todo -------------------------------------------------------------------------------------------------------
		});
