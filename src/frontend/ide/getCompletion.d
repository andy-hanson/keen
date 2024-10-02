module frontend.ide.getCompletion;

@safe @nogc pure nothrow:

import frontend.check.inferringType : isTypeMatchPossibleForCompletions;
import frontend.ide.position : ExprContainer, ExpressionPosition, ExpressionPositionKind, ExprKeyword, Position;
import frontend.showModel : ShowTypeCtx, writeFunDecl, WriteKind;
import lib.lsp.lspTypes : CompletionItem, CompletionList;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	BogusCallExpr,
	CallExpr,
	CallOptionExpr,
	Destructure,
	eachImportOrReExport,
	ExternExpr,
	FunDecl,
	FunPointerExpr,
	ImportOrExport,
	Module,
	NameReferents,
	Params,
	Type;
import util.alloc.alloc : Alloc;
import util.col.array : isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, none, Opt, optIf, some;
import util.symbol : stringOfSymbol;
import util.writer : makeStringWithWriter, Writer;
import util.util : debugLog; // -----------------------------------------------------------------------------------------------------------------

Opt!CompletionList getCompletionForPosition(ref Alloc alloc, in ShowTypeCtx showCtx, in Position pos) {
	debugLog("Top of getCompletionForPosition");
	return pos.kind.isA!ExpressionPosition
		? completionAtExpressionPosition(alloc, showCtx, pos.module_, pos.kind.as!ExpressionPosition)
		: none!CompletionList;
}

private:

Opt!CompletionList completionAtExpressionPosition(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in Module* module_,
	in ExpressionPosition a,
) {
	debugLog("It's at an expression");
	return a.kind.matchIn!(Opt!CompletionList)(
		(in BogusCallExpr _) =>
			none!CompletionList, // TODO ------------------------------------------------------------------------------------------------
		(in CallExpr _) {
			debugLog("It's at a call");
			return none!CompletionList; // TODO -------------------------------------------------------------------------------------
		},
		(in CallOptionExpr _) =>
			none!CompletionList,
		(in ExprKeyword _) =>
			none!CompletionList,
		(in ExternExpr _) =>
			none!CompletionList,
		(in FunPointerExpr x) =>
			none!CompletionList,
		(in ExpressionPositionKind.Literal) =>
			none!CompletionList,
		(in ExpressionPositionKind.LocalRef x) =>
			completionAfterType(alloc, showCtx, module_, a.container, x.local.type),
		(in ExpressionPositionKind.LoopKeyword) =>
			none!CompletionList);
}

Opt!CompletionList completionAfterType(ref Alloc alloc, in ShowTypeCtx showCtx, in Module* module_, in ExprContainer container, Type type) {
	debugLog("top of completionAfterType"); 
	CompletionItem[] items = buildArray!CompletionItem(alloc, (scope ref Builder!CompletionItem out_) {
		eachFunInExprScope(*module_, container, (FunDecl* fun) {
			Opt!Type t = firstParamType(*fun);
			if (has(t) && isTypeMatchPossibleForCompletions(TypeWithContainer(force(t), TypeContainer(fun)), type)) {
				out_ ~= completionForFun(alloc, showCtx, fun);	
			}
		});
	});
	return optIf(!isEmpty(items), () => CompletionList(items));
}

CompletionItem completionForFun(ref Alloc alloc, in ShowTypeCtx showCtx, in FunDecl* fun) =>
	CompletionItem(
		stringOfSymbol(alloc, fun.name),
		makeStringWithWriter(alloc, (scope ref Writer writer) {
			writeFunDecl(writer, showCtx, WriteKind.unquoted, fun);
		}),
		fun.docComment);

Opt!Type firstParamType(in FunDecl a) =>
	a.params.matchIn!(Opt!Type)(
		(in Destructure[] x) =>
			optIf(!isEmpty(x), () => x[0].type),
		(in Params.Varargs x) =>
			some(x.elementType));

void eachFunInExprScope(in Module module_, in ExprContainer container, in void delegate(FunDecl*) @safe @nogc pure nothrow cb) {
	// TODO: also use specs from container -----------------------------------------------------------------------------------------------------------------
	eachImportOrReExport(module_, (ref ImportOrExport x) {
		foreach (ref immutable NameReferents* refs; x.imported) {
			foreach (FunDecl* fun; refs.funs)
				cb(fun);
		}
	});
	foreach (ref FunDecl x; module_.funs)
		cb(&x);
}
