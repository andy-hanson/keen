module model.ast;

@safe @nogc pure nothrow:

import model.parseDiag : ParseDiag, ParseDiagnostic;
import util.alloc.alloc : Alloc;
import util.col.array : arrayOfSingle, emptySmallArray, exists, isEmpty, newArray, newSmallArray, sizeEq, SmallArray;
import util.conv : safeToUint;
import util.integralValues : IntegralValue;
import util.memory : allocate;
import util.opt : force, has, none, Opt, optIf, optOrDefault, some;
import util.sourceRange : combineRanges, Pos, Range, rangeOfStartAndLength;
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

	Range range() scope =>
		rangeOfStartAndLength(start, symbolSize(name));
}
static assert(NameAndRange.sizeof == ulong.sizeof);

immutable struct FieldMutabilityAst {
	@safe @nogc pure nothrow:

	Pos pos;
	Opt!Visibility visibility_;

	Range range() =>
		rangeOfStartAndLength(pos, has(visibility) ? "-mut".length : "mut".length);

	Opt!VisibilityAndRange visibility() =>
		getVisibilityAndRange(pos, visibility_);
}
static assert(FieldMutabilityAst.sizeof == ulong.sizeof);

immutable struct VisibilityAndRange {
	@safe @nogc pure nothrow:

	Visibility visibility;
	Pos pos;

	Range range() =>
		rangeOfStartAndLength(pos, "+".length);
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
		rangeOfStartAndLength(kindPos, stringOfEnum(kind).length);
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
enum SuffixSpecialTypeAstKind : ubyte { array, mutArray, mutPtr, option, ptr, sharedArray }

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
		case SuffixSpecialTypeAstKind.option:
			return cast(uint) "?".length;
		case SuffixSpecialTypeAstKind.mutArray:
			return cast(uint) "mut[]".length;
		case SuffixSpecialTypeAstKind.mutPtr:
			return cast(uint) "mut*".length;
		case SuffixSpecialTypeAstKind.ptr:
			return cast(uint) "*".length;
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
		case SuffixSpecialTypeAstKind.mutArray:
			return symbol!"mut-array";
		case SuffixSpecialTypeAstKind.mutPtr:
			return symbol!"mut-pointer";
		case SuffixSpecialTypeAstKind.option:
			return symbol!"option";
		case SuffixSpecialTypeAstKind.ptr:
			return symbol!"const-pointer";
		case SuffixSpecialTypeAstKind.sharedArray:
			return symbol!"shared-array";
	}
}

immutable struct ArrowAccessAst {
	@safe @nogc pure nothrow:
	ExprAst* left;
	Pos keywordPos;
	NameAndRange name;

	Range arrowRange() scope =>
		rangeOfStartAndLength(keywordPos, "->".length);
	Range arrowAndNameRange() scope =>
		combineRanges(arrowRange, name.range);
}

immutable struct AssertOrForbidAst {
	@safe @nogc pure nothrow:

	bool isForbid;
	ConditionAst condition;
	Opt!(AssertOrForbidThrownAst*) thrown;
	ExprAst* after;

	Range keywordRange(in ExprAst* ast) scope {
		static assert("assert".length == "forbid".length);
		return ast.range[0 .. "assert".length];
	}
}
immutable struct AssertOrForbidThrownAst {
	@safe @nogc pure nothrow:
	Pos colonPos;
	ExprAst expr;

	Range colonRange() scope =>
		rangeOfStartAndLength(colonPos, ":".length);
}

// `left := right`
immutable struct AssignmentAst {
	@safe @nogc pure nothrow:
	ExprAst left;
	Pos assignmentPos;
	ExprAst right;

	Range keywordRange() =>
		rangeOfStartAndLength(assignmentPos, ":=".length);
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

	Range keywordRange() =>
		rangeOfStartAndLength(funName.range.end, ":=".length);
}

immutable struct BogusAst {}

immutable struct CallAst {
	@safe @nogc pure nothrow:

	CallAstStyle style;
	Pos keywordPos; // Position of '.' or '?'
	NameAndRange funName;
	SmallArray!ExprAst args;
	Opt!(TypeAst*) typeArg;

	this(CallAstStyle s, NameAndRange fn, SmallArray!ExprAst a, Opt!(TypeAst*) ta = none!(TypeAst*)) {
		this(s, Pos.max, fn, a, ta);
	}
	this(CallAstStyle s, Pos kp, NameAndRange fn, SmallArray!ExprAst a, Opt!(TypeAst*) ta = none!(TypeAst*)) {
		style = s;
		keywordPos = kp;
		funName = fn;
		args = a;
		typeArg = ta;
		assert(has(keywordRange) == (keywordPos != Pos.max));
	}

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
	single, // `a@t` (without the type arg, it would just be an Identifier)
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
}

immutable struct DoAst {
	ExprAst* body_;
}

// Used for implicit 'else ()' or implicit '()' after a Let
immutable struct EmptyAst {}

immutable struct ExternAst {
	NameAndRange[] names;
}

immutable struct FinallyAst {
	@safe @nogc pure nothrow:

	ExprAst right;
	ExprAst below;

	Range finallyKeywordRange(in ExprAst* ast) scope {
		assert(ast.kind.as!(FinallyAst*) == &this);
		return ast.range[0 .. "finally".length];
	}
}

immutable struct ForAst {
	@safe @nogc pure nothrow:
	DestructureAst param;
	Pos colonPos;
	ExprAst collection;
	ExprAst body_;
	ExprAst else_; // May be EmptyAst

	Range forKeywordRange(in ExprAst source) scope {
		assert(source.kind.as!(ForAst*) == &this);
		return source.range[0 .. "for".length];
	}
	Range colonRange() scope =>
		rangeOfStartAndLength(colonPos, ":".length);
}

immutable struct IdentifierAst {
	Symbol name;
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
		combineRanges(destructure.range, option.range);
	Range questionEqualsRange() scope =>
		rangeOfStartAndLength(questionEqualsPos, "?=".length);
}

immutable struct IfAst {
	@safe @nogc pure nothrow:
	IfAstKind kind;
	bool isElseOfParent; // 'ifWithoutElse', 'ifElif', and 'ifElse' could all be the 'else' branch of a preceding 'if'
	Pos firstKeywordPos; // Position of 'if' or '?' or 'unless'
	Pos secondKeywordPos_; // Position of 'elif' or 'else' or ':' keyword
	ConditionAst condition;
	// How many branches this points to depends on 'kind'. See 'countIfBranches'.
	private ExprAst* branchesPtr;

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
	ExprAst[] parts;
}

immutable struct LambdaAst {
	@safe @nogc pure nothrow:
	DestructureAst param;
	Pos arrowPos;
	ExprAst body_;

	Range arrowRange() scope =>
		rangeOfStartAndLength(arrowPos, "=>".length);
}

immutable struct DestructureAst {
	@safe @nogc pure nothrow:

	mixin Union!(SingleDestructureAst, VoidDestructureAst, DestructureAst[]);

	Pos pos() scope =>
		matchIn!Pos(
			(in SingleDestructureAst x) =>
				x.name.start,
			(in VoidDestructureAst x) =>
				x.range.start,
			(in DestructureAst[] parts) =>
				parts[0].pos);

	Range range() scope =>
		matchIn!Range(
			(in SingleDestructureAst x) {
				Range name = x.name.range;
				return has(x.type)
					? Range(name.start, force(x.type).range.end)
					: name;
			},
			(in VoidDestructureAst x) =>
				x.range,
			(in DestructureAst[] parts) =>
				Range(parts[0].range.start, parts[$ - 1].range.end));
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
			? some(Range(force(mut), force(mut) + safeToUint("mut".length)))
			: none!Range;
}
// `()` is a destructure matching only void values
immutable struct VoidDestructureAst {
	Range range;
}

immutable struct LetAst {
	DestructureAst destructure;
	ExprAst value;
	ExprAst then;
}

immutable struct HighPrecisionFloat {
	// value is longValue * (10 ** exponent)
	long longValue;
	long exponent;
}

immutable struct LiteralFloatAst {
	HighPrecisionFloat value;
	bool overflow;
}

immutable struct LiteralIntegral {
	bool isSigned;
	bool overflow;
	IntegralValue value;
}

immutable struct LiteralIntegralAndRange {
	Range range;
	LiteralIntegral literal;
}

immutable struct LiteralStringAst {
	string value;
}

immutable struct LoopAst {
	@safe @nogc pure nothrow:
	ExprAst body_;
	Range keywordRange(in ExprAst* source) scope {
		assert(source.kind.as!(LoopAst*) == &this);
		return source.range[0 .. "loop".length];
	}
}

immutable struct LoopBreakAst {
	@safe @nogc pure nothrow:
	ExprAst value;

	Range keywordRange(in ExprAst* source) scope {
		assert(source.kind.as!(LoopBreakAst*) == &this);
		return source.range[0 .. "break".length];
	}
}

immutable struct LoopContinueAst {
	@safe @nogc pure nothrow:
	Range keywordRange(in ExprAst* source) =>
		source.range[0 .. "continue".length];
}

immutable struct LoopWhileOrUntilAst {
	@safe @nogc pure nothrow:
	bool isUntil;
	ConditionAst condition;
	ExprAst body_;
	ExprAst after;

	Range keywordRange(in ExprAst* source) scope {
		assert(source.kind.as!(LoopWhileOrUntilAst*) == &this);
		static assert("while".length == "until".length);
		return source.range[0 .. "while".length];
	}
}

immutable struct MatchAst {
	@safe @nogc pure nothrow:

	ExprAst* matched;
	SmallArray!CaseAst cases;
	Opt!(MatchElseAst*) else_;

	Range keywordRange(in ExprAst* source) scope =>
		rangeOfStartAndLength(source.range.start, "match".length);
}

immutable struct CaseAst {
	@safe @nogc pure nothrow:

	Pos keywordPos;
	CaseMemberAst member;
	ExprAst then;

	Range keywordAndMemberNameRange() scope =>
		Range(keywordPos, member.nameRange.end);
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

	Range keywordRange() =>
		rangeOfStartAndLength(keywordPos, "else".length);
}

immutable struct ParenthesizedAst {
	ExprAst inner;
}

immutable struct PtrAst {
	@safe @nogc pure nothrow:
	ExprAst inner;

	Range keywordRange(in ExprAst* ast) scope {
		assert(ast.kind.as!(PtrAst*) == &this);
		return ast.range[0 .. "&".length];
	}
}

immutable struct SeqAst {
	ExprAst first;
	ExprAst then;
}

immutable struct SharedAst {
	@safe @nogc pure nothrow:
	ExprAst inner;

	Range keywordRange(in ExprAst ast) scope {
		assert(ast.kind.as!(SharedAst*) == &this);
		return ast.range[0 .. "shared".length];
	}
}

immutable struct ThrowAst {
	@safe @nogc pure nothrow:
	ExprAst thrown;

	Range keywordRange(in ExprAst* ast) scope {
		assert(ast.kind.as!(ThrowAst*) == &this);
		return ast.range[0 .. "throw".length];
	}
}

immutable struct TrustedAst {
	@safe @nogc pure nothrow:
	ExprAst inner;

	Range keywordRange(in ExprAst* ast) scope {
		assert(ast.kind.as!(TrustedAst*) == &this);
		return ast.range[0 .. "trusted".length];
	}
}

immutable struct TryAst {
	@safe @nogc pure nothrow:

	ExprAst* tried;
	SmallArray!CaseAst catches;

	Range tryKeywordRange(in ExprAst* ast) scope =>
		ast.range[0 .. "try".length];
}

immutable struct TryLetAst {
	@safe @nogc pure nothrow:

	DestructureAst destructure;
	ExprAst value;
	Pos catchKeywordPos;
	CaseMemberAst catchMember;
	ExprAst catch_;
	ExprAst then;

	Range tryKeywordRange(in ExprAst* ast) scope =>
		ast.range[0 .. "try".length];
	Range catchKeywordRange() scope =>
		rangeOfStartAndLength(catchKeywordPos, "catch".length);
}

// expr :: t
immutable struct TypedAst {
	@safe @nogc pure nothrow:
	ExprAst expr;
	Pos colonPos;
	TypeAst type;

	Range keywordRange() =>
		rangeOfStartAndLength(colonPos, "::".length);
	Range keywordAndTypeRange() =>
		combineRanges(keywordRange, type.range);
}

immutable struct WithAst {
	@safe @nogc pure nothrow:

	DestructureAst param;
	Pos colonPos;
	ExprAst arg;
	ExprAst body_;
	ExprAst else_; // May be EmptyAst (or else a compile error)

	Range withKeywordRange(in ExprAst ast) scope {
		assert(ast.kind.as!(WithAst*) == &this);
		return ast.range[0 .. "with".length];
	}
	Range colonRange() scope =>
		rangeOfStartAndLength(colonPos, ":".length);
}

immutable struct ExprAstKind {
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
		IdentifierAst,
		IfAst,
		InterpolatedAst,
		LambdaAst*,
		LetAst*,
		LiteralFloatAst,
		LiteralIntegral,
		LiteralStringAst,
		LoopAst*,
		LoopBreakAst*,
		LoopContinueAst,
		LoopWhileOrUntilAst*,
		MatchAst,
		ParenthesizedAst*,
		PtrAst*,
		SeqAst*,
		SharedAst*,
		ThrowAst*,
		TrustedAst*,
		TryAst,
		TryLetAst*,
		TypedAst*,
		WithAst*);
}
version (WebAssembly) {} else {
	static assert(ExprAstKind.sizeof == CallAst.sizeof + ulong.sizeof);
}

immutable struct ExprAst {
	Range range;
	ExprAstKind kind;
}
static assert(ExprAst.sizeof <= 6 * ulong.sizeof);

ExprAst bogusExpr(in Range range) =>
	ExprAst(range, ExprAstKind(BogusAst()));

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
		rangeOfStartAndLength(keywordPos, "alias".length);
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
		rangeOfStartAndLength(keywordPos, stringOfModifierKeyword(keyword).length);
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
		rangeOfStartAndLength(keywordPos, keywordForStructBody(body_).length);
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
		rangeOfStartAndLength(specKeywordPos, "spec".length);
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
		rangeOfStartAndLength(range.start, "test".length);
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
		rangeOfStartAndLength(keywordPos, stringOfVarKindLowerCase(kind).length);
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
