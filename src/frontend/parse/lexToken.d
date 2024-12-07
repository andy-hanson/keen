module frontend.parse.lexToken;

@safe @nogc pure nothrow:

import frontend.parse.lexWhitespace :
	AddDiag, CStringRange, IndentKind, skipBlankLinesAndGetIndentDelta, skipUntilNewline;
import frontend.parse.token : Token;
import model.ast : HighPrecisionFloat, LiteralFloat, LiteralIntegral;
import model.integralValues : IntegralValue;
import util.conv : mulWithOverflow, safeToLong, Sign, toLongWithOverflow;
import util.opt : force, has, none, Opt, optIf, optOrDefault, some;
import util.string :
	CString,
	decodeHexDigit,
	isDecimalDigit,
	isWhitespace,
	MutCString,
	startsWith,
	startsWithThenWhitespace,
	stringOfRange,
	takeChar,
	tryTakeChar,
	tryTakeChars;
import util.symbol : appendEquals, Symbol, symbol, symbolOfString;
import util.unicode : isUtf8InitialOrContinueCode, mustTakeOneUnicodeChar;

immutable struct ExtraDedents {
	uint extraDedents;
}

immutable struct TokenAndData {
	@safe @nogc pure nothrow:

	Token token;
	private:
	union {
		Symbol symbol = void; // For Token.name or Token.operator
		// For Token.newline or Token.EOF
		ExtraDedents extraDedents = void;
		LiteralFloat literalFloat = void; // for Token.literalFloat
		LiteralIntegral literalIntegral = void; // for Token.literalIntegral
		dchar unexpectedCharacter = void;
		CStringRange region = void;
	}

	public:
	this(Token t, bool) {
		assert(!isSymbolToken(t) &&
			!isNewlineToken(t) &&
			t != Token.literalFloat &&
			t != Token.literalIntegral &&
			t != Token.region);
		token = t;
	}
	this(Token t, Symbol s) {
		assert(isSymbolToken(t));
		token = t;
		symbol = s;
	}
	this(Token t, ExtraDedents d) {
		assert(isNewlineToken(t));
		token = t;
		extraDedents = d;
	}
	this(Token t, LiteralFloat l) {
		assert(t == Token.literalFloat);
		token = t;
		literalFloat = l;
	}
	this(Token t, LiteralIntegral l) {
		assert(t == Token.literalIntegral);
		token = t;
		literalIntegral = l;
	}
	this(Token t, dchar c) {
		assert(t == Token.unexpectedCharacter);
		token = t;
		unexpectedCharacter = c;
	}
	this(Token t, CStringRange r) {
		assert(t == Token.region);
		token = t;
		region = r;
	}

	bool isSymbol() scope =>
		isSymbolToken(token);

	Symbol asSymbol() scope {
		assert(isSymbol);
		return symbol;
	}
	@trusted uint asExtraDedents() {
		assert(isNewlineToken(token));
		return extraDedents.extraDedents;
	}
	@trusted LiteralFloat asLiteralFloat() {
		assert(token == Token.literalFloat);
		return literalFloat;
	}
	@trusted LiteralIntegral asLiteralIntegral() {
		assert(token == Token.literalIntegral);
		return literalIntegral;
	}
	dchar asUnexpectedCharacter() {
		assert(token == Token.unexpectedCharacter);
		return unexpectedCharacter;
	}
	@trusted CStringRange asRegion() {
		assert(token == Token.region);
		return region;
	}
}

TokenAndData plainToken(Token a) =>
	TokenAndData(a, true);

bool isNewlineToken(Token a) {
	switch (a) {
		case Token.endOfFile:
		case Token.newlineDedent:
		case Token.newlineIndent:
		case Token.newlineSameIndent:
			return true;
		default:
			return false;
	}
}
bool isSymbolToken(Token a) {
	switch (a) {
		case Token.name:
		case Token.nameAfterBang:
		case Token.nameBang:
		case Token.nameOrOperatorEquals:
		case Token.nameOrOperatorColonEquals:
		case Token.operator:
			return true;
		default:
			return false;
	}
}

TokenAndData lexInitialToken(ref MutCString ptr, IndentKind indentKind, ref uint curIndent, in AddDiag addDiag) =>
	newlineToken(ptr, Token.newlineSameIndent, indentKind, curIndent, addDiag);

// Advances 'ptr' to lex a single token.
TokenAndData lexToken(
	ref MutCString ptr,
	IndentKind indentKind,
	Token prevToken,
	ref uint curIndent,
	in AddDiag addDiag,
) {
	if (*ptr == '\0')
		return newlineToken(ptr, Token.endOfFile, indentKind, curIndent, addDiag);

	CString start = ptr;
	char c = takeChar(ptr);
	switch (c) {
		case ' ':
		case '\t':
		case '\r':
		case '#':
			// handled by skipSpacesAndComments
			assert(false);
		case '\n':
			return newlineToken(ptr, Token.newlineSameIndent, indentKind, curIndent, addDiag);
		case '~':
			return operatorToken(ptr, tryTakeChar(ptr, '~') ? symbol!"~~" : symbol!"~");
		case '@':
			return plainToken(Token.at);
		case '!':
			if (!startsWith(ptr, "==") && tryTakeChar(ptr, '='))
				return operatorToken(ptr, symbol!"!=");
			else {
				CString beforeName = ptr;
				return tryTakeIdentifier(ptr)
					? TokenAndData(Token.nameAfterBang, symbolOfString(stringOfRange(beforeName, ptr)))
					: plainToken(Token.bang);
			}
		case '%':
			return operatorToken(ptr, symbol!"%");
		case '^':
			return operatorToken(ptr, symbol!"^");
		case '&':
			return operatorToken(ptr, tryTakeChar(ptr, '&') ? symbol!"&&" : symbol!"&");
		case '*':
			return operatorToken(ptr, tryTakeChar(ptr, '*') ? symbol!"**" : symbol!"*");
		case '(':
			return plainToken(Token.parenLeft);
		case ')':
			return plainToken(Token.parenRight);
		case '[':
			return plainToken(Token.bracketLeft);
		case ']':
			return plainToken(Token.bracketRight);
		case '{':
			return plainToken(Token.braceLeft);
		case '}':
			return plainToken(Token.braceRight);
		case '-':
			return isDecimalDigit(*ptr)
				? takeNumberAfterSign(ptr, some(Sign.minus))
				: tryTakeChar(ptr, '>')
				? plainToken(Token.arrowAccess)
				: operatorToken(ptr, symbol!"-");
		case '=':
			return tryTakeChar(ptr, '>')
				? plainToken(Token.arrowLambda)
				: tryTakeChar(ptr, '=')
				? operatorToken(ptr, symbol!"==")
				: plainToken(Token.equal);
		case '+':
			return isDecimalDigit(*ptr)
				? takeNumberAfterSign(ptr, some(Sign.plus))
				: operatorToken(ptr, symbol!"+");
		case '|':
			return isNewlineToken(prevToken) && isWhitespace(*ptr)
				? plainToken(Token.quoteBar)
				: operatorToken(ptr, tryTakeChar(ptr, '|') ? symbol!"||" : symbol!"|");
		case ':':
			return tryTakeChar(ptr, '=')
				? plainToken(Token.colonEqual)
				: tryTakeChar(ptr, ':')
				? plainToken(Token.colon2)
				: plainToken(Token.colon);
		case ';':
			return plainToken(Token.semicolon);
		case '"':
			return tryTakeChars(ptr, "\"\"")
				? plainToken(Token.quoteDouble3)
				: plainToken(Token.quoteDouble);
		case ',':
			return plainToken(Token.comma);
		case '<':
			return operatorToken(ptr, tryTakeChar(ptr, '=')
				? tryTakeChar(ptr, '>') ? symbol!"<=>" : symbol!"<="
				: tryTakeChar(ptr, '<')
				? symbol!"<<"
				: symbol!"<");
		case '>':
			return operatorToken(ptr, tryTakeChar(ptr, '=')
				? symbol!">="
				: tryTakeChar(ptr, '>')
				? symbol!">>"
				: symbol!">");
		case '.':
			return tryTakeChar(ptr, '.')
				? tryTakeChar(ptr, '.') ? plainToken(Token.dot3) : operatorToken(ptr, symbol!"..")
				: plainToken(Token.dot);
		case '/':
			return operatorToken(ptr, symbol!"/");
		case '?':
			switch (*ptr) {
				case '=':
					ptr++;
					return plainToken(Token.questionEqual);
				case '.':
					ptr++;
					return plainToken(Token.questionDot);
				case '[':
					ptr++;
					return plainToken(Token.questionBracket);
				case '?':
					ptr++;
					return operatorToken(ptr, symbol!"??");
				default:
					return plainToken(Token.question);
			}
		case '0': .. case '9':
			ptr = start;
			return takeNumberAfterSign(ptr, none!Sign);
		default:
			ptr = start;
			return lexIdentifierLike(ptr);
	}
}

private TokenAndData lexIdentifierLike(ref MutCString ptr) {
	CString start = ptr;
	if (tryTakeIdentifier(ptr)) {
		Symbol symbol = symbolOfString(stringOfRange(start, ptr));
		Token token = tokenForSymbol(symbol);
		switch (token) {
			case Token.name:
				return nameLikeToken(ptr, symbol, Token.name);
			case Token.region:
				skipUntilNewline(ptr);
				return TokenAndData(Token.region, CStringRange(start, ptr));
			default:
				return plainToken(token);
		}
	} else
		return TokenAndData(Token.unexpectedCharacter, mustTakeOneUnicodeChar(ptr));
}

bool lookaheadEquals(MutCString ptr) {
	while (true) {
		if (tryTakeChar(ptr, ' ')) {
			if (startsWithThenWhitespace(ptr, "="))
				return true;
			else
				continue;
		} else if (trySkipTypeChar(ptr)) {
			continue;
		} else
			return false;
	}
}

bool lookaheadColon(MutCString ptr) {
	while (tryTakeChar(ptr, ' ')) {}
	return tryTakeChar(ptr, ':') && *ptr != ':' && *ptr != '=';
}

bool lookaheadQuestionEquals(MutCString ptr) {
	while (true) {
		if (tryTakeChar(ptr, ' ')) {
			if (startsWithThenWhitespace(ptr, "?="))
				return true;
			else
				continue;
		} else if (trySkipTypeChar(ptr))
			continue;
		else
			return false;
	}
}

bool lookaheadLambdaAfterParenLeft(MutCString ptr) {
	size_t openParens = 1;
	while (true) {
		switch (*ptr) {
			case '(':
				openParens++;
				break;
			case ')':
				openParens--;
				//TODO: allow more or less whitespace
				if (openParens == 0) {
					ptr++;
					return startsWith(ptr, " =>");
				} else
					break;
			default:
				if (!isTypeChar(*ptr))
					return false;
		}
		ptr++;
	}
}

bool lookaheadKeyword(CString start, in string expected) {
	MutCString ptr = start;
	return tryTakeChars(ptr, expected) && !isProbablyIdentifierCharForLookahead(*ptr);
}

enum ElifOrElse { elif, else_ }
Opt!ElifOrElse lookaheadElifOrElse(CString ptr) =>
	lookaheadKeyword(ptr, "elif")
		? some(ElifOrElse.elif)
		: lookaheadKeyword(ptr, "else")
		? some(ElifOrElse.else_)
		: none!ElifOrElse;

private:

TokenAndData newlineToken(
	ref MutCString ptr,
	Token newlineOrEOF,
	IndentKind indentKind,
	ref uint curIndent,
	in AddDiag addDiag,
) {
	int delta = skipBlankLinesAndGetIndentDelta(ptr, indentKind, curIndent, addDiag);
	Token token = delta == 0 ? newlineOrEOF : delta < 0 ? Token.newlineDedent : Token.newlineIndent;
	return TokenAndData(token, ExtraDedents(token == Token.newlineDedent ? -delta - 1 : 0));
}

TokenAndData operatorToken(scope ref MutCString ptr, Symbol a) =>
	nameLikeToken(ptr, a, Token.operator);

TokenAndData nameLikeToken(scope ref MutCString ptr, Symbol a, Token regularToken) =>
	!startsWith(ptr, "==") && tryTakeChar(ptr, '=')
		? TokenAndData(Token.nameOrOperatorEquals, appendEquals(a))
		: TokenAndData(
			regularToken == Token.name && tryTakeChar(ptr, '!')
				? Token.nameBang
				: tryTakeChars(ptr, ":=")
				? Token.nameOrOperatorColonEquals
				: regularToken,
			a);

Token tokenForSymbol(Symbol a) {
	switch (a.value) {
		case symbol!"abstract".value:
			return Token.reserved;
		case symbol!"alias".value:
			return Token.alias_;
		case symbol!"as".value:
			return Token.as;
		case symbol!"assert".value:
			return Token.assert_;
		case symbol!"bare".value:
			return Token.bare;
		case symbol!"break".value:
			return Token.break_;
		case symbol!"builtin".value:
			return Token.builtin;
		case symbol!"by-ref".value:
			return Token.byRef;
		case symbol!"by-val".value:
			return Token.byVal;
		case symbol!"case".value:
			return Token.case_;
		case symbol!"catch".value:
			return Token.catch_;
		case symbol!"class".value:
			return Token.reserved;
		case symbol!"continue".value:
			return Token.continue_;
		case symbol!"data".value:
			return Token.data;
		case symbol!"do".value:
			return Token.do_;
		case symbol!"elif".value:
			return Token.elif;
		case symbol!"else".value:
			return Token.else_;
		case symbol!"enum".value:
			return Token.enum_;
		case symbol!"export".value:
			return Token.export_;
		case symbol!"extern".value:
			return Token.extern_;
		case symbol!"finally".value:
			return Token.finally_;
		case symbol!"flags".value:
			return Token.flags;
		case symbol!"for".value:
			return Token.for_;
		case symbol!"force-shared".value:
			return Token.forceShared;
		case symbol!"forbid".value:
			return Token.forbid;
		case symbol!"force-ctx".value:
			return Token.forceCtx;
		case symbol!"function".value:
			return Token.function_;
		case symbol!"global".value:
			return Token.global;
		case symbol!"guard".value:
			return Token.guard;
		case symbol!"if".value:
			return Token.if_;
		case symbol!"import".value:
			return Token.import_;
		case symbol!"interface".value:
			return Token.interface_;
		case symbol!"loop".value:
			return Token.loop;
		case symbol!"match".value:
			return Token.match;
		case symbol!"mut".value:
			return Token.mut;
		case symbol!"nominal".value:
			return Token.nominal;
		case symbol!"no-std".value:
			return Token.noStd;
		case symbol!"packed".value:
			return Token.packed;
		case symbol!"pure".value:
			return Token.pure_;
		case symbol!"record".value:
			return Token.record;
		case symbol!"region".value:
			return Token.region;
		case symbol!"shared".value:
			return Token.shared_;
		case symbol!"spec".value:
			return Token.spec;
		case symbol!"storage".value:
			return Token.storage;
		case symbol!"summon".value:
			return Token.summon;
		case symbol!"test".value:
			return Token.test;
		case symbol!"thread-local".value:
			return Token.thread_local;
		case symbol!"throw".value:
			return Token.throw_;
		case symbol!"trusted".value:
			return Token.trusted;
		case symbol!"try".value:
			return Token.try_;
		case symbol!"unless".value:
			return Token.unless;
		case symbol!"union".value:
			return Token.union_;
		case symbol!"unsafe".value:
			return Token.unsafe;
		case symbol!"until".value:
			return Token.until;
		case symbol!"variant".value:
			return Token.variant;
		case symbol!"while".value:
			return Token.while_;
		case symbol!"with".value:
			return Token.with_;
		case symbol!"_".value:
			return Token.underscore;
		default:
			return Token.name;
	}
}

TokenAndData takeNumberAfterSign(ref MutCString ptr, Opt!Sign sign) {
	ulong base = tryTakeChars(ptr, "0x")
		? 16
		: tryTakeChars(ptr, "0o")
		? 8
		: tryTakeChars(ptr, "0b")
		? 2
		: 10;
	NatAndOverflow n = takeNat(ptr, base);
	if (peekDecimalPoint(ptr)) {
		ptr++;
		return TokenAndData(Token.literalFloat, has(n.value)
			? takeFloat(ptr, optOrDefault!Sign(sign, () => Sign.plus), force(n.value), base)
			: LiteralFloat(none!HighPrecisionFloat));
	} else if (has(sign))
		return TokenAndData(Token.literalIntegral, () {
			Opt!IntegralValue value = () {
				final switch (force(sign)) {
					case Sign.plus:
						return optIf(has(n.value) && force(n.value) <= (cast(ulong) long.max), () =>
							IntegralValue(force(n.value)));
					case Sign.minus:
						return optIf(has(n.value) && force(n.value) <= (cast(ulong) long.max) + 1, () =>
							IntegralValue(-long(force(n.value))));
				}
			}();
			return LiteralIntegral(isSigned: true, value: value);
		}());
	else
		return TokenAndData(Token.literalIntegral, toLiteralIntegral(n));
}

bool peekDecimalPoint(MutCString ptr) {
	if (*ptr == '.') {
		ptr++;
		return isDecimalDigit(*ptr);
	} else
		return false;
}

LiteralFloat takeFloat(ref MutCString ptr, Sign sign, ulong natPart, ulong base) {
	NatAndOverflow beforeE = takeNatContinue(ptr, base, natPart);
	if (!has(beforeE.value))
		return LiteralFloat(none!HighPrecisionFloat);
	bool overflow = false;
	long value = mulWithOverflow(sign, toLongWithOverflow(force(beforeE.value), overflow), overflow);
	long exp = -safeToLong(beforeE.countDigits);
	if (tryTakeChar(ptr, 'e')) {
		Sign powerSign = tryTakeChar(ptr, '-') ? Sign.minus : Sign.plus;
		NatAndOverflow power = takeNat(ptr, 10);
		overflow = overflow || !has(power.value);
		exp += mulWithOverflow(
			powerSign,
			toLongWithOverflow(optOrDefault!ulong(power.value, () => 0), overflow),
			overflow);
	}
	return LiteralFloat(optIf(!overflow, () => HighPrecisionFloat(value, exp)));
}

public immutable struct NatAndOverflow {
	// empty on overflow
	Opt!ulong value;
	uint countDigits;
}
LiteralIntegral toLiteralIntegral(NatAndOverflow a) =>
	LiteralIntegral(isSigned: false, value: optIf(has(a.value), () => IntegralValue(force(a.value))));

public NatAndOverflow takeNat(scope ref MutCString ptr, ulong base) =>
	takeNatContinue(ptr, base, 0);

NatAndOverflow takeNatContinue(scope ref MutCString ptr, ulong base, ulong starting) {
	ulong value = starting;
	bool overflow = false;
	uint countDigits = 0;
	while (true) {
		Opt!ubyte digit = decodeHexDigit(*ptr);
		if (has(digit) && force(digit) < base) {
			countDigits++;
			ptr++;
			ulong newValue = value * base + force(digit);
			tryTakeChar(ptr, '_');
			overflow = overflow || newValue / base != value;
			value = newValue;
		} else
			break;
	}
	return NatAndOverflow(optIf(!overflow, () => value), countDigits);
}

public bool tryTakeIdentifier(ref MutCString ptr) {
	if (tryTakeInitialIdentifierChar(ptr)) {
		while (true) {
			CString beforeHyphen = ptr;
			while (*ptr == '-') ptr++;
			if (!tryTakeOneIdentifierChar(ptr)) {
				ptr = beforeHyphen;
				break;
			}
		}
		return true;
	} else
		return false;
}
bool tryTakeInitialIdentifierChar(ref MutCString ptr) =>
	!isDecimalDigit(*ptr) && *ptr != '-' && tryTakeOneIdentifierChar(ptr);

bool tryTakeOneIdentifierChar(ref MutCString ptr) {
	if (isSingleByteIdentifierChar(*ptr)) {
		ptr++;
		return true;
	} else if (isUtf8InitialOrContinueCode(*ptr)) {
		MutCString before = ptr;
		dchar x = mustTakeOneUnicodeChar(ptr);
		if (isAllowedUnicodeIdentifierChar(x))
			return true;
		else {
			ptr = before;
			return false;
		}
	} else
		return false;
}

bool isSingleByteIdentifierChar(char a) =>
	('a' <= a && a <= 'z') || ('A' <= a && a <= 'Z') || a == '-' || a == '_' || isDecimalDigit(a);

bool isProbablyIdentifierCharForLookahead(char a) =>
	isSingleByteIdentifierChar(a) || isUtf8InitialOrContinueCode(a);

bool isAllowedUnicodeIdentifierChar(dchar a) =>
	// Latin extended
	(0xc0 <= a && a <= 0xff && a != '×' && a != '÷') ||
	// Greek and Coptic
	(0x370 <= a && a <= 0x3ff) ||
	// Cyrillic
	(0x400 <= a && a <= 0x4ff) ||
	// Hebrew
	(0x591 <= a && a <= 0x5f4) ||
	// Arabic
	(0x600 <= a && a <= 0x6ff) ||
	// Devanagari
	(0x904 <= a && a <= 0x97f && !(0x964 <= a && a <= 0x971)) ||
	// Bengali
	(0x985 <= a && a <= 0x9e3) ||
	// Gurmukhi
	(0xa01 <= a && a <= 0xa5e) ||
	// Gujarati
	(0xa81 <= a && a <= 0xaff) ||
	// Tamil
	(0xb82 <= a && a <= 0xbfa) ||
	// Telugu
	(0xc00 <= a && a <= 0xc7f) ||
	// Tibetan
	(0xf00 <= a && a <= 0xfda) ||
	// Latin extended additional
	(0x1e00 <= a && a <= 0x1eff) ||
	// Hiragana
	(0x3041 <= a && a <= 0x309f) ||
	// Katakana
	(0x30a0 <= a && a <= 0x30ff) ||
	// CJK Unified Ideographs
	(0x4e00 <= a && a <= 0x9fff) ||
	// Hangul
	(0xac00 <= a && a <= 0xd7a3);

bool trySkipTypeChar(ref MutCString ptr) {
	if (isTypeChar(*ptr)) {
		ptr++;
		return true;
	} else
		return false;
}

bool isTypeChar(char c) {
	switch (c) {
		case ' ':
		case ',':
		case '?':
		case '^':
		case '*':
		case '[':
		case ']':
		case '(':
		case ')':
			return true;
		default:
			return isProbablyIdentifierCharForLookahead(c);
	}
}
