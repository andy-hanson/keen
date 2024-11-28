module frontend.parse.parseString;

@safe @nogc pure nothrow:

import frontend.parse.lexer :
	addDiag,
	curPos,
	Lexer,
	range,
	takeClosingBraceThenStringPart,
	takeInitialStringPart,
	Token;
import frontend.parse.lexString : QuoteKind, StringPart, StringPartAfter;
import frontend.parse.parseUtil : peekToken, skipBlankLines, takeNameOrOperator, tryTakeToken;
import model.ast :
	DocCommentAst, DocCommentContent, ExprAst, ExprAstKind, InterpolatedAst, LiteralStringAst, NameAndRange;
import model.parseDiag : ParseDiag, ParseDiagMissingInterpolated;
import model.sourceRange : Pos, Range;
import util.col.array : isEmpty;
import util.col.arrayBuilder : add, ArrayBuilder, finish, smallFinish;
import util.memory : allocate;
import util.opt : some;

DocCommentAst tryTakeDocComment(ref Lexer lexer) {
	skipBlankLines(lexer);
	Pos start = curPos(lexer);
	if (!tryTakeToken(lexer, Token.quoteBar)) return DocCommentAst.empty;

	ArrayBuilder!NameAndRange references;
	DocCommentAst done() =>
		DocCommentAst(some(allocate(lexer.alloc, DocCommentContent(
			range(lexer, start),
			smallFinish(lexer.alloc, references)))));
	DocCommentAst res = takeInterpolatedCb!DocCommentAst(
		lexer, start, QuoteKind.quoteBar,
		cbSingle: (StringPart _) =>
			done(),
		cbInterpolation: () {
			add(lexer.alloc, references, takeNameOrOperator(lexer));
		},
		cbString: (StringPart _) {},
		cbFinish: () =>
			done());
	skipBlankLines(lexer);
	return res;
}

ExprAst parseString(
	ref Lexer lexer,
	Pos start,
	QuoteKind quoteKind,
	in ExprAst delegate() @safe @nogc pure nothrow cbInterpolated,
) {
	ArrayBuilder!ExprAst parts;
	return takeInterpolatedCb!ExprAst(
		lexer, start, quoteKind,
		cbSingle: (StringPart part) =>
			ExprAst(range(lexer, start), ExprAstKind(LiteralStringAst(part.text))),
		cbInterpolation: () {
			add(lexer.alloc, parts, cbInterpolated());
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
		case StringPartAfter.done:
			return cbSingle(firstPart);
		case StringPartAfter.lbrace:
			if (!isEmpty(firstPart.text))
				cbString(firstPart);
			while (true) {
				if (peekToken(lexer, Token.braceRight)) {
					Pos pos = curPos(lexer);
					Range range = Range(pos - 1, pos + 1);
					addDiag(lexer, range, ParseDiag(ParseDiagMissingInterpolated()));
				} else
					cbInterpolation();
				StringPart part = takeClosingBraceThenStringPart(lexer, quoteKind);
				if (!isEmpty(part.text))
					cbString(part);
				final switch (part.after) {
					case StringPartAfter.done:
						return cbFinish();
					case StringPartAfter.lbrace:
						continue;
				}
			}
	}
}
