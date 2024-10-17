module util.wasm;

@safe @nogc nothrow: // not pure

version (WebAssembly) {
	// Not really pure, but JS doesn't know that
	extern(C) pure ulong getTimeNanos();
	extern(C) void perfLogMeasure(scope immutable char* name, uint count, ulong nanoseconds, uint bytesAllocated);
	extern(C) void perfLogFinish(scope immutable char* name, ulong totalNanoseconds);
}
