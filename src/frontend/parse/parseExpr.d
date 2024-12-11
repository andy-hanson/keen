module frontend.parse.parseExpr;

@safe @nogc pure nothrow:

import frontend.parse.lexer :
	addDiag,
	addDiagUnexpectedCurToken,
	curPos,
	ElifOrElse,
	ElifOrElseKeyword,
	getPeekToken,
	getPeekTokenAndData,
	Lexer,
	lookaheadEquals,
	lookaheadLambda,
	lookaheadNameColon,
	lookaheadQuestionEquals,
	range,
	rangeAtChar,
	rangeForCurToken,
	skipUntilNewlineNoDiag,
	takeInitialStringPart,
	takeNextToken,
	takeNextTokenMayContinueOntoNextLine,
	Token,
	TokenAndData,
	tryTakeNewlineThenAs,
	tryTakeNewlineThenCatch,
	tryTakeNewlineThenElifOrElse,
	tryTakeNewlineThenElse;
import frontend.parse.lexString : QuoteKind, StringPart, StringPartAfter;
import frontend.parse.lexToken : isNewlineToken;
import frontend.parse.parseString : parseString;
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
	tryTakeNameAndRangeOrDiag,
	tryTakeToken,
	tryTakeTokenAndMayContinueOntoNextLine;
import model.ast :
	AsBogusAst,
	AsNameAst,
	AsStringAst,
	ArrowAccessAst,
	AssertOrForbidAst,
	AssertOrForbidThrownAst,
	AssignmentAst,
	AssignmentCallAst,
	BogusAst,
	CallAst,
	CallAstStyle,
	CallNamedAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	createIfAst,
	DestructureAst,
	DoAst,
	EmptyAst,
	ExprAst,
	ExternAst,
	FinallyAst,
	ForAst,
	IfAstKind,
	LambdaAst,
	LetAst,
	LiteralFloatAndRange,
	LiteralIntegralAndRange,
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
	SingleDestructureAst,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	UnpackOptionAst,
	VoidDestructureAst,
	WithAst;
import model.parseDiag : ParseDiag, ParseDiagExpected, ParseDiagMatchCaseInterpolated, ParseDiagNeedsBlockCtx;
import model.sourceRange : Pos, Range;
import util.alloc.alloc : Alloc;
import util.col.array : emptySmallArray, newArray, newSmallArray, only2, SmallArray;
import util.col.arrayBuilder : add, ArrayBuilder, arrayBuilderIsEmpty, buildArray, buildSmallArray, Builder, finish;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, some, some;
import util.symbol : Symbol, symbol;
import util.util : max;

ExprAst parseFunExprBody(ref Lexer lexer) =>
	tryTakeToken(lexer, Token.newlineIndent)
		? parseStatementsAndDedent(lexer)
		: emptyAst(lexer);

private:

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
		case Token.case_:
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
		case Token.endOfFile:
		case Token.flags:
		case Token.forceCtx:
		case Token.forceShared:
		case Token.function_:
		case Token.global:
		case Token.import_:
		case Token.interface_:
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
		case Token.quoteBar:
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

ExprAst parseAssignment(ref Lexer lexer, ref ExprAst left, Pos assignmentPos) {
	ExprAst right = parseExprNoLet(lexer);
	return ExprAst(allocate(lexer.alloc, AssignmentAst(left, assignmentPos, right)));
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
	ExprAst(EmptyAst(rangeAtChar(lexer)));

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
	return ExprAst(createIfAst(
		lexer.alloc,
		start,
		hasColon ? IfAstKind.ternaryWithElse : IfAstKind.ternaryWithoutElse,
		false,
		questionPos,
		ConditionAst(allocate(lexer.alloc, lhs)),
		some(then),
		optIf(hasColon, () => colonPos),
		else_));
}

bool canParseTernaryExpr(in ArgCtx argCtx) =>
	ternaryPrecedence > argCtx.allowedCalls.minPrecedenceExclusive;

bool canParseCommaExpr(in ArgCtx argCtx) =>
	commaPrecedence > argCtx.allowedCalls.minPrecedenceExclusive;

ExprAst parseCallsAfterComma(ref Lexer lexer, Pos start, ref ExprAst lhs, Pos commaPos, ArgCtx argCtx) {
	SmallArray!ExprAst args = parseArgs(lexer, requirePrecedenceGt(argCtx, commaPrecedence), lhs);
	Range range = range(lexer, start);
	return ExprAst(CallAst(range, CallAstStyle.comma, commaPos, NameAndRange(range.start, symbol!"new"), args));
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
	ExprAst expr = () {
		if (has(assignment)) {
			final switch (force(assignment)) {
				case AssignmentKind.inPlace:
					return ExprAst(CallAst(range(lexer, start), CallAstStyle.infix, funName, args));
				case AssignmentKind.replace:
					return ExprAst(AssignmentCallAst(funName, allocate!(ExprAst[2])(lexer.alloc, only2(args))));
			}
		} else
			return ExprAst(CallAst(range(lexer, start), CallAstStyle.infix, funName, args, typeArg));
	}();
	ExprAst res = funToken == Token.nameAfterBang
		? makeAugment(lexer.alloc, range(lexer, start), funName.range.start - 1, symbol!"not", expr)
		: funToken == Token.nameBang
		? makeAugment(lexer.alloc, range(lexer, start), funName.range.end, symbol!"force", expr)
		: expr;
	return parseCalls(lexer, start, res, argCtx);
}

ExprAst makeAugment(ref Alloc alloc, Range range, Pos pos, Symbol name, ExprAst inner) =>
	ExprAst(CallAst(range, CallAstStyle.augment, pos, NameAndRange(pos, name), newSmallArray!ExprAst(alloc, [inner])));

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
				ArrowAccessAst(allocate(lexer.alloc, initial), dotPos, name)));
		case Token.bracketLeft:
		case Token.questionBracket:
			takeNextToken(lexer);
			return parseSubscript(lexer, initial, dotPos, isQuestionBracket: token == Token.questionBracket);
		case Token.colon2:
			takeNextToken(lexer);
			TypeAst type = parseTypeForTypedExpr(lexer);
			return tryParseDotsAndSubscripts(lexer, ExprAst(allocate(lexer.alloc, TypedAst(initial, dotPos, type))));
		case Token.bang:
			takeNextToken(lexer);
			return tryParseDotsAndSubscripts(lexer, ExprAst(CallAst(
				range(lexer, start),
				CallAstStyle.suffixBang,
				NameAndRange(dotPos, symbol!"force"),
				newSmallArray(lexer.alloc, [initial]))));
		default:
			return initial;
	}
}
ExprAst handleDotOrQuestionDot(ref Lexer lexer, ExprAst initial, Pos start, Pos dotPos, bool isQuestionDot) {
	CallAst call(NameAndRange name, Opt!(TypeAst*) typeArg) =>
		CallAst(
			range(lexer, start),
			isQuestionDot ? CallAstStyle.questionDot : CallAstStyle.dot,
			dotPos, name, newSmallArray(lexer.alloc, [initial]), typeArg);

	ExprAst res = () {
		if (peekToken(lexer, Token.nameBang)) {
			Pos nameStart = curPos(lexer);
			NameAndRange name = NameAndRange(nameStart, getPeekTokenAndData(lexer).asSymbol);
			takeNextToken(lexer);
			return makeAugment(
				lexer.alloc, range(lexer, start), name.range.end, symbol!"force",
				ExprAst(call(name, none!(TypeAst*))));
		} else {
			Opt!NameAndRange name = tryTakeNameAndRangeOrDiag(lexer);
			return has(name)
				? ExprAst(call(force(name), tryParseTypeArgForExpr(lexer)))
				: initial;
		}
	}();
	return tryParseDotsAndSubscripts(lexer, res);
}

ExprAst parseSubscript(ref Lexer lexer, ExprAst initial, Pos subscriptPos, bool isQuestionBracket) {
	ExprAst arg = () {
		if (tryTakeToken(lexer, Token.bracketRight))
			return ExprAst(CallAst(
				range(lexer, subscriptPos),
				CallAstStyle.emptyParens,
				NameAndRange(subscriptPos, symbol!"new"),
				emptySmallArray!ExprAst));
		else {
			ExprAst res = parseExprNoBlock(lexer);
			takeOrAddDiagExpectedToken(lexer, Token.bracketRight, ParseDiagExpected.closingBracket);
			return res;
		}
	}();
	return tryParseDotsAndSubscripts(lexer, ExprAst(CallAst(
		range(lexer, initial.range.start),
		isQuestionBracket ? CallAstStyle.questionSubscript : CallAstStyle.subscript,
		subscriptPos,
		NameAndRange(subscriptPos, symbol!"subscript"),
		newSmallArray(lexer.alloc, [initial, arg]))));
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
	return ExprAst(MatchAst(start, allocate(lexer.alloc, matched), cases, else_));
}

CaseMemberAst parseCaseMember(ref Lexer lexer) {
	Opt!NameAndRange name = tryTakeNameAndRange(lexer);
	if (has(name)) {
		Opt!DestructureAst destructure = peekEndOfLine(lexer) || peekToken(lexer, Token.colon)
			? none!DestructureAst
			: some(parseDestructureNoRequireParens(lexer));
		return CaseMemberAst(AsNameAst(force(name), destructure));
	} else {
		Opt!LiteralIntegralAndRange number = tryTakeLiteralIntegral(lexer);
		return has(number) ? CaseMemberAst(force(number)) : parseStringLiteralForMatchCase(lexer);
	}
}

CaseMemberAst parseStringLiteralForMatchCase(ref Lexer lexer) {
	Pos start = curPos(lexer);
	if (takeOrAddDiagExpectedToken(lexer, Token.quoteDouble, ParseDiagExpected.matchCase)) {
		StringPart part = takeInitialStringPart(lexer, QuoteKind.quoteDouble);
		final switch (part.after) {
			case StringPartAfter.done:
				break;
			case StringPartAfter.lbrace:
				addDiag(lexer, range(lexer, start), ParseDiag(ParseDiagMatchCaseInterpolated()));
				break;
		}
		return CaseMemberAst(AsStringAst(range(lexer, start), part.text));
	} else {
		skipUntilNewlineNoDiag(lexer);
		return CaseMemberAst(AsBogusAst(rangeForCurToken(lexer, start)));
	}
}

ExprAst parseDo(ref Lexer lexer, Pos start) {
	ExprAst body_ = parseIndentedStatements(lexer);
	return ExprAst(DoAst(start, allocate(lexer.alloc, body_)));
}

ConditionAst parseCondition(ref Lexer lexer, AllowedBlock allowedBlock) {
	if (lookaheadQuestionEquals(lexer)) {
		DestructureAst lhs = parseDestructureNoRequireParens(lexer);
		Pos questionEqualPos = curPos(lexer);
		takeOrAddDiagExpectedToken(lexer, Token.questionEqual, ParseDiagExpected.questionEqual);
		ExprAst option = parseExprNoBlock(lexer);
		return ConditionAst(allocate(lexer.alloc,
			UnpackOptionAst(lhs, questionEqualPos, allocate(lexer.alloc, option))));
	} else
		return ConditionAst(allocate(lexer.alloc, parseExprAndAllCalls(lexer, allowedBlock)));
}

ExprAst parseIf(ref Lexer lexer, Pos start, bool isElseOfParent) {
	ConditionAst condition = parseCondition(lexer, AllowedBlock.no);
	ExprAst then = parseIndentedStatements(lexer);
	Opt!ElifOrElseKeyword elifOrElse = tryTakeNewlineThenElifOrElse(lexer);

	Opt!ExprAst else_ = optIf(has(elifOrElse), () {
		final switch (force(elifOrElse).kind) {
			case ElifOrElse.elif:
				return parseIf(lexer, force(elifOrElse).pos, true);
			case ElifOrElse.else_:
				return parseIndentedStatements(lexer);
		}
	});

	IfAstKind kind = () {
		if (has(elifOrElse)) {
			final switch (force(elifOrElse).kind) {
				case ElifOrElse.elif:
					return IfAstKind.ifElif;
				case ElifOrElse.else_:
					return IfAstKind.ifElse;
			}
		} else
			return IfAstKind.ifWithoutElse;
	}();

	return ExprAst(createIfAst(
		lexer.alloc, start, kind, isElseOfParent, start, condition, some(then),
		optIf(has(elifOrElse), () => force(elifOrElse).pos),
		else_));
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
	return ExprAst(createIfAst(
		lexer.alloc, start, IfAstKind.unless, false, start, cb.condition, some(cb.body_), none!Pos, none!ExprAst));
}

ExprAst parseShared(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) {
	ExprAst inner = parseExprInlineOrBlock(lexer, start, allowedBlock, ParseDiagNeedsBlockCtx.shared_);
	return ExprAst(SharedAst(start, allocate(lexer.alloc, inner)));
}

ExprAst parseThrow(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) {
	ExprAst inner = parseExprInlineOrBlock(lexer, start, allowedBlock, ParseDiagNeedsBlockCtx.throw_);
	return ExprAst(ThrowAst(start, allocate(lexer.alloc, inner)));
}

ExprAst parseTrusted(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) {
	ExprAst inner = parseExprInlineOrBlock(lexer, start, allowedBlock, ParseDiagNeedsBlockCtx.trusted);
	return ExprAst(TrustedAst(start, allocate(lexer.alloc, inner)));
}

ExprAst parseAssertOrForbid(ref Lexer lexer, Pos start, bool isForbid) {
	ConditionAst condition = parseCondition(lexer, AllowedBlock.no);
	Pos colonPos = curPos(lexer);
	Opt!(AssertOrForbidThrownAst*) thrown = optIf(tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colon), () =>
		allocate(lexer.alloc, AssertOrForbidThrownAst(colonPos, parseExprNoBlock(lexer))));
	ExprAst* after = allocate(lexer.alloc, parseNextLinesOrEmpty(lexer));
	return ExprAst(AssertOrForbidAst(start, isForbid, condition, thrown, after));
}

ExprAst parseFinally(ref Lexer lexer, Pos start) {
	ExprAst right = parseExprNoLet(lexer);
	ExprAst below = parseNextLinesOrEmpty(lexer);
	return ExprAst(allocate(lexer.alloc, FinallyAst(start, right, below)));
}

ExprAst parseGuard(ref Lexer lexer, Pos start) {
	ConditionAst condition = parseCondition(lexer, AllowedBlock.no);
	Pos colonPos = curPos(lexer);
	Opt!ExprAst firstBranch = optIf(tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colon), () =>
		parseExprNoBlock(lexer));
	ExprAst secondBranch = parseNextLinesOrEmpty(lexer);
	return ExprAst(createIfAst(
		lexer.alloc,
		start,
		has(firstBranch) ? IfAstKind.guardWithColon : IfAstKind.guardWithoutColon,
		false,
		start,
		condition,
		firstBranch,
		optIf(has(firstBranch), () => colonPos),
		some(secondBranch)));
}

ExprAst parseFor(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parseForOrWith(
		lexer, start, allowedBlock, ParseDiagNeedsBlockCtx.for_,
		(DestructureAst param, Pos colon, ExprAst col, ExprAst body_, Opt!(ExprAst*) else_) =>
			ExprAst(allocate(lexer.alloc, ForAst(start, param, colon, col, body_, else_))));

ExprAst parseWith(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) =>
	parseForOrWith(
		lexer, start, allowedBlock, ParseDiagNeedsBlockCtx.with_,
		(DestructureAst param, Pos colon, ExprAst col, ExprAst body_, Opt!(ExprAst*) else_) =>
			ExprAst(allocate(lexer.alloc, WithAst(start, param, colon, col, body_, else_))));

ExprAst parseForOrWith(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiagNeedsBlockCtx blockKind,
	in ExprAst delegate(
		DestructureAst, Pos colon, ExprAst rhs, ExprAst body_, Opt!(ExprAst*) else_,
	) @safe @nogc pure nothrow cbMakeExpr,
) {
	DestructureAndEndTokenPos paramAndColon = parseForOrWithParameter(
		lexer, Token.colon, ParseDiagExpected.colon);
	DestructureAst param = paramAndColon.destructure;
	Pos colon = paramAndColon.endTokenPos;
	ExprAst rhs = parseExprNoBlock(lexer);
	bool semi = tryTakeToken(lexer, Token.semicolon);
	if (semi) {
		ExprAst body_ = parseExprNoBlock(lexer);
		return cbMakeExpr(param, colon, rhs, body_, none!(ExprAst*));
	} else
		final switch (allowedBlock) {
			case AllowedBlock.no:
				return exprBlockNotAllowed(lexer, start, blockKind);
			case AllowedBlock.yes:
				return takeIndentOrFail_Expr(lexer, () {
					ExprAst body_ = parseStatementsAndDedent(lexer);
					Opt!(ExprAst*) else_ = optIf(has(tryTakeNewlineThenElse(lexer)), () =>
						allocate(lexer.alloc, parseIndentedStatements(lexer)));
					return cbMakeExpr(param, colon, rhs, body_, else_);
				});
		}
}

Opt!(MatchElseAst*) tryParseElse(ref Lexer lexer) {
	Opt!Pos pos = tryTakeNewlineThenElse(lexer);
	return optIf(has(pos), () => allocate(lexer.alloc, MatchElseAst(force(pos), parseIndentedStatements(lexer))));
}

ExprAst parseLoop(ref Lexer lexer, Pos start) =>
	ExprAst(allocate(lexer.alloc, LoopAst(start, parseIndentedStatements(lexer))));

ExprAst parseLoopBreak(ref Lexer lexer, Pos start) =>
	ExprAst(allocate(lexer.alloc, LoopBreakAst(start, parseArgOrEmpty(lexer))));

ExprAst parseLoopWhileOrUntil(ref Lexer lexer, Pos start, bool isUntil) {
	ConditionAndBody cb = parseConditionAndBody(lexer);
	ExprAst after = parseNextLinesOrEmpty(lexer);
	return ExprAst(allocate(lexer.alloc, LoopWhileOrUntilAst(start, isUntil, cb.condition, cb.body_, after)));
}

ExprAst takeIndentOrFail_Expr(ref Lexer lexer, in ExprAst delegate() @safe @nogc pure nothrow cbIndent) =>
	takeIndentOrFailGeneric(lexer, cbIndent, (in Range range) => ExprAst(BogusAst(range)));

ExprAst parseLambdaWithParenthesizedParameters(ref Lexer lexer, Pos start, AllowedBlock allowedBlock) {
	DestructureAst parameter = parseDestructureRequireParens(lexer);
	Pos arrowPos = curPos(lexer);
	takeOrAddDiagExpectedToken(lexer, Token.arrowLambda, ParseDiagExpected.lambdaArrow);
	return parseLambdaAfterArrow(lexer, start, allowedBlock, parameter, arrowPos);
}

struct DestructureAndEndTokenPos {
	DestructureAst destructure;
	Pos endTokenPos;
}
DestructureAndEndTokenPos parseForOrWithParameter( // TODO: INLINE
	ref Lexer lexer,
	Token endToken,
	ParseDiagExpected expectedEndToken,
) {
	Pos pos = curPos(lexer);
	if (tryTakeToken(lexer, endToken))
		return DestructureAndEndTokenPos(DestructureAst(VoidDestructureAst(range(lexer, pos))), pos);
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
		DestructureAst(SingleDestructureAst(NameAndRange(start, paramName), none!Pos, none!(TypeAst*))),
		arrowPos);

ExprAst parseLambdaAfterArrow(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	DestructureAst parameter,
	Pos arrowPos,
) {
	ExprAst body_ = parseExprInlineOrBlock(lexer, start, allowedBlock, ParseDiagNeedsBlockCtx.lambda);
	return ExprAst(allocate(lexer.alloc, LambdaAst(start, parameter, arrowPos, body_)));
}

ExprAst parseExprInlineOrBlock(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiagNeedsBlockCtx needsBlockKind,
) {
	bool inLine = peekTokenExpression(lexer);
	return inLine
		? parseExprAndAllCalls(lexer, allowedBlock)
		: ifAllowBlock(lexer, start, allowedBlock, needsBlockKind, () => parseIndentedStatements(lexer));
}

ExprAst skipRestOfLineAndReturnBogusNoDiag(ref Lexer lexer, Pos start) {
	skipUntilNewlineNoDiag(lexer);
	return ExprAst(BogusAst(rangeForCurToken(lexer, start)));
}

ExprAst skipRestOfLineAndReturnBogus(ref Lexer lexer, Pos start, ParseDiag diag) {
	addDiag(lexer, range(lexer, start), diag);
	return skipRestOfLineAndReturnBogusNoDiag(lexer, start);
}

ExprAst exprBlockNotAllowed(ref Lexer lexer, Pos start, ParseDiagNeedsBlockCtx kind) =>
	skipRestOfLineAndReturnBogus(lexer, start, ParseDiag(ParseDiagNeedsBlockCtx(kind)));

ExprAst ifAllowBlock(
	ref Lexer lexer,
	Pos start,
	AllowedBlock allowedBlock,
	ParseDiagNeedsBlockCtx kind,
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
		ParseDiagNeedsBlockCtx kind,
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
				ExprAst expr = ExprAst(CallAst(
					range(lexer, start),
					CallAstStyle.emptyParens,
					NameAndRange(start, symbol!"new"),
					emptySmallArray!ExprAst));
				return tryParseDotsAndSubscripts(lexer, expr);
			} else {
				ExprAst inner = parseExprNoBlock(lexer);
				takeOrAddDiagExpectedToken(lexer, Token.parenRight, ParseDiagExpected.closingParen);
				ExprAst expr = ExprAst(allocate(lexer.alloc, ParenthesizedAst(range(lexer, start), inner)));
				return tryParseDotsAndSubscripts(lexer, expr);
			}
		case Token.quoteDouble:
		case Token.quoteDouble3:
			QuoteKind quoteKind = token.token == Token.quoteDouble ? QuoteKind.quoteDouble : QuoteKind.quoteDouble3;
			return tryParseDotsAndSubscripts(
				lexer,
				parseString(lexer, start, quoteKind, () => parseExprNoBlock(lexer)));
		case Token.bang:
			ExprAst inner = parseExprBeforeCall(lexer, AllowedBlock.no);
			return ExprAst(CallAst(
				range(lexer, start),
				CallAstStyle.prefixBang,
				NameAndRange(start, symbol!"not"),
				newSmallArray(lexer.alloc, [inner])));
		case Token.break_:
			return parseLoopBreak(lexer, start);
		case Token.continue_:
			return ExprAst(LoopContinueAst(start));
		case Token.do_:
			return ifAllowBlock(ParseDiagNeedsBlockCtx.do_, () => parseDo(lexer, start));
		case Token.extern_:
			return parseExtern(lexer, start);
		case Token.if_:
			return ifAllowBlock(ParseDiagNeedsBlockCtx.if_, () => parseIf(lexer, start, false));
		case Token.for_:
			return parseFor(lexer, start, allowedBlock);
		case Token.match:
			return ifAllowBlock(ParseDiagNeedsBlockCtx.match, () => parseMatch(lexer, start));
		case Token.name:
			Symbol name = token.asSymbol;
			Pos arrowPos = curPos(lexer);
			return tryTakeToken(lexer, Token.arrowLambda)
				? parseLambdaAfterNameAndArrow(lexer, start, allowedBlock, name, arrowPos)
				: handleName(lexer, start, NameAndRange(start, name));
		case Token.nameAfterBang:
			ExprAst inner = ExprAst(NameAndRange(start, token.asSymbol));
			return makeAugment(
				lexer.alloc, range(lexer, start), start, symbol!"not", tryParseDotsAndSubscripts(lexer, inner));
		case Token.nameBang:
			Range nameBangRange = range(lexer, start);
			ExprAst inner = ExprAst(NameAndRange(start, token.asSymbol));
			return tryParseDotsAndSubscripts(
				lexer,
				makeAugment(lexer.alloc, nameBangRange, nameBangRange.end - 1, symbol!"force", inner));
		case Token.operator:
			Symbol operator = token.asSymbol;
			if (isPrefixUnaryOperator(operator)) {
				if (operator == symbol!"&") {
					ExprAst inner = parseExprBeforeCall(lexer, AllowedBlock.no);
					return ExprAst(allocate(lexer.alloc, PtrAst(start, inner)));
				} else
					return handlePrefixUnaryOperator(lexer, allowedBlock, start, operator);
			} else
				return badToken(lexer, start, token);
		case Token.literalFloat:
			return tryParseDotsAndSubscripts(lexer, ExprAst(
				LiteralFloatAndRange(range(lexer, start), token.asLiteralFloat)));
		case Token.literalIntegral:
			return tryParseDotsAndSubscripts(lexer, ExprAst(
				LiteralIntegralAndRange(range(lexer, start), token.asLiteralIntegral)));
		case Token.loop:
			return ifAllowBlock(ParseDiagNeedsBlockCtx.loop, () => parseLoop(lexer, start));
		case Token.shared_:
			return parseShared(lexer, start, allowedBlock);
		case Token.throw_:
			return parseThrow(lexer, start, allowedBlock);
		case Token.trusted:
			return parseTrusted(lexer, start, allowedBlock);
		case Token.try_:
			return ifAllowBlock(ParseDiagNeedsBlockCtx.try_, () => parseTryBlock(lexer, start));
		case Token.underscore:
			Pos arrowPos = curPos(lexer);
			return tryTakeToken(lexer, Token.arrowLambda)
				? parseLambdaAfterNameAndArrow(lexer, start, allowedBlock, symbol!"_", arrowPos)
				: badToken(lexer, start, token);
		case Token.unless:
			return ifAllowBlock(ParseDiagNeedsBlockCtx.unless, () => parseUnless(lexer, start));
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
	return ExprAst(CallAst(
		range(lexer, start),
		CallAstStyle.prefixOperator,
		NameAndRange(start, operator),
		newSmallArray(lexer.alloc, [arg])));
}

ExprAst parseExtern(ref Lexer lexer, Pos start) {
	NameAndRange[] names = tryTakeToken(lexer, Token.parenLeft)
		? buildArray!NameAndRange(lexer.alloc, (scope ref Builder!NameAndRange res) {
			do {
				res ~= takeNameAndRange(lexer);
			} while (tryTakeToken(lexer, Token.comma));
			takeOrAddDiagExpectedToken(lexer, Token.parenRight, ParseDiagExpected.closingParen);
		})
		: newArray(lexer.alloc, [takeNameAndRange(lexer)]);
	return ExprAst(ExternAst(range(lexer, start), names));
}

ExprAst handleName(ref Lexer lexer, Pos start, NameAndRange name) {
	Opt!(TypeAst*) typeArg = tryParseTypeArgForExpr(lexer);
	return has(typeArg)
		? ExprAst(CallAst(
			range(lexer, start),
			CallAstStyle.single,
			name,
			emptySmallArray!ExprAst,
			typeArg))
		: tryParseDotsAndSubscripts(lexer, ExprAst(name));
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
					? parseAssignment(lexer, expr, assignmentPos)
					: parseCalls(lexer, start, expr, ArgCtx(AllowedBlock.yes, allowAllCalls()));
			}
	}
}

ExprAst parseNamedCall(ref Lexer lexer, Pos start) {
	ArrayBuilder!NameAndRange names;
	ArrayBuilder!ExprAst values;
	do {
		NameAndRange name = takeNameAndRange(lexer);
		if (takeOrAddDiagExpectedTokenAndSkipRestOfLine(lexer, Token.colon, ParseDiagExpected.namedArgument)) {
			add(lexer.alloc, names, name);
			add(lexer.alloc, values, parseExprNoLet(lexer));
		}
	} while (tryTakeToken(lexer, Token.newlineSameIndent));
	return arrayBuilderIsEmpty(names)
		? ExprAst(BogusAst(range(lexer, start)))
		: ExprAst(CallNamedAst(finish(lexer.alloc, names), finish(lexer.alloc, values)));
}

ExprAst parseEquals(ref Lexer lexer) {
	Pos start = curPos(lexer);
	if (tryTakeToken(lexer, Token.try_))
		return parseTryLet(lexer, start);
	else {
		DestructureAst left = parseDestructureNoRequireParens(lexer);
		takeOrAddDiagExpectedTokenAndMayContinueOntoNextLine(
			lexer, Token.equal, ParseDiagExpected.equals);
		ExprAst init = parseExprNoLet(lexer);
		ExprAst then = parseNextLinesOrEmpty(lexer);
		return ExprAst(allocate(lexer.alloc, LetAst(left, init, then)));
	}
}

ExprAst parseTryLet(ref Lexer lexer, Pos start) {
	DestructureAst destructure = parseDestructureNoRequireParens(lexer);
	takeOrAddDiagExpectedTokenAndMayContinueOntoNextLine(lexer, Token.equal, ParseDiagExpected.equals);
	ExprAst value = parseExprNoBlock(lexer);
	Pos catchPos = curPos(lexer);
	takeOrAddDiagExpectedToken(lexer, Token.catch_, ParseDiagExpected.catch_);
	CaseMemberAst catchMember = parseCaseMember(lexer);
	ExprAst catch_ = tryTakeTokenAndMayContinueOntoNextLine(lexer, Token.colon)
		? parseExprNoLet(lexer)
		: emptyAst(lexer);
	ExprAst then = parseNextLinesOrEmpty(lexer);
	return ExprAst(allocate(lexer.alloc, TryLetAst(
		start, destructure, value, catchPos, catchMember, catch_, then)));
}

ExprAst parseStatements(ref Lexer lexer) {
	Pos start = curPos(lexer);
	return parseStatementsRecur(lexer, start, parseSingleStatementLine(lexer));
}

ExprAst parseStatementsRecur(ref Lexer lexer, Pos start, ExprAst res) {
	if (tryTakeToken(lexer, Token.newlineSameIndent)) {
		ExprAst nextLine = parseSingleStatementLine(lexer);
		return parseStatementsRecur(lexer, start, ExprAst(allocate(lexer.alloc, SeqAst(res, nextLine))));
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
	return ExprAst(TryAst(start, body_, catches));
}
