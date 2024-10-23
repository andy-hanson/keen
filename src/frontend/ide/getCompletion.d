module frontend.ide.getCompletion;

@safe @nogc pure nothrow:

import document.document : docCommentString;
import frontend.check.inferringType : isTypeMatchPossibleForCompletions;
import frontend.ide.position : ExprContainer, ExpressionPosition, ExpressionPositionKind, ExprKeyword, Position;
import frontend.showModel : ShowTypeCtx, writeCalledDecl, WriteKind;
import lib.lsp.lspTypes : CompletionItem, CompletionList;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	BogusCallExpr,
	CalledDecl,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	Destructure,
	eachCalledSpecSig,
	eachImportOrReExport,
	ExternExpr,
	FunDecl,
	FunPointerExpr,
	ImportOrExport,
	Module,
	NameReferents,
	Params,
	SpecInst,
	StructInst,
	Type;
import util.alloc.alloc : Alloc;
import util.col.array : isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, none, Opt, optIf, some;
import util.symbol : stringOfSymbol;
import util.writer : makeStringWithWriter, Writer;

Opt!CompletionList getCompletionForPosition(ref Alloc alloc, in ShowTypeCtx showCtx, in Position pos) =>
	pos.kind.isA!ExpressionPosition
		? completionAtExpressionPosition(alloc, showCtx, pos.module_, pos.kind.as!ExpressionPosition)
		: none!CompletionList;

private:

Opt!CompletionList completionAtExpressionPosition(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in Module* module_,
	in ExpressionPosition a,
) =>
	a.kind.matchIn!(Opt!CompletionList)(
		(in BogusCallExpr _) =>
			none!CompletionList,
		(in CallExpr _) =>
			none!CompletionList,
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

Opt!CompletionList completionAfterType(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in Module* module_,
	in ExprContainer container,
	Type type,
) {
	CompletionItem[] items = buildArray!CompletionItem(alloc, (scope ref Builder!CompletionItem out_) {
		eachFunInExprScope(*module_, container, (CalledDecl fun) @safe {
			Opt!Type t = firstParamType(fun);
			if (has(t) &&
				// Don't include a function that accepts any type, since this results in too many functions matching
				force(t).isA!(StructInst*) &&
				isTypeMatchPossibleForCompletions(TypeWithContainer(force(t), typeContainerFor(fun)), type)
			) {
				out_ ~= completionForCalledDecl(alloc, showCtx, container.toTypeContainer, fun);
			}
		});
	});
	return optIf(!isEmpty(items), () => CompletionList(items));
}

TypeContainer typeContainerFor(CalledDecl a) =>
	a.matchWithPointers!TypeContainer(
		(FunDecl* x) =>
			TypeContainer(x),
		(CalledSpecSig x) =>
			TypeContainer(x.specInst.decl));

CompletionItem completionForCalledDecl(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in TypeContainer typeContainer,
	in CalledDecl a,
) =>
	CompletionItem(
		stringOfSymbol(alloc, a.name),
		makeStringWithWriter(alloc, (scope ref Writer writer) {
			writeCalledDecl(writer, showCtx, WriteKind.unquoted, typeContainer, a);
		}),
		docCommentString(showCtx.fileContentGetters, a.moduleUri, a.docComment));

Opt!Type firstParamType(in CalledDecl a) =>
	a.matchIn!(Opt!Type)(
		(in FunDecl x) =>
			firstParamType(x),
		(in CalledSpecSig x) =>
			firstParamType(x));
Opt!Type firstParamType(in FunDecl a) =>
	a.params.matchIn!(Opt!Type)(
		(in Destructure[] x) =>
			optIf(!isEmpty(x), () => x[0].type),
		(in Params.Varargs x) =>
			some(x.elementType));
Opt!Type firstParamType(in CalledSpecSig a) {
	Type[] paramTypes = a.instantiatedSig.paramTypes;
	return optIf(!isEmpty(paramTypes), () => paramTypes[0]);
}

void eachFunInExprScope(
	in Module module_,
	in ExprContainer container,
	in void delegate(CalledDecl) @safe @nogc pure nothrow cb,
) {
	foreach (SpecInst* spec; container.specs)
		eachCalledSpecSig(spec, (CalledSpecSig x) {
			cb(CalledDecl(x));
		});
	foreach (ref FunDecl x; module_.funs)
		cb(CalledDecl(&x));
	eachImportOrReExport(module_, (ref ImportOrExport x) {
		foreach (ref immutable NameReferents* refs; x.imported) {
			foreach (FunDecl* fun; refs.funs)
				cb(CalledDecl(fun));
		}
	});
}
