module frontend.parse.lexer;

@safe @nogc pure nothrow:

import frontend.parse.lexString : takeStringPart;
import frontend.parse.lexToken :
	ExtraDedents,
	isNewlineToken,
	lexInitialToken,
	lexToken,
	lookaheadColon,
	lookaheadElifOrElse,
	lookaheadKeyword,
	lookaheadEquals,
	lookaheadLambdaAfterParenLeft,
	lookaheadQuestionEquals,
	plainToken;
import frontend.parse.lexWhitespace :
	CStringRange, detectIndentKind, IndentKind, mayContinueOntoNextLine, skipSpacesAndComments, skipUntilNewline;
import model.parseDiag : ParseDiag, ParseDiagnostic;
import util.alloc.alloc : Alloc;
import util.cell : Cell, cellGet, cellSet;
import util.col.array : SmallArray;
import util.col.arrayBuilder : add, ArrayBuilder, smallFinish;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : Pos, Range;
import util.string : CString, MutCString;
import util.symbol : symbol;
import util.util : enumConvert;

public import frontend.parse.lexString : QuoteKind, StringPart;
public import frontend.parse.lexToken : ElifOrElseKeyword, Token, TokenAndData;

struct Lexer {
	@safe @nogc pure nothrow:
	private:
	Alloc* allocPtr;
	immutable CString sourceBegin;
	immutable IndentKind indentKind;

	// Lexer state:
	// This is the indent at 'ptr', after 'nextToken'.
	uint curIndent;
	// This is after 'nextToken'.
	MutCString ptr;
	MutCString prevTokenEnd;
	ArrayBuilder!ParseDiagnostic diagnosticsBuilder;
	// Position at start of 'nextToken'.
	Pos nextTokenPos = void;
	Cell!TokenAndData nextToken = void;

	public:
	ref Alloc alloc() return scope =>
		*allocPtr;
}

@trusted Lexer createLexer(Alloc* alloc, CString source) {
	Lexer lexer = Lexer(alloc, source, detectIndentKind(source), 0, source, source);
	cellSet(lexer.nextToken,
		lexInitialToken(lexer.ptr, lexer.indentKind, lexer.curIndent, (CString start, ParseDiag x) =>
			addDiagFromPointer(lexer, start, x)));
	return lexer;
}

uint getCurIndent(in Lexer lexer) =>
	lexer.curIndent;

private void addDiagFromPointer(scope ref Lexer lexer, CString start, ParseDiag diag) {
	addDiag(lexer, Range(posOf(lexer, start), posAtPtr(lexer)), diag);
}

Pos curPos(in Lexer lexer) =>
	lexer.nextTokenPos;
private Pos posAtPtr(in Lexer lexer) =>
	posOf(lexer, lexer.ptr);

Range rangeOf(in Lexer lexer, in CStringRange range) =>
	range.isEmpty
		? Range.empty
		: Range(posOf(lexer, range.start), posOf(lexer, range.end));
private Pos posOf(in Lexer lexer, in CString ptr) =>
	ptr - lexer.sourceBegin;

void addDiag(ref Lexer lexer, in Range range, ParseDiag diag) {
	add(lexer.alloc, lexer.diagnosticsBuilder, ParseDiagnostic(range, diag));
}

SmallArray!ParseDiagnostic finishDiagnostics(ref Lexer lexer) =>
	smallFinish(lexer.alloc, lexer.diagnosticsBuilder);

void addDiagAtChar(ref Lexer lexer, ParseDiag diag) {
	addDiag(lexer, rangeAtChar(lexer), diag);
}

Range rangeAtChar(in Lexer lexer) {
	Pos pos = curPos(lexer);
	Pos nextPos = () @trusted {
		switch (*lexer.ptr) {
			case '\0':
				return pos;
			case '\r':
				MutCString ptr = lexer.ptr;
				ptr++;
				// Treat "\r\n" as one character
				return *ptr == '\n' ? pos + 2 : pos + 1;
			default:
				return pos + 1;
		}
	}();
	return Range(pos, nextPos);
}

void addDiagUnexpectedCurToken(ref Lexer lexer, Pos start, in TokenAndData token) {
	ParseDiag diag = () @trusted {
		switch (token.token) {
			case Token.unexpectedCharacter:
				return ParseDiag(ParseDiag.UnexpectedCharacter(token.asUnexpectedCharacter));
			case Token.operator:
				return ParseDiag(ParseDiag.UnexpectedOperator(token.asSymbol));
			default:
				return ParseDiag(ParseDiag.UnexpectedToken(token.token));
		}
	}();
	addDiag(lexer, rangeForCurToken(lexer, start), diag);
}

Range range(in Lexer lexer, Pos start) =>
	Range(start, posOf(lexer, lexer.prevTokenEnd));

Range rangeForCurToken(in Lexer lexer, Pos start) =>
	isNewlineToken(getPeekToken(lexer))
		? Range(start, start)
		: Range(start, posAtPtr(lexer));

void skipUntilNewlineNoDiag(ref Lexer lexer) {
	if (!isNewlineToken(getPeekToken(lexer))) {
		skipUntilNewline(lexer.ptr);
		readNextToken(lexer);
		assert(isNewlineToken(getPeekToken(lexer)));
	}
}

/*
Since we've ignoring indentation, we need to set the final logical indent level
E.g., in:

f nat(
		x nat)
	x + 1

After the ')', we want to parse as if the previous indent level was 0 (which it was at the '(')
*/

void skipNewlinesIgnoreIndentation(ref Lexer lexer, uint indentLevel) {
	while (true) {
		switch (getPeekToken(lexer)) {
			case Token.newlineDedent:
			case Token.newlineIndent:
			case Token.newlineSameIndent:
				takeNextToken(lexer);
				continue;
			case Token.endOfFile:
				if (indentLevel != 0)
					cellSet(lexer.nextToken, TokenAndData(Token.newlineDedent, ExtraDedents(0)));
				lexer.curIndent = 0;
				return;
			default:
				lexer.curIndent = indentLevel;
				return;
		}
	}
}

void mustTakeToken(ref Lexer lexer, Token token) {
	Token actual = takeNextToken(lexer).token;
	assert(actual == token);
}

TokenAndData takeNextToken(ref Lexer lexer) {
	TokenAndData res = cellGet(lexer.nextToken);
	switch (res.token) {
		case Token.newlineDedent:
			uint extraDedents = res.asExtraDedents;
			cellSet(lexer.nextToken, TokenAndData(
				extraDedents == 0 ? Token.newlineSameIndent : Token.newlineDedent,
				ExtraDedents(extraDedents == 0 ? 0 : extraDedents - 1)));
			break;
		case Token.quoteBar:
		case Token.quoteDouble:
		case Token.quoteDouble3:
			cellSet(lexer.nextToken, plainToken(Token.quotedText));
			break;
		default:
			readNextToken(lexer);
			break;
	}
	return res;
}

TokenAndData takeNextTokenMayContinueOntoNextLine(ref Lexer lexer) {
	mayContinueOntoNextLine(lexer.ptr, lexer.indentKind, minIndent: lexer.curIndent);
	return takeNextToken(lexer);
}

private void readNextToken(ref Lexer lexer) {
	lexer.prevTokenEnd = lexer.ptr;
	skipSpacesAndComments(lexer.ptr, (CString _) {}, (CString start, ParseDiag x) =>
		addDiagFromPointer(lexer, start, x));
	lexer.nextTokenPos = posAtPtr(lexer);
	cellSet(lexer.nextToken, lexToken(
		lexer.ptr, lexer.indentKind, cellGet(lexer.nextToken).token, lexer.curIndent, (CString start, ParseDiag x) =>
			addDiagFromPointer(lexer, start, x)));
}

TokenAndData getPeekTokenAndData(return scope ref const Lexer lexer) =>
	cellGet(lexer.nextToken);
Token getPeekToken(in Lexer lexer) =>
	getPeekTokenAndData(lexer).token;

private Range range(in Lexer lexer, CString begin) =>
	range(lexer, posOf(lexer, begin));

StringPart takeClosingBraceThenStringPart(ref Lexer lexer, QuoteKind quoteKind) {
	if (getPeekToken(lexer) != Token.braceRight) {
		Pos start = posAtPtr(lexer);
		addDiagAtChar(lexer, ParseDiag(ParseDiag.Expected(ParseDiag.Expected.Kind.closeInterpolated)));
		skipUntilNewlineNoDiag(lexer);
		return StringPart(Range(start, posAtPtr(lexer)), "", StringPart.After.done);
	} else
		return takeStringPartCommon(lexer, quoteKind);
}

StringPart takeInitialStringPart(ref Lexer lexer, QuoteKind quoteKind) {
	assert(getPeekToken(lexer) == Token.quotedText);
	return takeStringPartCommon(lexer, quoteKind);
}

private StringPart takeStringPartCommon(ref Lexer lexer, QuoteKind quoteKind) {
	StringPart res = takeStringPart(lexer.alloc, lexer.ptr, posAtPtr(lexer), quoteKind, (CString start, ParseDiag x) =>
		addDiagFromPointer(lexer, start, x));
	// Don't skip newline token (which is a parse error)
	if (!isNewlineToken(getPeekToken(lexer)))
		takeNextToken(lexer);
	return res;
}

@trusted bool lookaheadEquals(in Lexer lexer) =>
	getPeekToken(lexer) == Token.equal || .lookaheadEquals(lexer.ptr);

bool lookaheadNewVisibility(in Lexer lexer) =>
	isVisibility(getPeekTokenAndData(lexer)) && lookaheadKeyword(lexer.ptr, "new");

private bool isVisibility(in TokenAndData a) {
	if (a.token == Token.operator) {
		switch (a.asSymbol.value) {
			case symbol!"-".value:
			case symbol!"~".value:
			case symbol!"+".value:
				return true;
			default:
				return false;
		}
	} else
		return false;
}

bool lookaheadNameColon(in Lexer lexer) =>
	getPeekToken(lexer) == Token.name && lookaheadColon(lexer.ptr);

@trusted bool lookaheadQuestionEquals(in Lexer lexer) =>
	getPeekToken(lexer) == Token.questionEqual || .lookaheadQuestionEquals(lexer.ptr);

bool lookaheadLambda(in Lexer lexer) =>
	getPeekToken(lexer) == Token.parenLeft && .lookaheadLambdaAfterParenLeft(lexer.ptr);

bool lookaheadOpenParen(in Lexer lexer) =>
	*lexer.ptr == '(';

bool lookaheadOpenBracket(in Lexer lexer) =>
	*lexer.ptr == '[';

// Returns position of 'as'
Opt!Pos tryTakeNewlineThenAs(ref Lexer lexer) =>
	tryTakeNewlineThenKeyword(lexer, Token.as, "as");

Opt!Pos tryTakeNewlineThenCatch(ref Lexer lexer) =>
	tryTakeNewlineThenKeyword(lexer, Token.catch_, "catch");

// Returns position of 'else'
Opt!Pos tryTakeNewlineThenElse(ref Lexer lexer) =>
	tryTakeNewlineThenKeyword(lexer, Token.else_, "else");

private Opt!Pos tryTakeNewlineThenKeyword(scope ref Lexer lexer, Token keyword, in string keywordString) {
	if (getPeekToken(lexer) == Token.newlineSameIndent && lookaheadKeyword(lexer.ptr, keywordString)) {
		mustTakeToken(lexer, Token.newlineSameIndent);
		Pos keywordPos = curPos(lexer);
		mustTakeToken(lexer, keyword);
		return some(keywordPos);
	} else
		return none!Pos;
}

Opt!ElifOrElseKeyword tryTakeNewlineThenElifOrElse(ref Lexer lexer) {
	if (getPeekToken(lexer) == Token.newlineSameIndent) {
		Opt!(ElifOrElseKeyword.Kind) kind = lookaheadElifOrElse(lexer.ptr);
		if (has(kind)) {
			mustTakeToken(lexer, Token.newlineSameIndent);
			Pos pos = curPos(lexer);
			mustTakeToken(lexer, enumConvert!Token(force(kind)));
			return some(ElifOrElseKeyword(force(kind), pos));
		} else
			return none!ElifOrElseKeyword;
	} else
		return none!ElifOrElseKeyword;
}
