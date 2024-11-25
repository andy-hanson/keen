module backend.jit;

@safe @nogc nothrow: // not pure

version (GccJitAvailable) {

import backend.builtinMath : builtinForBinaryMath, builtinForUnaryMath, BuiltinFunction;
import backend.gccTypes :
	assertFieldOffsetsFunctionName,
	AssertFieldOffsetsType,
	ExternTypeArrayInfo,
	ExternTypeInfo,
	GccTypes,
	generateAssertFieldOffsetsFunction,
	getGccType,
	getGccTypes,
	UnionFields;
import backend.libgccjit :
	gcc_jit_binary_op,
	gcc_jit_block,
	gcc_jit_block_add_assignment,
	gcc_jit_block_add_eval,
	gcc_jit_block_end_with_conditional,
	gcc_jit_block_end_with_jump,
	gcc_jit_block_end_with_return,
	gcc_jit_block_end_with_switch,
	gcc_jit_bool_option,
	gcc_jit_case,
	gcc_jit_comparison,
	gcc_jit_context,
	gcc_jit_context_acquire,
	gcc_jit_context_add_driver_option,
	gcc_jit_context_add_top_level_asm,
	gcc_jit_context_compile,
	gcc_jit_context_compile_to_file,
	gcc_jit_context_get_first_error,
	gcc_jit_context_get_type,
	gcc_jit_context_new_array_access,
	gcc_jit_context_new_array_constructor,
	gcc_jit_context_new_array_type,
	gcc_jit_context_new_binary_op,
	gcc_jit_context_get_builtin_function,
	gcc_jit_context_new_comparison,
	gcc_jit_context_new_call,
	gcc_jit_context_new_call_through_ptr,
	gcc_jit_context_new_case,
	gcc_jit_context_new_cast,
	gcc_jit_context_new_field,
	gcc_jit_context_new_function,
	gcc_jit_context_new_function_ptr_type,
	gcc_jit_context_new_global,
	gcc_jit_context_new_param,
	gcc_jit_context_new_rvalue_from_double,
	gcc_jit_context_new_rvalue_from_long,
	gcc_jit_context_new_string_literal,
	gcc_jit_context_new_unary_op,
	gcc_jit_context_new_union_type,
	gcc_jit_context_null,
	gcc_jit_context_release,
	gcc_jit_context_set_bool_option,
	gcc_jit_context_set_int_option,
	gcc_jit_context_zero,
	gcc_jit_field,
	gcc_jit_fn_attribute,
	gcc_jit_function,
	gcc_jit_function_add_attribute,
	gcc_jit_function_get_address,
	gcc_jit_function_get_param,
	gcc_jit_function_kind,
	gcc_jit_function_new_block,
	gcc_jit_function_new_local,
	gcc_jit_global_kind,
	gcc_jit_int_option,
	gcc_jit_lvalue,
	gcc_jit_lvalue_access_field,
	gcc_jit_lvalue_as_rvalue,
	gcc_jit_lvalue_get_address,
	gcc_jit_lvalue_set_tls_model,
	gcc_jit_output_kind,
	gcc_jit_param,
	gcc_jit_param_as_lvalue,
	gcc_jit_param_as_rvalue,
	gcc_jit_result,
	gcc_jit_result_get_code,
	gcc_jit_result_release,
	gcc_jit_rvalue,
	gcc_jit_rvalue_access_field,
	gcc_jit_rvalue_dereference,
	gcc_jit_rvalue_dereference_field,
	gcc_jit_tls_model,
	gcc_jit_type,
	gcc_jit_type_get_pointer,
	gcc_jit_type_get_volatile,
	gcc_jit_types,
	gcc_jit_unary_op;
import backend.mangle :
	buildMangledNames,
	MangledNames,
	writeConstantArrStorageName,
	writeConstantPointerStorageName,
	writeLowLocalName,
	writeLowFunMangledName,
	writeLowVarMangledName;
import backend.writeToC : getLinkOptions;
import frontend.showModel : ShowCtx;
import frontend.lang : JitOptions, OptimizationLevel;
import model.concreteModel : isCatchPoint;
import model.constant : Constant;
import model.lowModel :
	AbortLowExpr,
	ArrTypeAndConstantsLow,
	CallFunPointerLowExpr,
	CallLowExpr,
	CreateRecordLowExpr,
	CreateUnionLowExpr,
	FunPointerLowExpr,
	IfLowExpr,
	InitLowExpr,
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
	LowFun,
	LowFunBody,
	LowFunExprBody,
	LowFunIndex,
	LowFunPointerType,
	LowLocal,
	LowPointerCombine,
	LowProgram,
	LowRecord,
	LowUnion,
	LowVar,
	LowVarIndex,
	LowType,
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
import model.model : Builtin4ary, BuiltinBinary, BuiltinFun, BuiltinTernary, BuiltinUnary;
import model.showLowModel : writeFunSig;
import util.alloc.alloc : Alloc, withTempAlloc;
import util.col.array : fillArray, indexOfPointer, isEmpty, map, mapStatic, mapWithIndex, zip;
import util.col.enumMap : EnumMap, makeEnumMap;
import util.col.map : mustGet;
import util.col.fullIndexMap : FullIndexMap, fullIndexMapZip, mapFullIndexMap_mut;
import util.col.stackMap : StackMap, stackMapAdd, stackMapMustGet, withStackMap;
import util.conv : safeToInt;
import util.exitCode : ExitCode;
import util.integralValues : IntegralValue;
import util.opt : force, has, MutOpt, none, noneMut, Opt, some, someMut;
import util.perf : Perf, PerfMeasure, withMeasure;
import util.string : CString;
import util.union_ : TaggedUnion;
import util.util : castImmutable, castNonScope_ref, cStringOfEnum, debugLog, ptrTrustMe, todo;
import util.writer : debugLogWithWriter, withWriter, Writer;

@trusted ExitCode jitAndRun(
	scope ref Perf perf,
	ref Alloc alloc,
	in ShowCtx showCtx,
	in LowProgram program,
	in JitOptions options,
	in CString[] allArgs,
) {
	GccProgram gccProgram = getGccProgram(perf, alloc, showCtx, program, options);

	//TODO: perf measure this?
	AssertFieldOffsetsType assertFieldOffsets = cast(AssertFieldOffsetsType)
		gcc_jit_result_get_code(gccProgram.result, assertFieldOffsetsFunctionName);
	assert(assertFieldOffsets != null);

	//TODO
	if (false) {
		gcc_jit_context_compile_to_file(
			*gccProgram.ctx,
			gcc_jit_output_kind.GCC_JIT_OUTPUT_KIND_EXECUTABLE,
			"GCCJITOUT");
		return ExitCode.ok;
	}

	MainType main = withMeasure!(MainType, () @trusted =>
		cast(MainType) gcc_jit_result_get_code(gccProgram.result, "main")
	)(perf, alloc, PerfMeasure.gccJit);
	assert(main != null);
	gcc_jit_context_release(gccProgram.ctx);

	bool fieldOffsetsCorrect = assertFieldOffsets();
	assert(fieldOffsetsCorrect);
	int exitCode = runMain(perf, alloc, allArgs, main);
	gcc_jit_result_release(gccProgram.result);
	return ExitCode(exitCode);
}

private:

int runMain(scope ref Perf perf, ref Alloc alloc, in CString[] allArgs, MainType main) =>
	withMeasure!(int, () @trusted =>
		main(safeToInt(allArgs.length), cast(immutable char**) allArgs.ptr)
	)(perf, alloc, PerfMeasure.run);

pure:


struct GccProgram {
	gcc_jit_context* ctx;
	immutable gcc_jit_result* result;
}

GccProgram getGccProgram(
	scope ref Perf perf,
	ref Alloc alloc,
	in ShowCtx showCtx,
	in LowProgram program,
	in JitOptions options,
) {
	gcc_jit_context* ctx = gcc_jit_context_acquire();
	assert(ctx != null);

	gcc_jit_context_set_bool_option(*ctx, gcc_jit_bool_option.GCC_JIT_BOOL_OPTION_DEBUGINFO, true);
	final switch (options.optimization) {
		case OptimizationLevel.none:
			break;
		case OptimizationLevel.o2:
			gcc_jit_context_set_int_option(*ctx, gcc_jit_int_option.GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, 2);
			todo!void("TODO: Optimization requires 'gcc_jit_function_add_attribute' to prevent inlining fiber switch");
			break;
	}
	//gcc_jit_context_set_bool_option(*ctx, gcc_jit_bool_option.GCC_JIT_BOOL_OPTION_DUMP_INITIAL_GIMPLE, true);
	//gcc_jit_context_set_bool_option(*ctx, gcc_jit_bool_option.GCC_JIT_BOOL_OPTION_DUMP_GENERATED_CODE, true);

	getLinkOptions(alloc, isMSVC: false, program.externLibraries, (CString x) {
		gcc_jit_context_add_driver_option(*ctx, x.ptr);
	});

	withMeasure!(void, () {
		buildGccProgram(alloc, showCtx, *ctx, program);
	})(perf, alloc, PerfMeasure.gccCreateProgram);

	assert(gcc_jit_context_get_first_error(*ctx) == null);

	immutable gcc_jit_result* result = withMeasure!(immutable gcc_jit_result*, () =>
		gcc_jit_context_compile(*ctx)
	)(perf, alloc, PerfMeasure.gccCompile);

	const char* error = gcc_jit_context_get_first_error(*ctx);
	if (error != null)
		debugLog(error);
	assert(result != null);
	return GccProgram(ctx, result);
}

extern(C) {
	alias MainType = immutable int function(int, immutable char**) @nogc nothrow;
}

void buildGccProgram(ref Alloc alloc, in ShowCtx showCtx, ref gcc_jit_context ctx, in LowProgram program) {
	scope MangledNames mangledNames = buildMangledNames(alloc, program);
	GccTypes gccTypes = getGccTypes(alloc, ctx, program, mangledNames);

	//TODO:only in debug
	generateAssertFieldOffsetsFunction(alloc, ctx, program, gccTypes);

	GlobalsForConstants globalsForConstants = generateGlobalsForConstants(alloc, ctx, program, gccTypes, mangledNames);
	GccVars gccVars = generateGccVars(alloc, ctx, program, gccTypes, mangledNames);

	immutable gcc_jit_type* crowVoidType = getGccType(gccTypes, LowType(PrimitiveType.void_));
	gcc_jit_rvalue* globalVoid = gcc_jit_lvalue_as_rvalue(
		gcc_jit_context_new_global(
			ctx,
			null,
			gcc_jit_global_kind.GCC_JIT_GLOBAL_INTERNAL,
			crowVoidType,
			"void"));

	//immutable FullIndexMap!(LowFunIndex, LowFun) allFuns;
	FullIndexMap!(LowFunIndex, gcc_jit_function*) gccFuns =
		mapFullIndexMap_mut!(LowFunIndex, gcc_jit_function*, LowFun)(
			alloc,
			program.allFuns,
			(LowFunIndex funIndex, in LowFun fun) =>
				toGccFunctionSignature(alloc, ctx, program, mangledNames, gccTypes, funIndex, fun));

	immutable gcc_jit_type* boolType = getGccType(gccTypes, LowType(PrimitiveType.bool_));
	immutable gcc_jit_type* nat64Type = getGccType(gccTypes, LowType(PrimitiveType.nat64));
	immutable gcc_jit_function* abortFunction = makeFunction(
		ctx, crowVoidType, "abort", [], gcc_jit_function_kind.GCC_JIT_FUNCTION_IMPORTED);
	BuiltinFunctions builtinFunctions = generateBuiltinFunctions(ctx);
	ConversionFunctions conversionFunctions = generateConversionFunctions(ctx);

	immutable gcc_jit_type* voidPointerType = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_VOID_PTR);
	immutable gcc_jit_type* fiberReferenceType = getGccType(gccTypes, program.commonTypes.fiberReference);
	immutable gcc_jit_function* jumpToCatchFunction = makeJumpToCatchFunction(ctx, crowVoidType, voidPointerType);
	immutable gcc_jit_function* setupCatchFunction = makeSetupCatchFunction(ctx, boolType, voidPointerType);
	immutable gcc_jit_function* switchFiberFunction = makeSwitchFiberFunction(ctx, crowVoidType);
	immutable gcc_jit_function* switchFiberInitialFunction = makeSwitchFiberInitialFunction(
		ctx, crowVoidType, fiberReferenceType);

	// Now fill in the body of every function.
	fullIndexMapZip!(LowFunIndex, LowFun, gcc_jit_function*)(
		program.allFuns,
		gccFuns,
		(LowFunIndex funIndex, ref LowFun fun, ref gcc_jit_function* curFun) {
		fun.body_.match!void(
			(LowFunBody.Extern it) {},
			(LowFunExprBody expr) {
				gcc_jit_block* entryBlock = gcc_jit_function_new_block(curFun, "entry");
				ExprCtx exprCtx = ExprCtx(
					allocPtr: ptrTrustMe(alloc),
					programPtr: ptrTrustMe(program),
					gccPtr: ptrTrustMe(ctx),
					mangledNamesPtr: ptrTrustMe(mangledNames),
					typesPtr: ptrTrustMe(gccTypes),
					globalsForConstantsPtr: ptrTrustMe(globalsForConstants),
					gccVarsPtr: ptrTrustMe(gccVars),
					gccFuns: gccFuns,
					curLowFun: ptrTrustMe(fun),
					curFun: curFun,
					entryBlock: entryBlock,
					curBlock: entryBlock,
					nat64Type: nat64Type,
					abortFunction: abortFunction,
					jumpToCatchFunction: jumpToCatchFunction,
					setupCatchFunction: setupCatchFunction,
					switchFiberFunction: switchFiberFunction,
					switchFiberInitialFunction: switchFiberInitialFunction,
					builtinFunctionsPtr: &builtinFunctions,
					conversionFunctionsPtr: &conversionFunctions,
					globalVoid: globalVoid);

				if (isStubFunction(funIndex)) {
					debugLogWithWriter((scope ref Writer writer) {
						writer ~= "Stub ";
						writer ~= funIndex.index;
						writeFunSig(writer, showCtx, program, fun);
					});
					gcc_jit_block_end_with_return(exprCtx.curBlock, null, arbitraryValue(exprCtx, expr.expr.type));
				} else {
					ExprEmit emit = ExprEmit(ExprEmit.Return());
					ExprResult result = withStackMap!(ExprResult, LowLocal*, gcc_jit_lvalue*)((ref Locals locals) =>
						toGccExpr(exprCtx, locals, emit, expr.expr));
					result.match!void(
						(ExprResult.BreakContinueOrReturn) {},
						(ref gcc_jit_rvalue) => assert(false),
						(ExprResult.Void) {});
				}

				scope immutable char* err = gcc_jit_context_get_first_error(ctx);
				if (err != null)
					debugLogWithWriter((ref Writer writer) @trusted {
						writer ~= "Error: ";
						writer ~= CString(err);
					});
				assert(err == null);
			});
	});
}

//TODO:KILL
bool isStubFunction(LowFunIndex _) =>
	false;

alias BuiltinFunctions = EnumMap!(BuiltinFunction, immutable gcc_jit_function*);
BuiltinFunctions generateBuiltinFunctions(ref gcc_jit_context ctx) =>
	makeEnumMap((BuiltinFunction x) =>
		gcc_jit_context_get_builtin_function(ctx, cStringOfEnum(x).ptr));

immutable struct ConversionFunctions {
	gcc_jit_function* ptrToNat64;
	gcc_jit_function* nat64ToPtr;
	gcc_jit_function* bitsOfFloat32;
	gcc_jit_function* bitsOfFloat64;
	gcc_jit_function* float32FromBits;
	gcc_jit_function* float64FromBits;
}

@trusted ConversionFunctions generateConversionFunctions(ref gcc_jit_context ctx) {
	immutable gcc_jit_type* voidPtrType = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_VOID_PTR);
	immutable gcc_jit_type* float32Type = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_FLOAT);
	immutable gcc_jit_type* float64Type = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_DOUBLE);
	immutable gcc_jit_type* nat32Type = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_INT);
	immutable gcc_jit_type* nat64Type = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_LONG);

	immutable gcc_jit_field* float32Field = gcc_jit_context_new_field(ctx, null, float32Type, "float32");
	immutable gcc_jit_field* float64Field = gcc_jit_context_new_field(ctx, null, float64Type, "float64");
	immutable gcc_jit_field* nat32Field = gcc_jit_context_new_field(ctx, null, nat32Type, "nat32");
	immutable gcc_jit_field* nat64Field = gcc_jit_context_new_field(ctx, null, nat64Type, "nat64");
	immutable gcc_jit_field* ptrField = gcc_jit_context_new_field(ctx, null, voidPtrType, "ptr");
	immutable gcc_jit_field*[5] fields = [float32Field, float64Field, nat32Field, nat64Field, ptrField];

	immutable gcc_jit_type* unionType =
		gcc_jit_context_new_union_type(ctx, null, "__ptrToNat64Converter", fields.length, fields.ptr);
	return ConversionFunctions(
		ptrToNat64: makeConversionFunction(
			ctx, "__ptrToNat64", unionType, voidPtrType, ptrField, nat64Type, nat64Field),
		nat64ToPtr: makeConversionFunction(
			ctx, "__nat64ToPtr", unionType, nat64Type, nat64Field, voidPtrType, ptrField),
		bitsOfFloat32: makeConversionFunction(
			ctx, "__bitsOfFloat32", unionType, float32Type, float32Field, nat32Type, nat32Field),
		bitsOfFloat64: makeConversionFunction(
			ctx, "__bitsOfFloat64", unionType, float64Type, float64Field, nat64Type, nat64Field),
		float32FromBits: makeConversionFunction(
			ctx, "__float32FromBits", unionType, nat32Type, nat32Field, float32Type, float32Field),
		float64FromBits: makeConversionFunction(
			ctx, "__float64FromBits", unionType, nat64Type, nat64Field, float64Type, float64Field));
}

immutable(gcc_jit_function*) makeConversionFunction(
	ref gcc_jit_context ctx,
	immutable char* name,
	immutable gcc_jit_type* converterType,
	immutable gcc_jit_type* inType,
	immutable gcc_jit_field* inField,
	immutable gcc_jit_type* outType,
	immutable gcc_jit_field* outField,
) {
	immutable gcc_jit_param* param = gcc_jit_context_new_param(ctx, null, inType, "in");
	gcc_jit_function* res = makeFunction(ctx, outType, name, [param]);
	gcc_jit_block* block = gcc_jit_function_new_block(res, "entry");
	gcc_jit_lvalue* local = gcc_jit_function_new_local(res, null, converterType, "converter");
	gcc_jit_block_add_assignment(
		block,
		null,
		gcc_jit_lvalue_access_field(local, null, inField),
		gcc_jit_param_as_rvalue(param));
	gcc_jit_block_end_with_return(
		block,
		null,
		gcc_jit_rvalue_access_field(gcc_jit_lvalue_as_rvalue(local), null, outField));
	return castImmutable(res);
}

// This should match 'switch_fiber' in 'writeToC_boilerplate_posix.c'
immutable(gcc_jit_function*) makeSwitchFiberFunction(ref gcc_jit_context ctx, immutable gcc_jit_type* crowVoidType) {
	immutable gcc_jit_type* nat64Type = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_LONG);
	immutable gcc_jit_type* stackPointerType = gcc_jit_type_get_pointer(nat64Type);
	immutable gcc_jit_type* stackPointerMutPointerType = gcc_jit_type_get_pointer(stackPointerType);
	return makeAssemblyFunction(
		ctx, crowVoidType, "switch_fiber",
		[
			gcc_jit_context_new_param(ctx, null, stackPointerMutPointerType, "from"),
			gcc_jit_context_new_param(ctx, null, stackPointerType, "to"),
		],
		".text\n" ~
		".align 8\n" ~
		"switch_fiber:\n" ~
		"push %rbx\n" ~
		"push %rbp\n" ~
		"push %r12\n" ~
		"push %r13\n" ~
		"push %r14\n" ~
		"push %r15\n" ~
		"movq %rsp, (%rdi)\n" ~
		"movq %rsi, %rsp\n" ~
		"pop %r15\n" ~
		"pop %r14\n" ~
		"pop %r13\n" ~
		"pop %r12\n" ~
		"pop %rbp\n" ~
		"pop %rbx\n" ~
		"ret");
}

// This should match 'switch_fiber_initial' in 'writeToC_boilerplate_posix.c'
immutable(gcc_jit_function*) makeSwitchFiberInitialFunction(
	ref gcc_jit_context ctx,
	immutable gcc_jit_type* crowVoidType,
	immutable gcc_jit_type* fiberPointerType,
) {
	immutable gcc_jit_type* nat64Type = gcc_jit_context_get_type(ctx, gcc_jit_types.GCC_JIT_TYPE_UNSIGNED_LONG);
	immutable gcc_jit_type* stackPointerType = gcc_jit_type_get_pointer(nat64Type);
	immutable gcc_jit_type* stackPointerMutPointerType = gcc_jit_type_get_pointer(stackPointerType);
	immutable gcc_jit_type* funcType = gcc_jit_context_new_function_ptr_type(
		ctx, null, crowVoidType, 1, &fiberPointerType, false);
	return makeAssemblyFunction(
		ctx, crowVoidType, "switch_fiber_initial",
		[
			gcc_jit_context_new_param(ctx, null, fiberPointerType, "fiber"),
			gcc_jit_context_new_param(ctx, null, stackPointerMutPointerType, "from"),
			gcc_jit_context_new_param(ctx, null, stackPointerType, "to"),
			gcc_jit_context_new_param(ctx, null, funcType, "func"),
		],
		".text\n" ~
		".align 8\n" ~
		"switch_fiber_initial:\n" ~
		"push %rbx\n" ~
		"push %rbp\n" ~
		"push %r12\n" ~
		"push %r13\n" ~
		"push %r14\n" ~
		"push %r15\n" ~
		"movq %rsp, (%rsi)\n" ~
		"movq %rdx, %rsp\n" ~
		"subq $8, %rsp\n" ~
		"push %rcx\n" ~
		"ret\n");
}

// This should match 'setup_catch' in 'writeToC_boilerplate_posix.c'
immutable(gcc_jit_function*) makeSetupCatchFunction(
	ref gcc_jit_context ctx,
	immutable gcc_jit_type* boolType,
	immutable gcc_jit_type* voidPointerType,
) =>
	makeAssemblyFunction(
		ctx, boolType, "setup_catch",
		[gcc_jit_context_new_param(ctx, null, voidPointerType, "catch_point")],
		".text\n" ~
		".align 8\n" ~
		"setup_catch:\n" ~
		"movq %rbx, (%rdi)\n" ~
		"movq %rbp, 0x08(%rdi)\n" ~
		"movq %r12, 0x10(%rdi)\n" ~
		"movq %r13, 0x18(%rdi)\n" ~
		"movq %r14, 0x20(%rdi)\n" ~
		"movq %r15, 0x28(%rdi)\n" ~
		"movq %rsp, 0x30(%rdi)\n" ~
		"movq (%rsp), %rax\n" ~
		"movq %rax, 0x38(%rdi)\n" ~
		"xor %al, %al\n" ~
		"ret\n");

// This should match 'jump_to_catch' in 'writeToC_boilerplate_posix.c'
immutable(gcc_jit_function*) makeJumpToCatchFunction(
	ref gcc_jit_context ctx,
	immutable gcc_jit_type* crowVoidType,
	immutable gcc_jit_type* voidPointerType,
) =>
	makeAssemblyFunction(
		ctx, crowVoidType, "jump_to_catch",
		[gcc_jit_context_new_param(ctx, null, voidPointerType, "catch_point")],
		".text\n" ~
		".align 8\n" ~
		"jump_to_catch:\n" ~
		"movq (%rdi), %rbx\n" ~
		"movq 0x08(%rdi), %rbp\n" ~
		"movq 0x10(%rdi), %r12\n" ~
		"movq 0x18(%rdi), %r13\n" ~
		"movq 0x20(%rdi), %r14\n" ~
		"movq 0x28(%rdi), %r15\n" ~
		"movq 0x30(%rdi), %rsp\n" ~
		"movq 0x38(%rdi), %rax\n" ~
		"movq %rax, (%rsp)\n" ~
		"mov $1, %al\n" ~
		"ret\n");

immutable(gcc_jit_function*) makeAssemblyFunction(
	ref gcc_jit_context ctx,
	immutable gcc_jit_type* returnType,
	immutable char* name,
	in immutable gcc_jit_param*[] params,
	immutable char* assembly,
) {
	gcc_jit_function* res = makeFunction(
		ctx, returnType, name, params, gcc_jit_function_kind.GCC_JIT_FUNCTION_IMPORTED);
	if (false) { // TODO: This requires a newer libgccjit
		gcc_jit_function_add_attribute(res, gcc_jit_fn_attribute.GCC_JIT_FN_ATTRIBUTE_NOINLINE);
	}
	gcc_jit_context_add_top_level_asm(ctx, null, assembly);
	return res;
}

@trusted gcc_jit_function* makeFunction(
	ref gcc_jit_context ctx,
	immutable gcc_jit_type* returnType,
	immutable char* name,
	in immutable gcc_jit_param*[] params,
	gcc_jit_function_kind kind = gcc_jit_function_kind.GCC_JIT_FUNCTION_INTERNAL,
) =>
	gcc_jit_context_new_function(ctx, null, kind, returnType, name, safeToInt(params.length), params.ptr, false);

struct GlobalsForConstants {
	// This mirrors the structure of 'AllConstants'.
	// Ignoring program.allConstants.cStrings because gcc supports those directly.

	// WARN: This is the *storage* for the constant. It needs to be converted.
	immutable gcc_jit_rvalue*[][] arrs;
	gcc_jit_lvalue*[][] pointers;
}

GlobalsForConstants generateGlobalsForConstants(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in LowProgram program,
	in GccTypes types,
	in MangledNames mangledNames,
) {
	immutable gcc_jit_rvalue*[][] arrGlobals = map!(immutable gcc_jit_rvalue*[], ArrTypeAndConstantsLow)(
		alloc, program.allConstants.arrs, (ref ArrTypeAndConstantsLow tc) {
			immutable gcc_jit_type* gccElementType = getGccType(types, tc.elementType);
			return mapWithIndex!(immutable gcc_jit_rvalue*, immutable Constant[])(
				alloc,
				tc.constants,
				(size_t index, ref immutable Constant[] values) {
					immutable gcc_jit_type* arrayType = gcc_jit_context_new_array_type(
						ctx,
						null,
						gccElementType,
						safeToInt(values.length));
					//TODO:NO ALLOC
					CString name = withWriter(alloc, (scope ref Writer writer) {
						writeConstantArrStorageName(writer, mangledNames, program, tc.arrType, index);
					});
					return gcc_jit_lvalue_as_rvalue(gcc_jit_context_new_global(
						ctx,
						null,
						gcc_jit_global_kind.GCC_JIT_GLOBAL_INTERNAL,
						arrayType,
						name.ptr));
				});
		});

	gcc_jit_lvalue*[][] ptrGlobals = map!(gcc_jit_lvalue*[], PointerTypeAndConstantsLow)(
		alloc, program.allConstants.pointers, (ref PointerTypeAndConstantsLow tc) {
			immutable gcc_jit_type* gccPointeeType = getGccType(types, tc.pointeeType);
			return mapWithIndex!(gcc_jit_lvalue*, Constant)(
				alloc,
				tc.constants,
				(size_t index, scope ref Constant) {
					//TODO:NO ALLOC
					CString name = withWriter(alloc, (scope ref Writer writer) {
						writeConstantPointerStorageName(writer, mangledNames, program, tc.pointeeType, index);
					});
					return gcc_jit_context_new_global(
						ctx,
						null,
						gcc_jit_global_kind.GCC_JIT_GLOBAL_INTERNAL,
						gccPointeeType,
						name.ptr);
				});
		});

	return GlobalsForConstants(arrGlobals, ptrGlobals);
}

alias GccVars = FullIndexMap!(LowVarIndex, gcc_jit_lvalue*);

GccVars generateGccVars(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in LowProgram program,
	in GccTypes types,
	in MangledNames mangledNames,
) =>
	mapFullIndexMap_mut!(LowVarIndex, gcc_jit_lvalue*, LowVar)(
		alloc, program.vars, (LowVarIndex varIndex, in LowVar var) {
			immutable gcc_jit_type* type = getGccType(types, var.type);
			//TODO:NO ALLOC
			CString name = withWriter(alloc, (scope ref Writer writer) {
				writeLowVarMangledName(writer, mangledNames, varIndex, var);
			});
			gcc_jit_lvalue* res = gcc_jit_context_new_global(
				ctx, null,
				var.isExtern
					? gcc_jit_global_kind.GCC_JIT_GLOBAL_IMPORTED
					: gcc_jit_global_kind.GCC_JIT_GLOBAL_INTERNAL,
				type, name.ptr);
			final switch (var.kind) {
				case LowVar.Kind.externGlobal:
				case LowVar.Kind.global:
					break;
				case LowVar.Kind.threadLocal:
					gcc_jit_lvalue_set_tls_model(res, gcc_jit_tls_model.GCC_JIT_TLS_MODEL_LOCAL_DYNAMIC);
					break;
			}
			return res;
		});

gcc_jit_function* toGccFunctionSignature(
	ref Alloc alloc,
	ref gcc_jit_context ctx,
	in LowProgram program,
	in MangledNames mangledNames,
	in GccTypes gccTypes,
	LowFunIndex funIndex,
	in LowFun fun,
) {
	gcc_jit_function_kind kind = fun.body_.matchIn!gcc_jit_function_kind(
		(in LowFunBody.Extern x) =>
			gcc_jit_function_kind.GCC_JIT_FUNCTION_IMPORTED,
		(in LowFunExprBody _) =>
			funIndex == program.main
				? gcc_jit_function_kind.GCC_JIT_FUNCTION_EXPORTED
				: gcc_jit_function_kind.GCC_JIT_FUNCTION_INTERNAL);

	immutable gcc_jit_type* returnType = getGccType(gccTypes, fun.returnType);
	return withTempAlloc(alloc.meta, (ref Alloc tempAlloc) {
		immutable gcc_jit_param*[] params = map(tempAlloc, fun.params, (ref LowLocal param) {
			CString name = withWriter(tempAlloc, (scope ref Writer writer) {
				writeLowLocalName(writer, mangledNames, param);
			});
			return gcc_jit_context_new_param(ctx, null, getGccType(gccTypes, param.type), name.ptr);
		});
		CString name = withWriter(tempAlloc, (scope ref Writer writer) {
			writeLowFunMangledName(writer, mangledNames, funIndex, fun);
		});
		return makeFunction(ctx, returnType, name.ptr, params, kind);
	});
}

struct ExprEmit {
	struct Loop {
		gcc_jit_block* loopBlock;
		MutOpt!(gcc_jit_block*) endBlock;
		ExprEmit breakEmit;
	}
	// Return from the block. Return none.
	immutable struct Return {}
	// Return some.
	immutable struct Value {}
	/**
	Don't return anything. (Don't even return_void).
	This is used for `BuiltinUnary.drop` even if the expression type is not void.
	**/
	immutable struct Void {}

	mixin TaggedUnion!(Loop*, Return, Value, Void, gcc_jit_lvalue*);
}

bool isLoopOrReturn(in ExprEmit a) =>
	a.isA!(ExprEmit.Loop*) || a.isA!(ExprEmit.Return);

immutable struct ExprResult {
	@safe @nogc pure nothrow:

	// Did some kind of jump
	immutable struct BreakContinueOrReturn {}
	// Did not change control flow
	immutable struct Void {}

	mixin TaggedUnion!(BreakContinueOrReturn, gcc_jit_rvalue*, Void);

	bool opEquals(in ExprResult b) scope =>
		matchWithPointers!bool(
			(BreakContinueOrReturn _) =>
				b.isA!(ExprResult.BreakContinueOrReturn),
			(gcc_jit_rvalue* x) =>
				b.isA!(gcc_jit_rvalue*) && b.as!(gcc_jit_rvalue*) == x,
			(ExprResult.Void) =>
				b.isA!(ExprResult.Void));
}

ExprResult emitSimpleNoSideEffects(ref ExprCtx ctx, ExprEmit emit, gcc_jit_rvalue* value) {
	assert(value != null);
	return emit.matchWithPointers!ExprResult(
		(ExprEmit.Loop*) =>
			assert(false),
		(ExprEmit.Return) {
			gcc_jit_block_end_with_return(ctx.curBlock, null, value);
			return ExprResult(ExprResult.BreakContinueOrReturn());
		},
		(ExprEmit.Value) =>
			ExprResult(value),
		(ExprEmit.Void) {
			gcc_jit_block_add_eval(ctx.curBlock, null, value);
			return ExprResult(ExprResult.Void());
		},
		(gcc_jit_lvalue* x) {
			gcc_jit_block_add_assignment(ctx.curBlock, null, x, value);
			return ExprResult(ExprResult.Void());
		});
}

// We need to ensure side effects happen in order since GCC seems to evaluate call arguments in reverse.
ExprResult emitSimpleYesSideEffects(ref ExprCtx ctx, ExprEmit emit, LowType type, gcc_jit_rvalue* value) =>
	emit.isA!(ExprEmit.Value)
		? ExprResult(getRValueUsingLocal(ctx, type, (gcc_jit_lvalue* local) {
			gcc_jit_block_add_assignment(ctx.curBlock, null, local, value);
		}))
		: emitSimpleNoSideEffects(ctx, emit, value);

gcc_jit_rvalue* getRValueUsingLocal(
	ref ExprCtx ctx,
	LowType type,
	in void delegate(gcc_jit_lvalue*) @safe @nogc pure nothrow cb,
) {
	gcc_jit_lvalue* local = gcc_jit_function_new_local(ctx.curFun, null, getGccType(ctx.types, type), "temp");
	cb(local);
	return gcc_jit_lvalue_as_rvalue(local);
}

ExprResult emitWriteToLValue(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	in void delegate(gcc_jit_lvalue*) @safe @nogc pure nothrow cb,
) =>
	emit.matchWithPointers!ExprResult(
		(ExprEmit.Loop*) =>
			assert(false),
		(ExprEmit.Return) {
			gcc_jit_rvalue* rvalue = getRValueUsingLocal(ctx, type, cb);
			gcc_jit_block_end_with_return(ctx.curBlock, null, rvalue);
			return ExprResult(ExprResult.BreakContinueOrReturn());
		},
		(ExprEmit.Value) =>
			ExprResult(getRValueUsingLocal(ctx, type, cb)),
		(ExprEmit.Void) {
			// This can happen for a BuiltinUnary.drop
			getRValueUsingLocal(ctx, type, cb);
			return ExprResult(ExprResult.Void());
		},
		(gcc_jit_lvalue* x) {
			cb(x);
			return ExprResult(ExprResult.Void());
		});

ExprResult emitVoid(ref ExprCtx ctx, ExprEmit emit) =>
	emit.matchWithPointers!ExprResult(
		(ExprEmit.Loop*) =>
			assert(false),
		(ExprEmit.Return) {
			//TODO: this should be unnecessary, use local void
			gcc_jit_block_end_with_return(ctx.curBlock, null, ctx.globalVoid);
			return ExprResult(ExprResult.BreakContinueOrReturn());
		},
		(ExprEmit.Value) =>
			ExprResult(ctx.globalVoid),
		(ExprEmit.Void) =>
			ExprResult(ExprResult.Void()),
		(gcc_jit_lvalue* x) =>
			ExprResult(ExprResult.Void()));

ExprResult emitWithBranching(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	immutable char* endBlockName,
	in void delegate(
		gcc_jit_block* originalBlock,
		MutOpt!(gcc_jit_block*) endBlock,
		MutOpt!(gcc_jit_lvalue*) local,
		ExprResult expectedResult,
	) @safe @nogc pure nothrow cb,
) {
	MutOpt!(gcc_jit_block*) endBlock = isLoopOrReturn(emit)
		? noneMut!(gcc_jit_block*)
		: someMut(gcc_jit_function_new_block(ctx.curFun, endBlockName));
	MutOpt!(gcc_jit_lvalue*) local = emit.isA!(ExprEmit.Value)
		? someMut(gcc_jit_function_new_local(ctx.curFun, null, getGccType(ctx.types, type), "temp"))
		: noneMut!(gcc_jit_lvalue*);
	gcc_jit_block* originalBlock = ctx.curBlock;

	ExprResult expectedResult = emit.matchConst!ExprResult(
		(const ExprEmit.Loop*) =>
			ExprResult(ExprResult.BreakContinueOrReturn()),
		(ExprEmit.Return) =>
			ExprResult(ExprResult.BreakContinueOrReturn()),
		(ExprEmit.Value) {
			assert(has(local));
			return ExprResult(ExprResult.Void());
		},
		(ExprEmit.Void) =>
			ExprResult(ExprResult.Void()),
		(const gcc_jit_lvalue*) =>
			ExprResult(ExprResult.Void()));

	cb(originalBlock, endBlock, local, expectedResult);

	// If no endBlock, curBlock doesn't matter because nothing else will be done.
	ctx.curBlock = has(endBlock) ? force(endBlock) : originalBlock;
	if (has(local)) {
		assert(expectedResult.isA!(ExprResult.Void));
		return ExprResult(gcc_jit_lvalue_as_rvalue(force(local)));
	} else
		return expectedResult;
}

alias Locals = StackMap!(LowLocal*, gcc_jit_lvalue*);
alias addLocal = stackMapAdd!(LowLocal*, gcc_jit_lvalue*);
gcc_jit_lvalue* getLocal(ref ExprCtx ctx, ref Locals locals, in LowLocal* local) {
	Opt!size_t paramIndex = indexOfPointer(ctx.curLowFun.params, local);
	return has(paramIndex)
		? gcc_jit_param_as_lvalue(gcc_jit_function_get_param(ctx.curFun, safeToInt(force(paramIndex))))
		: stackMapMustGet!(LowLocal*, gcc_jit_lvalue*)(locals, local);
}

struct ExprCtx {
	@safe @nogc pure nothrow:

	Alloc* allocPtr;
	immutable LowProgram* programPtr;
	gcc_jit_context* gccPtr;
	const MangledNames* mangledNamesPtr;
	immutable GccTypes* typesPtr;
	GlobalsForConstants* globalsForConstantsPtr;
	GccVars* gccVarsPtr;
	FullIndexMap!(LowFunIndex, gcc_jit_function*) gccFuns;
	LowFun* curLowFun;
	gcc_jit_function* curFun;
	gcc_jit_block* entryBlock;
	gcc_jit_block* curBlock;
	immutable gcc_jit_type* nat64Type;
	immutable gcc_jit_function* abortFunction;
	immutable gcc_jit_function* jumpToCatchFunction;
	immutable gcc_jit_function* setupCatchFunction;
	immutable gcc_jit_function* switchFiberFunction;
	immutable gcc_jit_function* switchFiberInitialFunction;
	BuiltinFunctions* builtinFunctionsPtr;
	ConversionFunctions* conversionFunctionsPtr;
	immutable gcc_jit_rvalue* globalVoid;

	ref Alloc alloc() return scope =>
		*allocPtr;

	ref LowProgram program() const return scope =>
		*programPtr;

	ref MangledNames mangledNames() const return scope =>
		*mangledNamesPtr;

	ref GccTypes types() const return scope =>
		*typesPtr;

	ref GlobalsForConstants globalsForConstants() return scope =>
		*globalsForConstantsPtr;

	ref GccVars gccVars() return scope =>
		*gccVarsPtr;

	ref gcc_jit_context gcc() return scope =>
		*gccPtr;

	ref BuiltinFunctions builtinFunctions() return scope =>
		*builtinFunctionsPtr;
	ref ConversionFunctions conversionFunctions() return scope =>
		*conversionFunctionsPtr;
}

immutable(gcc_jit_field*[]) recordFields(in ExprCtx ctx, in LowRecord* record) =>
	ctx.types.recordFields[ctx.program.indexOfRecord(record)];
immutable(gcc_jit_field*) recordField(in ExprCtx ctx, in LowRecord* record, size_t fieldIndex) =>
	recordFields(ctx, record)[fieldIndex];

ExprResult toGccExpr(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, ref LowExpr a) =>
	a.kind.match!ExprResult(
		(AbortLowExpr x) =>
			abortToGcc(ctx, locals, emit, a.type),
		(CallLowExpr it) =>
			callToGcc(ctx, locals, emit, a.type, it),
		(CallFunPointerLowExpr it) =>
			callFunPointerToGcc(ctx, locals, emit, a, it),
		(CreateRecordLowExpr it) =>
			createRecordToGcc(ctx, locals, emit, a, it),
		(ref CreateUnionLowExpr it) =>
			createUnionToGcc(ctx, locals, emit, a, it),
		(FunPointerLowExpr x) =>
			funPointerToGcc(ctx, emit, a.type, x.fun),
		(ref IfLowExpr it) =>
			ifToGcc(ctx, locals, emit, a.type, it.cond, it.then, it.else_),
		(InitLowExpr x) =>
			initToGcc(ctx, emit, x.kind),
		(ref LetLowExpr it) =>
			letToGcc(ctx, locals, emit, it),
		(LocalGetLowExpr it) =>
			localGetToGcc(ctx, locals, emit, it),
		(LocalPointerLowExpr x) =>
			localPointerToGcc(ctx, locals, emit, a.type, x),
		(ref LocalSetLowExpr it) =>
			localSetToGcc(ctx, locals, emit, it),
		(ref LoopLowExpr it) =>
			loopToGcc(ctx, locals, emit, a.type, it),
		(ref LoopBreakLowExpr it) =>
			loopBreakToGcc(ctx, locals, emit, it),
		(LoopContinueLowExpr _) =>
			loopContinueToGcc(ctx, locals, emit),
		(ref PointerCastLowExpr it) =>
			ptrCastToGcc(ctx, locals, emit, a, it),
		(RecordFieldGetLowExpr it) =>
			recordFieldGetToGcc(ctx, locals, emit, it),
		(RecordFieldPointerLowExpr x) =>
			recordFieldPointerToGcc(ctx, locals, emit, a, x),
		(ref RecordFieldSetLowExpr it) =>
			recordFieldSetToGcc(ctx, locals, emit, it),
		(Constant x) =>
			constantToGcc(ctx, emit, a.type, x),
		(SpecialUnaryLowExpr x) =>
			unaryToGcc(ctx, locals, emit, a.type, x),
		(SpecialUnaryMathLowExpr x) =>
			callBuiltinUnary(ctx, locals, emit, x.arg, builtinForUnaryMath(x.kind)),
		(SpecialBinaryLowExpr x) =>
			binaryToGcc(ctx, locals, emit, a.type, x),
		(SpecialBinaryMathLowExpr x) =>
			callBuiltinBinary(ctx, locals, emit, x.args, builtinForBinaryMath(x.kind)),
		(SpecialTernaryLowExpr x) =>
			ternaryToGcc(ctx, locals, emit, a.type, x),
		(Special4aryLowExpr x) =>
			fouraryToGcc(ctx, locals, emit, a.type, x),
		(ref SwitchLowExpr x) =>
			switchToGcc(ctx, locals, emit, a.type, x),
		(TailRecurLowExpr it) =>
			tailRecurToGcc(ctx, locals, emit, it),
		(UnionAsLowExpr x) =>
			unionAsToGcc(ctx, locals, emit, x),
		(UnionKindLowExpr x) =>
			unionKindToGcc(ctx, locals, emit, x),
		(VarGetLowExpr x) =>
			varGetToGcc(ctx, locals, emit, x),
		(VarSetLowExpr x) =>
			varSetToGcc(ctx, locals, emit, x));

gcc_jit_rvalue* emitToRValueCb(
	in ExprResult delegate(ExprEmit) @safe @nogc pure nothrow cbEmit,
) {
	ExprEmit emit = ExprEmit(ExprEmit.Value());
	return cbEmit(emit).as!(gcc_jit_rvalue*);
}

immutable(gcc_jit_rvalue*) emitToRValue(ref ExprCtx ctx, ref Locals locals, ref LowExpr a) =>
	emitToRValueCb((ExprEmit emit) =>
		toGccExpr(ctx, locals, emit, a));

void emitToLValueCb(
	gcc_jit_lvalue* lvalue,
	in ExprResult delegate(ExprEmit) @safe @nogc pure nothrow cbEmit,
) {
	ExprResult result = cbEmit(ExprEmit(lvalue));
	assert(result.isA!(ExprResult.Void));
}

void emitToLValue(ref ExprCtx ctx, ref Locals locals, gcc_jit_lvalue* lvalue, ref LowExpr a) {
	emitToLValueCb(lvalue, (ExprEmit emitArg) @safe =>
		toGccExpr(ctx, locals, emitArg, a));
}

void emitToVoid(ref ExprCtx ctx, ref Locals locals, ref LowExpr a) {
	ExprEmit emitVoid = ExprEmit(ExprEmit.Void());
	ExprResult result = toGccExpr(ctx, locals, emitVoid, a);
	assert(result.isA!(ExprResult.Void));
}

ExprResult abortToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, LowType type) {
	gcc_jit_block_add_eval(ctx.curBlock, null, gcc_jit_context_new_call(ctx.gcc, null, ctx.abortFunction, 0, null));
	// Do something arbitrary to satisfy GCC that the block is ended.
	return emit.isA!(ExprEmit.Loop*)
		? loopContinueToGcc(ctx, locals, emit)
		: zeroedToGcc(ctx, emit, type);
}

ExprResult callToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	in CallLowExpr a,
) =>
	makeCall(
		ctx, emit, type, ctx.gccFuns[a.called],
		map(ctx.alloc, a.args, (ref LowExpr arg) => emitToRValue(ctx, locals, arg)));

@trusted ExprResult makeCall(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	const gcc_jit_function* called,
	in immutable gcc_jit_rvalue*[] args,
	bool noSideEffects = false
) {
	immutable gcc_jit_rvalue* call = castImmutable(
		gcc_jit_context_new_call(ctx.gcc, null, called, safeToInt(args.length), args.ptr));
	return noSideEffects
		? emitSimpleNoSideEffects(ctx, emit, call)
		: emitSimpleYesSideEffects(ctx, emit, type, call);
}

@trusted ExprResult callFunPointerToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	in LowExpr expr,
	in CallFunPointerLowExpr a,
) {
	gcc_jit_rvalue* funPtrGcc = emitToRValue(ctx, locals, *a.funPtr);
	//TODO:NO ALLOC
	immutable gcc_jit_rvalue*[] argsGcc =
		map(ctx.alloc, a.args, (ref LowExpr arg) => emitToRValue(ctx, locals, arg));
	return emitSimpleYesSideEffects(ctx, emit, expr.type, gcc_jit_context_new_call_through_ptr(
		ctx.gcc,
		null,
		funPtrGcc,
		safeToInt(argsGcc.length),
		argsGcc.ptr));
}

@trusted ExprResult tailRecurToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	in TailRecurLowExpr a,
) {
	assert(emit.isA!(ExprEmit.Return));

	// We need to be sure to generate all the new parameter values before overwriting any,
	gcc_jit_lvalue*[] updateParamLocals =
		map!(gcc_jit_lvalue*, UpdateParam)(ctx.alloc, a.updateParams, (ref UpdateParam updateParam) {
			gcc_jit_lvalue* local =
				gcc_jit_function_new_local(ctx.curFun, null, getGccType(ctx.types, updateParam.newValue.type), "temp");
			emitToLValue(ctx, locals, local, updateParam.newValue);
			return local;
		});
	zip!(gcc_jit_lvalue*, UpdateParam)(
		updateParamLocals,
		a.updateParams,
		(ref gcc_jit_lvalue* local, ref UpdateParam updateParam) {
			gcc_jit_block_add_assignment(
				ctx.curBlock,
				null,
				getLocal(ctx, locals, updateParam.param),
				gcc_jit_lvalue_as_rvalue(local));
		});
	gcc_jit_block_end_with_jump(ctx.curBlock, null, ctx.entryBlock);
	return ExprResult(ExprResult.BreakContinueOrReturn());
}

ExprResult varGetToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, in VarGetLowExpr a) {
	return emitSimpleNoSideEffects(ctx, emit, gcc_jit_lvalue_as_rvalue(ctx.gccVars[a.varIndex]));
}
ExprResult varSetToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, in VarSetLowExpr a) {
	emitToLValue(ctx, locals, ctx.gccVars[a.varIndex], *a.value);
	return emitVoid(ctx, emit);
}

ExprResult emitRecordCb(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	in ExprResult delegate(size_t, ExprEmit) @safe @nogc pure nothrow cbEmitArg,
) =>
	emitWriteToLValue(ctx, emit, type, (gcc_jit_lvalue* lvalue) {
		foreach (size_t i, immutable gcc_jit_field* field; recordFields(ctx, type.as!(LowRecord*))) {
			gcc_jit_rvalue* value = emitToRValueCb((ExprEmit emitArg) =>
				cbEmitArg(i, emitArg));
			gcc_jit_block_add_assignment(ctx.curBlock, null, gcc_jit_lvalue_access_field(lvalue, null, field), value);
		}
	});

ExprResult emitRecordCbWithArgs(T)(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	in T[] args,
	in ExprResult delegate(size_t, ExprEmit, ref T) @safe @nogc pure nothrow cbEmitArg,
) =>
	emitRecordCb(ctx, emit, type, (size_t argIndex, ExprEmit emitArg) =>
		cbEmitArg(argIndex, emitArg, args[argIndex]));

ExprResult createRecordToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr expr,
	ref CreateRecordLowExpr a,
) =>
	emitRecordCbWithArgs!LowExpr(ctx, emit, expr.type, a.args, (size_t _, ExprEmit emitArg, ref LowExpr arg) =>
		toGccExpr(ctx, locals, emitArg, arg));

ExprResult emitUnion(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	size_t memberIndex,
	in ExprResult delegate(ExprEmit) @safe @nogc pure nothrow cbEmitArg,
) =>
	emitWriteToLValue(ctx, emit, type, (gcc_jit_lvalue* lvalue) {
		UnionFields unionFields = getUnionFields(ctx, type);
		gcc_jit_block_add_assignment(
			ctx.curBlock,
			null,
			gcc_jit_lvalue_access_field(lvalue, null, unionFields.kindField),
			gcc_jit_context_new_rvalue_from_long(ctx.gcc, ctx.nat64Type, memberIndex));
		gcc_jit_lvalue* memberLValue = gcc_jit_lvalue_access_field(
			gcc_jit_lvalue_access_field(lvalue, null, unionFields.innerField),
			null,
			unionFields.memberFields[memberIndex]);
		emitToLValueCb(memberLValue, cbEmitArg);
	});

ExprResult createUnionToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr expr,
	ref CreateUnionLowExpr a,
) =>
	emitUnion(ctx, emit, expr.type, a.memberIndex, (ExprEmit emitArg) =>
		toGccExpr(ctx, locals, emitArg, a.arg));

ExprResult letToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, ref LetLowExpr a) =>
	emitWithLocal(ctx, locals, emit, a.local, a.then, (ExprEmit valueEmit) =>
		toGccExpr(ctx, locals, valueEmit, a.value));

ExprResult emitWithLocal(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	in LowLocal* lowLocal,
	ref LowExpr then,
	in ExprResult delegate(ExprEmit) @safe @nogc pure nothrow cbValue,
) {
	//TODO:NO ALLOC
	CString name = withWriter(ctx.alloc, (scope ref Writer writer) {
		writeLowLocalName(writer, ctx.mangledNames, *lowLocal);
	});
	immutable gcc_jit_type* type = getGccType(ctx.types, lowLocal.type);
	immutable gcc_jit_type* fullType = localMustBeVolatile(ctx, *lowLocal) ? gcc_jit_type_get_volatile(type) : type;
	gcc_jit_lvalue* gccLocal = gcc_jit_function_new_local(ctx.curFun, null, fullType, name.ptr);
	emitToLValueCb(gccLocal, (ExprEmit valueEmit) =>
		cbValue(valueEmit));
	Locals newLocals = addLocal(locals, lowLocal, gccLocal);
	return toGccExpr(ctx, castNonScope_ref(newLocals), emit, then);
}

ExprResult localGetToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, in LocalGetLowExpr a) {
	immutable gcc_jit_rvalue* value = gcc_jit_lvalue_as_rvalue(getLocal(ctx, locals, a.local));
	return emitSimpleNoSideEffects(ctx, emit, localMustBeVolatile(ctx, *a.local)
		? gcc_jit_context_new_cast(ctx.gcc, null, value, getGccType(ctx.types, a.local.type))
		: value);
}

bool localMustBeVolatile(in ExprCtx ctx, in LowLocal local) =>
	// The 'catch-point' doesn't really need to be volatile,
	// and having it volatile causes compile errors when initializing it
	localMustBeVolatile(*ctx.curLowFun, local) && !isCatchPoint(ctx, local.type);
bool isCatchPoint(in ExprCtx ctx, LowType type) =>
	type.isA!(LowExternType*) && isCatchPoint(*type.as!(LowExternType*).source);

ExprResult localSetToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, ref LocalSetLowExpr a) {
	emitToLValue(ctx, locals, getLocal(ctx, locals, a.local), a.value);
	return emitVoid(ctx, emit);
}

ExprResult loopToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, LowType type, ref LoopLowExpr a) =>
	emitWithBranching(
		ctx, emit, type, "loopEnd",
		(
			gcc_jit_block* originalBlock,
			MutOpt!(gcc_jit_block*) endBlock,
			MutOpt!(gcc_jit_lvalue*) local,
			ExprResult _,
		) {
			gcc_jit_block* loopBlock = gcc_jit_function_new_block(ctx.curFun, "loop");
			gcc_jit_block_end_with_jump(originalBlock, null, loopBlock);
			ctx.curBlock = loopBlock;
			ExprEmit.Loop info = ExprEmit.Loop(
				loopBlock,
				endBlock, // TODO:UNUSED
				has(local) ? ExprEmit(force(local)) : emit);
			ExprEmit innerEmit = ExprEmit(ptrTrustMe(info));
			ExprResult innerResult = toGccExpr(ctx, locals, innerEmit, a.body_);
			assert(innerResult.isA!(ExprResult.BreakContinueOrReturn));
		});

ExprResult loopBreakToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit, ref LoopBreakLowExpr a) {
	ExprEmit.Loop loop = *emit.as!(ExprEmit.Loop*);
	// Give 'breakEmit' to the inner expr, so it does whatever is needed by the loop
	ExprResult result = toGccExpr(ctx, locals, loop.breakEmit, a.value);
	result.match!void(
		(ExprResult.BreakContinueOrReturn) {},
		(ref gcc_jit_rvalue) { assert(false); },
		(ExprResult.Void) {
			gcc_jit_block_end_with_jump(ctx.curBlock, null, force(loop.endBlock));
		});
	return ExprResult(ExprResult.BreakContinueOrReturn());
}

ExprResult loopContinueToGcc(ref ExprCtx ctx, ref Locals locals, ExprEmit emit) {
	gcc_jit_block_end_with_jump(ctx.curBlock, null, emit.as!(ExprEmit.Loop*).loopBlock);
	return ExprResult(ExprResult.BreakContinueOrReturn());
}

ExprResult ptrCastToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr expr,
	ref PointerCastLowExpr a,
) =>
	emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_cast(
		ctx.gcc,
		null,
		emitToRValue(ctx, locals, a.target),
		getGccType(ctx.types, expr.type)));

ExprResult recordFieldPointerToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr expr,
	ref RecordFieldPointerLowExpr a,
) =>
	emitSimpleYesSideEffects(
		ctx, emit, expr.type,
		gcc_jit_lvalue_get_address(
			gcc_jit_rvalue_dereference_field(
				emitToRValue(ctx, locals, *a.target),
				null,
				recordField(ctx, a.targetRecordType, a.fieldIndex)),
			null));

ExprResult localPointerToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	ref LocalPointerLowExpr a,
) {
	immutable gcc_jit_rvalue* pointer = gcc_jit_lvalue_get_address(getLocal(ctx, locals, a.local), null);
	return emitSimpleNoSideEffects(ctx, emit, localMustBeVolatile(ctx, *a.local)
		? gcc_jit_context_new_cast(ctx.gcc, null, pointer, getGccType(ctx.types, type))
		: pointer);
}

ExprResult recordFieldGetToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref RecordFieldGetLowExpr a,
) {
	gcc_jit_rvalue* target = emitToRValue(ctx, locals, *a.target);
	immutable gcc_jit_field* field = recordField(ctx, a.targetRecordType, a.fieldIndex);
	return emitSimpleNoSideEffects(ctx, emit, a.targetIsPointer
		? gcc_jit_lvalue_as_rvalue(gcc_jit_rvalue_dereference_field(target, null, field))
		: gcc_jit_rvalue_access_field(target, null, field));
}

ref UnionFields getUnionFields(ref ExprCtx ctx, in LowType unionType) =>
	ctx.types.unionFields[ctx.program.indexOfUnion(unionType.as!(LowUnion*))];

ExprResult unionKindToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	in UnionKindLowExpr a,
) =>
	emitSimpleNoSideEffects(
		ctx, emit,
		gcc_jit_rvalue_access_field(
			emitToRValue(ctx, locals, *a.union_),
			null,
			getUnionFields(ctx, a.union_.type).kindField));

gcc_jit_rvalue* getUnionAs(gcc_jit_rvalue* union_, ref UnionFields unionFields, size_t memberIndex) =>
	gcc_jit_rvalue_access_field(
		gcc_jit_rvalue_access_field(union_, null, unionFields.innerField),
		null,
		unionFields.memberFields[memberIndex]);

ExprResult unionAsToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	in UnionAsLowExpr a,
) =>
	emitSimpleNoSideEffects(
		ctx, emit,
		getUnionAs(emitToRValue(ctx, locals, *a.union_), getUnionFields(ctx, a.union_.type), a.memberIndex));

ExprResult recordFieldSetToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref RecordFieldSetLowExpr a,
) {
	gcc_jit_rvalue* target = emitToRValue(ctx, locals, a.target);
	gcc_jit_rvalue* value = emitToRValue(ctx, locals, a.value);
	gcc_jit_block_add_assignment(
		ctx.curBlock, null,
		gcc_jit_rvalue_dereference_field(target, null, recordField(ctx, a.targetRecordType, a.fieldIndex)), value);
	return emitVoid(ctx, emit);
}

ExprResult constantToGcc(ref ExprCtx ctx, ExprEmit emit, LowType type, in Constant a) =>
	a.matchIn!ExprResult(
		(in Constant.ArrConstant it) {
			size_t arrSize = ctx.program.allConstants.arrs[it.typeIndex].constants[it.index].length;
			gcc_jit_rvalue* storage = ctx.globalsForConstants.arrs[it.typeIndex][it.index];
			gcc_jit_rvalue* arrPtr = gcc_jit_lvalue_get_address(
				gcc_jit_context_new_array_access(ctx.gcc, null, storage, gcc_jit_context_zero(ctx.gcc, ctx.nat64Type)),
				null);
			immutable gcc_jit_field*[] fields = recordFields(ctx, type.as!(LowRecord*));
			assert(fields.length == 2);
			immutable gcc_jit_field* sizeField = fields[0];
			immutable gcc_jit_field* ptrField = fields[1];
			return emitWriteToLValue(ctx, emit, type, (gcc_jit_lvalue* local) {
				gcc_jit_block_add_assignment(
					ctx.curBlock,
					null,
					gcc_jit_lvalue_access_field(local, null, ptrField),
					arrPtr);
				gcc_jit_block_add_assignment(
					ctx.curBlock,
					null,
					gcc_jit_lvalue_access_field(local, null, sizeField),
					gcc_jit_context_new_rvalue_from_long(ctx.gcc, ctx.nat64Type, arrSize));
			});
		},
		(in Constant.CString x) =>
			emitSimpleNoSideEffects(
				ctx, emit,
				// Cast to non-const since we don't use that
				gcc_jit_context_new_cast(
					ctx.gcc, null,
					gcc_jit_context_new_string_literal(
						ctx.gcc,
						ctx.program.allConstants.cStrings[x.index].ptr),
					getGccType(ctx.types, type))),
		(in Constant.Float it) =>
			emitSimpleNoSideEffects(
				ctx,
				emit,
				gcc_jit_context_new_rvalue_from_double(ctx.gcc, getGccType(ctx.types, type), it.value)),
		(in Constant.FunPointer x) =>
			funPointerToGcc(ctx, emit, type, mustGet(ctx.program.concreteFunToLowFunIndex, x.fun)),
		(in IntegralValue it) =>
			emitSimpleNoSideEffects(
				ctx,
				emit,
				gcc_jit_context_new_rvalue_from_long(ctx.gcc, getGccType(ctx.types, type), it.value)),
		(in Constant.Pointer it) {
			gcc_jit_lvalue* storage = ctx.globalsForConstants.pointers[it.typeIndex][it.index];
			return emitSimpleNoSideEffects(ctx, emit, gcc_jit_lvalue_get_address(storage, null));
		},
		(in Constant.Record x) =>
			emitRecordCbWithArgs!Constant(
				ctx, emit, type, x.args,
				(size_t argIndex, ExprEmit emitArg, ref Constant arg) =>
					constantToGcc(ctx, emitArg, type.as!(LowRecord*).fields[argIndex].type, arg)),
		(in Constant.Union x) =>
			emitUnion(ctx, emit, type, x.memberIndex, (ExprEmit emitArg) =>
				constantToGcc(ctx, emitArg, type.as!(LowUnion*).members[x.memberIndex], x.arg)),
		(in Constant.Zero) =>
			zeroedToGcc(ctx, emit, type));

ExprResult funPointerToGcc(ref ExprCtx ctx, ExprEmit emit, LowType type, LowFunIndex fun) {
	gcc_jit_rvalue* value = gcc_jit_function_get_address(ctx.gccFuns[fun], null);
	gcc_jit_rvalue* castValue = () {
		if (type.isA!(LowType.PointerConst))
			// We need to cast function pointer to any-ptr for 'all-funs'
			return gcc_jit_context_new_cast(ctx.gcc, null, value, getGccType(ctx.types, type));
		else {
			assert(type.isA!(LowFunPointerType*));
			return value;
		}
	}();
	return emitSimpleNoSideEffects(ctx, emit, castValue);
}

@trusted ExprResult unaryToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	in SpecialUnaryLowExpr a,
) {
	ExprResult builtin(BuiltinFunction x) =>
		callBuiltinUnary(ctx, locals, emit, a.arg, x);
	ExprResult builtinAndCast(BuiltinFunction x) =>
		callBuiltinUnaryAndCast(ctx, locals, emit, a.arg, x, getGccType(ctx.types, type));
	ExprResult callFn(const gcc_jit_function* func, bool noSideEffects = false) =>
		makeCall(ctx, emit, type, func, [emitToRValue(ctx, locals, a.arg)], noSideEffects: noSideEffects);
	ExprResult unaryOp(gcc_jit_unary_op op) =>
		emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_unary_op(
				ctx.gcc,
				null,
				op,
				getGccType(ctx.types, type),
				emitToRValue(ctx, locals, a.arg)));

	final switch (a.kind) {
		case BuiltinUnary.arrayPointer:
		case BuiltinUnary.arraySize:
		case BuiltinUnary.asFuture:
		case BuiltinUnary.asFutureImpl:
		case BuiltinUnary.asMutArray:
		case BuiltinUnary.asMutArrayImpl:
		case BuiltinUnary.cStringOfSymbol:
		case BuiltinUnary.symbolOfCString:
		case BuiltinUnary.toChar8ArrayFromString:
		case BuiltinUnary.trustAsString:
			// done in lower
			assert(false);
		case BuiltinUnary.bitsOfFloat32:
			return callFn(ctx.conversionFunctions.bitsOfFloat32, noSideEffects: true);
		case BuiltinUnary.bitsOfFloat64:
			return callFn(ctx.conversionFunctions.bitsOfFloat64, noSideEffects: true);
		case BuiltinUnary.bitwiseNotNat8:
		case BuiltinUnary.bitwiseNotNat16:
		case BuiltinUnary.bitwiseNotNat32:
		case BuiltinUnary.bitwiseNotNat64:
			return unaryOp(gcc_jit_unary_op.GCC_JIT_UNARY_OP_BITWISE_NEGATE);
		case BuiltinUnary.countOnesNat64:
			return builtinAndCast(BuiltinFunction.__builtin_popcountl);
		case BuiltinUnary.deref:
			return emitSimpleNoSideEffects(ctx, emit, gcc_jit_lvalue_as_rvalue(
				gcc_jit_rvalue_dereference(emitToRValue(ctx, locals, a.arg), null)));
		case BuiltinUnary.drop:
			emitToVoid(ctx, locals, a.arg);
			return emitVoid(ctx, emit);
		case BuiltinUnary.asAnyPointer:
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
			return emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_cast(
				ctx.gcc,
				null,
				emitToRValue(ctx, locals, a.arg),
				getGccType(ctx.types, type)));
		case BuiltinUnary.float32FromBits:
			return callFn(ctx.conversionFunctions.float32FromBits, noSideEffects: true);
		case BuiltinUnary.float64FromBits:
			return callFn(ctx.conversionFunctions.float64FromBits, noSideEffects: true);
		case BuiltinUnary.isNanFloat32:
		case BuiltinUnary.isNanFloat64:
			return builtinAndCast(BuiltinFunction.__builtin_isnan);
		case BuiltinUnary.jumpToCatch:
			return callFn(ctx.jumpToCatchFunction);
		case BuiltinUnary.not:
			return unaryOp(gcc_jit_unary_op.GCC_JIT_UNARY_OP_LOGICAL_NEGATE);
		case BuiltinUnary.setupCatch:
			return callFn(ctx.setupCatchFunction);
		case BuiltinUnary.toNat64FromPtr:
			return callFn(ctx.conversionFunctions.ptrToNat64, noSideEffects: true);
		case BuiltinUnary.toPtrFromNat64:
			immutable gcc_jit_rvalue* arg = emitToRValue(ctx, locals, a.arg);
			return emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_cast(
				ctx.gcc,
				null,
				castImmutable(gcc_jit_context_new_call(ctx.gcc, null, ctx.conversionFunctions.nat64ToPtr, 1, &arg)),
				getGccType(ctx.types, type)));
	}
}

ExprResult callBuiltinUnary(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr arg,
	BuiltinFunction function_,
) {
	immutable gcc_jit_rvalue* argGcc = emitToRValue(ctx, locals, arg);
	return emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_call(
		ctx.gcc, null, ctx.builtinFunctions[function_], 1, &argGcc));
}

ExprResult callBuiltinUnaryAndCast(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr arg,
	BuiltinFunction function_,
	immutable gcc_jit_type* castToType,
) {
	immutable gcc_jit_rvalue* argGcc = emitToRValue(ctx, locals, arg);
	gcc_jit_rvalue* call = gcc_jit_context_new_call(ctx.gcc, null, ctx.builtinFunctions[function_], 1, &argGcc);
	return emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_cast(ctx.gcc, null, call, castToType));
}

ExprResult callBuiltinBinary(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	ref LowExpr[2] args,
	BuiltinFunction function_,
) {
	immutable gcc_jit_rvalue*[2] argsGcc = [emitToRValue(ctx, locals, args[0]), emitToRValue(ctx, locals, args[1])];
	return emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_call(
		ctx.gcc, null, ctx.builtinFunctions[function_], argsGcc.length, argsGcc.ptr));
}

ExprResult ternaryToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	in SpecialTernaryLowExpr a,
) {
	final switch (a.kind) {
		case BuiltinTernary.interpreterBacktrace:
			assert(false);
	}
}

ExprResult fouraryToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	ref Special4aryLowExpr a,
) {
	final switch (a.kind) {
		case Builtin4ary.switchFiberInitial:
			immutable gcc_jit_rvalue*[4] args = mapStatic(a.args, (LowExpr arg) => emitToRValue(ctx, locals, arg));
			return emitSimpleYesSideEffects(
				ctx, emit, type,
				castImmutable(gcc_jit_context_new_call(
					ctx.gcc, null, ctx.switchFiberInitialFunction, args.length, args.ptr)));
	}
}

ExprResult binaryToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	ref SpecialBinaryLowExpr a,
) {
	LowExpr left = a.args[0], right = a.args[1];
	ExprResult operator(gcc_jit_binary_op op) {
		return binaryOperator(ctx, locals, emit, type, op, left, right);
	}
	ExprResult comparison(gcc_jit_comparison cmp) =>
		emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_comparison(
			ctx.gcc,
			null,
			cmp,
			emitToRValue(ctx, locals, left),
			emitToRValue(ctx, locals, right)));
	ExprResult callFn(const gcc_jit_function* func) =>
		makeCall(ctx, emit, type, func, [emitToRValue(ctx, locals, left), emitToRValue(ctx, locals, right)]);

	final switch (a.kind) {
		case BuiltinBinary.addFloat32:
		case BuiltinBinary.addFloat64:
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
			// TODO: does this handle wrapping?
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_PLUS);
		case BuiltinBinary.addPointerAndNat64:
			return ptrArithmeticToGcc(ctx, locals, emit, PtrArith.addNat, left, right);
		case BuiltinBinary.bitwiseAndInt8:
		case BuiltinBinary.bitwiseAndInt16:
		case BuiltinBinary.bitwiseAndInt32:
		case BuiltinBinary.bitwiseAndInt64:
		case BuiltinBinary.bitwiseAndNat8:
		case BuiltinBinary.bitwiseAndNat16:
		case BuiltinBinary.bitwiseAndNat32:
		case BuiltinBinary.bitwiseAndNat64:
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_BITWISE_AND);
		case BuiltinBinary.bitwiseOrInt8:
		case BuiltinBinary.bitwiseOrInt16:
		case BuiltinBinary.bitwiseOrInt32:
		case BuiltinBinary.bitwiseOrInt64:
		case BuiltinBinary.bitwiseOrNat8:
		case BuiltinBinary.bitwiseOrNat16:
		case BuiltinBinary.bitwiseOrNat32:
		case BuiltinBinary.bitwiseOrNat64:
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_BITWISE_OR);
		case BuiltinBinary.bitwiseXorInt8:
		case BuiltinBinary.bitwiseXorInt16:
		case BuiltinBinary.bitwiseXorInt32:
		case BuiltinBinary.bitwiseXorInt64:
		case BuiltinBinary.bitwiseXorNat8:
		case BuiltinBinary.bitwiseXorNat16:
		case BuiltinBinary.bitwiseXorNat32:
		case BuiltinBinary.bitwiseXorNat64:
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_BITWISE_XOR);
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
			return comparison(gcc_jit_comparison.GCC_JIT_COMPARISON_EQ);
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
			return comparison(gcc_jit_comparison.GCC_JIT_COMPARISON_LT);
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
			// TODO: does this handle wrapping?
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_MULT);
		case BuiltinBinary.newArray:
			assert(false);
		case BuiltinBinary.seq:
			emitToVoid(ctx, locals, left);
			return toGccExpr(ctx, locals, emit, right);
		case BuiltinBinary.subFloat32:
		case BuiltinBinary.subFloat64:
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
			// TODO: does this handle wrapping?
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_MINUS);
		case BuiltinBinary.switchFiber:
			return callFn(ctx.switchFiberFunction);
		case BuiltinBinary.subPointerAndNat64:
			return ptrArithmeticToGcc(ctx, locals, emit, PtrArith.subtractNat, left, right);
		case BuiltinBinary.unsafeBitShiftLeftNat64:
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_LSHIFT);
		case BuiltinBinary.unsafeBitShiftRightNat64:
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_RSHIFT);
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
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_DIVIDE);
		case BuiltinBinary.unsafeModNat64:
			return operator(gcc_jit_binary_op.GCC_JIT_BINARY_OP_MODULO);
		case BuiltinBinary.writeToPointer:
			gcc_jit_rvalue* gccLeft = emitToRValue(ctx, locals, left);
			gcc_jit_rvalue* gccRight = emitToRValue(ctx, locals, right);
			gcc_jit_block_add_assignment(ctx.curBlock, null, gcc_jit_rvalue_dereference(gccLeft, null), gccRight);
			return emitVoid(ctx, emit);
	}
}

ExprResult binaryOperator(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	gcc_jit_binary_op op,
	ref LowExpr left,
	ref LowExpr right,
) =>
	operatorForLhsRhs(ctx, emit, type, op, emitToRValue(ctx, locals, left), emitToRValue(ctx, locals, right));

ExprResult operatorForLhsRhs(
	ref ExprCtx ctx,
	ExprEmit emit,
	LowType type,
	gcc_jit_binary_op op,
	gcc_jit_rvalue* lhs,
	gcc_jit_rvalue* rhs,
) =>
	emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_new_binary_op(
		ctx.gcc,
		null,
		op,
		getGccType(ctx.types, type),
		lhs,
		rhs));

enum PtrArith { addNat, subtractNat }

ExprResult ptrArithmeticToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	PtrArith op,
	ref LowExpr left,
	ref LowExpr right,
) {
	// `ptr + nat` is `&ptr[nat]`
	// `ptr - nat` is `&ptr[-(int) nat]`
	gcc_jit_rvalue* rightRValue = emitToRValue(ctx, locals, right);
	gcc_jit_rvalue* rightWithSign = () {
		final switch (op) {
			case PtrArith.addNat:
				return rightRValue;
			case PtrArith.subtractNat:
				immutable gcc_jit_type* int64Type = getGccType(ctx.types, LowType(PrimitiveType.int64));
				return gcc_jit_context_new_unary_op(
					ctx.gcc,
					null,
					gcc_jit_unary_op.GCC_JIT_UNARY_OP_MINUS,
					int64Type,
					gcc_jit_context_new_cast(
						ctx.gcc,
						null,
						rightRValue,
						int64Type));
		}
	}();
	return emitSimpleNoSideEffects(ctx, emit, gcc_jit_lvalue_get_address(
		gcc_jit_context_new_array_access(
			ctx.gcc,
			null,
			emitToRValue(ctx, locals, left),
			rightWithSign),
		null));
}

ExprResult ifToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	ref LowExpr cond,
	ref LowExpr then,
	ref LowExpr else_,
) {
	gcc_jit_rvalue* condValue = emitToRValue(ctx, locals, cond);
	return emitWithBranching(
		ctx, emit, type, "ifEnd",
		(
			gcc_jit_block* originalBlock,
			MutOpt!(gcc_jit_block*) endBlock,
			MutOpt!(gcc_jit_lvalue*) local,
			ExprResult expectedResult,
		) {
			gcc_jit_block* thenBlock = gcc_jit_function_new_block(ctx.curFun, "then");
			gcc_jit_block* elseBlock = gcc_jit_function_new_block(ctx.curFun, "else");
			gcc_jit_block_end_with_conditional(originalBlock, null, condValue, thenBlock, elseBlock);
			void branch(gcc_jit_block* block, ref LowExpr blockExpr) {
				ctx.curBlock = block;
				ExprResult result = {
					if (has(local)) {
						emitToLValue(ctx, locals, force(local), blockExpr);
						return ExprResult(ExprResult.Void());
					}	else
						return toGccExpr(ctx, locals, emit, blockExpr);
				}();
				if (has(endBlock) && !result.isA!(ExprResult.BreakContinueOrReturn)) {
					// A nested if may have changed the block, so use 'curBlock' and not just 'block'
					gcc_jit_block_end_with_jump(ctx.curBlock, null, force(endBlock));
				}
				assert(result == expectedResult);
			}
			branch(thenBlock, then);
			branch(elseBlock, else_);
		});
}

void emitSwitchCaseOrDefault(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	MutOpt!(gcc_jit_block*) endBlock,
	MutOpt!(gcc_jit_lvalue*) local,
	ExprResult expectedResult,
	ref LowExpr case_,
) {
	ExprResult result = () {
		if (has(local)) {
			emitToLValueCb(force(local), (ExprEmit emitLocal) =>
				toGccExpr(ctx, locals, emitLocal, case_));
			return ExprResult(ExprResult.Void());
		} else
			return toGccExpr(ctx, locals, emit, case_);
	}();
	assert(result == expectedResult);
	if (has(endBlock) && !result.isA!(ExprResult.BreakContinueOrReturn)) {
		// A nested branch may have changed to a new block, so use that instead of 'caseBlock'
		gcc_jit_block_end_with_jump(ctx.curBlock, null, force(endBlock));
	}
}

ExprResult switchToGcc(
	ref ExprCtx ctx,
	ref Locals locals,
	ExprEmit emit,
	LowType type,
	ref SwitchLowExpr a,
) {
	gcc_jit_rvalue* switchedValue = emitToRValue(ctx, locals, a.value);
	return emitWithBranching(
		ctx, emit, type, "switchEnd",
		(
			gcc_jit_block* originalBlock,
			MutOpt!(gcc_jit_block*) endBlock,
			MutOpt!(gcc_jit_lvalue*) local,
			ExprResult expectedResult,
		) @trusted {
			immutable gcc_jit_case*[] cases = mapWithIndex!(immutable gcc_jit_case*, LowExpr)(
				ctx.alloc, a.caseExprs,
				(size_t caseIndex, ref LowExpr case_) {
					gcc_jit_block* caseBlock = gcc_jit_function_new_block(ctx.curFun, "switchCase");
					ctx.curBlock = caseBlock;
					emitSwitchCaseOrDefault(ctx, locals, emit, endBlock, local, expectedResult, case_);
					gcc_jit_rvalue* caseValue =
						//TODO:PERF cache these?
						gcc_jit_context_new_rvalue_from_long(ctx.gcc, ctx.nat64Type, a.caseValues[caseIndex].value);
					return gcc_jit_context_new_case(ctx.gcc, caseValue, caseValue, caseBlock);
				});

			gcc_jit_block* defaultBlock = gcc_jit_function_new_block(ctx.curFun, "switchDefault");
			ctx.curBlock = defaultBlock;
			emitSwitchCaseOrDefault(ctx, locals, emit, endBlock, local, expectedResult, a.default_);

			gcc_jit_block_end_with_switch(
				originalBlock,
				null,
				// TODO: use cases of appropriate type?
				gcc_jit_context_new_cast(ctx.gcc, null, switchedValue, ctx.nat64Type),
				defaultBlock,
				safeToInt(cases.length),
				cases.ptr);
		});
}

ExprResult zeroedToGcc(ref ExprCtx ctx, ExprEmit emit, LowType type) {
	immutable gcc_jit_type* gccType = getGccType(ctx.types, type);
	return type.combinePointer.matchWithPointers!ExprResult(
		(LowExternType* x) =>
			externZeroedToGcc(ctx, emit, x),
		(LowFunPointerType*) =>
			emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_null(ctx.gcc, gccType)),
		(PrimitiveType x) =>
			x == PrimitiveType.void_
				? emitVoid(ctx, emit)
				: emitSimpleNoSideEffects(ctx, emit, zeroForPrimitiveType(ctx, x)),
		(LowPointerCombine _) =>
			emitSimpleNoSideEffects(ctx, emit, gcc_jit_context_null(ctx.gcc, gccType)),
		(LowRecord* record) =>
			emitRecordCb(ctx, emit, type, (size_t argIndex, ExprEmit emitArg) =>
				zeroedToGcc(ctx, emitArg, record.fields[argIndex].type)),
		(LowUnion* union_) =>
			isEmpty(union_.members)
				// No legal value of this type, so leave uninitialized.
				? emitWriteToLValue(ctx, emit, type, (gcc_jit_lvalue* lvalue) {})
				: emitUnion(ctx, emit, type, 0, (ExprEmit emitArg) =>
					zeroedToGcc(ctx, emitArg, union_.members[0])));
}

ExprResult externZeroedToGcc(ref ExprCtx ctx, ExprEmit emit, LowExternType* type) =>
	emitWriteToLValue(ctx, emit, LowType(type), (gcc_jit_lvalue* lvalue) {
		ExternTypeInfo info = ctx.types.extern_[ctx.program.indexOfExternType(type)];
		if (has(info.array)) {
			ExternTypeArrayInfo array = force(info.array);
			gcc_jit_rvalue* elementValue = zeroForPrimitiveType(ctx, PrimitiveType.nat8);
			//TODO: no alloc
			immutable gcc_jit_rvalue*[] elementValues = fillArray!(immutable gcc_jit_rvalue*)(
				ctx.alloc, array.elementCount, elementValue);
			gcc_jit_rvalue* arrayValue = gcc_jit_context_new_array_constructor(
				ctx.gcc,
				null,
				array.arrayType,
				elementValues.length,
				&elementValues[0]);
			gcc_jit_block_add_assignment(
				ctx.curBlock, null,
				gcc_jit_lvalue_access_field(lvalue, null, array.field), arrayValue);
		}
	});

gcc_jit_rvalue* zeroForPrimitiveType(ref ExprCtx ctx, PrimitiveType a) {
	immutable gcc_jit_type* gccType = getGccType(ctx.types, LowType(a));
	final switch (a) {
		case PrimitiveType.bool_:
		case PrimitiveType.char8:
		case PrimitiveType.char32:
		case PrimitiveType.int8:
		case PrimitiveType.int16:
		case PrimitiveType.int32:
		case PrimitiveType.int64:
		case PrimitiveType.nat8:
		case PrimitiveType.nat16:
		case PrimitiveType.nat32:
		case PrimitiveType.nat64:
			return gcc_jit_context_new_rvalue_from_long(ctx.gcc, gccType, 0);
		case PrimitiveType.float32:
		case PrimitiveType.float64:
			return gcc_jit_context_new_rvalue_from_double(ctx.gcc, gccType, 0);
		case PrimitiveType.void_:
			assert(false);
	}
}

gcc_jit_rvalue* arbitraryValue(ref ExprCtx ctx, LowType type) {
	gcc_jit_rvalue* nullValue() =>
		gcc_jit_context_null(ctx.gcc, getGccType(ctx.types, type));
	return type.combinePointer.matchIn!(gcc_jit_rvalue*)(
		(in LowExternType _) =>
			todo!(gcc_jit_rvalue*)("!"),
		(in LowFunPointerType _) =>
			nullValue(),
		(in PrimitiveType _) =>
			emitToRValueCb((ExprEmit emit) =>
				zeroedToGcc(ctx, emit, type)),
		(in LowPointerCombine _) =>
			nullValue(),
		(in LowRecord _) =>
			getRValueUsingLocal(ctx, type, (gcc_jit_lvalue*) {}),
		(in LowUnion _) =>
			getRValueUsingLocal(ctx, type, (gcc_jit_lvalue*) {}));
}

ExprResult initToGcc(ref ExprCtx ctx, ExprEmit emit, BuiltinFun.Init.Kind kind) {
	final switch (kind) {
		case BuiltinFun.Init.Kind.global:
			zip!(immutable gcc_jit_rvalue*[], ArrTypeAndConstantsLow)(
				ctx.globalsForConstants.arrs,
				ctx.program.allConstants.arrs,
				(ref immutable gcc_jit_rvalue*[] globals, ref ArrTypeAndConstantsLow tc) {
					zip!(immutable gcc_jit_rvalue*, immutable Constant[])(
						globals,
						tc.constants,
						(ref immutable gcc_jit_rvalue* global, ref Constant[] elements) {
							assert(!isEmpty(elements)); // Not sure how GCC would handle an empty global
							foreach (size_t index, Constant elementValue; elements) {
								gcc_jit_lvalue* elementLValue = gcc_jit_context_new_array_access(
									ctx.gcc,
									null,
									global,
									//TODO: maybe cache these values?
									gcc_jit_context_new_rvalue_from_long(ctx.gcc, ctx.nat64Type, index));
								emitToLValueCb(elementLValue, (ExprEmit emitElement) =>
									constantToGcc(ctx, emitElement, tc.elementType, elementValue));
							}
						});
				});
			zip!(gcc_jit_lvalue*[], PointerTypeAndConstantsLow)(
				ctx.globalsForConstants.pointers,
				ctx.program.allConstants.pointers,
				(ref gcc_jit_lvalue*[] globals, ref PointerTypeAndConstantsLow tc) {
					zip!(gcc_jit_lvalue*, Constant)(
						globals,
						tc.constants,
						(ref gcc_jit_lvalue* global, ref Constant value) {
							emitToLValueCb(global, (ExprEmit emitPointee) =>
								constantToGcc(ctx, emitPointee, tc.pointeeType, value));
						});
				});
			return emitVoid(ctx, emit);
		case BuiltinFun.Init.Kind.perThread:
			return emitVoid(ctx, emit);
	}
}

} // GccJitAvailable
