module lower.lowerUtil;

@safe @nogc pure nothrow:

import lower.lowExprHelpers : voidType;
import model.concreteModel :
	ConcreteBuiltinType,
	ConcreteEnum,
	ConcreteExternType,
	ConcreteFlags,
	ConcreteFun,
	ConcreteRecord,
	ConcreteStruct,
	ConcreteType,
	ConcreteUnion,
	isEmptyStruct,
	ReferenceKind;
import model.lowModel :
	AllLowTypes,
	LowExternTypeIndex,
	LowFunIndex,
	LowFunPointerTypeIndex,
	LowPointerConst,
	LowPointerGc,
	LowPointerMut,
	LowRecordIndex,
	LowType,
	LowUnionIndex,
	PrimitiveType;
import model.model : BuiltinType, IntegralType;
import util.alloc.alloc : Alloc;
import util.col.array : only;
import util.col.map : Map, mustGet;
import util.col.mutArr : MutArr, mutArrSize, push;
import util.col.mutMap : getOrAdd, MutMap;
import util.memory : allocate;
import util.union_ : Union;
import util.util : enumConvert;

// TODO: I could just save generating all MarkRoot / MarkVisit funs to the end, then not need this?
immutable struct LowFunCause {
	immutable struct MarkRoot {
		LowType type;
	}
	immutable struct MarkVisit {
		LowType type;
	}
	mixin Union!(ConcreteFun*, MarkRoot, MarkVisit);
}

LowFunIndex addLowFun(ref Alloc alloc, scope ref MutArr!LowFunCause lowFunCauses, LowFunCause source) {
	LowFunIndex res = LowFunIndex(mutArrSize(lowFunCauses));
	push(alloc, lowFunCauses, source);
	return res;
}

struct GetLowTypeCtx {
	@safe @nogc pure nothrow:

	Alloc* allocPtr;
	AllLowTypes allTypes;
	private:
	// Meaning of the value depends on the kind of ConcreteStruct; it might be a LowRecordIndex for example.
	Map!(immutable ConcreteStruct*, immutable uint) lowIndices;
	MutMap!(LowType, LowType*) typeToAllocated;

	public ref Alloc alloc() return scope =>
		*allocPtr;
}

private LowType* allocateLowType(ref GetLowTypeCtx ctx, LowType a) =>
	getOrAdd(ctx.alloc, ctx.typeToAllocated, a, () =>
		allocate(ctx.alloc, a));

private LowType getPointerGc(ref GetLowTypeCtx ctx, LowType pointee) =>
	LowType(LowPointerGc(allocateLowType(ctx, pointee)));

LowType getPointerConst(ref GetLowTypeCtx ctx, LowType pointee) =>
	LowType(LowPointerConst(allocateLowType(ctx, pointee)));

LowType getPointerMut(ref GetLowTypeCtx ctx, LowType pointee) =>
	LowType(LowPointerMut(allocateLowType(ctx, pointee)));

LowType lowTypeFromConcreteStruct(ref GetLowTypeCtx ctx, in ConcreteStruct* struct_) {
	if (isEmptyStruct(*struct_))
		return voidType;

	uint lowIndex() => mustGet(ctx.lowIndices, struct_);
	LowType record() => LowType(&ctx.allTypes.allRecords[LowRecordIndex(lowIndex)]);
	return struct_.body_.matchIn!LowType(
		(in ConcreteBuiltinType x) {
			final switch (x.kind) {
				case BuiltinType.bool_:
					return LowType(PrimitiveType.bool_);
				case BuiltinType.catchPoint:
					return LowType(&ctx.allTypes.allExternTypes[LowExternTypeIndex(lowIndex)]);
				case BuiltinType.char8:
					return LowType(PrimitiveType.char8);
				case BuiltinType.char32:
					return LowType(PrimitiveType.char32);
				case BuiltinType.float32:
					return LowType(PrimitiveType.float32);
				case BuiltinType.float64:
					return LowType(PrimitiveType.float64);
				case BuiltinType.funPointer:
					return LowType(&ctx.allTypes.allFunPointerTypes[LowFunPointerTypeIndex(lowIndex)]);
				case BuiltinType.int8:
					return LowType(PrimitiveType.int8);
				case BuiltinType.int16:
					return LowType(PrimitiveType.int16);
				case BuiltinType.int32:
					return LowType(PrimitiveType.int32);
				case BuiltinType.int64:
					return LowType(PrimitiveType.int64);
				case BuiltinType.array:
				case BuiltinType.mutSlice:
					return record();
				case BuiltinType.future: // Concretize replaces this with 'future-impl'
				case BuiltinType.lambdaData:
				case BuiltinType.lambdaMut:
				case BuiltinType.lambdaShared: // Concretize replaces this with a Union type
				case BuiltinType.option: // Concretize replaces this with a Union type
				case BuiltinType.mutArray: // Concretize replaces this with 'mut-array-impl'
					assert(false);
				case BuiltinType.javaAny:
				case BuiltinType.jsAny:
				case BuiltinType.void_:
					return LowType(PrimitiveType.void_);
				case BuiltinType.nat8:
					return LowType(PrimitiveType.nat8);
				case BuiltinType.nat16:
					return LowType(PrimitiveType.nat16);
				case BuiltinType.nat32:
					return LowType(PrimitiveType.nat32);
				case BuiltinType.nat64:
					return LowType(PrimitiveType.nat64);
				case BuiltinType.pointerConst:
					return getPointerConst(ctx, lowTypeFromConcreteType(ctx, only(x.typeArgs)));
				case BuiltinType.pointerMut:
					return getPointerMut(ctx, lowTypeFromConcreteType(ctx, only(x.typeArgs)));
				case BuiltinType.string_:
				case BuiltinType.symbol:
					// concretize turns string into 'char array' and symbol into 'char*'
					assert(false);
			}
		},
		(in ConcreteEnum x) =>
			LowType(typeOfIntegralType(x.storage)),
		(in ConcreteExternType x) =>
			LowType(&ctx.allTypes.allExternTypes[LowExternTypeIndex(lowIndex)]),
		(in ConcreteFlags x) =>
			LowType(typeOfIntegralType(x.storage)),
		(in ConcreteRecord _) =>
			record(),
		(in ConcreteUnion _) =>
			LowType(&ctx.allTypes.allUnions[LowUnionIndex(lowIndex)]));
}

LowType lowTypeFromConcreteType(ref GetLowTypeCtx ctx, in ConcreteType type) {
	LowType inner = lowTypeFromConcreteStruct(ctx, type.struct_);
	final switch (type.reference) {
		case ReferenceKind.byVal:
			return inner;
		case ReferenceKind.byRef:
			return getPointerGc(ctx, inner);
	}
}

private PrimitiveType typeOfIntegralType(IntegralType a) =>
	enumConvert!PrimitiveType(a);
