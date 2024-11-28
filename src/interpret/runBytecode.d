module interpret.runBytecode;

@nogc nothrow: // not @safe, not pure

import frontend.showModel : ShowCtx;
import interpret.bytecode :
	ByteCode, ByteCodeOffset, ByteCodeOffsetUnsigned, FunPointerToOperationPointer, initialOperationPointer, Operation;
import interpret.debugInfo : BacktraceEntry, fillBacktrace, InterpreterDebugInfo, logBacktrace, printDebugInfo;
import interpret.extern_ : countParameterEntries, DoDynCall, doDynCall, DynCallSig, FunPointer, sizeWords;
import interpret.stacks :
	assertStacksAtOriginalState,
	dataDupWords,
	dataEnd,
	dataPeek,
	dataPop,
	dataPopN,
	dataPush,
	dataPushUninitialized,
	dataRef,
	dataRemove,
	dataReturn,
	dataTop,
	returnPop,
	returnPush,
	Stacks,
	withDefaultStacks;
import model.integralValues : IntegralValue;
import model.lowModel : LowProgram;
import model.typeLayout : PackField;
import util.alloc.stackAlloc : ensureStackAllocInitialized;
import util.col.array : indexOf;
import util.col.map : mustGet;
import util.conv : safeToUint, safeToSizeT;
import util.exitCode : ExitCode;
import util.memory : memcpy, memmove, overwriteMemory;
import util.opt : force, has, Opt;
import util.perf : Perf, PerfMeasure, withMeasureNoAlloc;
import util.string : CString;
import util.util : castNonScope_ref, debugLog, divRoundUp, ptrTrustMe;

@safe ExitCode runBytecode(
	scope ref Perf perf,
	in ShowCtx printCtx,
	in DoDynCall doDynCall,
	in LowProgram lowProgram,
	in ByteCode byteCode,
	in CString[] allArgs,
) {
	resetThreadLocals();
	return withDefaultStacks!ExitCode((ref Stacks stacks) =>
		withInterpreter!ExitCode(doDynCall, printCtx, lowProgram, byteCode, stacks, () {
			dataPush(stacks, allArgs.length);
			dataPush(stacks, cast(ulong) allArgs.ptr);
			return withMeasureNoAlloc!(ExitCode, () @trusted =>
				runBytecodeInner(stacks, initialOperationPointer(byteCode))
			)(perf, PerfMeasure.run);
		}));
}

private ExitCode runBytecodeInner(ref Stacks stacks, Operation* operation) {
	stepUntilExit(stacks, operation);
	ulong returnCode = dataPop(stacks);
	assertStacksAtOriginalState(stacks);
	return ExitCode(safeToUint(returnCode));
}

void syntheticCall(
	Operation* operationPtr,
	in void delegate(scope ref Stacks stacks) @nogc nothrow cbPushArgs,
	in void delegate(scope ref Stacks stacks) @nogc nothrow cbPopResult,
) =>
	withDefaultStacks!void((scope ref Stacks stacks) {
		cbPushArgs(stacks);
		syntheticCallWithStacks(stacks, operationPtr);
		cbPopResult(stacks);
	});

void syntheticCallWithStacks(scope ref Stacks stacks, Operation* operationPtr) {
	returnPush(stacks, operationOpStopInterpretation.ptr);
	Operation* op = operationPtr;
	stepUntilExit(stacks, op);
}

// This only works if you did 'returnPush(stacks, operationOpStopInterpretation.ptr);'
void stepUntilExit(ref Stacks stacks, ref Operation* operation) {
	setNext(stacks, operation);
	do {
		static foreach (size_t i; 0 .. 4)
			nextOperationPtr.fn(nextStacks.dataPtr, nextStacks.returnPtr, nextOperationPtr + 1);
	} while (nextOperationPtr.fn != &opStopInterpretation);
	stacks = nextStacks;
	operation = nextOperationPtr;
}

// Actually steps until the operation after the break.
// This is designed to work the same whether 'nextOperation' is implemented with tail recursion or returns.
// In the tail-recursive case, the while loop should be redundant,
// since only an opBreak (or opStopInterpretation) instruction returns.
void stepUntilBreak(ref Stacks stacks, ref Operation* operation) {
	setNext(stacks, operation);
	do {
		assert(nextOperationPtr.fn != &opStopInterpretation);
		nextOperationPtr.fn(nextStacks.dataPtr, nextStacks.returnPtr, nextOperationPtr + 1);
	} while ((nextOperationPtr - 1).fn != &opBreak);
	stacks = nextStacks;
	operation = nextOperationPtr;
}

T withInterpreter(T)(
	in DoDynCall doDynCall_,
	in ShowCtx printCtx,
	in LowProgram lowProgram,
	in ByteCode byteCode,
	ref Stacks stacks,
	in T delegate() @nogc nothrow cb,
) {
	InterpreterDebugInfo debugInfo = InterpreterDebugInfo(
		ptrTrustMe(printCtx), ptrTrustMe(lowProgram), ptrTrustMe(byteCode), operationOpStopInterpretation);
	setGlobals(InterpreterGlobals(
		ptrTrustMe(debugInfo),
		castNonScope_ref(byteCode).funPointerToOperationPointer,
		castNonScope_ref(doDynCall_)));

	// Ensure the last 'return' returns to here.
	// (NOTE: For fiber stacks, they will have 'null' instead, since the fiber shouldn't be allowed to complete)
	returnPush(stacks, operationOpStopInterpretation.ptr);

	static if (is(T == void))
		cb();
	else
		T res = cb();

	debug {
		setGlobals(InterpreterGlobals(null, FunPointerToOperationPointer(), null));
	}

	static if (!is(T == void))
		return res;
}

private void setNext(Stacks stacks, Operation* operationPtr) {
	nextStacks = stacks;
	nextOperationPtr = operationPtr;
}
private static Stacks nextStacks;
private static Operation* nextOperationPtr;

private struct InterpreterGlobals {
	InterpreterDebugInfo* debugInfoPtr;
	const FunPointerToOperationPointer funPointerToOperationPointer;
	DoDynCall doDynCall;
}
private __gshared InterpreterGlobals globals = void;

private @trusted void setGlobals(InterpreterGlobals value) {
	overwriteMemory(&globals, value);
}

private ref InterpreterDebugInfo debugInfo() =>
	*globals.debugInfoPtr;

pragma(inline, true):

private void operationWithoutNext(alias cb)(
	ulong* stacksData, Operation** stacksReturn, Operation* cur,
) {
	cb(Stacks(stacksData, stacksReturn), cur);
}

private void operation(alias cb)(
	ulong* stacksData,
	Operation** stacksReturn,
	Operation* cur,
) {
	Stacks stacks = Stacks(stacksData, stacksReturn);
	static if (false) {
		printDebugInfo(debugInfo, dataTempAsArr(stacks), returnTempAsArrReverse(stacks), cur - 1);
		debugLog(__traits(identifier, cb));
	}
	cb(stacks, cur);
	version (TailRecursionAvailable) {
		return cur.fn(stacks.dataPtr, stacks.returnPtr, cur + 1);
	} else {
		setNext(stacks, cur);
	}
}

alias opAbort = operationWithoutNext!opAbortInner;
private void opAbortInner(Stacks stacks, Operation* cur) {
	assert(false, "Reached 'abort' instruction");
}

alias opBreak = operationWithoutNext!opBreakInner;
private void opBreakInner(Stacks stacks, Operation* cur) {
	setNext(stacks, cur);
}

private immutable Operation[8] operationOpStopInterpretation = [
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
	Operation(&opStopInterpretation),
];

private alias opStopInterpretation = operationWithoutNext!opStopInterpretationInner;
private void opStopInterpretationInner(Stacks stacks, Operation* cur) {
	setNext(stacks, &operationOpStopInterpretation[0]);
}

alias opReturnData(size_t offsetWords, size_t sizeWords) =
	operation!(opReturnDataInner!(offsetWords, sizeWords));
private void opReturnDataInner(size_t offsetWords, size_t sizeWords)(
	ref Stacks stacks, ref Operation* cur,
) {
	static assert(sizeWords <= offsetWords + 1);
	dataReturn(stacks, offsetWords, sizeWords);
}

alias opReturnDataVariable = operation!opReturnDataVariableInner;
private void opReturnDataVariableInner(ref Stacks stacks, ref Operation* cur) {
	size_t offsetWords = readStackOffset(cur);
	size_t sizeWords = readSizeT(cur);
	dataReturn(stacks, offsetWords, sizeWords);
}

alias opReturn = operation!opReturnInner;
private void opReturnInner(ref Stacks stacks, ref Operation* cur) {
	cur = returnPop(stacks);
}

alias opJumpIfFalse = operation!opJumpIfFalseInner;
private void opJumpIfFalseInner(ref Stacks stacks, ref Operation* cur) {
	ByteCodeOffsetUnsigned offset = ByteCodeOffsetUnsigned(readSizeT(cur));
	ulong value = dataPop(stacks);
	if (value == 0)
		cur += offset.offset;
}

alias opSwitchFiberInitial = operation!opSwitchFiberInitialInner;
private void opSwitchFiberInitialInner(ref Stacks stacks, ref Operation* cur) {
	ulong func = cast(Operation*) dataPop(stacks);
	ulong* stackHigh = cast(ulong*) dataPop(stacks);
	ulong** fromPtr = cast(ulong**) dataPop(stacks);
	ulong fiber = dataPop(stacks);

	returnPush(stacks, cur);
	dataPush(stacks, cast(ulong) stacks.returnPtr);
	*fromPtr = stacks.dataPtr;

	stacks.returnPtr = cast(Operation**) stackHigh;
	stacks.dataPtr = stackHigh - 0x20000; // Size hardcoded in 'create-new-fiber'

	returnPush(stacks, null); // Should not ever be popped, but better 'null' than something arbitrary
	dataPush(stacks, fiber);
	cur = mustGet(globals.funPointerToOperationPointer, FunPointer.fromUlong(func).pointer);
}

alias opSwitchFiber = operation!opSwitchFiberInner;
private void opSwitchFiberInner(ref Stacks stacks, ref Operation* cur) {
	ulong* to = cast(ulong*) dataPop(stacks);
	ulong** fromPtr = cast(ulong**) dataPop(stacks);

	returnPush(stacks, cur);
	dataPush(stacks, cast(ulong) stacks.returnPtr);
	*fromPtr = stacks.dataPtr;

	stacks.dataPtr = to;
	stacks.returnPtr = cast(Operation**) dataPop(stacks);
	cur = returnPop(stacks);
}

alias opSwitch0ToN(bool hasElse) = operation!(opSwitch0ToNInner!hasElse);
private void opSwitch0ToNInner(bool hasElse)(ref Stacks stacks, ref Operation* cur) {
	ByteCodeOffsetUnsigned[] offsets = readArray!ByteCodeOffsetUnsigned(cur);
	ulong value = dataPop(stacks);
	ByteCodeOffsetUnsigned offset = !hasElse || value < offsets.length ? offsets[safeToSizeT(value)] : offsets[$ - 1];
	cur += offset.offset;
}

alias opSwitchWithValues = operation!opSwitchWithValuesInner;
private void opSwitchWithValuesInner(ref Stacks stacks, ref Operation* cur) {
	IntegralValue[] values = readArray!IntegralValue(cur);
	ByteCodeOffsetUnsigned[] offsets = readArray!ByteCodeOffsetUnsigned(cur);
	IntegralValue value = IntegralValue(dataPop(stacks));
	Opt!size_t index = indexOf!IntegralValue(values, value);
	ByteCodeOffsetUnsigned offset = () {
		if (has(index))
			return offsets[force(index)];
		else {
			assert(offsets.length == values.length + 1);
			return offsets[$ - 1];
		}
	}();
	cur += offset.offset;
}

alias opStackRef = operation!opStackRefInner;
private void opStackRefInner(ref Stacks stacks, ref Operation* cur) {
	size_t offset = readStackOffset(cur);
	dataPush(stacks, cast(ulong) dataRef(stacks, offset));
}

alias opThreadLocalPtr = operation!opThreadLocalPtrInner;
private void opThreadLocalPtrInner(ref Stacks stacks, ref Operation* cur) {
	size_t offsetWords = readSizeT(cur);
	dataPush(stacks, cast(ulong) (threadLocalsStorage.ptr + offsetWords));
}
@safe pure size_t maxThreadLocalsSizeWords() =>
	256;
private static ulong[maxThreadLocalsSizeWords] threadLocalsStorage;
private @safe void resetThreadLocals() {
	foreach (ref ulong x; threadLocalsStorage)
		x = 0;
}

alias opReadWords(size_t pointerOffsetWords, size_t nWordsToRead) =
	operation!(opReadWordsInner!(pointerOffsetWords, nWordsToRead));
private void opReadWordsInner(size_t pointerOffsetWords, size_t nWordsToRead)(
	ref Stacks stacks, ref Operation* cur,
) {
	static assert(nWordsToRead != 0);
	opReadWordsCommon(stacks, cur, pointerOffsetWords, nWordsToRead);
}

alias opReadWordsVariable = operation!opReadWordsVariableInner;
private void opReadWordsVariableInner(ref Stacks stacks, ref Operation* cur) {
	size_t pointerOffsetWords = readSizeT(cur);
	size_t nWordsToRead = readSizeT(cur);
	opReadWordsCommon(stacks, cur, pointerOffsetWords, nWordsToRead);
}

private void opReadWordsCommon(ref Stacks stacks, ref Operation* cur, size_t pointerOffsetWords, size_t nWordsToRead) {
	debug assert(nWordsToRead != 0);
	immutable ulong* ptr = (cast(immutable ulong*) dataPop(stacks)) + pointerOffsetWords;
	foreach (size_t i; 0 .. nWordsToRead)
		dataPush(stacks, ptr[i]);
}

alias opReadNat8(size_t offsetBytes) = operation!(opReadNat8Inner!offsetBytes);
private void opReadNat8Inner(size_t offsetBytes)(ref Stacks stacks, ref Operation* cur) {
	dataPush(stacks, *((cast(immutable ubyte*) dataPop(stacks)) + offsetBytes));
}

alias opReadNat16(size_t offsetNat16s) = operation!(opReadNat16Inner!offsetNat16s);
private void opReadNat16Inner(size_t offsetNat16s)(ref Stacks stacks, ref Operation* cur) {
	dataPush(stacks, *((cast(immutable ushort*) dataPop(stacks)) + offsetNat16s));
}

alias opReadNat32(size_t offsetNat32s) = operation!(opReadNat32Inner!offsetNat32s);
private void opReadNat32Inner(size_t offsetNat32s)(ref Stacks stacks, ref Operation* cur) {
	dataPush(stacks, *((cast(immutable uint*) dataPop(stacks)) + offsetNat32s));
}

alias opReadBytesVariable = operation!opReadBytesVariableInner;
private void opReadBytesVariableInner(ref Stacks stacks, ref Operation* cur) {
	size_t offsetBytes = readSizeT(cur);
	size_t sizeBytes = readSizeT(cur);
	immutable ubyte* ptr = (cast(immutable ubyte*) dataPop(stacks)) + offsetBytes;
	readNoCheck(stacks, ptr, sizeBytes);
}

alias opWrite = operation!opWriteInner;
private void opWriteInner(ref Stacks stacks, ref Operation* cur) {
	size_t offset = readSizeT(cur);
	size_t size = readSizeT(cur);
	if (size < 8) { //TODO:UNNECESSARY?
		assert(size != 0);
		ulong value = dataPop(stacks);
		ubyte* ptr = cast(ubyte*) dataPop(stacks);
		writePartialBytes(ptr + offset, value, size);
	} else {
		size_t sizeWords = divRoundUp(size, 8);
		ubyte* destWithoutOffset = cast(ubyte*) dataPeek(stacks, sizeWords);
		ubyte* src = cast(ubyte*) (dataEnd(stacks) - sizeWords);
		ubyte* dest = destWithoutOffset + offset;
		memcpy(dest, src, size);
		dataPopN(stacks, sizeWords + 1);
	}
}

private void writePartialBytes(ubyte* ptr, ulong value, size_t size) {
	//TODO: Just have separate ops for separate sizes
	switch (size) {
		case 1:
			*(cast(ubyte*) ptr) = cast(ubyte) value;
			break;
		case 2:
			*(cast(ushort*) ptr) = cast(ushort) value;
			break;
		case 4:
			*(cast(uint*) ptr) = cast(uint) value;
			break;
		default:
			assert(false);
	}
}

alias opCall = operation!opCallInner;
private void opCallInner(ref Stacks stacks, ref Operation* cur) {
	Operation* op = readOperationPtr(cur);
	returnPush(stacks, cur);
	cur = op;
}

alias opCallFunPointer = operation!opCallFunPointerInner;
private void opCallFunPointerInner(ref Stacks stacks, ref Operation* cur) {
	DynCallSig sig = DynCallSig.fromOperation(readOperation(cur));
	FunPointer funPtr = FunPointer(cast(immutable void*) dataRemove(stacks, countParameterEntries(sig)));
	Opt!(Operation*) operationPtr = globals.funPointerToOperationPointer[funPtr.pointer];
	if (has(operationPtr)) {
		returnPush(stacks, cur);
		cur = force(operationPtr);
	} else
		doDynCall(globals.doDynCall, stacks, sig, funPtr);
}

alias opCallFunPointerExtern = operation!opCallFunPointerExternInner;
private void opCallFunPointerExternInner(ref Stacks stacks, ref Operation* cur) {
	assert(FunPointer.sizeof <= ulong.sizeof);
	FunPointer funPtr = FunPointer(readOperation(cur).voidPtr);
	DynCallSig sig = DynCallSig.fromOperation(readOperation(cur));
	doDynCall(globals.doDynCall, stacks, sig, funPtr);
}

alias opSetupCatch = operation!opSetupCatchInner;
private void opSetupCatchInner(ref Stacks stacks, ref Operation* cur) {
	CatchPoint* point = cast(CatchPoint*) dataPop(stacks);
	*point = CatchPoint(stacks, cur);
	dataPush(stacks, 0);
}

alias opJumpToCatch = operation!opJumpToCatchInner;
private void opJumpToCatchInner(ref Stacks stacks, ref Operation* cur) {
	CatchPoint* point = cast(CatchPoint*) dataPop(stacks);
	stacks = point.stacks;
	cur = point.nextOperationPtr;
	// return value of 'setup-catch'
	dataPush(stacks, 1);
}

alias opInterpreterBacktrace = operation!opInterpreterBacktraceInner;
private void opInterpreterBacktraceInner(ref Stacks stacks, ref Operation* cur) {
	size_t skip = safeToSizeT(dataPop(stacks));
	size_t max = safeToSizeT(dataPop(stacks));
	BacktraceEntry* out_ = cast(BacktraceEntry*) dataPop(stacks);
	ensureStackAllocInitialized();
	BacktraceEntry* res = fillBacktrace(debugInfo, out_, max, skip, stacks);
	dataPush(stacks, cast(size_t) res);
}

public void debugLogInterpreterBacktrace(in Stacks stacks) {
	logBacktrace(debugInfo, stacks);
}

private struct CatchPoint {
	Stacks stacks;
	Operation* nextOperationPtr;
}
static assert(CatchPoint.sizeof <= 0x18); // Keep in sync with 'getBuiltinStructSize'

alias opFnUnary(alias cb) = operation!(opFnUnaryInner!cb);
private void opFnUnaryInner(alias cb)(ref Stacks stacks, ref Operation* cur) {
	dataPush(stacks, cb(dataPop(stacks)));
}

alias opFnBinary(alias cb) = operation!(opFnBinaryInner!cb);
private void opFnBinaryInner(alias cb)(ref Stacks stacks, ref Operation* cur) {
	ulong y = dataPop(stacks);
	ulong x = dataPop(stacks);
	dataPush(stacks, cb(x, y));
}

private Operation readOperation(scope ref Operation* cur) {
	Operation res = *cur;
	cur++;
	return res;
}

private size_t readStackOffset(ref Operation* cur) =>
	readSizeT(cur);

private long readInt64(ref Operation* cur) =>
	readOperation(cur).long_;

private ulong readNat64(ref Operation* cur) =>
	readOperation(cur).ulong_;

private size_t readSizeT(ref Operation* cur) =>
	safeToSizeT(readNat64(cur));

private Operation* readOperationPtr(ref Operation* cur) =>
	cast(Operation*) readSizeT(cur);

private immutable(T[]) readArray(T)(ref Operation* cur) {
	size_t size = readSizeT(cur);
	assert(size < 999); // sanity check
	immutable T* ptr = cast(immutable T*) cur;
	immutable T[] res = ptr[0 .. size];
	immutable(ubyte)* end = cast(immutable ubyte*) (ptr + size);
	while ((cast(size_t) end) % Operation.sizeof != 0) end++;
	assert((cast(size_t) cur) % Operation.sizeof == 0);
	assert((cast(size_t) end) % Operation.sizeof == 0);
	cur = cast(Operation*) end;
	return res;
}

alias opJump = operation!opJumpInner;
private void opJumpInner(ref Stacks stacks, ref Operation* cur) {
	ByteCodeOffset offset = ByteCodeOffset(readInt64(cur));
	cur += offset.offset;
}

alias opPack = operation!opPackInner;
private void opPackInner(ref Stacks stacks, ref Operation* cur) {
	size_t inEntries = readSizeT(cur);
	size_t outEntries = readSizeT(cur);
	PackField[] fields = readArray!PackField(cur);

	ubyte* base = cast(ubyte*) (dataEnd(stacks) - inEntries);
	foreach (PackField field; fields)
		memmove(base + field.outOffset, base + field.inOffset, safeToSizeT(field.size));

	// drop extra entries
	dataPopN(stacks, inEntries - outEntries);

	// fill remaining bytes with 0
	ubyte* ptr = base + fields[$ - 1].outOffset + fields[$ - 1].size;
	while (ptr < cast(ubyte*) dataEnd(stacks)) {
		*ptr = 0;
		ptr++;
	}
}

alias opPushValue64 = operation!opPushInner;
private void opPushInner(ref Stacks stacks, ref Operation* cur) {
	dataPush(stacks, readNat64(cur));
}

alias opDupBytes = operation!opDupBytesInner;
private void opDupBytesInner(ref Stacks stacks, ref Operation* cur) {
	size_t offsetBytes = readSizeT(cur);
	size_t sizeBytes = readSizeT(cur);
	const ubyte* ptr = (cast(const ubyte*) dataEnd(stacks)) - offsetBytes;
	readNoCheck(stacks, ptr, sizeBytes);
}

alias opDupWords(size_t offsetWords, size_t sizeWords) =
	operation!(opDupWordsInner!(offsetWords, sizeWords));
private void opDupWordsInner(size_t offsetWords, size_t sizeWords)(ref Stacks stacks, ref Operation* cur) {
	static assert(sizeWords <= offsetWords + 1);
	dataDupWords(stacks, offsetWords, sizeWords);
}

alias opDupWordsVariable = operation!opDupWordsVariableInner;
private void opDupWordsVariableInner(ref Stacks stacks, ref Operation* cur) {
	size_t offsetWords = readStackOffset(cur);
	size_t sizeWords = readSizeT(cur);
	dataDupWords(stacks, offsetWords, sizeWords);
}

// Copies data from the top of the stack to write to something lower on the stack.
alias opSet(size_t offsetWords, size_t sizeWords) = operation!(opSetInner!(offsetWords, sizeWords));
private void opSetInner(size_t offsetWords, size_t sizeWords)(
	ref Stacks stacks, ref Operation* cur,
) {
	static assert(sizeWords != 0);
	static assert(sizeWords <= offsetWords + 1);
	opSetCommon(stacks, cur, offsetWords, sizeWords);
}

alias opSetVariable = operation!opSetVariableInner;
private void opSetVariableInner(ref Stacks stacks, ref Operation* cur) {
	size_t offsetWords = readStackOffset(cur);
	size_t sizeWords = readSizeT(cur);
	opSetCommon(stacks, cur, offsetWords, sizeWords);
}

private void opSetCommon(ref Stacks stacks, ref Operation* cur, size_t offsetWords, size_t sizeWords) {
	debug assert(sizeWords != 0);
	debug assert(sizeWords <= offsetWords + 1);
	// Start at the end of the range and pop in reverse
	ulong* begin = dataTop(stacks) - offsetWords;
	ulong* ptr = begin + sizeWords;
	foreach (size_t i; 0 .. sizeWords) {
		ptr--;
		*ptr = dataPop(stacks);
	}
	assert(ptr == begin);
}

private void readNoCheck(ref Stacks stacks, const ubyte* readFrom, size_t sizeBytes) {
	size_t sizeWords = divRoundUp(sizeBytes, ulong.sizeof);
	ubyte* outPtr = cast(ubyte*) dataPushUninitialized(stacks, sizeWords);
	memcpy(outPtr, readFrom, sizeBytes);

	ubyte* endPtr = outPtr + sizeBytes;
	while (endPtr < cast(ubyte*) dataEnd(stacks)) {
		*endPtr = 0;
		endPtr++;
	}
}
