module lower.checkLowModel;

@safe @nogc pure nothrow:

import frontend.showModel : ShowCtx;
import lower.lowExprHelpers :
	boolType,
	char8Type,
	char32Type,
	float32Type,
	float64Type,
	int8Type,
	int16Type,
	int32Type,
	int64Type,
	nat8Type,
	nat16Type,
	nat32Type,
	nat64Type,
	voidType;
import model.concreteModel : ConcreteFun, ConcreteProgram, Constant;
import model.jsonOfConcreteModel : jsonOfConcreteStructRef;
import model.lowModel :
	AbortLowExpr,
	asNonGcPointee,
	asPointee,
	CallLowExpr,
	CallFunPointerLowExpr,
	CreateRecordLowExpr,
	CreateUnionLowExpr,
	FunPointerLowExpr,
	IfLowExpr,
	isPointerNonGc,
	isVoid,
	LetLowExpr,
	LocalGetLowExpr,
	LowFunBodyExtern,
	LowPointerConst,
	LowPointerGc,
	LowPointerMut,
	LocalPointerLowExpr,
	LocalSetLowExpr,
	LoopBreakLowExpr,
	LoopContinueLowExpr,
	LoopLowExpr,
	LowCommonTypes,
	LowExpr,
	LowExternType,
	LowField,
	LowFun,
	LowFunExprBody,
	LowFunPointerType,
	LowLocal,
	LowProgram,
	LowRecord,
	LowType,
	LowUnion,
	PointerCastLowExpr,
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
import model.model :
	Builtin4ary,
	BuiltinBinary,
	BuiltinBinaryMath,
	BuiltinFunInit,
	BuiltinTernary,
	BuiltinUnary,
	BuiltinUnaryMath,
	Program;
import model.showLowModel : writeFunName;
import util.alloc.alloc : Alloc;
import util.col.array : sizeEq;
import util.col.array : zip;
import util.json : field, Json, jsonObject, jsonString, kindField;
import util.opt : force, has, none, Opt, some;
import util.util : castNonScope, ptrTrustMe, stringOfEnum;
import util.writer : debugLogWithWriter, Writer;

void checkLowProgram(in ShowCtx showCtx, in Program program, in ConcreteProgram concreteProgram, in LowProgram a) {
	Ctx ctx = Ctx(ptrTrustMe(showCtx), ptrTrustMe(program), ptrTrustMe(concreteProgram), ptrTrustMe(a));
	foreach (ref LowFun fun; a.allFuns)
		checkLowFun(ctx, fun);
}

private:

const struct Ctx {
	@safe @nogc pure nothrow:

	ShowCtx* showCtx;
	Program* modelProgramPtr;
	ConcreteProgram* concreteProgramPtr;
	LowProgram* programPtr;

	ref Program modelProgram() return scope const =>
		*modelProgramPtr;
	ref ConcreteProgram concreteProgram() return scope const =>
		*concreteProgramPtr;
	ref LowProgram program() return scope const =>
		*programPtr;
}

struct FunCtx {
	@safe @nogc pure nothrow:

	Ctx* ctxPtr;
	immutable LowFun* funPtr;

	ref inout(Ctx) ctx() return scope inout =>
		*ctxPtr;

	ref LowFun fun() return scope const =>
		*funPtr;

	ref LowProgram program() return scope const =>
		ctx.program;

	ref LowCommonTypes commonTypes() return scope const =>
		program.commonTypes;
}

void checkLowFun(ref Ctx ctx, in LowFun fun) {
	fun.body_.matchIn!void(
		(in LowFunBodyExtern _) {},
		(in LowFunExprBody x) {
			FunCtx funCtx = FunCtx(ptrTrustMe(ctx), ptrTrustMe(fun));
			checkLowExpr(funCtx, fun.returnType, x.expr, ExprPos.tail);
		});
}

enum ExprPos { nonTail, tail, loop }

void checkLowExpr(ref FunCtx ctx, in LowType type, in LowExpr expr, in ExprPos exprPos) {
	checkTypeEqual(ctx, type, expr.type);
	expr.kind.matchIn!void(
		(in AbortLowExpr _) {},
		(in CallLowExpr x) {
			LowFun* fun = &ctx.program.allFuns[x.called];
			assert(
				!fun.mayYield ||
				ctx.fun.mayYield ||
				ctx.fun.source.as!(ConcreteFun*) == ctx.ctx.concreteProgram.commonFuns.runFiber);
			checkTypeEqual(ctx, type, fun.returnType);
			zip!(LowLocal, LowExpr)(fun.params, x.args, (ref LowLocal param, ref LowExpr arg) {
				checkLowExpr(ctx, param.type, arg, ExprPos.nonTail);
			});
		},
		(in CallFunPointerLowExpr x) {
			checkTypeEqual(ctx, type, x.funPointerType.returnType);
			assert(sizeEq(x.funPointerType.paramTypes, x.args));
			zip!(LowType, LowExpr)(x.funPointerType.paramTypes, x.args, (ref LowType paramType, ref LowExpr arg) {
				checkLowExpr(ctx, paramType, arg, ExprPos.nonTail);
			});
		},
		(in CreateRecordLowExpr x) {
			zip!(LowField, LowExpr)(type.as!(LowRecord*).fields, x.args, (ref LowField field, ref LowExpr arg) {
				checkLowExpr(ctx, field.type, arg, ExprPos.nonTail);
			});
		},
		(in CreateUnionLowExpr x) {
			checkLowExpr(ctx, type.as!(LowUnion*).members[x.memberIndex], x.arg, ExprPos.nonTail);
		},
		(in FunPointerLowExpr x) {
			// TODO
		},
		(in IfLowExpr it) {
			checkLowExpr(ctx, boolType, it.cond, ExprPos.nonTail);
			checkLowExpr(ctx, type, it.then, exprPos);
			checkLowExpr(ctx, type, it.else_, exprPos);
		},
		(in BuiltinFunInit _) {
			assert(isVoid(type));
		},
		(in LetLowExpr x) {
			checkLowExpr(ctx, x.local.type, x.value, ExprPos.nonTail);
			checkLowExpr(ctx, type, x.then, exprPos);
		},
		(in LocalGetLowExpr x) {
			checkTypeEqual(ctx, type, x.local.type);
		},
		(in LocalPointerLowExpr x) {
			checkTypeEqual(ctx, asNonGcPointee(type), x.local.type);
		},
		(in LocalSetLowExpr x) {
			checkTypeEqual(ctx, type, voidType);
			checkLowExpr(ctx, x.local.type, x.value, ExprPos.nonTail);
		},
		(in LoopLowExpr x) {
			checkLowExpr(ctx, type, x.body_, ExprPos.loop);
		},
		(in LoopBreakLowExpr x) {
			checkLowExpr(ctx, type, x.value, ExprPos.nonTail);
		},
		(in LoopContinueLowExpr x) {
			assert(exprPos == ExprPos.loop);
		},
		(in PointerCastLowExpr x) {
			// TODO: there are some limitations on target...
			checkLowExpr(ctx, x.target.type, x.target, ExprPos.nonTail);
		},
		(in RecordFieldGetLowExpr x) {
			checkLowExpr(ctx, x.target.type, *x.target, ExprPos.nonTail);
			LowType fieldType = x.targetRecordType.fields[x.fieldIndex].type;
			checkTypeEqual(ctx, type, fieldType);
		},
		(in RecordFieldPointerLowExpr x) {
			checkLowExpr(ctx, x.target.type, *x.target, ExprPos.nonTail);
			LowType fieldType = x.targetRecordType.fields[x.fieldIndex].type;
			checkTypeEqual(ctx, asNonGcPointee(type), fieldType);
		},
		(in RecordFieldSetLowExpr x) {
			checkLowExpr(ctx, x.target.type, x.target, ExprPos.nonTail);
			LowType fieldType = x.targetRecordType.fields[x.fieldIndex].type;
			checkLowExpr(ctx, fieldType, x.value, ExprPos.nonTail);
			checkTypeEqual(ctx, type, voidType);
		},
		(in Constant _) {
			// Constants are untyped, so can't check more
		},
		(in SpecialUnaryLowExpr x) {
			checkSpecialUnary(ctx, type, x);
		},
		(in SpecialUnaryMathLowExpr x) {
			LowType actual = unaryMathType(x.kind);
			checkTypeEqual(ctx, type, actual);
			checkLowExpr(ctx, actual, x.arg, ExprPos.nonTail);
		},
		(in SpecialBinaryLowExpr it) {
			checkSpecialBinary(ctx, type, it, exprPos);
		},
		(in SpecialBinaryMathLowExpr x) {
			LowType actual = binaryMathType(x.kind);
			checkTypeEqual(ctx, type, actual);
			foreach (scope ref LowExpr arg; castNonScope(x.args))
				checkLowExpr(ctx, actual, arg, ExprPos.nonTail);
		},
		(in SpecialTernaryLowExpr x) {
			final switch (x.kind) {
				case BuiltinTernary.interpreterBacktrace:
					// TODO
					break;
			}
		},
		(in Special4aryLowExpr x) {
			final switch (x.kind) {
				case Builtin4ary.switchFiberInitial:
					checkTypeEqual(ctx, type, voidType);
					checkLowExpr(ctx, ctx.commonTypes.fiberReference, x.args[0], ExprPos.nonTail);
					checkLowExpr(ctx, ctx.commonTypes.nat64MutPointerMutPointer, x.args[1], ExprPos.nonTail);
					checkLowExpr(ctx, ctx.commonTypes.nat64MutPointer, x.args[2], ExprPos.nonTail);
					// TODO: x.args[3] is a 'void function(a fiber)'
					break;
			}
		},
		(in SwitchLowExpr x) {
			checkLowExpr(ctx, x.value.type, x.value, ExprPos.nonTail);
			foreach (ref LowExpr case_; x.caseExprs)
				checkLowExpr(ctx, type, case_, exprPos);
		},
		(in TailRecurLowExpr x) {
			assert(exprPos == ExprPos.tail);
			foreach (ref UpdateParam update; x.updateParams)
				checkLowExpr(ctx, update.param.type, update.newValue, ExprPos.nonTail);
		},
		(in UnionAsLowExpr x) {
			checkTypeEqual(ctx, type, x.union_.type.as!(LowUnion*).members[x.memberIndex]);
			checkLowExpr(ctx, x.union_.type, *x.union_, ExprPos.nonTail);
		},
		(in UnionKindLowExpr x) {
			checkTypeEqual(ctx, type, LowType(PrimitiveType.nat64));
			checkLowExpr(ctx, x.union_.type, *x.union_, ExprPos.nonTail);
		},
		(in VarGetLowExpr x) {
			checkTypeEqual(ctx, type, ctx.program.vars[x.varIndex].type);
		},
		(in VarSetLowExpr x) {
			checkTypeEqual(ctx, type, voidType);
			checkLowExpr(ctx, ctx.program.vars[x.varIndex].type, *x.value, ExprPos.nonTail);
		});
}

void checkSpecialUnary(ref FunCtx ctx, in LowType type, in SpecialUnaryLowExpr a) {
	ExpectUnary expected = unaryExpected(ctx.commonTypes, a.kind, type, a.arg.type);
	if (has(expected.return_))
		checkTypeEqual(ctx, force(expected.return_), type);
	checkLowExpr(ctx, has(expected.arg) ? force(expected.arg) : a.arg.type, a.arg, ExprPos.nonTail);
}

ExpectUnary unaryExpected(
	ref LowCommonTypes commonTypes,
	BuiltinUnary kind,
	return scope LowType returnType,
	return scope LowType argType,
) {
	final switch (kind) {
		case BuiltinUnary.asFuture:
		case BuiltinUnary.asFutureImpl:
		case BuiltinUnary.asMutArray:
		case BuiltinUnary.asMutArrayImpl:
		case BuiltinUnary.arraySize:
		case BuiltinUnary.arrayPointer:
		case BuiltinUnary.cStringOfSymbol:
		case BuiltinUnary.symbolOfCString:
		case BuiltinUnary.toChar8ArrayFromString:
		case BuiltinUnary.trustAsString:
		case BuiltinUnary.weakRefGet:
			// done in lower
			assert(false);
		case BuiltinUnary.referenceFromPointer:
		case BuiltinUnary.asAnyPointer:
			//TODO: returns one of anyPtrConstType or anyPtrMutType. Maybe split these up
			return ExpectUnary();
		case BuiltinUnary.bitsOfFloat32:
			return expect(nat32Type, float32Type);
		case BuiltinUnary.bitsOfFloat64:
			return expect(nat64Type, float64Type);
		case BuiltinUnary.bitwiseNotNat8:
			return expect(nat8Type, nat8Type);
		case BuiltinUnary.bitwiseNotNat16:
			return expect(nat16Type, nat16Type);
		case BuiltinUnary.bitwiseNotNat32:
			return expect(nat32Type, nat32Type);
		case BuiltinUnary.bitwiseNotNat64:
		case BuiltinUnary.countOnesNat64:
			return expect(nat64Type, nat64Type);
		case BuiltinUnary.deref:
			return ExpectUnary(some(asPointee(argType)), none!LowType);
		case BuiltinUnary.drop:
			return ExpectUnary(some(voidType), none!LowType);
		case BuiltinUnary.float32FromBits:
			return expect(float32Type, nat32Type);
		case BuiltinUnary.float64FromBits:
			return expect(float64Type, nat64Type);
		case BuiltinUnary.isNanFloat32:
			return expect(boolType, float32Type);
		case BuiltinUnary.isNanFloat64:
			return expect(boolType, float64Type);
		case BuiltinUnary.jumpToCatch:
			return expect(voidType, commonTypes.catchPointConstPointer);
		case BuiltinUnary.not:
			return expect(boolType, boolType);
		case BuiltinUnary.setupCatch:
			return expect(boolType, commonTypes.catchPointMutPointer);
		case BuiltinUnary.toChar8FromNat8:
			return expect(char8Type, nat8Type);
		case BuiltinUnary.toFloat32FromFloat64:
			return expect(float32Type, float64Type);
		case BuiltinUnary.toFloat64FromFloat32:
			return expect(float64Type, float32Type);
		case BuiltinUnary.toFloat64FromInt64:
			return expect(float64Type, int64Type);
		case BuiltinUnary.toFloat64FromNat64:
			return expect(float64Type, nat64Type);
		case BuiltinUnary.toInt64FromInt8:
			return expect(int64Type, int8Type);
		case BuiltinUnary.toInt64FromInt16:
			return expect(int64Type, int16Type);
		case BuiltinUnary.toInt64FromInt32:
			return expect(int64Type, int32Type);
		case BuiltinUnary.toNat8FromChar8:
			return expect(nat8Type, char8Type);
		case BuiltinUnary.toNat32FromChar32:
			return expect(nat32Type, char32Type);
		case BuiltinUnary.toNat64FromNat8:
			return expect(nat64Type, nat8Type);
		case BuiltinUnary.toNat64FromNat16:
			return expect(nat64Type, nat16Type);
		case BuiltinUnary.toNat64FromNat32:
			return expect(nat64Type, nat32Type);
		case BuiltinUnary.toNat64FromPtr:
			assert(isPointerNonGc(argType));
			return ExpectUnary(some(nat64Type), none!LowType);
		case BuiltinUnary.toPtrFromNat64:
			assert(isPointerNonGc(returnType));
			return ExpectUnary(none!LowType, some(nat64Type));
		case BuiltinUnary.truncateToInt64FromFloat64:
			return expect(int64Type, float64Type);
		case BuiltinUnary.unsafeToChar32FromChar8:
			return expect(char32Type, char8Type);
		case BuiltinUnary.unsafeToChar32FromNat32:
			return expect(char32Type, nat32Type);
		case BuiltinUnary.unsafeToInt8FromInt64:
			return expect(int8Type, int64Type);
		case BuiltinUnary.unsafeToInt16FromInt64:
			return expect(int16Type, int64Type);
		case BuiltinUnary.unsafeToInt32FromInt64:
			return expect(int32Type, int64Type);
		case BuiltinUnary.unsafeToInt64FromNat64:
			return expect(int64Type, nat64Type);
		case BuiltinUnary.unsafeToNat8FromNat64:
			return expect(nat8Type, nat64Type);
		case BuiltinUnary.unsafeToNat16FromNat64:
			return expect(nat16Type, nat64Type);
		case BuiltinUnary.unsafeToNat32FromInt32:
			return expect(nat32Type, int32Type);
		case BuiltinUnary.unsafeToNat32FromNat64:
			return expect(nat32Type, nat64Type);
		case BuiltinUnary.unsafeToNat64FromInt64:
			return expect(nat64Type, int64Type);
	}
}

LowType unaryMathType(BuiltinUnaryMath kind) {
	final switch (kind) {
		case BuiltinUnaryMath.acosFloat32:
		case BuiltinUnaryMath.acoshFloat32:
		case BuiltinUnaryMath.asinFloat32:
		case BuiltinUnaryMath.asinhFloat32:
		case BuiltinUnaryMath.atanFloat32:
		case BuiltinUnaryMath.atanhFloat32:
		case BuiltinUnaryMath.cosFloat32:
		case BuiltinUnaryMath.coshFloat32:
		case BuiltinUnaryMath.roundDownFloat32:
		case BuiltinUnaryMath.roundFloat32:
		case BuiltinUnaryMath.roundUpFloat32:
		case BuiltinUnaryMath.sinFloat32:
		case BuiltinUnaryMath.sinhFloat32:
		case BuiltinUnaryMath.sqrtFloat32:
		case BuiltinUnaryMath.tanFloat32:
		case BuiltinUnaryMath.tanhFloat32:
		case BuiltinUnaryMath.unsafeLogFloat32:
			return float32Type;
		case BuiltinUnaryMath.acosFloat64:
		case BuiltinUnaryMath.acoshFloat64:
		case BuiltinUnaryMath.asinFloat64:
		case BuiltinUnaryMath.asinhFloat64:
		case BuiltinUnaryMath.atanFloat64:
		case BuiltinUnaryMath.atanhFloat64:
		case BuiltinUnaryMath.cosFloat64:
		case BuiltinUnaryMath.coshFloat64:
		case BuiltinUnaryMath.roundDownFloat64:
		case BuiltinUnaryMath.roundFloat64:
		case BuiltinUnaryMath.roundUpFloat64:
		case BuiltinUnaryMath.sinFloat64:
		case BuiltinUnaryMath.sinhFloat64:
		case BuiltinUnaryMath.tanFloat64:
		case BuiltinUnaryMath.tanhFloat64:
		case BuiltinUnaryMath.sqrtFloat64:
		case BuiltinUnaryMath.unsafeLogFloat64:
			return float64Type;
	}
}

immutable struct ExpectUnary {
	Opt!LowType return_;
	Opt!LowType arg;
}
ExpectUnary expect() =>
	ExpectUnary(none!LowType, none!LowType);
ExpectUnary expect(LowType return_, LowType arg) =>
	ExpectUnary(some(return_), some(arg));

void checkSpecialBinary(ref FunCtx ctx, in LowType type, in SpecialBinaryLowExpr a, in ExprPos exprPos) {
	ExpectBinary expected = binaryExpected(ctx.commonTypes, a.kind, type, a.args[0].type, a.args[1].type);
	if (has(expected.return_))
		checkTypeEqual(ctx, force(expected.return_), type);
	foreach (size_t i; 0 .. a.args.length)
		checkLowExpr(
			ctx, has(expected.args[i]) ? force(expected.args[i]) : a.args[i].type, a.args[i],
			i == 1 && canTailRecurse(a.kind) ? exprPos : ExprPos.nonTail);
}

bool canTailRecurse(BuiltinBinary a) =>
	a == BuiltinBinary.seq;

ExpectBinary binaryExpected(
	ref LowCommonTypes commonTypes,
	in BuiltinBinary kind,
	in LowType returnType,
	return scope LowType arg0Type,
	in LowType arg1Type,
) {
	final switch (kind) {
		case BuiltinBinary.addFloat32:
		case BuiltinBinary.mulFloat32:
		case BuiltinBinary.subFloat32:
		case BuiltinBinary.unsafeDivFloat32:
			return expect(float32Type, float32Type, float32Type);
		case BuiltinBinary.addFloat64:
		case BuiltinBinary.mulFloat64:
		case BuiltinBinary.subFloat64:
		case BuiltinBinary.unsafeDivFloat64:
			return expect(float64Type, float64Type, float64Type);
		case BuiltinBinary.addPointerAndNat64:
		case BuiltinBinary.subPointerAndNat64:
			assert(returnType == arg0Type);
			assert(isPointerNonGc(returnType));
			return ExpectBinary(none!LowType, [none!LowType, some(nat64Type)]);
		case BuiltinBinary.bitwiseAndInt8:
		case BuiltinBinary.bitwiseOrInt8:
		case BuiltinBinary.bitwiseXorInt8:
		case BuiltinBinary.unsafeAddInt8:
		case BuiltinBinary.unsafeDivInt8:
		case BuiltinBinary.unsafeMulInt8:
		case BuiltinBinary.unsafeSubInt8:
			return expect(int8Type, int8Type, int8Type);
		case BuiltinBinary.bitwiseAndInt16:
		case BuiltinBinary.bitwiseOrInt16:
		case BuiltinBinary.bitwiseXorInt16:
		case BuiltinBinary.unsafeAddInt16:
		case BuiltinBinary.unsafeDivInt16:
		case BuiltinBinary.unsafeMulInt16:
		case BuiltinBinary.unsafeSubInt16:
			return expect(int16Type, int16Type, int16Type);
		case BuiltinBinary.bitwiseAndInt32:
		case BuiltinBinary.bitwiseOrInt32:
		case BuiltinBinary.bitwiseXorInt32:
		case BuiltinBinary.unsafeAddInt32:
		case BuiltinBinary.unsafeDivInt32:
		case BuiltinBinary.unsafeMulInt32:
		case BuiltinBinary.unsafeSubInt32:
			return expect(int32Type, int32Type, int32Type);
		case BuiltinBinary.bitwiseAndInt64:
		case BuiltinBinary.bitwiseOrInt64:
		case BuiltinBinary.bitwiseXorInt64:
		case BuiltinBinary.unsafeAddInt64:
		case BuiltinBinary.unsafeDivInt64:
		case BuiltinBinary.unsafeMulInt64:
		case BuiltinBinary.unsafeSubInt64:
			return expect(int64Type, int64Type, int64Type);
		case BuiltinBinary.bitwiseAndNat8:
		case BuiltinBinary.bitwiseOrNat8:
		case BuiltinBinary.bitwiseXorNat8:
		case BuiltinBinary.unsafeAddNat8:
		case BuiltinBinary.unsafeDivNat8:
		case BuiltinBinary.unsafeMulNat8:
		case BuiltinBinary.unsafeSubNat8:
		case BuiltinBinary.wrapAddNat8:
		case BuiltinBinary.wrapMulNat8:
		case BuiltinBinary.wrapSubNat8:
			return expect(nat8Type, nat8Type, nat8Type);
		case BuiltinBinary.bitwiseAndNat16:
		case BuiltinBinary.bitwiseOrNat16:
		case BuiltinBinary.bitwiseXorNat16:
		case BuiltinBinary.unsafeAddNat16:
		case BuiltinBinary.unsafeDivNat16:
		case BuiltinBinary.unsafeMulNat16:
		case BuiltinBinary.unsafeSubNat16:
		case BuiltinBinary.wrapAddNat16:
		case BuiltinBinary.wrapMulNat16:
		case BuiltinBinary.wrapSubNat16:
			return expect(nat16Type, nat16Type, nat16Type);
		case BuiltinBinary.bitwiseAndNat32:
		case BuiltinBinary.bitwiseOrNat32:
		case BuiltinBinary.bitwiseXorNat32:
		case BuiltinBinary.unsafeAddNat32:
		case BuiltinBinary.unsafeDivNat32:
		case BuiltinBinary.unsafeMulNat32:
		case BuiltinBinary.unsafeSubNat32:
		case BuiltinBinary.wrapAddNat32:
		case BuiltinBinary.wrapMulNat32:
		case BuiltinBinary.wrapSubNat32:
			return expect(nat32Type, nat32Type, nat32Type);
		case BuiltinBinary.bitwiseAndNat64:
		case BuiltinBinary.bitwiseOrNat64:
		case BuiltinBinary.bitwiseXorNat64:
		case BuiltinBinary.unsafeBitShiftLeftNat64:
		case BuiltinBinary.unsafeBitShiftRightNat64:
		case BuiltinBinary.unsafeAddNat64:
		case BuiltinBinary.unsafeDivNat64:
		case BuiltinBinary.unsafeModNat64:
		case BuiltinBinary.unsafeMulNat64:
		case BuiltinBinary.unsafeSubNat64:
		case BuiltinBinary.wrapAddNat64:
		case BuiltinBinary.wrapMulNat64:
		case BuiltinBinary.wrapSubNat64:
			return expect(nat64Type, nat64Type, nat64Type);
		case BuiltinBinary.equalChar8:
			return expect(boolType, char8Type, char8Type);
		case BuiltinBinary.equalChar32:
			return expect(boolType, char32Type, char32Type);
		case BuiltinBinary.equalFloat32:
		case BuiltinBinary.lessFloat32:
			return expect(boolType, float32Type, float32Type);
		case BuiltinBinary.equalFloat64:
		case BuiltinBinary.lessFloat64:
			return expect(boolType, float64Type, float64Type);
		case BuiltinBinary.equalInt8:
		case BuiltinBinary.lessInt8:
			return expect(boolType, int8Type, int8Type);
		case BuiltinBinary.equalInt16:
		case BuiltinBinary.lessInt16:
			return expect(boolType, int16Type, int16Type);
		case BuiltinBinary.equalInt32:
		case BuiltinBinary.lessInt32:
			return expect(boolType, int32Type, int32Type);
		case BuiltinBinary.equalInt64:
		case BuiltinBinary.lessInt64:
			return expect(boolType, int64Type, int64Type);
		case BuiltinBinary.equalNat8:
		case BuiltinBinary.lessNat8:
			return expect(boolType, nat8Type, nat8Type);
		case BuiltinBinary.equalNat16:
		case BuiltinBinary.lessNat16:
			return expect(boolType, nat16Type, nat16Type);
		case BuiltinBinary.equalNat32:
		case BuiltinBinary.lessNat32:
			return expect(boolType, nat32Type, nat32Type);
		case BuiltinBinary.equalNat64:
		case BuiltinBinary.lessNat64:
			return expect(boolType, nat64Type, nat64Type);
		case BuiltinBinary.equalPointer:
		case BuiltinBinary.lessPointer:
		case BuiltinBinary.referenceEqual:
			assert(arg0Type == arg1Type);
			return ExpectBinary(some(boolType), [none!LowType, none!LowType]);
		case BuiltinBinary.lessChar8:
			return expect(boolType, char8Type, char8Type);
		case BuiltinBinary.newArray:
			assert(false);
		case BuiltinBinary.seq:
			assert(returnType == arg1Type);
			return ExpectBinary(none!LowType, [some(voidType), none!LowType]);
		case BuiltinBinary.switchFiber:
			return expect(voidType, commonTypes.nat64MutPointerMutPointer, commonTypes.nat64MutPointer);
		case BuiltinBinary.writeToPointer:
			return ExpectBinary(some(voidType), [none!LowType, some(asPointee(arg0Type))]);
	}
}

LowType binaryMathType(BuiltinBinaryMath kind) {
	final switch (kind) {
		case BuiltinBinaryMath.atan2Float32:
		case BuiltinBinaryMath.unsafePowFloat32:
		case BuiltinBinaryMath.fmodFloat32:
			return float32Type;
		case BuiltinBinaryMath.fmodFloat64:
		case BuiltinBinaryMath.atan2Float64:
		case BuiltinBinaryMath.unsafePowFloat64:
			return float64Type;
	}
}

immutable struct ExpectBinary {
	Opt!LowType return_;
	Opt!LowType[2] args;
}
ExpectBinary expect(LowType return_, LowType arg0, LowType arg1) =>
	ExpectBinary(some(return_), [some(arg0), some(arg1)]);

void checkTypeEqual(in FunCtx ctx, in LowType expected, in LowType actual) {
	if (expected != actual)
		debugLogWithWriter((scope ref Alloc alloc, scope ref Writer writer) {
			writer ~= "In ";
			writeFunName(writer, *ctx.ctx.showCtx, ctx.program, ctx.fun);
			writer ~= ":\nType is not as expected. Expected:\n";
			writer ~= jsonOfLowType2(alloc, ctx.program, expected);
			writer ~= "\nActual:\n";
			writer ~= jsonOfLowType2(alloc, ctx.program, actual);
		});
	assert(expected == actual);
}

Json jsonOfLowType2(ref Alloc alloc, in LowProgram program, in LowType a) =>
	a.matchIn!Json(
		(in LowExternType _) =>
			jsonString!"some-extern", //TODO: more detail
		(in LowFunPointerType _) =>
			jsonString!"some-fun-ptr", //TODO: more detail
		(in PrimitiveType x) =>
			jsonString(stringOfEnum(x)),
		(in LowPointerGc x) =>
			jsonObject(alloc, [
				kindField!"pointer-gc",
				field!"pointee"(jsonOfLowType2(alloc, program, *x.pointee))]),
		(in LowPointerConst x) =>
			jsonObject(alloc, [
				kindField!"pointer-const",
				field!"pointee"(jsonOfLowType2(alloc, program, *x.pointee))]),
		(in LowPointerMut x) =>
			jsonObject(alloc, [
				kindField!"pointer-mut",
				field!"pointee"(jsonOfLowType2(alloc, program, *x.pointee))]),
		(in LowRecord x) =>
			jsonOfConcreteStructRef(alloc, *x.source),
		(in LowUnion x) =>
			jsonOfConcreteStructRef(alloc, *x.source));
