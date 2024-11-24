module interpret.bytecodeWriter;

@safe @nogc pure nothrow:

import interpret.applyFn : fnWrapAddIntegral, fnWrapMulIntegral;
import interpret.bytecode :
	addByteCodeIndex,
	ByteCodeIndex,
	ByteCodeOffset,
	ByteCodeOffsetUnsigned,
	ByteCodeSource,
	Operation,
	Operations,
	stackEntrySize,
	StackOffset,
	StackOffsetBytes,
	subtractByteCodeIndex;
import interpret.extern_ : countParameterEntries, DynCallSig, FunPointer, sizeWords;
import interpret.runBytecode :
	opAbort,
	opBreak,
	opCall,
	opCallFunPointer,
	opCallFunPointerExtern,
	opDupBytes,
	opDupWords,
	opDupWordsVariable,
	opInterpreterBacktrace,
	opJumpToCatch,
	opPack,
	opPushValue64,
	opSet,
	opSetVariable,
	opJump,
	opJumpIfFalse,
	opReadBytesVariable,
	opReadNat8,
	opReadNat16,
	opReadNat32,
	opReadWords,
	opReadWordsVariable,
	opReturnData,
	opReturnDataVariable,
	opReturn,
	opStackRef,
	opSwitch0ToN,
	opSwitchWithValues,
	opThreadLocalPtr,
	opWrite;
import model.typeLayout : Pack;
import util.alloc.alloc : Alloc;
import util.col.array : endPtr;
import util.col.arrayBuilder : add, ArrayBuilder, backUp, finish;
import util.col.fullIndexMap : fullIndexMapOfArr;
import util.col.mutArr : moveToMutArray, mustPop, MutArr, mutArrEnd, mutArrSize, push;
import util.integralValues : IntegralValues;
import util.memory : initMemory, overwriteMemory;
import util.util : divRoundUp, isMultipleOf, todo;

struct ByteCodeWriter {
	private:
	Alloc* alloc;
	// NOTE: sometimes we will write operation arguments here and cast to Operation
	MutArr!Operation operations;
	ArrayBuilder!ByteCodeSource sources; // parallel to operations
	size_t nextStackEntry = 0;
}

ByteCodeWriter newByteCodeWriter(return scope Alloc* alloc) =>
	ByteCodeWriter(alloc);

immutable struct StackEntry {
	size_t entry;
}

immutable struct StackEntries {
	StackEntry start; // Index of first entry
	size_t size; // Number of entries
}

StackEntry stackEntriesEnd(StackEntries a) =>
	StackEntry(a.start.entry + a.size);

Operations finishOperations(ref ByteCodeWriter writer) =>
	Operations(
		moveToMutArray!Operation(*writer.alloc, writer.operations),
		fullIndexMapOfArr!(ByteCodeIndex, ByteCodeSource)(finish(*writer.alloc, writer.sources)));

StackEntry getNextStackEntry(in ByteCodeWriter writer) =>
	StackEntry(writer.nextStackEntry);

void setNextStackEntry(scope ref ByteCodeWriter writer, StackEntry entry) {
	writer.nextStackEntry = entry.entry;
}

void setStackEntryAfterParameters(scope ref ByteCodeWriter writer, StackEntry entry) {
	assert(writer.nextStackEntry == 0);
	writer.nextStackEntry = entry.entry;
}

ByteCodeIndex nextByteCodeIndex(in ByteCodeWriter writer) =>
	ByteCodeIndex(mutArrSize(writer.operations));

void writeAbort(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opAbort);
}

// This special instruction returns instead of proceeding to the next operation.
// (Though in non-tail-recursive builds, all operations return.)
void writeBreak(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opBreak);
}

ByteCodeIndex writeCallDelayed(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	StackEntry stackEntryBeforeArgs,
	size_t nEntriesForReturnType,
) {
	pushOperationFn(writer, source, &opCall);
	ByteCodeIndex fnAddress = nextByteCodeIndex(writer);
	pushNat64(writer, source, 0);
	writer.nextStackEntry = stackEntryBeforeArgs.entry + nEntriesForReturnType;
	return fnAddress;
}

void fillDelayedCall(ref Operations operations, ByteCodeIndex index, Operation* definition) {
	overwriteMemory(&operations.byteCode[index.index], Operation(definition));
}

void writeCallFunPointer(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	// This is before the fun-pointer arg, which should be the first
	StackEntry stackEntryBeforeArgs,
	DynCallSig sig,
) {
	assert(stackEntryBeforeArgs.entry == writer.nextStackEntry - countParameterEntries(sig) - 1);
	pushOperationFn(writer, source, &opCallFunPointer);
	writeCallFunPointerCommon(writer, source, sig);
	writer.nextStackEntry -= 1; // for the fun-pointer
	assert(writer.nextStackEntry == stackEntryBeforeArgs.entry + sizeWords(sig.returnType));
}

void writeCallFunPointerExtern(scope ref ByteCodeWriter writer, ByteCodeSource source, FunPointer fun, DynCallSig sig) {
	pushOperationFn(writer, source, &opCallFunPointerExtern);
	pushOperation(writer, source, Operation(fun.pointer));
	writeCallFunPointerCommon(writer, source, sig);
}

private void writeCallFunPointerCommon(scope ref ByteCodeWriter writer, ByteCodeSource source, DynCallSig sig) {
	pushOperation(writer, source, sig.toOperation);
	writer.nextStackEntry -= countParameterEntries(sig);
	writer.nextStackEntry += sizeWords(sig.returnType);
}

private size_t getStackOffsetTo(in ByteCodeWriter writer, StackEntry stackEntry) {
	assert(stackEntry.entry <= getNextStackEntry(writer).entry);
	return getNextStackEntry(writer).entry - 1 - stackEntry.entry;
}

private StackOffsetBytes getStackOffsetBytes(in ByteCodeWriter writer, StackEntry stackEntry, size_t offsetBytes) =>
	// stack entry offsets use 0 for the last entry,
	// but byte offsets use 0 for the next entry (thus 1 is the final byte of the last entry)
	StackOffsetBytes((getStackOffsetTo(writer, stackEntry) + 1) * 8 - offsetBytes);

void writeDupEntries(scope ref ByteCodeWriter writer, ByteCodeSource source, StackEntries entries) {
	assert(entries.size != 0);
	assert(entries.start.entry + entries.size <= getNextStackEntry(writer).entry);
	writeDup(writer, source, start: entries.start, offsetBytes: 0, sizeBytes: entries.size * 8);
}

void writeDup(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	StackEntry start,
	size_t offsetBytes,
	size_t sizeBytes,
) {
	assert(sizeBytes != 0);
	assert(offsetBytes < 8);

	if (offsetBytes == 0 && isMultipleOf(sizeBytes, 8)) {
		writeDupWords(writer, source, getStackOffsetTo(writer, start), sizeBytes / 8);
	} else {
		pushOperationFn(writer, source, &opDupBytes);
		pushSizeT(writer, source, getStackOffsetBytes(writer, start, offsetBytes).offsetBytes);
		pushSizeT(writer, source, sizeBytes);
		writer.nextStackEntry += divRoundUp(sizeBytes, 8);
	}
}

private void writeDupWords(
	scope ref ByteCodeWriter writer,
	ByteCodeSource source,
	size_t offsetWords,
	size_t sizeWords,
) {
	assert(sizeWords != 0);
	writer.nextStackEntry += sizeWords;

	static foreach (size_t possibleSize; 1 .. 8)
		static foreach (size_t possibleOffset; possibleSize - 1 .. 16)
			if (offsetWords == possibleOffset && sizeWords == possibleSize) {
				pushOperationFn(writer, source, &opDupWords!(possibleOffset, possibleSize));
				return;
			}

	pushOperationFn(writer, source, &opDupWordsVariable);
	pushSizeT(writer, source, offsetWords);
	pushSizeT(writer, source, sizeWords);
}

void writeSet(scope ref ByteCodeWriter writer, ByteCodeSource source, StackEntries entries) {
	if (entries.size != 0) {
		writeSetInner(writer, source, getStackOffsetTo(writer, entries.start), entries.size);
		writer.nextStackEntry -= entries.size;
	}
}

private void writeSetInner(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t offset, size_t size) {
	static foreach (size_t possibleSize; 1 .. 8)
		static foreach (size_t possibleOffset; possibleSize - 1 .. 16)
			if (offset == possibleOffset && size == possibleSize) {
				pushOperationFn(writer, source, &opSet!(possibleOffset, possibleSize));
				return;
			}

	pushOperationFn(writer, source, &opSetVariable);
	pushSizeT(writer, source, offset);
	pushSizeT(writer, source, size);
}

void writeRead(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t pointerOffsetBytes, size_t nBytesToRead) {
	assert(nBytesToRead != 0);
	if (isMultipleOf(pointerOffsetBytes, 8) && isMultipleOf(nBytesToRead, 8))
		writeReadWords(writer, source, pointerOffsetBytes / 8, nBytesToRead / 8);
	else
		writeReadBytes(writer, source, pointerOffsetBytes, nBytesToRead);
	writer.nextStackEntry += divRoundUp(nBytesToRead, stackEntrySize) - 1;
}

private void writeReadWords(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	size_t pointerOffsetWords,
	size_t nWordsToRead,
) {
	assert(nWordsToRead != 0);

	static foreach (size_t possiblePointerOffsetWords; 0 .. 8)
		static foreach (size_t possibleNWordsToRead; 1 .. 4)
			if (pointerOffsetWords == possiblePointerOffsetWords && nWordsToRead == possibleNWordsToRead) {
				pushOperationFn(writer, source, &opReadWords!(possiblePointerOffsetWords, possibleNWordsToRead));
				return;
			}

	pushOperationFn(writer, source, &opReadWordsVariable);
	pushSizeT(writer, source, pointerOffsetWords);
	pushSizeT(writer, source, nWordsToRead);
}

private void writeReadBytes(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	size_t pointerOffsetBytes,
	size_t nBytesToRead,
) {
	switch (nBytesToRead) {
		case 1:
			static foreach (size_t possibleOffsetNat8s; 0 .. 8)
				if (pointerOffsetBytes == possibleOffsetNat8s) {
					pushOperationFn(writer, source, &opReadNat8!possibleOffsetNat8s);
					return;
				}
			break;
		case 2:
			if (isMultipleOf(pointerOffsetBytes, 2)) {
				size_t offsetNat16s = pointerOffsetBytes / 2;
				static foreach (size_t possibleOffsetNat16s; 0 .. 4)
					if (offsetNat16s == possibleOffsetNat16s) {
						pushOperationFn(writer, source, &opReadNat16!possibleOffsetNat16s);
						return;
					}
			}
			break;
		case 4:
			if (isMultipleOf(pointerOffsetBytes, 4)) {
				size_t offsetNat32s = pointerOffsetBytes / 2;
				static foreach (size_t possibleOffsetNat32s; 0 .. 2)
					if (offsetNat32s == possibleOffsetNat32s) {
						pushOperationFn(writer, source, &opReadNat32!possibleOffsetNat32s);
						return;
					}
			}
			break;
		default:
			break;
	}

	pushOperationFn(writer, source, &opReadBytesVariable);
	pushSizeT(writer, source, pointerOffsetBytes);
	pushSizeT(writer, source, nBytesToRead);
}

void writeStackRef(
	scope ref ByteCodeWriter writer,
	ByteCodeSource source,
	StackEntry stackEntry,
	size_t byteOffset = 0,
) {
	pushOperationFn(writer, source, &opStackRef);
	StackOffset offset = StackOffset(getStackOffsetTo(writer, stackEntry));
	pushSizeT(writer, source, offset.offset);
	writer.nextStackEntry += 1;

	if (byteOffset != 0)
		writeAddConstantNat64(writer, source, byteOffset);
}

void writeThreadLocalPtr(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t offsetWords) {
	pushOperationFn(writer, source, &opThreadLocalPtr);
	pushSizeT(writer, source, offsetWords);
	writer.nextStackEntry += 1;
}

void writeWrite(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t offset, size_t size) {
	assert(size != 0);
	pushOperationFn(writer, source, &opWrite);
	pushSizeT(writer, source, offset);
	pushSizeT(writer, source, size);
	writer.nextStackEntry -= divRoundUp(size, stackEntrySize) + 1;
}

void writeAddConstantNat64(scope ref ByteCodeWriter writer, ByteCodeSource source, ulong arg) {
	assert(arg != 0);
	writePushConstant(writer, source, arg);
	writeFnBinary(writer, source, &fnWrapAddIntegral);
}

void writeMulConstantNat64(scope ref ByteCodeWriter writer, ByteCodeSource source, ulong arg) {
	assert(arg != 0 && arg != 1);
	writePushConstant(writer, source, arg);
	writeFnBinary(writer, source, &fnWrapMulIntegral);
}

// Consume stack space without caring what's in it. Useful for unions.
void writePushEmptySpace(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t nSpaces) {
	foreach (ulong i; 0 .. nSpaces)
		writePushConstant(writer, source, 0);
}

void writePushConstants(scope ref ByteCodeWriter writer, ByteCodeSource source, in ulong[] values) {
	foreach (ulong value; values)
		writePushConstant(writer, source, value);
}

void writePushConstant(scope ref ByteCodeWriter writer, ByteCodeSource source, ulong value) {
	pushOperationFn(writer, source, &opPushValue64);
	pushNat64(writer, source, value);
	writer.nextStackEntry++;
}

void writePushConstantPointer(scope ref ByteCodeWriter writer, ByteCodeSource source, immutable ubyte* value) {
	writePushConstant(writer, source, cast(ulong) value);
}

void writeReturn(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opReturn);
}

ByteCodeIndex writePushFunPointerDelayed(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opPushValue64);
	ByteCodeIndex fnAddress = nextByteCodeIndex(writer);
	pushNat64(writer, source, 0);
	writer.nextStackEntry++;
	return fnAddress;
}

void fillDelayedFunPointer(ref Operations operations, ByteCodeIndex index, FunPointer definition) {
	overwriteMemory(&operations.byteCode[index.index], Operation(definition.asUlong));
}

void writeRemove(scope ref ByteCodeWriter writer, ByteCodeSource source, StackEntries entries) {
	if (entries.size != 0) {
		writeRemoveInner(
			writer,
			source,
			getStackOffsetTo(writer, entries.start),
			entries.size);
		writer.nextStackEntry -= entries.size;
	}
}

/*
'returnEntries' is where we want to return value to end up. (It is currently at the end of the stack)
*/
void writeReturnData(scope ref ByteCodeWriter writer, ByteCodeSource source, StackEntries returnEntries) {
	StackEntry next = getNextStackEntry(writer);
	StackEntry returnEnd = stackEntriesEnd(returnEntries);
	assert(stackEntriesEnd(returnEntries).entry <= next.entry);
	if (returnEnd != next) {
		size_t offset = getStackOffsetTo(writer, returnEntries.start);
		writeReturnDataInner(writer, source, offset, returnEntries.size);
		assert(writer.nextStackEntry - (offset + 1) + returnEntries.size == returnEnd.entry);
		writer.nextStackEntry = returnEnd.entry;
	}
}

private void writeRemoveInner(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	size_t offsetWords,
	size_t removedWords,
) {
	assert(removedWords <= offsetWords + 1);
	size_t returnedWords = offsetWords + 1 - removedWords;
	writeReturnDataInner(writer, source, offsetWords, returnedWords);
}

private void writeReturnDataInner(
	ref ByteCodeWriter writer,
	ByteCodeSource source,
	size_t offsetWords,
	size_t returnedWords,
) {
	assert(returnedWords <= offsetWords + 1);

	static foreach (size_t possibleSize; 0 .. 8)
		static foreach (size_t possibleOffset; possibleSize + 1 .. 16)
			if (offsetWords == possibleOffset && returnedWords == possibleSize) {
				pushOperationFn(writer, source, &opReturnData!(possibleOffset, possibleSize));
				return;
			}

	pushOperationFn(writer, source, &opReturnDataVariable);
	pushSizeT(writer, source, offsetWords);
	pushSizeT(writer, source, returnedWords);
}

void writeJump(scope ref ByteCodeWriter writer, ByteCodeSource source, ByteCodeIndex target) {
	pushOperationFn(writer, source, &opJump);
	// We take the jump after having read the jump value
	static assert(ByteCodeIndex.sizeof <= Operation.sizeof);
	pushInt64(writer, source, subtractByteCodeIndex(
		target,
		ByteCodeIndex(nextByteCodeIndex(writer).index + 1)).offset);
}

ByteCodeIndex writeJumpDelayed(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opJump);
	ByteCodeIndex jumpOffsetIndex = nextByteCodeIndex(writer);
	static assert(ByteCodeOffset.sizeof == long.sizeof);
	pushInt64(writer, source, 0);
	return jumpOffsetIndex;
}

@trusted void fillInJumpDelayed(scope ref ByteCodeWriter writer, ByteCodeIndex jumpIndex) {
	if (jumpIndex.index == nextByteCodeIndex(writer).index) {
		todo!void("!"); // I think this will work, but don't have code testing it yet
		// This happens for a 'break' at the bottom of a loop.
		// Just back up to remove the jump.
		Operation popped1 = popOperation(writer);
		assert(popped1.ulong_ == 0);
		Operation popped0 = popOperation(writer);
		assert(popped0.fn == &opJump);
	} else {
		ByteCodeOffset offset = getByteCodeOffsetForJumpToCurrent(writer, jumpIndex);
		writer.operations[jumpIndex.index] = Operation(offset.offset);
	}
}

private ByteCodeOffset getByteCodeOffsetForJumpToCurrent(in ByteCodeWriter writer, ByteCodeIndex jumpIndex) {
	assert(jumpIndex.index < nextByteCodeIndex(writer).index);
	static assert(ByteCodeIndex.sizeof <= Operation.sizeof);
	// We add the jump offset after having read the jump value
	ByteCodeIndex jumpEnd = addByteCodeIndex(jumpIndex, 1);
	return subtractByteCodeIndex(nextByteCodeIndex(writer), jumpEnd);
}

void writePack(scope ref ByteCodeWriter writer, ByteCodeSource source, in Pack pack) {
	pushOperationFn(writer, source, &opPack);
	pushSizeT(writer, source, pack.inEntries);
	pushSizeT(writer, source, pack.outEntries);
	writeArray(writer, source, pack.fields);
	writer.nextStackEntry -= pack.inEntries;
	writer.nextStackEntry += pack.outEntries;
}

immutable struct JumpIfFalseDelayed {
	ByteCodeIndex offsetIndex;
}

JumpIfFalseDelayed writeJumpIfFalseDelayed(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opJumpIfFalse);
	ByteCodeIndex offsetIndex = nextByteCodeIndex(writer);
	pushNat64(writer, source, 0);
	writer.nextStackEntry -= 1;
	return JumpIfFalseDelayed(offsetIndex);
}

@trusted void fillDelayedJumpIfFalse(scope ref ByteCodeWriter writer, JumpIfFalseDelayed delayed) {
	ByteCodeOffsetUnsigned diff =
		subtractByteCodeIndex(
			nextByteCodeIndex(writer),
			// + 1 because jump is relative to after reading the offset
			addByteCodeIndex(delayed.offsetIndex, 1),
		).unsigned();
	static assert(ByteCodeOffsetUnsigned.sizeof <= Operation.sizeof);
	writer.operations[delayed.offsetIndex.index] = Operation(diff.offset);
}

immutable struct SwitchDelayed {
	ByteCodeIndex firstCase;
	ByteCodeIndex afterCases;
}

SwitchDelayed writeSwitchDelay(
	scope ref ByteCodeWriter writer,
	ByteCodeSource source,
	in IntegralValues values,
	bool hasElse,
) {
	if (values.isRange0ToN)
		pushOperationFn(writer, source, hasElse ? &opSwitch0ToN!true : &opSwitch0ToN!false);
	else {
		pushOperationFn(writer, source, &opSwitchWithValues);
		writeArray(writer, source, values);
	}
	// + 1 because the array size takes up one entry
	ByteCodeIndex addresses = addByteCodeIndex(nextByteCodeIndex(writer), 1);
	writeArrayUninitialized!ByteCodeOffsetUnsigned(writer, source, values.length + hasElse);
	writer.nextStackEntry -= 1;
	return SwitchDelayed(addresses, nextByteCodeIndex(writer));
}

@trusted void fillDelayedSwitchEntry(scope ref ByteCodeWriter writer, SwitchDelayed delayed, size_t switchEntry) {
	ByteCodeOffsetUnsigned* start = cast(ByteCodeOffsetUnsigned*) &writer.operations[delayed.firstCase.index];
	ByteCodeOffsetUnsigned diff = subtractByteCodeIndex(nextByteCodeIndex(writer), delayed.afterCases).unsigned();
	overwriteMemory(start + switchEntry, diff);
}

void writeJumpToCatch(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opJumpToCatch);
	writer.nextStackEntry -= 1;
}

private @trusted void writeArray(T)(scope ref ByteCodeWriter writer, ByteCodeSource source, in T[] values) {
	T[] res = writeArrayUninitialized!T(writer, source, values.length);
	foreach (size_t i, T value; values)
		initMemory(&res[i], value);
}

private @trusted T[] writeArrayUninitialized(T)(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t size) {
	pushSizeT(writer, source, size);
	size_t nOperations = divRoundUp(size * T.sizeof, Operation.sizeof);
	foreach (size_t i; 0 .. nOperations)
		pushOperation(writer, source, Operation(ulong(0)));
	T[] res = (cast(T*) &writer.operations[mutArrSize(writer.operations) - nOperations])[0 .. size];
	assert(endPtr(res) <= cast(T*) mutArrEnd(writer.operations));
	return res;
}

void writeInterpreterBacktrace(scope ref ByteCodeWriter writer, ByteCodeSource source) {
	pushOperationFn(writer, source, &opInterpreterBacktrace);
	writer.nextStackEntry -= 2;
}

void writeFnBinary(scope ref ByteCodeWriter writer, ByteCodeSource source, Operation.Fn fn, bool returnVoid = false) {
	pushOperationFn(writer, source, fn);
	writer.nextStackEntry -= (returnVoid ? 2 : 1);
}

void writeFn4ary(scope ref ByteCodeWriter writer, ByteCodeSource source, Operation.Fn fn, bool returnVoid) {
	pushOperationFn(writer, source, fn);
	writer.nextStackEntry -= (returnVoid ? 4 : 3);
}

void writeFnUnary(scope ref ByteCodeWriter writer, ByteCodeSource source, Operation.Fn fn) {
	pushOperationFn(writer, source, fn);
}

private void pushOperation(scope ref ByteCodeWriter writer, ByteCodeSource source, Operation value) {
	push(*writer.alloc, writer.operations, value);
	add(*writer.alloc, writer.sources, source);
}

private Operation popOperation(scope ref ByteCodeWriter writer) {
	Operation res = mustPop(writer.operations);
	backUp(writer.sources);
	return res;
}

private void pushOperationFn(scope ref ByteCodeWriter writer, ByteCodeSource source, Operation.Fn fn) {
	pushOperation(writer, source, Operation(fn));
}

private void pushInt64(scope ref ByteCodeWriter writer, ByteCodeSource source, long value) {
	pushOperation(writer, source, Operation(value));
}

private void pushNat64(scope ref ByteCodeWriter writer, ByteCodeSource source, ulong value) {
	pushOperation(writer, source, Operation(value));
}

private void pushSizeT(scope ref ByteCodeWriter writer, ByteCodeSource source, size_t value) {
	pushNat64(writer, source, value);
}
