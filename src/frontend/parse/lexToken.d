module frontend.parse.lexToken;

@safe @nogc pure nothrow:

import frontend.parse.lexWhitespace :
	AddDiag, DocCommentAndIndentDelta, IndentKind, skipBlankLinesAndGetIndentDelta, takeRestOfLine;
import model.ast : HighPrecisionFloat, LiteralFloatAst, LiteralIntegral;
import util.conv : safeToLong;
import util.integralValues : IntegralValue;
import util.opt : force, has, none, Opt, optOrDefault, some;
import util.sourceRange : Pos;
import util.string :
	CString,
	decodeHexDigit,
	isDecimalDigit,
	MutCString,
	SmallString,
	startsWith,
	startsWithThenWhitespace,
	stringOfRange,
	takeChar,
	tryGetAfterStartsWith,
	tryTakeChar,
	tryTakeChars;
import util.symbol : appendEquals, Symbol, symbol, symbolOfString;
import util.unicode : isUtf8InitialOrContinueCode, mustTakeOneUnicodeChar;

immutable struct DocCommentAndExtraDedents {
	SmallString docComment;
	uint extraDedents;
}

immutable struct TokenAndData {
	@safe @nogc pure nothrow:

	Token token;
	private:
	union {
		Symbol symbol = void; // For Token.name or Token.operator
		// For Token.newline or Token.EOF. WARN: The string is temporary.
		DocCommentAndExtraDedents docComment = void;
		LiteralFloatAst literalFloat = void; // for Token.literalFloat
		LiteralIntegral literalIntegral = void; // for Token.literalIntegral
		dchar unexpectedCharacter;
		string region;
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
	this(Token t, DocCommentAndExtraDedents d) {
		assert(isNewlineToken(t));
		token = t;
		docComment = d;
	}
	this(Token t, LiteralFloatAst l) {
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
	this(Token t, string s) {
		assert(t == Token.region);
		token = t;
		region = s;
	}

	bool isSymbol() scope =>
		isSymbolToken(token);

	Symbol asSymbol() scope {
		assert(isSymbol);
		return symbol;
	}
	@trusted DocCommentAndExtraDedents asDocComment() {
		assert(isNewlineToken(token));
		return docComment;
	}
	@trusted LiteralFloatAst asLiteralFloat() {
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
	@trusted string asRegion() {
		assert(token == Token.region);
		return region;
	}
}

TokenAndData plainToken(Token a) =>
	TokenAndData(a, true);

enum Token {
	alias_, // 'alias'
	arrowAccess, // '->'
	arrowLambda, // '=>'
	as, // 'as'
	assert_, // 'assert'
	at, // '@'
	bang, // '!'
	bare, // 'bare'
	break_, // 'break'
	builtin, // 'builtin'
	braceLeft, // '{'
	braceRight, // '}'
	bracketLeft, // '['
	bracketRight, // ']'
	byRef,
	byVal,
	catch_, // 'catch'
	colon, // ':'
	colon2, // '::'
	colonEqual, // ':='
	comma, // ','
	continue_, // 'continue'
	data, // 'data'
	do_, // 'do'
	dot, // '.'. // '..' is Operator.range
	dot3, // '...'
	elif, // 'elif'
	else_, // 'else'
	enum_, // 'enum'
	equal, // '='
	extern_, // 'extern'
	EOF, // end of file
	export_, // 'export'
	finally_, // 'finally'
	flags, // 'flags'
	for_, // 'for'
	forceShared, // 'force-shared'
	forbid, // 'forbid'
	forceCtx, // 'force-ctx'
	function_, // 'function'
	global, // 'global'
	guard, // 'guard'
	if_, // 'if'
	import_, // 'import'
	literalFloat, // Use asLiteralFloat
	literalIntegral, // Use asLiteralIntegral
	loop, // 'loop'
	match, // 'match'
	mut, // 'mut'
	name, // Any non-keyword, non-operator name; use TokenAndData.asSymbol with this
	nameAfterBang, // '!name'
	// Tokens for a name with '!', ':', ':=', or '=' on the end.
	nameBang,
	nameOrOperatorColonEquals, // 'TokenAndData.asSymbol' does NOT include the ':='
	nameOrOperatorEquals, // 'TokenAndData.asSymbol' DOES include the '='
	// End of line followed by another line at lesser indentation.
	// There will be one of these tokens for each reduced indent level, followed by a 'newline' token.
	newlineDedent,
	// End of line followed by another line at 1 greater indent level.
	// Unlike 'newlineDedent', this is not followed by a 'newlineSameIndent' token.
	newlineIndent,
	// end of line followed by another line at the same indent level.
	newlineSameIndent,
	nominal, // 'nominal'
	noStd, // 'no-std'
	operator, // Any operator; use TokenAndData.asSymbol with this
	packed, // 'packed'
	parenLeft, // '('
	parenRight, // ')'
	pure_, // 'pure'
	question, // '?'
	questionDot, // '?.'
	questionBracket, // '?['
	questionEqual, // '?='
	quoteDouble, // '"'
	quoteDouble3, // '"""'
	quotedText, // Fake token to be the peek after the '"'
	record, // 'record'
	region, // 'region'
	reserved, // any reserved word
	semicolon, // ';'
	shared_, // 'shared'
	spec, // 'spec'
	storage, // 'storage'
	summon, // 'summon'
	summonVariantMember, // 'summon-variant-member'
	test, // 'test'
	thread_local, // 'thread-local'
	throw_, // 'throw'
	trusted, // 'trusted'
	try_, // 'try'
	unexpectedCharacter, // Any unexpected character
	underscore, // '_'
	union_, // 'union'
	unless, // 'unless'
	unsafe, // 'unsafe'
	until, // 'until'
	variant, // 'variant'
	variantMember, // 'variant-member'
	while_, // 'while'
	with_, // 'with'
}

bool isNewlineToken(Token a) {
	switch (a) {
		case Token.EOF:
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

/*
Advances 'ptr' to lex a single token.
Possibly writes to 'data' depending on the kind of token returned.
*/
TokenAndData lexToken(ref MutCString ptr, IndentKind indentKind, ref uint curIndent, in AddDiag addDiag) {
	if (*ptr == '\0')
		return newlineToken(ptr, Token.EOF, indentKind, curIndent, addDiag);

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
		case '{':
			return plainToken(Token.braceLeft);
		case '}':
			return plainToken(Token.braceRight);
		case ']':
			return plainToken(Token.bracketRight);
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
			return operatorToken(ptr, tryTakeChar(ptr, '|') ? symbol!"||" : symbol!"|");
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
				return TokenAndData(Token.region, takeRestOfLine(ptr));
			default:
				return plainToken(token);
		}
	} else
		return TokenAndData(Token.unexpectedCharacter, mustTakeOneUnicodeChar(ptr));
}

bool lookaheadEquals(MutCString ptr) {
	while (true) {
		switch (*ptr) {
			case ' ':
				ptr++;
				if (startsWithThenWhitespace(ptr, "="))
					return true;
				else
					break;
			// characters that appear in types
			default:
				if (!isTypeChar(*ptr))
					return false;
				else {
					ptr++;
					break;
				}
		}
	}
}

bool lookaheadColon(MutCString ptr) {
	while (tryTakeChar(ptr, ' ')) {}
	return tryTakeChar(ptr, ':') && *ptr != ':' && *ptr != '=';
}

bool lookaheadQuestionEquals(MutCString ptr) {
	while (true) {
		switch (*ptr) {
			case ' ':
				ptr++;
				if (startsWithThenWhitespace(ptr, "?="))
					return true;
				else
					break;
			default:
				// Destructure chars are same as type chars
				if (!isTypeChar(*ptr))
					return false;
				else {
					ptr++;
					break;
				}
		}
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

bool lookaheadKeyword(CString ptr, in string expected) {
	Opt!CString end = tryGetAfterStartsWith(ptr, expected);
	return has(end) && !isProbablyIdentifierCharForLookahead(*force(end));
}

immutable struct ElifOrElseKeyword {
	enum Kind { elif, else_ }
	Kind kind;
	Pos pos;
}
Opt!(ElifOrElseKeyword.Kind) lookaheadElifOrElse(CString ptr) =>
	lookaheadKeyword(ptr, "elif")
		? some(ElifOrElseKeyword.Kind.elif)
		: lookaheadKeyword(ptr, "else")
		? some(ElifOrElseKeyword.Kind.else_)
		: none!(ElifOrElseKeyword.Kind);

private:

TokenAndData newlineToken(
	ref MutCString ptr,
	Token newlineOrEOF,
	IndentKind indentKind,
	ref uint curIndent,
	in AddDiag addDiag,
) {
	DocCommentAndIndentDelta x = skipBlankLinesAndGetIndentDelta(ptr, indentKind, curIndent, addDiag);
	Token token = x.indentDelta == 0 ? newlineOrEOF : x.indentDelta < 0 ? Token.newlineDedent : Token.newlineIndent;
	uint extraDedents = token == Token.newlineDedent ? -x.indentDelta - 1 : 0;
	return TokenAndData(token, DocCommentAndExtraDedents(x.docComment, extraDedents));
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
			return Token.reserved;
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
		case symbol!"summon-variant-member".value:
			return Token.summonVariantMember;
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
		case symbol!"variant-member".value:
			return Token.variantMember;
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

enum Sign {
	plus,
	minus,
}
int intOfSign(Sign a) {
	final switch (a) {
		case Sign.plus:
			return 1;
		case Sign.minus:
			return -1;
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
		return takeFloat(ptr, optOrDefault!Sign(sign, () => Sign.plus), n, base);
	} else if (has(sign))
		return TokenAndData(Token.literalIntegral, () {
			final switch (force(sign)) {
				case Sign.plus:
					return LiteralIntegral(
						isSigned: true, overflow: n.value > long.max, value: IntegralValue(n.value));
				case Sign.minus:
					return LiteralIntegral(
						isSigned: true, overflow: n.value > (cast(ulong) long.max) + 1, value: IntegralValue(-n.value));
			}
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


TokenAndData takeFloat(ref MutCString ptr, Sign sign, NatAndOverflow natPart, ulong base) {
	NatAndOverflow res = takeNatContinue(ptr, base, NatAndOverflow(natPart.value, natPart.overflow, countDigits: 0));
	bool overflow = res.overflow || (res.value > long.max);
	long value = intOfSign(sign) * res.value;
	long exp = -safeToLong(res.countDigits);
	assert(-100 <= exp); // kill -------------------------------------------------------------------------------------------------
	assert(exp <= 100); // kill -------------------------------------------------------------------------------------------------
	if (tryTakeChar(ptr, 'e')) {
		bool neg = tryTakeChar(ptr, '-');
		NatAndOverflow x = takeNat(ptr, 10);
		overflow = overflow || x.overflow;
		exp += (neg ? -1 : 1) * x.value; // TODO: this can overflow on negate -------------------------------------------------------------
	}
	return TokenAndData(Token.literalFloat, LiteralFloatAst(HighPrecisionFloat(value, exp), overflow));
}

double pow(double acc, double base, ulong power) =>
	power == 0 ? acc : pow(acc * base, base, power - 1);

//TODO: overflow bug possible here
ulong getDivisor(ulong acc, ulong a, ulong base) =>
	acc < a ? getDivisor(acc * base, a, base) : acc;

public immutable struct NatAndOverflow { ulong value; bool overflow; uint countDigits; }
LiteralIntegral toLiteralIntegral(NatAndOverflow a) =>
	LiteralIntegral(isSigned: false, overflow: a.overflow, value: IntegralValue(a.value));

public NatAndOverflow takeNat(scope ref MutCString ptr, ulong base) =>
	takeNatContinue(ptr, base, NatAndOverflow(0, false, 0));

NatAndOverflow takeNatContinue(scope ref MutCString ptr, ulong base, NatAndOverflow starting) {
	ulong value = starting.value;
	bool overflow = starting.overflow;
	uint countDigits = starting.countDigits;
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
	return NatAndOverflow(value, overflow, countDigits);
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
