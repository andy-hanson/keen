module model.lowModel;

@safe @nogc pure nothrow:

import model.concreteModel :
	ConcreteField,
	ConcreteFun,
	ConcreteStruct,
	ConcreteStructSource,
	ConcreteVar,
	isArrayOrMutArray,
	isFiber,
	isTuple,
	name;
import model.constant : Constant;
import model.model :
	Builtin4ary,
	BuiltinFun,
	BuiltinType,
	BuiltinUnary,
	BuiltinUnaryMath,
	BuiltinBinary,
	BuiltinBinaryMath,
	BuiltinTernary,
	Local,
	StructBody,
	TypeSize;
import util.col.array : isEmpty, SmallArray;
import util.col.map : Map;
import util.col.fullIndexMap : FullIndexMap, indexOfPointer;
import util.hash : HashCode, hashTaggedPointer;
import util.integralValues : IntegralValues;
import util.late : Late, lateGet, lateSet;
import util.opt : has, none, Opt;
import util.sourceRange : UriAndRange;
import util.string : CString;
import util.symbol : Symbol, symbol, symbolOfEnum;
import util.union_ : IndexType, TaggedUnion, Union;
import util.uri : Uri;
import versionInfo : VersionInfo;

immutable struct LowExternTypeIndex { mixin IndexType; }
immutable struct LowExternType {
	ConcreteStruct* source;
}

TypeSize typeSize(in LowExternType a) =>
	a.source.typeSize;

immutable struct LowRecordIndex { mixin IndexType; }
immutable struct LowRecord {
	@safe @nogc pure nothrow:

	ConcreteStruct* source;
	private Late!(SmallArray!LowField) fields_;

	SmallArray!LowField fields() return scope =>
		lateGet(fields_);
	void fields(SmallArray!LowField x) =>
		lateSet(fields_, x);

	bool isPacked() scope =>
		source.source.matchIn!bool(
			(in ConcreteStructSource.Bogus) =>
				false,
			(in ConcreteStructSource.Inst x) =>
				x.decl.body_.isA!BuiltinType
					? false
					: x.decl.body_.as!(StructBody.Record).flags.packed,
			(in ConcreteStructSource.Lambda) =>
				false);
}

TypeSize typeSize(in LowRecord a) =>
	a.source.typeSize;

bool isArrayOrMutArray(in LowRecord a) =>
	isArrayOrMutArray(*a.source);
bool isFiber(in LowRecord a) =>
	isFiber(*a.source);
bool isTuple(in LowRecord a) =>
	isTuple(*a.source);

immutable struct LowUnionIndex { mixin IndexType; }
immutable struct LowUnion {
	@safe @nogc pure nothrow:

	ConcreteStruct* source;
	Late!(SmallArray!LowType) members_;

	SmallArray!LowType members() return scope =>
		lateGet(members_);
	void members(SmallArray!LowType x) =>
		lateSet(members_, x);

	// This might change if we use tagged pointers
	size_t membersOffset() scope =>
		ulong.sizeof;
}

TypeSize typeSize(in LowUnion a) =>
	a.source.typeSize;

immutable struct LowFunPointerTypeIndex { mixin IndexType; }
immutable struct LowFunPointerType {
	@safe @nogc pure nothrow:

	ConcreteStruct* source;
	private Late!LowType returnType_;
	private Late!(SmallArray!LowType) paramTypes_;

	LowType returnType() return scope =>
		lateGet(returnType_);
	void returnType(LowType value) =>
		lateSet(returnType_, value);

	SmallArray!LowType paramTypes() return scope =>
		lateGet(paramTypes_);
	void paramTypes(SmallArray!LowType value) {
		lateSet(paramTypes_, value);
	}
}

enum PrimitiveType : ubyte {
	bool_,
	char8,
	char32,
	float32,
	float64,
	int8,
	int16,
	int32,
	int64,
	nat8,
	nat16,
	nat32,
	nat64,
	void_,
}
bool isSignedInteger(PrimitiveType a) =>
	a == PrimitiveType.int8 || a == PrimitiveType.int16 || a == PrimitiveType.int32 || a == PrimitiveType.int64;

immutable struct LowType {
	@safe @nogc pure nothrow:

	// Warn: Do not construct directly, use 'getPointerGc' from 'lowerUtil.d'
	immutable struct PointerGc {
		@safe @nogc pure nothrow:
		LowType* pointee;

		@system void* asPointerForTaggedUnion() =>
			cast(void*) pointee;
		@system static PointerGc fromPointerForTaggedUnion(void* a) =>
			PointerGc(cast(LowType*) a);
	}
	// Warn: Do not construct directly, use 'getPointerConst' from 'lowerUtil.d'
	immutable struct PointerConst {
		@safe @nogc pure nothrow:
		LowType* pointee;

		@system void* asPointerForTaggedUnion() =>
			cast(void*) pointee;
		@system static PointerConst fromPointerForTaggedUnion(void* a) =>
			PointerConst(cast(LowType*) a);
	}
	// Warn: Do not construct directly, use 'getPointerMut' from 'lowerUtil.d'
	immutable struct PointerMut {
		@safe @nogc pure nothrow:
		LowType* pointee;

		@system void* asPointerForTaggedUnion() =>
			cast(void*) pointee;
		@system static PointerMut fromPointerForTaggedUnion(void* a) =>
			PointerMut(cast(LowType*) a);
	}

	mixin TaggedUnion!(
		LowExternType*,
		LowFunPointerType*,
		PrimitiveType,
		PointerGc,
		PointerConst,
		PointerMut,
		LowRecord*,
		LowUnion*);

	bool opEquals(scope LowType b) scope =>
		taggedPointerEquals(b);

	HashCode hash() scope =>
		hashTaggedPointer!LowType(this);

	LowTypeCombinePointer combinePointer() return scope =>
		matchWithPointers!LowTypeCombinePointer(
			(LowExternType* x) =>
				LowTypeCombinePointer(x),
			(LowFunPointerType* x) =>
				LowTypeCombinePointer(x),
			(PrimitiveType x) =>
				LowTypeCombinePointer(x),
			(PointerGc x) =>
				LowTypeCombinePointer(LowPointerCombine(*x.pointee)),
			(PointerConst x) =>
				LowTypeCombinePointer(LowPointerCombine(*x.pointee)),
			(PointerMut x) =>
				LowTypeCombinePointer(LowPointerCombine(*x.pointee)),
			(LowRecord* x) =>
				LowTypeCombinePointer(x),
			(LowUnion* x) =>
				LowTypeCombinePointer(x));
}
static assert(LowType.sizeof <= 16);

bool isChar8(LowType a) =>
	a.isA!PrimitiveType && a.as!PrimitiveType == PrimitiveType.char8;
bool isChar32(LowType a) =>
	a.isA!PrimitiveType && a.as!PrimitiveType == PrimitiveType.char32;

bool isVoid(LowType a) =>
	a.isA!PrimitiveType && a.as!PrimitiveType == PrimitiveType.void_;

bool isPointerNonGc(LowType a) =>
	a.isA!(LowType.PointerConst) || a.isA!(LowType.PointerMut);

private bool isPointerGcOrRaw(LowType a) =>
	a.isA!(LowType.PointerGc) || isPointerNonGc(a);

@trusted LowType asPointee(return scope LowType a) =>
	a.combinePointer.as!LowPointerCombine.pointee;

immutable(LowType) asGcPointee(LowType a) =>
	*a.as!(LowType.PointerGc).pointee;

immutable(LowType) asNonGcPointee(LowType a) {
	assert(isPointerNonGc(a));
	return asPointee(a);
}

immutable(LowType.PointerConst) asPointerConst(LowType.PointerMut a) =>
	LowType.PointerConst(a.pointee);

immutable struct LowPointerCombine {
	LowType pointee;
}

private immutable struct LowTypeCombinePointer {
	mixin Union!(LowExternType*, LowFunPointerType*, PrimitiveType, LowPointerCombine, LowRecord*, LowUnion*);
}

bool isPrimitiveType(LowType a, PrimitiveType p) =>
	a.isA!PrimitiveType && a.as!PrimitiveType == p;

immutable struct LowFieldSource {
	enum ArrayField { pointer, size }
	mixin TaggedUnion!(ConcreteField*, ArrayField);
}

immutable struct LowField {
	LowFieldSource source;
	size_t offset;
	LowType type;
}

Symbol debugName(in LowField a) =>
	a.source.matchIn!Symbol(
		(in ConcreteField x) =>
			x.debugName,
		(in LowFieldSource.ArrayField x) =>
			symbolOfEnum(x));

immutable struct LowLocalSource {
	immutable struct Generated {
		Symbol name;
		bool isMutable;
	}
	mixin TaggedUnion!(Local*, Generated*);
}

immutable struct LowLocal {
	@safe @nogc pure nothrow:
	@disable this(ref const LowLocal);
	this(LowLocalSource s, uint i, LowType t) {
		source = s;
		index = i;
		type = t;
	}

	LowLocalSource source;
	uint index; // index within this function
	LowType type;

	Symbol name() scope =>
		source.matchIn!Symbol(
			(in Local x) =>
				x.name,
			(in LowLocalSource.Generated x) =>
				x.name);

	// This is whether the local itself is mutable, not whether its value is.
	bool isMutable() scope =>
		source.matchIn!bool(
			(in Local x) =>
				x.isMutable,
			(in LowLocalSource.Generated x) =>
				x.isMutable);
}
bool localMustBeVolatile(in LowFun curFun, in LowLocal local) =>
	// https://stackoverflow.com/questions/7996825/why-volatile-works-for-setjmp-longjmp
	local.isMutable && curFun.hasSetupCatch;

immutable struct LowFunBody {
	immutable struct Extern {
		Symbol libraryName;
	}

	mixin Union!(Extern, LowFunExprBody);
}

immutable struct LowFunExprBody {
	LowFunFlags flags;
	LowExpr expr;

	alias flags this;
}

immutable struct LowFunFlags {
	@safe @nogc pure nothrow:
	bool hasSetupCatch;
	bool hasTailRecur;
	bool mayYield;

	static LowFunFlags none() =>
		LowFunFlags(false, false, false);
}

immutable struct LowFunSource {
	immutable struct Generated {
		Symbol name;
		LowType[] typeArgs;
	}

	mixin TaggedUnion!(ConcreteFun*, Generated*);
}

immutable struct LowFun {
	@safe @nogc pure nothrow:
	@disable this(ref const LowFun);

	LowFunSource source;
	LowType returnType;
	SmallArray!LowLocal params;
	LowFunBody body_;

	Opt!Symbol name() scope =>
		source.matchIn!(Opt!Symbol)(
			(in ConcreteFun x) => x.name,
			(in LowFunSource.Generated) => none!Symbol);

	UriAndRange range() scope =>
		source.matchIn!UriAndRange(
			(in ConcreteFun x) =>
				x.range,
			(in LowFunSource.Generated) =>
				UriAndRange.empty);

	LowFunFlags flags() scope =>
		body_.matchIn!LowFunFlags(
			(in LowFunBody.Extern) =>
				LowFunFlags(
					hasSetupCatch: false,
					hasTailRecur: false,
					mayYield: false),
			(in LowFunExprBody x) =>
				x.flags);

	bool hasSetupCatch() scope =>
		flags.hasSetupCatch;

	bool mayYield() scope =>
		flags.mayYield;

	bool isGeneratedMain() scope =>
		source.matchIn!bool(
			(in ConcreteFun _) =>
				false,
			(in LowFunSource.Generated x) =>
				x.name == symbol!"main");
}

// TODO: use ConcreteExpr*
private alias LowExprSource = UriAndRange;

immutable struct LowExpr {
	LowType type;
	LowExprSource source;
	LowExprKind kind;
}

immutable struct LowFunIndex {
	@safe @nogc pure nothrow:

	size_t index;

	HashCode hash() scope =>
		HashCode(index);
}

immutable struct LowExprKind {
	immutable struct Abort {}

	immutable struct Call {
		LowFunIndex called;
		SmallArray!LowExpr args; // Includes implicit ctx arg if needed
	}

	immutable struct CallFunPointer {
		@safe @nogc pure nothrow:

		LowExpr* funPtr;
		SmallArray!LowExpr args;

		LowFunPointerType* funPointerType() scope =>
			funPtr.type.as!(LowFunPointerType*);
	}

	immutable struct CreateRecord {
		@safe @nogc pure nothrow:
		LowExpr[] args;

		this(LowExpr[] a) {
			args = a;
			assert(!isEmpty(args));
		}
	}

	immutable struct CreateUnion {
		size_t memberIndex;
		LowExpr arg;
	}

	// Sometimes this will be a Constant.FunPointer instead,
	// but that's only possible for functions known to ConcreteModel
	immutable struct FunPointer {
		LowFunIndex fun;
	}

	immutable struct If {
		LowExpr cond;
		LowExpr then;
		LowExpr else_;
	}

	immutable struct Init {
		BuiltinFun.Init.Kind kind;
	}

	immutable struct Let {
		// A heap-allocated mutable local will become a read-only local whose type is a gc-ptr
		LowLocal* local;
		LowExpr value;
		LowExpr then;
	}

	immutable struct LocalGet {
		LowLocal* local;
	}

	immutable struct LocalPointer {
		LowLocal* local;
	}

	immutable struct LocalSet {
		LowLocal* local;
		LowExpr value;
	}

	immutable struct Loop {
		LowExpr body_;
	}
	immutable struct LoopBreak {
		LowExpr value;
	}
	immutable struct LoopContinue {}

	immutable struct PointerCast {
		LowExpr target;
	}

	immutable struct RecordFieldGet {
		@safe @nogc pure nothrow:

		LowExpr* target; // Call 'targetIsPointer' to see if this is x.y or x->y
		size_t fieldIndex;

		LowRecord* targetRecordType() scope =>
			(targetIsPointer ? asPointee(target.type) : target.type).as!(LowRecord*);

		bool targetIsPointer() scope =>
			isPointerGcOrRaw(target.type);
	}

	immutable struct RecordFieldPointer {
		@safe @nogc pure nothrow:

		LowExpr* target; // Always a pointer
		size_t fieldIndex;

		LowRecord* targetRecordType() scope =>
			asPointee(target.type).as!(LowRecord*);
	}

	immutable struct RecordFieldSet {
		@safe @nogc pure nothrow:

		LowExpr target; // Always a pointer
		size_t fieldIndex;
		LowExpr value;

		// Use a template to avoid forward reference errors
		LowRecord* targetRecordType()() scope =>
			asPointee(target.type).as!(LowRecord*);
	}

	immutable struct SpecialUnary {
		@safe @nogc pure nothrow:

		BuiltinUnary kind;
		LowExpr* argPtr;

		ref LowExpr arg() return scope =>
			*argPtr;

		this(BuiltinUnary k, LowExpr* a) {
			kind = k;
			argPtr = a;
			switch (k) {
				case BuiltinUnary.arrayPointer:
				case BuiltinUnary.arraySize:
					// These should be lowered to RecordFieldGet
					assert(false);
				default:
					break;
			}
		}
	}

	immutable struct SpecialUnaryMath {
		@safe @nogc pure nothrow:
		BuiltinUnaryMath kind;
		LowExpr* argPtr;

		ref LowExpr arg() return scope =>
			*argPtr;
	}

	immutable struct SpecialBinary {
		@safe @nogc pure nothrow:

		BuiltinBinary kind;
		LowExpr[2]* argsPtr;

		ref LowExpr[2] args() return scope =>
			*argsPtr;

		this(BuiltinBinary k, LowExpr[2]* a) {
			kind = k;
			argsPtr = a;
			assert(k != BuiltinBinary.newArray); // This should be lowered to CreateRecord
		}
	}

	immutable struct SpecialBinaryMath {
		@safe @nogc pure nothrow:
		BuiltinBinaryMath kind;
		LowExpr[2]* argsPtr;

		ref LowExpr[2] args() return scope =>
			*argsPtr;
	}

	immutable struct SpecialTernary {
		@safe @nogc pure nothrow:
		BuiltinTernary kind;
		LowExpr[3]* argsPtr;

		ref LowExpr[3] args() return scope =>
			*argsPtr;
	}

	immutable struct Special4ary {
		@safe @nogc pure nothrow:
		Builtin4ary kind;
		LowExpr[4]* argsPtr;

		ref LowExpr[4] args() return scope =>
			*argsPtr;
	}

	immutable struct Switch {
		@safe @nogc pure nothrow:
		LowExpr value;
		IntegralValues caseValues;
		SmallArray!LowExpr caseExprs;
		LowExpr default_; // This is often Abort

		this(LowExpr value, IntegralValues caseValues, SmallArray!LowExpr caseExprs, LowExpr default_) {
			this.value = value; this.caseValues = caseValues; this.caseExprs = caseExprs; this.default_ = default_;
			assert(caseValues.length == caseExprs.length);
			assert(!isEmpty(caseExprs));
		}
	}

	immutable struct TailRecur {
		UpdateParam[] updateParams;
	}

	immutable struct VarGet {
		LowVarIndex varIndex;
	}
	immutable struct VarSet {
		LowVarIndex varIndex;
		LowExpr* value;
	}
	immutable struct UnionAs {
		LowExpr* union_;
		uint memberIndex;
	}
	immutable struct UnionKind {
		LowExpr* union_;
	}

	mixin Union!(
		Abort,
		Call,
		CallFunPointer,
		CreateRecord,
		CreateUnion*,
		FunPointer,
		If*,
		Init,
		Let*,
		LocalGet,
		LocalPointer,
		LocalSet*,
		Loop*,
		LoopBreak*,
		LoopContinue,
		PointerCast*,
		RecordFieldGet,
		RecordFieldPointer,
		RecordFieldSet*,
		Constant,
		SpecialUnary,
		SpecialUnaryMath,
		SpecialBinary,
		SpecialBinaryMath,
		SpecialTernary,
		Special4ary,
		Switch*,
		TailRecur,
		UnionAs,
		UnionKind,
		VarGet,
		VarSet);
}
version (WebAssembly) {
	static assert(LowExprKind.sizeof == Constant.sizeof + ulong.sizeof);
} else {
	static assert(LowExprKind.sizeof == LowExprKind.Call.sizeof + ulong.sizeof);
}

immutable struct UpdateParam {
	LowLocal* param;
	LowExpr newValue;
}

immutable struct ArrTypeAndConstantsLow {
	@safe @nogc pure nothrow:

	@disable this(ref const ArrTypeAndConstantsLow);
	this(LowRecord* a, LowType e, immutable Constant[][] c) {
		arrType = a; elementType = e; constants = c;
	}

	LowRecord* arrType;
	LowType elementType;
	Constant[][] constants;
}

immutable struct PointerTypeAndConstantsLow {
	@safe @nogc pure nothrow:

	@disable this(ref const PointerTypeAndConstantsLow);
	this(LowType p, Constant[] c) {
		pointeeType = p; constants = c;
	}

	LowType pointeeType;
	Constant[] constants;
}

// TODO: rename -- this is not all constants, just the ones by-ref
immutable struct AllConstantsLow {
	CString[] cStrings;
	//TODO:FullIndexMap
	ArrTypeAndConstantsLow[] arrs;
	//TODO:FullIndexMap
	// These are just the by-ref records
	PointerTypeAndConstantsLow[] pointers;
}

alias ConcreteFunToLowFunIndex = Map!(ConcreteFun*, LowFunIndex);

immutable struct LowVarIndex {
	size_t index;
}

immutable struct LowVar {
	@safe @nogc pure nothrow:

	ConcreteVar* source;
	enum Kind {
		externGlobal,
		global,
		threadLocal,
	}
	Kind kind;
	LowType type;

	bool isExtern() scope =>
		has(externLibraryName);
	Opt!Symbol externLibraryName() scope =>
		source.source.externLibraryName;
	Symbol name() scope =>
		source.source.name;
}

immutable struct LowProgram {
	@safe @nogc pure nothrow:

	VersionInfo version_;
	ConcreteFunToLowFunIndex concreteFunToLowFunIndex;
	AllConstantsLow allConstants;
	LowCommonTypes commonTypes;
	FullIndexMap!(LowVarIndex, LowVar) vars;
	AllLowTypes allTypes;
	FullIndexMap!(LowFunIndex, LowFun) allFuns;
	LowFunIndex main;
	ExternLibraries externLibraries;

	ref immutable(FullIndexMap!(LowExternTypeIndex, LowExternType)) allExternTypes() scope return =>
		allTypes.allExternTypes;
	LowExternTypeIndex indexOfExternType(in LowExternType* x) =>
		allTypes.indexOfExternType(x);

	ref immutable(FullIndexMap!(LowFunPointerTypeIndex, LowFunPointerType)) allFunPointerTypes() scope return =>
		allTypes.allFunPointerTypes;
	LowFunPointerTypeIndex indexOfFunPointerType(in LowFunPointerType* x) scope =>
		allTypes.indexOfFunPointerType(x);

	ref immutable(FullIndexMap!(LowRecordIndex, LowRecord)) allRecords() scope return =>
		allTypes.allRecords;
	LowRecordIndex indexOfRecord(in LowRecord* x) scope =>
		allTypes.indexOfRecord(x);

	ref immutable(FullIndexMap!(LowUnionIndex, LowUnion)) allUnions() scope return =>
		allTypes.allUnions;
	LowUnionIndex indexOfUnion(in LowUnion* x) scope =>
		allTypes.indexOfUnion(x);
}

immutable struct LowCommonTypes {
	@safe @nogc pure nothrow:

	LowType catchPointConstPointer;
	LowType catchPointMutPointer;
	LowType fiberReference;
	LowType nat8ConstPointer;
	LowType nat8MutPointer;
	LowType nat64MutPointer;
	LowType nat64MutPointerMutPointer;

	LowType catchPoint() =>
		*catchPointConstPointer.as!(LowType.PointerConst).pointee;
}

alias ExternLibraries = immutable ExternLibrary[];

immutable struct ExternLibrary {
	Symbol libraryName;
	Opt!Uri configuredDir;
	Symbol[] importNames;
}

immutable struct AllLowTypes {
	@safe @nogc pure nothrow:

	FullIndexMap!(LowExternTypeIndex, LowExternType) allExternTypes;
	FullIndexMap!(LowFunPointerTypeIndex, LowFunPointerType) allFunPointerTypes;
	FullIndexMap!(LowRecordIndex, LowRecord) allRecords;
	FullIndexMap!(LowUnionIndex, LowUnion) allUnions;

	LowExternTypeIndex indexOfExternType(in LowExternType* x) scope =>
		indexOfPointer!(LowExternTypeIndex, LowExternType)(allExternTypes, x);
	LowFunPointerTypeIndex indexOfFunPointerType(in LowFunPointerType* x) scope =>
		indexOfPointer!(LowFunPointerTypeIndex, LowFunPointerType)(allFunPointerTypes, x);
	LowRecordIndex indexOfRecord(in LowRecord* record) scope =>
		indexOfPointer!(LowRecordIndex, LowRecord)(allRecords, record);
	LowUnionIndex indexOfUnion(in LowUnion* union_) scope =>
		indexOfPointer!(LowUnionIndex, LowUnion)(allUnions, union_);
}
