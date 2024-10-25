module model.parseDiag;

@safe @nogc pure nothrow:

import frontend.parse.lexer : Token;
import model.diag : ReadFileDiag;
import util.sourceRange : Range;
import util.symbol : Symbol;
import util.union_ : Union;

immutable struct ParseDiagnostic {
	Range range;
	ParseDiag kind;
}

immutable struct ParseDiag {
	@safe @nogc pure nothrow:
	immutable struct DocCommentUnused {}
	immutable struct Expected {
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
	immutable struct FileNotUtf8 {}
	immutable struct ImportFileTypeNotSupported {}
	immutable struct IndentNotDivisible {
		uint nSpaces;
		uint nSpacesPerIndent;
	}
	immutable struct IndentTooMuch {}
	immutable struct IndentWrongCharacter {
		bool expectedTabs;
	}
	immutable struct InvalidStringEscape {
		string actual;
	}
	immutable struct MatchCaseInterpolated {}
	immutable struct MissingInterpolated {}
	immutable struct NeedsBlockCtx {
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
	immutable struct TrailingComma {}
	immutable struct TypeEmptyParens {}
	immutable struct TypeTrailingMut {}
	immutable struct TypeUnnecessaryParens {}
	immutable struct UnexpectedCharacter {
		dchar character;
	}
	immutable struct UnexpectedOperator {
		Symbol operator;
	}
	immutable struct UnexpectedToken {
		Token token;
	}

	mixin Union!(
		DocCommentUnused,
		Expected,
		FileNotUtf8,
		ImportFileTypeNotSupported,
		IndentNotDivisible,
		IndentTooMuch,
		IndentWrongCharacter,
		InvalidStringEscape,
		MatchCaseInterpolated,
		MissingInterpolated,
		NeedsBlockCtx,
		ReadFileDiag,
		TrailingComma,
		TypeEmptyParens,
		TypeTrailingMut,
		TypeUnnecessaryParens,
		UnexpectedCharacter,
		UnexpectedOperator,
		UnexpectedToken);
}
static assert(ParseDiag.sizeof <= 32);
