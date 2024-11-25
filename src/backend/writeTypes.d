module backend.writeTypes;

@safe @nogc pure nothrow:

import model.concreteModel : ConcreteStruct;
import model.lowModel :
	LowExternType,
	LowField,
	LowFunPointerType,
	LowFunPointerTypeIndex,
	LowProgram,
	LowPointerCombine,
	LowRecord,
	LowRecordIndex,
	LowType,
	LowUnion,
	LowUnionIndex,
	PrimitiveType,
	typeSize;
import model.model : TypeSize;
import util.alloc.alloc : Alloc;
import util.col.array : every;
import util.col.fullIndexMap : FullIndexMap, fullIndexMapEachPointer, makeFullIndexMap_mut;
import util.opt : none, Opt, some;

void writeTypes(ref Alloc alloc, in LowProgram program, in TypeWriters writers) {
	foreach (ref LowExternType x; program.allExternTypes) {
		TypeSize size = typeSize(x);
		writers.cbWriteExternWithSize(x.source, size.alignmentBytes == 0 ? none!TypeSize : some(size));
	}

	// TODO: use a temp alloc...
	scope StructStates structStates = StructStates(
		makeFullIndexMap_mut!(LowFunPointerTypeIndex, bool)(
			alloc, program.allFunPointerTypes.length, (LowFunPointerTypeIndex _) => false),
		makeFullIndexMap_mut!(LowRecordIndex, StructState)(
			alloc, program.allRecords.length, (LowRecordIndex _) => StructState.none),
		makeFullIndexMap_mut!(LowUnionIndex, StructState)(
			alloc, program.allUnions.length, (LowUnionIndex _) => StructState.none));
	while (true) {
		bool madeProgress = false;
		bool someIncomplete = false;
		fullIndexMapEachPointer!(LowFunPointerTypeIndex, LowFunPointerType)(
			program.allFunPointerTypes,
			(LowFunPointerTypeIndex index, LowFunPointerType* funPointerType) {
				bool curState = structStates.funPtrStates[index];
				if (!curState) {
					if (tryWriteFunPointerDeclaration(program, structStates, writers, index, funPointerType)) {
						structStates.funPtrStates[index] = true;
						madeProgress = true;
					} else
						someIncomplete = true;
				}
			});
		fullIndexMapEachPointer!(LowRecordIndex, LowRecord)(
			program.allRecords,
			(LowRecordIndex recordIndex, LowRecord* record) {
				StructState curState = structStates.recordStates[recordIndex];
				if (curState != StructState.defined) {
					StructState didWork = writeRecordDeclarationOrDefinition(
						program, writers, structStates, curState, recordIndex, record);
					if (didWork > curState) {
						structStates.recordStates[recordIndex] = didWork;
						madeProgress = true;
					} else
						someIncomplete = true;
				}
			});
		fullIndexMapEachPointer!(LowUnionIndex, LowUnion)(
			program.allUnions,
			(LowUnionIndex unionIndex, LowUnion* union_) {
				StructState curState = structStates.unionStates[unionIndex];
				if (curState != StructState.defined) {
					StructState didWork = writeUnionDeclarationOrDefinition(
						program, writers, structStates, curState, unionIndex, union_);
					if (didWork > curState) {
						structStates.unionStates[unionIndex] = didWork;
						madeProgress = true;
					} else
						someIncomplete = true;
				}
			});
		if (someIncomplete)
			assert(madeProgress);
		else
			break;
	}
}

immutable struct TypeWriters {
	void delegate(ConcreteStruct*) @safe @nogc pure nothrow cbDeclareStruct;
	void delegate(ConcreteStruct*, in Opt!TypeSize) @safe @nogc pure nothrow cbWriteExternWithSize;
	void delegate(LowFunPointerTypeIndex, in LowFunPointerType) @safe @nogc pure nothrow cbWriteFunPointer;
	void delegate(LowRecordIndex, in LowRecord*) @safe @nogc pure nothrow cbWriteRecord;
	void delegate(LowUnionIndex, in LowUnion*) @safe @nogc pure nothrow cbWriteUnion;
}

private:

enum StructState {
	none,
	declared,
	defined,
}

struct StructStates {
	FullIndexMap!(LowFunPointerTypeIndex, bool) funPtrStates; // No need to define, just declared or not
	FullIndexMap!(LowRecordIndex, StructState) recordStates;
	FullIndexMap!(LowUnionIndex, StructState) unionStates;
}

bool canReferenceTypeAsValue(in LowProgram program, in StructStates states, in LowType a) =>
	a.combinePointer.matchWithPointers!bool(
		(LowExternType*) =>
			true,
		(LowFunPointerType* x) =>
			states.funPtrStates[program.indexOfFunPointerType(x)],
		(PrimitiveType _) =>
			true,
		(LowPointerCombine x) =>
			canReferenceTypeAsPointee(program, states, x.pointee),
		(LowRecord* x) =>
			states.recordStates[program.indexOfRecord(x)] == StructState.defined,
		(LowUnion* x) =>
			states.unionStates[program.indexOfUnion(x)] == StructState.defined);

bool canReferenceTypeAsPointee(in LowProgram program, in StructStates states, in LowType a) =>
	a.combinePointer.matchWithPointers!bool(
		(LowExternType*) =>
			true,
		(LowFunPointerType* x) =>
			states.funPtrStates[program.indexOfFunPointerType(x)],
		(PrimitiveType _) =>
			true,
		(LowPointerCombine x) =>
			canReferenceTypeAsPointee(program, states, x.pointee),
		(LowRecord* x) =>
			states.recordStates[program.indexOfRecord(x)] != StructState.none,
		(LowUnion* x) =>
			states.unionStates[program.indexOfUnion(x)] != StructState.none);

StructState writeRecordDeclarationOrDefinition(
	in LowProgram program,
	in TypeWriters writers,
	in StructStates structStates,
	StructState prevState,
	LowRecordIndex recordIndex,
	in LowRecord* record,
) {
	assert(prevState != StructState.defined);
	bool canWriteFields = every!LowField(record.fields, (in LowField f) =>
		canReferenceTypeAsValue(program, structStates, f.type));
	if (canWriteFields) {
		writers.cbWriteRecord(recordIndex, record);
		return StructState.defined;
	} else {
		writers.cbDeclareStruct(record.source);
		return StructState.declared;
	}
}

StructState writeUnionDeclarationOrDefinition(
	in LowProgram program,
	in TypeWriters writers,
	in StructStates structStates,
	StructState prevState,
	LowUnionIndex unionIndex,
	in LowUnion* union_,
) {
	assert(prevState != StructState.defined);
	if (every!LowType(union_.members, (in LowType t) => canReferenceTypeAsValue(program, structStates, t))) {
		writers.cbWriteUnion(unionIndex, union_);
		return StructState.defined;
	} else {
		writers.cbDeclareStruct(union_.source);
		return StructState.declared;
	}
}

bool tryWriteFunPointerDeclaration(
	in LowProgram program,
	in StructStates structStates,
	in TypeWriters writers,
	LowFunPointerTypeIndex funPointerIndex,
	in LowFunPointerType* funPointerType,
) {
	LowFunPointerType funPtr = program.allFunPointerTypes[funPointerIndex];
	bool canDeclare =
		canReferenceTypeAsPointee(program, structStates, funPtr.returnType) &&
		every!LowType(funPtr.paramTypes, (in LowType x) =>
			canReferenceTypeAsPointee(program, structStates, x));
	if (canDeclare)
		writers.cbWriteFunPointer(funPointerIndex, *funPointerType);
	return canDeclare;
}
