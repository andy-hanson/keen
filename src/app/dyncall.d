module app.dyncall;

@safe @nogc nothrow: // not pure

import interpret.bytecode : Operation;
import interpret.extern_ :
	AggregateCbs,
	DCaggr,
	DynCallSig,
	DynCallType,
	countParameterEntries,
	Extern,
	ExternPointer,
	ExternPointersForAllLibraries,
	ExternPointersForLibrary,
	FunPointer,
	FunPointerInputs,
	WriteError;
import interpret.runBytecode : syntheticCall;
import interpret.stacks : dataPop, dataPopN, dataPush, dataPushUninitialized, loadStacks, saveStacks, Stacks;
import model.lowModel : ExternLibraries, ExternLibrary, PrimitiveType;
import model.model : BuiltinExtern;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withExactStackArray;
import util.col.array : isEmpty, map, mapImpure;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish;
import util.col.map : Map, KeyValuePair, makeMapFromKeys, zipToMap;
import util.col.mapBuilder : MapBuilder, finishMap, tryAddToMap;
import util.col.mutArr : MutArr, mutArrIsEmpty, push;
import util.conv : bitsOfFloat32, bitsOfFloat64, bitsOfInt, bitsOfLong, float32OfBits, float64OfBits;
import util.exitCode : ExitCodeOrSignal;
import util.late : Late, late, lateGet, lateSet;
import util.memory : allocate;
import util.opt : force, has, Opt, none, some;
import util.string : CString, cString;
import util.symbol : addExtension, addPrefixAndExtension, Extension, Symbol, symbolOfEnum;
import util.uri : asFilePath, Uri, uriIsFile, withCStringOfFilePath;
import util.writer : withStackWriterCString, withStackWriterImpure, withStackWriterImpureCString, Writer;

@trusted ExitCodeOrSignal withRealExtern(
	ref Alloc alloc,
	in ExitCodeOrSignal delegate(scope ref Extern) @safe @nogc nothrow cb,
) {
	Late!DebugNames debugNames = late!DebugNames;
	scope Extern extern_ = Extern(
		(in ExternLibraries libraries, scope WriteError writeError) {
			LoadedLibraries res = loadLibraries(alloc, libraries, writeError);
			lateSet(debugNames, res.debugNames);
			return res.funPointers;
		},
		(in FunPointerInputs[] inputs) =>
			makeSyntheticFunPointers(alloc, inputs),
		AggregateCbs(&newAggregate, &aggregateAddField, (DCaggr* x) { dcCloseAggr(x); }),
		(FunPointer funPointer, in DynCallSig sig) =>
			dynamicCallFunPointer(funPointer, lateGet(debugNames)[funPointer.asExternPointer], sig));
	return cb(extern_);
}

private:

alias DebugNames = Map!(ExternPointer, Symbol);

immutable struct LoadedLibraries {
	DebugNames debugNames;
	Opt!ExternPointersForAllLibraries funPointers;
}

LoadedLibraries loadLibraries(ref Alloc alloc, in ExternLibraries libraries, in WriteError writeError) {
	bool success = true;
	immutable DLLib*[] libs = mapImpure!(immutable DLLib*, ExternLibrary)(alloc, libraries, (in ExternLibrary x) {
		LibraryAndError lib = getLibrary(x.libraryName, x.configuredDir, writeError);
		if (lib.error) success = false;
		return lib.library;
	});
	return success
		? loadLibrariesInner(alloc, libraries, libs, writeError)
		: LoadedLibraries(DebugNames(), none!ExternPointersForAllLibraries);
}

// Can't use Opt since 'null' is sometimes allowed as the library
immutable struct LibraryAndError {
	DLLib* library;
	bool error;
}

LibraryAndError getLibrary(Symbol libraryName, Opt!Uri configuredDir, in WriteError writeError) {
	Symbol fileName = dllOrSoName(libraryName);
	Opt!(DLLib*) fromUri = has(configuredDir)
		? tryLoadLibraryFromUri(force(configuredDir) / fileName)
		: none!(DLLib*);
	if (has(fromUri))
		return LibraryAndError(force(fromUri), false);
	else {
		switch (libraryName.value) {
			case symbolOfEnum(BuiltinExtern.libc).value:
			case symbolOfEnum(BuiltinExtern.linux).value:
			case symbolOfEnum(BuiltinExtern.posix).value:
				version (Windows) {
					return loadLibraryFromName(cString!"ucrtbase.dll", writeError);
				} else {
					return LibraryAndError(null, false);
				}
			case symbolOfEnum(BuiltinExtern.pthread).value:
				// TODO: understand why this is different
				return loadLibraryFromName(cString!"libpthread.so.0", writeError);
			case symbolOfEnum(BuiltinExtern.windows).value:
				return loadLibraryFromName(cString!"kernel32.dll", writeError);
			default:
				return loadLibraryFromName(fileName, writeError);
		}
	}
}

Symbol dllOrSoName(immutable Symbol libraryName) {
	version (Windows)
		return addExtension(libraryName, Extension.dll);
	else
		return addPrefixAndExtension("lib", libraryName, ".so");
}

@trusted Opt!(DLLib*) tryLoadLibraryFromUri(Uri uri) {
	if (uriIsFile(uri)) {
		DLLib* res = withCStringOfFilePath!(DLLib*)(asFilePath(uri), (in CString file) =>
			dlLoadLibrary(file.ptr));
		return res == null ? none!(DLLib*) : some(res);
	} else
		return none!(DLLib*);
}

LibraryAndError loadLibraryFromName(Symbol name, in WriteError writeError) =>
	withCStringOfSymbolImpure(name, (in CString nameStr) => loadLibraryFromName(nameStr, writeError));

T withCStringOfSymbol(T)(Symbol a, in T delegate(in CString) @safe @nogc pure nothrow cb) =>
	withStackWriterCString((scope ref Writer writer) { writer ~= a; }, cb);
T withCStringOfSymbolImpure(T)(Symbol a, in T delegate(in CString) @safe @nogc nothrow cb) =>
	withStackWriterImpureCString((scope ref Writer writer) { writer ~= a; }, cb);

LibraryAndError loadLibraryFromName(in CString name, in WriteError writeError) {
	DLLib* res = dlLoadLibrary(name.ptr);
	if (res == null) {
		// TODO: use a Diagnostic
		withStackWriterImpure!void((scope ref Writer writer) {
			writer ~= "Could not load library ";
			writer ~= name;
		}, writeError);
	}
	return LibraryAndError(res, res == null);
}

LoadedLibraries loadLibrariesInner(
	ref Alloc alloc,
	in ExternLibraries libraries,
	immutable DLLib*[] libs,
	in WriteError writeError,
) {
	MapBuilder!(ExternPointer, Symbol) debugNames;
	MutArr!(KeyValuePair!(Symbol, Symbol)) failures;
	ExternPointersForAllLibraries res = zipToMap!(Symbol, Map!(Symbol, ExternPointer), ExternLibrary, DLLib*)(
		alloc,
		libraries,
		libs,
		(ref ExternLibrary x, ref DLLib* lib) {
			ExternPointersForLibrary pointers = makeMapFromKeys!(Symbol, ExternPointer)(
				alloc,
				x.importNames,
				(Symbol importName) {
					Opt!ExternPointer p = getExternPointer(lib, importName);
					if (has(p)) {
						// sometimes two names refer to the same function -- just go with the first name
						tryAddToMap!(ExternPointer, Symbol)(alloc, debugNames, force(p), importName);
						return force(p);
					} else {
						push(alloc, failures, KeyValuePair!(Symbol, Symbol)(x.libraryName, importName));
						return ExternPointer(null);
					}
				});
			return immutable KeyValuePair!(Symbol, ExternPointersForLibrary)(x.libraryName, pointers);
		});
	foreach (KeyValuePair!(Symbol, Symbol) x; failures)
		withStackWriterImpure((scope ref Writer writer) {
			writer ~= "Could not load extern function ";
			writer ~= x.value;
			writer ~= " from library ";
			writer ~= x.key;
		}, writeError);
	return LoadedLibraries(
		finishMap(alloc, debugNames),
		mutArrIsEmpty(failures) ? some(res) : none!ExternPointersForAllLibraries);
}

pure Opt!ExternPointer getExternPointer(DLLib* library, Symbol name) =>
	withCStringOfSymbol!(Opt!ExternPointer)(name, (in CString nameStr) @trusted {
		DCpointer ptr = dlFindSymbol(library, nameStr.ptr);
		return ptr == null ? none!ExternPointer : some(ExternPointer(cast(immutable) ptr));
	});

@system void dynamicCallFunPointer(FunPointer fun, Opt!Symbol debugName, in DynCallSig sig) {
	static DCCallVM* dcVm = null;
	if (dcVm == null) {
		// first time an extern function called on this thread
		// TODO: dyncall doesn't seem to have any internal checking,
		// so overflowing this just leads to wierd behavior.
		// (this happens if you call a native function that calls back into crow,
		// which calls another native function, etc, growing the dyncall stack indefinitely.)
		// TODO: manually track the stack size and abort on failure
		dcVm = dcNewCallVM(0x1000);
		assert(dcVm != null);
		dcMode(dcVm, DC_CALL_C_DEFAULT);
	}

	DCpointer ptr = cast(DCpointer) fun.pointer;
	dcReset(dcVm);

	if (sig.returnType.isA!(DynCallType.Aggregate*))
		dcBeginCallAggr(dcVm, sig.returnType.as!(DynCallType.Aggregate*).dcAggr);
	Stacks stacks = loadStacks();
	scope const(ulong)[] args = dataPopN(stacks, countParameterEntries(sig));
	foreach (DynCallType type; sig.parameterTypes)
		addArgForDynCall(dcVm, args, type);
	assert(isEmpty(args));
	doDynCallForType(dcVm, ptr, sig.returnType, stacks);
	dcReset(dcVm);
	saveStacks(stacks);
}

@system void addArgForDynCall(DCCallVM* dcVm, scope ref const(ulong)[] args, DynCallType parameterType) {
	parameterType.matchImpure!void(
		(in PrimitiveType x) @trusted {
			ulong value = args[0];
			args = args[1 .. $];
			final switch (x) {
				case PrimitiveType.bool_:
					dcArgBool(dcVm, cast(bool) value);
					break;
				case PrimitiveType.char8:
				case PrimitiveType.int8:
				case PrimitiveType.nat8:
					dcArgChar(dcVm, cast(char) value);
					break;
				case PrimitiveType.int16:
				case PrimitiveType.nat16:
					dcArgShort(dcVm, cast(short) value);
					break;
				case PrimitiveType.char32:
				case PrimitiveType.int32:
				case PrimitiveType.nat32:
					dcArgInt(dcVm, cast(int) value);
					break;
				case PrimitiveType.int64:
				case PrimitiveType.nat64:
					dcArgLongLong(dcVm, value);
					break;
				case PrimitiveType.float32:
					dcArgFloat(dcVm, float32OfBits(cast(uint) value));
					break;
				case PrimitiveType.float64:
					dcArgDouble(dcVm, float64OfBits(value));
					break;
				case PrimitiveType.void_:
					assert(false);
			}
		},
		(in DynCallType.Pointer) @trusted {
			dcArgPointer(dcVm, cast(void*) args[0]);
			args = args[1 .. $];
		},
		(in DynCallType.Aggregate x) @trusted {
			dcArgAggr(dcVm, x.dcAggr, args.ptr);
			args = args[x.sizeWords .. $];
		});
}

@system void doDynCallForType(DCCallVM* dcVm, DCpointer ptr, DynCallType returnType, scope ref Stacks stacks) {
	returnType.matchImpure!void(
		(in PrimitiveType x) @trusted {
			dcCallPrimitive(dcVm, ptr, x, stacks);
		},
		(in DynCallType.Pointer) @trusted {
			dataPush(stacks, cast(ulong) dcCallPointer(dcVm, ptr));
		},
		(in DynCallType.Aggregate x) @trusted {
			ulong* out_ = dataPushUninitialized(stacks, x.sizeWords);
			DCpointer ret = dcCallAggr(dcVm, ptr, x.dcAggr, out_);
			assert(ret == out_);
		});
}

@system void dcCallPrimitive(DCCallVM* dcVm, DCpointer ptr, PrimitiveType type, scope ref Stacks stacks) {
	final switch (type) {
		case PrimitiveType.bool_:
			return dataPush(stacks, dcCallBool(dcVm, ptr));
		case PrimitiveType.char8:
		case PrimitiveType.int8:
		case PrimitiveType.nat8:
			return dataPush(stacks, dcCallChar(dcVm, ptr));
		case PrimitiveType.int16:
		case PrimitiveType.nat16:
			return dataPush(stacks, dcCallShort(dcVm, ptr));
		case PrimitiveType.char32:
		case PrimitiveType.int32:
		case PrimitiveType.nat32:
			return dataPush(stacks, bitsOfInt(dcCallInt(dcVm, ptr)));
		case PrimitiveType.int64:
		case PrimitiveType.nat64:
			return dataPush(stacks, bitsOfLong(dcCallLongLong(dcVm, ptr)));
		case PrimitiveType.float32:
			return dataPush(stacks, bitsOfFloat32(dcCallFloat(dcVm, ptr)));
		case PrimitiveType.float64:
			return dataPush(stacks, bitsOfFloat64(dcCallDouble(dcVm, ptr)));
		case PrimitiveType.void_:
			return dcCallVoid(dcVm, ptr);
	}
}

immutable struct UserData {
	DynCallSig sig;
	Operation* operationPtr;
}

pure FunPointer[] makeSyntheticFunPointers(ref Alloc alloc, in FunPointerInputs[] inputs) =>
	map(alloc, inputs, (ref FunPointerInputs x) =>
		syntheticFunPointerForSig(alloc, x.sig, x.operationPtr));

pure FunPointer syntheticFunPointerForSig(ref Alloc alloc, DynCallSig sig, Operation* operationPtr) =>
	withExactStackArray!(FunPointer, char)(
		sig.returnTypeAndParameterTypes.length + ")\0".length,
		(scope ref ExactSizeArrayBuilder!char sigStr) @trusted {
			// Apparently the 'sig' can be temporary, but this can't.
			immutable DCaggr*[] aggrs = buildArray(alloc, (scope ref Builder!(immutable DCaggr*) aggrsOut) {
				void writeToSig(DynCallType x) {
					sigStr ~= dynCallSigChar(x);
					if (x.isA!(DynCallType.Aggregate*))
						aggrsOut ~= x.as!(DynCallType.Aggregate*).dcAggr;
				}

				foreach (DynCallType x; sig.parameterTypes)
					writeToSig(x);
				sigStr ~= ')';
				writeToSig(sig.returnType);
				sigStr ~= '\0';
			});
			UserData* userData = allocate(alloc, UserData(sig, operationPtr));
			return FunPointer(
				dcbNewCallback2(finish(sigStr).ptr, &callbackHandler, cast(void*) userData, aggrs.ptr));
		});

@system extern(C) char callbackHandler(DCCallback* cb, DCArgs* args, DCValue* result, void* userDataPtr) {
	UserData userData = *(cast(UserData*) userDataPtr);
	DynCallSig sig = userData.sig;
	syntheticCall(
		userData.operationPtr,
		(scope ref Stacks stacks) {
			foreach (DynCallType argType; sig.parameterTypes)
				dyncallGetArg(args, argType, stacks);
		},
		(scope ref Stacks stacks) {
			dyncallSetResult(args, result, sig.returnType, stacks);
		});
	return dynCallSigChar(sig.returnType);
}

pure int safeToInt(size_t a) {
	assert(a < int.max);
	return cast(int) a;
}

pure char dynCallSigChar(in DynCallType a) =>
	a.matchIn!char(
		(in PrimitiveType x) {
			final switch (x) {
				case PrimitiveType.bool_:
					return 'B';
				case PrimitiveType.char8:
				case PrimitiveType.int8:
					return 'c';
				case PrimitiveType.int16:
					return 's';
				case PrimitiveType.char32:
				case PrimitiveType.int32:
					return 'i';
				case PrimitiveType.int64:
					return 'l';
				case PrimitiveType.float32:
					return 'f';
				case PrimitiveType.float64:
					return 'd';
				case PrimitiveType.nat8:
					return 'C';
				case PrimitiveType.nat16:
					return 'S';
				case PrimitiveType.nat32:
					return 'I';
				case PrimitiveType.nat64:
					return 'L';
				case PrimitiveType.void_:
					return 'v';
			}
		},
		(in DynCallType.Pointer) =>
			'p',
		(in DynCallType.Aggregate) =>
			// Aggregate is sent out-of-band in 'dcArgAggr' or 'dcCallAggr'
			'A');

@system void dyncallGetArg(DCArgs* args, DynCallType type, scope ref Stacks stacks) =>
	type.matchImpure!void(
		(in PrimitiveType x) @trusted {
			final switch (x) {
				case PrimitiveType.bool_:
					return dataPush(stacks, dcbArgBool(args));
				case PrimitiveType.char8:
				case PrimitiveType.int8:
					return dataPush(stacks, dcbArgChar(args));
				case PrimitiveType.int16:
					return dataPush(stacks, dcbArgShort(args));
				case PrimitiveType.char32:
				case PrimitiveType.int32:
					return dataPush(stacks, dcbArgInt(args));
				case PrimitiveType.int64:
					return dataPush(stacks, dcbArgLongLong(args));
				case PrimitiveType.float32:
					return dataPush(stacks, bitsOfFloat32(dcbArgFloat(args)));
				case PrimitiveType.float64:
					return dataPush(stacks, bitsOfFloat64(dcbArgDouble(args)));
				case PrimitiveType.nat8:
					return dataPush(stacks, dcbArgUChar(args));
				case PrimitiveType.nat16:
					return dataPush(stacks, dcbArgUShort(args));
				case PrimitiveType.nat32:
					return dataPush(stacks, dcbArgUInt(args));
				case PrimitiveType.nat64:
					return dataPush(stacks, dcbArgULongLong(args));
				case PrimitiveType.void_:
					assert(false);
			}
		},
		(in DynCallType.Pointer) @trusted {
			dataPush(stacks, cast(ulong) dcbArgPointer(args));
		},
		(in DynCallType.Aggregate x) @trusted {
			ulong* ptr = dataPushUninitialized(stacks, x.sizeWords);
			void* out_ = dcbArgAggr(args, ptr);
			assert(out_ == ptr);
		});

@system void dyncallSetResult(DCArgs* args, DCValue* result, DynCallType type, scope ref Stacks stacks) {
	type.matchImpure!void(
		(in PrimitiveType x) @trusted {
			final switch (x) {
				case PrimitiveType.bool_:
					result.B = cast(bool) dataPop(stacks);
					break;
				case PrimitiveType.char8:
				case PrimitiveType.int8:
					result.c = cast(char) dataPop(stacks);
					break;
				case PrimitiveType.int16:
					result.s = cast(short) dataPop(stacks);
					break;
				case PrimitiveType.char32:
				case PrimitiveType.int32:
					result.i = cast(int) dataPop(stacks);
					break;
				case PrimitiveType.int64:
					result.l = cast(long) dataPop(stacks);
					break;
				case PrimitiveType.float32:
					result.f = float32OfBits(dataPop(stacks));
					break;
				case PrimitiveType.float64:
					result.d = float64OfBits(dataPop(stacks));
					break;
				case PrimitiveType.nat8:
					result.C = cast(ubyte) dataPop(stacks);
					break;
				case PrimitiveType.nat16:
					result.S = cast(ushort) dataPop(stacks);
					break;
				case PrimitiveType.nat32:
					result.I = cast(uint) dataPop(stacks);
					break;
				case PrimitiveType.nat64:
					result.L = dataPop(stacks);
					break;
				case PrimitiveType.void_:
					break;
			}
		},
		(in DynCallType.Pointer) @trusted {
			result.p = cast(void*) dataPop(stacks);
		},
		(in DynCallType.Aggregate x) @trusted {
			dcbReturnAggr(args, result, cast(void*) dataPopN(stacks, x.sizeWords).ptr);
		});
}

@system pure DCaggr* newAggregate(size_t countFields, size_t sizeBytes) =>
	dcNewAggr(countFields, sizeBytes);

@system pure void aggregateAddField(DCaggr* aggr, size_t fieldOffset, DynCallType fieldType) {
	assert(!fieldType.isA!(DynCallType.Aggregate*));
	dcAggrField(aggr, dynCallSigChar(fieldType), safeToInt(fieldOffset), 1);
}

extern(C) {
	@system:

	// dyncall_types.h
	//alias DCvoid = void;
	alias DCbool = int;
	alias DCchar = byte;
	alias DCuchar = ubyte;
	alias DCshort = short;
	alias DCushort = ushort;
	alias DCint = int;
	alias DCuint = uint;
	// Depends on the system?
	// alias DClong = long;
	// alias DCulong = ulong;
	alias DClonglong = long;
	alias DCulonglong = ulong;
	alias DCfloat = float;
	alias DCdouble = double;
	alias DCpointer = void*;
	alias DCstring = const char*;
	alias DCsize = size_t;

	// dyncall_args.h
	struct DCArgs;
	DCbool dcbArgBool(DCArgs*);
	DCchar dcbArgChar(DCArgs*);
	DCshort dcbArgShort(DCArgs*);
	DCint dcbArgInt(DCArgs*);
	// pure DClong dcbArgLong(DCArgs*);
	DClonglong dcbArgLongLong(DCArgs*);
	DCuchar dcbArgUChar(DCArgs*);
	DCushort dcbArgUShort(DCArgs*);
	DCuint dcbArgUInt(DCArgs*);
	// pure DCulong dcbArgULong(DCArgs*);
	DCulonglong dcbArgULongLong(DCArgs*);
	DCfloat dcbArgFloat(DCArgs*);
	DCdouble dcbArgDouble(DCArgs*);
	DCpointer dcbArgPointer(DCArgs*);
	DCpointer dcbArgAggr(DCArgs* p, DCpointer target);

	void dcbReturnAggr(DCArgs *args, DCValue* result, DCpointer ret);

	// dyncall_callback.h
	struct DCCallback;
	alias DCCallbackHandler = char function(DCCallback* pcb, DCArgs* args, DCValue* result, void* userdata);
	pure DCCallback* dcbNewCallback2(
		scope const char* signature,
		DCCallbackHandler funcptr,
		void* userdata,
		const DCaggr** aggrs);

	// dyncall_value.h
	union DCValue {
		// TODO: big-endian architectures are different
		DCbool B;
		DCchar c;
		DCuchar C;
		DCshort s;
		DCushort S;
		DCint i;
		DCuint I;
		//DClong j;
		//DCulong J;
		DClonglong l;
		DCulonglong L;
		DCfloat f;
		DCdouble d;
		DCpointer p;
		//DCstring Z;
	}

	// dyncall.h
	struct DCCallVM;

	enum DC_CALL_C_DEFAULT = 0;

	DCCallVM* dcNewCallVM(DCsize size);
	void dcReset(DCCallVM* vm);

	void dcMode(DCCallVM* vm, DCint mode);

	void dcBeginCallAggr(DCCallVM* vm, const DCaggr* ag);

	void dcArgBool(DCCallVM* vm, DCbool value);
	void dcArgChar(DCCallVM* vm, DCchar value);
	void dcArgShort(DCCallVM* vm, DCshort value);
	void dcArgInt(DCCallVM* vm, DCint value);
	//void dcArgLong(DCCallVM* vm, DClong value);
	void dcArgLongLong(DCCallVM* vm, DClonglong value);
	void dcArgFloat(DCCallVM* vm, DCfloat value);
	void dcArgDouble(DCCallVM* vm, DCdouble value);
	void dcArgPointer(DCCallVM* vm, DCpointer value);
	void dcArgAggr(DCCallVM* vm, const DCaggr* ag, const void* value);

	void dcCallVoid(DCCallVM* vm, DCpointer funcptr);
	DCbool dcCallBool(DCCallVM* vm, DCpointer funcptr);
	DCchar dcCallChar(DCCallVM* vm, DCpointer funcptr);
	DCshort dcCallShort(DCCallVM* vm, DCpointer funcptr);
	DCint dcCallInt(DCCallVM* vm, DCpointer funcptr);
	//DClong dcCallLong (DCCallVM* vm, DCpointer funcptr);
	DClonglong dcCallLongLong(DCCallVM* vm, DCpointer funcptr);
	DCfloat dcCallFloat(DCCallVM* vm, DCpointer funcptr);
	DCdouble dcCallDouble(DCCallVM* vm, DCpointer funcptr);
	DCpointer dcCallPointer(DCCallVM* vm, DCpointer funcptr);
	DCpointer dcCallAggr(DCCallVM* vm, DCpointer funcptr, const DCaggr* ag, DCpointer ret);

	//DCint dcGetError (DCCallVM* vm);

	alias DCsigchar = char;

	pure DCaggr* dcNewAggr(DCsize maxFieldCount, DCsize size);
	pure void dcAggrField(DCaggr* ag, DCsigchar type, DCint offset, DCsize array_len, ...);
	pure void dcCloseAggr(DCaggr* ag);
	//void dcFreeAggr(DCaggr* ag);
}

extern(C) {
	// based on dyncall/dynload/dynload.h
	immutable struct DLLib;
	DLLib* dlLoadLibrary(scope const char* libpath);
	pure void* dlFindSymbol(DLLib* pLib, scope const char* pSymbolName);
}
