module model.parseDiag;

@safe @nogc pure nothrow:

import frontend.parse.lexer : Token;
import util.sourceRange : Range;
import util.symbol : Symbol;
import util.union_ : Union;

enum ReadFileDiag_ {
	unknown, // We've just encountered the file and haven't notified the environment.
	loading, // We've notified the environment that we want this file, but haven't received a response.
	notFound, // The file is known to not exist.
	error, // There was some error trying read the file.
}
alias ReadFileDiag = immutable ReadFileDiag_;

immutable struct ParseDiagnostic {
	Range range;
	ParseDiag kind;
}

immutable struct ParseDiag {
	@safe @nogc pure nothrow:
	mixin Union!(
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
		ReadFileDiag,
		ParseDiagTrailingComma,
		ParseDiagTypeEmptyParens,
		ParseDiagTypeTrailingMut,
		ParseDiagTypeUnnecessaryParens,
		ParseDiagUnexpectedCharacter,
		ParseDiagUnexpectedOperator,
		ParseDiagUnexpectedToken);
}
static assert(ParseDiag.sizeof <= 32);

immutable struct ParseDiagDocCommentUnused {}
immutable struct ParseDiagExpected {
	enum Kind {
		as,
		blockCommentEnd,
		catch_,
		closeInterpolated,
		closingBracket,
		closingParen,
		colon,
		comma,
		dedent,
		endOfLine,
		equals,
		indent,
		lambdaArrow,
		less,
		literalIntegral,
		literalNat,
		matchCase,
		name,
		namedArgument,
		nameOrOperator,
		newline,
		newlineOrDedent,
		openParen,
		questionEqual,
		quoteDouble,
		quoteDouble3,
		slash,
		typeArgsEnd,
	}
	Kind kind;
}
immutable struct ParseDiagFileNotUtf8 {}
immutable struct ParseDiagImportFileTypeNotSupported {}
immutable struct ParseDiagIndentNotDivisible {
	uint nSpaces;
	uint nSpacesPerIndent;
}
immutable struct ParseDiagIndentTooMuch {}
immutable struct ParseDiagIndentWrongCharacter {
	bool expectedTabs;
}
immutable struct ParseDiagInvalidStringEscape {
	string actual;
}
immutable struct ParseDiagMatchCaseInterpolated {}
immutable struct ParseDiagMissingInterpolated {}
immutable struct ParseDiagNeedsBlockCtx {
	enum Kind {
		do_,
		for_,
		if_,
		match,
		lambda,
		loop,
		shared_,
		throw_,
		trusted,
		try_,
		unless,
		with_,
	}
	Kind kind;
}
immutable struct ParseDiagTrailingComma {}
immutable struct ParseDiagTypeEmptyParens {}
immutable struct ParseDiagTypeTrailingMut {}
immutable struct ParseDiagTypeUnnecessaryParens {}
immutable struct ParseDiagUnexpectedCharacter {
	dchar character;
}
immutable struct ParseDiagUnexpectedOperator {
	Symbol operator;
}
immutable struct ParseDiagUnexpectedToken {
	Token token;
}
