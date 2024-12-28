module interpret.generateBytecode;

@safe @nogc pure nothrow:

import frontend.showModel : ShowCtx;
import interpret.bytecode :
	ByteCode, ByteCodeIndex, ByteCodeSource, FunPointerToOperationPointer, Operation, Operations, TextIndex;
import interpret.bytecodeWriter :
	ByteCodeWriter,
	fillDelayedCall,
	fillDelayedFunPointer,
	finishOperations,
	getNextStackEntry,
	newByteCodeWriter,
	nextByteCodeIndex,
	setNextStackEntry,
	setStackEntryAfterParameters,
	StackEntries,
	StackEntry,
	writeCallFunPointerExtern,
	writeReturn;
import interpret.extern_ :
	AggregateCbs,
	DCaggr,
	DynCallType,
	DynCallSig,
	ExternPointersForAllLibraries,
	FunPointer,
	FunPointerInputs,
	MakeSyntheticFunPointers;
import interpret.funToReferences :
	eachFunPointer,
	finishAt,
	FunPointerReferences,
	FunPointerTypeToDynCallSig,
	FunReferences,
	FunToReferences,
	initFunToReferences;
import interpret.generateExpr : generateFunFromExpr, maxGlobalsSizeWords;
import interpret.generateText : generateText, generateVarsInfo, TextAndInfo, TextInfo, VarsInfo;
import interpret.runBytecode : maxThreadLocalsSizeWords;
import model.concreteModel : name;
import model.lowModel :
	LowExternType,
	LowField,
	LowFun,
	LowFunBodyExtern,
	LowFunExprBody,
	LowFunIndex,
	LowFunPointerType,
	LowFunPointerTypeIndex,
	LowLocal,
	LowPointerConst,
	LowPointerGc,
	LowPointerMut,
	LowProgram,
	LowPointerCombine,
	LowRecord,
	LowType,
	LowUnion,
	PrimitiveType;
import model.model : Program, VarKind;
import model.typeLayout : nStackEntriesForType, typeSizeBytes;
import util.alloc.alloc : Alloc, TempAlloc;
import util.col.array : map;
import util.col.arrayBuilder : buildArray, Builder, buildSmallArray;
import util.col.fullIndexMap : FullIndexMap, fullIndexMapEach, mapFullIndexMap;
import util.col.map : Map, KeyValuePair, mustGet, zipToMap;
import util.col.mutMap : getOrAddAndDidAdd, MutMap, ValueAndDidAdd;
import util.memory : allocate;
import util.opt : force, has;
import util.perf : Perf, PerfMeasure, withMeasure;
import util.util : castImmutable, castMutable, castNonScope_ref, ptrTrustMe, todo;

ByteCode generateBytecode(
	scope ref Perf perf,
	ref Alloc alloc,
	in ShowCtx showCtx,
	in Program modelProgram,
	in LowProgram program,
	ExternPointersForAllLibraries externPointers,
	in AggregateCbs aggregateCbs,
	in MakeSyntheticFunPointers makeSyntheticFunPointers,
) {
	//TODO: use a temp alloc for 2nd arg
	return withMeasure!(ByteCode, () =>
		generateBytecodeInner(
			alloc, alloc, showCtx, modelProgram, program, externPointers, aggregateCbs, makeSyntheticFunPointers)
	)(perf, alloc, PerfMeasure.generateBytecode);
}

private ByteCode generateBytecodeInner(
	ref Alloc codeAlloc,
	ref TempAlloc tempAlloc,
	in ShowCtx showCtx,
	in Program modelProgram,
	in LowProgram program,
	ExternPointersForAllLibraries externPointers,
	in AggregateCbs aggregateCbs,
	in MakeSyntheticFunPointers cbMakeSyntheticFunPointers,
) {
	DynCallTypeCtx typeCtx = DynCallTypeCtx(ptrTrustMe(codeAlloc), ptrTrustMe(showCtx), castNonScope_ref(aggregateCbs), ptrTrustMe(program));

	FunPointerTypeToDynCallSig funPtrTypeToDynCallSig =
		mapFullIndexMap!(LowFunPointerTypeIndex, DynCallSig, LowFunPointerType)(
			codeAlloc, program.allFunPointerTypes, (LowFunPointerTypeIndex _, ref LowFunPointerType x) =>
				makeDynCallSigFromPointer(typeCtx, x));

	FunToReferences funToReferences = initFunToReferences(tempAlloc, funPtrTypeToDynCallSig, program.allFuns.length);
	TextAndInfo text = generateText(codeAlloc, tempAlloc, program, funToReferences);
	VarsInfo vars = generateVarsInfo(codeAlloc, program);
	ByteCodeWriter writer = newByteCodeWriter(ptrTrustMe(codeAlloc));

	immutable FullIndexMap!(LowFunIndex, ByteCodeIndex) funToDefinition =
		mapFullIndexMap!(LowFunIndex, ByteCodeIndex, LowFun)(
			tempAlloc,
			program.allFuns,
			(LowFunIndex funIndex, ref LowFun fun) {
				ByteCodeIndex funPos = nextByteCodeIndex(writer);
				generateBytecodeForFun(
					tempAlloc, writer, funToReferences, text.info, vars, modelProgram, program,
					externPointers, typeCtx, funIndex, fun);
				return funPos;
		});

	Operations operations = finishOperations(writer);

	SyntheticFunPointers syntheticFunPointers = makeSyntheticFunPointers(
		codeAlloc, program, operations.byteCode, funToDefinition, funToReferences, cbMakeSyntheticFunPointers);

	fullIndexMapEach!(LowFunIndex, ByteCodeIndex)(
		funToDefinition,
		(LowFunIndex funIndex, ref ByteCodeIndex definitionIndex) @trusted {
			Operation* definition = &operations.byteCode[definitionIndex.index];
			FunReferences references = finishAt(tempAlloc, funToReferences, funIndex);
			foreach (ByteCodeIndex reference; references.calls)
				fillDelayedCall(operations, reference, definition);
			if (has(references.ptrRefs)) {
				FunPointerReferences ptrRefs = force(references.ptrRefs);
				FunPointer funPtr = mustGet(syntheticFunPointers.funToFunPointer, funIndex);
				foreach (TextIndex reference; ptrRefs.textRefs)
					*(cast(ulong*) &text.text[reference.index]) = funPtr.asUlong;
				foreach (ByteCodeIndex reference; ptrRefs.funPtrRefs)
					fillDelayedFunPointer(operations, reference, funPtr);
			}
		});

	return ByteCode(
		operations,
		syntheticFunPointers.funPointerToOperationPointer,
		castImmutable(text.text),
		vars.totalSizeWords,
		funToDefinition[program.main]);
}

private:

SyntheticFunPointers makeSyntheticFunPointers(
	ref Alloc alloc,
	in LowProgram program,
	Operation[] byteCode,
	in FunToDefinition funToDefinition,
	in FunToReferences funToReferences,
	in MakeSyntheticFunPointers cbMakeSyntheticFunPointers,
) {
	FunPointerInputs[] inputs = buildArray!FunPointerInputs(alloc, (scope ref Builder!FunPointerInputs builder) {
		eachFunPointer(funToReferences, (LowFunIndex funIndex, DynCallSig sig) {
			builder ~= FunPointerInputs(funIndex, sig, &byteCode[funToDefinition[funIndex].index]);
		});
	});
	FunPointer[] funPtrs = cbMakeSyntheticFunPointers(inputs);
	FunToFunPointer funToFunPointer = zipToMap!(LowFunIndex, FunPointer, FunPointerInputs, FunPointer)(
		alloc, inputs, funPtrs, (ref FunPointerInputs inputs, ref FunPointer funPtr) =>
			immutable KeyValuePair!(LowFunIndex, FunPointer)(inputs.funIndex, funPtr));
	FunPointerToOperationPointer funToOp = zipToMap!(immutable void*, Operation*, FunPointerInputs, FunPointer)(
		alloc, inputs, funPtrs, (ref FunPointerInputs inputs, ref FunPointer funPtr) =>
			immutable KeyValuePair!(immutable void*, immutable Operation*)(funPtr.pointer, inputs.operationPtr));
	return SyntheticFunPointers(funToFunPointer, funToOp);
}

immutable struct SyntheticFunPointers {
	FunToFunPointer funToFunPointer;
	FunPointerToOperationPointer funPointerToOperationPointer;
}
alias FunToFunPointer = Map!(LowFunIndex, FunPointer);
alias FunToDefinition = immutable FullIndexMap!(LowFunIndex, ByteCodeIndex);

void generateBytecodeForFun(
	ref TempAlloc tempAlloc,
	scope ref ByteCodeWriter writer,
	ref FunToReferences funToReferences,
	in TextInfo textInfo,
	in VarsInfo varsInfo,
	in Program modelProgram,
	in LowProgram program,
	ExternPointersForAllLibraries externPointers,
	ref DynCallTypeCtx typeCtx,
	LowFunIndex funIndex,
	ref LowFun fun,
) {
	assert(varsInfo.totalSizeWords[VarKind.global] < maxGlobalsSizeWords);
	assert(varsInfo.totalSizeWords[VarKind.threadLocal] < maxThreadLocalsSizeWords);

	size_t stackEntry = 0;
	StackEntries[] parameters = map(tempAlloc, fun.params, (ref LowLocal it) {
		StackEntry start = StackEntry(stackEntry);
		size_t n = nStackEntriesForType(program, it.type);
		stackEntry += n;
		return StackEntries(start, n);
	});
	setStackEntryAfterParameters(writer, StackEntry(stackEntry));
	size_t returnEntries = nStackEntriesForType(program, fun.returnType);
	ByteCodeSource source = ByteCodeSource(funIndex, fun.range.range.start);

	fun.body_.matchIn!void(
		(in LowFunBodyExtern body_) {
			generateExternCall(writer, program, funIndex, fun, body_, externPointers, typeCtx);
			writeReturn(writer, source);
		},
		(in LowFunExprBody body_) {
			generateFunFromExpr(
				tempAlloc, writer, modelProgram, program, textInfo, varsInfo, externPointers, funIndex,
				funToReferences, fun.params, parameters, returnEntries, body_);
		});
	assert(getNextStackEntry(writer).entry == returnEntries);
	setNextStackEntry(writer, StackEntry(0));
}

void generateExternCall(
	scope ref ByteCodeWriter writer,
	in LowProgram program,
	LowFunIndex funIndex,
	ref LowFun fun,
	in LowFunBodyExtern a,
	ExternPointersForAllLibraries externPointers,
	ref DynCallTypeCtx typeCtx,
) {
	ByteCodeSource source = ByteCodeSource(funIndex, fun.range.range.start);
	writeCallFunPointerExtern(
		writer, source,
		mustGet(mustGet(externPointers, a.libraryName), force(fun.name)).asFunPointer,
		makeDynCallSig(typeCtx, fun));
	writeReturn(writer, source);
}

struct DynCallTypeCtx {
	@safe @nogc pure nothrow:

	Alloc* allocPtr;
	ShowCtx* showCtx;
	AggregateCbs aggregateCbs;
	LowProgram* programPtr;
	MutMap!(LowRecord*, DynCallType.Aggregate*) records;
	MutMap!(LowUnion*, DynCallType.Aggregate*) unions;

	ref Alloc alloc() =>
		*allocPtr;
	ref LowProgram program() =>
		*programPtr;
}

DynCallSig makeDynCallSig(ref DynCallTypeCtx ctx, ref LowFun fun) =>
	DynCallSig(buildSmallArray!DynCallType(ctx.alloc, (scope ref Builder!DynCallType res) {
		res ~= toDynCallType(ctx, fun.returnType);
		foreach (ref LowLocal x; fun.params)
			res ~= toDynCallType(ctx, x.type);
	}));

DynCallSig makeDynCallSigFromPointer(ref DynCallTypeCtx ctx, ref LowFunPointerType fun) =>
	DynCallSig(buildSmallArray!DynCallType(ctx.alloc, (scope ref Builder!DynCallType res) {
		res ~= toDynCallType(ctx, fun.returnType);
		foreach (LowType x; fun.paramTypes)
			res ~= toDynCallType(ctx, x);
	}));

@trusted DynCallType recordOrUnionToDynCallType(T)(
	ref DynCallTypeCtx ctx,
	MutMap!(T, DynCallType.Aggregate*) cache,
	T x,
) {
	ValueAndDidAdd!(DynCallType.Aggregate*) res = getOrAddAndDidAdd(ctx.alloc, cache, x, () @trusted =>
		newAggregate(ctx, LowType(x)));
	DynCallType.Aggregate* aggr = res.value;
	if (res.didAdd)
		fillInAggregate(ctx, castMutable(aggr.dcAggr), LowType(x));
	return DynCallType(aggr);
}

@system DynCallType.Aggregate* newAggregate(ref DynCallTypeCtx ctx, LowType type) =>
	allocate(ctx.alloc, DynCallType.Aggregate(
		nStackEntriesForType(ctx.program, type),
		ctx.aggregateCbs.newAggregate(countFlattenedFields(ctx.program, type), typeSizeBytes(ctx.program, type))));

@system void fillInAggregate(ref DynCallTypeCtx ctx, DCaggr* dcAggr, LowType type) {
	eachFlattenedField(ctx.program, type, 0, (size_t offset, LowType fieldType) @trusted {
		ctx.aggregateCbs.addField(dcAggr, offset, toDynCallType(ctx, fieldType));
	});
	ctx.aggregateCbs.close(dcAggr);
}

DynCallType toDynCallType(ref DynCallTypeCtx ctx, LowType a) =>
	a.matchWithPointers!DynCallType(
		(LowExternType*) =>
			// If it has a size, could make an Aggregate.
			// If not this should be a compile error.
			todo!DynCallType("!"),
		(LowFunPointerType*) =>
			DynCallType.pointer,
		(PrimitiveType x) =>
			DynCallType(x),
		(LowPointerGc _) =>
			DynCallType.pointer,
		(LowPointerConst _) =>
			DynCallType.pointer,
		(LowPointerMut _) =>
			DynCallType.pointer,
		(LowRecord* x) =>
			recordOrUnionToDynCallType(ctx, ctx.records, x),
		(LowUnion* x) =>
			recordOrUnionToDynCallType(ctx, ctx.unions, x));

size_t countFlattenedFields(in LowProgram program, LowType type) {
	size_t res = 0;
	eachFlattenedField(program, type, 0, (size_t _, LowType _2) { res++; });
	return res;
}

alias CbFlattenedField = void delegate(size_t offset, LowType type) @safe @nogc pure nothrow;

void eachFlattenedField(in LowProgram program, in LowType type, size_t baseOffset, in CbFlattenedField cb) {
	type.combinePointer.matchIn!void(
		(in LowExternType _) =>
			assert(false),
		(in LowFunPointerType _) =>
			cb(baseOffset, type),
		(in PrimitiveType _) =>
			cb(baseOffset, type),
		(in LowPointerCombine _) =>
			cb(baseOffset, type),
		(in LowRecord x) {
			foreach (LowField field; x.fields)
				eachFlattenedField(program, field.type, baseOffset + field.offset, cb);
		},
		(in LowUnion x) {
			cb(baseOffset, LowType(PrimitiveType.nat64));
			foreach (LowType member; x.members)
				eachFlattenedField(program, member, baseOffset + x.membersOffset, cb);
		});
}
