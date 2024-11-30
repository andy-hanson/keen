module frontend.ide.syntaxTranslate;

@safe @nogc pure nothrow:

import frontend.parse.lexToken : tryTakeIdentifier;
import frontend.parse.parse : ExprAndDiags, parseSingleLineExpression;
import lib.lsp.lspTypes : Language, SyntaxTranslateParams, SyntaxTranslateResult;
import model.ast : CallAst, ExprAst, NameAndRange, ParenthesizedAst;
import model.parseDiag : ParseDiagnostic;
import model.sourceRange : Pos;
import util.alloc.alloc : Alloc;
import util.col.array : contains, emptySmallArray, isEmpty, map, newArray, prepend, small, SmallArray;
import util.col.arrayBuilder : add, ArrayBuilder, Builder, buildArray, buildSmallArray, finish;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf;
import util.union_ : Union;
import util.string : copyString, copyToCString, CString, isWhitespace, MutCString, stringOfRange, tryTakeChar;
import util.symbol : enumOfSymbol, Symbol, symbolOfString;
import util.util : ptrTrustMe;
import util.writer : makeStringWithWriter, Writer, writeWithCommas;

SyntaxTranslateResult syntaxTranslate(ref Alloc alloc, in SyntaxTranslateParams params) {
	if (contains(params.source, '\n'))
		return SyntaxTranslateResult("", newArray!(immutable Pos)(alloc, [0]));

	CString source = copyToCString(alloc, params.source);
	if (params.from == params.to)
		return SyntaxTranslateResult(output: copyString(alloc, params.source), diagnostics: []);
	else if (params.to == Language.crow) {
		JavaExprAndDiags expr = parseJavaExpr(alloc, source);
		return SyntaxTranslateResult(
			output: makeStringWithWriter(alloc, (scope ref Writer writer) {
				translateToCrow(writer, expr.expr, Position.root, none!Augment);
			}),
			diagnostics: expr.diagnostics);
	} else if (params.from == Language.crow) {
		ExprAndDiags res = parseSingleLineExpression(alloc, source);
		string output;
		immutable Pos[] diagnostics = buildArray!(immutable Pos)(alloc, (scope ref Builder!(immutable Pos) out_) {
			foreach (ParseDiagnostic x; res.diags)
				out_ ~= x.range.start;
			output = makeStringWithWriter(alloc, (scope ref Writer writer) {
				translateCrowToCOrJava(writer, out_, res.expr, params.to == Language.java);
			});
		});
		return SyntaxTranslateResult(output, diagnostics);
	} else {
		JavaExprAndDiags expr = parseJavaExpr(alloc, source);
		string output = makeStringWithWriter(alloc, (scope ref Writer writer) {
			outputCOrJava(writer, translateBetweenCOrJava(alloc, expr.expr, params.to == Language.java));
		});
		return SyntaxTranslateResult(output, expr.diagnostics);
	}
}

private:

void translateCrowToCOrJava(
	scope ref Writer writer,
	scope ref Builder!(immutable Pos) diagnostics,
	in ExprAst a,
	bool isJava,
) {
	if (a.isA!CallAst) {
		CallAst call = a.as!CallAst;
		ExprAst[] remainingArgs = () {
			if (isJava && call.args.length != 0) {
				translateCrowToCOrJava(writer, diagnostics, call.args[0], isJava);
				writer ~= '.';
				return call.args[1 .. $];
			} else
				return call.args;
		}();
		writer ~= call.funName.name;
		writeParenthesized!ExprAst(writer, remainingArgs, (in ExprAst x) {
			translateCrowToCOrJava(writer, diagnostics, x, isJava);
		});
	} else if (a.isA!NameAndRange)
		writer ~= a.as!NameAndRange.name;
	else if (a.isA!(ParenthesizedAst*))
		translateCrowToCOrJava(writer, diagnostics, a.as!(ParenthesizedAst*).inner, isJava);
	else
		diagnostics ~= a.range.start;
}

void outputCOrJava(scope ref Writer writer, in JavaExpr a) {
	a.matchIn!void(
		(in JavaExpr.Bogus _) {
			writer ~= "bogus";
		},
		(in Symbol x) {
			writer ~= x;
		},
		(in JavaExpr.Call x) {
			outputCOrJava(writer, *x.called);
			writeParenthesized!JavaExpr(writer, x.args, (in JavaExpr arg) {
				outputCOrJava(writer, arg);
			});
		},
		(in JavaExpr.Dot x) {
			outputCOrJava(writer, *x.left);
			writer ~= '.';
			writer ~= x.name;
		});
}

JavaExpr translateBetweenCOrJava(ref Alloc alloc, JavaExpr a, bool outputJava) {
	JavaExpr recur(JavaExpr x) =>
		translateBetweenCOrJava(alloc, x, outputJava);
	SmallArray!JavaExpr recurArgs(JavaExpr[] xs) =>
		small!JavaExpr(map(alloc, xs, (ref JavaExpr x) => recur(x)));
	if (a.isA!(JavaExpr.Call)) {
		JavaExpr.Call call = a.as!(JavaExpr.Call);
		return call.called.match!JavaExpr(
			(JavaExpr.Bogus _) =>
				a,
			(Symbol x) =>
				outputJava && !isEmpty(call.args)
					? JavaExpr(JavaExpr.Call(
						allocate(alloc, JavaExpr(JavaExpr.Dot(allocate(alloc, recur(call.args[0])), x))),
						recurArgs(call.args[1 .. $])))
					: a,
			(JavaExpr.Call _) =>
				a,
			(JavaExpr.Dot x) =>
				outputJava
					? a
					: JavaExpr(JavaExpr.Call(
						allocate(alloc, JavaExpr(x.name)),
						prepend!JavaExpr(alloc, recur(*x.left), recurArgs(call.args)))));
	} else
		return a;
}

void writeParenthesized(T)(scope ref Writer writer, in T[] values, in void delegate(in T) @safe @nogc pure nothrow cb) {
	writer ~= '(';
	writeWithCommas!T(writer, values, cb);
	writer ~= ')';
}

enum Position { root, firstArg, nonFirstArg, beforeDot }

enum Augment { not, force }
void withAugment(scope ref Writer writer, Opt!Augment augment, Symbol name) {
	withAugment(writer, augment, () {
		writer ~= name;
	});
}
void withAugment(scope ref Writer writer, Opt!Augment augment, in void delegate() @safe @nogc pure nothrow cb) {
	if (has(augment)) {
		final switch (force(augment)) {
			case Augment.not:
				writer ~= '!';
				break;
			case Augment.force:
				break;
		}
	}
	cb();
	if (has(augment)) {
		final switch (force(augment)) {
			case Augment.not:
				break;
			case Augment.force:
				writer ~= '!';
				break;
		}
	}
}

void translateToCrow(scope ref Writer writer, in JavaExpr a, Position position, Opt!Augment augment) {
	a.matchIn!void(
		(in JavaExpr.Bogus _) {
			writer ~= "bogus";
		},
		(in Symbol x) {
			withAugment(writer, augment, x);
		},
		(in JavaExpr.Call x) {
			translateCallToCrow(writer, x, position, augment);
		},
		(in JavaExpr.Dot x) {
			writeCrowCall(writer, *x.left, x.name, [], position, augment);
		});
}
void translateCallToCrow(scope ref Writer writer, in JavaExpr.Call a, Position position, Opt!Augment augment) {
	JavaExpr[] args = a.args;
	a.called.matchIn!void(
		(in JavaExpr.Bogus _) {
			writer ~= "bogus";
		},
		(in Symbol x) {
			if (isEmpty(args))
				withAugment(writer, augment, x);
			else
				writeCrowCall(writer, args[0], x, args[1 .. $], position, augment);
		},
		(in JavaExpr.Call x) {
			withAugment(writer, augment, () {
				translateToCrow(writer, JavaExpr(x), position, none!Augment);
				writer ~= '[';
				writeWithCommas!JavaExpr(writer, args, (in JavaExpr arg) {
					translateToCrow(writer, arg, Position.nonFirstArg, none!Augment);
				});
				writer ~= ']';
			});
		},
		(in JavaExpr.Dot x) {
			writeCrowCall(writer, *x.left, x.name, args, position, augment);
		});
}
void writeCrowCall(
	scope ref Writer writer,
	in JavaExpr firstArg,
	Symbol name,
	in JavaExpr[] restArgs,
	Position position,
	Opt!Augment augment,
) {
	if (isEmpty(restArgs)) {
		Opt!Augment newAugment = has(augment) ? none!Augment : enumOfSymbol!Augment(name);
		if (has(newAugment)) {
			translateToCrow(writer, firstArg, position, newAugment);
		} else {
			bool isRoot = position == Position.root;
			if (isRoot) {
				translateToCrow(writer, firstArg, Position.firstArg, none!Augment);
				writer ~= ' ';
				withAugment(writer, augment, name);
			} else {
				withAugment(writer, augment, () {
					translateToCrow(writer, firstArg, Position.beforeDot, none!Augment);
					writer ~= '.';
					writer ~= name;
				});
			}
		}
	} else {
		bool needsParens = () {
			final switch (position) {
				case Position.root:
				case Position.firstArg:
					return false;
				case Position.nonFirstArg:
				case Position.beforeDot:
					return true;
			}
		}();
		if (needsParens)
			writer ~= '(';
		translateToCrow(writer, firstArg, Position.firstArg, none!Augment);
		writer ~= ' ';
		withAugment(writer, augment, name);
		writer ~= ' ';
		writeWithCommas!JavaExpr(writer, restArgs, (in JavaExpr arg) {
			translateToCrow(writer, arg, Position.nonFirstArg, none!Augment);
		});
		if (needsParens)
			writer ~= ')';
	}
}

// Also represents C expressions
immutable struct JavaExpr {
	immutable struct Bogus {}
	immutable struct Call {
		JavaExpr* called;
		SmallArray!JavaExpr args;
	}
	immutable struct Dot {
		JavaExpr* left;
		Symbol name;
	}
	mixin Union!(Bogus, Symbol, Call, Dot);
}

struct ParseCtx {
	@safe @nogc pure nothrow:
	Alloc* allocPtr;
	CString start;
	ArrayBuilder!Pos diags;

	ref Alloc alloc() =>
		*allocPtr;
}

void addDiag(ref ParseCtx ctx, in CString ptr) {
	add(ctx.alloc, ctx.diags, ptr - ctx.start);
}

immutable struct JavaExprAndDiags {
	JavaExpr expr;
	Pos[] diagnostics;
}
JavaExprAndDiags parseJavaExpr(ref Alloc alloc, CString source) {
	ParseCtx ctx = ParseCtx(ptrTrustMe(alloc), source);
	MutCString ptr = source;
	JavaExpr res = parseJavaExprRecur(ctx, ptr);
	skipWhitespace(ptr);
	if (*ptr != '\0')
		addDiag(ctx, ptr);
	return JavaExprAndDiags(res, finish(alloc, ctx.diags));
}

JavaExpr parseJavaExprRecur(ref ParseCtx ctx, scope ref MutCString ptr) {
	skipWhitespace(ptr);
	Opt!Symbol name = tryTakeName(ptr);
	if (has(name))
		return parseJavaExprSuffixes(ctx, ptr, JavaExpr(force(name)));
	else {
		addDiag(ctx, ptr);
		return JavaExpr(JavaExpr.Bogus());
	}
}

JavaExpr parseJavaExprSuffixes(ref ParseCtx ctx, scope ref MutCString ptr, JavaExpr lhs) {
	skipWhitespace(ptr);
	if (tryTakeChar(ptr, '.')) {
		Opt!Symbol name = tryTakeName(ptr);
		if (has(name))
			return parseJavaExprSuffixes(ctx, ptr, JavaExpr(JavaExpr.Dot(allocate(ctx.alloc, lhs), force(name))));
		else {
			addDiag(ctx, ptr);
			return lhs;
		}
	} else if (tryTakeChar(ptr, '(')) {
		SmallArray!JavaExpr args = tryTakeChar(ptr, ')')
			? emptySmallArray!JavaExpr
			: buildSmallArray!JavaExpr(ctx.alloc, (scope ref Builder!JavaExpr out_) {
				do {
					out_ ~= parseJavaExprRecur(ctx, ptr);
					skipWhitespace(ptr);
				} while (tryTakeChar(ptr, ','));
				if (!tryTakeChar(ptr, ')'))
					addDiag(ctx, ptr);
			});
		return parseJavaExprSuffixes(ctx, ptr, JavaExpr(JavaExpr.Call(allocate(ctx.alloc, lhs), args)));
	} else
		return lhs;
}

Opt!Symbol tryTakeName(scope ref MutCString ptr) {
	CString start = ptr;
	bool ok = tryTakeIdentifier(ptr);
	return optIf(ok, () => symbolOfString(stringOfRange(start, ptr)));
}

void skipWhitespace(scope ref MutCString ptr) {
	while (isWhitespace(*ptr))
		ptr++;
}
