module model.ast;

@safe @nogc pure nothrow:

import model.integralValues : IntegralValue;
import model.parseDiag : ParseDiag, ParseDiagnostic;
import model.sourceRange : combineRanges, Pos, Range, rangeOfStartAndLength;
import util.alloc.alloc : Alloc;
import util.col.array : arrayOfSingle, emptySmallArray, exists, isEmpty, newArray, newSmallArray, sizeEq, SmallArray;
import util.conv : safeToUint;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, optOrDefault, some;
import util.symbol : Symbol, symbol, symbolSize;
import util.union_ : TaggedUnion, Union;
import util.uri : Path, pathLength, RelPath, relPathLength;
import util.util : roundUp, stringOfEnum;

enum FunKind {
	data,
	shared_,
	mut,
	function_,
}

enum SumTypeKind { interface_, union_, variant }

enum VarKind { global, threadLocal }

string stringOfVarKindLowerCase(VarKind a) {
	final switch (a) {
		case VarKind.global:
			return "global";
		case VarKind.threadLocal:
			return "thread-local";
	}
}

string stringOfVarKindUpperCase(VarKind a) {
	final switch (a) {
		case VarKind.global:
			return "Global";
		case VarKind.threadLocal:
			return "Thread-local";
	}
}

enum Visibility : ubyte {
	private_,
	internal,
	public_,
}

immutable struct NameAndRange {
	@safe @nogc pure nothrow:

	Symbol name;
	// Range length is given by size of name
	Pos start;

	this(Pos s, Symbol n) {
		name = n;
		start = s;
	}

	Pos end() scope =>
		start + symbolSize(name);
	Range range() scope =>
		Range(start, end);
}
static assert(NameAndRange.sizeof == ulong.sizeof);

immutable struct FieldMutabilityAst {
	@safe @nogc pure nothrow:

	Pos pos;
	Opt!Visibility visibility_;

	Range range() =>
		rangeOfStartAndLength(pos, has(visibility) ? "-mut" : "mut");

	Opt!VisibilityAndRange visibility() =>
		getVisibilityAndRange(pos, visibility_);
}
static assert(FieldMutabilityAst.sizeof == ulong.sizeof);

immutable struct VisibilityAndRange {
	@safe @nogc pure nothrow:

	Visibility visibility;
	Pos pos;

	Range range() =>
		rangeOfStartAndLength(pos, "+");
}

private Opt!VisibilityAndRange getVisibilityAndRange(Pos pos, Opt!Visibility visibility) =>
	optIf(has(visibility), () =>
		VisibilityAndRange(force(visibility), pos));

immutable struct TypeAst {
	@safe @nogc pure nothrow:

	mixin Union!(
		BogusTypeAst,
		FunTypeAst*,
		MapTypeAst*,
		NameAndRange,
		SuffixNameTypeAst*,
		SuffixSpecialTypeAst*,
		TupleTypeAst*);

	Pos end() scope =>
		range.end;
	Range range() scope =>
		matchIn!Range(
			(in BogusTypeAst x) => x.range,
			(in FunTypeAst x) => x.range,
			(in MapTypeAst x) => x.range,
			(in NameAndRange x) => x.range,
			(in SuffixNameTypeAst x) => x.range,
			(in SuffixSpecialTypeAst x) => x.range,
			(in TupleTypeAst x) => x.range);
	Range nameRangeOrRange() scope =>
		matchIn!Range(
			(in BogusTypeAst x) => x.range,
			(in FunTypeAst x) => x.kindRange,
			(in MapTypeAst x) => x.range,
			(in NameAndRange x) => x.range,
			(in SuffixNameTypeAst x) => x.suffixRange,
			(in SuffixSpecialTypeAst x) => x.suffixRange,
			(in TupleTypeAst x) => x.range);
}
static assert(TypeAst.sizeof == size_t.sizeof + NameAndRange.sizeof);

immutable struct BogusTypeAst {
	Range range;
}

immutable struct FunTypeAst {
	@safe @nogc pure nothrow:

	TypeAst returnType;
	Pos kindPos;
	FunKind kind;
	Range paramsRange;
	ParamsAst params;

	Range range() scope =>
		combineRanges(returnType.range, paramsRange);
	Range kindRange() scope =>
		rangeOfStartAndLength(kindPos, stringOfEnum(kind));
}

immutable struct MapTypeAst {
	@safe @nogc pure nothrow:
	MapTypeAstKind kind;
	// They are actually written v[k] at the use, but applied as (k, v)
	TypeAst[2] kv;
	TypeAst k() return scope =>
		kv[0];
	TypeAst v() return scope =>
		kv[1];

	Range range() scope =>
		Range(v.range.start, safeToUint(k.range.end + "]".length));
}
enum MapTypeAstKind { data, mut, shared_ }

immutable struct SuffixNameTypeAst {
	@safe @nogc pure nothrow:
	TypeAst left;
	NameAndRange name;

	Range range() scope =>
		combineRanges(left.range, suffixRange);
	Range suffixRange() scope =>
		name.range;
}

immutable struct SuffixSpecialTypeAst {
	@safe @nogc pure nothrow:
	TypeAst left;
	Pos suffixPos;
	SuffixSpecialTypeAstKind kind;

	Range range() scope =>
		Range(left.range.start, suffixEnd);
	Range suffixRange() scope =>
		Range(suffixPos, suffixEnd);
	private Pos suffixEnd() scope =>
		suffixPos + suffixLength(kind);
}
enum SuffixSpecialTypeAstKind : ubyte { array, constPointer, mutArray, mutPointer, option, sharedArray }

immutable struct TupleTypeAst {
	@safe @nogc pure nothrow:

	Range range;
	SmallArray!TypeAst members;

	this(Range r, TypeAst[] ms) {
		range = r;
		members = ms;
		assert(members.length >= 2);
	}
}

private uint suffixLength(SuffixSpecialTypeAstKind a) {
	final switch (a) {
		case SuffixSpecialTypeAstKind.array:
			return cast(uint) "[]".length;
		case SuffixSpecialTypeAstKind.constPointer:
			return cast(uint) "*".length;
		case SuffixSpecialTypeAstKind.mutArray:
			return cast(uint) "mut[]".length;
		case SuffixSpecialTypeAstKind.mutPointer:
			return cast(uint) "mut*".length;
		case SuffixSpecialTypeAstKind.option:
			return cast(uint) "?".length;
		case SuffixSpecialTypeAstKind.sharedArray:
			return cast(uint) "shared[]".length;
	}
}

Symbol symbolForTypeAstMap(MapTypeAstKind a) {
	final switch (a) {
		case MapTypeAstKind.data:
			return symbol!"map";
		case MapTypeAstKind.mut:
			return symbol!"mut-map";
		case MapTypeAstKind.shared_:
			return symbol!"shared-map";
	}
}

Symbol symbolForTypeAstSuffix(SuffixSpecialTypeAstKind a) {
	final switch (a) {
		case SuffixSpecialTypeAstKind.array:
			return symbol!"array";
		case SuffixSpecialTypeAstKind.constPointer:
			return symbol!"const-pointer";
		case SuffixSpecialTypeAstKind.mutArray:
			return symbol!"mut-array";
		case SuffixSpecialTypeAstKind.mutPointer:
			return symbol!"mut-pointer";
		case SuffixSpecialTypeAstKind.option:
			return symbol!"option";
		case SuffixSpecialTypeAstKind.sharedArray:
			return symbol!"shared-array";
	}
}

immutable struct ArrowAccessAst {
	@safe @nogc pure nothrow:
	ExprAst* left;
	Pos keywordPos;
	NameAndRange name;

	Pos start() scope =>
		left.start;
	Pos end() scope =>
		name.end;
	Range arrowRange() scope =>
		rangeOfStartAndLength(keywordPos, "->");
	Range arrowAndNameRange() scope =>
		combineRanges(arrowRange, name.range);
}

immutable struct AssertOrForbidAst {
	@safe @nogc pure nothrow:

	Pos start;
	bool isForbid;
	ConditionAst condition;
	Opt!(AssertOrForbidThrownAst*) thrown;
	ExprAst* after;

	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "assert");
	Pos end() scope =>
		after.end;
}
immutable struct AssertOrForbidThrownAst {
	@safe @nogc pure nothrow:
	Pos colonPos;
	ExprAst expr;

	Range colonRange() scope =>
		rangeOfStartAndLength(colonPos, ":");
}

// `left := right`
immutable struct AssignmentAst {
	@safe @nogc pure nothrow:
	ExprAst left;
	Pos assignmentPos;
	ExprAst right;

	Pos start() scope =>
		left.start;
	Pos end() scope =>
		right.end;
	Range keywordRange() scope =>
		rangeOfStartAndLength(assignmentPos, ":=");
}

// `left f:= right`
immutable struct AssignmentCallAst {
	@safe @nogc pure nothrow:

	NameAndRange funName;
	ExprAst[2]* leftAndRight;

	ref ExprAst left() return scope =>
		(*leftAndRight)[0];
	ref ExprAst right() return scope =>
		(*leftAndRight)[1];

	Pos start() scope =>
		left.start;
	Pos end() scope =>
		right.end;
	Range keywordRange() scope =>
		rangeOfStartAndLength(funName.range.end, ":=");
}

immutable struct BogusAst {
	@safe @nogc pure nothrow:
	Range range;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct CallAst {
	@safe @nogc pure nothrow:

	Range range;
	CallAstStyle style;
	Pos keywordPos; // Position of '.' or '?'
	NameAndRange funName;
	SmallArray!ExprAst args;
	Opt!(TypeAst*) typeArg;

	this(Range r, CallAstStyle s, NameAndRange fn, SmallArray!ExprAst a, Opt!(TypeAst*) ta = none!(TypeAst*)) {
		this(r, s, Pos.max, fn, a, ta);
	}
	this(Range r, CallAstStyle s, Pos kp, NameAndRange fn, SmallArray!ExprAst a, Opt!(TypeAst*) ta = none!(TypeAst*)) {
		range = r;
		style = s;
		keywordPos = kp;
		funName = fn;
		args = a;
		typeArg = ta;
		assert(has(keywordRange) == (keywordPos != Pos.max));
	}

	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
	Opt!Range keywordRange() scope {
		final switch (style) {
			case CallAstStyle.augment:
				return some(funName.range);
			case CallAstStyle.comma:
			case CallAstStyle.dot:
			case CallAstStyle.subscript:
				return some(rangeOfStartAndLength(keywordPos, 1));
			case CallAstStyle.questionDot:
			case CallAstStyle.questionSubscript:
				return some(rangeOfStartAndLength(keywordPos, 2));
			case CallAstStyle.emptyParens:
			case CallAstStyle.infix:
			case CallAstStyle.prefixBang:
			case CallAstStyle.prefixOperator:
			case CallAstStyle.single:
			case CallAstStyle.suffixBang:
				return none!Range;
		}
	}

	Range nameRange(in ExprAst* ast) scope =>
		style == CallAstStyle.comma ? ast.range : funName.range;
}
enum CallAstStyle : ubyte {
	augment, // This is the call for '!' in 'x !f y' or for '?!' in 'x f?! y'
	comma, // `a, b`, `a, b, c`, etc.
	dot, // `a.b`
	emptyParens, // `()`
	infix, // `a b`, `a b c`, `a b c, d`, etc.
	prefixBang,
	prefixOperator, // `-x`, `x`, `~x`
	single, // `a@t` (without the type arg, the ExprAst would just be a NameAndRange)
	subscript, // `a[b]`
	suffixBang, // `x!`
	questionSubscript, // `a?[b]``
	questionDot, // `a?.b``
}

immutable struct CallNamedAst {
	@safe @nogc pure nothrow:

	NameAndRange[] names;
	ExprAst[] args;

	this(NameAndRange[] ns, ExprAst[] as) {
		names = ns;
		args = as;
		assert(!isEmpty(names));
		assert(sizeEq(names, args));
	}

	Pos start() scope =>
		names[0].start;
	Pos end() scope =>
		args[$ - 1].end;
}

immutable struct DoAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst* body_;

	Pos end() scope =>
		body_.end;
}

// Used for implicit 'else ()' or implicit '()' after a Let
immutable struct EmptyAst {
	@safe @nogc pure nothrow:
	Range range;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct ExternAst {
	@safe @nogc pure nothrow:
	Range range;
	NameAndRange[] names;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct FinallyAst {
	@safe @nogc pure nothrow:

	Pos start;
	ExprAst right;
	ExprAst below;

	Pos end() scope =>
		below.end;
	Range finallyKeywordRange() scope =>
		rangeOfStartAndLength(start, "finally");
}

immutable struct ForAst {
	@safe @nogc pure nothrow:
	Pos start;
	DestructureAst param;
	Pos colonPos;
	ExprAst collection;
	ExprAst body_;
	ExprAst else_; // May be EmptyAst

	Pos end() scope =>
		else_.isA!EmptyAst
			? body_.end
			: else_.end;
	Range forKeywordRange() scope =>
		rangeOfStartAndLength(start, "for");
	Range colonRange() scope =>
		rangeOfStartAndLength(colonPos, ":");
}

immutable struct ConditionAst {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(ExprAst*, UnpackOptionAst*);

	Range range() scope =>
		matchIn!Range(
			(in ExprAst x) =>
				x.range,
			(in UnpackOptionAst x) =>
				x.range);
}
immutable struct UnpackOptionAst {
	@safe @nogc pure nothrow:
	DestructureAst destructure;
	Pos questionEqualsPos;
	ExprAst* option;

	Range range() scope =>
		Range(destructure.start, option.end);
	Range questionEqualsRange() scope =>
		rangeOfStartAndLength(questionEqualsPos, "?=");
}

immutable struct IfAst {
	@safe @nogc pure nothrow:
	Pos start;
	IfAstKind kind;
	bool isElseOfParent; // 'ifWithoutElse', 'ifElif', and 'ifElse' could all be the 'else' branch of a preceding 'if'
	Pos firstKeywordPos; // Position of 'if' or '?' or 'unless'
	Pos secondKeywordPos_; // Position of 'elif' or 'else' or ':' keyword
	ConditionAst condition;
	// How many branches this points to depends on 'kind'. See 'countIfBranches'.
	private ExprAst* branchesPtr;

	Pos end() scope =>
		has(secondBranch)
			? force(secondBranch).end
			: force(firstBranch).end;

	@trusted ExprAst[] allBranches() return scope =>
		branchesPtr[0 .. countIfBranches(kind)];

	bool isConditionNegated() scope {
		final switch (kind) {
			case IfAstKind.ifWithoutElse:
			case IfAstKind.ifElif:
			case IfAstKind.ifElse:
			case IfAstKind.ternaryWithElse:
			case IfAstKind.ternaryWithoutElse:
				return false;
			case IfAstKind.guardWithColon:
			case IfAstKind.guardWithoutColon:
			case IfAstKind.unless:
				return true;
		}
	}

	// For a 'guard', this is optional.
	Opt!(ExprAst*) firstBranch() return scope {
		final switch (kind) {
			case IfAstKind.guardWithColon:
			case IfAstKind.ifWithoutElse:
			case IfAstKind.ifElif:
			case IfAstKind.ifElse:
			case IfAstKind.ternaryWithElse:
			case IfAstKind.ternaryWithoutElse:
			case IfAstKind.unless:
				return some(branchesPtr);
			case IfAstKind.guardWithoutColon:
				return none!(ExprAst*);
		}
	}
	@trusted Opt!(ExprAst*) secondBranch() return scope {
		final switch (kind) {
			case IfAstKind.guardWithColon:
			case IfAstKind.ifElif:
			case IfAstKind.ifElse:
			case IfAstKind.ternaryWithElse:
				return some(&branchesPtr[1]);
			case IfAstKind.guardWithoutColon:
				return some(branchesPtr);
			case IfAstKind.ifWithoutElse:
			case IfAstKind.ternaryWithoutElse:
			case IfAstKind.unless:
				return none!(ExprAst*);
		}
	}

	Range firstKeywordRange() scope {
		size_t length = () {
			final switch (kind) {
				case IfAstKind.guardWithColon:
				case IfAstKind.guardWithoutColon:
					return "guard".length;
				case IfAstKind.ifWithoutElse:
				case IfAstKind.ifElif:
				case IfAstKind.ifElse:
					return "if".length;
				case IfAstKind.ternaryWithElse:
				case IfAstKind.ternaryWithoutElse:
					return "?".length;
				case IfAstKind.unless:
					return "unless".length;
			}
		}();
		return rangeOfStartAndLength(firstKeywordPos, length);
	}
	Opt!Pos secondKeywordPos() scope =>
		optIf(has(secondBranch), () => secondKeywordPos_);
	Opt!Range secondKeywordRange() scope {
		size_t length = () {
			final switch (kind) {
				case IfAstKind.guardWithoutColon:
				case IfAstKind.ifWithoutElse:
				case IfAstKind.ternaryWithoutElse:
				case IfAstKind.unless:
					return 0;
				case IfAstKind.ifElif:
				case IfAstKind.ifElse:
					return "else".length;
				case IfAstKind.guardWithColon:
				case IfAstKind.ternaryWithElse:
					return ":".length;
			}
		}();
		return optIf(length != 0, () => rangeOfStartAndLength(secondKeywordPos_, length));
	}
}
enum IfAstKind {
	guardWithColon,
	guardWithoutColon,
	ifWithoutElse, // 'if' with no 'else'
	ifElif, // In this case, the 'else' expression will be another IfAst
	ifElse, // Has 'if' and 'else' keywords
	ternaryWithElse, // 'cond ? then : else'
	ternaryWithoutElse, // 'cond ? then'
	unless,
}

private size_t countIfBranches(IfAstKind kind) {
	final switch (kind) {
		case IfAstKind.guardWithoutColon:
		case IfAstKind.ifWithoutElse:
		case IfAstKind.ternaryWithoutElse:
		case IfAstKind.unless:
			return 1;
		case IfAstKind.guardWithColon:
		case IfAstKind.ifElif:
		case IfAstKind.ifElse:
		case IfAstKind.ternaryWithElse:
			return 2;
	}
}

// Have to move this out of the struct due to forward reference error
IfAst createIfAst(
	ref Alloc alloc,
	Pos start,
	IfAstKind kind,
	bool isElseOfParent,
	Pos firstKeywordPos,
	ConditionAst condition,
	Opt!ExprAst firstBranch,
	Opt!Pos secondKeywordPos,
	Opt!ExprAst secondBranch,
) {
	assert(countIfBranches(kind) == has(firstBranch) + has(secondBranch));
	return IfAst(
		start: start,
		kind: kind,
		isElseOfParent: isElseOfParent,
		firstKeywordPos: firstKeywordPos,
		secondKeywordPos_: optOrDefault!Pos(secondKeywordPos, () => 0),
		condition: condition,
		branchesPtr: has(firstBranch)
			? has(secondBranch)
				? &newArray!ExprAst(alloc, [force(firstBranch), force(secondBranch)])[0]
				: allocate!ExprAst(alloc, force(firstBranch))
			: allocate!ExprAst(alloc, force(secondBranch)));
}

immutable struct InterpolatedAst {
	@safe @nogc pure nothrow:
	Range range;
	ExprAst[] parts;

	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct LambdaAst {
	@safe @nogc pure nothrow:
	Pos start;
	DestructureAst param;
	Pos arrowPos;
	ExprAst body_;

	Pos end() scope =>
		body_.end;
	Range arrowRange() scope =>
		rangeOfStartAndLength(arrowPos, "=>");
}

immutable struct DestructureAst {
	@safe @nogc pure nothrow:

	mixin Union!(SingleDestructureAst, VoidDestructureAst, DestructureAst[]);

	Range range() scope =>
		Range(start, end);

	Pos start() scope =>
		matchIn!Pos(
			(in SingleDestructureAst x) =>
				x.name.start,
			(in VoidDestructureAst x) =>
				x.range.start,
			(in DestructureAst[] parts) =>
				parts[0].start);

	Pos end() scope =>
		matchIn!Pos(
			(in SingleDestructureAst x) =>
				has(x.type)
					? force(x.type).range.end
					: x.name.end,
			(in VoidDestructureAst x) =>
				x.range.end,
			(in DestructureAst[] parts) =>
				parts[$ - 1].end);
}
immutable struct SingleDestructureAst {
	@safe @nogc pure nothrow:
	NameAndRange name; // Name may be '_', meaning ignore and don't create a local
	Opt!Pos mut; // position of 'mut' keyword if it exists
	Opt!(TypeAst*) type;

	Range range() scope =>
		Range(name.start, (
			has(type)
			? force(type).range
			: optOrDefault!Range(mutRange, () => name.range)
		).end);
	Range nameRange() scope =>
		name.range;
	Opt!Range mutRange() scope =>
		has(mut)
			? some(rangeOfStartAndLength(force(mut), safeToUint("mut".length)))
			: none!Range;
}
// `()` is a destructure matching only void values
immutable struct VoidDestructureAst {
	Range range;
}

immutable struct LetAst {
	@safe @nogc pure nothrow:
	DestructureAst destructure;
	ExprAst value;
	ExprAst then;
	Pos start() scope =>
		destructure.start;
	Pos end() scope =>
		then.end;
}

immutable struct HighPrecisionFloat {
	// value is longValue * (10 ** exponent)
	long longValue;
	long exponent;
}

immutable struct LiteralFloat {
	HighPrecisionFloat value;
	bool overflow;
}

immutable struct LiteralFloatAndRange {
	@safe @nogc pure nothrow:
	Range range;
	LiteralFloat literal;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct LiteralIntegral {
	bool isSigned;
	bool overflow;
	IntegralValue value;
}

immutable struct LiteralIntegralAndRange {
	@safe @nogc pure nothrow:
	Range range;
	LiteralIntegral literal;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct LiteralStringAst {
	@safe @nogc pure nothrow:
	Range range;
	string value;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct LoopAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst body_;
	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "loop");
	Pos end() scope =>
		body_.end;
}

immutable struct LoopBreakAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst value;

	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "break");
	Pos end() scope =>
		value.end;
}

immutable struct LoopContinueAst {
	@safe @nogc pure nothrow:
	Pos start;
	Pos end() scope =>
		keywordRange.end;
	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "continue");
}

immutable struct LoopWhileOrUntilAst {
	@safe @nogc pure nothrow:
	Pos start;
	bool isUntil;
	ConditionAst condition;
	ExprAst body_;
	ExprAst after;

	Pos end() scope =>
		after.end;
	Range keywordRange() scope {
		static assert("while".length == "until".length);
		return rangeOfStartAndLength(start, "while");
	}
}

immutable struct MatchAst {
	@safe @nogc pure nothrow:

	Pos start;
	ExprAst* matched;
	SmallArray!CaseAst cases;
	Opt!(MatchElseAst*) else_;

	Pos end() scope =>
		has(else_)
			? force(else_).end
			: !isEmpty(cases)
			? cases[$ - 1].end
			: matched.end;
	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "match");
}

immutable struct CaseAst {
	@safe @nogc pure nothrow:

	Pos keywordPos;
	CaseMemberAst member;
	ExprAst then;

	Range keywordAndMemberNameRange() scope =>
		Range(keywordPos, member.nameRange.end);
	Pos end() scope =>
		then.end;
}

immutable struct CaseMemberAst {
	@safe @nogc pure nothrow:

	mixin Union!(AsNameAst, LiteralIntegralAndRange, AsStringAst, AsBogusAst);
	Range nameRange() scope =>
		matchIn!Range(
			(in AsNameAst x) => x.name.range,
			(in LiteralIntegralAndRange x) => x.range,
			(in AsStringAst x) => x.range,
			(in AsBogusAst x) => x.range);
}
static assert(CaseMemberAst.sizeof == roundUp(AsNameAst.sizeof, 8) + ulong.sizeof);

immutable struct AsBogusAst {
	Range range;
}
immutable struct AsNameAst {
	NameAndRange name;
	Opt!DestructureAst destructure;
}
immutable struct AsStringAst {
	Range range;
	string value;
}

immutable struct MatchElseAst {
	@safe @nogc pure nothrow:
	Pos keywordPos;
	ExprAst expr;

	Pos end() scope =>
		expr.end;
	Range keywordRange() =>
		rangeOfStartAndLength(keywordPos, "else");
}

immutable struct ParenthesizedAst {
	@safe @nogc pure nothrow:
	Range range;
	ExprAst inner;
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
}

immutable struct PtrAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst inner;

	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "&");
	Pos end() scope =>
		inner.end;
}

immutable struct SeqAst {
	@safe @nogc pure nothrow:
	ExprAst first;
	ExprAst then;
	Pos start() scope =>
		first.start;
	Pos end() scope =>
		then.end;
}

immutable struct SharedAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst* inner;

	Pos end() scope =>
		inner.end;
	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "shared");
}

immutable struct ThrowAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst* thrown;

	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "throw".length);
	Pos end() scope =>
		thrown.end;
}

immutable struct TrustedAst {
	@safe @nogc pure nothrow:
	Pos start;
	ExprAst* inner;

	Range keywordRange() scope =>
		rangeOfStartAndLength(start, "trusted");
	Pos end() scope =>
		inner.end;
}

immutable struct TryAst {
	@safe @nogc pure nothrow:

	Pos start;
	ExprAst* tried;
	SmallArray!CaseAst catches;

	Range tryKeywordRange() scope =>
		rangeOfStartAndLength(start, "try");
	Pos end() scope =>
		catches[$ - 1].end;
}

immutable struct TryLetAst {
	@safe @nogc pure nothrow:

	Pos start;
	DestructureAst destructure;
	ExprAst value;
	Pos catchKeywordPos;
	CaseMemberAst catchMember;
	ExprAst catch_;
	ExprAst then;

	Pos end() scope =>
		then.end;
	Range tryKeywordRange() scope =>
		rangeOfStartAndLength(start, "try");
	Range catchKeywordRange() scope =>
		rangeOfStartAndLength(catchKeywordPos, "catch");
}

// expr :: t
immutable struct TypedAst {
	@safe @nogc pure nothrow:
	ExprAst expr;
	Pos colonPos;
	TypeAst type;

	Pos start() scope =>
		expr.start;
	Pos end() scope =>
		type.end;
	Range keywordRange() =>
		rangeOfStartAndLength(colonPos, "::");
	Range keywordAndTypeRange() =>
		combineRanges(keywordRange, type.range);
}

immutable struct WithAst {
	@safe @nogc pure nothrow:

	Pos start;
	DestructureAst param;
	Pos colonPos;
	ExprAst arg;
	ExprAst body_;
	ExprAst else_; // Usually EmptyAst (or else a compile error)

	Pos end() scope =>
		else_.isA!EmptyAst ? else_.end : body_.end;
	Range withKeywordRange() scope =>
		rangeOfStartAndLength(start, "with");
	Range colonRange() scope =>
		rangeOfStartAndLength(colonPos, ":");
}

immutable struct ExprAst {
	@safe @nogc pure nothrow:
	mixin Union!(
		ArrowAccessAst,
		AssertOrForbidAst,
		AssignmentAst*,
		AssignmentCallAst,
		BogusAst,
		CallAst,
		CallNamedAst,
		DoAst,
		EmptyAst,
		ExternAst,
		FinallyAst*,
		ForAst*,
		NameAndRange,
		IfAst,
		InterpolatedAst,
		LambdaAst*,
		LetAst*,
		LiteralFloatAndRange,
		LiteralIntegralAndRange,
		LiteralStringAst,
		LoopAst*,
		LoopBreakAst*,
		LoopContinueAst,
		LoopWhileOrUntilAst*,
		MatchAst,
		ParenthesizedAst*,
		PtrAst*,
		SeqAst*,
		SharedAst,
		ThrowAst,
		TrustedAst,
		TryAst,
		TryLetAst*,
		TypedAst*,
		WithAst*);
	
	Pos start() scope =>
		matchIn!Pos(
			(in ArrowAccessAst x) =>
				x.start,
			(in AssertOrForbidAst x) =>
				x.start,
			(in AssignmentAst x) =>
				x.start,
			(in AssignmentCallAst x) =>
				x.start,
			(in BogusAst x) =>
				x.start,
			(in CallAst x) =>
				x.start,
			(in CallNamedAst x) =>
				x.start,
			(in DoAst x) =>
				x.start,
			(in EmptyAst x) =>
				x.start,
			(in ExternAst x) =>
				x.start,
			(in FinallyAst x) =>
				x.start,
			(in ForAst x) =>
				x.start,
			(in NameAndRange x) =>
				x.start,
			(in IfAst x) =>
				x.start,
			(in InterpolatedAst x) =>
				x.start,
			(in LambdaAst x) =>
				x.start,
			(in LetAst x) =>
				x.start,
			(in LiteralFloatAndRange x) =>
				x.start,
			(in LiteralIntegralAndRange x) =>
				x.start,
			(in LiteralStringAst x) =>
				x.start,
			(in LoopAst x) =>
				x.start,
			(in LoopBreakAst x) =>
				x.start,
			(in LoopContinueAst x) =>
				x.start,
			(in LoopWhileOrUntilAst x) =>
				x.start,
			(in MatchAst x) =>
				x.start,
			(in ParenthesizedAst x) =>
				x.start,
			(in PtrAst x) =>
				x.start,
			(in SeqAst x) =>
				x.start,
			(in SharedAst x) =>
				x.start,
			(in ThrowAst x) =>
				x.start,
			(in TrustedAst x) =>
				x.start,
			(in TryAst x) =>
				x.start,
			(in TryLetAst x) =>
				x.start,
			(in TypedAst x) =>
				x.start,
			(in WithAst x) =>
				x.start);
	Pos end() scope =>
		matchIn!Pos(
			(in ArrowAccessAst x) =>
				x.end,
			(in AssertOrForbidAst x) =>
				x.end,
			(in AssignmentAst x) =>
				x.end,
			(in AssignmentCallAst x) =>
				x.end,
			(in BogusAst x) =>
				x.end,
			(in CallAst x) =>
				x.end,
			(in CallNamedAst x) =>
				x.end,
			(in DoAst x) =>
				x.end,
			(in EmptyAst x) =>
				x.end,
			(in ExternAst x) =>
				x.end,
			(in FinallyAst x) =>
				x.end,
			(in ForAst x) =>
				x.end,
			(in NameAndRange x) =>
				x.end,
			(in IfAst x) =>
				x.end,
			(in InterpolatedAst x) =>
				x.end,
			(in LambdaAst x) =>
				x.end,
			(in LetAst x) =>
				x.end,
			(in LiteralFloatAndRange x) =>
				x.end,
			(in LiteralIntegralAndRange x) =>
				x.end,
			(in LiteralStringAst x) =>
				x.end,
			(in LoopAst x) =>
				x.end,
			(in LoopBreakAst x) =>
				x.end,
			(in LoopContinueAst x) =>
				x.end,
			(in LoopWhileOrUntilAst x) =>
				x.end,
			(in MatchAst x) =>
				x.end,
			(in ParenthesizedAst x) =>
				x.end,
			(in PtrAst x) =>
				x.end,
			(in SeqAst x) =>
				x.end,
			(in SharedAst x) =>
				x.end,
			(in ThrowAst x) =>
				x.end,
			(in TrustedAst x) =>
				x.end,
			(in TryAst x) =>
				x.end,
			(in TryLetAst x) =>
				x.end,
			(in TypedAst x) =>
				x.end,
			(in WithAst x) =>
				x.end);
	Range range() scope =>
		Range(start, end);
}
version (WebAssembly) {} else {
	static assert(ExprAst.sizeof == CallAst.sizeof + ulong.sizeof);
}

immutable struct ParamsAst {
	mixin TaggedUnion!(SmallArray!DestructureAst, VarargsAst*);
}
immutable struct VarargsAst {
	DestructureAst param;
}

DestructureAst[] paramsArray(return scope ParamsAst a) =>
	a.matchWithPointers!(DestructureAst[])(
		(DestructureAst[] x) =>
			x,
		(VarargsAst* x) =>
			arrayOfSingle(&x.param));

immutable struct SignatureAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Symbol name;
	TypeAst returnType;
	ParamsAst params;

	NameAndRange nameAndRange() scope =>
		NameAndRange(range.start, name);
	Range nameRange() scope =>
		nameAndRange.range;
}

immutable struct StructAliasAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Opt!Visibility visibility_;
	NameAndRange name;
	SmallArray!NameAndRange typeParams;
	Pos keywordPos;
	TypeAst target;

	Range nameRange() scope =>
		name.range;
	Range keywordRange() scope =>
		rangeOfStartAndLength(keywordPos, "alias");
	Opt!VisibilityAndRange visibility() scope =>
		getVisibilityAndRange(range.start, visibility_);
}

Range typeParamsRange(in SmallArray!NameAndRange typeParams) {
	assert(!isEmpty(typeParams));
	return combineRanges(
		typeParams[0].range,
		typeParams[$ - 1].range);
}

immutable struct ModifierAst {
	@safe @nogc pure nothrow:

	mixin Union!(ModifierKeywordAst, SpecUseAst);

	Range range() scope =>
		matchIn!Range(
			(in ModifierKeywordAst x) =>
				x.range,
			(in SpecUseAst x) =>
				x.range);
}

immutable struct ModifierKeywordAst {
	@safe @nogc pure nothrow:

	Opt!TypeAst typeArg;
	Pos keywordPos;
	ModifierKeyword keyword;

	Range range() scope =>
		has(typeArg)
			? combineRanges(force(typeArg).range, keywordRange)
			: keywordRange;
	Range keywordRange() scope =>
		rangeOfStartAndLength(keywordPos, stringOfModifierKeyword(keyword));
}

immutable struct SpecUseAst {
	@safe @nogc pure nothrow:
	Opt!TypeAst typeArg;
	NameAndRange name;

	Range range() scope =>
		has(typeArg)
			? combineRanges(force(typeArg).range, name.range)
			: name.range;
	Range nameRange() scope =>
		name.range;
}

enum ModifierKeyword : ubyte {
	bare,
	builtin,
	byRef,
	byVal,
	case_,
	data,
	// It's a compile error to have extern without a library name,
	// so those will usually be a Extern instead
	extern_,
	forceCtx,
	forceShared,
	mut,
	newInternal,
	newPublic,
	newPrivate,
	nominal,
	packed,
	pure_,
	shared_,
	storage,
	summon,
	trusted,
	unsafe,
}

immutable struct StructBodyAst {
	mixin .Union!(BuiltinTypeAst, EnumAst, ExternTypeAst, FlagsAst, RecordAst, SumTypeAst);
}
static assert(StructBodyAst.sizeof <= 24);


immutable struct BuiltinTypeAst {}
immutable struct EnumAst {
	Opt!ParamsAst params;
	SmallArray!EnumOrFlagsMemberAst members;
}
immutable struct ExternTypeAst {
	Opt!(LiteralIntegralAndRange*) size;
	Opt!(LiteralIntegralAndRange*) alignment;
}
immutable struct FlagsAst {
	Opt!ParamsAst params;
	SmallArray!EnumOrFlagsMemberAst members;
}
immutable struct RecordAst {
	Opt!ParamsAst params;
	SmallArray!RecordFieldAst fields;
}
immutable struct SumTypeAst {
	@safe @nogc pure nothrow:
	SumTypeKind kind;
	immutable struct TypesAndMethods {
		SmallArray!TypeAst types;
		SmallArray!SignatureAst methods;
	}
	private TypesAndMethods* typesAndMethods;

	SmallArray!TypeAst types() return scope =>
		typesAndMethods.types;
	SmallArray!SignatureAst methods() return scope =>
		typesAndMethods.methods;
}

immutable struct EnumOrFlagsMemberAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Symbol name;
	Opt!LiteralIntegralAndRange value;

	NameAndRange nameAndRange() scope =>
		NameAndRange(range.start, name);
	Range nameRange() scope =>
		nameAndRange.range;
}

immutable struct RecordFieldAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Opt!Visibility visibility_;
	NameAndRange name;
	Opt!FieldMutabilityAst mutability;
	Opt!TypeAst type;

	Opt!VisibilityAndRange visibility() scope =>
		getVisibilityAndRange(range.start, visibility_);

	Range nameRange() scope =>
		name.range;
}

immutable struct StructDeclAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	// Range starts at the visibility
	Range range;
	Opt!Visibility visibility_;
	NameAndRange name;
	SmallArray!NameAndRange typeParams;
	Pos keywordPos;
	SmallArray!ModifierAst modifiers;
	StructBodyAst body_;

	Range nameRange() scope =>
		name.range;
	Range keywordRange() scope =>
		rangeOfStartAndLength(keywordPos, keywordForStructBody(body_));
	Opt!VisibilityAndRange visibility() scope =>
		getVisibilityAndRange(range.start, visibility_);
}

private string keywordForStructBody(in StructBodyAst a) =>
	a.matchIn!string(
		(in BuiltinTypeAst _) =>
			"builtin",
		(in EnumAst _) =>
			"enum",
		(in ExternTypeAst _) =>
			"extern",
		(in FlagsAst _) =>
			"flags",
		(in RecordAst _) =>
			"record",
		(in SumTypeAst x) =>
			stringOfEnum(x.kind));

immutable struct SpecDeclAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Opt!Visibility visibility_;
	NameAndRange name;
	SmallArray!NameAndRange typeParams;
	Pos specKeywordPos;
	SmallArray!ModifierAst modifiers;
	SmallArray!SignatureAst sigs;

	Range nameRange() scope =>
		name.range;
	Range keywordRange() scope =>
		rangeOfStartAndLength(specKeywordPos, "spec");
	Opt!VisibilityAndRange visibility() scope =>
		getVisibilityAndRange(range.start, visibility_);
}

immutable struct FunDeclAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Opt!Visibility visibility_;
	NameAndRange name;
	SmallArray!NameAndRange typeParams;
	TypeAst returnType;
	ParamsAst params;
	SmallArray!ModifierAst modifiers;
	ExprAst body_; // EmptyAst if missing

	Opt!VisibilityAndRange visibility() scope =>
		getVisibilityAndRange(range.start, visibility_);

	Range nameRange() scope =>
		name.range;
}

string stringOfModifierKeyword(ModifierKeyword a) {
	final switch (a) {
		case ModifierKeyword.bare:
			return "bare";
		case ModifierKeyword.builtin:
			return "builtin";
		case ModifierKeyword.byRef:
			return "by-ref";
		case ModifierKeyword.byVal:
			return "by-val";
		case ModifierKeyword.case_:
			return "case";
		case ModifierKeyword.data:
			return "data";
		case ModifierKeyword.extern_:
			return "extern";
		case ModifierKeyword.forceCtx:
			return "force-ctx";
		case ModifierKeyword.forceShared:
			return "force-shared";
		case ModifierKeyword.mut:
			return "mut";
		case ModifierKeyword.newInternal:
			return "~new";
		case ModifierKeyword.newPrivate:
			return "-new";
		case ModifierKeyword.newPublic:
			return "+new";
		case ModifierKeyword.nominal:
			return "nominal";
		case ModifierKeyword.packed:
			return "packed";
		case ModifierKeyword.pure_:
			return "pure";
		case ModifierKeyword.shared_:
			return "shared";
		case ModifierKeyword.storage:
			return "storage";
		case ModifierKeyword.summon:
			return "summon";
		case ModifierKeyword.trusted:
			return "trusted";
		case ModifierKeyword.unsafe:
			return "unsafe";
	}
}

immutable struct TestAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	SmallArray!ModifierAst modifiers;
	ExprAst body_; // EmptyAst if missing

	Range keywordRange() scope =>
		rangeOfStartAndLength(range.start, "test");
}

// 'global' or 'thread-local'
immutable struct VarDeclAst {
	@safe @nogc pure nothrow:

	DocCommentAst docComment;
	Range range;
	Opt!Visibility visibility_;
	NameAndRange name;
	SmallArray!NameAndRange typeParams; // This will be a compile error
	Pos keywordPos;
	VarKind kind;
	TypeAst type;
	SmallArray!ModifierAst modifiers; // Any but 'extern' will be a compile error

	Range nameRange() scope =>
		name.range;
	Range keywordRange() scope =>
		rangeOfStartAndLength(keywordPos, stringOfVarKindLowerCase(kind));
	Opt!VisibilityAndRange visibility() scope =>
		getVisibilityAndRange(range.start, visibility_);
}

immutable struct ImportOrExportAst {
	@safe @nogc pure nothrow:
	Range range;
	// Does not include the extension (which is only allowed for file imports)
	PathOrRelPath path;
	ImportOrExportAstKind kind;

	Range pathRange() scope =>
		rangeOfStartAndLength(range.start, pathOrRelPathLength(path));
}

immutable struct PathOrRelPath {
	mixin TaggedUnion!(Path, RelPath);
}
private size_t pathOrRelPathLength(in PathOrRelPath a) =>
	a.matchIn!size_t(
		(in Path x) =>
			pathLength(x),
		(in RelPath x) =>
			relPathLength(x));

immutable struct ImportOrExportAstKind {
	mixin TaggedUnion!(ImportWholeModuleAst, SmallArray!NameAndRange, ImportFileAst*);
}
immutable struct ImportWholeModuleAst {}
immutable struct ImportFileAst {
	NameAndRange name;
	TypeAst typeAst;
	ImportFileType type;
}

enum ImportFileType { nat8Array, string }

immutable struct ImportsOrExportsAst {
	Range range;
	SmallArray!ImportOrExportAst paths;
}

immutable struct DocCommentAst {
	@safe @nogc pure nothrow:
	private Opt!(DocCommentContent*) content;

	static DocCommentAst empty() =>
		DocCommentAst(none!(DocCommentContent*));

	bool isEmpty() scope =>
		!has(content);

	Opt!Range range() scope =>
		optIf(has(content), () =>
			force(content).range);

	SmallArray!NameAndRange references() return scope =>
		has(content)
			? force(content).references
			: emptySmallArray!NameAndRange;
}
immutable struct DocCommentContent {
	Range range;
	SmallArray!NameAndRange references;
}

immutable struct FileAst {
	SmallArray!ParseDiagnostic parseDiagnostics;
	DocCommentAst docComment;
	bool noStd;
	Opt!ImportsOrExportsAst imports;
	Opt!ImportsOrExportsAst reExports;
	// Stores range of each 'region' comment. (Not the range of the region itself.)
	SmallArray!Range regions;
	SmallArray!SpecDeclAst specs;
	SmallArray!StructAliasAst structAliases;
	SmallArray!StructDeclAst structs;
	SmallArray!FunDeclAst funs;
	SmallArray!TestAst tests;
	SmallArray!VarDeclAst vars;
}

private FileAst fileAstForDiags(SmallArray!ParseDiagnostic diags) =>
	// Make sure the dummy AST doesn't have implicit imports
	FileAst(diags, noStd: true);

FileAst fileAstForDiag(ref Alloc alloc, ParseDiag diag) =>
	fileAstForDiags(newSmallArray(alloc, [ParseDiagnostic(Range.empty, diag)]));
