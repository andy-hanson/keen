module interpret.fakeExtern;

@safe @nogc nothrow: // not pure

version (WebAssembly) {} else {
	import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC, timespec;
}

import lib.lsp.lspTypes : Pipe;
import interpret.bytecode : Operation;
import interpret.extern_ :
	AggregateCbs,
	countParameterEntries,
	DCaggr,
	DynCallSig,
	DynCallType,
	Extern,
	ExternPointer,
	ExternPointersForAllLibraries,
	ExternPointersForLibrary,
	FunPointer,
	FunPointerInputs,
	WriteError;
import interpret.runBytecode : debugLogInterpreterBacktrace, syntheticCallWithStacks;
import interpret.stacks : dataPopN, dataPush, loadStacks, saveStacks, Stacks;
import model.lowModel : ExternLibraries, ExternLibrary;
import util.alloc.alloc : Alloc, allocateBytes, allocateZeroedBytes;
import util.col.array : map;
import util.col.map : KeyValuePair, makeMap;
import util.col.mutArr : MutArr, mutArrIsEmpty, push;
import util.conv : safeMul;
import util.memory : memmove, memset;
import util.opt : has, none, Opt, optOrDefault, some;
import util.symbol : Symbol, symbol;
import util.util : debugLog, todo;
import util.writer : withStackWriterImpure, Writer;
version (WebAssembly) {
	import util.wasm : getTimeNanos;
}

alias WriteCb = void delegate(Pipe, in string) @safe @nogc nothrow;

WriteCb unreachableWriteCb() =>
	(Pipe _, in string _1) => assert(false);

T withFakeExtern(T)(ref Alloc alloc, in WriteCb write, in T delegate(scope ref Extern) @safe @nogc nothrow cb) {
	scope Extern extern_ = Extern(
		(in ExternLibraries libraries, scope WriteError writeError) =>
			getAllFakeExternFuns(alloc, libraries, writeError),
		(in FunPointerInputs[] inputs) =>
			fakeSyntheticFunPointers(alloc, inputs),
		AggregateCbs(
			(size_t _, size_t _2) =>
				null,
			(DCaggr* aggr, size_t _, DynCallType _2) {
				assert(aggr == null);
			},
			(DCaggr* aggr) {
				assert(aggr == null);
			}),
		(FunPointer fun, in DynCallSig sig) =>
			callFakeExternFun(alloc, write, fun.pointer, sig));
	return cb(extern_);
}

pure FunPointer[] fakeSyntheticFunPointers(ref Alloc alloc, in FunPointerInputs[] inputs) =>
	map(alloc, inputs, (ref FunPointerInputs x) =>
		FunPointer(x.operationPtr));

private:

Opt!ExternPointersForAllLibraries getAllFakeExternFuns(
	ref Alloc alloc,
	in ExternLibraries libraries,
	scope WriteError writeError,
) {
	MutArr!(immutable KeyValuePair!(Symbol, Symbol)) failures;
	ExternPointersForAllLibraries res = makeMap!(Symbol, ExternPointersForLibrary, ExternLibrary)(
		alloc, libraries, (in ExternLibrary x) =>
			immutable KeyValuePair!(Symbol, ExternPointersForLibrary)(
				x.libraryName,
				fakeExternFunsForLibrary(alloc, failures, x)));
	foreach (immutable KeyValuePair!(Symbol, Symbol) x; failures)
		withStackWriterImpure((scope ref Writer writer) {
			writer ~= "Could not load extern function ";
			writer ~= x.value;
			writer ~= " from library ";
			writer ~= x.key;
		}, writeError);
	return mutArrIsEmpty(failures) ? some(res) : none!ExternPointersForAllLibraries;
}

@system void callFakeExternFun(
	ref Alloc alloc,
	in WriteCb writeCb,
	immutable void* ptr,
	in DynCallSig sig,
) {
	Stacks stacks = loadStacks();
	scope const(ulong)[] args = dataPopN(stacks, countParameterEntries(sig));
	if (ptr == &abort) {
		debugLogInterpreterBacktrace(stacks);
		abort();
	} else if (ptr == &calloc) {
		assert(args.length == 2);
		size_t nElems = cast(size_t) args[0];
		size_t sizeofElem = cast(size_t) args[1];
		dataPush(stacks, cast(ulong) allocateZeroedBytes(alloc, safeMul(nElems, sizeofElem)).ptr);
	} else if (ptr == &fakeMonotimeNsec) {
		assert(args.length == 0);
		dataPush(stacks, fakeMonotimeNsec());
	} else if (ptr == &free) {
		assert(args.length == 1);
	} else if (ptr == &malloc) {
		assert(args.length == 1);
		dataPush(stacks, cast(ulong) allocateBytes(alloc, cast(size_t) args[0]).ptr);
	} else if (ptr == &memmove) {
		assert(args.length == 3);
		dataPush(stacks, cast(ulong) memmove(cast(ubyte*) args[0], cast(const ubyte*) args[1], cast(size_t) args[2]));
	} else if (ptr == &memset) {
		assert(args.length == 3);
		dataPush(stacks, cast(ulong) memset(cast(ubyte*) args[0], cast(ubyte) args[1], cast(size_t) args[2]));
	} else if (ptr == &writeFake) {
		assert(args.length == 3);
		int fd = cast(int) args[0];
		immutable char* buf = cast(immutable char*) args[1];
		size_t nBytes = cast(size_t) args[2];
		assert(fd == 1 || fd == 2);
		Pipe pipe = fd == 1 ? Pipe.stdout : Pipe.stderr;
		writeCb(pipe, buf[0 .. nBytes]);
	} else {
		dataPush(stacks, args);
		syntheticCallWithStacks(stacks, cast(Operation*) ptr);
		// Result remains on stack
	}
	saveStacks(stacks);
}

@system ulong fakeMonotimeNsec() {
	version (WebAssembly) {
		return getTimeNanos();
	} else {
		timespec time;
		int err = clock_gettime(CLOCK_MONOTONIC, &time);
		assert(err == 0);
		return time.tv_sec * 1_000_000_000 + time.tv_nsec;
	}
}

pure:

ExternPointersForLibrary fakeExternFunsForLibrary(
	ref Alloc alloc,
	ref MutArr!(immutable KeyValuePair!(Symbol, Symbol)) failures,
	in ExternLibrary lib,
) =>
	makeMap!(Symbol, ExternPointer, Symbol)(alloc, lib.importNames, (in Symbol importName) {
		Opt!FunPointer res = getFakeExternFun(lib.libraryName, importName);
		if (!has(res))
			push(alloc, failures, KeyValuePair!(Symbol, Symbol)(lib.libraryName, importName));
		return immutable KeyValuePair!(Symbol, ExternPointer)(
			importName,
			optOrDefault!FunPointer(res, () => FunPointer(null)).asExternPointer());
	});

Opt!FunPointer getFakeExternFun(Symbol libraryName, Symbol name) {
	if (libraryName != symbol!"posix" && libraryName != symbol!"libc" && libraryName != symbol!"fake")
		return none!FunPointer;
	switch (name.value) {
		case symbol!"abort".value:
			return some(FunPointer(&abort));
		case symbol!"calloc".value:
			return some(FunPointer(&calloc));
		case symbol!"fake-monotime-nsec".value:
			return some(FunPointer(&fakeMonotimeNsec));
		case symbol!"free".value:
			return some(FunPointer(&free));
		case symbol!"nanosleep".value:
			return some(FunPointer(&nanosleep));
		case symbol!"malloc".value:
			return some(FunPointer(&malloc));
		case symbol!"memcpy".value: // TODO: maybe these should be compiler intrinsics instead (and have a nicer interface)
		case symbol!"memmove".value:
			return some(FunPointer(&memmove));
		case symbol!"memset".value:
			return some(FunPointer(&memset));
		case symbol!"write-fake".value:
			return some(FunPointer(&writeFake));
		default:
			return none!FunPointer;
	}
}

// Just used as fake funtion pointers, actual implementation in callFakeExternFun
void free() { assert(false); }
void calloc() { assert(false); }
void malloc() { assert(false); }
void writeFake() { assert(false); }

void abort() {
	debugLog("program aborted");
	assert(false);
}

int nanosleep(const(void*), void*) =>
	todo!int("!");
