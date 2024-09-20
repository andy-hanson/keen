module frontend.parse.parseExpr;

@safe @nogc pure nothrow:

import frontend.parse.lexer :
	addDiag,
	addDiagUnexpectedCurToken,
	curPos,
	ElifOrElseKeyword,
	getPeekToken,
	getPeekTokenAndData,
	Lexer,
	lookaheadEquals,
	lookaheadLambda,
	lookaheadNameColon,
	lookaheadQuestionEquals,
	QuoteKind,
	range,
	rangeAtChar,
	rangeForCurToken,
	skipUntilNewlineNoDiag,
	StringPart,
	takeClosingBraceThenStringPart,
	takeInitialStringPart,
	takeNextToken,
	takeNextTokenMayContinueOntoNextLine,
	Token,
	TokenAndData,
	tryTakeNewlineThenAs,
	tryTakeNewlineThenCatch,
	tryTakeNewlineThenElifOrElse,
	tryTakeNewlineThenElse;
import frontend.parse.lexToken : isNewlineToken;
import frontend.parse.parseType :
	parseDestructureNoRequireParens, parseDestructureRequireParens, parseTypeForTypedExpr, tryParseTypeArgForExpr;
import frontend.parse.parseUtil :
	peekEndOfLine,
	peekToken,
	takeDedent,
	takeIndentOrFailGeneric,
	takeNameAndRange,
	takeOrAddDiagExpectedToken,
	takeOrAddDiagExpectedTokenAndMayContinueOntoNextLine,
	takeOrAddDiagExpectedTokenAndSkipRestOfLine,
	tryTakeLiteralIntegral,
	tryTakeNameAndRange,
	tryTakeToken,
	tryTakeTokenAndMayContinueOntoNextLine;
import model.ast :
	ArrowAccessAst,
	AssertOrForbidAst,
	AssertOrForbidThrownAst,
	AssignmentAst,
	AssignmentCallAst,
	BogusAst,
	CallAst,
	CallNamedAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	createIfAst,
	DestructureAst,
	DoAst,
	EmptyAst,
	ExprAst,
	ExprAstKind,
	ExternAst,
	FinallyAst,
	ForAst,
	IdentifierAst,
	IfAst,
	InterpolatedAst,
	LambdaAst,
	LetAst,
	LiteralIntegralAndRange,
	LiteralStringAst,
	LoopAst,
	LoopBreakAst,
	LoopContinueAst,
	LoopWhileOrUntilAst,
	MatchAst,
	MatchElseAst,
	NameAndRange,
	ParenthesizedAst,
	PtrAst,
	SeqAst,
	SharedAst,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	WithAst;
import model.parseDiag : ParseDiag;
import util.alloc.alloc : Alloc;
import util.col.array : emptySmallArray, isEmpty, newArray, newSmallArray, only2, SmallArray;
import util.col.arrayBuilder : add, ArrayBuilder, arrayBuilderIsEmpty, buildArray, buildSmallArray, Builder, finish;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some, some;
import util.sourceRange : Pos, Range;
import util.symbol : Symbol, symbol;
import util.util : max;

ExprAst parseFunExprBody(ref Lexer lexer) =>
	tryTakeToken(lexer, Token.newlineIndent)
		? parseStatementsAndDedent(lexer)
		: emptyAst(lexer);

private:

ExprAst bogusExpr(in Range range) =>
	ExprAst(range, ExprAstKind(BogusAst()));

enum AllowedBlock { no, yes }

immutable struct AllowedCalls {
	int minPrecedenceExclusive;
}

AllowedCalls allowAllCalls() =>
	AllowedCalls(int.min);

immutable struct ArgCtx {
	// Allow things like 'if' that continue into an indented block.
	AllowedBlock allowedBlock;
	AllowedCalls allowedCalls;
}

ArgCtx requirePrecedenceGt(ArgCtx a, int precedence) =>
	ArgCtx(
		a.allowedBlock,
		AllowedCalls(max(a.allowedCalls.minPrecedenceExclusive, precedence)));

ArgCtx requirePrecedenceGtComma(ArgCtx a) =>
	requirePrecedenceGt(a, commaPrecedence);

SmallArray!ExprAst parseArgs(ref Lexer lexer, ArgCtx ctx, ExprAst first) =>
	buildSmallArray!ExprAst(lexer.alloc, (scope ref Builder!ExprAst out_) {
		out_ ~= first;
		assert(ctx.allowedCalls.minPrecedenceExclusive >= commaPrecedence);
		if (peekTokenExpression(lexer)) {
			do {
				out_ ~= parseExprAndCalls(lexer, ctx);
			} while (tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.comma));
		}
	});

bool peekTokenExpression(ref Lexer lexer) =>
	isExpressionStartToken(getPeekTokenAndData(lexer));

bool isExpressionStartToken(in TokenAndData a) {
	final switch (a.token) {
		case Token.alias_:
		case Token.arrowAccess:
		case Token.arrowLambda:
		case Token.as:
		case Token.at:
		case Token.bare:
		case Token.builtin:
		case Token.braceLeft:
		case Token.braceRight:
		case Token.bracketRight:
		case Token.byRef:
		case Token.byVal:
		case Token.catch_:
		case Token.colon:
		case Token.colon2:
		case Token.colonEqual:
		case Token.comma:
		case Token.data:
		case Token.dot:
		case Token.dot3:
		case Token.elif:
		case Token.else_:
		case Token.enum_:
		case Token.equal:
		case Token.export_:
		case Token.EOF:
		case Token.flags:
		case Token.forceCtx:
		case Token.forceShared:
		case Token.function_:
		case Token.global:
		case Token.import_:
		case Token.mut:
		case Token.nameOrOperatorColonEquals:
		case Token.nameOrOperatorEquals:
		case Token.newlineDedent:
		case Token.newlineIndent:
		case Token.newlineSameIndent:
		case Token.nominal:
		case Token.noStd:
		case Token.packed:
		case Token.parenRight:
		case Token.pure_:
		case Token.question:
		case Token.questionBracket:
		case Token.questionDot:
		case Token.questionEqual:
		case Token.quotedText:
		case Token.record:
		case Token.region:
		case Token.reserved:
		case Token.semicolon:
		case Token.spec:
		case Token.storage:
		case Token.summon:
		case Token.test:
		case Token.thread_local:
		case Token.unexpectedCharacter:
		case Token.union_:
		case Token.unsafe:
		case Token.variant:
		case Token.variantMember:
			return false;
		case Token.assert_:
		case Token.bang:
		case Token.bracketLeft:
		case Token.break_:
		case Token.continue_:
		case Token.do_:
		case Token.extern_:
		case Token.forbid:
		case Token.guard:
		case Token.if_:
		case Token.finally_:
		case Token.for_:
		case Token.literalFloat:
		case Token.literalIntegral:
		case Token.loop:
		case Token.match:
		case Token.name:
		case Token.nameAfterBang:
		case Token.nameBang:
		case Token.parenLeft:
		case Token.quoteDouble:
		case Token.quoteDouble3:
		case Token.shared_:
		case Token.throw_:
		case Token.trusted:
		case Token.try_:
		case Token.underscore:
		case Token.unless:
		case Token.until:
		case Token.with_:
		case Token.while_:
			return true;
		case Token.operator:
			return isPrefixUnaryOperator(a.asSymbol);
	}
}
bool isPrefixUnaryOperator(Symbol a) {
	switch (a.value) {
		case symbol!"!".value:
		case symbol!"-".value:
		case symbol!"~".value:
		case symbol!"*".value:
		case symbol!"&".value:
			return true;
		default:
			return false;
	}
}

ExprAst parseAssignment(ref Lexer lexer, Pos start, ref ExprAst left, Pos assignmentPos) {
	ExprAst right = parseExprNoLet(lexer);
	return ExprAst(
		range(lexer, start),
		ExprAstKind(allocate(lexer.alloc, AssignmentAst(left, assignmentPos, right))));
}

ExprAst parseArgOrEmpty(ref Lexer lexer) =>
	peekEndOfLine(lexer)
		? emptyAst(lexer)
		: parseExprNoLet(lexer);

ExprAst parseNextLinesOrEmpty(ref Lexer lexer) =>
	tryTakeToken(lexer, Token.newlineSameIndent)
		? parseStatements(lexer)
		: emptyAst(lexer);

ExprAst emptyAst(ref Lexer lexer) =>
	ExprAst(rangeAtChar(lexer), ExprAstKind(EmptyAst()));

ExprAst parseCalls(ref Lexer lexer, Pos start, ref ExprAst lhs, ArgCtx argCtx) {
	Pos beforeCall = curPos(lexer);
	return canParseCommaExpr(argCtx) && tryTakeToken(lexer, Token.comma)
		? parseCallsAfterComma(lexer, start, lhs, beforeCall, argCtx)
		: canParseTernaryExpr(argCtx) && tryTakeToken(lexer, Token.question)
		? parseCallsAfterQuestion(lexer, start, lhs, beforeCall, argCtx)
		: parseNamedCalls(lexer, start, lhs, argCtx);
}

ExprAst parseCallsAfterQuestion(ref Lexer lexer, Pos start, ref ExprAst lhs, Pos questionPos, ArgCtx argCtx) {
	ExprAst then = parseExprAndCalls(lexer, argCtx);
	Pos colonPos = curPos(lexer);
	bool hasColon = tryTakeToken(lexer, Token.colon);
	Opt!ExprAst else_ = optIf(hasColon, () => parseExprAndCalls(lexer, argCtx));
	return ExprAst(range(lexer, start), ExprAstKind(createIfAst(
		lexer.alloc,
		hasColon ? IfAst.Kind.ternaryWithElse : IfAst.Kind.ternaryWithoutElse,
		false,
		questionPos,
		ConditionAst(allocate(lexer.alloc, lhs)),
		some(then),
		optIf(hasColon, () => colonPos),
		else_)));
}

bool canParseTernaryExpr(in ArgCtx argCtx) =>
	ternaryPrecedence > argCtx.allowedCalls.minPrecedenceExclusive;

bool canParseCommaExpr(in ArgCtx argCtx) =>
	commaPrecedence > argCtx.allowedCalls.minPrecedenceExclusive;

ExprAst parseCallsAfterComma(ref Lexer lexer, Pos start, ref ExprAst lhs, Pos commaPos, ArgCtx argCtx) {
	SmallArray!ExprAst args = parseArgs(lexer, requirePrecedenceGtComma(argCtx), lhs);
	Range range = range(lexer, start);
	return ExprAst(range, ExprAstKind(
		//TODO: range is wrong..
		CallAst(CallAst.Style.comma, commaPos, NameAndRange(range.start, symbol!"new"), args)));
}

ExprAst parseNamedCalls(ref Lexer lexer, Pos start, ref ExprAst lhs, ArgCtx argCtx) {
	Pos pos = curPos(lexer);
	Opt!NameAndPrecedence optName = tryTakeNameAndPrecedence(lexer, argCtx);
	if (!has(optName))
		return lhs;

	Token funToken = force(optName).token;
	NameAndRange funName = NameAndRange(pos + (funToken == Token.nameAfterBang ? 1 : 0), force(optName).name);
	int precedence = force(optName).precedence;
	Opt!AssignmentKind assignment = () {
		switch (funToken) {
			case Token.nameOrOperatorColonEquals:
				return some(AssignmentKind.replace);
			case Token.nameOrOperatorEquals:
				return some(AssignmentKind.inPlace);
			default:
				return none!AssignmentKind;
		}
	}();
	bool isOperator = precedence != 0;
	//TODO: don't do this for operators
	Opt!(TypeAst*) typeArg = tryParseTypeArgForExpr(lexer);
	ArgCtx innerCtx = requirePrecedenceGt(argCtx, precedence);
	SmallArray!ExprAst args = isOperator
		? newSmallArray!ExprAst(lexer.alloc, [lhs, parseExprAndCalls(lexer, innerCtx)])
		: parseArgs(lexer, innerCtx, lhs);
	ExprAstKind exprKind = () {
		if (has(assignment)) {
			final switch (force(assignment)) {
				case AssignmentKind.inPlace:
					return ExprAstKind(CallAst(CallAst.Style.infix, funName, args));
				case AssignmentKind.replace:
					return ExprAstKind(AssignmentCallAst(funName, allocate!(ExprAst[2])(lexer.alloc, only2(args))));
			}
		} else
			return ExprAstKind(CallAst(CallAst.Style.infix, funName, args, typeArg));
	}();
	ExprAst expr = ExprAst(range(lexer, start), exprKind);
	ExprAst res = funToken == Token.nameAfterBang
		? makeAugment(lexer.alloc, range(lexer, start), funName.range.start - 1, symbol!"not", expr)
		: funToken == Token.nameBang
		? makeAugment(lexer.alloc, range(lexer, start), funName.range.end, symbol!"force", expr)
		: expr;
	return parseCalls(lexer, start, res, argCtx);
}

ExprAst makeAugment(ref Alloc alloc, Range range, Pos pos, Symbol name, ExprAst inner) =>
	ExprAst(range, ExprAstKind(
		CallAst(CallAst.Style.augment, pos, NameAndRange(pos, name), newSmallArray!ExprAst(alloc, [inner]))));

immutable struct NameAndPrecedence {
	Token token;
	Symbol name;
	int precedence;
}
Opt!NameAndPrecedence tryTakeNameAndPrecedence(scope ref Lexer lexer, ArgCtx argCtx) {
	TokenAndData x = getPeekTokenAndData(lexer);
	if (x.isSymbol) {
		int precedence = symbolPrecedence(
			x.asSymbol,
			x.token == Token.nameOrOperatorEquals || x.token == Token.nameOrOperatorColonEquals);
		if (precedence > argCtx.allowedCalls.minPrecedenceExclusive) {
			if (tokenHasContinuation(x.token))
				takeNextTokenMayContinueOntoNextLine(lexer);
			else
				takeNextToken(lexer);
			return some(NameAndPrecedence(x.token, x.asSymbol, precedence));
		} else
			return none!NameAndPrecedence;
	} else
		return none!NameAndPrecedence;
}

bool tokenHasContinuation(Token a) {
	switch (a) {
		case Token.operator:
		case Token.nameOrOperatorColonEquals:
		case Token.nameOrOperatorEquals:
			return true;
		default:
			return false;
	}
}

enum AssignmentKind {
	inPlace, // foo=
	replace, // foo:=
}

// This is for the , in `1, 2`, not the comma between args
int commaPrecedence() =>
	-6;
// Precedence for '?' and ':' in 'a ? b : c'
int ternaryPrecedence() =>
	-5;

int namePrecedence() =>
	0;
int symbolPrecedence(Symbol a, bool isAssignment) {
	if (isAssignment) return -4;
	switch (a.value) {
		case symbol!"||".value:
			return -3;
		case symbol!"&&".value:
			return -2;
		case symbol!"??".value:
			return -1;
		case symbol!"..".value:
			return 1;
		case symbol!"~".value:
		case symbol!"~~".value:
			return 2;
		case symbol!"==".value:
		case symbol!"!=".value:
		case symbol!"<".value:
		case symbol!"<=".value:
		case symbol!">".value:
		case symbol!">=".value:
		case symbol!"<=>".value:
			return 3;
		case symbol!"|".value:
			return 4;
		case symbol!"^".value:
			return 5;
		case symbol!"&".value:
			return 6;
		case symbol!"<<".value:
		case symbol!">>".value:
			return 7;
		case symbol!"+".value:
		case symbol!"-".value:
			return 8;
		case symbol!"*".value:
		case symbol!"/".value:
		case symbol!"%".value:
			return 9;
		case symbol!"**".value:
			return 10;
		default:
			// All other names
			return namePrecedence;
	}
}

ExprAst tryParseDotsAndSubscripts(ref Lexer lexer, ExprAst initial) {
	Pos start = initial.range.start;
	Pos dotPos = curPos(lexer);
	Token token = getPeekToken(lexer);
	switch (token) {
		case Token.dot:
		case Token.questionDot:
			takeNextToken(lexer);
			return handleDotOrQuestionDot(lexer, initial, start, dotPos, isQuestionDot: token == Token.questionDot);
		case Token.arrowAccess:
			takeNextToken(lexer);
			NameAndRange name = takeNameAndRange(lexer);
			return tryParseDotsAndSubscripts(lexer, ExprAst(
				range(lexer, start),
				ExprAstKind(ArrowAccessAst(allocate(lexer.alloc, initial), dotPos, name))));
		case Token.bracketLeft:
		case Token.questionBracket:
			takeNextToken(lexer);
			return parseSubscript(lexer, initial, dotPos, isQuestionBracket: token == Token.questionBracket);
		case Token.colon2:
			takeNextToken(lexer);
			TypeAst type = parseTypeForTypedExpr(lexer);
			return tryParseDotsAndSubscripts(lexer, ExprAst(
				range(lexer, start),
				ExprAstKind(allocate(lexer.alloc, TypedAst(initial, dotPos, type)))));
		case Token.bang:
			takeNextToken(lexer);
			return tryParseDotsAndSubscripts(lexer, ExprAst(
				range(lexer, start),
				ExprAstKind(CallAst(
					CallAst.Style.suffixBang,
					NameAndRange(dotPos, symbol!"force"),
					newSmallArray(lexer.alloc, [initial])))));
		default:
			return initial;
	}
}
ExprAst handleDotOrQuestionDot(ref Lexer lexer, ExprAst initial, Pos start, Pos dotPos, bool isQuestionDot) {
	CallAst call(NameAndRange name, Opt!(TypeAst*) typeArg) =>
		CallAst(
			isQuestionDot ? CallAst.Style.questionDot : CallAst.Style.dot,
			dotPos, name, newSmallArray(lexer.alloc, [initial]), typeArg);

	ExprAst res = () {
		if (peekToken(lexer, Token.nameBang)) {
			Pos nameStart = curPos(lexer);
			NameAndRange name = NameAndRange(nameStart, getPeekTokenAndData(lexer).asSymbol);
			takeNextToken(lexer);
			return makeAugment(
				lexer.alloc, range(lexer, start), name.range.end, symbol!"force",
				ExprAst(range(lexer, start), ExprAstKind(call(name, none!(TypeAst*)))));
		} else {
			NameAndRange name = takeNameAndRange(lexer);
			return ExprAst(range(lexer, start), ExprAstKind(call(name, tryParseTypeArgForExpr(lexer))));
		}
	}();
	return tryParseDotsAndSubscripts(lexer, res);
}

ExprAst parseSubscript(ref Lexer lexer, ExprAst initial, Pos subscriptPos, bool isQuestionBracket) {
	ExprAst arg = () {
		if (tryTakeToken(lexer, Token.bracketRight))
			return ExprAst(
				range(lexer, subscriptPos),
				ExprAstKind(CallAst(
					CallAst.Style.emptyParens,
					NameAndRange(subscriptPos, symbol!"new"),
					emptySmallArray!ExprAst)));
		else {
			ExprAst res = parseExprNoBlock(lexer);
			takeOrAddDiagExpectedToken(lexer, Token.bracketRight, ParseDiag.Expected.Kind.closingBracket);
			return res;
		}
	}();
	return tryParseDotsAndSubscripts(lexer, ExprAst(
		range(lexer, initial.range.start),
		ExprAstKind(CallAst(
			isQuestionBracket ? CallAst.Style.questionSubscript : CallAst.Style.subscript,
			subscriptPos,
			NameAndRange(subscriptPos, symbol!"subscript"),
			newSmallArray(lexer.alloc, [initial, arg])))));
}

ExprAst parseMatch(ref Lexer lexer, Pos start) {
	ExprAst matched = parseExprNoBlock(lexer);
	SmallArray!CaseAst cases = buildSmallArray(lexer.alloc, (scope ref Builder!CaseAst out_) {
		while (true) {
			Opt!Pos asPos = tryTakeNewlineThenAs(lexer);
			if (has(asPos)) {
				CaseMemberAst member = parseCaseMember(lexer);
				ExprAst then = parseIndentedStatements(lexer);
				out_ ~= CaseAst(force(asPos), member, then);
			} else
				break;
		}
	});
	Opt!(MatchElseAst*) else_ = tryParseElse(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(MatchAst(allocate(lexer.alloc, matched), cases, else_)));
}

CaseMemberAst parseCaseMember(ref Lexer lexer) {
	Opt!NameAndRange name = tryTakeNameAndRange(lexer);
	if (has(name)) {
		Opt!DestructureAst destructure = peekEndOfLine(lexer) || peekToken(lexer, Token.colon)
			? none!DestructureAst
			: some(parseDestructureNoRequireParens(lexer));
		return CaseMemberAst(CaseMemberAst.Name(force(name), destructure));
	} else {
		Opt!LiteralIntegralAndRange number = tryTakeLiteralIntegral(lexer);
		return has(number) ? CaseMemberAst(force(number)) : parseStringLiteralForMatchCase(lexer);
	}
}

CaseMemberAst parseStringLiteralForMatchCase(ref Lexer lexer) {
	Pos start = curPos(lexer);
	if (takeOrAddDiagExpectedToken(lexer, Token.quoteDouble, ParseDiag.Expected.Kind.matchCase)) {
		StringPart part = takeInitialStringPart(lexer, QuoteKind.quoteDouble);
		final switch (part.after) {
			case StringPart.After.quote:
				break;
			case StringPart.After.lbrace:
				addDiag(lexer, range(lexer, start), ParseDiag(ParseDiag.MatchCaseInterpolated()));
				break;
		}
		return CaseMemberAst(CaseMemberAst.String(range(lexer, start), part.text));
	} else {
		skipUntilNewlineNoDiag(lexer);
		return CaseMemberAst(CaseMemberAst.Bogus(rangeForCurToken(lexer, start)));
	}
}

ExprAst parseDo(ref Lexer lexer, Pos start) {
	ExprAst body_ = parseIndentedStatements(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(DoAst(allocate(lexer.alloc, body_))));
}

ConditionAst parseCondition(ref Lexer lexer, AllowedBlock allowedBlock) {
	if (lookaheadQuestionEquals(lexer)) {
		DestructureAst lhs = parseDestructureNoRequireParens(lexer);
		Pos questionEqualPos = curPos(lexer);
		takeOrAddDiagExpectedToken(lexer, Token.questionEqual, ParseDiag.Expected.Kind.questionEqual);
		ExprAst option = parseExprNoBlock(lexer);
		return ConditionAst(allocate(lexer.alloc,
			ConditionAst.UnpackOption(lhs, questionEqualPos, allocate(lexer.alloc, option))));
	} else
		return ConditionAst(allocate(lexer.alloc, parseExprAndAllCalls(lexer, allowedBlock)));
}

ExprAst parseIf(ref Lexer lexer, Pos start, bool isElseOfParent) {
	ConditionAst condition = parseCondition(lexer, AllowedBlock.no);
	ExprAst then = parseIndentedStatements(lexer);
	Opt!ElifOrElseKeyword elifOrElse = tryTakeNewlineThenElifOrElse(lexer);

	Opt!ExprAst else_ = optIf(has(elifOrElse), () {
		final switch (force(elifOrElse).kind) {
			case ElifOrElseKeyword.Kind.elif:
				return parseIf(lexer, force(elifOrElse).pos, true);
			case ElifOrElseKeyword.Kind.else_:
				return parseIndentedStatements(lexer);
		}
	});

	IfAst.Kind kind = () {
		if (has(elifOrElse)) {
			final switch (force(elifOrElse).kind) {
				case ElifOrElseKeyword.Kind.elif:
					return IfAst.Kind.ifElif;
				case ElifOrElseKeyword.Kind.else_:
					return IfAst.Kind.ifElse;
			}
		} else
			return IfAst.Kind.ifWithoutElse;
	}();

	ExprAstKind exprKind = ExprAstKind(createIfAst(
		lexer.alloc, kind, isElseOfParent, start, condition, some(then),
		optIf(has(elifOrElse), () => force(elifOrElse).pos),
		else_));
	return ExprAst(range(lexer, start), exprKind);
}


immutable struct ConditionAndBody {
	ConditionAst condition;
	ExprAst body_;
}

ConditionAndBody parseConditionAndBody(ref Lexer lexer) {
	ConditionAst cond = parseCondition(lexer, AllowedBlock.no);
	ExprAst body_ = parseIndentedStatements(lexer);
	return ConditionAndBody(cond, body_);
}

ExprAst parseUnless(ref Lexer lexer, Pos start) {
	ConditionAndBody cb = parseConditionAndBody(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(createIfAst(
		lexer.alloc, IfAst.Kind.unless, false, start, cb.condition, some(cb.body_), none!Pos, none!ExprAst)));
}

ExprAst parseShared(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parsePrefixKeyword(lexer, start, allowedBlock, ParseDiag.NeedsBlockCtx.Kind.shared_, (ExprAst inner) =>
		ExprAstKind(allocate(lexer.alloc, SharedAst(inner))));

ExprAst parseThrow(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parsePrefixKeyword(lexer, start, allowedBlock, ParseDiag.NeedsBlockCtx.Kind.throw_, (ExprAst inner) =>
		ExprAstKind(allocate(lexer.alloc, ThrowAst(inner))));

ExprAst parseTrusted(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parsePrefixKeyword(lexer, start, allowedBlock, ParseDiag.NeedsBlockCtx.Kind.trusted, (ExprAst inner) =>
		ExprAstKind(allocate(lexer.alloc, TrustedAst(inner))));

ExprAst parsePrefixKeyword(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiag.NeedsBlockCtx.Kind needsBlockKind,
	in ExprAstKind delegate(ExprAst) @safe @nogc pure nothrow cbMakeExpr,
) {
	ExprAst inner = parseExprInlineOrBlock(lexer, start, allowedBlock, needsBlockKind);
	return ExprAst(range(lexer, start), cbMakeExpr(inner));
}

ExprAst parseAssertOrForbid(ref Lexer lexer, Pos start, bool isForbid) {
	ConditionAst condition = parseCondition(lexer, AllowedBlock.no);
	Pos colonPos = curPos(lexer);
	Opt!(AssertOrForbidThrownAst*) thrown = optIf(tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colon), () =>
		allocate(lexer.alloc, AssertOrForbidThrownAst(colonPos, parseExprNoBlock(lexer))));
	ExprAst* after = allocate(lexer.alloc, parseNextLinesOrEmpty(lexer));
	return ExprAst(range(lexer, start), ExprAstKind(AssertOrForbidAst(isForbid, condition, thrown, after)));
}

ExprAst parseFinally(ref Lexer lexer, Pos start) {
	ExprAst right = parseExprNoLet(lexer);
	ExprAst below = parseNextLinesOrEmpty(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc, FinallyAst(right, below))));
}

ExprAst parseGuard(ref Lexer lexer, Pos start) {
	ConditionAst condition = parseCondition(lexer, AllowedBlock.no);
	Pos colonPos = curPos(lexer);
	Opt!ExprAst firstBranch = optIf(tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colon), () =>
		parseExprNoBlock(lexer));
	ExprAst secondBranch = parseNextLinesOrEmpty(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(createIfAst(
		lexer.alloc,
		has(firstBranch) ? IfAst.Kind.guardWithColon : IfAst.Kind.guardWithoutColon,
		false,
		start,
		condition,
		firstBranch,
		optIf(has(firstBranch), () => colonPos),
		some(secondBranch))));
}

ExprAst parseFor(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parseForOrWith(
		lexer, start, allowedBlock, ParseDiag.NeedsBlockCtx.Kind.for_,
		(DestructureAst param, Pos colon, ExprAst col, ExprAst body_, ExprAst else_) =>
			ExprAstKind(allocate(lexer.alloc, ForAst(param, colon, col, body_, else_))));

ExprAst parseWith(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parseForOrWith(
		lexer, start, allowedBlock, ParseDiag.NeedsBlockCtx.Kind.with_,
		(DestructureAst param, Pos colon, ExprAst col, ExprAst body_, ExprAst else_) =>
			ExprAstKind(allocate(lexer.alloc, WithAst(param, colon, col, body_, else_))));

ExprAst parseForOrWith(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiag.NeedsBlockCtx.Kind blockKind,
	in ExprAstKind delegate(
		DestructureAst, Pos colon, ExprAst rhs, ExprAst body_, ExprAst else_,
	) @safe @nogc pure nothrow cbMakeExprKind,
) {
	DestructureAndEndTokenPos paramAndColon = parseForThenOrWithParameter(
		lexer, Token.colon, ParseDiag.Expected.Kind.colon);
	DestructureAst param = paramAndColon.destructure;
	Pos colon = paramAndColon.endTokenPos;
	ExprAst rhs = parseExprNoBlock(lexer);
	bool semi = tryTakeToken(lexer, Token.semicolon);
	if (semi) {
		ExprAst body_ = parseExprNoBlock(lexer);
		return ExprAst(range(lexer, start), cbMakeExprKind(param, colon, rhs, body_, emptyAst(lexer)));
	} else
		final switch (allowedBlock) {
			case AllowedBlock.no:
				return exprBlockNotAllowed(lexer, start, blockKind);
			case AllowedBlock.yes:
				return takeIndentOrFail_Expr(lexer, () {
					ExprAst body_ = parseStatementsAndDedent(lexer);
					ExprAst else_ = parseElseOrEmpty(lexer);
					return ExprAst(range(lexer, start), cbMakeExprKind(param, colon, rhs, body_, else_));
				});
		}
}

Opt!(MatchElseAst*) tryParseElse(ref Lexer lexer) {
	Opt!Pos pos = tryTakeNewlineThenElse(lexer);
	return optIf(has(pos), () => allocate(lexer.alloc, MatchElseAst(force(pos), parseIndentedStatements(lexer))));
}

ExprAst parseElseOrEmpty(ref Lexer lexer) =>
	has(tryTakeNewlineThenElse(lexer)) ? parseIndentedStatements(lexer) : emptyAst(lexer);

ExprAst parseLoop(ref Lexer lexer, Pos start) {
	ExprAst body_ = parseIndentedStatements(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc, LoopAst(body_))));
}

ExprAst parseLoopBreak(ref Lexer lexer, Pos start) {
	ExprAst value = parseArgOrEmpty(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc, LoopBreakAst(value))));
}

ExprAst parseLoopWhileOrUntil(ref Lexer lexer, Pos start, bool isUntil) {
	ConditionAndBody cb = parseConditionAndBody(lexer);
	ExprAst after = parseNextLinesOrEmpty(lexer);
	return ExprAst(
		range(lexer, start),
		ExprAstKind(allocate(lexer.alloc, LoopWhileOrUntilAst(isUntil, cb.condition, cb.body_, after))));
}

ExprAst takeIndentOrFail_Expr(ref Lexer lexer, in ExprAst delegate() @safe @nogc pure nothrow cbIndent) =>
	takeIndentOrFailGeneric(lexer, cbIndent, (in Range range) => bogusExpr(range));

ExprAst parseLambdaWithParenthesizedParameters(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) {
	DestructureAst parameter = parseDestructureRequireParens(lexer);
	Pos arrowPos = curPos(lexer);
	takeOrAddDiagExpectedToken(lexer, Token.arrowLambda, ParseDiag.Expected.Kind.lambdaArrow);
	return parseLambdaAfterArrow(lexer, start, allowedBlock, parameter, arrowPos);
}

struct DestructureAndEndTokenPos {
	DestructureAst destructure;
	Pos endTokenPos;
}
DestructureAndEndTokenPos parseForThenOrWithParameter(
	ref Lexer lexer,
	Token endToken,
	ParseDiag.Expected.Kind expectedEndToken,
) {
	Pos pos = curPos(lexer);
	if (tryTakeToken(lexer, endToken))
		return DestructureAndEndTokenPos(DestructureAst(DestructureAst.Void(range(lexer, pos))), pos);
	else {
		DestructureAst res = parseDestructureNoRequireParens(lexer);
		Pos endTokenPos = curPos(lexer);
		takeOrAddDiagExpectedTokenAndMayContinueOntoNextLine(lexer, endToken, expectedEndToken);
		return DestructureAndEndTokenPos(res, endTokenPos);
	}
}

ExprAst parseLambdaAfterNameAndArrow(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	Symbol paramName,
	Pos arrowPos,
) =>
	parseLambdaAfterArrow(
		lexer, start, allowedBlock,
		DestructureAst(DestructureAst.Single(NameAndRange(start, paramName), none!Pos, none!(TypeAst*))),
		arrowPos);

ExprAst parseLambdaAfterArrow(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	DestructureAst parameter,
	Pos arrowPos,
) {
	ExprAst body_ = parseExprInlineOrBlock(lexer, start, allowedBlock, ParseDiag.NeedsBlockCtx.Kind.lambda);
	return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc, LambdaAst(parameter, arrowPos, body_))));
}

ExprAst parseExprInlineOrBlock(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiag.NeedsBlockCtx.Kind needsBlockKind,
) {
	bool inLine = peekTokenExpression(lexer);
	return inLine
		? parseExprAndAllCalls(lexer, allowedBlock)
		: ifAllowBlock(lexer, start, allowedBlock, needsBlockKind, () => parseIndentedStatements(lexer));
}

ExprAst skipRestOfLineAndReturnBogusNoDiag(ref Lexer lexer, Pos start) {
	skipUntilNewlineNoDiag(lexer);
	return bogusExpr(rangeForCurToken(lexer, start));
}

ExprAst skipRestOfLineAndReturnBogus(ref Lexer lexer, Pos start, ParseDiag diag) {
	addDiag(lexer, range(lexer, start), diag);
	return skipRestOfLineAndReturnBogusNoDiag(lexer, start);
}

ExprAst exprBlockNotAllowed(ref Lexer lexer, Pos start, ParseDiag.NeedsBlockCtx.Kind kind) =>
	skipRestOfLineAndReturnBogus(lexer, start, ParseDiag(ParseDiag.NeedsBlockCtx(kind)));

ExprAst ifAllowBlock(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiag.NeedsBlockCtx.Kind kind,
	in ExprAst delegate() @safe @nogc pure nothrow cbAllowBlock,
) {
	final switch (allowedBlock) {
		case AllowedBlock.no:
			return exprBlockNotAllowed(lexer, start, kind);
		case AllowedBlock.yes:
			return cbAllowBlock();
	}
}

ExprAst parseExprBeforeCall(ref Lexer lexer, AllowedBlock allowedBlock) {
	Pos start = curPos(lexer);
	if (lookaheadLambda(lexer))
		return parseLambdaWithParenthesizedParameters(lexer, start, allowedBlock);

	ExprAst ifAllowBlock(
		ParseDiag.NeedsBlockCtx.Kind kind,
		in ExprAst delegate() @safe @nogc pure nothrow cbAllowBlock,
	) =>
		.ifAllowBlock(lexer, start, allowedBlock, kind, cbAllowBlock);

	// Don't skip newline tokens
	if (isNewlineToken(getPeekToken(lexer)))
		return badToken(lexer, start, getPeekTokenAndData(lexer));

	TokenAndData token = takeNextToken(lexer);
	switch (token.token) {
		case Token.parenLeft:
			if (tryTakeToken(lexer, Token.parenRight)) {
				//TODO: range is wrong..
				ExprAst expr = ExprAst(range(lexer, start), ExprAstKind(
					CallAst(CallAst.Style.emptyParens, NameAndRange(start, symbol!"new"), emptySmallArray!ExprAst)));
				return tryParseDotsAndSubscripts(lexer, expr);
			} else {
				ExprAst inner = parseExprNoBlock(lexer);
				takeOrAddDiagExpectedToken(lexer, Token.parenRight, ParseDiag.Expected.Kind.closingParen);
				ExprAst expr = ExprAst(
					range(lexer, start),
					ExprAstKind(allocate(lexer.alloc, ParenthesizedAst(inner))));
				return tryParseDotsAndSubscripts(lexer, expr);
			}
		case Token.quoteDouble:
		case Token.quoteDouble3:
			QuoteKind quoteKind = token.token == Token.quoteDouble ? QuoteKind.quoteDouble : QuoteKind.quoteDouble3;
			StringPart part = takeInitialStringPart(lexer, quoteKind);
			ExprAst quoted = () {
				final switch (part.after) {
					case StringPart.After.quote:
						return ExprAst(range(lexer, start), ExprAstKind(LiteralStringAst(part.text)));
					case StringPart.After.lbrace:
						return takeInterpolated(lexer, start, part, quoteKind);
				}
			}();
			return tryParseDotsAndSubscripts(lexer, quoted);
		case Token.bang:
			ExprAst inner = parseExprBeforeCall(lexer, AllowedBlock.no);
			return ExprAst(
				range(lexer, start),
				ExprAstKind(CallAst(
					CallAst.Style.prefixBang,
					NameAndRange(start, symbol!"not"),
					newSmallArray(lexer.alloc, [inner]))));
		case Token.break_:
			return parseLoopBreak(lexer, start);
		case Token.continue_:
			return ExprAst(range(lexer, start), ExprAstKind(LoopContinueAst()));
		case Token.do_:
			return ifAllowBlock(ParseDiag.NeedsBlockCtx.Kind.do_, () => parseDo(lexer, start));
		case Token.extern_:
			return parseExtern(lexer, start);
		case Token.if_:
			return ifAllowBlock(ParseDiag.NeedsBlockCtx.Kind.if_, () => parseIf(lexer, start, false));
		case Token.for_:
			return parseFor(lexer, start, allowedBlock);
		case Token.match:
			return ifAllowBlock(ParseDiag.NeedsBlockCtx.Kind.match, () => parseMatch(lexer, start));
		case Token.name:
			Symbol name = token.asSymbol;
			Pos arrowPos = curPos(lexer);
			return tryTakeToken(lexer, Token.arrowLambda)
				? parseLambdaAfterNameAndArrow(lexer, start, allowedBlock, name, arrowPos)
				: handleName(lexer, start, NameAndRange(start, name));
		case Token.nameAfterBang:
			ExprAst inner = ExprAst(range(lexer, start), ExprAstKind(IdentifierAst(token.asSymbol)));
			return makeAugment(
				lexer.alloc, range(lexer, start), start, symbol!"not", tryParseDotsAndSubscripts(lexer, inner));
		case Token.nameBang:
			Range nameBangRange = range(lexer, start);
			ExprAst inner = ExprAst(nameBangRange, ExprAstKind(IdentifierAst(token.asSymbol)));
			return tryParseDotsAndSubscripts(
				lexer,
				makeAugment(lexer.alloc, nameBangRange, nameBangRange.end - 1, symbol!"force", inner));
		case Token.operator:
			Symbol operator = token.asSymbol;
			if (isPrefixUnaryOperator(operator)) {
				if (operator == symbol!"&") {
					ExprAst inner = parseExprBeforeCall(lexer, AllowedBlock.no);
					return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc, PtrAst(inner))));
				} else
					return handlePrefixUnaryOperator(lexer, allowedBlock, start, operator);
			} else
				return badToken(lexer, start, token);
		case Token.literalFloat:
			return tryParseDotsAndSubscripts(lexer, ExprAst(range(lexer, start), ExprAstKind(token.asLiteralFloat)));
		case Token.literalIntegral:
			return tryParseDotsAndSubscripts(lexer, ExprAst(range(lexer, start), ExprAstKind(token.asLiteralIntegral)));
		case Token.loop:
			return ifAllowBlock(ParseDiag.NeedsBlockCtx.Kind.loop, () => parseLoop(lexer, start));
		case Token.shared_:
			return parseShared(lexer, start, allowedBlock);
		case Token.throw_:
			return parseThrow(lexer, start, allowedBlock);
		case Token.trusted:
			return parseTrusted(lexer, start, allowedBlock);
		case Token.try_:
			return ifAllowBlock(ParseDiag.NeedsBlockCtx.Kind.try_, () => parseTryBlock(lexer, start));
		case Token.underscore:
			Pos arrowPos = curPos(lexer);
			return tryTakeToken(lexer, Token.arrowLambda)
				? parseLambdaAfterNameAndArrow(lexer, start, allowedBlock, symbol!"_", arrowPos)
				: badToken(lexer, start, token);
		case Token.unless:
			return ifAllowBlock(ParseDiag.NeedsBlockCtx.Kind.unless, () => parseUnless(lexer, start));
		case Token.with_:
			return parseWith(lexer, start, allowedBlock);
		default:
			return badToken(lexer, start, token);
	}
}

ExprAst badToken(ref Lexer lexer, Pos start, TokenAndData token) {
	addDiagUnexpectedCurToken(lexer, start, token);
	return skipRestOfLineAndReturnBogusNoDiag(lexer, start);
}

ExprAst handlePrefixUnaryOperator(ref Lexer lexer, AllowedBlock allowedBlock, Pos start, Symbol operator) {
	ExprAst arg = parseExprBeforeCall(lexer, allowedBlock);
	return ExprAst(range(lexer, start), ExprAstKind(
		CallAst(CallAst.Style.prefixOperator, NameAndRange(start, operator), newSmallArray(lexer.alloc, [arg]))));
}

ExprAst parseExtern(ref Lexer lexer, Pos start) {
	NameAndRange[] names = tryTakeToken(lexer, Token.parenLeft)
		? buildArray!NameAndRange(lexer.alloc, (scope ref Builder!NameAndRange res) {
			do {
				res ~= takeNameAndRange(lexer);
			} while (tryTakeToken(lexer, Token.comma));
			takeOrAddDiagExpectedToken(lexer, Token.parenRight, ParseDiag.Expected.Kind.closingParen);
		})
		: newArray(lexer.alloc, [takeNameAndRange(lexer)]);
	return ExprAst(range(lexer, start), ExprAstKind(ExternAst(names)));
}

ExprAst handleName(ref Lexer lexer, Pos start, NameAndRange name) {
	Opt!(TypeAst*) typeArg = tryParseTypeArgForExpr(lexer);
	return has(typeArg)
		? ExprAst(range(lexer, start), ExprAstKind(
			CallAst(CallAst.Style.single, name, emptySmallArray!ExprAst, typeArg)))
		: tryParseDotsAndSubscripts(lexer, ExprAst(range(lexer, start), ExprAstKind(IdentifierAst(name.name))));
}

ExprAst takeInterpolated(ref Lexer lexer, Pos start, StringPart firstPart, QuoteKind quoteKind) {
	ExprAst[] parts = buildArray!ExprAst(lexer.alloc, (scope ref Builder!ExprAst res) {
		if (!isEmpty(firstPart.text))
			res ~= ExprAst(firstPart.range, ExprAstKind(LiteralStringAst(firstPart.text)));
		while (true) {
			res ~= () {
				if (peekToken(lexer, Token.braceRight)) {
					Pos pos = curPos(lexer);
					Range range = Range(pos - 1, pos + 1);
					addDiag(lexer, range, ParseDiag(ParseDiag.MissingExpression()));
					return bogusExpr(range);
				} else
					return parseExprNoBlock(lexer);
			}();
			StringPart part = takeClosingBraceThenStringPart(lexer, quoteKind);
			if (!isEmpty(part.text))
				res ~= ExprAst(part.range, ExprAstKind(LiteralStringAst(part.text)));
			final switch (part.after) {
				case StringPart.After.quote:
					return;
				case StringPart.After.lbrace:
					continue;
			}
		}
	});
	return ExprAst(range(lexer, start), ExprAstKind(InterpolatedAst(parts)));
}

ExprAst parseExprNoBlock(ref Lexer lexer) =>
	parseExprAndAllCalls(lexer, AllowedBlock.no);

ExprAst parseExprAndAllCalls(ref Lexer lexer, AllowedBlock allowedBlock) =>
	parseExprAndCalls(lexer, ArgCtx(allowedBlock, allowAllCalls()));

ExprAst parseExprAndCalls(ref Lexer lexer, ArgCtx argCtx) {
	Pos start = curPos(lexer);
	ExprAst left = parseExprBeforeCall(lexer, argCtx.allowedBlock);
	return parseCalls(lexer, start, left, argCtx);
}

ExprAst parseExprNoLet(ref Lexer lexer) =>
	parseExprAndAllCalls(lexer, AllowedBlock.yes);

public ExprAst parseSingleStatementLine(ref Lexer lexer) {
	Pos start = curPos(lexer);
	Token token = getPeekToken(lexer);
	switch (token) {
		case Token.assert_:
		case Token.forbid:
			takeNextToken(lexer);
			return parseAssertOrForbid(lexer, start, isForbid: token == Token.forbid);
		case Token.finally_:
			takeNextToken(lexer);
			return parseFinally(lexer, start);
		case Token.guard:
			takeNextToken(lexer);
			return parseGuard(lexer, start);
		case Token.until:
		case Token.while_:
			takeNextToken(lexer);
			return parseLoopWhileOrUntil(lexer, start, isUntil: token == Token.until);
		default:
			if (lookaheadEquals(lexer))
				return parseEquals(lexer);
			else if (lookaheadNameColon(lexer))
				return parseNamedCall(lexer, start);
			else {
				ExprAst expr = parseExprBeforeCall(lexer, AllowedBlock.yes);
				Pos assignmentPos = curPos(lexer);
				return tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colonEqual)
					? parseAssignment(lexer, start, expr, assignmentPos)
					: parseCalls(lexer, start, expr, ArgCtx(AllowedBlock.yes, allowAllCalls()));
			}
	}
}

ExprAst parseNamedCall(ref Lexer lexer, Pos start) {
	ArrayBuilder!NameAndRange names;
	ArrayBuilder!ExprAst values;
	do {
		NameAndRange name = takeNameAndRange(lexer);
		if (takeOrAddDiagExpectedTokenAndSkipRestOfLine(lexer, Token.colon, ParseDiag.Expected.Kind.namedArgument)) {
			add(lexer.alloc, names, name);
			add(lexer.alloc, values, parseExprNoLet(lexer));
		}
	} while (tryTakeToken(lexer, Token.newlineSameIndent));
	return arrayBuilderIsEmpty(names)
		? ExprAst(range(lexer, start), ExprAstKind(BogusAst()))
		: ExprAst(range(lexer, start), ExprAstKind(
			CallNamedAst(finish(lexer.alloc, names), finish(lexer.alloc, values))));
}

ExprAst parseEquals(ref Lexer lexer) {
	Pos start = curPos(lexer);
	if (tryTakeToken(lexer, Token.try_))
		return parseTryLet(lexer, start);
	else {
		DestructureAst left = parseDestructureNoRequireParens(lexer);
		takeOrAddDiagExpectedTokenAndMayContinueOntoNextLine(
			lexer, Token.equal, ParseDiag.Expected.Kind.equals);
		ExprAst init = parseExprNoLet(lexer);
		ExprAst then = parseNextLinesOrEmpty(lexer);
		return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc, LetAst(left, init, then))));
	}
}

ExprAst parseTryLet(ref Lexer lexer, Pos start) {
	DestructureAst destructure = parseDestructureNoRequireParens(lexer);
	takeOrAddDiagExpectedTokenAndMayContinueOntoNextLine(lexer, Token.equal, ParseDiag.Expected.Kind.equals);
	ExprAst value = parseExprNoBlock(lexer);
	Pos catchPos = curPos(lexer);
	takeOrAddDiagExpectedToken(lexer, Token.catch_, ParseDiag.Expected.Kind.catch_);
	CaseMemberAst catchMember = parseCaseMember(lexer);
	ExprAst catch_ = tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colon)
		? parseExprNoLet(lexer)
		: emptyAst(lexer);
	ExprAst then = parseNextLinesOrEmpty(lexer);
	return ExprAst(range(lexer, start), ExprAstKind(allocate(lexer.alloc,
		TryLetAst(destructure, value, catchPos, catchMember, catch_, then))));
}

ExprAst parseStatements(ref Lexer lexer) {
	Pos start = curPos(lexer);
	return parseStatementsRecur(lexer, start, parseSingleStatementLine(lexer));
}

ExprAst parseStatementsRecur(ref Lexer lexer, Pos start, ExprAst res) {
	if (tryTakeToken(lexer, Token.newlineSameIndent)) {
		ExprAst nextLine = parseSingleStatementLine(lexer);
		return parseStatementsRecur(lexer, start, ExprAst(
			range(lexer, start),
			ExprAstKind(allocate(lexer.alloc, SeqAst(res, nextLine)))));
	} else
		return res;
}

ExprAst parseIndentedStatements(ref Lexer lexer) =>
	takeIndentOrFail_Expr(lexer, () => parseStatementsAndDedent(lexer));

ExprAst parseStatementsAndDedent(ref Lexer lexer) {
	ExprAst res = parseStatements(lexer);
	takeDedent(lexer);
	return res;
}

ExprAst parseTryBlock(ref Lexer lexer, Pos start) {
	ExprAst* body_ = allocate(lexer.alloc, parseIndentedStatements(lexer));
	SmallArray!CaseAst catches = buildSmallArray(lexer.alloc, (scope ref Builder!CaseAst out_) {
		while (true) {
			Opt!Pos catchPos = tryTakeNewlineThenCatch(lexer);
			if (has(catchPos)) {
				CaseMemberAst member = parseCaseMember(lexer);
				ExprAst then = parseIndentedStatements(lexer);
				out_ ~= CaseAst(force(catchPos), member, then);
			} else
				break;
		}
	});
	return ExprAst(range(lexer, start), ExprAstKind(TryAst(body_, catches)));
}
