module frontend.showDiag;

@safe @nogc pure nothrow:

import frontend.getDiagnosticSeverity : getDiagnosticSeverity;
import frontend.parse.lexer : Token;
import frontend.showModel :
	ShowCtx,
	ShowDiagCtx,
	writeCalledDecls,
	writeCalleds,
	writeFunDecl,
	writeFunDeclAndTypeArgs,
	writeFunInst,
	writeKeyword,
	WriteKind,
	writeName,
	writePurity,
	writeSig,
	writeSigSimple,
	writeStructInst,
	writeTypeQuoted,
	writeTypeUnquoted,
	writeUri,
	writeUriAndRange,
	writeVisibility;
import model.ast : ModifierKeyword, stringOfModifierKeyword;
import model.diag :
	AutoFunName,
	Diagnostic,
	Diag,
	DiagnosticSeverity,
	ExpectedForDiag,
	ReadFileDiag,
	DeclKind,
	UriAndDiagnostic;
import model.model :
	arityMatches,
	bestCasePurity,
	BuiltinType,
	CalledDecl,
	eachDiagnostic,
	EnumOrFlagsMember,
	FunDeclAndTypeArgs,
	Local,
	maxValue,
	minValue,
	nTypeParams,
	Params,
	ProgramWithOptMain,
	SpecDecl,
	Signature,
	StructBody,
	StructDecl,
	StructInst,
	Type,
	TypeContainer,
	TypeParamsAndSig,
	TypeWithContainer;
import model.parseDiag : ParseDiag, ParseDiagnostic;
import util.alloc.alloc : Alloc;
import util.col.array : contains, exists, isEmpty, only;
import util.col.arrayBuilder : arrayBuilderSort, buildArray, Builder;
import util.col.multiMap : makeMultiMap, MultiMap, MultiMapCb;
import util.col.sortUtil : sorted;
import util.comparison : Comparison;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : compareRange;
import util.symbol : Symbol, symbol;
import util.uri : baseName, compareUriNaturally, Uri;
import util.util : stringOfEnum, max;
import util.writer :
	makeStringWithWriter,
	writeFloatLiteral,
	writeHex,
	writeNewline,
	writeQuotedChar,
	writeQuotedString,
	writeWithCommas,
	writeWithNewlines,
	writeWithSeparator,
	Writer;

string stringOfDiagnostics(
	ref Alloc alloc,
	in ShowDiagCtx ctx,
	in ProgramWithOptMain program,
	in Opt!(Uri[]) onlyForUris,
) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		DiagnosticSeverity severity = maxDiagnosticSeverity(program);
		bool first = true;
		foreach (UriAndDiagnostics x; sortedDiagnostics(alloc, program))
			if (!has(onlyForUris) || contains(force(onlyForUris), x.uri))
				foreach (Diagnostic diagnostic; x.diagnostics) {
					if (getDiagnosticSeverity(diagnostic.kind) == severity) {
						if (!first)
							writer ~= '\n';
						else
							first = false;
						showDiagnostic(writer, ctx, UriAndDiagnostic(x.uri, diagnostic));
					}
				}
	});

string stringOfDiag(ref Alloc alloc, in ShowDiagCtx ctx, in Diag diag) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writeDiag(writer, ctx, diag);
	});

string stringOfParseDiagnostics(ref Alloc alloc, in ShowCtx ctx, Uri uri, in ParseDiagnostic[] diagnostics) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writeWithNewlines!ParseDiagnostic(writer, diagnostics, (in ParseDiagnostic x) {
			writer ~= ctx.lineAndColumnGetters[uri][x.range];
			writer ~= ' ';
			writeParseDiag(writer, ctx, x.kind);
		});
	});

immutable struct UriAndDiagnostics {
	Uri uri;
	Diagnostic[] diagnostics;
}

UriAndDiagnostics[] sortedDiagnostics(ref Alloc alloc, in ProgramWithOptMain program) {
	MultiMap!(Uri, Diagnostic) map = makeMultiMap!(Uri, Diagnostic)(alloc, (in MultiMapCb!(Uri, Diagnostic) cb) {
		eachDiagnostic(program, (in UriAndDiagnostic x) {
			cb(x.uri, x.diagnostic);
		});
	});
	return buildArray!UriAndDiagnostics(alloc, (scope ref Builder!UriAndDiagnostics res) {
		foreach (Uri uri, immutable Diagnostic[] diags; map) {
			Diagnostic[] sortedDiags = sorted!Diagnostic(alloc, diags, (in Diagnostic x, in Diagnostic y) =>
				compareDiagnostic(x, y));
			res ~= UriAndDiagnostics(uri, sortedDiags);
		}
		arrayBuilderSort!(UriAndDiagnostics, compareUriAndDiagnosticsByUri)(res);
	});
}

private:

Comparison compareUriAndDiagnosticsByUri(in UriAndDiagnostics a, in UriAndDiagnostics b) =>
	compareUriNaturally(a.uri, b.uri);

Comparison compareDiagnostic(in Diagnostic a, in Diagnostic b) =>
	compareRange(a.range, b.range);

DiagnosticSeverity maxDiagnosticSeverity(in ProgramWithOptMain a) {
	DiagnosticSeverity res = DiagnosticSeverity.unusedCode;
	eachDiagnostic(a, (in UriAndDiagnostic x) {
		res = max(res, getDiagnosticSeverity(x.kind));
	});
	return res;
}

void writeUnusedDiag(scope ref Writer writer, in ShowCtx ctx, in Diag.Unused a) {
	a.kind.matchIn!void(
		(in Diag.Unused.Kind.Import x) {
			if (has(x.importedName)) {
				writer ~= "Imported name ";
				writeName(writer, ctx, force(x.importedName));
			} else {
				writer ~= "Imported module ";
				writeName(writer, ctx, baseName(x.importedModule.uri));
			}
			writer ~= " is unused.";
		},
		(in Diag.Unused.Kind.Local x) {
			writer ~= "Local ";
			writeName(writer, ctx, x.local.name);
			writer ~= !x.local.isMutable
				? " is unused"
				: x.usedGet
				? " is mutable but never reassigned"
				: x.usedSet
				? " is assigned to but unused"
				: " is unused.";
		},
		(in Diag.Unused.Kind.PrivateDecl x) {
			writeName(writer, ctx, x.name);
			writer ~= " is unused.";
		});
}

void writeParseDiag(scope ref Writer writer, in ShowCtx ctx, in ParseDiag d) {
	d.matchIn!void(
		(in ParseDiag.DocCommentUnused) {
			writer ~= "Doc comment must appear at top of module or before a declaration.";
		},
		(in ParseDiag.Expected x) {
			writer ~= showParseDiagExpected(x.kind);
		},
		(in ParseDiag.FileNotUtf8) {
			writer ~= "File is not encoded as UTF-8 or has encoding errors.";
		},
		(in ParseDiag.ImportFileTypeNotSupported) {
			writer ~= "Import file type not allowed; the only supported types are 'nat8 array' and 'string'.";
		},
		(in ParseDiag.IndentNotDivisible d) {
			writer ~= "Expected indentation by ";
			writer ~= d.nSpacesPerIndent;
			writer ~= " spaces per level, but got ";
			writer ~= d.nSpaces;
			writer ~= " which is not divisible.";
		},
		(in ParseDiag.IndentTooMuch x) {
			writer ~= "Indented too far.";
		},
		(in ParseDiag.IndentWrongCharacter d) {
			writer ~= "Expected indentation by ";
			writer ~= d.expectedTabs ? "tabs" : "spaces";
			writer ~= " (based on first indented line), but here there is a ";
			writer ~= d.expectedTabs ? "space" : "tab.";
		},
		(in ParseDiag.InvalidStringEscape x) {
			writer ~= "Invalid escape sequence '";
			writer ~= x.actual;
			writer ~= "'.";
		},
		(in ParseDiag.MatchCaseInterpolated) {
			writer ~= "'match' only works with literal strings, not interpolated strings.";
		},
		(in ParseDiag.MissingInterpolated x) {
			writer ~= "Expected something inside of the '{}'.";
		},
		(in ParseDiag.NeedsBlockCtx x) {
			if (x.kind == ParseDiag.NeedsBlockCtx.Kind.lambda)
				writer ~= "Lambda";
			else {
				writer ~= '\'';
				writer ~= stringOfEnum(x.kind);
				writer ~= '\'';
			}
			writer ~= " expression must appear in a context where it can be followed by an indented block.";
		},
		(in ReadFileDiag x) {
			showReadFileDiag(writer, ctx, x, none!Uri);
		},
		(in ParseDiag.TrailingComma) {
			writer ~= "Remove this trailing comma.";
		},
		(in ParseDiag.TypeEmptyParens) {
			writer ~= "'()' is not a type. Did you mean 'void'?";
		},
		(in ParseDiag.TypeTrailingMut) {
			writer ~= "To make something mutable, put 'mut' after its name, not after its type.";
		},
		(in ParseDiag.TypeUnnecessaryParens) {
			writer ~= "Parentheses are unnecessary.";
		},
		(in ParseDiag.UnexpectedCharacter x) {
			writer ~= "Unexpected character ";
			writeQuotedChar(writer, x.character);
			writer ~= " (U+";
			writeHex(writer, x.character, minDigits: 4);
			writer ~= ").";
		},
		(in ParseDiag.UnexpectedOperator x) {
			writer ~= "Unexpected '";
			writer ~= x.operator;
			writer ~= "'.";
		},
		(in ParseDiag.UnexpectedToken u) {
			writer ~= describeTokenForUnexpected(u.token);
		});
}

string showParseDiagExpected(ParseDiag.Expected.Kind kind) {
	final switch (kind) {
		case ParseDiag.Expected.Kind.as:
			return "Expected 'as'.";
		case ParseDiag.Expected.Kind.blockCommentEnd:
			return "Expected '###' (then a newline).";
		case ParseDiag.Expected.Kind.catch_:
			return "Expected 'catch'.";
		case ParseDiag.Expected.Kind.closeInterpolated:
			return "Expected '}'.";
		case ParseDiag.Expected.Kind.closingBracket:
			return "Expected ']'.";
		case ParseDiag.Expected.Kind.closingParen:
			return "Expected ')'.";
		case ParseDiag.Expected.Kind.colon:
			return "Expected ':'.";
		case ParseDiag.Expected.Kind.comma:
			return "Expected ','.";
		case ParseDiag.Expected.Kind.dedent:
			return "Expected a dedent.";
		case ParseDiag.Expected.Kind.endOfLine:
			return "Expected end of line.";
		case ParseDiag.Expected.Kind.equals:
			return "Expected '='.";
		case ParseDiag.Expected.Kind.indent:
			return "Expected an indent.";
		case ParseDiag.Expected.Kind.lambdaArrow:
			return "Expected ' =>' after lambda parameters.";
		case ParseDiag.Expected.Kind.less:
			return "Expected '<'.";
		case ParseDiag.Expected.Kind.literalIntegral:
			return "Expected an integer.";
		case ParseDiag.Expected.Kind.literalNat:
			return "Expected a natural number.";
		case ParseDiag.Expected.Kind.matchCase:
			return "A branch of a 'match' must be an identifier, number literal, or string literal.";
		case ParseDiag.Expected.Kind.name:
			return "Expected a name (non-operator).";
		case ParseDiag.Expected.Kind.namedArgument:
			return "Expected another named argument.";
		case ParseDiag.Expected.Kind.nameOrOperator:
			return "Expected a name or operator.";
		case ParseDiag.Expected.Kind.newline:
			return "Expected a newline.";
		case ParseDiag.Expected.Kind.newlineOrDedent:
			return "Expected a newline or dedent.";
		case ParseDiag.Expected.Kind.openParen:
			return "Expected '('.";
		case ParseDiag.Expected.Kind.questionEqual:
			return "Expected '?='.";
		case ParseDiag.Expected.Kind.quoteDouble:
			return "Expected '\"'.";
		case ParseDiag.Expected.Kind.quoteDouble3:
			return "Expected '\"\"\"'.";
		case ParseDiag.Expected.Kind.slash:
			return "Expected '/'.";
		case ParseDiag.Expected.Kind.typeArgsEnd:
			return "Expected '>'.";
	}
}

void showReadFileDiag(scope ref Writer writer, in ShowCtx ctx, ReadFileDiag a, Opt!Uri uri) {
	final switch (a) {
		case ReadFileDiag.notFound:
			if (has(uri)) {
				writer ~= "Imported file ";
				writeUri(writer, ctx, force(uri));
				writer ~= " does not exist.";
			} else
				writer ~= "This file does not exist.";
			break;
		case ReadFileDiag.error:
			if (has(uri)) {
				writer ~= "There was an error reading imported file ";
				writeUri(writer, ctx, force(uri));
				writer ~= '.';
			} else
				writer ~= "There was an error reading this file.";
			break;
		case ReadFileDiag.loading:
			if (has(uri)) {
				writer ~= "IDE is still loading imported file ";
				writeUri(writer, ctx, force(uri));
				writer ~= '.';
			} else
				writer ~= "The editor is still loading this file.";
			break;
		case ReadFileDiag.unknown:
			assert(false);
	}
}

void writeSpecTrace(
	scope ref Writer writer,
	in ShowDiagCtx ctx,
	in TypeContainer outermostTypeContainer,
	in FunDeclAndTypeArgs[] trace,
) {
	foreach (size_t i, FunDeclAndTypeArgs x; trace) {
		writer ~= "\n\t";
		TypeContainer typeContainer = i == 0 ? outermostTypeContainer : TypeContainer(trace[i - 1].decl);
		writeFunDeclAndTypeArgs(writer, ctx, typeContainer, x);
	}
}

void writeCallNoMatch(scope ref Writer writer, in ShowDiagCtx ctx, in Diag.CallNoMatch d) {
	bool someCandidateHasCorrectNTypeArgs =
		d.actualNTypeArgs == 0 ||
		exists!CalledDecl(d.allCandidates, (in CalledDecl c) =>
			nTypeParams(c) == 1 || nTypeParams(c) == d.actualNTypeArgs);
	bool someCandidateHasCorrectArity =
		exists!CalledDecl(d.allCandidates, (in CalledDecl c) =>
			(d.actualNTypeArgs == 0 || nTypeParams(c) == d.actualNTypeArgs) &&
			arityMatches(c.arity, d.actualArity));

	if (isEmpty(d.allCandidates)) {
		writer ~= "There is no function ";
		if (d.actualArity == 0)
			// If there is no local variable by that name we try a call,
			// but message should reflect that the user might not have wanted a call.
			writer ~= "or variable ";
		writer ~= "named ";
		writeName(writer, ctx, d.funName);
		writer ~= '.';

		if (d.actualArgTypes.length == 1) {
			writer ~= "\nArgument type: ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(only(d.actualArgTypes), d.typeContainer));
		}
	} else if (!someCandidateHasCorrectArity) {
		writer ~= "There are functions named ";
		writeName(writer, ctx, d.funName);
		writer ~= ", but none takes ";
		if (someCandidateHasCorrectNTypeArgs) {
			writer ~= d.actualArity;
		} else {
			writer ~= d.actualNTypeArgs;
			writer ~= " type";
		}
		writer ~= " arguments. candidates:";
		writeCalledDecls(writer, ctx, d.typeContainer, d.allCandidates);
	} else {
		writer ~= "There are functions named ";
		writeName(writer, ctx, d.funName);
		writer ~= ", but they do not match the ";
		bool hasRet = d.expectedReturnType.isA!(ExpectedForDiag.Choices);
		bool hasArgs = !isEmpty(d.actualArgTypes);
		string descr = hasRet
			? hasArgs ? "expected return type and actual argument types" : "expected return type"
			: "actual argument types";
		writer ~= descr;
		writer ~= '.';
		writeNewline(writer, 0);
		if (hasRet)
			writeExpected(writer, ctx, d.expectedReturnType, ExpectedKind.return_);
		if (hasArgs) {
			writer ~= "\nActual argument types: ";
			writeWithCommas!Type(writer, d.actualArgTypes, (in Type t) {
				writeTypeQuoted(writer, ctx, TypeWithContainer(t, d.typeContainer));
			});
			if (d.actualArgTypes.length < d.actualArity)
				writer ~= " (Other arguments not checked; gave up early.)";
		}
		writer ~= "\nCandidates (with ";
		writer ~= d.actualArity;
		writer ~= " arguments):";
		writeCalledDecls(writer, ctx, d.typeContainer, d.allCandidates, (in CalledDecl c) =>
			arityMatches(c.arity, d.actualArity));
	}
}

void writeDiag(scope ref Writer writer, in ShowDiagCtx ctx, in Diag diag) {
	diag.matchIn!void(
		(in Diag.AliasNotAllowed) {
			writer ~= "An alias is not allowed to reference another alias in the same module.";
		},
		(in Diag.AssertOrForbidMessageIsThrow) {
			writer ~= "The expression after the ':' for an assert or forbid is always thrown; it doesn't need 'throw'.";
		},
		(in Diag.AssignmentNotAllowed) {
			writer ~= "Can't assign to this kind of expression.";
		},
		(in Diag.AutoFunError x) {
			x.matchIn!void(
				(in Diag.AutoFunError.Bare) {
					writer ~= "Automatic 'to json' can't be 'bare'.";
				},
				(in Diag.AutoFunError.EnumOrFlagsToWrongStorage x) {
					writer ~= "Type ";
					writeName(writer, ctx, x.enumOrFlagsType.name);
					writer ~= " has storage type ";
					writeName(writer, ctx, stringOfEnum(x.actualStorageType));
					writer ~= ", not ";
					writeName(writer, ctx, stringOfEnum(x.expectedStorageType));
				},
				(in Diag.AutoFunError.ParamNotSimple) {
					writer ~= "An auto fun must have simple parameters (not ignored or destructured).";
				},
				(in Diag.AutoFunError.SpecCorrupt x) {
					writer ~= "Spec ";
					writeName(writer, ctx, x.specName);
					writer ~= " does not have the expected content.";
				},
				(in Diag.AutoFunError.SpecFromWrongModule) {
					writer ~= "Spec for automatic function comes from unexpected module.";
				},
				(in Diag.AutoFunError.TypeNotFullyVisible) {
					writer ~= "This function can't be automatic because the type is not fully visible in this context.";
				},
				(in Diag.AutoFunError.WrongName) {
					writer ~= "Function needs a body. (An automatic function must be named '==', '<=>', or 'to'.)";
				},
				(in Diag.AutoFunError.WrongParams p) {
					writer ~= () {
						final switch (p.kind) {
							case AutoFunName.compare:
								return "'<=>' must take two parameters of the same type.";
							case AutoFunName.equals:
								return "'==' must take two parameters of the same type.";
							case AutoFunName.members:
								return "'members' must take no parameters.";
							case AutoFunName.to:
								return "'to' must take a single parameter.";
						}
					}();
				},
				(in Diag.AutoFunError.WrongParamType p) {
					writer ~= "An automatic function parameter must be a ";
					writeKeyword(writer, ctx, symbol!"record");
					writer ~= " or ";
					writeKeyword(writer, ctx, symbol!"union");
					writer ~= " type.";
				},
				(in Diag.AutoFunError.WrongReturnType p) {
					writer ~= () {
						final switch (p.kind) {
							case AutoFunName.compare:
								return "'<=>' must return 'comparison'.";
							case AutoFunName.equals:
								return "'==' must return 'bool'.";
							case AutoFunName.members:
								return "'members' must return an array of an 'enum' or 'flags' type.";
							case AutoFunName.to:
								return "'to' must be one of:\n" ~
									"\t'to json(a t)' where 't' is a enum, flags, record, or union type\n" ~
									"\t'to symbol(a e)' where 'e' is an enum type\n" ~
									"\t'to e?(a symbol)' where 'e' is an enum or flags type\n" ~
									"\t'to symbol[](a f)' where 'f' is a flags type\n";
						}
					}();
				});
		},
		(in Diag.BuiltinFunCantHaveBody x) {
			writer ~= "A 'builtin' function can't have a body.";
		},
		(in Diag.BuiltinUnsupported x) {
			writer ~= "Crow does not implement a builtin ";
			writer ~= stringOfEnum(x.kind);
			writer ~= " named ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(in Diag.CallMissingExtern x) {
			writer ~= "Function ";
			writeFunDecl(writer, ctx, WriteKind.quoted, x.callee);
			writer ~= " requires extern ";
			writeName(writer, ctx, x.missingExtern);
			writer ~= ", but that is not in scope.";
		},
		(in Diag.CallMultipleMatches x) {
			writer ~= "Cannot choose an overload of ";
			writeName(writer, ctx, x.funName);
			writer ~= ". Multiple functions match:";
			writeCalledDecls(writer, ctx, x.typeContainer, x.matches);
		},
		(in Diag.CallNoMatch x) {
			writeCallNoMatch(writer, ctx, x);
		},
		(in Diag.CallShouldUseSyntax x) {
			writer ~= () {
				final switch (x.kind) {
					case Diag.CallShouldUseSyntax.Kind.for_break:
						return "Prefer to write a 'for' loop instead of calling 'for-break'.";
					case Diag.CallShouldUseSyntax.Kind.force:
						return "Prefer to write 'x!' instead of 'x.force'.";
					case Diag.CallShouldUseSyntax.Kind.for_loop:
						return "Prefer to write a 'for' loop instead of calling 'for-loop'.";
					case Diag.CallShouldUseSyntax.Kind.new_:
						switch (x.arity) {
							case 0:
								return "Prefer to write '()' instead of 'new'.";
							case 1:
								return "Prefer to write '(x,)' instead of 'x.new'.";
							default:
								return "Prefer to write 'x, y' instead of 'x new y'.";
						}
					case Diag.CallShouldUseSyntax.Kind.not:
						return "Prefer to write '!x' instead of 'x.not'";
					case Diag.CallShouldUseSyntax.Kind.set_subscript:
						return "Prefer to write 'x[i] := y' instead of 'x set-subscript i, y'.";
					case Diag.CallShouldUseSyntax.Kind.subscript:
						return "Prefer to write 'x[i]' instead of 'x subscript i'.";
					case Diag.CallShouldUseSyntax.Kind.with_block:
						return "Prefer to write a 'with' block instead of calling 'with-block'.";
				}
			}();
		},
		(in Diag.CantCall x) {
			writer ~= () {
				final switch (x.reason) {
					case Diag.CantCall.Reason.nonBare:
						return "A 'bare' function can't call non-'bare' function";
					case Diag.CantCall.Reason.summon:
						return "A non-'summon' function can't call 'summon' function";
					case Diag.CantCall.Reason.summonInDataLambda:
						return "Can't call a 'summon' function from inside a 'data' lambda.";
					case Diag.CantCall.Reason.unsafe:
						return "A non-'unsafe' function can't call 'unsafe' function";
					case Diag.CantCall.Reason.variadicFromBare:
						return "A 'bare' function can't call variadic function";
				}
			}();
			writer ~= ' ';
			writeFunDecl(writer, ctx, WriteKind.quoted, x.callee);
			writer ~= '.';
			if (x.reason == Diag.CantCall.Reason.unsafe)
				writer ~= "\n(Consider putting the call in a 'trusted' expression.)";
		},
		(in Diag.CharLiteralMustBeOneChar) {
			writer ~= "Value of 'char' type must be a single character";
		},
		(in Diag.CommonFunDuplicate x) {
			writer ~= "Module contains multiple valid ";
			writeName(writer, ctx, x.name);
			writer ~= " functions.";
		},
		(in Diag.CommonFunMissing x) {
			writer ~= "Module should have a function:\n\t";
			writeWithSeparator!TypeParamsAndSig(writer, x.sigChoices, "\nOr:\n\t", (in TypeParamsAndSig sig) {
				writeSigSimple(writer, ctx, TypeContainer(x.dummyForContext), x.dummyForContext.name, sig);
			});
		},
		(in Diag.CommonTypeMissing x) {
			writer ~= "Expected to find a type named ";
			writeName(writer, ctx, x.name);
			writer ~= " in this module.";
		},
		(in Diag.CommonVarMissing x) {
			writer ~= "Expected to find a ";
			writer ~= stringOfEnum(x.varKind);
			writer ~= " named ";
			writeName(writer, ctx, x.name);
			writer ~= " in this module.";
		},
		(in Diag.DestructureTypeMismatch x) {
			x.expected.matchIn!void(
				(in Diag.DestructureTypeMismatch.Expected.Tuple t) {
					writer ~= "Expected a tuple with ";
					writer ~= t.size;
					writer ~= " elements, but got ";
				},
				(in TypeWithContainer t) {
					writer ~= "Expected type ";
					writeTypeQuoted(writer, ctx, t);
					writer ~= ", but got ";
				});
			writeTypeQuoted(writer, ctx, x.actual);
			writer ~= '.';
		},
		(in Diag.DuplicateDeclaration x) {
			writer ~= () {
				final switch (x.kind) {
					case Diag.DuplicateDeclaration.Kind.enumMember:
						return "Enum member";
					case Diag.DuplicateDeclaration.Kind.flagsMember:
						return "Flags member";
					case Diag.DuplicateDeclaration.Kind.paramOrLocal:
						return "Local";
					case Diag.DuplicateDeclaration.Kind.recordField:
						return "Record field";
					case Diag.DuplicateDeclaration.Kind.spec:
						return "Spec";
					case Diag.DuplicateDeclaration.Kind.structOrAlias:
						return "Type";
					case Diag.DuplicateDeclaration.Kind.typeParam:
						return "Type parameter";
					case Diag.DuplicateDeclaration.Kind.unionMember: // still used? ------------------------------------------------------
						return "Union member";
				}
			}();
			writer ~= " name ";
			writeName(writer, ctx, x.name);
			writer ~= " is already used.";
		},
		(in Diag.DuplicateExports x) {
			writer ~= "There are multiple exported ";
			writer ~= () {
				final switch (x.kind) {
					case Diag.DuplicateExports.Kind.spec:
						return "specs";
					case Diag.DuplicateExports.Kind.type:
						return "types";
				}
			}();
			writer ~= " named ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(in Diag.DuplicateImportName x) {
			writeName(writer, ctx, x.name);
			writer ~= " is imported twice from the same module.";
		},
		(in Diag.DuplicateImports x) {
			//TODO: use x.kind
			writer ~= "The symbol ";
			writeName(writer, ctx, x.name);
			writer ~= " appears in multiple modules.";
		},
		(in Diag.EmptyEnumOrUnion x) {
			writer ~= "An enum or union type must have at least one member.";
		},
		(in Diag.EnumBackingTypeInvalid x) {
			writer ~= "Type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.actual, TypeContainer(x.enum_)));
			writer ~= " cannot be used to back an enum.";
		},
		(in Diag.EnumDuplicateValue x) {
			writer ~= "Duplicate enum value ";
			if (x.signed)
				writer ~= x.value;
			else
				writer ~= cast(ulong) x.value;
			writer ~= '.';
		},
		(in Diag.ExpectedTypeIsNotALambda x) {
			if (has(x.expectedType)) {
				writer ~= "The expected type at the lambda is ";
				writeTypeQuoted(writer, ctx, force(x.expectedType));
				writer ~= ", which is not a lambda type.";
			} else
				writer ~= "There is no expected type at this location; lambdas need an expected type.";
		},
		(in Diag.ExternBodyMultiple x) {
			writer ~= "This function has multiple 'extern' modifiers, so it's ambiguous which to use for the body.";
		},
		(in Diag.ExternInvalidName x) {
			writeName(writer, ctx, x.name);
			writer ~= " is not a builtin extern name and is not configured in 'crow-config.json'";
		},
		(in Diag.ExternIsUnsafe x) {
			writer ~= "An 'extern' expression can only appear in an 'unsafe' or 'trusted' context.";
		},
		(in Diag.ExternRedundant x) {
			writer ~= "Extern ";
			writeName(writer, ctx, x.name);
			writer ~= " is already in scope, so this expression is always 'true'.";
		},
		(in Diag.ExternFunVariadic) {
			writer ~= "An 'extern' function can't be variadic.";
		},
		(in Diag.ExternHasUnnecessaryLibraryName) {
			writer ~= "'extern' for a type does not need the library name.";
		},
		(in Diag.ExternMissingLibraryName) {
			writer ~= "Expected 'extern' to be preceded by the library name.";
		},
		(in Diag.ExternRecordImplicitlyByVal x) {
			writer ~= "'extern' record ";
			writeName(writer, ctx, x.struct_.name);
			writer ~= " is implicitly 'by-val'.";
		},
		(in Diag.ExternTypeError x) {
			writer ~= () {
				final switch (x.reason) {
					case Diag.ExternTypeError.Reason.alignmentIsDefault:
						return "Alignment value is the default and can be omitted.";
					case Diag.ExternTypeError.Reason.badAlignment:
						return "Alignment must be 1, 2, 4, or 8.";
					case Diag.ExternTypeError.Reason.tooBig:
						return "Type size is too big.";
				}
			}();
		},
		(in Diag.ExternUnion) {
			writer ~= "A union can't be 'extern'.";
		},
		(in Diag.FlagsSigned) {
			writer ~= "A 'flags' type can't use a signed storage type.";
		},
		(in Diag.FunctionWithSignatureNotFound x) {
			writer ~= "Could not find a function '";
			writer ~= x.name;
			writer ~= ' ';
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.returnAndParamTypes.returnType, x.typeContainer));
			writer ~= '(';
			writeWithCommas!Type(writer, x.returnAndParamTypes.paramTypes, (in Type t) {
				writer ~= "_ ";
				writeTypeUnquoted(writer, ctx, TypeWithContainer(t, x.typeContainer));
			});
			writer ~= ")'.";
		},
		(in Diag.FunPointerExprMustBeName) {
			writer ~= "Function pointer expression must be a plain identifier ('&f').";
		},
		(in Diag.FunPointerNotBare) {
			writer ~= "The target of a function pointer must be a 'bare' function.";
		},
		(in Diag.IfThrow) {
			writer ~= "Instead of throwing from a conditional expression, use 'assert' or 'forbid'.";
		},
		(in Diag.ImportFileDiag x) {
			x.matchIn!void(
				(in Diag.ImportFileDiag.CantImportCrowAsText y) {
					writer ~= "Can't import a '.crow' file as content.";
				},
				(in Diag.ImportFileDiag.CircularImport y) {
					writer ~= "This is part of a circular import:";
					foreach (Uri uri; y.cycle) {
						writeNewline(writer, 1);
						writeUri(writer, ctx, uri);
						writer ~= " imports";
					}
					writeNewline(writer, 1);
					writeUri(writer, ctx, y.cycle[0]);
				},
				(in Diag.ImportFileDiag.LibraryNotConfigured x) {
					writer ~= "Library ";
					writeName(writer, ctx, x.libraryName);
					writer ~= " is not configured.";
					writeNewline(writer, 0);
					writer ~= "It must be added to \"include\" in 'crow-config.json'.";
				},
				(in Diag.ImportFileDiag.ReadError y) {
					showReadFileDiag(writer, ctx, y.diag, some(y.uri));
				},
				(in Diag.ImportFileDiag.RelativeImportReachesPastRoot y) {
					writer ~= "Relative path ";
					writer ~= y.imported;
					writer ~= " reaches above the root directory.";
				});
		},
		(in Diag.ImportRefersToNothing x) {
			writer ~= "Imported name ";
			writeName(writer, ctx, x.name);
			writer ~= " does not refer to anything.";
		},
		(in Diag.LambdaCantBeFunctionPointer x) {
			writer ~= "A function pointer can't be implemented by a lambda. Write a function and use '&f' instead.";
		},
		(in Diag.LambdaCantInferParamType x) {
			writer ~= "Can't infer the lambda parameter's type.";
		},
		(in Diag.LambdaClosurePurity x) {
			writer ~= "Can't access ";
			writeName(writer, ctx, x.localName);
			writer ~= " in a ";
			writeKeyword(writer, ctx, stringOfEnum(x.lambdaKind));
			writer ~= " lambda because it is ";
			if (has(x.type)) {
				writer ~= "of ";
				writePurity(writer, ctx, x.localPurity);
				writer ~= " type ";
				writeTypeQuoted(writer, ctx, force(x.type));
			} else {
				writer ~= "a ";
				writeKeyword(writer, ctx, "mut");
				writer ~= " local";
			}
			writer ~= '.';
		},
		(in Diag.LambdaMultipleMatch x) {
			writer ~= "Multiple lambda types are possible:";
			writeTypesOnLines(writer, ctx, x.choices);
			writeNewline(writer, 0);
			writer ~= "Consider explicitly typing the lambda's parameter.";
		},
		(in Diag.LambdaNotExpected x) {
			if (x.expected.isA!(ExpectedForDiag.Infer))
				writer ~= "Lambda expression needs an expected type.";
			else {
				writer ~= "The lambda doesn't match the expected type at this location.";
				writeNewline(writer, 0);
				writeExpected(writer, ctx, x.expected, ExpectedKind.lambda);
			}
		},
		(in Diag.LambdaTypeMissingParamType) {
			writer ~= "Function type needs parameter types. " ~
				"(It is parsed a as a destructure, so it needs both parameter names and types.)";
		},
		(in Diag.LambdaTypeVariadic) {
			writer ~= "A function type can't be variadic; only a function can.";
		},
		(in Diag.LinkageWorseThanContainingFun x) {
			writer ~= "'extern' function ";
			writeName(writer, ctx, x.containingFun.name);
			if (has(x.param)) {
				Opt!Symbol paramName = force(x.param).name;
				if (has(paramName)) {
					writer ~= " parameter ";
					writeName(writer, ctx, force(paramName));
				}
			}
			writer ~= " can't reference non-extern type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.referencedType, TypeContainer(x.containingFun)));
			writer ~= '.';
		},
		(in Diag.LinkageWorseThanContainingType x) {
			writer ~= "Extern type ";
			writeName(writer, ctx, x.containingType.name);
			writer ~= " can't reference non-extern type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.referencedType, TypeContainer(x.containingType)));
			writer ~= '.';
		},
		(in Diag.LiteralFloatAccuracy x) {
			writer ~= "Literal of type '";
			writeName(writer, ctx, stringOfEnum(x.type));
			writer ~= "' will be rounded to ";
			writeFloatLiteral(writer, x.actual, infinity: "infinity", nan: "NaN");
		},
		(in Diag.LiteralMultipleMatch x) {
			writer ~= "Multiple possible types for literal expression: ";
			writeWithCommas!(StructInst*)(writer, x.types, (in StructInst* type) {
				writeStructInst(writer, ctx, x.typeContainer, *type);
			});
		},
		(in Diag.LiteralNotExpected x) {
			if (x.expected.isA!(ExpectedForDiag.Infer))
				writer ~= "Literal expression needs an expected type.";
			else {
				writer ~= "The literal doesn't match the expected type at this location.";
				writeNewline(writer, 0);
				writeExpected(writer, ctx, x.expected, ExpectedKind.lambda);
			}
		},
		(in Diag.LiteralOverflow x) {
			writer ~= "A value of type ";
			writeName(writer, ctx, stringOfEnum(x.type));
			writer ~= " must be from ";
			writer ~= minValue(x.type);
			writer ~= " to ";
			writer ~= maxValue(x.type);
			writer ~= '.';
		},
		(in Diag.LocalIgnoredButMutable) {
			writer ~= "Unnecessary 'mut' on ignored local variable.";
		},
		(in Diag.LocalNotMutable x) {
			writer ~= "Local variable ";
			writeName(writer, ctx, x.local.name);
			writer ~= " was not marked 'mut'.";
		},
		(in Diag.LoopDisallowedBody x) {
			writer ~= "Loop body cannot be a ";
			writeName(writer, ctx, stringOfEnum(x.kind));
			writer ~= " expression";
		},
		(in Diag.LoopWithoutBreak) {
			writer ~= "'loop' has no 'break'.";
		},
		(in Diag.MainMissingExterns x) {
			writer ~= "'main' function depends on extern ";
			writeWithCommas!Symbol(writer, x.missing, (in Symbol x) {
				writeName(writer, ctx, x);
			});
			writer ~= " which is not provided.";
		},
		(in Diag.MainTestMissing x) {
			writer ~= "There is no 'test' keyword on line ";
			writer ~= x.expectedLine + 1;
			writer ~= '.';
		},
		(in Diag.MatchCaseDuplicate x) {
			writer ~= "Duplicate branch ";
			x.kind.matchIn!void(
				(in Symbol x) {
					writeName(writer, ctx, x);
				},
				(in string x) {
					writeQuotedString(writer, x);
				},
				(in ulong x) {
					writer ~= x;
				},
				(in long x) {
					writer ~= x;
				});
		},
		(in Diag.MatchCaseForType x) {
			writer ~= () {
				final switch (x.kind) {
					case Diag.MatchCaseForType.Kind.enumOrUnion:
						return "To match an enum or union, branches must use identifiers.";
					case Diag.MatchCaseForType.Kind.numeric:
						return "To match a number, branches must use number literals.";
					case Diag.MatchCaseForType.Kind.stringLike:
						return "To match a string-like type, branches must use identifiers or string literals.";
				}
			}();
		},
		(in Diag.MatchCaseNameDoesNotMatch x) {
			bool isEnum = x.enum_.body_.isA!(StructBody.Enum*);
			writer ~= "Enum ";
			writeName(writer, ctx, x.enum_.name);
			writer ~= " has no member ";
			writer ~= x.actual;
			writer ~= ".\nThis should be one of: ";
			writeWithCommas!EnumOrFlagsMember(
				writer, x.enum_.body_.as!(StructBody.Enum*).members, (in EnumOrFlagsMember member) {
					writeName(writer, ctx, member.name);
				});
		},
		(in Diag.MatchCaseNoValueForEnumOrSymbol x) {
			writer ~= "Matching on ";
			if (has(x.enum_)) {
				writer ~= "enum ";
				writeName(writer, ctx, force(x.enum_).name);
			} else
				writeName(writer, ctx, symbol!"symbol");
			writer ~= ", so case should not expect a value.";
		},
		(in Diag.MatchCaseShouldUseIgnore x) {
			writer ~= "Variant member type ";
			writeName(writer, ctx, x.member.decl.name);
			writer ~= " is non-empty, so it should be explicitly ignored using ";
			writeName(writer, ctx, symbol!"_");
			writer ~= '.';
		},
		(in Diag.MatchNeedsElse x) {
			final switch (x.kind) {
				case Diag.MatchNeedsElse.Kind.variant:
					writer ~= "Match on a 'variant' must have an explicit 'else'.";
			}
		},
		(in Diag.MatchOnNonMatchable x) {
			writer ~= "Can only match on enum, union, variant, integral, symbol, string, or character type, not ";
			writeTypeQuoted(writer, ctx, x.type);
			writer ~= '.';
		},
		(in Diag.MatchUnhandledCases x) {
			writer ~= "'match' is missing ";
			size_t length = x.matchIn!size_t(
				(in EnumOrFlagsMember*[] xs) => xs.length,
				(in StructInst*[] xs) => xs.length);
			writer ~= (length == 1 ? "case" : "cases:");
			writer ~= ' ';
			x.matchIn!void(
				(in EnumOrFlagsMember*[] members) {
					writeWithCommas!(EnumOrFlagsMember*)(writer, members, (in EnumOrFlagsMember* member) {
						writeName(writer, ctx, member.name);
					});
				},
				(in StructInst*[] members) {
					writeWithCommas!(StructInst*)(writer, members, (in StructInst* member) {
						writeName(writer, ctx, member.decl.name);
					});
				});
			writer ~= '.';
		},
		(in Diag.MatchUnnecessaryElse x) {
			writer ~= "'match' handles every case, so the 'else' is unused.";
		},
		(in Diag.MatchVariantCantInferTypeArgs x) {
			writer ~= "Can't infer type arguments of ";
			writer ~= x.member.name;
		},
		(in Diag.MatchVariantNoMember x) {
			writer ~= "Type ";
			writeName(writer, ctx, x.nonMember.name);
			writer ~= " is not a member of variant ";
			writeTypeQuoted(writer, ctx, x.variant);
			writer ~= '.';
		},
		(in Diag.ModifierConflict x) {
			writeModifier(writer, ctx, x.curModifier);
			writer ~= " conflicts with ";
			writeModifier(writer, ctx, x.prevModifier);
			writer ~= '.';
		},
		(in Diag.ModifierDuplicate x) {
			writer ~= "Redundant ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= '.';
		},
		(in Diag.ModifierInvalid x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " can't be ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= '.';
			if (x.declKind == DeclKind.test && x.modifier == ModifierKeyword.unsafe)
				writer ~= " Did you mean 'trusted'?";
		},
		(in Diag.ModifierRedundantDueToDeclKind x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " is already ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= " by default.";
		},
		(in Diag.ModifierRedundantDueToModifier x) {
			writeModifier(writer, ctx, x.redundantModifier);
			writer ~= " is redundant given ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= '.';
		},
		(in Diag.ModifierTypeArgInvalid x) {
			writeModifier(writer, ctx, x.modifier);
			writer ~= " does not take a type argument in this context.";
		},
		(in Diag.MutFieldNotAllowed) {
			writer ~= "This field is 'mut', so the record must be 'mut'.";
		},
		(in Diag.NameNotFound x) {
			writer ~= "There is no ";
			writer ~= stringOfEnum(x.kind);
			writer ~= " in scope named ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(in Diag.NeedsExpectedType x) {
			writer ~= '\'';
			writer ~= stringOfEnum(x.kind);
			writer ~= "' expression needs an expected type.";
		},
		(in Diag.ParamMissingType) {
			writer ~= "This parameter needs a type.";
		},
		(in Diag.ParamMutable) {
			writer ~= "A parameter can't be mutable.";
		},
		(in ParseDiag x) {
			writeParseDiag(writer, ctx, x);
		},
		(in Diag.PointerIsNative) {
			writer ~= "Can only get a pointer in an 'extern native' context.";
		},
		(in Diag.PointerIsUnsafe) {
			writer ~= "Can only get a pointer in an 'unsafe' or 'trusted' context.";
		},
		(in Diag.PointerMutToConst x) {
			writer ~= () {
				final switch (x.kind) {
					case Diag.PointerMutToConst.Kind.fieldOfByRef:
						return "Can't get a 'mut' pointer to a non-'mut' field.";
					case Diag.PointerMutToConst.Kind.fieldOfByVal:
						return "Can't get a 'mut' field pointer from a non-'mut' record pointer.";
					case Diag.PointerMutToConst.Kind.local:
						return "Can't get a 'mut' pointer to a non-'mut' local.";
				}
			}();
		},
		(in Diag.PointerUnsupported x) {
			final switch (x.reason) {
				case Diag.PointerUnsupported.Reason.other:
					writer ~= "Can't get a pointer to this kind of expression.";
					break;
				case Diag.PointerUnsupported.Reason.recordNotByRef:
					writer ~= "To get a pointer to a record field, " ~
						"the record must be 'by-ref' or a pointer to a 'by-val' record.";
					break;
			}
		},
		(in Diag.PurityWorseThanParent x) {
			writer ~= "Type ";
			writeName(writer, ctx, x.parent.name);
			writer ~= " has purity ";
			writePurity(writer, ctx, x.parent.purity);
			writer ~= ", but member of type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.child, TypeContainer(x.parent)));
			writer ~= " has purity ";
			writePurity(writer, ctx, bestCasePurity(x.child));
			writer ~= '.';
		},
		(in Diag.PurityWorseThanVariant x) {
			writer ~= "Variant ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(Type(x.variant), TypeContainer(x.member)));
			writer ~= " has purity ";
			writePurity(writer, ctx, x.variant.purityRange.bestCase);
			writer ~= ", but member ";
			writeName(writer, ctx, x.member.name);
			writer ~= " has purity ";
			writePurity(writer, ctx, x.member.purity);
			writer ~= '.';
		},
		(in Diag.RecordFieldNeedsType x) {
			writer ~= "Record field ";
			writeName(writer, ctx, x.fieldName);
			writer ~= " needs a type.";
		},
		(in Diag.SharedArgIsNotLambda) {
			writer ~= "Argument to 'shared' must be a lambda expression.";
		},
		(in Diag.SharedLambdaTypeIsNotShared x) {
			writer ~= "'shared' lambda needs a 'shared' ";
			writer ~= () {
				final switch (x.kind) {
					case Diag.SharedLambdaTypeIsNotShared.Kind.paramType:
						return "parameter";
					case Diag.SharedLambdaTypeIsNotShared.Kind.returnType:
						return "return";
				}
			}();
			writer ~= " type, but it is ";
			writeTypeQuoted(writer, ctx, x.actual);
			writer ~= '.';
		},
		(in Diag.SharedLambdaUnused x) {
			writer ~= "The lambda does not have anything 'mut' in its closure, so it does not need 'shared'.";
		},
		(in Diag.SharedNotExpected x) {
			writer ~= () {
				final switch (x.reason) {
					case Diag.SharedNotExpected.Reason.notShared:
						return "Expected type is a lambda, but it is not 'shared'.";
				}
			}();
			writer ~= '\n';
			writeExpected(writer, ctx, x.expected, ExpectedKind.lambda);
		},
		(in Diag.SpecMatchError x) {
			x.reason.matchIn!void(
				(in Diag.SpecMatchError.Reason.MultipleMatches y) {
					writer ~= "Multiple implementations found for spec signature ";
					writeName(writer, ctx, y.sigName);
					writer ~= ':';
					writeCalleds(writer, ctx, x.outermostTypeContainer, y.matches);
				});
			writeNewline(writer, 1);
			writer ~= "Calling:";
			writeSpecTrace(writer, ctx, x.outermostTypeContainer, x.trace);
		},
		(in Diag.SpecNoMatch x) {
			x.reason.matchIn!void(
				(in Diag.SpecNoMatch.Reason.BuiltinNotSatisfied y) {
					writeTypeQuoted(writer, ctx, TypeWithContainer(y.type, x.outermostTypeContainer));
					writer ~= " is not '";
					writer ~= stringOfEnum(y.kind);
					writer ~= "'.";
				},
				(in Diag.SpecNoMatch.Reason.CantInferTypeArguments y) {
					writer ~= "Can't infer type arguments to ";
					writeFunDecl(writer, ctx, WriteKind.quoted, y.fun);
				},
				(in Diag.SpecNoMatch.Reason.SpecImplNotFound y) {
					writer ~= "No implementation was found for spec signature ";
					Signature* sig = y.sigDecl;
					writeSig(
						writer, ctx, WriteKind.quoted, x.outermostTypeContainer, sig.name, sig.returnType,
						Params(sig.params), some(y.sigType));
					writer ~= '.';
				},
				(in Diag.SpecNoMatch.Reason.TooDeep _) {
					writer ~= "Spec instantiation is too deep.";
				});
			if (!isEmpty(x.trace)) {
				writeNewline(writer, 1);
				writer ~= "Calling:";
				writeSpecTrace(writer, ctx, x.outermostTypeContainer, x.trace);
			}
		},
		(in Diag.SpecRecursion x) {
			writer ~= "Spec's parents tree is too deep.";
			writeNewline(writer, 1);
			writer ~= "Trace: ";
			writeWithCommas!(immutable SpecDecl*)(writer, x.trace, (in SpecDecl* spec) {
				writeName(writer, ctx, spec.name);
			});
		},
		(in Diag.SpecSigCantBeVariadic x) {
			writer ~= "A spec signature can't be variadic.";
		},
		(in Diag.SpecUseInvalid x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " can't have specs.";
		},
		(in Diag.StringLiteralInvalid x) {
			writer ~= () {
				final switch (x.reason) {
					case Diag.StringLiteralInvalid.Reason.cStringContainsNul:
						return "'c-string' literal can't contain '\\0'.";
					case Diag.StringLiteralInvalid.Reason.notExternJs:
						return "Cant' create a 'js-any' value without 'js extern'.";
					case Diag.StringLiteralInvalid.Reason.stringContainsNul:
						return "'string' literal can't contain '\\0'.";
					case Diag.StringLiteralInvalid.Reason.symbolContainsNul:
						return "'symbol' literal can't contain '\\0'.";
				}
			}();
		},
		(in Diag.StorageMissingType) {
			writer ~= "'storage' needs a type.";
		},
		(in Diag.StructParamsSyntaxError x) {
			final switch (x.reason) {
				case Diag.StructParamsSyntaxError.Reason.hasParamsAndFields:
					writer ~= aOrAnDeclKind(declKindOfStruct(x.struct_));
					writer ~= " can't have both parameter-style and indented fields.";
					break;
				case Diag.StructParamsSyntaxError.Reason.destructure:
					writer ~= aOrAnMemberKind(memberKindOfStruct(x.struct_));
					writer ~= " can't use destructuring.";
					break;
				case Diag.StructParamsSyntaxError.Reason.variadic:
					writer ~= aOrAnMemberKind(memberKindOfStruct(x.struct_));
					writer ~= " can't be variadic.";
					break;
			}
		},
		(in Diag.TestMissingBody) {
			writer ~= "This test needs a body.";
		},
		(in Diag.TrustedUnnecessary x) {
			writer ~= () {
				final switch (x.reason) {
					case Diag.TrustedUnnecessary.Reason.inTrusted:
						return "'trusted' expression is redundant inside another 'trusted' expression.";
					case Diag.TrustedUnnecessary.Reason.inUnsafeFunction:
						return "'trusted' expression is redundant inside an 'unsafe' function.";
					case Diag.TrustedUnnecessary.Reason.unused:
						return "There is no unsafe code in this expression; you could remove 'trusted'.";
				}
			}();
		},
		(in Diag.TupleTooBig x) {
			writer ~= "This tuple has ";
			writer ~= x.actual;
			writer ~= " elements; the maximum allowed is ";
			writer ~= x.maxAllowed;
		},
		(in Diag.TypeAnnotationUnnecessary x) {
			writer ~= "Type annotation is unnecessary; type ";
			writeTypeQuoted(writer, ctx, x.type);
			writer ~= " was already inferred.";
		},
		(in Diag.TypeConflict x) {
			writeExpected(writer, ctx, x.expected, ExpectedKind.generic);
			writeNewline(writer, 0);
			writer ~= "Actual: ";
			writeTypeQuoted(writer, ctx, x.actual);
			writer ~= '.';
		},
		(in Diag.TypeParamCantHaveTypeArgs) {
			writer ~= "Can't provide type arguments to a type parameter.";
		},
		(in Diag.TypeParamsUnsupported x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " can't have type parameters.";
		},
		(in Diag.TypeShouldUseSyntax x) {
			writer ~= () {
				final switch (x.kind) {
					case Diag.TypeShouldUseSyntax.Kind.array:
						return "Prefer to write 't[]' instead of 't array'.";
					case Diag.TypeShouldUseSyntax.Kind.funData:
						return "Prefer to write 'r data(x p)' instead of '(r, p) fun-data'.";
					case Diag.TypeShouldUseSyntax.Kind.funMut:
						return "Prefer to write 'r mut(x p)' instead of '(r, p) fun-mut'.";
					case Diag.TypeShouldUseSyntax.Kind.funPointer:
						return "Prefer to writer 'r function(x p)' instead of '(r, p) fun-pointer'.";
					case Diag.TypeShouldUseSyntax.Kind.funShared:
						return "Prefer to write 'r shared(x p)' instead of '(r, p) fun-shared'.";
					case Diag.TypeShouldUseSyntax.Kind.map:
						return "Prefer to write 'v[k]' instead of '(k, v) map'.";
					case Diag.TypeShouldUseSyntax.Kind.mutArray:
						return "Prefer to write 't mut[]' instead of 't mut-array'.";
					case Diag.TypeShouldUseSyntax.Kind.mutMap:
						return "Prefer to write 'v mut[k]' instead of '(k, v) mut-map'.";
					case Diag.TypeShouldUseSyntax.Kind.mutPointer:
						return "Prefer to write 't mut*' instead of 't mut-pointer'.";
					case Diag.TypeShouldUseSyntax.Kind.opt:
						return "Prefer to write 't?' instead of 't option'.";
					case Diag.TypeShouldUseSyntax.Kind.pointer:
						return "Prefer to write 't*' instead of 't const-pointer'.";
					case Diag.TypeShouldUseSyntax.Kind.sharedArray:
						return "Prefer to write 't shared[]' instead of 't shared-array'.";
					case Diag.TypeShouldUseSyntax.Kind.sharedMap:
						return "Prefer to write 'v shared[k]' instead of '(k, v) shared-map'.";
					case Diag.TypeShouldUseSyntax.Kind.tuple:
						return "Prefer to write '(t, u)' instead of '(t, u) tuple2'.";
				}
			}();
		},
		(in Diag.UnsupportedSyntax x) {
			writer ~= () {
				final switch (x.reason) {
					case Diag.UnsupportedSyntax.Reason.enumMemberMutability:
						return "An enum member can't be 'mut'.";
					case Diag.UnsupportedSyntax.Reason.enumMemberType:
						return "An enum member can't specify a type.";
				}
			}();
		},
		(in Diag.Unused x) {
			writeUnusedDiag(writer, ctx, x);
		},
		(in Diag.VarargsParamMustBeArray) {
			writer ~= "Variadic parameter must be an ";
			writeName(writer, ctx, symbol!"array");
			writer ~= '.';
		},
		(in Diag.VariantMemberIsTemplate x) {
			writeName(writer, ctx, x.member.name);
			writer ~= " can't be a 'variant-member' because it is a template.";
		},
		(in Diag.VariantMemberMissingVariant x) {
			writer ~= "'variant-member' needs a variant.";
		},
		(in Diag.VariantMemberMultiple x) {
			writer ~= "Type ";
			writeName(writer, ctx, x.member.name);
			writer ~= " can't declare itself a member of the same variant ";
			writeName(writer, ctx, x.variant.name);
			writer ~= " multiple times.";
		},
		(in Diag.VariantMemberOfNonVariant x) {
			writer ~= "Not a variant: ";
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.actual, TypeContainer(x.member)));
		},
		(in Diag.VariantMethodImplVisibility x) {
			writer ~= "A method of variant ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(Type(x.variant), TypeContainer(x.member)));
			writer ~= " is implemented by ";
			writeFunInst(writer, ctx, WriteKind.quoted, TypeContainer(x.member), *x.methodImpl);
			writer ~= ", but it is less visible than ";
			writeName(writer, ctx, x.member.name);
			writer ~= '.';
		},
		(in Diag.VisibilityWarning x) {
			writeVisibilityWarning(writer, ctx, x);
		},
		(in Diag.WithHasElse) {
			writeKeyword(writer, ctx, "with");
			writer ~= " statement can't have ";
			writeKeyword(writer, ctx, "else");
			writer ~= '.';
		},
		(in Diag.WrongNumberTypeArgs x) {
			writeName(writer, ctx, x.name);
			writer ~= " expected to get ";
			writer ~= x.nExpectedTypeArgs;
			writer ~= " type arguments, but got ";
			writer ~= x.nActualTypeArgs;
			writer ~= '.';
		});
}

void showDiagnostic(scope ref Writer writer, in ShowDiagCtx ctx, in UriAndDiagnostic a) {
	writeUriAndRange(writer, ctx, a.where);
	writer ~= ' ';
	writeDiag(writer, ctx, a.kind);
}

enum ExpectedKind {
	generic,
	lambda,
	return_,
}

void writeExpected(scope ref Writer writer, in ShowDiagCtx ctx, in ExpectedForDiag a, ExpectedKind kind) {
	void writeType() {
		if (kind == ExpectedKind.return_) writer ~= "return ";
		writer ~= "type";
	}
	a.matchIn!void(
		(in ExpectedForDiag.Choices choices) {
			if (choices.types.length == 1) {
				writer ~= "Expected ";
				writeType();
				writer ~= ' ';
				writeTypeQuoted(writer, ctx, TypeWithContainer(only(choices.types), choices.typeContainer));
				writer ~= '.';
			} else {
				writer ~= "Expected one of these ";
				writeType();
				writer ~= "s:";
				writeTypesOnLines(writer, ctx, choices);
			}
		},
		(in ExpectedForDiag.Infer) {
			writer ~= "This location has no expected ";
			writeType();
			writer ~= '.';
		},
		(in ExpectedForDiag.Loop) {
			writer ~= "Expected a loop 'break' or 'continue'.";
		});
}

void writeTypesOnLines(scope ref Writer writer, in ShowDiagCtx ctx, in ExpectedForDiag.Choices choices) {
	foreach (Type x; choices.types) {
		writeNewline(writer, 1);
		writeTypeQuoted(writer, ctx, TypeWithContainer(x, choices.typeContainer));
	}
}

void writeModifier(scope ref Writer writer, in ShowDiagCtx ctx, ModifierKeyword kind) {
	writeName(writer, ctx, stringOfModifierKeyword(kind));
}

DeclKind declKindOfStruct(StructDecl* a) =>
	a.body_.matchIn!DeclKind(
		(in StructBody.Bogus) =>
			assert(false),
		(in BuiltinType) =>
			assert(false),
		(in StructBody.Enum) =>
			DeclKind.enum_,
		(in StructBody.Extern) =>
			assert(false),
		(in StructBody.Flags) =>
			DeclKind.flags,
		(in StructBody.Record) =>
			DeclKind.record,
		(in StructBody.Variant) =>
			DeclKind.variant);

enum MemberKind { enumMember, flagsMember, recordField }
MemberKind memberKindOfStruct(StructDecl* a) =>
	a.body_.matchIn!MemberKind(
		(in StructBody.Bogus) =>
			assert(false),
		(in BuiltinType) =>
			assert(false),
		(in StructBody.Enum) =>
			MemberKind.enumMember,
		(in StructBody.Extern) =>
			assert(false),
		(in StructBody.Flags) =>
			MemberKind.flagsMember,
		(in StructBody.Record) =>
			MemberKind.recordField,
		(in StructBody.Variant) =>
			assert(false));

string aOrAnDeclKind(DeclKind a) {
	final switch (a) {
		case DeclKind.alias_:
			return "A type alias";
		case DeclKind.builtin:
			return "A builtin type";
		case DeclKind.enum_:
			return "An enum type";
		case DeclKind.extern_:
			return "An extern type";
		case DeclKind.externFunction:
			return "An extern function";
		case DeclKind.function_:
			return "A function";
		case DeclKind.global:
			return "A global variable";
		case DeclKind.flags:
			return "A flags type";
		case DeclKind.record:
			return "A record type";
		case DeclKind.spec:
			return "A spec";
		case DeclKind.test:
			return "A test";
		case DeclKind.threadLocal:
			return "A thread-local variable";
		case DeclKind.variant:
			return "An interface, union, or variant type";
	}
}

string aOrAnMemberKind(MemberKind a) {
	final switch (a) {
		case MemberKind.enumMember:
			return "An enum member";
		case MemberKind.flagsMember:
			return "A flags member";
		case MemberKind.recordField:
			return "A record field";
	}
}

void writeVisibilityWarning(scope ref Writer writer, in ShowDiagCtx ctx, in Diag.VisibilityWarning a) {
	if (a.actualVisibility > a.defaultVisibility) {
		a.kind.matchIn!void(
			(in Diag.VisibilityWarning.Kind.Field x) {
				writer ~= "Field ";
				writeName(writer, ctx, x.fieldName);
				writer ~= " should not be more visible than record ";
				writeName(writer, ctx, x.record.name);
				writer ~= " which is only ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= '.';
			},
			(in Diag.VisibilityWarning.Kind.FieldMutability x) {
				writer ~= "Field ";
				writeName(writer, ctx, x.fieldName);
				writer ~= " can't have ";
				writeVisibility(writer, ctx, a.actualVisibility);
				writer ~= " mutability when the field itself is ";
				writeVisibility(writer, ctx, a.defaultVisibility);
			},
			(in Diag.VisibilityWarning.Kind.New x) {
				writeName(writer, ctx, symbol!"new");
				writer ~= " function for record ";
				writeName(writer, ctx, x.record.name);
				writer ~= " should not have greater visibility than ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= " (derived from visibility of fields).";
			});
	} else {
		assert(a.actualVisibility == a.defaultVisibility);
		a.kind.matchIn!void(
			(in Diag.VisibilityWarning.Kind.Field x) {
				writer ~= "Fields of record ";
				writeName(writer, ctx, x.record.name);
				writer ~= " are already ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= " by default.";
			},
			(in Diag.VisibilityWarning.Kind.FieldMutability x) {
				writer ~= "Field ";
				writeName(writer, ctx, x.fieldName);
				writer ~= " mutability would already be ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= " by default.";
			},
			(in Diag.VisibilityWarning.Kind.New x) {
				writer ~= "The 'new' function for ";
				writeName(writer, ctx, x.record.name);
				writer ~= " is already ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= " by default (derived from visibility of fields).";
			});
	}
}

string describeTokenForUnexpected(Token token) {
	final switch (token) {
		case Token.alias_:
			return "Unexpected keyword 'alias'.";
		case Token.arrowAccess:
			return "Unexpected '->'.";
		case Token.arrowLambda:
			return "Unexpected '=>'.";
		case Token.as:
			return "Unexpected keyword 'as'.";
		case Token.assert_:
			return "Unexpected keyword 'assert'.";
		case Token.at:
			return "Unexpected '@'.";
		case Token.bang:
			return "Unexpected '!'.";
		case Token.bare:
			return "Unexpected keyword 'bare'.";
		case Token.break_:
			return "Unexpected keyword 'break'.";
		case Token.builtin:
			return "Unexpected keyword 'builtin'.";
		case Token.braceLeft:
			return "Unexpected '{'.";
		case Token.braceRight:
			return "Unexpected '}'.";
		case Token.bracketLeft:
			return "Unexpected '['.";
		case Token.bracketRight:
			return "Unexpected ']'.";
		case Token.byRef:
			return "Unexpected keyword 'by-ref'.";
		case Token.byVal:
			return "Unexpected keyword 'by-val'.";
		case Token.catch_:
			return "Unexpected keyword 'catch'.";
		case Token.colon:
			return "Unexpected ':'.";
		case Token.colon2:
			return "Unexpected '::'.";
		case Token.colonEqual:
			return "Unexpected ':='.";
		case Token.comma:
			return "Unexpected ','.";
		case Token.continue_:
			return "Unexpected keyword 'continue'.";
		case Token.data:
			return "Unexpected keyword 'data'.";
		case Token.do_:
			return "Unexpected keyword 'do'.";
		case Token.dot:
			return "Unexpected '.'.";
		case Token.dot3:
			return "Unexpected '...'.";
		case Token.elif:
			return "Unexpected keyword 'elif'.";
		case Token.else_:
			return "Unexpected keyword 'else'.";
		case Token.enum_:
			return "Unexpected keyword 'enum'.";
		case Token.export_:
			return "Unexpected keyword 'export'.";
		case Token.equal:
			return "Unexpected '='.";
		case Token.extern_:
			return "Unexpected keyword 'extern'.";
		case Token.endOfFile:
			return "Unexpected end of file.";
		case Token.finally_:
			return "Unexpected keyword 'finally'.";
		case Token.flags:
			return "Unexpected keyword 'flags'.";
		case Token.for_:
			return "Unexpected keyword 'for'.";
		case Token.forceShared:
			return "Unexpected keyword 'force-shared'.";
		case Token.forbid:
			return "Unexpected keyword 'forbid'.";
		case Token.forceCtx:
			return "Unexpected keyword 'force-ctx'.";
		case Token.function_:
			return "Unexpected keyword 'function'.";
		case Token.global:
			return "Unexpected keyword 'global'.";
		case Token.guard:
			return "Unexpected keyword 'guard'.";
		case Token.if_:
			return "Unexpected keyword 'if'.";
		case Token.import_:
			return "Unexpected keyword 'import'.";
		case Token.interface_:
			return "Unexpected keyword 'interface'.";
		case Token.literalFloat:
		case Token.literalIntegral:
			return "Unexpected number literal expression.";
		case Token.loop:
			return "Unexpected keyword 'loop'.";
		case Token.match:
			return "Unexpected keyword 'match'.";
		case Token.mut:
			return "Unexpected keyword 'mut'.";
		case Token.name:
			return "Did not expect a name here.";
		case Token.nameAfterBang:
			return "Did not expect a '!name' here.";
		case Token.nameBang:
			return "Did not expect a 'name!' here.";
		case Token.nameOrOperatorColonEquals:
			return "Did not expect a 'name:=' here.";
		case Token.nameOrOperatorEquals:
			return "Did not expect a 'name=' here.";
		case Token.newlineDedent:
		case Token.newlineIndent:
		case Token.newlineSameIndent:
			return "Unexpected newline.";
		case Token.nominal:
			return "Unexpected keyword 'nominal'.";
		case Token.noStd:
			return "Unexpected keyword 'no-std'.";
		case Token.operator:
			// This is UnexpectedOperator instead
			assert(false);
		case Token.packed:
			return "Unexpected keyword 'packed'.";
		case Token.parenLeft:
			return "Unexpected '('.";
		case Token.parenRight:
			return "Unexpected ')'.";
		case Token.pure_:
			return "Unexpected keyword 'pure'.";
		case Token.question:
			return "Unexpected '?'.";
		case Token.questionBracket:
			return "Unexpected '?['.";
		case Token.questionDot:
			return "Unexpected '?.'.";
		case Token.questionEqual:
			return "Unexpected '?='.";
		case Token.quoteBar:
			return "Unexpected '|'.";
		case Token.quoteDouble:
			return "Unexpected '\"'.";
		case Token.quoteDouble3:
			return "Unexpected '\"\"\"'.";
		case Token.quotedText:
			return "Unexpected string literal.";
		case Token.record:
			return "Unexpected keyword 'record'.";
		case Token.region:
			return "Unexpected keyword 'region'.";
		case Token.reserved:
			return "Unexpected reserved keyword.";
		case Token.semicolon:
			return "Unexpected ';'.";
		case Token.shared_:
			return "Unexpected keyword 'shared'.";
		case Token.spec:
			return "Unexpected keyword 'spec'.";
		case Token.storage:
			return "Unexpected keyword 'storage'.";
		case Token.summon:
			return "Unexpected keyword 'summon'.";
		case Token.test:
			return "Unexpected keyword 'test'.";
		case Token.thread_local:
			return "Unexpected keyword 'thread-local'.";
		case Token.throw_:
			return "Unexpected keyword 'throw'.";
		case Token.trusted:
			return "Unexpected keyword 'trusted'.";
		case Token.try_:
			return "Unexpected keyword 'try'.";
		case Token.underscore:
			return "Unexpected '_'.";
		case Token.unexpectedCharacter:
			// This is ParseDiag.UnexpectedCharacter instead
			assert(false);
		case Token.union_:
			return "Unexpected keyword 'union'.";
		case Token.unless:
			return "Unexpected keyword 'unless'.";
		case Token.unsafe:
			return "Unexpected keyword 'unsafe'.";
		case Token.until:
			return "Unexpected keyword 'until'.";
		case Token.variant:
			return "Unexpected keyword 'variant'.";
		case Token.variantMember:
			return "Unexpected keyword 'variant-member'.";
		case Token.while_:
			return "Unexpected keyword 'while'.";
		case Token.with_:
			return "Unexpected keyword 'with'.";
	}
}
