module model.concreteModel;

@safe @nogc pure nothrow:

import model.constant : Constant;
import model.model :
	BuiltinFun,
	BuiltinType,
	CommonTypes,
	EnumOrFlagsMember,
	Expr,
	FunDecl,
	IntegralType,
	isOptionType,
	isString,
	isTuple,
	Local,
	Params,
	Purity,
	mustBeEnumOrFlags,
	StructBody,
	StructDecl,
	Test,
	TypeSize,
	VarDecl;
import util.col.array : arraysEqual, exists, isEmpty, only, SmallArray;
import util.col.set : Set;
import util.hash : HashCode, Hasher, hashPointer;
import util.integralValues : IntegralValue, IntegralValues;
import util.late : Late, lateGet, lateIsSet, lateSet, lateSetOverwrite;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : UriAndRange;
import util.string : CString;
import util.symbol : Symbol;
import util.union_ : TaggedUnion, Union;
import util.uri : Uri;
import versionInfo : VersionInfo;

immutable struct ConcreteStructBody {
	immutable struct Builtin {
		BuiltinType kind;
		SmallArray!ConcreteType typeArgs;
	}
	immutable struct Enum {
		IntegralType storage;
	}
	immutable struct Flags {
		IntegralType storage;
	}
	immutable struct Extern {}
	immutable struct Record {
		SmallArray!ConcreteField fields;
	}
	// Lambdas and all StructBody.Variant kinds compile to this
	immutable struct Union {
		@safe @nogc pure nothrow:
		// In the concrete model we identify members by index, so don't care about their names.
		// This may be empty for a lambda type with no implementations.
		Late!(SmallArray!ConcreteType) members_;

		bool hasMembers() scope => // used? -----------------------------------------------------------------------------------
			lateIsSet(members_);
		SmallArray!ConcreteType members() return scope =>
			lateGet(members_);
		void members(SmallArray!ConcreteType value) {
			lateSet(members_, value);
		}
	}

	mixin .Union!(Builtin*, Enum, Extern, Flags, Record, Union);
}
static assert(ConcreteStructBody.sizeof == ConcreteStructBody.Record.sizeof + size_t.sizeof);

immutable struct ConcreteType {
	@safe @nogc pure nothrow:

	ReferenceKind reference;
	ConcreteStruct* struct_;

	static ConcreteType byVal(ConcreteStruct* struct_) =>
		ConcreteType(ReferenceKind.byVal, struct_);

	bool opEquals(scope ConcreteType b) scope =>
		struct_ == b.struct_ && reference == reference;

	HashCode hash() scope =>
		hashPointer(struct_);
}

bool isBogus(in ConcreteType a) =>
	a.reference == ReferenceKind.byVal &&
	isBogus(*a.struct_);
bool isVoid(in ConcreteType a) =>
	a.reference == ReferenceKind.byVal &&
	a.struct_.body_.isA!(ConcreteStructBody.Builtin*) &&
	a.struct_.body_.as!(ConcreteStructBody.Builtin*).kind == BuiltinType.void_;
bool isEmptyType(in ConcreteType a) =>
	a.reference == ReferenceKind.byVal && isEmptyStruct(*a.struct_);
bool isEmptyStruct(in ConcreteStruct a) =>
	a.typeSize.sizeBytes == 0;

alias ReferenceKind = immutable ReferenceKind_;
private enum ReferenceKind_ { byVal, byRef }

Purity purity(ConcreteType a) =>
	a.struct_.purity;

ConcreteStruct* mustBeByVal(ConcreteType a) {
	assert(a.reference == ReferenceKind.byVal);
	return a.struct_;
}

EnumOrFlagsMember[] mustBeEnumOrFlags(ConcreteType a) =>
	mustBeEnumOrFlags(*mustBeByVal(a).source.as!(ConcreteStructSource.Inst).decl);
EnumOrFlagsMember[] mustBeEnum(ConcreteType a) =>
	mustBeByVal(a).source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Enum*).members;
ref StructBody.Flags mustBeFlags(ConcreteType a) =>
	mustBeByVal(a).source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Flags);

immutable struct ConcreteStructInfo {
	ConcreteStructBody body_;
	bool isSelfMutable; //TODO: never used? (may need for GC though)
}

immutable struct ConcreteStructSource {
	immutable struct Bogus {}

	immutable struct Inst {
		@safe @nogc pure nothrow:
		StructDecl* decl;
		SmallArray!ConcreteType typeArgs;

		this(StructDecl* d, SmallArray!ConcreteType ta) {
			decl = d;
			typeArgs = ta;
			assert(typeArgs.length == decl.typeParams.length);
			assert(!isString(*decl)); // Concretize should replace 'string' with 'char8 array'
		}

		bool opEquals(in Inst b) scope =>
			decl == b.decl && arraysEqual!ConcreteType(typeArgs, b.typeArgs);

		HashCode hash() scope {
			Hasher hasher;
			hasher ~= decl;
			foreach (ConcreteType t; typeArgs)
				hasher ~= t.struct_;
			return hasher.finish();
		}
	}

	immutable struct Lambda {
		ConcreteFun* containingFun;
		size_t index;
	}

	mixin Union!(Bogus, Inst, Lambda);
}

immutable struct ConcreteStruct {
	@safe @nogc pure nothrow:

	enum SpecialKind {
		none,
		arrayOrMutArray,
		catchPoint,
		fiber,
		pointer, // mut or const
		tuple,
	}

	Purity purity;
	SpecialKind specialKind;
	ConcreteStructSource source;
	private Late!ConcreteStructInfo info_;
	//TODO: this isn't needed outside of concretizeCtx.d
	private Late!ReferenceKind defaultReferenceKind_;
	private Late!TypeSize typeSize_;
	// Only set for records
	private Late!(immutable uint[]) fieldOffsets_;

	bool infoIsSet() scope =>
		lateIsSet(info_);
	void info(ConcreteStructInfo value) {
		lateSet(info_, value);
	}
	private ref ConcreteStructInfo info() return scope =>
		lateGet(info_);

	ref ConcreteStructBody body_() return scope =>
		info.body_;

	bool isSelfMutable() scope =>
		info.isSelfMutable;

	bool typeSizeIsSet() scope =>
		lateIsSet(typeSize_);
	TypeSize typeSize() scope =>
		lateGet(typeSize_);
	void typeSize(TypeSize value) {
		lateSet(typeSize_, value);
	}

	ReferenceKind defaultReferenceKind() scope =>
		lateGet(defaultReferenceKind_);
	void defaultReferenceKind(ReferenceKind value) {
		lateSet(defaultReferenceKind_, value);
	}
	bool defaultReferenceKindIsSet() =>
		lateIsSet(defaultReferenceKind_);

	immutable(uint[]) fieldOffsets() =>
		lateGet(fieldOffsets_);
	void fieldOffsets(immutable uint[] value) {
		lateSet(fieldOffsets_, value);
	}
}

bool isArrayOrMutArray(in ConcreteStruct a) =>
	a.specialKind == ConcreteStruct.SpecialKind.arrayOrMutArray;
ConcreteType arrayElementType(ConcreteType arrayType) {
	assert(isArrayOrMutArray(*mustBeByVal(arrayType)));
	return only(mustBeByVal(arrayType).source.as!(ConcreteStructSource.Inst).typeArgs);
}
private bool isOption(in ConcreteStruct a) =>
	a.source.isA!(ConcreteStructSource.Inst) && isOptionType(a.source.as!(ConcreteStructSource.Inst).decl);

ConcreteType unwrapOptionType(ConcreteType optionType) {
	assert(isOption(*mustBeByVal(optionType)));
	return only(mustBeByVal(optionType).source.as!(ConcreteStructSource.Inst).typeArgs);
}
bool isCatchPoint(in ConcreteStruct a) =>
	a.specialKind == ConcreteStruct.SpecialKind.catchPoint;
bool isFiber(in ConcreteStruct a) =>
	a.specialKind == ConcreteStruct.SpecialKind.fiber;
bool isPointer(ConcreteType a) =>
	a.reference == ReferenceKind.byVal && isPointer(*a.struct_);
private bool isPointer(in ConcreteStruct a) =>
	a.specialKind == ConcreteStruct.SpecialKind.pointer;
ConcreteType pointeeType(ConcreteType pointerType) {
	assert(isPointer(*mustBeByVal(pointerType)));
	return only(mustBeByVal(pointerType).source.as!(ConcreteStructSource.Inst).typeArgs);
}
ConcreteType pointeeTypeIfIsPointer(ConcreteType a) =>
	isPointer(a)
		? pointeeType(a)
		: a;
private bool isBogus(in ConcreteStruct a) =>
	a.source.isA!(ConcreteStructSource.Bogus);
bool isTuple(in ConcreteStruct a) =>
	a.specialKind == ConcreteStruct.SpecialKind.tuple;

//TODO: this is only useful during concretize, move
bool hasSizeOrPointerSizeBytes(in ConcreteType a) {
	final switch (a.reference) {
		case ReferenceKind.byVal:
			return lateIsSet(a.struct_.typeSize_);
		case ReferenceKind.byRef:
			return true;
	}
}

TypeSize sizeOrPointerSizeBytes(in ConcreteType a) {
	final switch (a.reference) {
		case ReferenceKind.byVal:
			return a.struct_.typeSize;
		case ReferenceKind.byRef:
			return TypeSize(8, 8);
	}
}

enum ConcreteMutability {
	const_,
	mutable,
}

immutable struct ConcreteField {
	Symbol debugName;
	ConcreteMutability mutability;
	ConcreteType type;
}

immutable struct ConcreteLocalSource {
	immutable struct Closure {} // Closure parameter
	enum Generated { args, ignore, destruct, member, reference }
	mixin TaggedUnion!(Local*, Closure, Generated);
}

immutable struct ConcreteLocal {
	ConcreteLocalSource source;
	ConcreteType type;
}

immutable struct ConcreteFunBody {
	immutable struct Builtin {
		BuiltinFun kind;
		ConcreteType[] typeArgs;
	}
	immutable struct Extern {
		Symbol libraryName;
	}
	immutable struct VarGet { ConcreteVar* var; }
	immutable struct VarSet { ConcreteVar* var; }
	immutable struct Deferred {} // Should only be used temporarily

	mixin Union!(Builtin, Extern, ConcreteExpr, VarGet, VarSet, Deferred);
}

immutable struct ConcreteFunSource {
	immutable struct Lambda {
		ConcreteFun* containingFun;
		Expr* bodyExpr;
		size_t index; // nth lambda in the containing function
	}

	immutable struct Test {
		.Test* test;
		size_t testIndex; // Arbitrary index over all tests
	}

	immutable struct WrapMain {
		UriAndRange range;
	}

	mixin Union!(ConcreteFunKey, Lambda*, Test*, WrapMain*);
}

// We generate a ConcreteFun for:
// Each instantiation of a FunDecl
// Each lambda inside an instantiation of a FunDecl
immutable struct ConcreteFun {
	@safe @nogc pure nothrow:

	ConcreteFunSource source;
	ConcreteType returnType;
	SmallArray!ConcreteLocal params;
	private Late!ConcreteFunBody lateBody;

	ref ConcreteFunBody body_() return scope =>
		lateGet(lateBody);

	void body_(ConcreteFunBody value) {
		lateSet(lateBody, value);
	}

	void overwriteBody(ConcreteFunBody value) {
		lateSetOverwrite(lateBody, value);
	}

	Uri moduleUri() scope =>
		range.uri;

	UriAndRange range() scope =>
		source.matchIn!UriAndRange(
			(in ConcreteFunKey x) =>
				x.decl.range,
			(in ConcreteFunSource.Lambda x) =>
				UriAndRange(x.containingFun.moduleUri, x.bodyExpr.range),
			(in ConcreteFunSource.Test x) =>
				x.test.range,
			(in ConcreteFunSource.WrapMain x) =>
				x.range);
}

immutable struct ConcreteFunKey {
	@safe @nogc pure nothrow:

	FunDecl* decl;
	SmallArray!ConcreteType typeArgs;
	SmallArray!(immutable ConcreteFun*) specImpls;

	bool opEquals(scope ConcreteFunKey b) scope =>
		decl == b.decl &&
		arraysEqual!ConcreteType(typeArgs, b.typeArgs) &&
		arraysEqual!(ConcreteFun*)(specImpls, b.specImpls);

	HashCode hash() scope {
		Hasher hasher;
		hasher ~= decl;
		foreach (ConcreteType t; typeArgs)
			// Ignore 'reference', functions are unlikely to overload by that
			hasher ~= t.struct_;
		foreach (ConcreteFun* p; specImpls)
			hasher ~= p;
		return hasher.finish();
	}
}

bool isVariadic(in ConcreteFun a) =>
	a.source.matchIn!bool(
		(in ConcreteFunKey x) =>
			x.decl.params.isA!(Params.Varargs*),
		(in ConcreteFunSource.Lambda) =>
			false,
		(in ConcreteFunSource.Test) =>
			false,
		(in ConcreteFunSource.WrapMain) =>
			false);

Opt!Symbol name(ref ConcreteFun a) =>
	a.source.isA!ConcreteFunKey ? some(a.source.as!ConcreteFunKey.decl.name) : none!Symbol;

bool isSummon(ref ConcreteFun a) =>
	a.source.matchIn!bool(
		(in ConcreteFunKey x) =>
			x.decl.isSummon,
		(in ConcreteFunSource.Lambda x) =>
			isSummon(*x.containingFun),
		(in ConcreteFunSource.Test) =>
			// 'isSummon' is called for direct calls, but tests are never called directly
			assert(false),
		(in ConcreteFunSource.WrapMain) =>
			assert(false));

immutable struct ConcreteExpr {
	ConcreteType type;
	UriAndRange range;
	ConcreteExprKind kind;
}

immutable struct ConcreteExprKind {
	immutable struct Builtin {
		BuiltinFun fun;
		SmallArray!ConcreteExpr args;
	}

	immutable struct Call {
		ConcreteFun* called;
		SmallArray!ConcreteExpr args;
	}

	// Cast between different types with the same size.
	immutable struct Cast {
		ConcreteExpr* inner;
	}

	immutable struct CreateArray {
		@safe @nogc pure nothrow:
		ConcreteExpr[] args;
		this(ConcreteExpr[] a) {
			args = a;
			assert(!isEmpty(args));
		}
	}

	immutable struct CreateRecord {
		@safe @nogc pure nothrow:
		ConcreteExpr[] args;
		this(ConcreteExpr[] a) {
			args = a;
			assert(!isEmpty(args));
		}
	}

	immutable struct CreateUnion {
		size_t memberIndex;
		ConcreteExpr arg;
	}

	immutable struct Drop {
		ConcreteExpr arg;
	}

	immutable struct Finally {
		ConcreteExpr right;
		ConcreteExpr below;
	}

	immutable struct If {
		ConcreteExpr cond;
		ConcreteExpr then;
		ConcreteExpr else_;
	}

	immutable struct Let {
		ConcreteLocal* local;
		ConcreteExpr value;
		ConcreteExpr then;
	}

	immutable struct LocalGet {
		ConcreteLocal* local;
	}
	immutable struct LocalPointer {
		ConcreteLocal* local;
	}
	immutable struct LocalSet {
		ConcreteLocal* local;
		ConcreteExpr value;
	}

	immutable struct Loop {
		ConcreteExpr body_;
	}
	immutable struct LoopBreak {
		ConcreteExpr value;
	}
	immutable struct LoopContinue {}

	immutable struct MatchEnumOrIntegral {
		@safe @nogc pure nothrow:
		ConcreteExpr matched;
		IntegralValues caseValues;
		SmallArray!ConcreteExpr caseExprs;
		Opt!(ConcreteExpr*) else_;

		this(ConcreteExpr m, IntegralValues cv, ConcreteExpr[] ce, Opt!(ConcreteExpr*) e) {
			matched = m; caseValues = cv; caseExprs = ce; else_ = e;
			assert(caseExprs.length == caseValues.length);
			assert(!isEmpty(caseExprs));
		}
	}

	immutable struct MatchStringLike {
		immutable struct Case {
			ConcreteExpr value;
			ConcreteExpr then;
		}

		ConcreteExpr matched;
		ConcreteFun* equals;
		SmallArray!Case cases;
		ConcreteExpr else_;
	}

	immutable struct MatchUnion {
		@safe @nogc pure nothrow:

		immutable struct Case {
			Opt!(ConcreteLocal*) local;
			ConcreteExpr then;
		}

		ConcreteExpr matched;
		IntegralValues memberIndices;
		SmallArray!Case cases;
		Opt!(ConcreteExpr*) else_;

		this(ConcreteExpr m, IntegralValues mi, SmallArray!Case c, Opt!(ConcreteExpr*) e) {
			matched = m;
			memberIndices = mi;
			cases = c;
			else_ = e;
			assert(!isEmpty(cases));
		}
	}

	immutable struct RecordFieldGet {
		ConcreteExpr* record; // May be by-value or by-ref
		size_t fieldIndex;
	}

	immutable struct RecordFieldPointer {
		ConcreteExpr* record;
		size_t fieldIndex;
	}

	immutable struct RecordFieldSet {
		ConcreteExpr record; // May be by-value or by-ref
		size_t fieldIndex;
		ConcreteExpr value;
	}

	immutable struct Seq {
		ConcreteExpr first;
		ConcreteExpr then;
	}

	immutable struct Throw {
		// a `c-string`
		ConcreteExpr thrown;
	}

	immutable struct Try {
		ConcreteExpr tried;
		IntegralValues exceptionMemberIndices;
		SmallArray!(MatchUnion.Case) catchCases;
	}

	immutable struct TryLet {
		Opt!(ConcreteLocal*) local;
		ConcreteExpr value;
		IntegralValue exceptionMemberIndex;
		MatchUnion.Case catch_;
		ConcreteExpr then;
	}

	// Unsafe internal operation for casting a union to a member. Does not check the kind!
	immutable struct UnionAs {
		ConcreteExpr* union_;
		uint memberIndex;
	}

	// Internal operation for getting the 'kind' of a union. (This is the member index.)
	immutable struct UnionKind {
		ConcreteExpr* union_;
	}

	mixin Union!(
		Builtin*,
		Call,
		Cast,
		Constant,
		CreateArray,
		CreateRecord,
		CreateUnion*,
		Drop*,
		Finally*,
		If*,
		Let*,
		LocalGet,
		LocalPointer,
		LocalSet*,
		Loop*,
		LoopBreak*,
		LoopContinue,
		MatchEnumOrIntegral*,
		MatchStringLike*,
		MatchUnion*,
		RecordFieldGet,
		RecordFieldPointer,
		RecordFieldSet*,
		Seq*,
		Throw*,
		Try*,
		TryLet*,
		UnionAs,
		UnionKind);
}
version (WebAssembly) {} else {
	static assert(ConcreteExprKind.sizeof == ConcreteExprKind.Call.sizeof + ulong.sizeof);
}

ConcreteType returnType(ConcreteExprKind.Call a) =>
	a.called.returnType;

immutable struct ArrTypeAndConstantsConcrete {
	ConcreteStruct* arrType;
	ConcreteType elementType;
	Constant[][] constants;
}

immutable struct PointerTypeAndConstantsConcrete {
	ConcreteStruct* pointeeType;
	Constant[] constants;
}

// TODO: rename -- this is not all constants, just the ones by-ref
immutable struct AllConstantsConcrete {
	CString[] cStrings;
	Constant staticSymbols;
	ArrTypeAndConstantsConcrete[] arrs;
	// These are just the by-ref records
	PointerTypeAndConstantsConcrete[] pointers;
}

immutable struct ConcreteVar {
	VarDecl* source;
	ConcreteType type;
}

immutable struct ConcreteProgram {
	@safe @nogc pure nothrow:

	VersionInfo version_;
	AllConstantsConcrete allConstants;
	ConcreteStruct*[] allStructs;
	ConcreteVar*[] allVars;
	ConcreteFun*[] allFuns;
	// The functions are still in 'allFuns', this is just to identify them
	Set!(immutable ConcreteFun*) yieldingFuns;
	ConcreteCommonFuns commonFuns;
}
immutable struct ConcreteCommonFuns {
	@safe @nogc pure nothrow:
	ConcreteFun* alloc;
	ConcreteFun* curCatchPoint;
	ConcreteFun* setCurCatchPoint;
	ConcreteVar* curThrown;
	ConcreteFun* mark;
	ConcreteFun* markVisitFiber;
	ConcreteFun* rethrowCurrentException;
	ConcreteFun* runFiber;
	ConcreteFun* rtMain;
	ConcreteFun* throwImpl;
	ConcreteFun* userMain;

	ConcreteFun* gcRoot;
	ConcreteFun* setGcRoot;
	ConcreteFun* popGcRoot;

	ConcreteType fiberReferenceType() =>
		runFiber.params[1].type;
}

bool existsDirectChildExpr(ref ConcreteExpr a, in bool delegate(ref ConcreteExpr) @safe @nogc pure nothrow cb) =>
	a.kind.matchWithPointers!bool(
		(ConcreteExprKind.Builtin* x) =>
			exists!ConcreteExpr(x.args, cb),
		(ConcreteExprKind.Call x) =>
			exists!ConcreteExpr(x.args, cb),
		(ConcreteExprKind.Cast x) =>
			cb(*x.inner),
		(Constant x) =>
			false,
		(ConcreteExprKind.CreateArray x) =>
			exists!ConcreteExpr(x.args, cb),
		(ConcreteExprKind.CreateRecord x) =>
			exists!ConcreteExpr(x.args, cb),
		(ConcreteExprKind.CreateUnion* x) =>
			cb(x.arg),
		(ConcreteExprKind.Drop* x) =>
			cb(x.arg),
		(ConcreteExprKind.Finally* x) =>
			cb(x.right) || cb(x.below),
		(ConcreteExprKind.If* x) =>
			cb(x.cond) || cb(x.then) || cb(x.else_),
		(ConcreteExprKind.Let* x) =>
			cb(x.value) || cb(x.then),
		(ConcreteExprKind.LocalGet) =>
			false,
		(ConcreteExprKind.LocalPointer) =>
			false,
		(ConcreteExprKind.LocalSet* x) =>
			cb(x.value),
		(ConcreteExprKind.Loop* x) =>
			cb(x.body_),
		(ConcreteExprKind.LoopBreak* x) =>
			cb(x.value),
		(ConcreteExprKind.LoopContinue) =>
			false,
		(ConcreteExprKind.MatchEnumOrIntegral* x) =>
			cb(x.matched) ||
			exists!ConcreteExpr(x.caseExprs, cb) ||
			(has(x.else_) && cb(*force(x.else_))),
		(ConcreteExprKind.MatchStringLike* x) =>
			cb(x.matched) ||
			exists!(ConcreteExprKind.MatchStringLike.Case)(x.cases, (ref ConcreteExprKind.MatchStringLike.Case case_) =>
				cb(case_.value) || cb(case_.then)) ||
			cb(x.else_),
		(ConcreteExprKind.MatchUnion* x) =>
			cb(x.matched) ||
			exists!(ConcreteExprKind.MatchUnion.Case)(x.cases, (ref ConcreteExprKind.MatchUnion.Case case_) =>
				cb(case_.then)) ||
			(has(x.else_) && cb(*force(x.else_))),
		(ConcreteExprKind.RecordFieldGet x) =>
			cb(*x.record),
		(ConcreteExprKind.RecordFieldPointer x) =>
			cb(*x.record),
		(ConcreteExprKind.RecordFieldSet* x) =>
			cb(x.record) || cb(x.value),
		(ConcreteExprKind.Seq* x) =>
			cb(x.first) || cb(x.then),
		(ConcreteExprKind.Throw* x) =>
			cb(x.thrown),
		(ConcreteExprKind.Try* x) =>
			cb(x.tried) ||
			exists!(ConcreteExprKind.MatchUnion.Case)(x.catchCases, (ref ConcreteExprKind.MatchUnion.Case case_) =>
				cb(case_.then)),
		(ConcreteExprKind.TryLet* x) =>
			cb(x.value) || cb(x.catch_.then) || cb(x.then),
		(ConcreteExprKind.UnionAs x) =>
			cb(*x.union_),
		(ConcreteExprKind.UnionKind x) =>
			cb(*x.union_));
