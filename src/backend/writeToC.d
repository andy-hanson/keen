module backend.writeToC;

@safe @nogc pure nothrow:

import backend.mangle :
	buildMangledNames,
	MangledNames,
	writeConstantArrStorageName,
	writeConstantPointerStorageName,
	writeLowFunMangledName,
	writeLowLocalName,
	writeLowVarMangledName,
	writeMangledName,
	writeStructMangledName;
import backend.builtinMath : builtinForBinaryMath, builtinForUnaryMath;
import backend.writeTypes : TypeWriters, writeTypes;
import frontend.lang : CCompileOptions, CVersion, OptimizationLevel;
import frontend.showModel : ShowCtx;
import model.concreteModel : ConcreteStruct, ConcreteStructBody, isEmptyStruct;
import model.constant : Constant;
import model.lowModel :
	AbortLowExpr,
	AllConstantsLow,
	ArrTypeAndConstantsLow,
	asGcPointee,
	CallFunPointerLowExpr,
	CallLowExpr,
	CreateRecordLowExpr,
	CreateUnionLowExpr,
	debugName,
	ExternLibraries,
	ExternLibrary,
	FunPointerLowExpr,
	IfLowExpr,
	InitLowExpr,
	isChar8,
	isChar32,
	isPointerNonGc,
	LetLowExpr,
	LocalGetLowExpr,
	localMustBeVolatile,
	LocalPointerLowExpr,
	LocalSetLowExpr,
	LoopBreakLowExpr,
	LoopContinueLowExpr,
	LoopLowExpr,
	LowExpr,
	LowExternType,
	LowField,
	LowFun,
	LowFunBody,
	LowFunExprBody,
	LowFunIndex,
	LowFunPointerType,
	LowFunPointerTypeIndex,
	LowLocal,
	LowPointerCombine,
	LowProgram,
	LowRecord,
	LowRecordIndex,
	LowVar,
	LowVarIndex,
	LowType,
	LowUnion,
	LowUnionIndex,
	PointerCastLowExpr,
	PointerTypeAndConstantsLow,
	PrimitiveType,
	RecordFieldGetLowExpr,
	RecordFieldPointerLowExpr,
	RecordFieldSetLowExpr,
	Special4aryLowExpr,
	SpecialBinaryLowExpr,
	SpecialBinaryMathLowExpr,
	SpecialTernaryLowExpr,
	SpecialUnaryLowExpr,
	SpecialUnaryMathLowExpr,
	SwitchLowExpr,
	TailRecurLowExpr,
	UnionAsLowExpr,
	UnionKindLowExpr,
	UpdateParam,
	VarGetLowExpr,
	VarSetLowExpr;
import model.model : Builtin4ary, BuiltinBinary, BuiltinFunInitKind, BuiltinTernary, BuiltinUnary, isLambda, TypeSize;
import model.showLowModel : writeFunSig;
import model.typeLayout : sizeOfType, typeSizeBytes;
import util.alloc.alloc : Alloc, TempAlloc;
import util.col.array : contains, every, exists, isEmpty, map, only, sizeEq, zip;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.map : mustGet;
import util.col.fullIndexMap : FullIndexMap, fullIndexMapEach;
import util.conv : safeToUint;
import util.integralValues : IntegralValue;
import util.opt : force, has, none, Opt, some;
import util.string : CString, cString, cStringSize, stringOfCString;
import util.symbol : addExtension, cStringOfSymbol, Extension, Symbol, symbol;
import util.unicode : isValidUnicodeCharacter, mustUnicodeDecode;
import util.union_ : Union;
import util.uri : asFilePath, cStringOfFilePath, FilePath, uriIsFile;
import util.util : abs, castImmutable, castNonScope, castNonScope_ref, ptrTrustMe, stringOfEnum, todo;
import util.writer :
	makeStringWithWriter,
	withWriter,
	writeEscapedChar_inner,
	writeFloatLiteralForC,
	writeNewline,
	writeQuotedString,
	Writer,
	writeWithCommas,
	writeWithCommasZip,
	writeWithSpaces;
import versionInfo : OS;

private immutable string boilerplatePosix = import("writeToC_boilerplate_posix.c");
private immutable string boilerplateMsvc = import("writeToC_boilerplate_msvc.c");

immutable struct PathAndArgs {
	FilePath path;
	CString[] args;
}

immutable struct WriteToCResult {
	PathAndArgs compileCommand;
	string cSource;
}

immutable struct WriteToCParams {
	FilePath cCompiler;
	FilePath cPath;
	FilePath exePath;
	CCompileOptions compileOptions;
}

WriteToCResult writeToC(ref Alloc alloc, in ShowCtx printCtx, in LowProgram program, in WriteToCParams params) {
	bool isMSVC = program.version_.os == OS.windows;
	CString[] args = cCompileArgs(alloc, program.externLibraries, isMSVC, params);
	string content = makeStringWithWriter(alloc, (scope ref Writer writer) {
		writeCommandComment(writer, params.cCompiler, args);
		writeWithoutCr(writer, isMSVC ? boilerplateMsvc : boilerplatePosix);
		if (isMSVC) {
			writer ~= "unsigned short __popcnt16(unsigned short value);\n";
			writer ~= "unsigned int __popcnt(unsigned int value);\n";
			writer ~= "unsigned __int64 __popcnt64(unsigned __int64 value);\n";
		}
		writer ~= "union _convert { uint32_t nat32; uint64_t nat64; float float32; double float64; };\n";

		CVersion cVersion = params.compileOptions.cVersion;
		if (cVersion == CVersion.c99) {
			// Based on https://github.com/BartMassey/popcount/blob/master/popcount.c
			writer ~=
				"static uint32_t popcount32(uint32_t a) {\n" ~
				"\tuint32_t y = (a >> 1) & 033333333333;\n" ~
				"\ty = a - y - ((y >>1) & 033333333333);\n" ~
				"\treturn ((y + (y >> 3)) & 030707070707) % 63;\n" ~
				"}\n" ~
				"uint64_t __builtin_popcountl(uint64_t x) {\n" ~
				"\treturn popcount32(x & 0xffffffff) + popcount32(x >> 32);\n" ~
				"}\n";
		}

		Ctx ctx = Ctx(
			ptrTrustMe(printCtx), ptrTrustMe(program), buildMangledNames(alloc, program),
			isMSVC: isMSVC, cVersion: cVersion);

		writeStructs(alloc, writer, ctx);

		fullIndexMapEach!(LowFunIndex, LowFun)(program.allFuns, (LowFunIndex funIndex, ref LowFun fun) {
			writeFunDeclaration(writer, ctx, funIndex, fun);
		});

		writeConstants(writer, ctx, program.allConstants);
		writeVars(writer, ctx, program.vars);

		fullIndexMapEach!(LowFunIndex, LowFun)(
			program.allFuns,
			(LowFunIndex funIndex, ref LowFun fun) {
				writeFunDefinition(writer, alloc, ctx, funIndex, fun);
			});
	});
	return WriteToCResult(PathAndArgs(params.cCompiler, args), content);
}

// On Windows builds, the imported file might have CRLF line endings, but we don't want those in our output
private void writeWithoutCr(scope ref Writer writer, in string a) {
	version (Windows) {
		foreach (char c; a)
			if (c != '\r')
				writer ~= c;
	} else
		writer ~= a;
}

private void writeCommandComment(scope ref Writer writer, FilePath cCompiler, in CString[] args) {
	writer ~= "/* \"";
	writer ~= cCompiler;
	writer ~= "\" ";
	writeWithSpaces!CString(writer, args, (in CString arg) { writeAndQuoteIfNecessary(writer, stringOfCString(arg)); });
	writer ~= " */\n\n";
}

private void writeAndQuoteIfNecessary(scope ref Writer writer, in string a) {
	if (contains(a, ' '))
		writeQuotedString(writer, a);
	else
		writer ~= a;
}

public void getLinkOptions(
	ref Alloc alloc,
	bool isMSVC,
	in ExternLibraries externLibraries,
	in void delegate(CString) @safe @nogc pure nothrow cb,
) {
	if (isMSVC)
		cb(cString!"/link");
	foreach (ExternLibrary x; externLibraries) {
		if (isMSVC) {
			Symbol xDotLib = addExtension(x.libraryName, Extension.lib);
			if (has(x.configuredDir)) {
				if (!uriIsFile(force(x.configuredDir)))
					todo!void("diagnostic: can't link to non-file");
				cb(cStringOfFilePath(alloc, asFilePath(force(x.configuredDir)) / xDotLib));
			} else
				switch (x.libraryName.value) {
					case symbol!"libc".value:
					case symbol!"m".value:
					case symbol!"ucrtbase".value:
					case symbol!"windows".value:
						break;
					default:
						cb(cStringOfSymbol(alloc, xDotLib));
						break;
				}
		} else {
			if (has(x.configuredDir)) {
				cb(withWriter(alloc, (scope ref Writer writer) {
					writer ~= "-L/";
					if (!uriIsFile(force(x.configuredDir)))
						todo!void("diagnostic: can't link to non-file");
					writer ~= asFilePath(force(x.configuredDir));
				}));
			}

			if (!ignoreExternLibrary(x.libraryName))
				cb(withWriter(alloc, (scope ref Writer writer) {
					writer ~= "-l";
					writer ~= x.libraryName;
				}));
		}
	}
}

private:

bool ignoreExternLibrary(Symbol a) {
	switch (a.value) {
		case symbol!"libc".value:
		case symbol!"linux".value:
		case symbol!"posix".value:
			return true;
		default:
			return false;
	}
}

CString[] cCompileArgs(
	ref Alloc alloc,
	in ExternLibraries externLibraries,
	bool isMSVC,
	in WriteToCParams params,
) =>
	buildArray(alloc, (scope ref Builder!CString args) {
		args ~= cCompilerArgs(isMSVC, params.compileOptions);
		args ~= cStringOfFilePath(alloc, params.cPath);
		getLinkOptions(alloc, isMSVC, externLibraries, (CString x) { args ~= x; });
		if (isMSVC) {
			args ~= [
				cString!"/nologo",
				withWriter(alloc, (scope ref Writer writer) {
					writer ~= "/out:";
					writer ~= params.exePath;
				}),
			];
		} else {
			args ~= [cString!"-o", cStringOfFilePath(alloc, params.exePath)];
		}
	});

CString[] cCompilerArgs(bool isMSVC, in CCompileOptions options) {
	if (isMSVC) {
		static immutable CString[] optimizedArgs = [
			cString!"/DEBUG",
			cString!"/Z7",
			cString!"/std:c17",
			cString!"/W3",
			cString!"/wd4028",
			cString!"/wd4102",
			cString!"/wd4723",
			cString!"/WX",
			cString!"/O2",
		];
		static immutable CString[] regularArgs = optimizedArgs[0 .. $ - 1];
		final switch (options.optimizationLevel) {
			case OptimizationLevel.none:
				return regularArgs;
			case OptimizationLevel.o2:
				return optimizedArgs;
		}
	} else {
		static immutable CString[] optimizedArgs = [
			cString!"-Werror",
			cString!"-Wextra",
			cString!"-Wall",
			cString!"-ansi",
			cString!"-std=c17",
			cString!"-Wno-address-of-packed-member",
			cString!"-Wno-builtin-declaration-mismatch",
			cString!"-Wno-clobbered",
			cString!"-Wno-maybe-uninitialized",
			cString!"-Wno-missing-field-initializers",
			cString!"-Wno-unused-but-set-parameter",
			cString!"-Wno-unused-but-set-variable",
			cString!"-Wno-unused-function",
			cString!"-Wno-unused-parameter",
			cString!"-Wno-unused-label",
			cString!"-Wno-unused-variable",
			cString!"-Wno-unused-value",
			cString!"-Ofast",
			// Without this, 'is-nan' can return 'false' even for 'nan' values.
			cString!"-fno-fast-math",
		];
		static immutable CString[] regularArgs = optimizedArgs[0 .. $ - 2] ~ [cString!"-g"];
		final switch (options.optimizationLevel) {
			case OptimizationLevel.none:
				return regularArgs;
			case OptimizationLevel.o2:
				return optimizedArgs;
		}
	}
}

void writeCStringName(scope ref Writer writer, size_t index) {
	writer ~= "__cString";
	writer ~= index;
}

void writeConstants(scope ref Writer writer, scope ref Ctx ctx, in AllConstantsLow allConstants) {
	// Need to ensure strings are written only once so MSVC doesn't create duplicates (which breaks Symbol uniqueness)
	foreach (size_t index, CString x; allConstants.cStrings) {
		writer ~= "char ";
		writeCStringName(writer, index);
		writer ~= "[";
		writer ~= cStringSize(x) + 1;
		writer ~= "] = ";
		writeStringLiteralWithNul(writer, ctx.isMSVC, stringOfCString(x));
		writer ~= ";\n";
	}
	writer ~= '\n';

	foreach (ref ArrTypeAndConstantsLow a; allConstants.arrs) {
		foreach (size_t i, Constant[] elements; a.constants) {
			declareConstantArrStorage(writer, ctx, a.arrType, a.elementType, i, elements.length);
			writer ~= ";\n";
		}
	}

	foreach (ref PointerTypeAndConstantsLow a; allConstants.pointers) {
		foreach (size_t i; 0 .. a.constants.length) {
			declareConstantPointerStorage(writer, ctx, a.pointeeType, i);
			writer ~= ";\n";
		}
	}

	foreach (ref ArrTypeAndConstantsLow a; allConstants.arrs) {
		foreach (size_t i, Constant[] elements; a.constants) {
			declareConstantArrStorage(writer, ctx, a.arrType, a.elementType, i, elements.length);
			writer ~= " = ";
			writeArrayConstant(writer, ctx, a.elementType, elements);
			writer ~= ";\n";
		}
	}

	foreach (ref PointerTypeAndConstantsLow a; allConstants.pointers) {
		foreach (size_t i, Constant pointee; a.constants) {
			declareConstantPointerStorage(writer, ctx, a.pointeeType, i);
			writer ~= " = ";
			writeConstantRef(writer, ctx, ConstantRefPos.inner, a.pointeeType, pointee);
			writer ~= ";\n";
		}
	}
}

void writeArrayConstant(scope ref Writer writer, scope ref Ctx ctx, in LowType elementType, in Constant[] elements) {
	if (isChar8(elementType)) {
		char[0x10000] buf;
		foreach (size_t i, Constant x; elements)
			buf[i] = cast(char) x.as!IntegralValue.value;
		writeStringLiteralWithoutNul(writer, ctx.isMSVC, castImmutable(buf[0 .. elements.length]));
	} else if (isChar32(elementType) && ctx.cVersion >= CVersion.c11 && !ctx.isMSVC) {
		writer ~= "U\"";
		foreach (Constant element; elements)
			writeEscapedCharForC(writer, cast(dchar) element.as!IntegralValue.value);
		writer ~= '"';
	} else {
		writer ~= '{';
		writeWithCommas!Constant(writer, elements, (in Constant element) {
			writeConstantRef(writer, ctx, ConstantRefPos.inner, elementType, element);
		});
		writer ~= '}';
	}
}

void writeEscapedCharForC(scope ref Writer writer, dchar a) {
	if (a == '?')
		// avoid trigraphs
		writer ~= "\\?";
	else
		writeEscapedChar_inner(writer, a, forC: true);
}

bool useStructThreadLocals(in Ctx ctx) =>
	// Putting thread-locals a pointer seems to be necessary
	// to avoid accessing cached values after a fiber switch in optimized builds
	// TODO: It seems that we don't need this with newer GCC versions. Or maybe just got lucky?
	true;

void writeVars(scope ref Writer writer, scope ref Ctx ctx, in immutable FullIndexMap!(LowVarIndex, LowVar) vars) {
	if (useStructThreadLocals(ctx)) {
		writer ~= "struct ThreadLocals {\n";
		fullIndexMapEach!(LowVarIndex, LowVar)(vars, (LowVarIndex varIndex, ref LowVar var) {
			if (var.kind == LowVar.Kind.threadLocal) {
				writer ~= '\t';
				writeVarTypeAndName(writer, ctx, varIndex, var);
				writer ~= ";\n";
			}
		});
		writer ~= "};\n";
	}

	fullIndexMapEach!(LowVarIndex, LowVar)(vars, (LowVarIndex varIndex, ref LowVar var) {
		if (!(useStructThreadLocals(ctx) && var.kind == LowVar.Kind.threadLocal)) {
			writer ~= () {
				final switch (var.kind) {
					case LowVar.Kind.externGlobal:
						return "extern ";
					case LowVar.Kind.global:
						return "static ";
					case LowVar.Kind.threadLocal:
						return "static _Thread_local ";
				}
			}();
			writeVarTypeAndName(writer, ctx, varIndex, var);
			writer ~= ";\n";
		}
	});
}
void writeVarTypeAndName(scope ref Writer writer, in Ctx ctx, LowVarIndex varIndex, in LowVar var) {
	writeType(writer, ctx, var.type);
	writer ~= ' ';
	writeLowVarMangledName(writer, ctx.mangledNames, varIndex, var);
}

void declareConstantArrStorage(
	scope ref Writer writer,
	scope ref Ctx ctx,
	in LowRecord* arrType,
	in LowType elementType,
	size_t index,
	size_t nElements,
) {
	writeType(writer, ctx, elementType);
	writer ~= ' ';
	writeConstantArrStorageName(writer, ctx.mangledNames, ctx.program, arrType, index);
	writer ~= '[';
	writer ~= nElements;
	writer ~= ']';
}

void declareConstantPointerStorage(
	scope ref Writer writer,
	scope ref Ctx ctx,
	in LowType pointeeType,
	size_t index,
) {
	//TODO: some day we may support non-record pointee?
	writeStructType(writer, ctx, pointeeType.as!(LowRecord*).source);
	writer ~= ' ';
	writeConstantPointerStorageName(writer, ctx.mangledNames, ctx.program, pointeeType, index);
}

const struct Ctx {
	@safe @nogc pure nothrow:

	ShowCtx* showDiagCtxPtr;
	LowProgram* programPtr;
	MangledNames mangledNames;
	bool isMSVC;
	CVersion cVersion;

	ref ShowCtx printCtx() return scope =>
		*showDiagCtxPtr;
	ref LowProgram program() return scope const =>
		*programPtr;
}

struct FunBodyCtx {
	@safe @nogc pure nothrow:

	TempAlloc* tempAllocPtr;
	Ctx* ctxPtr;
	immutable bool hasTailRecur;
	immutable LowFunIndex curFun;
	size_t nextTemp;

	ref TempAlloc tempAlloc() scope =>
		*castNonScope(tempAllocPtr);

	ref inout(Ctx) ctx() return scope inout =>
		*ctxPtr;

	ref LowProgram program() return scope const =>
		ctx.program;

	ref MangledNames mangledNames() return scope const =>
		ctx.mangledNames;

	bool isMSVC() scope const =>
		ctx.isMSVC;
}

size_t nextLoopIndex(ref FunBodyCtx ctx) {
	size_t res = ctx.nextTemp;
	ctx.nextTemp++;
	return res;
}

Temp getNextTemp(ref FunBodyCtx ctx) {
	Temp temp = Temp(ctx.nextTemp);
	ctx.nextTemp++;
	return temp;
}

void writeType(scope ref Writer writer, scope ref Ctx ctx, in LowType t) {
	t.combinePointer.matchWithPointers!void(
		(LowExternType* x) {
			writeStructType(writer, ctx, x.source);
		},
		(LowFunPointerType* x) {
			writeStructMangledName(writer, ctx.mangledNames, x.source);
		},
		(PrimitiveType it) {
			writePrimitiveType(writer, it);
		},
		(LowPointerCombine it) {
			writeType(writer, ctx, it.pointee);
			writer ~= '*';
		},
		(LowRecord* x) {
			writeStructType(writer, ctx, x.source);
		},
		(LowUnion* x) {
			writeStructType(writer, ctx, x.source);
		});
}

void writeStructType(scope ref Writer writer, in Ctx ctx, in ConcreteStruct* source) {
	writer ~= "struct ";
	writeStructMangledName(writer, ctx.mangledNames, source);
}

void writeCastToType(scope ref Writer writer, scope ref Ctx ctx, in LowType type) {
	writer ~= '(';
	writeType(writer, ctx, type);
	writer ~= ") ";
}

void writeParamDecl(scope ref Writer writer, scope ref Ctx ctx, in LowLocal a) {
	writeType(writer, ctx, a.type);
	writer ~= ' ';
	writeLowLocalName(writer, ctx.mangledNames, a);
}

void writeStructHead(scope ref Writer writer, scope ref Ctx ctx, in ConcreteStruct* source) {
	writer ~= "struct ";
	writeStructMangledName(writer, ctx.mangledNames, source);
	writer ~= " {";
}

void writeStructEnd(ref Writer writer) {
	writer ~= "\n};\n";
}

bool isEmptyType(in Ctx ctx, in LowType a) =>
	sizeOfType(ctx.program, a).sizeBytes == 0;
bool isEmptyType(in FunBodyCtx ctx, in LowType a) =>
	isEmptyType(ctx.ctx, a);

void writeRecord(scope ref Writer writer, scope ref Ctx ctx, in LowRecord a) {
	if (a.isPacked && ctx.isMSVC)
		writer ~= "__pragma(pack(push, 1))\n";
	writeStructHead(writer, ctx, a.source);
	foreach (ref LowField field; a.fields) {
		if (!isEmptyType(ctx, field.type)) {
			writer ~= "\n\t";
			writeType(writer, ctx, field.type);
			writer ~= ' ';
			writeMangledName(writer, ctx.mangledNames, debugName(field));
			writer ~= ';';
		}
	}
	writer ~= "\n}";
	if (a.isPacked)
		writer ~= ctx.isMSVC ? "__pragma(pack(pop))" : " __attribute__ ((__packed__))";
	writer ~= ";\n";
}

bool canUseAnonymousUnions(in Ctx ctx) =>
	ctx.cVersion < CVersion.c11;

void writeUnion(scope ref Writer writer, scope ref Ctx ctx, in LowUnion a) {
	bool isBuiltin = a.source.body_.isA!(ConcreteStructBody.Builtin*);
	if (isBuiltin) assert(isLambda(a.source.body_.as!(ConcreteStructBody.Builtin*).kind));

	if (isBuiltin || exists!LowType(a.members, (in LowType member) => !isEmptyType(ctx, member))) {
		if (canUseAnonymousUnions(ctx)) {
			writeStructHead(writer, ctx, a.source);
			writer ~= "\n\tuint64_t kind;\n\tunion {";
		} else {
			writer ~= "union ";
			writeStructMangledName(writer, ctx.mangledNames, a.source);
			writer ~= "_union {";
		}

		foreach (size_t memberIndex, LowType member; a.members) {
			if (!isEmptyType(ctx, member)) {
				writer ~= "\n\t\t";
				writeType(writer, ctx, member);
				writer ~= " as";
				writer ~= memberIndex;
				writer ~= ';';
			}
		}
		// Fun types must be 16 bytes
		if (isBuiltin &&
			every!LowType(a.members, (in LowType member) => typeSizeBytes(ctx.program, member) < 8))
			writer ~= "\n\t\tuint64_t __ensureSizeIs16;";

		if (canUseAnonymousUnions(ctx))
			writer ~= "\n\t};";
		else {
			writeStructEnd(writer);
			writeStructHead(writer, ctx, a.source);
			writer ~= "\n\tuint64_t kind;";
			writer ~= "\n\tunion ";
			writeStructMangledName(writer, ctx.mangledNames, a.source);
			writer ~= "_union ";
			writer ~= "u;";
		}
		writeStructEnd(writer);
	} else {
		writeStructHead(writer, ctx, a.source);
		writer ~= " uint64_t kind; };\n";
	}
}

void declareStruct(scope ref Writer writer, scope ref Ctx ctx, in ConcreteStruct* source) {
	writer ~= "struct ";
	writeStructMangledName(writer, ctx.mangledNames, source);
	writer ~= ";\n";
}

void staticAssertStructSize(scope ref Writer writer, scope ref Ctx ctx, in LowType type, TypeSize size) {
	writer ~= "_Static_assert(sizeof(";
	writeType(writer, ctx, type);
	writer ~= ") == ";
	writer ~= size.sizeBytes;
	writer ~= ", \"\");\n";

	writer ~= "_Static_assert(_Alignof(";
	writeType(writer, ctx, type);
	writer ~= ") == ";
	writer ~= size.alignmentBytes;
	writer ~= ", \"\");\n";
}

void writeStructs(ref Alloc alloc, scope ref Writer writer, scope ref Ctx ctx) {
	scope TypeWriters writers = TypeWriters(
		(ConcreteStruct* x) {
			if (!isEmptyStruct(*x))
				declareStruct(writer, ctx, x);
		},
		(ConcreteStruct* source, in Opt!TypeSize typeSize) {
			if (has(typeSize) && ctx.isMSVC) {
				writer ~= "__declspec(align(";
				writer ~= force(typeSize).alignmentBytes;
				writer ~= ")) ";
			}
			writer ~= "struct ";
			writeStructMangledName(writer, ctx.mangledNames, source);
			if (has(typeSize)) {
				writer ~= " { uint8_t __sizer[";
				writer ~= force(typeSize).sizeBytes;
				writer ~= "]; }";
				if (!ctx.isMSVC) {
					writer ~= " __attribute__((aligned(";
					writer ~= force(typeSize).alignmentBytes;
					writer ~= ")))";
				}
			}
			writer ~= ";\n";
		},
		(LowFunPointerTypeIndex _, in LowFunPointerType funPtr) {
			writer ~= "typedef ";
			if (isEmptyType(ctx, funPtr.returnType))
				writer ~= "void";
			else
				writeType(writer, ctx, funPtr.returnType);
			writer ~= " (*";
			writeStructMangledName(writer, ctx.mangledNames, funPtr.source);
			writer ~= ")(";
			if (isEmpty(funPtr.paramTypes))
				writer ~= "void";
			else
				writeWithCommas!LowType(
					writer,
					funPtr.paramTypes,
					(in LowType paramType) =>
						!isEmptyType(ctx, paramType),
					(in LowType paramType) {
						writeType(writer, ctx, paramType);
					});
			writer ~= ");\n";
		},
		(LowRecordIndex _, in LowRecord* record) {
			if (!isEmptyType(ctx, LowType(record)))
				writeRecord(writer, ctx, *record);
		},
		(LowUnionIndex _, in LowUnion* union_) {
			writeUnion(writer, ctx, *union_);
		});
	writeTypes(alloc, ctx.program, writers);

	writer ~= '\n';

	void assertSize(LowType t) {
		staticAssertStructSize(writer, ctx, t, sizeOfType(ctx.program, t));
	}

	foreach (ref LowRecord x; ctx.program.allRecords)
		if (!isEmptyType(ctx, LowType(&x)))
			assertSize(LowType(&x));
	foreach (ref LowUnion x; ctx.program.allUnions)
		assertSize(LowType(&x));
}

void writeFunReturnTypeNameAndParams(scope ref Writer writer, scope ref Ctx ctx, LowFunIndex funIndex, in LowFun fun) {
	if (isEmptyType(ctx,fun.returnType))
		writer ~= "void";
	else
		writeType(writer, ctx, fun.returnType);
	writer ~= ' ';
	writeLowFunMangledName(writer, ctx.mangledNames, funIndex, fun);
	writer ~= '(';
	if (every!LowLocal(fun.params, (in LowLocal x) => isEmptyType(ctx, x.type)))
		writer ~= "void";
	else
		writeWithCommas!LowLocal(
			writer,
			fun.params,
			(in LowLocal x) =>
				!isEmptyType(ctx, x.type),
			(in LowLocal x) {
				writeParamDecl(writer, ctx, x);
			});
	writer ~= ')';
}

void writeFunDeclaration(scope ref Writer writer, scope ref Ctx ctx, LowFunIndex funIndex, in LowFun fun) {
	if (fun.body_.isA!(LowFunBody.Extern))
		writer ~= "extern ";
	else if (!fun.isGeneratedMain)
		writer ~= "static ";
	writeFunReturnTypeNameAndParams(writer, ctx, funIndex, fun);
	writer ~= ";\n";
}

void writeFunDefinition(
	scope ref Writer writer,
	ref TempAlloc tempAlloc,
	scope ref Ctx ctx,
	LowFunIndex funIndex,
	in LowFun fun,
) {
	fun.body_.matchIn!void(
		(in LowFunBody.Extern) {
			// declaration is enough
		},
		(in LowFunExprBody x) {
			// TODO: only if a flag is set
			writer ~= "/* ";
			writeFunSig(writer, ctx.printCtx, ctx.program, fun);
			writer ~= " */\n";
			writeFunWithExprBody(writer, tempAlloc, ctx, funIndex, fun, x);
		});
}

void writeFunWithExprBody(
	scope ref Writer writer,
	ref TempAlloc tempAlloc,
	scope ref Ctx ctx,
	LowFunIndex funIndex,
	in LowFun fun,
	in LowFunExprBody body_,
) {
	if (!fun.isGeneratedMain) writer ~= "static ";
	writeFunReturnTypeNameAndParams(writer, ctx, funIndex, fun);
	writer ~= " {";
	if (body_.hasTailRecur)
		writer ~= "\n\ttop:;"; // Need ';' so it labels a statement
	FunBodyCtx bodyCtx = FunBodyCtx(ptrTrustMe(tempAlloc), ptrTrustMe(ctx), body_.hasTailRecur, funIndex, 0);
	WriteKind writeKind = isEmptyType(ctx, fun.returnType)
		? WriteKind(WriteKind.Void())
		: WriteKind(WriteKind.Return());
	cast(void) writeExpr(writer, 1, bodyCtx, writeKind, body_.expr);
	writer ~= "\n}\n";
}

immutable struct Temp {
	size_t index;
}

// If expr, we refused to write to a temp because this can be written inline
immutable struct WriteExprResult {
	// Meaning depends on the WriteKind
	// If the write kind was TempOrInline, this indicates that it should be done inline.
	immutable struct Done {
		// Args (not written inline) prepared for writing inline.
		WriteExprResult[] args;
	}

	mixin Union!(Done, Temp);
}

WriteExprResult writeExprDone() =>
	WriteExprResult(WriteExprResult.Done([]));

void writeTempDeclare(
	scope ref Writer writer,
	scope ref FunBodyCtx ctx,
	in LowType type,
	Temp temp,
) {
	writeType(writer, ctx.ctx, type);
	writer ~= ' ';
	writeTempRef(writer, temp);
}

void writeTempRef(scope ref Writer writer, in Temp a) {
	writer ~= "_";
	writer ~= a.index;
}

void writeTempOrInline(scope ref Writer writer, scope ref FunBodyCtx ctx, in LowExpr e, in WriteExprResult a) {
	a.matchIn!void(
		(in WriteExprResult.Done it) {
			WriteKind writeKind = WriteKind(WriteKind.Inline(it.args));
			WriteExprResult res = writeExpr(writer, 0, ctx, writeKind, e);
			assert(isEmpty(res.as!(WriteExprResult.Done).args));
		},
		(in Temp it) {
			writeTempRef(writer, it);
		});
}

void writeTempOrInlines(
	scope ref Writer writer,
	scope ref FunBodyCtx ctx,
	in LowExpr[] exprs,
	in WriteExprResult[] args,
) {
	assert(sizeEq(exprs, args));
	writeWithCommasZip!(LowExpr, WriteExprResult)(
		writer,
		exprs,
		args,
		(in LowExpr expr, in WriteExprResult) =>
			!isEmptyType(ctx, expr.type),
		(in expr, in WriteExprResult arg) {
			writeTempOrInline(writer, ctx, expr, arg);
		});
}

void writeDeclareLocal(scope ref Writer writer, size_t indent, scope ref FunBodyCtx ctx, in LowLocal local) {
	writeNewline(writer, indent);
	bool isVolatile = localMustBeVolatile(ctx, local);
	if (isVolatile)
		writer ~= "volatile ";
	writeType(writer, ctx.ctx, local.type);
	// It seems that 'volatile' alone doesn't to the job with MSVC
	// (it optimizes 'setup-catch' assuming only one branch happens),
	// but allocating it with a volatile pointee works.
	bool isAlloca = isVolatile && localMustAllocaIfVolatile(ctx);
	if (isAlloca)
		writer ~= '*';
	writer ~= ' ';
	writeLowLocalName(writer, ctx.mangledNames, local);
	if (isAlloca) {
		writer ~= " = ";
		writer ~= ctx.isMSVC ? "_alloca" : "__builtin_alloca";
		writer ~= "(sizeof(";
		writeType(writer, ctx.ctx, local.type);
		writer ~= "))";
	}
	writer ~= ';';
}

bool localMustAllocaIfVolatile(in FunBodyCtx ctx) =>
	ctx.isMSVC;

bool localMustBeVolatile(in FunBodyCtx ctx, in LowLocal local) =>
	.localMustBeVolatile(ctx.ctx.program.allFuns[ctx.curFun], local);

void writeAccessLocal(scope ref Writer writer, in FunBodyCtx ctx, in LowLocal local) {
	if (localMustAllocaIfVolatile(ctx) && localMustBeVolatile(ctx, local))
		writer ~= '*';
	writeLowLocalName(writer, ctx.mangledNames, local);
}

immutable struct WriteKind {
	immutable struct Inline {
		WriteExprResult[] args;
	}
	// May write a temp now, or delay and write inline when needed.
	immutable struct InlineOrTemp {}
	immutable struct MakeTemp {}
	immutable struct Return {}
	immutable struct UseTemp {
		Temp temp;
	}
	// Simple statement, don't return anything
	immutable struct Void {}

	mixin Union!(Inline, InlineOrTemp, LowLocal*, LowVarIndex, MakeTemp, Return, UseTemp, LoopInfo*, Void);
}
static assert(WriteKind.sizeof == size_t.sizeof * 3);

WriteExprResult[] writeExprsTempOrInline(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in LowExpr[] args,
) =>
	map(ctx.tempAlloc, args, (ref LowExpr arg) =>
		writeExprTempOrInline(writer, indent, ctx, arg));

Temp writeExprTemp(scope ref Writer writer, size_t indent, scope ref FunBodyCtx ctx, in LowExpr expr) {
	WriteKind writeKind = WriteKind(WriteKind.MakeTemp());
	return writeExpr(writer, indent, ctx, writeKind, expr).as!Temp;
}

void writeExprVoid(scope ref Writer writer, size_t indent, scope ref FunBodyCtx ctx, in LowExpr expr) {
	WriteKind writeKind = WriteKind(WriteKind.Void());
	cast(void) writeExpr(writer, indent, ctx, writeKind, expr);
}

WriteExprResult writeExprTempOrInline(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in LowExpr expr,
) {
	WriteKind writeKind = WriteKind(WriteKind.InlineOrTemp());
	return writeExpr(writer, indent, ctx, writeKind, expr);
}

immutable struct LoopInfo {
	size_t index;
	WriteKind writeKind;
}

WriteExprResult writeExpr(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowExpr expr,
) {
	LowType type = expr.type;
	WriteExprResult nonInlineable(in void delegate() @safe @nogc pure nothrow cb) =>
		writeNonInlineable(writer, indent, ctx, writeKind, type, cb);
	WriteExprResult inlineable(
		in LowExpr[] args,
		in void delegate(in WriteExprResult[]) @safe @nogc pure nothrow inline,
	) =>
		writeInlineable(writer, indent, ctx, writeKind, type, args, inline);
	WriteExprResult inlineableSingleArg(
		in LowExpr arg,
		in void delegate(in WriteExprResult) @safe @nogc pure nothrow inline,
	) =>
		writeInlineableSingleArg(writer, indent, ctx, writeKind, type, arg, inline);
	WriteExprResult inlineableSimple(in void delegate() @safe @nogc pure nothrow inline) =>
		writeInlineableSimple(writer, indent, ctx, writeKind, type, inline);

	return expr.kind.matchIn!WriteExprResult(
		(in AbortLowExpr _) =>
			writeAbort(writer, indent, ctx, writeKind, type),
		(in CallLowExpr it) =>
			writeCallExpr(writer, indent, ctx, writeKind, type, it),
		(in CallFunPointerLowExpr it) =>
			writeCallFunPointer(writer, indent, ctx, writeKind, type, it),
		(in CreateRecordLowExpr it) =>
			inlineable(it.args, (in WriteExprResult[] args) {
				writeCastToType(writer, ctx.ctx, type);
				writer ~= '{';
				writeTempOrInlines(writer, ctx, it.args, args);
				writer ~= '}';
			}),
		(in CreateUnionLowExpr it) =>
			inlineableSingleArg(it.arg, (in WriteExprResult arg) {
				writeCreateUnion(writer, ctx.ctx, ConstantRefPos.outer, type, it.memberIndex, () {
					writeTempOrInline(writer, ctx, it.arg, arg);
				});
			}),
		(in FunPointerLowExpr x) =>
			inlineableSimple(() {
				writeFunPointer(writer, ctx.ctx, x.fun);
			}),
		(in IfLowExpr it) =>
			writeIf(writer, indent, ctx, writeKind, type, it),
		(in InitLowExpr x) =>
			writeInit(writer, indent, ctx, writeKind, x),
		(in LetLowExpr it) =>
			writeLet(writer, indent, ctx, writeKind, it),
		(in LocalGetLowExpr it) =>
			inlineableSimple(() {
				writeAccessLocal(writer, ctx, *it.local);
			}),
		(in LocalPointerLowExpr x) =>
			inlineableSimple(() {
				if (localMustBeVolatile(ctx, *x.local))
					writeCastToType(writer, ctx.ctx, type);
				writer ~= '&';
				writeAccessLocal(writer, ctx, *x.local);
			}),
		(in LocalSetLowExpr it) =>
			writeLocalSet(writer, indent, ctx, writeKind, it),
		(in LoopLowExpr x) =>
			writeLoop(writer, indent, ctx, writeKind, type, x),
		(in LoopBreakLowExpr x) =>
			writeLoopBreak(writer, indent, ctx, writeKind, x),
		(in LoopContinueLowExpr _) =>
			writeLoopContinue(writer, indent, writeKind),
		(in PointerCastLowExpr x) =>
			inlineableSingleArg(x.target, (in WriteExprResult arg) {
				writer ~= '(';
				writeCastToType(writer, ctx.ctx, type);
				writeTempOrInline(writer, ctx, x.target, arg);
				writer ~= ')';
			}),
		(in RecordFieldGetLowExpr x) =>
			writeRecordFieldGet(writer, indent, ctx, writeKind, type, x),
		(in RecordFieldPointerLowExpr x) =>
			writeRecordFieldPointer(writer, indent, ctx, writeKind, type, x),
		(in RecordFieldSetLowExpr x) {
			WriteExprResult recordValue = writeExprTempOrInline(writer, indent, ctx, x.target);
			WriteExprResult fieldValue = writeExprTempOrInline(writer, indent, ctx, x.value);
			return writeReturnVoid(writer, indent, ctx, writeKind, () {
				writeTempOrInline(writer, ctx, x.target, recordValue);
				writeRecordFieldRef(writer, ctx, true, *x.targetRecordType, x.fieldIndex);
				writer ~= " = ";
				writeTempOrInline(writer, ctx, x.value, fieldValue);
			});
		},
		(in Constant it) =>
			inlineableSimple(() {
				writeConstantRef(writer, ctx.ctx, ConstantRefPos.outer, type, it);
			}),
		(in SpecialUnaryLowExpr x) =>
			writeSpecialUnary(writer, indent, ctx, writeKind, type, x),
		(in SpecialUnaryMathLowExpr x) =>
			specialCallUnary(writer, indent, ctx, writeKind, type, x.arg, stringOfEnum(builtinForUnaryMath(x.kind))),
		(in SpecialBinaryLowExpr x) =>
			writeSpecialBinary(writer, indent, ctx, writeKind, type, x),
		(in SpecialBinaryMathLowExpr x) =>
			specialCallBinary(writer, indent, ctx, writeKind, type, x.args, stringOfEnum(builtinForBinaryMath(x.kind))),
		(in SpecialTernaryLowExpr x) {
			final switch (x.kind) {
				case BuiltinTernary.interpreterBacktrace:
					assert(false);
					return writeExprDone(); // needed to give the lambda a return type
			}
		},
		(in Special4aryLowExpr x) {
			final switch (x.kind) {
				case Builtin4ary.switchFiberInitial:
					// defined in writeToC_boilerplace.c
					return specialCallNary(writer, indent, ctx, writeKind, type, x.args, "switch_fiber_initial");
			}
		},
		(in SwitchLowExpr x) =>
			writeSwitch(writer, indent, ctx, writeKind, type, x),
		(in TailRecurLowExpr x) {
			assert(writeKind.isA!(WriteKind.Void) || writeKind.isA!(WriteKind.Return));
			writeTailRecur(writer, indent, ctx, x);
			return writeExprDone();
		},
		(in UnionAsLowExpr x) =>
			writeUnionAs(writer, indent, ctx, writeKind, type, x),
		(in UnionKindLowExpr x) =>
			writeUnionKind(writer, indent, ctx, writeKind, type, x),
		(in VarGetLowExpr x) =>
			inlineableSimple(() {
				writeLowVarAccess(writer, ctx.ctx, x.varIndex);
			}),
		(in VarSetLowExpr x) {
			WriteKind varWriteKind = WriteKind(x.varIndex);
			cast(void) writeExpr(writer, indent, ctx, varWriteKind, *x.value);
			return writeReturnVoid(writer, indent, ctx, writeKind);
		});
}

WriteExprResult writeNonInlineable(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in void delegate() @safe @nogc pure nothrow cb,
) {
	if (!writeKind.isA!(WriteKind.Inline))
		writeNewline(writer, indent);
	WriteExprResult makeTemp() {
		Temp temp = getNextTemp(ctx);
		if (!isEmptyType(ctx, type)) {
			writeTempDeclare(writer, ctx, type, temp);
			writer ~= " = ";
		}
		return WriteExprResult(temp);
	}
	WriteExprResult res = castNonScope_ref(writeKind).matchIn!WriteExprResult(
		(in WriteKind.Inline) =>
			writeExprDone(),
		(in WriteKind.InlineOrTemp) =>
			makeTemp(),
		(in LowLocal x) {
			writeAccessLocal(writer, ctx, x);
			writer ~= " = ";
			return writeExprDone();
		},
		(in LowVarIndex x) {
			writeLowVarAccess(writer, ctx.ctx, x);
			writer ~= " = ";
			return writeExprDone();
		},
		(in WriteKind.MakeTemp _) =>
			makeTemp(),
		(in WriteKind.Return) {
			writer ~= "return ";
			return writeExprDone();
		},
		(in WriteKind.UseTemp x) {
			writeTempRef(writer, x.temp);
			writer ~= " = ";
			return writeExprDone();
		},
		(in LoopInfo _) =>
			writeExprDone(),
		(in WriteKind.Void) =>
			writeExprDone());
	cb();
	if (!writeKind.isA!(WriteKind.Inline))
		writer ~= ';';
	return res;
}

void writeLowVarAccess(scope ref Writer writer, in Ctx ctx, in LowVarIndex varIndex) {
	LowVar var() => ctx.program.vars[varIndex];
	if (useStructThreadLocals(ctx) && var.kind == LowVar.Kind.threadLocal)
		writer ~= "threadLocals()->";
	writeLowVarMangledName(writer, ctx.mangledNames, varIndex, var);
}

WriteExprResult writeVoid(in WriteKind writeKind) {
	assert(writeKind.isA!(WriteKind.Void));
	return writeExprDone;
}

WriteExprResult writeInlineable(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in LowExpr[] args,
	in void delegate(in WriteExprResult[]) @safe @nogc pure nothrow inline,
) {
	if (writeKind.isA!(WriteKind.InlineOrTemp))
		return WriteExprResult(WriteExprResult.Done(writeExprsTempOrInline(writer, indent, ctx, args)));
	else if (writeKind.isA!(WriteKind.Inline)) {
		inline(writeKind.as!(WriteKind.Inline).args);
		return writeExprDone();
	} else {
		WriteExprResult[] argTemps = writeExprsTempOrInline(writer, indent, ctx, args);
		return writeNonInlineable(writer, indent, ctx, writeKind, type, () {
			inline(argTemps);
		});
	}
}

WriteExprResult writeInlineableSingleArg(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in LowExpr arg,
	in void delegate(in WriteExprResult) @safe @nogc pure nothrow inline,
) =>
	writeInlineable(writer, indent, ctx, writeKind, type, [castNonScope_ref(arg)], (in WriteExprResult[] args) {
		inline(only(args));
	});

WriteExprResult writeInlineableSimple(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in void delegate() @safe @nogc pure nothrow inline,
) =>
	writeInlineable(writer, indent, ctx, writeKind, type, [], (in WriteExprResult[]) {
		if (!isEmptyType(ctx, type))
			inline();
	});

WriteExprResult writeReturnVoid(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
) =>
	writeReturnVoid(writer, indent, ctx, writeKind, null);

WriteExprResult writeReturnVoid(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in void delegate() @safe @nogc pure nothrow cb,
) =>
	castNonScope_ref(writeKind).matchIn!WriteExprResult(
		(in WriteKind.Inline) =>
			assert(false),
		(in WriteKind.InlineOrTemp) =>
			assert(false),
		(in LowLocal _) =>
			assert(false),
		(in LowVarIndex _) =>
			assert(false),
		(in WriteKind.MakeTemp) =>
			assert(false),
		(in WriteKind.Return) {
			if (cb != null) {
				writeNewline(writer, indent);
				cb();
			}
			writer ~= ';';
			writeNewline(writer, indent);
			writer ~= "return;";
			return writeExprDone();
		},
		(in WriteKind.UseTemp) =>
			assert(false),
		(in LoopInfo _) =>
			assert(false),
		(in WriteKind.Void) {
			if (cb != null) {
				writeNewline(writer, indent);
				cb();
				writer ~= ';';
			}
			return writeExprDone();
		});

WriteExprResult writeAbort(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
) {
	if (writeKind.isA!(LoopInfo*) || writeKind.isA!(WriteKind.Return) || writeKind.isA!(WriteKind.Void)) {
		writeNewline(writer, indent);
		writer ~= "abort();";
		if (ctx.isMSVC) { // MSVC doesn't recognize abort as aborting, so need a fake return
			if (writeKind.isA!(LoopInfo*)) {
				writeNewline(writer, indent);
				return writeLoopContinue(writer, indent, writeKind);
			} else if (writeKind.isA!(WriteKind.Return)) {
				writeNewline(writer, indent);
				bool needValue = !isEmptyType(ctx, type);
				if (needValue) {
					writer ~= "return ";
					writeZeroedValue(writer, ctx.ctx, type);
					writer ~= ';';
				} else
					writer ~= "return;";
				return writeExprDone();
			} else
				return writeExprDone();
		} else
			return writeExprDone();
	} else
		return writeInlineableSimple(writer, indent, ctx, writeKind, type, () {
			bool needValue = !isEmptyType(ctx, type);
			if (needValue)
				writer ~= '(';
			writer ~= "abort()";
			if (needValue) {
				writer ~= ", ";
				writeZeroedValue(writer, ctx.ctx, type);
				writer ~= ')';
			}
		});
}

WriteExprResult writeCallExpr(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in CallLowExpr a,
) {
	WriteExprResult[] args = writeExprsTempOrInline(writer, indent, ctx, a.args);
	return writeNonInlineable(writer, indent, ctx, writeKind, type, () {
		writeLowFunMangledName(writer, ctx.mangledNames, a.called, ctx.program.allFuns[a.called]);
		writer ~= '(';
		writeTempOrInlines(writer, ctx, a.args, args);
		writer ~= ')';
	});
}

void writeTailRecur(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in TailRecurLowExpr a,
) {
	WriteExprResult[] newValues =
		map(ctx.tempAlloc, a.updateParams, (ref UpdateParam updateParam) =>
			writeExprTempOrInline(writer, indent, ctx, updateParam.newValue));
	zip!(UpdateParam, WriteExprResult)(
		a.updateParams,
		newValues,
		(ref UpdateParam updateParam, ref WriteExprResult newValue) {
			if (!isEmptyType(ctx, updateParam.param.type)) {
				writeNewline(writer, indent);
				writeLowLocalName(writer, ctx.mangledNames, *updateParam.param);
				writer ~= " = ";
				writeTempOrInline(writer, ctx, updateParam.newValue, newValue);
				writer ~= ';';
			}
		});
	writeNewline(writer, indent);
	writer ~= "goto top;";
}

void writeCreateUnion(
	scope ref Writer writer,
	scope ref Ctx ctx,
	ConstantRefPos pos,
	in LowType type,
	size_t memberIndex,
	in void delegate() @safe @nogc pure nothrow cbWriteMember,
) {
	if (pos == ConstantRefPos.outer) writeCastToType(writer, ctx, type);
	writer ~= '{';
	writer ~= memberIndex;
	if (!isEmptyType(ctx, type.as!(LowUnion*).members[memberIndex])) {
		writer ~= canUseAnonymousUnions(ctx) ? ", " : ", .u = { ";
		writer ~= ".as";
		writer ~= memberIndex;
		writer ~= " = ";
		cbWriteMember();
		if (!canUseAnonymousUnions(ctx))
			writer ~= " }";
	}
	writer ~= '}';
}

void writeFunPointer(scope ref Writer writer, scope ref Ctx ctx, LowFunIndex a) {
	writeLowFunMangledName(writer, ctx.mangledNames, a, ctx.program.allFuns[a]);
}

WriteExprResult writeSwitch(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type, // type returned by the switch
	in SwitchLowExpr a,
) {
	WriteExprResult valueResult = writeExprTempOrInline(writer, indent, ctx, a.value);
	WriteExprResultAndNested nested = getNestedWriteKind(writer, indent, ctx, type, castNonScope_ref(writeKind));
	writeNewline(writer, indent);
	writer ~= "switch (";
	writeTempOrInline(writer, ctx, a.value, valueResult);
	writer ~= ") {";

	void writeCaseOrDefault(in LowExpr expr) {
		cast(void) writeExpr(writer, indent + 2, ctx, nested.writeKind, expr);
		if (!nested.writeKind.isA!(WriteKind.Return)) {
			writeNewline(writer, indent + 2);
			writer ~= "break;";
		}
		writeNewline(writer, indent + 1);
		writer ~= '}';
	}

	foreach (size_t caseIndex, LowExpr caseExpr; a.caseExprs) {
		writeNewline(writer, indent + 1);
		writer ~= "case ";
		writeConstantIntegral(writer, ctx.ctx, a.value.type, a.caseValues[caseIndex]);
		writer ~= ": {";
		writeCaseOrDefault(caseExpr);
	}

	writeNewline(writer, indent + 1);
	writer ~= "default: {";
	writeCaseOrDefault(a.default_);
	writeNewline(writer, indent);
	writer ~= '}';
	return nested.result;
}

bool isSignedIntegral(PrimitiveType a) {
	final switch (a) {
		case PrimitiveType.char8:
		case PrimitiveType.char32:
		case PrimitiveType.float32:
		case PrimitiveType.float64:
		case PrimitiveType.void_:
			assert(false);
		case PrimitiveType.int8:
		case PrimitiveType.int16:
		case PrimitiveType.int32:
		case PrimitiveType.int64:
			return true;
		case PrimitiveType.bool_:
		case PrimitiveType.nat8:
		case PrimitiveType.nat16:
		case PrimitiveType.nat32:
		case PrimitiveType.nat64:
			return false;
	}
}

void writeRecordFieldRef(
	scope ref Writer writer,
	in FunBodyCtx ctx,
	bool targetIsPointer,
	in LowRecord record,
	size_t fieldIndex,
) {
	writer ~= targetIsPointer ? "->" : ".";
	writeMangledName(writer, ctx.mangledNames, debugName(record.fields[fieldIndex]));
}

// For some reason, providing a type for a record makes it non-constant.
// But that is mandatory at the outermost level.
enum ConstantRefPos {
	outer,
	inner,
}

void writeConstantRef(
	scope ref Writer writer,
	scope ref Ctx ctx,
	ConstantRefPos pos,
	in LowType type,
	in Constant a,
) {
	assert(!isEmptyType(ctx, type));
	a.matchIn!void(
		(in Constant.ArrConstant x) {
			if (pos == ConstantRefPos.outer) writeCastToType(writer, ctx, type);
			size_t size = ctx.program.allConstants.arrs[x.typeIndex].constants[x.index].length;
			writer ~= '{';
			writer ~= size;
			writer ~= ", ";
			if (size == 0)
				writer ~= "NULL";
			else
				writeConstantArrStorageName(writer, ctx.mangledNames, ctx.program, type.as!(LowRecord*), x.index);
			writer ~= '}';
		},
		(in Constant.CString x) {
			writeCStringName(writer, x.index);
		},
		(in Constant.Float x) {
			switch (type.as!PrimitiveType) {
				case PrimitiveType.float32:
					writeCastToType(writer, ctx, type);
					break;
				case PrimitiveType.float64:
					break;
				default:
					assert(false);
			}
			writeFloatLiteralForC(writer, x.value);
		},
		(in Constant.FunPointer x) {
			if (isPointerNonGc(type))
				writer ~= "((uint8_t*)";
			writeFunPointer(writer, ctx, mustGet(ctx.program.concreteFunToLowFunIndex, x.fun));
			if (isPointerNonGc(type))
				writer ~= ')';
		},
		(in IntegralValue x) {
			writeConstantIntegral(writer, ctx, type, x);
		},
		(in Constant.Pointer it) {
			writer ~= '&';
			writeConstantPointerStorageName(writer, ctx.mangledNames, ctx.program, asGcPointee(type), it.index);
		},
		(in Constant.Record it) {
			if (pos == ConstantRefPos.outer)
				writeCastToType(writer, ctx, type);
			writer ~= '{';
			writeWithCommasZip!(LowField, Constant)(
				writer,
				type.as!(LowRecord*).fields,
				it.args,
				(in LowField field, in Constant arg) =>
					!isEmptyType(ctx, field.type),
				(in LowField field, in Constant arg) {
					writeConstantRef(writer, ctx, ConstantRefPos.inner, field.type, arg);
				});
			writer ~= '}';
		},
		(in Constant.Union x) {
			writeCreateUnion(writer, ctx, pos, type, x.memberIndex, () {
				writeConstantRef(writer, ctx, ConstantRefPos.inner, type.as!(LowUnion*).members[x.memberIndex], x.arg);
			});
		},
		(in Constant.Zero) {
			writeZeroedValue(writer, ctx, type);
		});
}

void writeConstantIntegral(scope ref Writer writer, in Ctx ctx, in LowType type, IntegralValue a) {
	PrimitiveType primitive = type.as!PrimitiveType;
	if (primitive == PrimitiveType.char8 || primitive == PrimitiveType.char32) {
		if (!ctx.isMSVC && ctx.cVersion >= CVersion.c11 && isValidUnicodeCharacter(safeToUint(a.asUnsigned))) {
			writer ~= "'";
			writeEscapedCharForC(writer, safeToUint(a.asUnsigned));
			writer ~= "'";
		} else
			writer ~= a.asUnsigned;
	} else if (isSignedIntegral(primitive)) {
		if (a.value == int.min)
			writer ~= "INT32_MIN";
		else if (a.value == long.min)
			// Can't write this as a literal since the '-' and rest are parsed separately,
			// and the abs of the minimum integer is out of range.
			writer ~= "INT64_MIN";
		else {
			writer ~= a.asSigned;
			if (primitive == PrimitiveType.int64)
				writer ~= 'l';
		}
	} else {
		writer ~= a.asUnsigned;
		writer ~= 'u';
		if (primitive == PrimitiveType.nat64)
			writer ~= "ll";
	}
}

void writeStringLiteralWithoutNul(scope ref Writer writer, bool isMSVC, in string a) {
	writer ~= '"';
	writeStringLiteralInner(writer, isMSVC, a);
	writer ~= '"';
}

void writeStringLiteralWithNul(scope ref Writer writer, bool isMSVC, in string a) {
	writer ~= '"';
	writeStringLiteralInner(writer, isMSVC, a);
	writer ~= "\\0";
	writer ~= '"';
}

void writeStringLiteralInner(scope ref Writer writer, bool isMSVC, in string a) {
	size_t chunk = 0;
	mustUnicodeDecode(a, (dchar x) {
		writeEscapedCharForC(writer, x);
		if (isMSVC) {
			// Avoid error with MSVC: "error C2026: string too big, trailing characters truncated"
			chunk++;
			if (chunk == 2048) {
				writer ~= '"';
				writer ~= '"';
				chunk = 0;
			}
		}
	});
}

WriteExprResult writeRecordFieldPointer(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in RecordFieldPointerLowExpr a,
) =>
	writeInlineableSingleArg(writer, indent, ctx, writeKind, type, *a.target, (in WriteExprResult recordValue) {
		writer ~= "(&";
		writeTempOrInline(writer, ctx, *a.target, recordValue);
		writeRecordFieldRef(writer, ctx, true, *a.targetRecordType, a.fieldIndex);
		writer ~= ')';
	});

WriteExprResult writeRecordFieldGet(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in RecordFieldGetLowExpr a,
) =>
	writeInlineableSingleArg(writer, indent, ctx, writeKind, type, *a.target, (in WriteExprResult recordValue) {
		if (!isEmptyType(ctx, type)) {
			writeTempOrInline(writer, ctx, *a.target, recordValue);
			writeRecordFieldRef(writer, ctx, a.targetIsPointer, *a.targetRecordType, a.fieldIndex);
		}
	});

WriteExprResult writeUnionAs(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in UnionAsLowExpr a,
) =>
	writeInlineableSingleArg(writer, indent, ctx, writeKind, type, *a.union_, (in WriteExprResult unionValue) {
		if (!isEmptyType(ctx, type)) {
			writeTempOrInline(writer, ctx, *a.union_, unionValue);
			if (!canUseAnonymousUnions(ctx.ctx))
				writer ~= ".u";
			writer ~= ".as";
			writer ~= a.memberIndex;
		}
	});

WriteExprResult writeUnionKind(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in UnionKindLowExpr a,
) =>
	writeInlineableSingleArg(writer, indent, ctx, writeKind, type, *a.union_, (in WriteExprResult unionValue) {
		if (!isEmptyType(ctx, type)) {
			writeTempOrInline(writer, ctx, *a.union_, unionValue);
			writer ~= ".kind";
		}
	});

WriteExprResult writeSpecialUnary(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in SpecialUnaryLowExpr a,
) {
	WriteExprResult prefix(string prefix) =>
		writeInlineableSingleArg(writer, indent, ctx, writeKind, type, a.arg, (in WriteExprResult temp) {
			writer ~= '(';
			writer ~= prefix;
			writeTempOrInline(writer, ctx, a.arg, temp);
			writer ~= ')';
		});

	WriteExprResult convert(string to, string from) =>
		writeInlineableSingleArg(writer, indent, ctx, writeKind, type, a.arg, (in WriteExprResult temp) {
			writer ~= "((union _convert) { .";
			writer ~= from;
			writer ~= " = ";
			writeTempOrInline(writer, ctx, a.arg, temp);
			writer ~= " }.";
			writer ~= to;
			writer ~= ')';
		});

	WriteExprResult writeCast() =>
		writeInlineableSingleArg(writer, indent, ctx, writeKind, type, a.arg, (in WriteExprResult temp) {
			if (isEmptyType(ctx, a.arg.type))
				writeTempOrInline(writer, ctx, a.arg, temp);
			else {
				writer ~= '(';
				writeCastToType(writer, ctx.ctx, type);
				writeTempOrInline(writer, ctx, a.arg, temp);
				writer ~= ')';
			}
		});

	WriteExprResult specialCall(in string name) =>
		specialCallUnary(writer, indent, ctx, writeKind, type, a.arg, name);

	final switch (a.kind) {
		case BuiltinUnary.asFuture:
		case BuiltinUnary.asFutureImpl:
		case BuiltinUnary.asMutArray:
		case BuiltinUnary.asMutArrayImpl:
		case BuiltinUnary.arrayPointer:
		case BuiltinUnary.arraySize:
		case BuiltinUnary.cStringOfSymbol:
		case BuiltinUnary.symbolOfCString:
			// Done in lower
			assert(false);
		case BuiltinUnary.asAnyPointer:
			return prefix("(uint8_t*) ");
		case BuiltinUnary.bitsOfFloat32:
			return convert(to: "nat32", from: "float32");
		case BuiltinUnary.bitsOfFloat64:
			return convert(to: "nat64", from: "float64");
		case BuiltinUnary.deref:
			return prefix("*");
		case BuiltinUnary.drop:
			return a.arg.kind.isA!Constant ? writeVoid(writeKind) : writeCast();
		case BuiltinUnary.float32FromBits:
			return convert(to: "float32", from: "nat32");
		case BuiltinUnary.float64FromBits:
			return convert(to: "float64", from: "nat64");
		case BuiltinUnary.isNanFloat32:
		case BuiltinUnary.isNanFloat64:
			return specialCall(ctx.isMSVC ? "isnan" : "__builtin_isnan");
		case BuiltinUnary.referenceFromPointer:
		case BuiltinUnary.toChar8FromNat8:
		case BuiltinUnary.toFloat32FromFloat64:
		case BuiltinUnary.toFloat64FromFloat32:
		case BuiltinUnary.toFloat64FromInt64:
		case BuiltinUnary.toFloat64FromNat64:
		case BuiltinUnary.toInt64FromInt8:
		case BuiltinUnary.toInt64FromInt16:
		case BuiltinUnary.toInt64FromInt32:
		case BuiltinUnary.toNat8FromChar8:
		case BuiltinUnary.toNat32FromChar32:
		case BuiltinUnary.toNat64FromNat8:
		case BuiltinUnary.toNat64FromNat16:
		case BuiltinUnary.toNat64FromNat32:
		case BuiltinUnary.toNat64FromPtr:
		case BuiltinUnary.toPtrFromNat64:
		case BuiltinUnary.truncateToInt64FromFloat64:
		case BuiltinUnary.unsafeToChar32FromChar8:
		case BuiltinUnary.unsafeToChar32FromNat32:
		case BuiltinUnary.unsafeToInt8FromInt64:
		case BuiltinUnary.unsafeToInt16FromInt64:
		case BuiltinUnary.unsafeToInt32FromInt64:
		case BuiltinUnary.unsafeToInt64FromNat64:
		case BuiltinUnary.unsafeToNat8FromNat64:
		case BuiltinUnary.unsafeToNat16FromNat64:
		case BuiltinUnary.unsafeToNat32FromInt32:
		case BuiltinUnary.unsafeToNat32FromNat64:
		case BuiltinUnary.unsafeToNat64FromInt64:
			return writeCast();
		case BuiltinUnary.bitwiseNotNat8:
		case BuiltinUnary.bitwiseNotNat16:
		case BuiltinUnary.bitwiseNotNat32:
		case BuiltinUnary.bitwiseNotNat64:
			return prefix("~");
		case BuiltinUnary.countOnesNat64:
			return specialCall(ctx.isMSVC ? "__popcnt64" : "__builtin_popcountl");
		case BuiltinUnary.not:
			return prefix("!");
		case BuiltinUnary.jumpToCatch:
			return specialCall("jump_to_catch");
		case BuiltinUnary.setupCatch:
			return specialCall("setup_catch");
		// Concretize removes these calls
		case BuiltinUnary.toChar8ArrayFromString:
		case BuiltinUnary.trustAsString:
			assert(false);
	}
}

WriteExprResult specialCallUnary(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in LowExpr arg,
	in string name,
) =>
	writeInlineableSingleArg(
		writer, indent, ctx, writeKind, type, arg,
		(in WriteExprResult temp) {
			writer ~= name;
			writer ~= '(';
			writeTempOrInline(writer, ctx, arg, temp);
			writer ~= ')';
		});

WriteExprResult specialCallBinary(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in LowExpr[2] args,
	in string name,
) =>
	specialCallNary(writer, indent, ctx, writeKind, type, castNonScope_ref(args), name);

WriteExprResult specialCallNary(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in LowExpr[] args,
	in string name,
) =>
	writeInlineable(
		writer, indent, ctx, writeKind, type, args,
		(in WriteExprResult[] temps) {
			writer ~= name;
			writer ~= '(';
			writeTempOrInlines(writer, ctx, args, temps);
			writer ~= ')';
		});

void writeZeroedValue(scope ref Writer writer, scope ref Ctx ctx, in LowType type) {
	type.combinePointer.matchIn!void(
		(in LowExternType _) {
			writeCastToType(writer, ctx, type);
			writer ~= "{{0}}";
		},
		(in LowFunPointerType _) {
			writer ~= "NULL";
		},
		(in PrimitiveType x) {
			assert(x != PrimitiveType.void_);
			writer ~= '0';
		},
		(in LowPointerCombine _) {
			writer ~= "NULL";
		},
		(in LowRecord x) {
			writeCastToType(writer, ctx, type);
			writer ~= '{';
			writeWithCommas!LowField(
				writer,
				x.fields,
				(in LowField field) =>
					!isEmptyType(ctx, field.type),
				(in LowField field) {
					writeZeroedValue(writer, ctx, field.type);
				});
			writer ~= '}';
		},
		(in LowUnion _) {
			writeCastToType(writer, ctx, type);
			writer ~= "{0}";
		});
}

WriteExprResult writeSpecialBinary(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in SpecialBinaryLowExpr a,
) {
	LowExpr left = a.args[0], right = a.args[1];
	WriteExprResult arg0() =>
		writeExprTempOrInline(writer, indent, ctx, left);
	WriteExprResult arg1() =>
		writeExprTempOrInline(writer, indent, ctx, right);

	WriteExprResult operator(string op) =>
		writeInlineable(
			writer, indent, ctx, writeKind, type, [castNonScope_ref(left), castNonScope_ref(right)],
			(in WriteExprResult[] args) {
				assert(args.length == 2);
				writer ~= '(';
				writeTempOrInline(writer, ctx, left, args[0]);
				writer ~= ' ';
				writer ~= op;
				writer ~= ' ';
				writeTempOrInline(writer, ctx, right, args[1]);
				writer ~= ')';
			});

	final switch (a.kind) {
		case BuiltinBinary.addFloat32:
		case BuiltinBinary.addFloat64:
		case BuiltinBinary.addPointerAndNat64:
		case BuiltinBinary.unsafeAddInt8:
		case BuiltinBinary.unsafeAddInt16:
		case BuiltinBinary.unsafeAddInt32:
		case BuiltinBinary.unsafeAddInt64:
		case BuiltinBinary.unsafeAddNat8:
		case BuiltinBinary.unsafeAddNat16:
		case BuiltinBinary.unsafeAddNat32:
		case BuiltinBinary.unsafeAddNat64:
		case BuiltinBinary.wrapAddNat8:
		case BuiltinBinary.wrapAddNat16:
		case BuiltinBinary.wrapAddNat32:
		case BuiltinBinary.wrapAddNat64:
			return operator("+");
		case BuiltinBinary.bitwiseAndInt8:
		case BuiltinBinary.bitwiseAndInt16:
		case BuiltinBinary.bitwiseAndInt32:
		case BuiltinBinary.bitwiseAndInt64:
		case BuiltinBinary.bitwiseAndNat8:
		case BuiltinBinary.bitwiseAndNat16:
		case BuiltinBinary.bitwiseAndNat32:
		case BuiltinBinary.bitwiseAndNat64:
			return operator("&");
		case BuiltinBinary.bitwiseOrInt8:
		case BuiltinBinary.bitwiseOrInt16:
		case BuiltinBinary.bitwiseOrInt32:
		case BuiltinBinary.bitwiseOrInt64:
		case BuiltinBinary.bitwiseOrNat8:
		case BuiltinBinary.bitwiseOrNat16:
		case BuiltinBinary.bitwiseOrNat32:
		case BuiltinBinary.bitwiseOrNat64:
			return operator("|");
		case BuiltinBinary.bitwiseXorInt8:
		case BuiltinBinary.bitwiseXorInt16:
		case BuiltinBinary.bitwiseXorInt32:
		case BuiltinBinary.bitwiseXorInt64:
		case BuiltinBinary.bitwiseXorNat8:
		case BuiltinBinary.bitwiseXorNat16:
		case BuiltinBinary.bitwiseXorNat32:
		case BuiltinBinary.bitwiseXorNat64:
			return operator("^");
		case BuiltinBinary.equalChar8:
		case BuiltinBinary.equalChar32:
		case BuiltinBinary.equalFloat32:
		case BuiltinBinary.equalFloat64:
		case BuiltinBinary.equalInt8:
		case BuiltinBinary.equalInt16:
		case BuiltinBinary.equalInt32:
		case BuiltinBinary.equalInt64:
		case BuiltinBinary.equalNat8:
		case BuiltinBinary.equalNat16:
		case BuiltinBinary.equalNat32:
		case BuiltinBinary.equalNat64:
		case BuiltinBinary.equalPointer:
		case BuiltinBinary.referenceEqual:
			return operator("==");
		case BuiltinBinary.lessChar8:
		case BuiltinBinary.lessFloat32:
		case BuiltinBinary.lessFloat64:
		case BuiltinBinary.lessInt8:
		case BuiltinBinary.lessInt16:
		case BuiltinBinary.lessInt32:
		case BuiltinBinary.lessInt64:
		case BuiltinBinary.lessNat8:
		case BuiltinBinary.lessNat16:
		case BuiltinBinary.lessNat32:
		case BuiltinBinary.lessNat64:
		case BuiltinBinary.lessPointer:
			return operator("<");
		case BuiltinBinary.mulFloat32:
		case BuiltinBinary.mulFloat64:
		case BuiltinBinary.unsafeMulInt8:
		case BuiltinBinary.unsafeMulInt16:
		case BuiltinBinary.unsafeMulInt32:
		case BuiltinBinary.unsafeMulInt64:
		case BuiltinBinary.unsafeMulNat8:
		case BuiltinBinary.unsafeMulNat16:
		case BuiltinBinary.unsafeMulNat32:
		case BuiltinBinary.unsafeMulNat64:
		case BuiltinBinary.wrapMulNat8:
		case BuiltinBinary.wrapMulNat16:
		case BuiltinBinary.wrapMulNat32:
		case BuiltinBinary.wrapMulNat64:
			return operator("*");
		case BuiltinBinary.newArray:
			assert(false);
		case BuiltinBinary.seq:
			if (!writeKind.isA!(WriteKind.Inline))
				writeExprVoid(writer, indent, ctx, left);
			return writeExpr(writer, indent, ctx, writeKind, right);
		case BuiltinBinary.subFloat32:
		case BuiltinBinary.subFloat64:
		case BuiltinBinary.subPointerAndNat64:
		case BuiltinBinary.unsafeSubInt8:
		case BuiltinBinary.unsafeSubInt16:
		case BuiltinBinary.unsafeSubInt32:
		case BuiltinBinary.unsafeSubInt64:
		case BuiltinBinary.unsafeSubNat8:
		case BuiltinBinary.unsafeSubNat16:
		case BuiltinBinary.unsafeSubNat32:
		case BuiltinBinary.unsafeSubNat64:
		case BuiltinBinary.wrapSubNat8:
		case BuiltinBinary.wrapSubNat16:
		case BuiltinBinary.wrapSubNat32:
		case BuiltinBinary.wrapSubNat64:
			return operator("-");
		case BuiltinBinary.switchFiber:
			// defined in writeToC_boiilerplace.c
			return specialCallBinary(writer, indent, ctx, writeKind, type, a.args, "switch_fiber");
		case BuiltinBinary.unsafeBitShiftLeftNat64:
			return operator("<<");
		case BuiltinBinary.unsafeBitShiftRightNat64:
			return operator(">>");
		case BuiltinBinary.unsafeDivFloat32:
		case BuiltinBinary.unsafeDivFloat64:
		case BuiltinBinary.unsafeDivInt8:
		case BuiltinBinary.unsafeDivInt16:
		case BuiltinBinary.unsafeDivInt32:
		case BuiltinBinary.unsafeDivInt64:
		case BuiltinBinary.unsafeDivNat8:
		case BuiltinBinary.unsafeDivNat16:
		case BuiltinBinary.unsafeDivNat32:
		case BuiltinBinary.unsafeDivNat64:
			return operator("/");
		case BuiltinBinary.unsafeModNat64:
			return operator("%");
		case BuiltinBinary.writeToPointer:
			WriteExprResult temp0 = arg0();
			WriteExprResult temp1 = arg1();
			return writeReturnVoid(writer, indent, ctx, writeKind, () {
				if (!isEmptyType(ctx, right.type)) {
					writer ~= "*";
					writeTempOrInline(writer, ctx, left, temp0);
					writer ~= " = ";
					writeTempOrInline(writer, ctx, right, temp1);
				}
			});
	}
}

immutable struct WriteExprResultAndNested {
	WriteExprResult result;
	WriteKind writeKind;
}

// If we need to make a temporary, have to do that in an outer scope and write to it in an inner scope
WriteExprResultAndNested getNestedWriteKind(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in LowType type,
	return scope ref WriteKind writeKind,
) {
	if (isEmptyType(ctx, type)) {
		assert(writeKind.isA!(WriteKind.Void) ||
			writeKind.isA!(WriteKind.Return) ||
			writeKind.isA!(LoopInfo*) ||
			writeKind.isA!(WriteKind.InlineOrTemp));
		return WriteExprResultAndNested(writeExprDone(), writeKind);
	} else if (writeKind.isA!(WriteKind.MakeTemp) || writeKind.isA!(WriteKind.InlineOrTemp)) {
		Temp temp = getNextTemp(ctx);
		writeTempDeclare(writer, ctx, type, temp);
		writer ~= ';';
		writeNewline(writer, indent);
		return WriteExprResultAndNested(WriteExprResult(temp), WriteKind(WriteKind.UseTemp(temp)));
	} else
		return WriteExprResultAndNested(writeExprDone(), writeKind);
}

WriteExprResult writeIf(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in IfLowExpr a,
) {
	// TODO: writeExprTempOrInline
	Temp temp0 = writeExprTemp(writer, indent, ctx, a.cond);
	WriteExprResultAndNested nested = getNestedWriteKind(writer, indent, ctx, type, castNonScope_ref(writeKind));
	writeNewline(writer, indent);
	writer ~= "if (";
	writeTempRef(writer, temp0);
	writer ~= ") {";
	cast(void) writeExpr(writer, indent + 1, ctx, nested.writeKind, a.then);
	writeNewline(writer, indent);
	writer ~= "} else {";
	cast(void) writeExpr(writer, indent + 1, ctx, nested.writeKind, a.else_);
	writeNewline(writer, indent);
	writer ~= '}';
	return nested.result;
}

WriteExprResult writeInit(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in InitLowExpr a,
) {
	if (useStructThreadLocals(ctx.ctx)) {
		writeNewline(writer, indent);
		writer ~= () {
			final switch (a.kind) {
				case BuiltinFunInitKind.global:
					return ctx.isMSVC
						? "THREAD_LOCALS_INDEX = TlsAlloc();"
						: "";
				case BuiltinFunInitKind.perThread:
					return ctx.isMSVC
						? "TlsSetValue(THREAD_LOCALS_INDEX, " ~
							"(struct ThreadLocals*) calloc(1, sizeof(struct ThreadLocals)));"
						: "__threadLocals = (struct ThreadLocals*) calloc(1, sizeof(struct ThreadLocals));";
			}
		}();
	} // No init needed otherwise
	return writeReturnVoid(writer, indent, ctx, writeKind);
}

WriteExprResult writeCallFunPointer(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in CallFunPointerLowExpr a,
) {
	WriteExprResult fn = writeExprTempOrInline(writer, indent, ctx, *a.funPtr);
	WriteExprResult[] args = writeExprsTempOrInline(writer, indent, ctx, a.args);
	return writeNonInlineable(writer, indent, ctx, writeKind, type, () {
		writeTempOrInline(writer, ctx, *a.funPtr, fn);
		writer ~= '(';
		writeTempOrInlines(writer, ctx, a.args, args);
		writer ~= ')';
	});
}

WriteExprResult writeLet(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LetLowExpr a,
) {
	if (!writeKind.isA!(WriteKind.Inline)) {
		if (isEmptyType(ctx, a.local.type))
			writeExprVoid(writer, indent, ctx, a.value);
		else {
			writeDeclareLocal(writer, indent, ctx, *a.local);
			WriteKind localWriteKind = WriteKind(a.local);
			cast(void) writeExpr(writer, indent, ctx, localWriteKind, a.value);
			writeNewline(writer, indent);
		}
	}
	return writeExpr(writer, indent, ctx, writeKind, a.then);
}

WriteExprResult writeLocalSet(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LocalSetLowExpr a,
) {
	if (isEmptyType(ctx, a.local.type))
		writeExprVoid(writer, indent, ctx, a.value);
	else {
		WriteKind localWriteKind = WriteKind(a.local);
		cast(void) writeExpr(writer, indent, ctx, localWriteKind, a.value);
	}
	return writeReturnVoid(writer, indent, ctx, writeKind);
}

WriteExprResult writeLoop(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LowType type,
	in LoopLowExpr a,
) {
	WriteExprResultAndNested nested = getNestedWriteKind(writer, indent, ctx, type, castNonScope_ref(writeKind));

	size_t index = nextLoopIndex(ctx);
	LoopInfo loopInfo = LoopInfo(index, nested.writeKind);

	writeNewline(writer, indent);
	writer ~= "__loop";
	writer ~= index;
	// Since the next line might declare a variable,
	// use ';' to avoid the error 'A label can only be part of a statement and a declaration is not a statement'.
	writer ~= ":;";
	writeNewline(writer, indent);

	WriteKind bodyWriteKind = WriteKind(&loopInfo);
	WriteExprResult bodyResult = writeExpr(writer, indent, ctx, bodyWriteKind, a.body_);
	assert(bodyResult.isA!(WriteExprResult.Done));
	return nested.result;
}

WriteExprResult writeLoopBreak(
	scope ref Writer writer,
	size_t indent,
	scope ref FunBodyCtx ctx,
	in WriteKind writeKind,
	in LoopBreakLowExpr a,
) {
	cast(void) writeExpr(writer, indent, ctx, writeKind.as!(LoopInfo*).writeKind, a.value);
	return writeExprDone;
}

WriteExprResult writeLoopContinue(scope ref Writer writer, size_t indent, in WriteKind writeKind) {
	writeNewline(writer, indent);
	writer ~= "goto __loop";
	writer ~= writeKind.as!(LoopInfo*).index;
	writer ~= ';';
	return writeExprDone;
}

void writePrimitiveType(scope ref Writer writer, PrimitiveType a) {
	writer ~= () {
		final switch (a) {
			case PrimitiveType.bool_:
				return "_Bool";
			case PrimitiveType.char8:
				return "char";
			case PrimitiveType.char32:
				return "char32_t";
			case PrimitiveType.float32:
				return "float";
			case PrimitiveType.float64:
				return "double";
			case PrimitiveType.int8:
				return "int8_t";
			case PrimitiveType.int16:
				return "int16_t";
			case PrimitiveType.int32:
				return "int32_t";
			case PrimitiveType.int64:
				return "int64_t";
			case PrimitiveType.nat8:
				return "uint8_t";
			case PrimitiveType.nat16:
				return "uint16_t";
			case PrimitiveType.nat32:
				return "uint32_t";
			case PrimitiveType.nat64:
				return "uint64_t";
			case PrimitiveType.void_:
				return "void";
		}
	}();
}
