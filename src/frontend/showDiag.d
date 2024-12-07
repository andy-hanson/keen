module frontend.showDiag;

@safe @nogc pure nothrow:

import frontend.getDiagnosticSeverity : getDiagnosticSeverity;
import frontend.parse.lexer : Token;
import frontend.showModel :
	ShowCtx,
	ShowDiagCtx,
	showSumTypeKindUpperCase,
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
import model.model :
	arityMatches,
	AutoFunName,
	bestCasePurity,
	BuiltinType,
	CalledDecl,
	CantImportCrowAsText,
	CircularImport,
	DeclKind,
	DestructureExpectedTuple,
	Diag,
	DiagAliasNotAllowed,
	DiagAssertOrForbidMessageIsThrow,
	DiagAssignmentNotAllowed,
	DiagAutoFunBare,
	DiagAutoFunEnumOrFlagsToWrongStorage,
	DiagAutoFunParamNotSimple,
	DiagAutoFunSpecCorrupt,
	DiagAutoFunSpecFromWrongModule,
	DiagAutoFunTypeNotFullyVisible,
	DiagAutoFunWrongName,
	DiagAutoFunWrongParams,
	DiagAutoFunWrongParamType,
	DiagAutoFunWrongReturnType,
	DiagBuiltinFunCantHaveBody,
	DiagBuiltinUnsupported,
	DiagCallMissingExtern,
	DiagCallMultipleMatches,
	DiagCallNoMatch,
	DiagCallShouldUseSyntax,
	DiagCallShouldUseSyntaxKind,
	DiagCantCall,
	DiagCantCallReason,
	DiagCaseDuplicate,
	DiagCaseInvalidSumType,
	DiagCaseMissingType,
	DiagCaseTypeIsTemplate,
	DiagCharLiteralMustBeOneChar,
	DiagCommonFunDuplicate,
	DiagCommonFunMissing,
	DiagCommonTypeMissing,
	DiagCommonVarMissing,
	DiagDestructureTypeMismatch,
	DiagDuplicateDeclaration,
	DiagDuplicateDeclarationKind,
	DiagDuplicateExports,
	DiagDuplicateImportName,
	DiagDuplicateImports,
	DiagEmptyEnumOrUnion,
	DiagEnumBackingTypeInvalid,
	DiagEnumDuplicateValue,
	DiagExpectedTypeIsNotALambda,
	DiagExternBodyMultiple,
	DiagExternInvalidName,
	DiagExternIsUnsafe,
	DiagExternRedundant,
	DiagExternFunVariadic,
	DiagExternHasUnnecessaryLibraryName,
	DiagExternMissingLibraryName,
	DiagExternRecordImplicitlyByVal,
	DiagExternSumType,
	DiagExternTypeError,
	DiagFlagsSigned,
	DiagFunctionWithSignatureNotFound,
	DiagFunPointerExprMustBeName,
	DiagFunPointerNotBare,
	DiagIfThrow,
	DiagImportFile,
	DiagImportRefersToNothing,
	DiagLambdaCantBeFunctionPointer,
	DiagLambdaCantInferParamType,
	DiagLambdaClosurePurity,
	DiagLambdaMultipleMatch,
	DiagLambdaNotExpected,
	DiagLambdaTypeMissingParamType,
	DiagLambdaTypeVariadic,
	DiagLinkageWorseThanContainingFun,
	DiagLinkageWorseThanContainingType,
	DiagLiteralFloatAccuracy,
	DiagLiteralMultipleMatch,
	DiagLiteralNotExpected,
	DiagLiteralOverflow,
	DiagLocalIgnoredButMutable,
	DiagLocalNotMutable,
	DiagLoopDisallowedBody,
	DiagLoopWithoutBreak,
	DiagMainMissingExterns,
	DiagMainTestMissing,
	DiagMatchCaseDuplicate,
	DiagMatchCaseForType,
	DiagMatchCaseNameNotInEnum,
	DiagMatchCaseNoValueForEnumOrSymbol,
	DiagMatchCaseShouldUseIgnore,
	DiagMatchNeedsElse,
	DiagMatchOnNonMatchable,
	DiagMatchSumTypeCantInferTypeArgs,
	DiagMatchSumTypeNoMember,
	DiagMatchUnhandledCases,
	DiagMatchUnnecessaryElse,
	DiagMethodImplVisibility,
	DiagModifierConflict,
	DiagModifierDuplicate,
	DiagModifierInvalid,
	DiagModifierRedundantDueToDeclKind,
	DiagModifierRedundantDueToModifier,
	DiagModifierTypeArgInvalid,
	DiagMutFieldNotAllowed,
	DiagNameNotFound,
	DiagNeedsExpectedType,
	Diagnostic,
	DiagnosticSeverity,
	DiagParamMissingType,
	DiagParamMutable,
	DiagPointerIsNative,
	DiagPointerIsUnsafe,
	DiagPointerMutToConst,
	DiagPointerUnsupported,
	DiagPurityWorseThanParent,
	DiagPurityWorseThanSumType,
	DiagRecordFieldNeedsType,
	DiagSharedArgIsNotLambda,
	DiagSharedLambdaTypeIsNotShared,
	DiagSharedLambdaTypeIsNotSharedKind,
	DiagSharedLambdaUnused,
	DiagSharedNotExpected,
	DiagSpecMatchMultiple,
	DiagSpecNoMatch,
	DiagSpecRecursion,
	DiagSpecSigCantBeVariadic,
	DiagSpecUseInvalid,
	DiagStringLiteralInvalid,
	DiagStorageMissingType,
	DiagStructParamsSyntaxError,
	DiagStructParamsSyntaxErrorReason,
	DiagSumTypeListedMembersNonUnion,
	DiagTestMissingBody,
	DiagTrustedUnnecessary,
	DiagTupleTooBig,
	DiagTypeAnnotationUnnecessary,
	DiagTypeConflict,
	DiagTypeParamCantHaveTypeArgs,
	DiagTypeParamsUnsupported,
	DiagTypeShouldUseSyntax,
	DiagUnionMemberTypeParameter,
	DiagUnsupportedSyntax,
	DiagUnusedImport,
	DiagUnusedLocal,
	DiagUnusedPrivateDecl,
	DiagVarargsParamMustBeArray,
	DiagVisibilityWarning,
	DiagWithHasElse,
	DiagWrongNumberTypeArgs,
	eachDiagnostic,
	Enum,
	EnumOrFlagsMember,
	ExpectedForDiag,
	ExpectedForDiagChoices,
	ExpectedForDiagInfer,
	ExpectedForDiagLoop,
	ExternType,
	Flags,
	FunDeclAndTypeArgs,
	LibraryNotConfigured,
	maxValue,
	minValue,
	nTypeParams,
	Params,
	ProgramWithOptMain,
	ReadError,
	Record,
	RelativeImportReachesPastRoot,
	Signature,
	SpecBuiltinNotSatisfied,
	SpecCantInferTypeArgs,
	SpecImplNotFound,
	SpecTooDeep,
	SpecDecl,
	StructBodyBogus,
	StructDecl,
	StructInst,
	SumType,
	Type,
	TypeContainer,
	TypeParamsAndSig,
	TypeWithContainer,
	UriAndDiagnostic,
	VisibilityWarningField,
	VisibilityWarningFieldMutability,
	VisibilityWarningNew;
import model.parseDiag :
	ParseDiag,
	ParseDiagDocCommentUnused,
	ParseDiagExpected,
	ParseDiagFileNotUtf8,
	ParseDiagImportFileTypeNotSupported,
	ParseDiagIndentNotDivisible,
	ParseDiagIndentTooMuch,
	ParseDiagIndentWrongCharacter,
	ParseDiagInvalidStringEscape,
	ParseDiagMatchCaseInterpolated,
	ParseDiagMissingInterpolated,
	ParseDiagNeedsBlockCtx,
	ParseDiagnostic,
	ParseDiagTrailingComma,
	ParseDiagTypeEmptyParens,
	ParseDiagTypeTrailingMut,
	ParseDiagTypeUnnecessaryParens,
	ParseDiagUnexpectedCharacter,
	ParseDiagUnexpectedOperator,
	ParseDiagUnexpectedToken,
	ReadFileDiag;
import model.sourceRange : compareRange;
import util.alloc.alloc : Alloc;
import util.col.array : contains, exists, isEmpty, only;
import util.col.arrayBuilder : arrayBuilderSort, buildArray, Builder;
import util.col.multiMap : makeMultiMap, MultiMap, MultiMapCb;
import util.col.sortUtil : sorted;
import util.comparison : Comparison;
import util.opt : force, has, none, Opt, some;
import util.symbol : Symbol, symbol;
import util.uri : baseName, compareUriNaturally, Uri;
import util.util : stringOfEnum, max;
import util.writer :
	makeStringWithWriter,
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

void writeParseDiag(scope ref Writer writer, in ShowCtx ctx, in ParseDiag d) {
	d.matchIn!void(
		(in ParseDiagDocCommentUnused _) {
			writer ~= "Doc comment must appear at top of module or before a declaration.";
		},
		(in ParseDiagExpected x) {
			writer ~= showParseDiagExpected(x);
		},
		(in ParseDiagFileNotUtf8 _) {
			writer ~= "File is not encoded as UTF-8 or has encoding errors.";
		},
		(in ParseDiagImportFileTypeNotSupported _) {
			writer ~= "Import file type not allowed; the only supported types are 'nat8 array' and 'string'.";
		},
		(in ParseDiagIndentNotDivisible d) {
			writer ~= "Expected indentation by ";
			writer ~= d.nSpacesPerIndent;
			writer ~= " spaces per level, but got ";
			writer ~= d.nSpaces;
			writer ~= " which is not divisible.";
		},
		(in ParseDiagIndentTooMuch x) {
			writer ~= "Indented too far.";
		},
		(in ParseDiagIndentWrongCharacter d) {
			writer ~= "Expected indentation by ";
			writer ~= d.expectedTabs ? "tabs" : "spaces";
			writer ~= " (based on first indented line), but here there is a ";
			writer ~= d.expectedTabs ? "space" : "tab.";
		},
		(in ParseDiagInvalidStringEscape x) {
			writer ~= "Invalid escape sequence '";
			writer ~= x.actual;
			writer ~= "'.";
		},
		(in ParseDiagMatchCaseInterpolated _) {
			writer ~= "'match' only works with literal strings, not interpolated strings.";
		},
		(in ParseDiagMissingInterpolated x) {
			writer ~= "Expected something inside of the '{}'.";
		},
		(in ParseDiagNeedsBlockCtx x) {
			if (x == ParseDiagNeedsBlockCtx.lambda)
				writer ~= "Lambda";
			else {
				writer ~= '\'';
				writer ~= stringOfEnum(x);
				writer ~= '\'';
			}
			writer ~= " expression must appear in a context where it can be followed by an indented block.";
		},
		(in ReadFileDiag x) {
			showReadFileDiag(writer, ctx, x, none!Uri);
		},
		(in ParseDiagTrailingComma _) {
			writer ~= "Remove this trailing comma.";
		},
		(in ParseDiagTypeEmptyParens _) {
			writer ~= "'()' is not a type. Did you mean 'void'?";
		},
		(in ParseDiagTypeTrailingMut _) {
			writer ~= "To make something mutable, put 'mut' after its name, not after its type.";
		},
		(in ParseDiagTypeUnnecessaryParens _) {
			writer ~= "Parentheses are unnecessary.";
		},
		(in ParseDiagUnexpectedCharacter x) {
			writer ~= "Unexpected character ";
			writeQuotedChar(writer, x.character);
			writer ~= " (U+";
			writeHex(writer, x.character, minDigits: 4);
			writer ~= ").";
		},
		(in ParseDiagUnexpectedOperator x) {
			writer ~= "Unexpected '";
			writer ~= x.operator;
			writer ~= "'.";
		},
		(in ParseDiagUnexpectedToken u) {
			writer ~= describeTokenForUnexpected(u.token);
		});
}

string showParseDiagExpected(ParseDiagExpected kind) {
	final switch (kind) {
		case ParseDiagExpected.as:
			return "Expected 'as'.";
		case ParseDiagExpected.blockCommentEnd:
			return "Expected '###' (then a newline).";
		case ParseDiagExpected.catch_:
			return "Expected 'catch'.";
		case ParseDiagExpected.closeInterpolated:
			return "Expected '}'.";
		case ParseDiagExpected.closingBracket:
			return "Expected ']'.";
		case ParseDiagExpected.closingParen:
			return "Expected ')'.";
		case ParseDiagExpected.colon:
			return "Expected ':'.";
		case ParseDiagExpected.comma:
			return "Expected ','.";
		case ParseDiagExpected.dedent:
			return "Expected a dedent.";
		case ParseDiagExpected.endOfLine:
			return "Expected end of line.";
		case ParseDiagExpected.equals:
			return "Expected '='.";
		case ParseDiagExpected.indent:
			return "Expected an indent.";
		case ParseDiagExpected.lambdaArrow:
			return "Expected ' =>' after lambda parameters.";
		case ParseDiagExpected.less:
			return "Expected '<'.";
		case ParseDiagExpected.literalIntegral:
			return "Expected an integer.";
		case ParseDiagExpected.literalNat:
			return "Expected a natural number.";
		case ParseDiagExpected.matchCase:
			return "A branch of a 'match' must be an identifier, number literal, or string literal.";
		case ParseDiagExpected.name:
			return "Expected a name (non-operator).";
		case ParseDiagExpected.namedArgument:
			return "Expected another named argument.";
		case ParseDiagExpected.nameOrOperator:
			return "Expected a name or operator.";
		case ParseDiagExpected.newline:
			return "Expected a newline.";
		case ParseDiagExpected.newlineOrDedent:
			return "Expected a newline or dedent.";
		case ParseDiagExpected.openParen:
			return "Expected '('.";
		case ParseDiagExpected.questionEqual:
			return "Expected '?='.";
		case ParseDiagExpected.quoteDouble:
			return "Expected '\"'.";
		case ParseDiagExpected.quoteDouble3:
			return "Expected '\"\"\"'.";
		case ParseDiagExpected.slash:
			return "Expected '/'.";
		case ParseDiagExpected.typeArgsEnd:
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

void writeCallNoMatch(scope ref Writer writer, in ShowDiagCtx ctx, in DiagCallNoMatch d) {
	bool someCandidateHasCorrectNTypeArgs =
		d.actualNTypeArgs == 0 ||
		exists!CalledDecl(d.allCandidates, (in CalledDecl c) =>
			nTypeParams(c) == 1 || nTypeParams(c) == d.actualNTypeArgs);
	bool someCandidateHasCorrectArity =
		exists!CalledDecl(d.allCandidates, (in CalledDecl c) =>
			(d.actualNTypeArgs == 0 || nTypeParams(c) == d.actualNTypeArgs) &&
			arityMatches(c.arity, d.actualArity));

	if (isEmpty(d.allCandidates))
		writeCallNoCandidates(writer, ctx, d);
	else if (!someCandidateHasCorrectArity)
		writeCallNoCorrectArity(writer, ctx, d, someCandidateHasCorrectNTypeArgs);
	else
		writeCallCloseMatch(writer, ctx, d);
}

void writeCallNoCandidates(scope ref Writer writer, in ShowDiagCtx ctx, in DiagCallNoMatch d) {
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
}

void writeCallNoCorrectArity(
	scope ref Writer writer,
	in ShowDiagCtx ctx,
	in DiagCallNoMatch d,
	bool someCandidateHasCorrectNTypeArgs,
) {
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
}

void writeCallCloseMatch(scope ref Writer writer, in ShowDiagCtx ctx, in DiagCallNoMatch d) {
	writer ~= "There are functions named ";
	writeName(writer, ctx, d.funName);
	writer ~= ", but they do not match the ";
	bool hasRet = d.expectedReturnType.isA!ExpectedForDiagChoices;
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

void writeDiag(scope ref Writer writer, in ShowDiagCtx ctx, in Diag diag) {
	diag.matchIn!void(
		(in DiagAliasNotAllowed _) {
			writer ~= "An alias is not allowed to reference another alias in the same module.";
		},
		(in DiagAssertOrForbidMessageIsThrow _) {
			writer ~= "The expression after the ':' for an assert or forbid is always thrown; it doesn't need 'throw'.";
		},
		(in DiagAssignmentNotAllowed _) {
			writer ~= "Can't assign to this kind of expression.";
		},
		(in DiagAutoFunBare _) {
			writer ~= "Automatic 'to json' can't be 'bare'.";
		},
		(in DiagAutoFunEnumOrFlagsToWrongStorage x) {
			writer ~= "Type ";
			writeName(writer, ctx, x.enumOrFlagsType.name);
			writer ~= " has storage type ";
			writeName(writer, ctx, stringOfEnum(x.actualStorageType));
			writer ~= ", not ";
			writeName(writer, ctx, stringOfEnum(x.expectedStorageType));
		},
		(in DiagAutoFunParamNotSimple _) {
			writer ~= "An auto fun must have simple parameters (not ignored or destructured).";
		},
		(in DiagAutoFunSpecCorrupt x) {
			writer ~= "Spec ";
			writeName(writer, ctx, x.specName);
			writer ~= " does not have the expected content.";
		},
		(in DiagAutoFunSpecFromWrongModule _) {
			writer ~= "Spec for automatic function comes from unexpected module.";
		},
		(in DiagAutoFunTypeNotFullyVisible _) {
			writer ~= "This function can't be automatic because the type is not fully visible in this context.";
		},
		(in DiagAutoFunWrongName _) {
			writer ~= "Function needs a body. (An automatic function must be named '==', '<=>', or 'to'.)";
		},
		(in DiagAutoFunWrongParams x) {
			writer ~= () {
				final switch (x.kind) {
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
		(in DiagAutoFunWrongParamType _) {
			writer ~= "An automatic function parameter must be a ";
			writeKeyword(writer, ctx, symbol!"record");
			writer ~= " or ";
			writeKeyword(writer, ctx, symbol!"union");
			writer ~= " type.";
		},
		(in DiagAutoFunWrongReturnType x) {
			writer ~= () {
				final switch (x.kind) {
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
		},
		(in DiagBuiltinFunCantHaveBody x) {
			writer ~= "A 'builtin' function can't have a body.";
		},
		(in DiagBuiltinUnsupported x) {
			writer ~= "Crow does not implement a builtin ";
			writer ~= stringOfEnum(x.kind);
			writer ~= " named ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(in DiagCallMissingExtern x) {
			writer ~= "Function ";
			writeFunDecl(writer, ctx, WriteKind.quoted, x.callee);
			writer ~= " requires extern ";
			writeName(writer, ctx, x.missingExtern);
			writer ~= ", but that is not in scope.";
		},
		(in DiagCallMultipleMatches x) {
			writer ~= "Cannot choose an overload of ";
			writeName(writer, ctx, x.funName);
			writer ~= ". Multiple functions match:";
			writeCalledDecls(writer, ctx, x.typeContainer, x.matches);
		},
		(in DiagCallNoMatch x) {
			writeCallNoMatch(writer, ctx, x);
		},
		(in DiagCallShouldUseSyntax x) {
			writer ~= () {
				final switch (x.kind) {
					case DiagCallShouldUseSyntaxKind.for_break:
						return "Prefer to write a 'for' loop instead of calling 'for-break'.";
					case DiagCallShouldUseSyntaxKind.force:
						return "Prefer to write 'x!' instead of 'x.force'.";
					case DiagCallShouldUseSyntaxKind.for_loop:
						return "Prefer to write a 'for' loop instead of calling 'for-loop'.";
					case DiagCallShouldUseSyntaxKind.new_:
						switch (x.arity) {
							case 0:
								return "Prefer to write '()' instead of 'new'.";
							case 1:
								return "Prefer to write '(x,)' instead of 'x.new'.";
							default:
								return "Prefer to write 'x, y' instead of 'x new y'.";
						}
					case DiagCallShouldUseSyntaxKind.not:
						return "Prefer to write '!x' instead of 'x.not'";
					case DiagCallShouldUseSyntaxKind.set_subscript:
						return "Prefer to write 'x[i] := y' instead of 'x set-subscript i, y'.";
					case DiagCallShouldUseSyntaxKind.subscript:
						return "Prefer to write 'x[i]' instead of 'x subscript i'.";
					case DiagCallShouldUseSyntaxKind.with_block:
						return "Prefer to write a 'with' block instead of calling 'with-block'.";
				}
			}();
		},
		(in DiagCantCall x) {
			writer ~= () {
				final switch (x.reason) {
					case DiagCantCallReason.nonBare:
						return "A 'bare' function can't call non-'bare' function";
					case DiagCantCallReason.summon:
						return "A non-'summon' function can't call 'summon' function";
					case DiagCantCallReason.summonInDataLambda:
						return "Can't call a 'summon' function from inside a 'data' lambda.";
					case DiagCantCallReason.unsafe:
						return "A non-'unsafe' function can't call 'unsafe' function";
					case DiagCantCallReason.variadicFromBare:
						return "A 'bare' function can't call variadic function";
				}
			}();
			writer ~= ' ';
			writeFunDecl(writer, ctx, WriteKind.quoted, x.callee);
			writer ~= '.';
			if (x.reason == DiagCantCallReason.unsafe)
				writer ~= "\n(Consider putting the call in a 'trusted' expression.)";
		},
		(in DiagCaseDuplicate x) {
			writer ~= "Type ";
			writeName(writer, ctx, x.member.name);
			writer ~= " can't be declared a case of ";
			writeName(writer, ctx, x.sumType.name);
			writer ~= " multiple times.";
		},
		(in DiagCaseInvalidSumType x) {
			writer ~= "'case' requires an 'interface' or 'variant' type, not ";
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.actual, TypeContainer(x.member)));
			writer ~= '.';
		},
		(in DiagCaseMissingType x) {
			writer ~= "'case' needs a type argument. It should be an 'interface' or 'variant' type.";
		},
		(in DiagCaseTypeIsTemplate x) {
			writeName(writer, ctx, x.caseType.name);
			writer ~= " can't be a 'case' because it is a template.";
		},
		(in DiagCharLiteralMustBeOneChar _) {
			writer ~= "Value of 'char' type must be a single character";
		},
		(in DiagCommonFunDuplicate x) {
			writer ~= "Module contains multiple valid ";
			writeName(writer, ctx, x.name);
			writer ~= " functions.";
		},
		(in DiagCommonFunMissing x) {
			writer ~= "Module should have a function:\n\t";
			writeWithSeparator!TypeParamsAndSig(writer, x.sigChoices, "\nOr:\n\t", (in TypeParamsAndSig sig) {
				writeSigSimple(writer, ctx, TypeContainer(x.dummyForContext), x.dummyForContext.name, sig);
			});
		},
		(in DiagCommonTypeMissing x) {
			writer ~= "Expected to find a type named ";
			writeName(writer, ctx, x.name);
			writer ~= " in this module.";
		},
		(in DiagCommonVarMissing x) {
			writer ~= "Expected to find a ";
			writer ~= stringOfEnum(x.varKind);
			writer ~= " named ";
			writeName(writer, ctx, x.name);
			writer ~= " in this module.";
		},
		(in DiagDestructureTypeMismatch x) {
			x.expected.matchIn!void(
				(in DestructureExpectedTuple t) {
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
		(in DiagDuplicateDeclaration x) {
			writer ~= () {
				final switch (x.kind) {
					case DiagDuplicateDeclarationKind.enumMember:
						return "Enum member";
					case DiagDuplicateDeclarationKind.flagsMember:
						return "Flags member";
					case DiagDuplicateDeclarationKind.paramOrLocal:
						return "Local";
					case DiagDuplicateDeclarationKind.recordField:
						return "Record field";
					case DiagDuplicateDeclarationKind.spec:
						return "Spec";
					case DiagDuplicateDeclarationKind.structOrAlias:
						return "Type";
					case DiagDuplicateDeclarationKind.typeParam:
						return "Type parameter";
					case DiagDuplicateDeclarationKind.unionMember:
						return "Union case";
				}
			}();
			writer ~= " name ";
			writeName(writer, ctx, x.name);
			writer ~= " is already used.";
		},
		(in DiagDuplicateExports x) {
			writer ~= "There are multiple exported ";
			writer ~= stringOfEnum(x.kind);
			writer ~= " named ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(in DiagDuplicateImportName x) {
			writeName(writer, ctx, x.name);
			writer ~= " is imported twice from the same module.";
		},
		(in DiagDuplicateImports x) {
			//TODO: use x.kind
			writer ~= "The symbol ";
			writeName(writer, ctx, x.name);
			writer ~= " appears in multiple modules.";
		},
		(in DiagEmptyEnumOrUnion x) {
			writer ~= "An enum or union type must have at least one member.";
		},
		(in DiagEnumBackingTypeInvalid x) {
			writer ~= "Type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.actual, TypeContainer(x.enum_)));
			writer ~= " cannot be used to back an enum.";
		},
		(in DiagEnumDuplicateValue x) {
			writer ~= "Duplicate enum value ";
			if (x.signed)
				writer ~= x.value;
			else
				writer ~= cast(ulong) x.value;
			writer ~= '.';
		},
		(in DiagExpectedTypeIsNotALambda x) {
			if (has(x.expectedType)) {
				writer ~= "The expected type at the lambda is ";
				writeTypeQuoted(writer, ctx, force(x.expectedType));
				writer ~= ", which is not a lambda type.";
			} else
				writer ~= "There is no expected type at this location; lambdas need an expected type.";
		},
		(in DiagExternBodyMultiple x) {
			writer ~= "This function has multiple 'extern' modifiers, so it's ambiguous which to use for the body.";
		},
		(in DiagExternInvalidName x) {
			writeName(writer, ctx, x.name);
			writer ~= " is not a builtin extern name and is not configured in 'crow-config.json'";
		},
		(in DiagExternIsUnsafe x) {
			writer ~= "An 'extern' expression can only appear in an 'unsafe' or 'trusted' context.";
		},
		(in DiagExternRedundant x) {
			writer ~= "Extern ";
			writeName(writer, ctx, x.name);
			writer ~= " is already in scope, so this expression is always 'true'.";
		},
		(in DiagExternFunVariadic _) {
			writer ~= "An 'extern' function can't be variadic.";
		},
		(in DiagExternHasUnnecessaryLibraryName _) {
			writer ~= "'extern' for a type does not need the library name.";
		},
		(in DiagExternMissingLibraryName _) {
			writer ~= "Expected 'extern' to be preceded by the library name.";
		},
		(in DiagExternRecordImplicitlyByVal x) {
			writer ~= "'extern' record ";
			writeName(writer, ctx, x.struct_.name);
			writer ~= " is implicitly 'by-val'.";
		},
		(in DiagExternSumType _) {
			writer ~= "An 'interface', 'union', or 'variant' can't be 'extern'.";
		},
		(in DiagExternTypeError x) {
			writer ~= () {
				final switch (x) {
					case DiagExternTypeError.alignmentIsDefault:
						return "Alignment value is the default and can be omitted.";
					case DiagExternTypeError.badAlignment:
						return "Alignment must be 1, 2, 4, or 8.";
					case DiagExternTypeError.tooBig:
						return "Type size is too big.";
				}
			}();
		},
		(in DiagFlagsSigned _) {
			writer ~= "A 'flags' type can't use a signed storage type.";
		},
		(in DiagFunctionWithSignatureNotFound x) {
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
		(in DiagFunPointerExprMustBeName _) {
			writer ~= "Function pointer expression must be a plain identifier ('&f').";
		},
		(in DiagFunPointerNotBare _) {
			writer ~= "The target of a function pointer must be a 'bare' function.";
		},
		(in DiagIfThrow _) {
			writer ~= "Instead of throwing from a conditional expression, use 'assert' or 'forbid'.";
		},
		(in DiagImportFile x) {
			x.matchIn!void(
				(in CantImportCrowAsText y) {
					writer ~= "Can't import a '.crow' file as content.";
				},
				(in CircularImport y) {
					writer ~= "This is part of a circular import:";
					foreach (Uri uri; y.cycle) {
						writeNewline(writer, 1);
						writeUri(writer, ctx, uri);
						writer ~= " imports";
					}
					writeNewline(writer, 1);
					writeUri(writer, ctx, y.cycle[0]);
				},
				(in LibraryNotConfigured x) {
					writer ~= "Library ";
					writeName(writer, ctx, x.libraryName);
					writer ~= " is not configured.";
					writeNewline(writer, 0);
					writer ~= "It must be added to \"include\" in 'crow-config.json'.";
				},
				(in ReadError y) {
					showReadFileDiag(writer, ctx, y.diag, some(y.uri));
				},
				(in RelativeImportReachesPastRoot y) {
					writer ~= "Relative path ";
					writer ~= y.imported;
					writer ~= " reaches above the root directory.";
				});
		},
		(in DiagImportRefersToNothing x) {
			writer ~= "Imported name ";
			writeName(writer, ctx, x.name);
			writer ~= " does not refer to anything.";
		},
		(in DiagLambdaCantBeFunctionPointer x) {
			writer ~= "A function pointer can't be implemented by a lambda. Write a function and use '&f' instead.";
		},
		(in DiagLambdaCantInferParamType x) {
			writer ~= "Can't infer the lambda parameter's type.";
		},
		(in DiagLambdaClosurePurity x) {
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
		(in DiagLambdaMultipleMatch x) {
			writer ~= "Multiple lambda types are possible:";
			writeTypesOnLines(writer, ctx, x.choices);
			writeNewline(writer, 0);
			writer ~= "Consider explicitly typing the lambda's parameter.";
		},
		(in DiagLambdaNotExpected x) {
			if (x.expected.isA!ExpectedForDiagInfer)
				writer ~= "Lambda expression needs an expected type.";
			else {
				writer ~= "The lambda doesn't match the expected type at this location.";
				writeNewline(writer, 0);
				writeExpected(writer, ctx, x.expected, ExpectedKind.lambda);
			}
		},
		(in DiagLambdaTypeMissingParamType _) {
			writer ~= "Function type needs parameter types. " ~
				"(It is parsed a as a destructure, so it needs both parameter names and types.)";
		},
		(in DiagLambdaTypeVariadic _) {
			writer ~= "A function type can't be variadic; only a function can.";
		},
		(in DiagLinkageWorseThanContainingFun x) {
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
		(in DiagLinkageWorseThanContainingType x) {
			writer ~= "Extern type ";
			writeName(writer, ctx, x.containingType.name);
			writer ~= " can't reference non-extern type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.referencedType, TypeContainer(x.containingType)));
			writer ~= '.';
		},
		(in DiagLiteralFloatAccuracy x) {
			writer ~= "Literal of type '";
			writeName(writer, ctx, stringOfEnum(x.type));
			writer ~= " overflows.";
		},
		(in DiagLiteralMultipleMatch x) {
			writer ~= "Multiple possible types for literal expression: ";
			writeWithCommas!(StructInst*)(writer, x.types, (in StructInst* type) {
				writeStructInst(writer, ctx, x.typeContainer, *type);
			});
		},
		(in DiagLiteralNotExpected x) {
			if (x.expected.isA!ExpectedForDiagInfer)
				writer ~= "Literal expression needs an expected type.";
			else {
				writer ~= "The literal doesn't match the expected type at this location.";
				writeNewline(writer, 0);
				writeExpected(writer, ctx, x.expected, ExpectedKind.lambda);
			}
		},
		(in DiagLiteralOverflow x) {
			writer ~= "A value of type ";
			writeName(writer, ctx, stringOfEnum(x.type));
			writer ~= " must be from ";
			writer ~= minValue(x.type);
			writer ~= " to ";
			writer ~= maxValue(x.type);
			writer ~= '.';
		},
		(in DiagLocalIgnoredButMutable _) {
			writer ~= "Unnecessary 'mut' on ignored local variable.";
		},
		(in DiagLocalNotMutable x) {
			writer ~= "Local variable ";
			writeName(writer, ctx, x.local.name);
			writer ~= " was not marked 'mut'.";
		},
		(in DiagLoopDisallowedBody x) {
			writer ~= "Loop body cannot be a ";
			writeName(writer, ctx, stringOfEnum(x));
			writer ~= " expression";
		},
		(in DiagLoopWithoutBreak _) {
			writer ~= "'loop' has no 'break'.";
		},
		(in DiagMainMissingExterns x) {
			writer ~= "'main' function depends on extern ";
			writeWithCommas!Symbol(writer, x.missing, (in Symbol x) {
				writeName(writer, ctx, x);
			});
			writer ~= " which is not provided.";
		},
		(in DiagMainTestMissing x) {
			writer ~= "There is no 'test' keyword on line ";
			writer ~= x.expectedLine + 1;
			writer ~= '.';
		},
		(in DiagMatchCaseDuplicate x) {
			writer ~= "Duplicate branch ";
			x.matchIn!void(
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
		(in DiagMatchCaseForType x) {
			writer ~= () {
				final switch (x) {
					case DiagMatchCaseForType.enumOrUnion:
						return "To match an enum or union, branches must use identifiers.";
					case DiagMatchCaseForType.numeric:
						return "To match a number, branches must use number literals.";
					case DiagMatchCaseForType.stringLike:
						return "To match a string-like type, branches must use identifiers or string literals.";
				}
			}();
		},
		(in DiagMatchCaseNameNotInEnum x) {
			writer ~= "Enum ";
			writeName(writer, ctx, x.enum_.name);
			writer ~= " has no member ";
			writer ~= x.actual;
			writer ~= ".\nThis should be one of: ";
			writeWithCommas!EnumOrFlagsMember(
				writer, x.enum_.body_.as!(Enum*).members, (in EnumOrFlagsMember member) {
					writeName(writer, ctx, member.name);
				});
		},
		(in DiagMatchCaseNoValueForEnumOrSymbol x) {
			writer ~= "Matching on ";
			if (has(x.enum_)) {
				writer ~= "enum ";
				writeName(writer, ctx, force(x.enum_).name);
			} else
				writeName(writer, ctx, symbol!"symbol");
			writer ~= ", so case should not expect a value.";
		},
		(in DiagMatchCaseShouldUseIgnore x) {
			writer ~= "Variant member type ";
			writeName(writer, ctx, x.member.decl.name);
			writer ~= " is non-empty, so it should be explicitly ignored using ";
			writeName(writer, ctx, symbol!"_");
			writer ~= '.';
		},
		(in DiagMatchNeedsElse x) {
			writer ~= "A 'match' on ";
			writer ~= () {
				final switch (x) {
					case DiagMatchNeedsElse.integral:
						return "an integral ";
					case DiagMatchNeedsElse.stringLike:
						return "a string or symbol";
					case DiagMatchNeedsElse.variant:
						return "a variant ";
				}
			}();
			writer ~= " must have an explicit 'else'.";
		},
		(in DiagMatchOnNonMatchable x) {
			writer ~= "Can only match on an enum, union, variant, integral, symbol, string, or character type, not ";
			writeTypeQuoted(writer, ctx, x.type);
			writer ~= '.';
		},
		(in DiagMatchSumTypeCantInferTypeArgs x) {
			writer ~= "Can't infer type arguments of ";
			writer ~= x.member.name;
		},
		(in DiagMatchSumTypeNoMember x) {
			writer ~= "Type ";
			writeName(writer, ctx, x.nonMember.name);
			writer ~= " is not a case of ";
			writeTypeQuoted(writer, ctx, x.variant);
			writer ~= '.';
		},
		(in DiagMatchUnhandledCases x) {
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
		(in DiagMatchUnnecessaryElse x) {
			writer ~= "The 'match' handles every possible case, so the 'else' is unused.";
		},
		(in DiagMethodImplVisibility x) {
			writer ~= "A method of ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(Type(x.sumType), TypeContainer(x.member)));
			writer ~= " is implemented by ";
			writeFunInst(writer, ctx, WriteKind.quoted, TypeContainer(x.member), *x.methodImpl);
			writer ~= ", but it is less visible than ";
			writeName(writer, ctx, x.member.name);
			writer ~= '.';
		},
		(in DiagModifierConflict x) {
			writeModifier(writer, ctx, x.curModifier);
			writer ~= " conflicts with ";
			writeModifier(writer, ctx, x.prevModifier);
			writer ~= '.';
		},
		(in DiagModifierDuplicate x) {
			writer ~= "Redundant ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= '.';
		},
		(in DiagModifierInvalid x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " can't be ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= '.';
			if (x.declKind == DeclKind.test && x.modifier == ModifierKeyword.unsafe)
				writer ~= " Did you mean 'trusted'?";
		},
		(in DiagModifierRedundantDueToDeclKind x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " is already ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= " by default.";
		},
		(in DiagModifierRedundantDueToModifier x) {
			writeModifier(writer, ctx, x.redundantModifier);
			writer ~= " is redundant given ";
			writeModifier(writer, ctx, x.modifier);
			writer ~= '.';
		},
		(in DiagModifierTypeArgInvalid x) {
			writeModifier(writer, ctx, x.modifier);
			writer ~= " does not take a type argument in this context.";
		},
		(in DiagMutFieldNotAllowed _) {
			writer ~= "This field is 'mut', so the record must be 'mut'.";
		},
		(in DiagNameNotFound x) {
			writer ~= "There is no ";
			writer ~= stringOfEnum(x.kind);
			writer ~= " in scope named ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(in DiagNeedsExpectedType x) {
			writer ~= '\'';
			writer ~= stringOfEnum(x);
			writer ~= "' expression needs an expected type.";
		},
		(in DiagParamMissingType _) {
			writer ~= "This parameter needs a type.";
		},
		(in DiagParamMutable _) {
			writer ~= "A parameter can't be mutable.";
		},
		(in ParseDiag x) {
			writeParseDiag(writer, ctx, x);
		},
		(in DiagPointerIsNative _) {
			writer ~= "Can only get a pointer in an 'extern native' context.";
		},
		(in DiagPointerIsUnsafe _) {
			writer ~= "Can only get a pointer in an 'unsafe' or 'trusted' context.";
		},
		(in DiagPointerMutToConst x) {
			writer ~= () {
				final switch (x) {
					case DiagPointerMutToConst.fieldOfByRef:
						return "Can't get a 'mut' pointer to a non-'mut' field.";
					case DiagPointerMutToConst.fieldOfByVal:
						return "Can't get a 'mut' field pointer from a non-'mut' record pointer.";
					case DiagPointerMutToConst.local:
						return "Can't get a 'mut' pointer to a non-'mut' local.";
				}
			}();
		},
		(in DiagPointerUnsupported x) {
			final switch (x) {
				case DiagPointerUnsupported.other:
					writer ~= "Can't get a pointer to this kind of expression.";
					break;
				case DiagPointerUnsupported.recordNotByRef:
					writer ~= "To get a pointer to a record field, " ~
						"the record must be 'by-ref' or a pointer to a 'by-val' record.";
					break;
			}
		},
		(in DiagPurityWorseThanParent x) {
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
		(in DiagPurityWorseThanSumType x) {
			writer ~= showSumTypeKindUpperCase(x.sumType.decl.body_.as!SumType.kind);
			writer ~= ' ';
			writeName(writer, ctx, x.sumType.decl.name);
			writer ~= " has purity ";
			writePurity(writer, ctx, x.sumType.purityRange.bestCase);
			writer ~= ", but case ";
			writeName(writer, ctx, x.case_.name);
			writer ~= " has purity ";
			writePurity(writer, ctx, x.case_.purity);
			writer ~= '.';
		},
		(in DiagRecordFieldNeedsType x) {
			writer ~= "Record field ";
			writeName(writer, ctx, x.fieldName);
			writer ~= " needs a type.";
		},
		(in DiagSharedArgIsNotLambda _) {
			writer ~= "Argument to 'shared' must be a lambda expression.";
		},
		(in DiagSharedLambdaTypeIsNotShared x) {
			writer ~= "'shared' lambda needs a 'shared' ";
			writer ~= () {
				final switch (x.kind) {
					case DiagSharedLambdaTypeIsNotSharedKind.paramType:
						return "parameter";
					case DiagSharedLambdaTypeIsNotSharedKind.returnType:
						return "return";
				}
			}();
			writer ~= " type, but it is ";
			writeTypeQuoted(writer, ctx, x.actual);
			writer ~= '.';
		},
		(in DiagSharedLambdaUnused x) {
			writer ~= "The lambda does not have anything 'mut' in its closure, so it does not need 'shared'.";
		},
		(in DiagSharedNotExpected x) {
			writer ~= "Expected type is a lambda, but it is not 'shared'.\n";
			writeExpected(writer, ctx, x.expected, ExpectedKind.lambda);
		},
		(in DiagSpecMatchMultiple x) {
			writer ~= "Multiple implementations found for spec signature ";
			writeName(writer, ctx, x.sigName);
			writer ~= ':';
			writeCalleds(writer, ctx, x.outermostTypeContainer, x.matches);
			writeNewline(writer, 1);
			writer ~= "Calling:";
			writeSpecTrace(writer, ctx, x.outermostTypeContainer, x.trace);
		},
		(in DiagSpecNoMatch x) {
			x.reason.matchIn!void(
				(in SpecBuiltinNotSatisfied y) {
					writeTypeQuoted(writer, ctx, TypeWithContainer(y.type, x.outermostTypeContainer));
					writer ~= " is not '";
					writer ~= stringOfEnum(y.kind);
					writer ~= "'.";
				},
				(in SpecCantInferTypeArgs y) {
					writer ~= "Can't infer type arguments to ";
					writeFunDecl(writer, ctx, WriteKind.quoted, y.fun);
				},
				(in SpecImplNotFound y) {
					writer ~= "No implementation was found for spec signature ";
					Signature* sig = y.sigDecl;
					writeSig(
						writer, ctx, WriteKind.quoted, x.outermostTypeContainer, sig.name, sig.returnType,
						Params(sig.params), some(y.sigType));
					writer ~= '.';
				},
				(in SpecTooDeep _) {
					writer ~= "Spec instantiation is too deep.";
				});
			if (!isEmpty(x.trace)) {
				writeNewline(writer, 1);
				writer ~= "Calling:";
				writeSpecTrace(writer, ctx, x.outermostTypeContainer, x.trace);
			}
		},
		(in DiagSpecRecursion x) {
			writer ~= "Spec's parents tree is too deep.";
			writeNewline(writer, 1);
			writer ~= "Trace: ";
			writeWithCommas!(immutable SpecDecl*)(writer, x.trace, (in SpecDecl* spec) {
				writeName(writer, ctx, spec.name);
			});
		},
		(in DiagSpecSigCantBeVariadic x) {
			writer ~= "A spec signature can't be variadic.";
		},
		(in DiagSpecUseInvalid x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " can't have specs.";
		},
		(in DiagStringLiteralInvalid x) {
			writer ~= () {
				final switch (x) {
					case DiagStringLiteralInvalid.cStringContainsNul:
						return "'c-string' literal can't contain '\\0'.";
					case DiagStringLiteralInvalid.notExternJs:
						return "Cant' create a 'js-any' value without 'js extern'.";
					case DiagStringLiteralInvalid.stringContainsNul:
						return "'string' literal can't contain '\\0'.";
					case DiagStringLiteralInvalid.symbolContainsNul:
						return "'symbol' literal can't contain '\\0'.";
				}
			}();
		},
		(in DiagStorageMissingType _) {
			writer ~= "'storage' needs a type.";
		},
		(in DiagStructParamsSyntaxError x) {
			final switch (x.reason) {
				case DiagStructParamsSyntaxErrorReason.hasParamsAndFields:
					writer ~= aOrAnDeclKind(declKindOfStruct(x.struct_));
					writer ~= " can't have both parameter-style and indented fields.";
					break;
				case DiagStructParamsSyntaxErrorReason.destructure:
					writer ~= aOrAnMemberKind(memberKindOfStruct(x.struct_));
					writer ~= " can't use destructuring.";
					break;
				case DiagStructParamsSyntaxErrorReason.variadic:
					writer ~= aOrAnMemberKind(memberKindOfStruct(x.struct_));
					writer ~= " can't be variadic.";
					break;
			}
		},
		(in DiagSumTypeListedMembersNonUnion _) {
			writer ~= "Only 'union' types support listing member types.";
		},
		(in DiagTestMissingBody _) {
			writer ~= "This test needs a body.";
		},
		(in DiagTrustedUnnecessary x) {
			writer ~= () {
				final switch (x) {
					case DiagTrustedUnnecessary.inTrusted:
						return "'trusted' expression is redundant inside another 'trusted' expression.";
					case DiagTrustedUnnecessary.inUnsafeFunction:
						return "'trusted' expression is redundant inside an 'unsafe' function.";
					case DiagTrustedUnnecessary.unused:
						return "There is no unsafe code in this expression; you could remove 'trusted'.";
				}
			}();
		},
		(in DiagTupleTooBig x) {
			writer ~= "This tuple has ";
			writer ~= x.actual;
			writer ~= " elements; the maximum allowed is ";
			writer ~= x.maxAllowed;
		},
		(in DiagTypeAnnotationUnnecessary x) {
			writer ~= "Type annotation is unnecessary; type ";
			writeTypeQuoted(writer, ctx, x.type);
			writer ~= " was already inferred.";
		},
		(in DiagTypeConflict x) {
			writeExpected(writer, ctx, x.expected, ExpectedKind.generic);
			writeNewline(writer, 0);
			writer ~= "Actual: ";
			writeTypeQuoted(writer, ctx, x.actual);
			writer ~= '.';
		},
		(in DiagTypeParamCantHaveTypeArgs _) {
			writer ~= "Can't provide type arguments to a type parameter.";
		},
		(in DiagTypeParamsUnsupported x) {
			writer ~= aOrAnDeclKind(x.declKind);
			writer ~= " can't have type parameters.";
		},
		(in DiagTypeShouldUseSyntax x) {
			writer ~= () {
				final switch (x) {
					case DiagTypeShouldUseSyntax.array:
						return "Prefer to write 't[]' instead of 't array'.";
					case DiagTypeShouldUseSyntax.funData:
						return "Prefer to write 'r data(x p)' instead of '(r, p) fun-data'.";
					case DiagTypeShouldUseSyntax.funMut:
						return "Prefer to write 'r mut(x p)' instead of '(r, p) fun-mut'.";
					case DiagTypeShouldUseSyntax.funPointer:
						return "Prefer to writer 'r function(x p)' instead of '(r, p) fun-pointer'.";
					case DiagTypeShouldUseSyntax.funShared:
						return "Prefer to write 'r shared(x p)' instead of '(r, p) fun-shared'.";
					case DiagTypeShouldUseSyntax.map:
						return "Prefer to write 'v[k]' instead of '(k, v) map'.";
					case DiagTypeShouldUseSyntax.mutArray:
						return "Prefer to write 't mut[]' instead of 't mut-array'.";
					case DiagTypeShouldUseSyntax.mutMap:
						return "Prefer to write 'v mut[k]' instead of '(k, v) mut-map'.";
					case DiagTypeShouldUseSyntax.mutPointer:
						return "Prefer to write 't mut*' instead of 't mut-pointer'.";
					case DiagTypeShouldUseSyntax.opt:
						return "Prefer to write 't?' instead of 't option'.";
					case DiagTypeShouldUseSyntax.pointer:
						return "Prefer to write 't*' instead of 't const-pointer'.";
					case DiagTypeShouldUseSyntax.sharedArray:
						return "Prefer to write 't shared[]' instead of 't shared-array'.";
					case DiagTypeShouldUseSyntax.sharedMap:
						return "Prefer to write 'v shared[k]' instead of '(k, v) shared-map'.";
					case DiagTypeShouldUseSyntax.tuple:
						return "Prefer to write '(t, u)' instead of '(t, u) tuple2'.";
				}
			}();
		},
		(in DiagUnionMemberTypeParameter _) {
			writer ~= "A type parameter can't be a union member.";
		},
		(in DiagUnsupportedSyntax x) {
			writer ~= () {
				final switch (x) {
					case DiagUnsupportedSyntax.enumMemberMutability:
						return "An enum member can't be 'mut'.";
					case DiagUnsupportedSyntax.enumMemberType:
						return "An enum member can't specify a type.";
				}
			}();
		},
		(in DiagUnusedImport x) {
			if (has(x.importedName)) {
				writer ~= "Imported name ";
				writeName(writer, ctx, force(x.importedName));
			} else {
				writer ~= "Imported module ";
				writeName(writer, ctx, baseName(x.importedModule.uri));
			}
			writer ~= " is unused.";
		},
		(in DiagUnusedLocal x) {
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
		(in DiagUnusedPrivateDecl x) {
			writeName(writer, ctx, x.name);
			writer ~= " is unused.";
		},
		(in DiagVarargsParamMustBeArray _) {
			writer ~= "Variadic parameter must be an ";
			writeName(writer, ctx, symbol!"array");
			writer ~= '.';
		},
		(in DiagVisibilityWarning x) {
			writeVisibilityWarning(writer, ctx, x);
		},
		(in DiagWithHasElse _) {
			writeKeyword(writer, ctx, "with");
			writer ~= " statement can't have ";
			writeKeyword(writer, ctx, "else");
			writer ~= '.';
		},
		(in DiagWrongNumberTypeArgs x) {
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
		(in ExpectedForDiagChoices choices) {
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
		(in ExpectedForDiagInfer _) {
			writer ~= "This location has no expected ";
			writeType();
			writer ~= '.';
		},
		(in ExpectedForDiagLoop _) {
			writer ~= "Expected a loop 'break' or 'continue'.";
		});
}

void writeTypesOnLines(scope ref Writer writer, in ShowDiagCtx ctx, in ExpectedForDiagChoices choices) {
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
		(in StructBodyBogus _) =>
			assert(false),
		(in BuiltinType _) =>
			assert(false),
		(in Enum _) =>
			DeclKind.enum_,
		(in ExternType _) =>
			assert(false),
		(in Flags _) =>
			DeclKind.flags,
		(in Record _) =>
			DeclKind.record,
		(in SumType _) =>
			DeclKind.variant);

enum MemberKind { enumMember, flagsMember, recordField }
MemberKind memberKindOfStruct(StructDecl* a) =>
	a.body_.matchIn!MemberKind(
		(in StructBodyBogus _) =>
			assert(false),
		(in BuiltinType _) =>
			assert(false),
		(in Enum _) =>
			MemberKind.enumMember,
		(in ExternType _) =>
			assert(false),
		(in Flags _) =>
			MemberKind.flagsMember,
		(in Record _) =>
			MemberKind.recordField,
		(in SumType _) =>
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
		case DeclKind.flags:
			return "A flags type";
		case DeclKind.function_:
			return "A function";
		case DeclKind.global:
			return "A global variable";
		case DeclKind.interface_:
			return "An interface type";
		case DeclKind.record:
			return "A record type";
		case DeclKind.spec:
			return "A spec";
		case DeclKind.test:
			return "A test";
		case DeclKind.threadLocal:
			return "A thread-local variable";
		case DeclKind.union_:
			return "A union type";
		case DeclKind.variant:
			return "A variant type";
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

void writeVisibilityWarning(scope ref Writer writer, in ShowDiagCtx ctx, in DiagVisibilityWarning a) {
	if (a.actualVisibility > a.defaultVisibility) {
		a.kind.matchIn!void(
			(in VisibilityWarningField x) {
				writer ~= "Field ";
				writeName(writer, ctx, x.fieldName);
				writer ~= " should not be more visible than record ";
				writeName(writer, ctx, x.record.name);
				writer ~= " which is only ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= '.';
			},
			(in VisibilityWarningFieldMutability x) {
				writer ~= "Field ";
				writeName(writer, ctx, x.fieldName);
				writer ~= " can't have ";
				writeVisibility(writer, ctx, a.actualVisibility);
				writer ~= " mutability when the field itself is ";
				writeVisibility(writer, ctx, a.defaultVisibility);
			},
			(in VisibilityWarningNew x) {
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
			(in VisibilityWarningField x) {
				writer ~= "Fields of record ";
				writeName(writer, ctx, x.record.name);
				writer ~= " are already ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= " by default.";
			},
			(in VisibilityWarningFieldMutability x) {
				writer ~= "Field ";
				writeName(writer, ctx, x.fieldName);
				writer ~= " mutability would already be ";
				writeVisibility(writer, ctx, a.defaultVisibility);
				writer ~= " by default.";
			},
			(in VisibilityWarningNew x) {
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
		case Token.case_:
			return "Unexpected keyword 'case'.";
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
			// This is ParseDiagUnexpectedCharacter instead
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
		case Token.while_:
			return "Unexpected keyword 'while'.";
		case Token.with_:
			return "Unexpected keyword 'with'.";
	}
}
