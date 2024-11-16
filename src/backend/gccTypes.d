module backend.gccTypes;

@safe @nogc pure nothrow:

version (GccJitAvailable) {

import backend.libgccjit :
	gcc_jit_binary_op,
	gcc_jit_block,
	gcc_jit_block_end_with_return,
	gcc_jit_comparison,
	gcc_jit_context,
	gcc_jit_context_get_type,
	gcc_jit_context_new_array_type,
	gcc_jit_context_new_binary_op,
	gcc_jit_context_new_cast,
	gcc_jit_context_new_comparison,
	gcc_jit_context_new_field,
	gcc_jit_context_new_function,
	gcc_jit_context_new_function_ptr_type,
	gcc_jit_context_new_opaque_struct,
	gcc_jit_context_new_rvalue_from_long,
	gcc_jit_context_new_struct_type,
	gcc_jit_context_new_union_type,
	gcc_jit_field,
	gcc_jit_function,
	gcc_jit_function_kind,
	gcc_jit_function_new_block,
	gcc_jit_function_new_local,
	gcc_jit_lvalue,
	gcc_jit_lvalue_access_field,
	gcc_jit_lvalue_get_address,
	gcc_jit_rvalue,
	gcc_jit_struct,
	gcc_jit_struct_as_type,
	gcc_jit_struct_set_fields,
	gcc_jit_type,
	gcc_jit_type_get_aligned,
	gcc_jit_type_get_pointer,
	gcc_jit_types;
import backend.mangle : MangledNames, writeStructMangledName;
import backend.writeTypes : TypeWriters, writeTypes;
import model.concreteModel : ConcreteStruct;
import model.lowModel :
	AllLowTypes,
	debugName,
	LowExternType,
	LowExternTypeIndex,
	LowField,
	LowFunPointerType,
	LowFunPointerTypeIndex,
	LowPointerCombine,
	LowProgram,
	LowRecord,
	LowRecordIndex,
	LowType,
	LowUnion,
	LowUnionIndex,
	PrimitiveType,
	typeSize;
import model.model : TypeSize;
import util.alloc.alloc : Alloc;
import util.col.array : isEmpty, map, mapWithIndex, zip;
import util.col.enumMap : EnumMap, makeEnumMap;
import util.col.fullIndexMap :
	FullIndexMap,
	fullIndexMapCastImmutable,
	fullIndexMapCastImmutable2,
	fullIndexMapZip3,
	mapFullIndexMap,
	mapFullIndexMap_mut;
import util.conv : safeToInt;
import util.opt : force, has, MutOpt, none, noneMut, Opt, some, someMut;
import util.string : CString;
import util.symbol : withCStringOfSymbol;
import util.util : castImmutable, castNonScope_ref, ptrTrustMe, typeAs;
import util.writer : withWriter, Writer;

immutable struct GccTypes {
	private:
	AllLowTypes* allTypes;
	GccPrimitiveTypes primitiveTypes;
	public GccExternTypes extern_;
	FullIndexMap!(LowFunPointerTypeIndex, gcc_jit_type*) funPtrs;
	FullIndexMap!(LowRecordIndex, gcc_jit_struct*) records;
	public FullIndexMap!(LowRecordIndex, gcc_jit_field*[]) recordFields;
	FullIndexMap!(LowUnionIndex, gcc_jit_struct*) unions;
	public FullIndexMap!(LowUnionIndex, UnionFields) unionFields;
}

private alias GccPrimitiveTypes = immutable EnumMap!(PrimitiveType, immutable gcc_jit_type*);
private alias GccExternTypes = immutable FullIndexMap!(LowExternTypeIndex, ExternTypeInfo);

immutable struct ExternTypeInfo {
	gcc_jit_type* type;
	Opt!ExternTypeArrayInfo array;
}
immutable struct ExternTypeArrayInfo {
	size_t elementCount;
	gcc_jit_field* field;
	gcc_jit_type* arrayType;
}

immutable struct UnionFields {
	gcc_jit_field* kindField;
	gcc_jit_field* innerField;
	gcc_jit_field*[] memberFields;
}

GccTypes getGccTypes(ref Alloc alloc, ref gcc_jit_context ctx, in LowProgram program, in MangledNames mangledNames) {
	GccTypesWip typesWip = GccTypesWip(
		ptrTrustMe(program.allTypes),
		getPrimitiveTypes(ctx),
		gccExternTypes(alloc, ctx, program, mangledNames),
		mapFullIndexMap_mut!(LowFunPointerTypeIndex, MutOpt!(gcc_jit_type*), LowFunPointerType)(
			alloc,
			program.allFunPointerTypes,
			(LowFunPointerTypeIndex _, in LowFunPointerType) =>
				noneMut!(gcc_jit_type*)),
		mapFullIndexMap_mut!(LowRecordIndex, gcc_jit_struct*, LowRecord)(
			alloc,
			program.allRecords,
			(LowRecordIndex _, in LowRecord record) =>
				structStub(alloc, ctx, mangledNames, record.source)),
		mapFullIndexMap_mut!(LowRecordIndex, immutable gcc_jit_field*[], LowRecord)(
			alloc,
			program.allRecords,
			(LowRecordIndex _, in LowRecord record) =>
				typeAs!(immutable gcc_jit_field*[])([])),
		mapFullIndexMap_mut!(LowUnionIndex, gcc_jit_struct*, LowUnion)(
			alloc,
			program.allUnions,
			(LowUnionIndex _, in LowUnion union_) =>
				structStub(alloc, ctx, mangledNames, union_.source)),
		mapFullIndexMap_mut!(LowUnionIndex, Opt!UnionFields, LowUnion)(
			alloc,
			program.allUnions,
			(LowUnionIndex, in LowUnion) =>
				none!UnionFields));

	scope TypeWriters writers = TypeWriters(
		(ConcreteStruct*) {
			// Do nothing, we declared types ahead of time.
		},
		(ConcreteStruct* source, in Opt!TypeSize) {
			// Declared ahead of time
		},
		(LowFunPointerTypeIndex funPtrIndex, in LowFunPointerType funPtr) {
			writeFunPointerType(alloc, ctx, typesWip, funPtrIndex, funPtr);
		},
		(LowRecordIndex recordIndex, in LowRecord* record) {
			writeRecordType(alloc, ctx, typesWip, recordIndex, *record);
		},
		(LowUnionIndex unionIndex, in LowUnion* union_) {
			writeUnionType(alloc, ctx, mangledNames, typesWip, unionIndex, *union_);
		});
	writeTypes(alloc, program, writers);

	return GccTypes(
		ptrTrustMe(program.allTypes),
		typesWip.primitiveTypes,
		typesWip.extern_,
		//TODO:PERF just cast, since Opt!Ptr and Ptr representations are the same
		mapFullIndexMap!(LowFunPointerTypeIndex, gcc_jit_type*, MutOpt!(gcc_jit_type*))(
			alloc,
			fullIndexMapCastImmutable(typesWip.funPtrs),
			(LowFunPointerTypeIndex _, ref immutable MutOpt!(gcc_jit_type*) a) =>
				force(a)),
		fullIndexMapCastImmutable(typesWip.records),
		fullIndexMapCastImmutable2!(LowRecordIndex, gcc_jit_field*[])(typesWip.recordFields),
		fullIndexMapCastImmutable(typesWip.unions),
		mapFullIndexMap!(LowUnionIndex, UnionFields, MutOpt!UnionFields)(
			alloc,
			fullIndexMapCastImmutable2(typesWip.unionFields),
			(LowUnionIndex, ref Opt!UnionFields x) =>
				force(x)));
}

immutable char* assertFieldOffsetsFunctionName = "__assertFieldOffsets";

extern(C) {
	alias AssertFieldOffsetsType = immutable bool function();
}

//TODO: this is just for debugging
immutable(gcc_jit_function*) generateAssertFieldOffsetsFunction(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in LowProgram program,
	in GccTypes types,
) {
	immutable gcc_jit_type* boolType = getGccType(types, LowType(PrimitiveType.bool_));
	immutable gcc_jit_type* nat64Type = getGccType(types, LowType(PrimitiveType.nat64));
	immutable gcc_jit_type* voidPtrType = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_VOID_PTR);

	gcc_jit_function* fn = gcc_jit_context_new_function(
		ctx,
		null,
		gcc_jit_function_kind.GCC_JIT_FUNCTION_EXPORTED,
		boolType,
		assertFieldOffsetsFunctionName,
		0,
		null,
		false);

	gcc_jit_rvalue* accum = gcc_jit_context_new_rvalue_from_long(ctx, boolType, 1);
	fullIndexMapZip3!(LowRecordIndex, LowRecord, gcc_jit_struct*, gcc_jit_field*[])(
		program.allRecords,
		types.records,
		types.recordFields,
		(LowRecordIndex _,
		 ref LowRecord record,
		 ref immutable gcc_jit_struct* gccRecord,
		 ref immutable gcc_jit_field*[] gccFields) {
			gcc_jit_lvalue* local = gcc_jit_function_new_local(fn, null, gcc_jit_struct_as_type(gccRecord), "temp");
			gcc_jit_rvalue* recordAddress = gcc_jit_context_new_cast(
				ctx,
				null,
				gcc_jit_lvalue_get_address(local, null),
				voidPtrType);
			zip!(LowField, immutable gcc_jit_field*)(
				record.fields,
				gccFields,
				(ref LowField field, ref immutable gcc_jit_field* gccField) {
					gcc_jit_rvalue* fieldAddress = gcc_jit_context_new_cast(
						ctx,
						null,
						gcc_jit_lvalue_get_address(gcc_jit_lvalue_access_field(local, null, gccField), null),
						voidPtrType);
					gcc_jit_rvalue* actualOffset = gcc_jit_context_new_binary_op(
						ctx,
						null,
						//TODO: pointer subtraction?
						gcc_jit_binary_op.GCC_JIT_BINARY_OP_MINUS,
						nat64Type,
						fieldAddress,
						recordAddress);
					gcc_jit_rvalue* expectedOffset =
						gcc_jit_context_new_rvalue_from_long(ctx, nat64Type, field.offset);
					gcc_jit_rvalue* eq = gcc_jit_context_new_comparison(
						ctx,
						null,
						gcc_jit_comparison.GCC_JIT_COMPARISON_EQ,
						actualOffset,
						expectedOffset);
					accum = gcc_jit_context_new_binary_op(
						ctx, null, gcc_jit_binary_op.GCC_JIT_BINARY_OP_LOGICAL_OR, boolType, accum, eq);
				});
		});

	gcc_jit_block* block = gcc_jit_function_new_block(fn, null);
	gcc_jit_block_end_with_return(block, null, accum);

	return castImmutable(fn);
}

immutable(gcc_jit_type*) getGccType(in GccTypes types, in LowType a) =>
	castNonScope_ref(a).combinePointer.matchWithPointers!(immutable gcc_jit_type*)(
		(LowExternType* x) =>
			types.extern_[types.allTypes.indexOfExternType(x)].type,
		(LowFunPointerType* x) =>
			types.funPtrs[types.allTypes.indexOfFunPointerType(x)],
		(PrimitiveType x) =>
			types.primitiveTypes[x],
		(LowPointerCombine x) =>
			gcc_jit_type_get_pointer(getGccType(types, x.pointee)),
		(LowRecord* x) =>
			gcc_jit_struct_as_type(types.records[types.allTypes.indexOfRecord(x)]),
		(LowUnion* x) =>
			gcc_jit_struct_as_type(types.unions[types.allTypes.indexOfUnion(x)]));

private:

immutable(gcc_jit_type*) getGccType(ref GccTypesWip typesWip, LowType a) =>
	a.combinePointer.matchWithPointers!(immutable gcc_jit_type*)(
		(LowExternType* x) =>
			typesWip.extern_[typesWip.allTypes.indexOfExternType(x)].type,
		(LowFunPointerType* x) =>
			castImmutable(force(typesWip.funPtrs[typesWip.allTypes.indexOfFunPointerType(x)])),
		(PrimitiveType x) =>
			typesWip.primitiveTypes[x],
		(LowPointerCombine x) =>
			gcc_jit_type_get_pointer(getGccType(typesWip, x.pointee)),
		(LowRecord* x) =>
			gcc_jit_struct_as_type(typesWip.records[typesWip.allTypes.indexOfRecord(x)]),
		(LowUnion* x) =>
			gcc_jit_struct_as_type(typesWip.unions[typesWip.allTypes.indexOfUnion(x)]));

GccPrimitiveTypes getPrimitiveTypes(ref gcc_jit_context ctx) =>
	makeEnumMap!(PrimitiveType, immutable gcc_jit_type*)((PrimitiveType type) =>
		getOnePrimitiveType(ctx, type));

immutable(gcc_jit_type*) getOnePrimitiveType(ref gcc_jit_context ctx, PrimitiveType a) {
	final switch (a) {
		case PrimitiveType.bool_:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_BOOL);
		case PrimitiveType.char8:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_CHAR);
		case PrimitiveType.char32:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_INT);
		case PrimitiveType.float32:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_FLOAT);
		case PrimitiveType.float64:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_DOUBLE);
		case PrimitiveType.int8:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_CHAR);
		case PrimitiveType.int16:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_SHORT);
		case PrimitiveType.int32:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_INT);
		case PrimitiveType.int64:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_LONG);
		case PrimitiveType.nat8:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_CHAR);
		case PrimitiveType.nat16:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_SHORT);
		case PrimitiveType.nat32:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_INT);
		case PrimitiveType.nat64:
			return gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_LONG);
		case PrimitiveType.void_:
			return gcc_jit_struct_as_type(gcc_jit_context_new_struct_type(ctx, null, "void", 0, null));
	}
}

struct GccTypesWip {
	AllLowTypes* allTypes;
	immutable GccPrimitiveTypes primitiveTypes;
	immutable GccExternTypes extern_;
	FullIndexMap!(LowFunPointerTypeIndex, MutOpt!(gcc_jit_type*)) funPtrs;
	FullIndexMap!(LowRecordIndex, gcc_jit_struct*) records;
	FullIndexMap!(LowRecordIndex, immutable gcc_jit_field*[]) recordFields;
	FullIndexMap!(LowUnionIndex, gcc_jit_struct*) unions;
	FullIndexMap!(LowUnionIndex, Opt!UnionFields) unionFields;
}

@trusted void writeFunPointerType(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	ref GccTypesWip typesWip,
	LowFunPointerTypeIndex funPtrIndex,
	in LowFunPointerType funPtr,
) {
	MutOpt!(gcc_jit_type*)* ptr = &typesWip.funPtrs[funPtrIndex];
	assert(!has(*ptr));
	const gcc_jit_type* returnType = getGccType(typesWip, funPtr.returnType);
	//TODO:NO ALLOC
	immutable gcc_jit_type*[] paramTypes = map(alloc, funPtr.paramTypes, (ref LowType x) =>
		getGccType(typesWip, x));
	*ptr = someMut!(gcc_jit_type*)(gcc_jit_context_new_function_ptr_type(
		ctx,
		null,
		returnType,
		cast(int) paramTypes.length,
		paramTypes.ptr,
		false));
}

@trusted void writeRecordType(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	ref GccTypesWip typesWip,
	LowRecordIndex recordIndex,
	in LowRecord record,
) {
	gcc_jit_struct* struct_ = typesWip.records[recordIndex];
	immutable gcc_jit_field*[] fields = map(alloc, record.fields, (ref LowField field) =>
		withCStringOfSymbol(debugName(field), (in CString name) =>
			gcc_jit_context_new_field(ctx, null, getGccType(typesWip, field.type), name.ptr)));
	assert(isEmpty(typesWip.recordFields[recordIndex]));
	typesWip.recordFields[recordIndex] = fields;
	gcc_jit_struct_set_fields(struct_, null, cast(int) fields.length, fields.ptr);
}

@trusted void writeUnionType(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in MangledNames mangledNames,
	ref GccTypesWip typesWip,
	LowUnionIndex unionIndex,
	in LowUnion union_,
) {
	gcc_jit_struct* struct_ = typesWip.unions[unionIndex];

	//TODO:NO ALLOC
	CString mangledNameInner = withWriter(alloc, (scope ref Writer writer) {
		writeStructMangledName(writer, mangledNames, union_.source);
		writer ~= "_inner";
	});

	immutable gcc_jit_field*[] memberFields = mapWithIndex!(immutable gcc_jit_field*, LowType)(
		alloc,
		union_.members,
		(size_t memberIndex, ref LowType memberType) {
			//TODO:NO ALLOC
			CString name = withWriter(alloc, (scope ref Writer writer) {
				writer ~= "as";
				writer ~= memberIndex;
			});
			return gcc_jit_context_new_field(ctx, null, getGccType(typesWip, castNonScope_ref(memberType)), name.ptr);
		});
	immutable gcc_jit_type* innerUnion = gcc_jit_context_new_union_type(
		ctx,
		null,
		mangledNameInner.ptr,
		cast(int) memberFields.length,
		memberFields.ptr);

	immutable gcc_jit_field* kindField =
		gcc_jit_context_new_field(ctx, null, getGccType(typesWip, LowType(PrimitiveType.nat64)), "kind");
	immutable gcc_jit_field* innerField = gcc_jit_context_new_field(ctx, null, innerUnion, "inner");
	scope immutable gcc_jit_field*[2] outerFields = [kindField, innerField];
	gcc_jit_struct_set_fields(struct_, null, 2, outerFields.ptr);
	assert(!has(typesWip.unionFields[unionIndex]));
	typesWip.unionFields[unionIndex] = some(UnionFields(kindField, innerField, memberFields));
}

GccExternTypes gccExternTypes(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in LowProgram program,
	in MangledNames mangledNames,
) =>
	mapFullIndexMap!(LowExternTypeIndex, ExternTypeInfo, LowExternType)(
		alloc,
		program.allExternTypes,
		(LowExternTypeIndex _, ref LowExternType extern_) {
			gcc_jit_struct* struct_ = structStub(alloc, ctx, mangledNames, extern_.source);
			TypeSize typeSize = typeSize(extern_);
			Opt!ExternTypeArrayInfo arrayInfo = () {
				if (typeSize.sizeBytes != 0) {
					immutable gcc_jit_type* elementType = getOnePrimitiveType(ctx, PrimitiveType.nat8);
					immutable gcc_jit_type* arrayType = gcc_jit_context_new_array_type(
						ctx, null, elementType, safeToInt(typeSize.sizeBytes));
					immutable gcc_jit_field* field = gcc_jit_context_new_field(ctx, null, arrayType, "__sizer");
					gcc_jit_struct_set_fields(struct_, null, 1, &field);
					return some(ExternTypeArrayInfo(typeSize.sizeBytes, field, arrayType));
				} else
					return none!ExternTypeArrayInfo;
			}();
			immutable gcc_jit_type* structType = gcc_jit_struct_as_type(struct_);
			immutable gcc_jit_type* type = typeSize.alignmentBytes == 0
				? structType
				: gcc_jit_type_get_aligned(structType, typeSize.alignmentBytes);
			return ExternTypeInfo(type, arrayInfo);
		});

gcc_jit_struct* structStub(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in MangledNames mangledNames,
	in ConcreteStruct* source,
) =>
	//TODO:PERF use a temporary (dont' allocate string)
	gcc_jit_context_new_opaque_struct(ctx, null, withWriter(alloc, (scope ref Writer writer) {
		writeStructMangledName(writer, mangledNames, source);
	}).ptr);

} // GccJitAvailable
