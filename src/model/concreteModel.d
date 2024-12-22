module model.concreteModel;

@safe @nogc pure nothrow:

import model.integralValues : IntegralValue, IntegralValues;
import model.model :
	BuiltinFun,
	BuiltinType,
	Destructure,
	Enum,
	EnumOrFlagsMember,
	Expr,
	Flags,
	FunDecl,
	IntegralType,
	isOptionType,
	isString,
	isTuple,
	Local,
	mustBeEnumOrFlags,
	Purity,
	Record,
	StructDecl,
	Test,
	TypeSize,
	Varargs,
	VarDecl;
import model.sourceRange : UriAndRange;
import util.col.array : arraysEqual, every, exists, isEmpty, only, SmallArray;
import util.col.set : Set;
import util.hash : HashCode, Hasher, hashPointer;
import util.late : Late, lateGet, lateIsSet, lateSet, lateSetOverwrite;
import util.opt : force, has, none, Opt, some;
import util.string : CString;
import util.symbol : Symbol;
import util.union_ : TaggedUnion, Union;
import util.uri : Uri;
import versionInfo : VersionInfo;

immutable struct ConcreteStructBody {
	mixin Union!(ConcreteBuiltinType*, ConcreteEnum, ConcreteExternType, ConcreteFlags, ConcreteRecord, ConcreteUnion);
}
static assert(ConcreteStructBody.sizeof == ConcreteRecord.sizeof + size_t.sizeof);

immutable struct ConcreteBuiltinType {
	BuiltinType kind;
	SmallArray!ConcreteType typeArgs;
}
immutable struct ConcreteEnum {
	IntegralType storage;
}
immutable struct ConcreteFlags {
	IntegralType storage;
}
immutable struct ConcreteExternType {}
immutable struct ConcreteRecord {
	bool isSomeFieldMutable;
	SmallArray!ConcreteField fields;
}
// Lambdas and all SumType kinds compile to this
immutable struct ConcreteUnion {
	@safe @nogc pure nothrow:
	// In the concrete model we identify members by index, so don't care about their names.
	// This may be empty for a lambda type with no implementations.
	Late!(SmallArray!ConcreteType) members_;

	bool hasMembers() scope =>
		lateIsSet(members_);
	SmallArray!ConcreteType members() return scope =>
		lateGet(members_);
	void members(SmallArray!ConcreteType value) {
		lateSet(members_, value);
	}
}

bool isPacked(in ConcreteStruct a) =>
	a.source.matchIn!bool(
		(in ConcreteStructSourceBogus _) =>
			false,
		(in ConcreteStructSourceInst x) =>
			x.decl.body_.isA!BuiltinType
				? false
				: x.decl.body_.as!Record.flags.packed,
		(in ConcreteStructSourceLambda _) =>
			false);

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
	a.struct_.body_.isA!(ConcreteBuiltinType*) &&
	a.struct_.body_.as!(ConcreteBuiltinType*).kind == BuiltinType.void_;
bool isEmptyType(in ConcreteType a) =>
	a.reference == ReferenceKind.byVal && isEmptyStruct(*a.struct_);
bool isEmptyStruct(in ConcreteStruct a) =>
	a.typeSize.sizeBytes == 0;
bool isFlags(in ConcreteType a) =>
	a.reference == ReferenceKind.byVal && isFlags(*a.struct_);
bool isFlags(in ConcreteStruct a) =>
	a.body_.isA!ConcreteFlags;

alias ReferenceKind = immutable ReferenceKind_;
private enum ReferenceKind_ { byVal, byRef }

Purity purity(ConcreteType a) =>
	a.struct_.purity;

ConcreteStruct* mustBeByVal(ConcreteType a) {
	assert(a.reference == ReferenceKind.byVal);
	return a.struct_;
}

EnumOrFlagsMember[] mustBeEnumOrFlags(ConcreteType a) =>
	mustBeEnumOrFlags(*mustBeByVal(a).source.as!ConcreteStructSourceInst.decl);
EnumOrFlagsMember[] mustBeEnum(ConcreteType a) =>
	mustBeByVal(a).source.as!ConcreteStructSourceInst.decl.body_.as!(Enum*).members;
ref Flags mustBeFlags(ConcreteType a) =>
	mustBeByVal(a).source.as!ConcreteStructSourceInst.decl.body_.as!Flags;

immutable struct ConcreteStructSource {
	mixin Union!(ConcreteStructSourceBogus, ConcreteStructSourceInst, ConcreteStructSourceLambda);
}
immutable struct ConcreteStructSourceBogus {}
immutable struct ConcreteStructSourceInst {
	@safe @nogc pure nothrow:
	StructDecl* decl;
	SmallArray!ConcreteType typeArgs;

	this(StructDecl* d, SmallArray!ConcreteType ta) {
		decl = d;
		typeArgs = ta;
		assert(typeArgs.length == decl.typeParams.length);
		assert(!isString(*decl)); // Concretize should replace 'string' with 'char8 array'
	}

	bool opEquals(in ConcreteStructSourceInst b) scope =>
		decl == b.decl && arraysEqual!ConcreteType(typeArgs, b.typeArgs);

	HashCode hash() scope {
		Hasher hasher;
		hasher ~= decl;
		foreach (ConcreteType t; typeArgs)
			hasher ~= t.struct_;
		return hasher.finish();
	}
}
immutable struct ConcreteStructSourceLambda {
	ConcreteFun* containingFun;
	size_t index;
}

immutable struct ConcreteStruct {
	@safe @nogc pure nothrow:

	Purity purity;
	ConcreteStructSpecialKind specialKind;
	ConcreteStructSource source;
	private Late!ConcreteStructBody lateBody;
	//TODO: this isn't needed outside of concretizeCtx.d
	private Late!ReferenceKind defaultReferenceKind_;
	private Late!TypeSize typeSize_;
	// Only set for records
	private Late!(immutable uint[]) fieldOffsets_;

	void body_(ConcreteStructBody value) {
		lateSet(lateBody, value);
	}
	ref ConcreteStructBody body_() return scope =>
		lateGet(lateBody);

	bool isSelfMutable() scope =>
		body_.isA!ConcreteRecord && body_.as!ConcreteRecord.isSomeFieldMutable;

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
enum ConcreteStructSpecialKind {
	none,
	arrayOrMutArray,
	catchPoint,
	fiber,
	pointer, // mut or const
	tuple,
}

bool isArrayOrMutArray(in ConcreteStruct a) =>
	a.specialKind == ConcreteStructSpecialKind.arrayOrMutArray;
ConcreteType arrayElementType(ConcreteType arrayType) {
	assert(isArrayOrMutArray(*mustBeByVal(arrayType)));
	return only(mustBeByVal(arrayType).source.as!ConcreteStructSourceInst.typeArgs);
}
private bool isOption(in ConcreteStruct a) =>
	a.source.isA!ConcreteStructSourceInst && isOptionType(a.source.as!ConcreteStructSourceInst.decl);

ConcreteType unwrapOptionType(ConcreteType optionType) {
	assert(isOption(*mustBeByVal(optionType)));
	return only(mustBeByVal(optionType).source.as!ConcreteStructSourceInst.typeArgs);
}
bool isCatchPoint(in ConcreteStruct a) =>
	a.specialKind == ConcreteStructSpecialKind.catchPoint;
bool isFiber(in ConcreteStruct a) =>
	a.specialKind == ConcreteStructSpecialKind.fiber;
bool isPointer(ConcreteType a) =>
	a.reference == ReferenceKind.byVal && isPointer(*a.struct_);
private bool isPointer(in ConcreteStruct a) =>
	a.specialKind == ConcreteStructSpecialKind.pointer;
ConcreteType pointeeType(ConcreteType pointerType) {
	assert(isPointer(*mustBeByVal(pointerType)));
	return only(mustBeByVal(pointerType).source.as!ConcreteStructSourceInst.typeArgs);
}
ConcreteType pointeeTypeIfIsPointer(ConcreteType a) =>
	isPointer(a)
		? pointeeType(a)
		: a;
private bool isBogus(in ConcreteStruct a) =>
	a.source.isA!ConcreteStructSourceBogus;
bool isTuple(in ConcreteStruct a) =>
	a.specialKind == ConcreteStructSpecialKind.tuple;

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

immutable struct ConcreteField {
	Symbol debugName;
	bool isMutable;
	ConcreteType type;
}

immutable struct ConcreteLocalSource {
	mixin TaggedUnion!(Local*, ConcreteLocalSourceClosure, ConcreteGeneratedLocalKind);
}
immutable struct ConcreteLocalSourceClosure {}
enum ConcreteGeneratedLocalKind { args, ignore, destruct, member, reference }

immutable struct ConcreteLocal {
	ConcreteLocalSource source;
	ConcreteType type;
}

immutable struct ConcreteFunBody {
	mixin Union!(
		ConcreteFunBodyBuiltin,
		ConcreteFunBodyExtern,
		ConcreteExpr,
		ConcreteFunBodyVarGet,
		ConcreteFunBodyVarSet,
		ConcreteFunBodyDeferred);
}
immutable struct ConcreteFunBodyBuiltin {
	BuiltinFun kind;
	ConcreteType[] typeArgs;
}
immutable struct ConcreteFunBodyExtern {
	Symbol libraryName;
}
immutable struct ConcreteFunBodyVarGet { ConcreteVar* var; }
immutable struct ConcreteFunBodyVarSet { ConcreteVar* var; }
immutable struct ConcreteFunBodyDeferred {} // Should only be used temporarily

immutable struct ConcreteFunSource {
	mixin Union!(ConcreteFunKey, ConcreteFunSourceLambda*, ConcreteFunSourceTest*, ConcreteFunSourceWrapMain*);
}
immutable struct ConcreteFunSourceLambda {
	ConcreteFun* containingFun;
	Destructure param;
	Expr* bodyExpr;
	size_t index; // nth lambda in the containing function
}
immutable struct ConcreteFunSourceTest {
	Test* test;
	size_t testIndex; // Arbitrary index over all tests
}
immutable struct ConcreteFunSourceWrapMain {
	UriAndRange range;
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
			(in ConcreteFunSourceLambda x) =>
				UriAndRange(x.containingFun.moduleUri, x.bodyExpr.range),
			(in ConcreteFunSourceTest x) =>
				x.test.range,
			(in ConcreteFunSourceWrapMain x) =>
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
			x.decl.params.isA!(Varargs*),
		(in ConcreteFunSourceLambda _) =>
			false,
		(in ConcreteFunSourceTest _) =>
			false,
		(in ConcreteFunSourceWrapMain _) =>
			false);

Opt!Symbol name(ref ConcreteFun a) =>
	a.source.isA!ConcreteFunKey ? some(a.source.as!ConcreteFunKey.decl.name) : none!Symbol;

bool isSummon(ref ConcreteFun a) =>
	a.source.matchIn!bool(
		(in ConcreteFunKey x) =>
			x.decl.isSummon,
		(in ConcreteFunSourceLambda x) =>
			isSummon(*x.containingFun),
		(in ConcreteFunSourceTest _) =>
			// 'isSummon' is called for direct calls, but tests are never called directly
			assert(false),
		(in ConcreteFunSourceWrapMain _) =>
			assert(false));

immutable struct ConcreteExpr {
	ConcreteType type;
	UriAndRange range;
	ConcreteExprKind kind;
}

immutable struct ConcreteExprKind {
	mixin Union!(
		BuiltinConcreteExpr*,
		CallConcreteExpr,
		CastConcreteExpr,
		Constant,
		CreateArrayConcreteExpr,
		CreateRecordConcreteExpr,
		CreateUnionConcreteExpr*,
		DropConcreteExpr*,
		FinallyConcreteExpr*,
		IfConcreteExpr*,
		LetConcreteExpr*,
		LocalGetConcreteExpr,
		LocalPointerConcreteExpr,
		LocalSetConcreteExpr*,
		LoopConcreteExpr*,
		LoopBreakConcreteExpr*,
		LoopContinueConcreteExpr,
		MatchEnumOrIntegralConcreteExpr*,
		MatchStringLikeConcreteExpr*,
		MatchUnionConcreteExpr*,
		RecordFieldGetConcreteExpr,
		RecordFieldPointerConcreteExpr,
		RecordFieldSetConcreteExpr*,
		SeqConcreteExpr*,
		ThrowConcreteExpr*,
		TryConcreteExpr*,
		TryLetConcreteExpr*,
		UnionAsConcreteExpr,
		UnionKindConcreteExpr);
}
version (WebAssembly) {} else {
	static assert(ConcreteExprKind.sizeof == CallConcreteExpr.sizeof + ulong.sizeof);
}

immutable struct BuiltinConcreteExpr {
	BuiltinFun fun;
	SmallArray!ConcreteExpr args;
}

immutable struct CallConcreteExpr {
	ConcreteFun* called;
	SmallArray!ConcreteExpr args;
}

// Cast between different types with the same size.
immutable struct CastConcreteExpr {
	ConcreteExpr* inner;
}

immutable struct CreateArrayConcreteExpr {
	@safe @nogc pure nothrow:
	ConcreteExpr[] args;
	this(ConcreteExpr[] a) {
		args = a;
		assert(!isEmpty(args));
	}
}

immutable struct CreateRecordConcreteExpr {
	@safe @nogc pure nothrow:
	ConcreteExpr[] args;
	this(ConcreteExpr[] a) {
		args = a;
		assert(!isEmpty(args));
	}
}

immutable struct CreateUnionConcreteExpr {
	size_t memberIndex;
	ConcreteExpr arg;
}

immutable struct DropConcreteExpr {
	ConcreteExpr arg;
}

immutable struct FinallyConcreteExpr {
	ConcreteExpr right;
	ConcreteExpr below;
}

immutable struct IfConcreteExpr {
	ConcreteExpr cond;
	ConcreteExpr then;
	ConcreteExpr else_;
}

immutable struct LetConcreteExpr {
	ConcreteLocal* local;
	ConcreteExpr value;
	ConcreteExpr then;
}

immutable struct LocalGetConcreteExpr {
	ConcreteLocal* local;
}
immutable struct LocalPointerConcreteExpr {
	ConcreteLocal* local;
}
immutable struct LocalSetConcreteExpr {
	ConcreteLocal* local;
	ConcreteExpr value;
}

immutable struct LoopConcreteExpr {
	ConcreteExpr body_;
}
immutable struct LoopBreakConcreteExpr {
	ConcreteExpr value;
}
immutable struct LoopContinueConcreteExpr {}

immutable struct MatchEnumOrIntegralConcreteExpr {
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

immutable struct MatchStringLikeConcreteExpr {
	ConcreteExpr matched;
	ConcreteFun* equals;
	SmallArray!ConcreteMatchStringLikeCase cases;
	ConcreteExpr else_;
}
immutable struct ConcreteMatchStringLikeCase {
	ConcreteExpr value;
	ConcreteExpr then;
}

immutable struct MatchUnionConcreteExpr {
	@safe @nogc pure nothrow:

	ConcreteExpr matched;
	IntegralValues memberIndices;
	SmallArray!ConcreteMatchUnionCase cases;
	Opt!(ConcreteExpr*) else_;

	this(ConcreteExpr m, IntegralValues mi, SmallArray!ConcreteMatchUnionCase c, Opt!(ConcreteExpr*) e) {
		matched = m;
		memberIndices = mi;
		cases = c;
		else_ = e;
		assert(!isEmpty(cases));
	}
}
immutable struct ConcreteMatchUnionCase {
	Opt!(ConcreteLocal*) local;
	ConcreteExpr then;
}

immutable struct RecordFieldGetConcreteExpr {
	ConcreteExpr* record; // May be by-value or by-ref
	size_t fieldIndex;
}

immutable struct RecordFieldPointerConcreteExpr {
	ConcreteExpr* record;
	size_t fieldIndex;
}

immutable struct RecordFieldSetConcreteExpr {
	ConcreteExpr record; // May be by-value or by-ref
	size_t fieldIndex;
	ConcreteExpr value;
}

immutable struct SeqConcreteExpr {
	ConcreteExpr first;
	ConcreteExpr then;
}

immutable struct ThrowConcreteExpr {
	ConcreteExpr thrown;
}

immutable struct TryConcreteExpr {
	ConcreteExpr tried;
	IntegralValues exceptionMemberIndices;
	SmallArray!ConcreteMatchUnionCase catchCases;
}

immutable struct TryLetConcreteExpr {
	Opt!(ConcreteLocal*) local;
	ConcreteExpr value;
	IntegralValue exceptionMemberIndex;
	ConcreteMatchUnionCase catch_;
	ConcreteExpr then;
}

// Unsafe internal operation for casting a union to a member. Does not check the kind!
immutable struct UnionAsConcreteExpr {
	ConcreteExpr* union_;
	uint memberIndex;
}

// Internal operation for getting the 'kind' of a union. (This is the member index.)
immutable struct UnionKindConcreteExpr {
	ConcreteExpr* union_;
}

ConcreteType returnType(CallConcreteExpr a) =>
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
		(BuiltinConcreteExpr* x) =>
			exists!ConcreteExpr(x.args, cb),
		(CallConcreteExpr x) =>
			exists!ConcreteExpr(x.args, cb),
		(CastConcreteExpr x) =>
			cb(*x.inner),
		(Constant x) =>
			false,
		(CreateArrayConcreteExpr x) =>
			exists!ConcreteExpr(x.args, cb),
		(CreateRecordConcreteExpr x) =>
			exists!ConcreteExpr(x.args, cb),
		(CreateUnionConcreteExpr* x) =>
			cb(x.arg),
		(DropConcreteExpr* x) =>
			cb(x.arg),
		(FinallyConcreteExpr* x) =>
			cb(x.right) || cb(x.below),
		(IfConcreteExpr* x) =>
			cb(x.cond) || cb(x.then) || cb(x.else_),
		(LetConcreteExpr* x) =>
			cb(x.value) || cb(x.then),
		(LocalGetConcreteExpr _) =>
			false,
		(LocalPointerConcreteExpr _) =>
			false,
		(LocalSetConcreteExpr* x) =>
			cb(x.value),
		(LoopConcreteExpr* x) =>
			cb(x.body_),
		(LoopBreakConcreteExpr* x) =>
			cb(x.value),
		(LoopContinueConcreteExpr _) =>
			false,
		(MatchEnumOrIntegralConcreteExpr* x) =>
			cb(x.matched) ||
			exists!ConcreteExpr(x.caseExprs, cb) ||
			(has(x.else_) && cb(*force(x.else_))),
		(MatchStringLikeConcreteExpr* x) =>
			cb(x.matched) ||
			exists!ConcreteMatchStringLikeCase(x.cases, (ref ConcreteMatchStringLikeCase case_) =>
				cb(case_.value) || cb(case_.then)) ||
			cb(x.else_),
		(MatchUnionConcreteExpr* x) =>
			cb(x.matched) ||
			exists!ConcreteMatchUnionCase(x.cases, (ref ConcreteMatchUnionCase case_) =>
				cb(case_.then)) ||
			(has(x.else_) && cb(*force(x.else_))),
		(RecordFieldGetConcreteExpr x) =>
			cb(*x.record),
		(RecordFieldPointerConcreteExpr x) =>
			cb(*x.record),
		(RecordFieldSetConcreteExpr* x) =>
			cb(x.record) || cb(x.value),
		(SeqConcreteExpr* x) =>
			cb(x.first) || cb(x.then),
		(ThrowConcreteExpr* x) =>
			cb(x.thrown),
		(TryConcreteExpr* x) =>
			cb(x.tried) ||
			exists!ConcreteMatchUnionCase(x.catchCases, (ref ConcreteMatchUnionCase case_) =>
				cb(case_.then)),
		(TryLetConcreteExpr* x) =>
			cb(x.value) || cb(x.catch_.then) || cb(x.then),
		(UnionAsConcreteExpr x) =>
			cb(*x.union_),
		(UnionKindConcreteExpr x) =>
			cb(*x.union_));

// WARN: The type of a constant is implicit (given by context).
// This means two constants that look equal may not be the same constant if they have different types
// (e.g., IntegralValue has different sizes.)
// WARN: A Constant.Record is *by value* even if the record usually isn't. Use Constant.Pointer for a pointer.
immutable struct Constant {
	@safe @nogc pure nothrow:

	mixin Union!(
		ConstantArray,
		ConstantCString,
		ConstantFloat,
		ConstantFunPointer,
		IntegralValue,
		ConstantPointer,
		ConstantRecord,
		ConstantUnion*,
		ConstantZero);

	// WARN: Only do this with constants known to have the same type
	bool opEquals(in Constant b) scope {
		if (isA!ConstantZero || b.isA!ConstantZero)
			return isZero(this) && isZero(b);
		else {
			assert(kind == b.kind);
			return matchIn!bool(
				(in ConstantArray x) =>
					b.as!ConstantArray.index == x.index,
				(in ConstantCString x) =>
					b.as!ConstantCString.index == x.index,
				(in ConstantFloat x) =>
					//TODO: handle NaN
					b.as!ConstantFloat.value == x.value,
				(in ConstantFunPointer x) =>
					b.as!ConstantFunPointer.fun == x.fun,
				(in IntegralValue x) =>
					b.as!IntegralValue.value == x.value,
				(in ConstantPointer x) =>
					b.as!ConstantPointer.index == x.index,
				(in ConstantRecord ra) =>
					arraysEqual!Constant(ra.args, b.as!ConstantRecord.args),
				(in ConstantUnion ua) =>
					ua.memberIndex == b.as!(ConstantUnion*).memberIndex && ua.arg == b.as!(ConstantUnion*).arg,
				(in ConstantZero _) =>
					true);
		}
	}
}
static assert(Constant.sizeof <= 16);

immutable struct ConstantArray {
	uint typeIndex; // Index of the arr type in AllConstants
	uint index; // Index into AllConstants#arrs for this type.
}
// Nul-terminated string identified only by its begin pointer.
immutable struct ConstantCString {
	uint index; // Index into AllConstants#cStrings
}
// Used for float32 / float64
immutable struct ConstantFloat {
	double value;
}
immutable struct ConstantFunPointer {
	ConcreteFun* fun;
}
// Pointer (or gc-pointer) to another constant
immutable struct ConstantPointer {
	uint typeIndex;
	uint index; // Index into AllConstants#pointers for this type
}
// This is a record by-value.
immutable struct ConstantRecord {
	SmallArray!Constant args;
}
immutable struct ConstantUnion {
	size_t memberIndex;
	Constant arg;
}
// All 0 bits. Good for null, void, or empty value of 'extern' type.
immutable struct ConstantZero {}

private bool isZero(in Constant a) =>
	a.matchIn!bool(
		(in ConstantArray _) =>
			// We only create ArrConstant for non-empty arrays
			false,
		(in ConstantCString _) =>
			false,
		(in ConstantFloat x) =>
			x.value == 0,
		(in ConstantFunPointer x) =>
			false,
		(in IntegralValue x) =>
			x.value == 0,
		(in ConstantPointer x) =>
			false,
		(in ConstantRecord x) =>
			every!Constant(x.args, (in Constant arg) => isZero(arg)),
		(in ConstantUnion x) =>
			isZero(x.arg),
		(in ConstantZero _) =>
			true);

Constant constantBool(bool b) =>
	Constant(IntegralValue(b));

bool asBool(Constant a) {
	ulong value = a.as!IntegralValue.asUnsigned;
	assert(value == 0 || value == 1);
	return value == 1;
}

Constant constantZero() =>
	Constant(ConstantZero());

ulong asNat64(Constant a) =>
	a.isA!(ConstantZero) ? 0 : a.as!IntegralValue.asUnsigned;
