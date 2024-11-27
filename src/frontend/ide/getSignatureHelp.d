module frontend.ide.getSignatureHelp;

@safe @nogc pure nothrow:

import document.document : docCommentString;
import frontend.ide.position :
	ExpressionPosition, ExpressionPositionKind, ExpressionPositionLiteral, ExprKeyword, LocalRef, LoopKeyword, Position;
import frontend.showModel : ShowTypeCtx, writeCalledDecl, WriteKind;
import lib.lsp.lspTypes : ParameterInformation, SignatureHelp, SignatureInformation;
import model.ast : CallAst, ExprAstKind;
import model.model :
	Arity,
	BogusCallExpr,
	CalledDecl,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	ExternExpr,
	FunDecl,
	FunPointerExpr,
	TypeContainer;
import util.alloc.alloc : Alloc;
import util.col.array : map;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish, newExactSizeArrayBuilder;
import util.conv : safeToUint;
import util.opt : none, Opt, some;
import util.sourceRange : Range;
import util.string : smallString;
import util.writer : curUtf16Offset, makeStringWithWriter, Writer;

Opt!SignatureHelp getSignatureHelpForPosition(ref Alloc alloc, in ShowTypeCtx showCtx, in Position position) =>
	position.kind.isA!ExpressionPosition
		? signatureHelpAtExpressionPosition(alloc, showCtx, position.kind.as!ExpressionPosition)
		: none!SignatureHelp;

private:

Opt!SignatureHelp signatureHelpAtExpressionPosition(ref Alloc alloc, in ShowTypeCtx showCtx, in ExpressionPosition a) =>
	a.kind.matchIn!(Opt!SignatureHelp)(
		(in BogusCallExpr x) =>
			some(signatureHelpAtBogusCall(alloc, showCtx, a.container.toTypeContainer, a, x)),
		(in CallExpr x) =>
			none!SignatureHelp,
		(in CallOptionExpr x) =>
			none!SignatureHelp,
		(in ExprKeyword x) =>
			none!SignatureHelp,
		(in ExternExpr _) =>
			none!SignatureHelp,
		(in FunPointerExpr x) =>
			none!SignatureHelp,
		(in ExpressionPositionLiteral _) =>
			none!SignatureHelp,
		(in LocalRef _) =>
			none!SignatureHelp,
		(in LoopKeyword _) =>
			none!SignatureHelp);

SignatureHelp signatureHelpAtBogusCall(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in TypeContainer outerTypeContainer,
	in ExpressionPosition expr,
	in BogusCallExpr a,
) {
	Opt!uint activeParameter = activeParameter(expr);
	return SignatureHelp(
		signatures: map(alloc, a.candidates, (ref CalledDecl x) =>
			signatureInformation(alloc, showCtx, outerTypeContainer, x, activeParameter)),
		activeSignature: none!uint,
		activeParameter: activeParameter);
}

Opt!uint activeParameter(in ExpressionPosition a) {
	ExprAstKind kind = a.expr.expr.ast.kind;
	return kind.isA!CallAst
		? some(safeToUint(kind.as!CallAst.args.length))
		: none!uint;
}

SignatureInformation signatureInformation(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in TypeContainer outerTypeContainer,
	ref CalledDecl a,
	in Opt!uint activeParameter,
) {
	TypeContainer typeContainer = a.matchWithPointers!TypeContainer(
		(FunDecl* x) =>
			TypeContainer(x),
		(CalledSpecSig _) =>
			outerTypeContainer);

	size_t nParams = a.arity.matchIn!size_t(
		(in uint x) => x,
		(in Arity.Varargs) => 1);
	ExactSizeArrayBuilder!ParameterInformation parameters =
		newExactSizeArrayBuilder!ParameterInformation(alloc, nParams);

	uint begin;
	string signature = makeStringWithWriter(alloc, (scope ref Writer writer) {
		writeCalledDecl(
			writer, showCtx, WriteKind.unquoted, typeContainer, a,
			() {
				begin = safeToUint(curUtf16Offset(writer));
			},
			() {
				uint end = safeToUint(curUtf16Offset(writer));
				parameters ~= ParameterInformation(Range(begin, end));
			});
	});
	return SignatureInformation(
		signature,
		smallString(docCommentString(alloc, showCtx.fileContentGetters, a.moduleUri, a.docComment)),
		finish(parameters),
		activeParameter: activeParameter);
}
