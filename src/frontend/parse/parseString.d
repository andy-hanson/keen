module frontend.parse.parseString;

@safe @nogc pure nothrow:

import frontend.parse.parseExpr : parseExprNoBlock; // TODO: CIRCULAR DEPENDENCY =--=-----------------------------------------------
import frontend.parse.lexer :
	addDiag, curPos, Lexer, QuoteKind, range, StringPart, takeClosingBraceThenStringPart, takeInitialStringPart, Token;
import frontend.parse.parseType : parseType;
import frontend.parse.parseUtil : peekToken, tryTakeToken;
import model.ast : DocCommentAst, DocCommentContent, ExprAst, ExprAstKind, InterpolatedAst, LiteralStringAst, TypeAst;
import model.parseDiag : ParseDiag;
import util.col.array : isEmpty;
import util.col.arrayBuilder : add, ArrayBuilder, finish, smallFinish;
import util.memory : allocate;
import util.opt : some;
import util.sourceRange : Pos, Range;

DocCommentAst tryTakeDocComment(ref Lexer lexer) {
	Pos start = curPos(lexer);
	if (!tryTakeToken(lexer, Token.quoteBar)) return DocCommentAst.empty;

	ArrayBuilder!TypeAst references;
	DocCommentAst done() =>
		DocCommentAst(some(allocate(lexer.alloc, DocCommentContent(
			range(lexer, start),
			smallFinish(lexer.alloc, references)))));
	return takeInterpolatedCb!DocCommentAst(
		lexer, start, QuoteKind.quoteBar,
		cbSingle: (StringPart _) =>
			done(),
		cbInterpolation: () {
			add(lexer.alloc, references, parseType(lexer));
		},
		cbString: (StringPart _) {},
		cbFinish: () =>
			done());
}

ExprAst parseString(ref Lexer lexer, Pos start, QuoteKind quoteKind) {
	ArrayBuilder!ExprAst parts;
	return takeInterpolatedCb!ExprAst(
		lexer, start, quoteKind,
		cbSingle: (StringPart part) =>
			ExprAst(range(lexer, start), ExprAstKind(LiteralStringAst(part.text))),
		cbInterpolation: () {
			add(lexer.alloc, parts, parseExprNoBlock(lexer));
		},
		cbString: (StringPart part) {
			add(lexer.alloc, parts, ExprAst(part.range, ExprAstKind(LiteralStringAst(part.text))));
		},
		cbFinish: () => 
			ExprAst(range(lexer, start), ExprAstKind(InterpolatedAst(finish(lexer.alloc, parts)))));
}

private:

Out takeInterpolatedCb(Out)(
	ref Lexer lexer,
	Pos start,
	QuoteKind quoteKind,
	in Out delegate(StringPart) @safe @nogc pure nothrow cbSingle,
	in void delegate() @safe @nogc pure nothrow cbInterpolation,
	in void delegate(StringPart) @safe @nogc pure nothrow cbString,
	in Out delegate() @safe @nogc pure nothrow cbFinish,
) {
	StringPart firstPart = takeInitialStringPart(lexer, quoteKind);
	final switch (firstPart.after) {
		case StringPart.After.done:
			return cbSingle(firstPart);
		case StringPart.After.lbrace:
			if (!isEmpty(firstPart.text))
				cbString(firstPart);
			while (true) {
				if (peekToken(lexer, Token.braceRight)) {
					Pos pos = curPos(lexer);
					Range range = Range(pos - 1, pos + 1);
					addDiag(lexer, range, ParseDiag(ParseDiag.MissingExpression())); // TODO: update diag for doc comment case ........
				} else
					cbInterpolation();
				StringPart part = takeClosingBraceThenStringPart(lexer, quoteKind);
				if (!isEmpty(part.text))
					cbString(part);
				final switch (part.after) {
					case StringPart.After.done:
						return cbFinish();
					case StringPart.After.lbrace:
						continue;
				}
			}
	}
}
