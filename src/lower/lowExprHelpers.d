module lower.lowExprHelpers;

@safe @nogc pure nothrow:

import model.concreteModel : ConcreteFun;
import model.constant : Constant, constantZero;
import model.model : Builtin4ary, BuiltinUnary, BuiltinUnaryMath, BuiltinBinary, BuiltinBinaryMath, BuiltinTernary;
import model.lowModel :
	asPointee,
	AllLowTypes,
	debugName,
	isPointerNonGc,
	LowExpr,
	LowExprKind,
	LowFunIndex,
	LowLocal,
	LowLocalSource,
	LowRecord,
	LowType,
	LowVarIndex,
	PrimitiveType;
import model.typeLayout : typeSizeBytes;
import util.alloc.alloc : Alloc;
import util.col.array : mapWithIndex, newArray, small, SmallArray;
import util.conv : safeToUint;
import util.integralValues : IntegralValue, integralValuesRange;
import util.memory : allocate;
import util.sourceRange : UriAndRange;
import util.symbol : Symbol, symbol;

LowType boolType() => LowType(PrimitiveType.bool_);
LowType char8Type() => LowType(PrimitiveType.char8);
LowType char32Type() => LowType(PrimitiveType.char32);
LowType float32Type() => LowType(PrimitiveType.float32);
LowType float64Type() => LowType(PrimitiveType.float64);
LowType int8Type() => LowType(PrimitiveType.int8);
LowType int16Type() => LowType(PrimitiveType.int16);
LowType int32Type() => LowType(PrimitiveType.int32);
LowType int64Type() => LowType(PrimitiveType.int64);
LowType nat8Type() => LowType(PrimitiveType.nat8);
LowType nat16Type() => LowType(PrimitiveType.nat16);
LowType nat32Type() => LowType(PrimitiveType.nat32);
LowType nat64Type() => LowType(PrimitiveType.nat64);
LowType voidType() => LowType(PrimitiveType.void_);

LowExpr genAbort(LowType type, UriAndRange range) =>
	LowExpr(type, range, LowExprKind(LowExprKind.Abort()));

LowExpr genUnionAs(LowType asType, UriAndRange range, LowExpr* union_, uint memberIndex) =>
	LowExpr(asType, range, LowExprKind(LowExprKind.UnionAs(union_, memberIndex)));

LowExpr genUnionKind(UriAndRange range, LowExpr* union_) =>
	LowExpr(nat64Type, range, LowExprKind(LowExprKind.UnionKind(union_)));

LowExpr genUnionMatch(
	ref Alloc alloc,
	LowType type,
	UriAndRange range,
	LowExpr getUnion,
	SmallArray!LowType unionMembers,
	in LowExpr delegate(size_t, LowExpr) @safe @nogc pure nothrow cbCase,
) {
	assert(getUnion.kind.isA!(LowExprKind.LocalGet));
	LowExpr* getUnionPtr = allocate(alloc, getUnion);
	return LowExpr(type, range, LowExprKind(allocate(alloc,
		LowExprKind.Switch(
			genUnionKind(range, getUnionPtr),
			integralValuesRange(unionMembers.length),
			mapWithIndex!(LowExpr, LowType)(
				alloc, unionMembers, (size_t memberIndex, ref LowType memberType) =>
					cbCase(memberIndex, genUnionAs(memberType, range, getUnionPtr, safeToUint(memberIndex)))),
			genAbort(type, range)))));
}

LowExpr genUnary(ref Alloc alloc, LowType type, UriAndRange range, BuiltinUnary kind, LowExpr arg) =>
	LowExpr(type, range, LowExprKind(LowExprKind.SpecialUnary(kind, allocate(alloc, arg))));
LowExpr genUnaryMath(ref Alloc alloc, LowType type, UriAndRange range, BuiltinUnaryMath kind, LowExpr arg) =>
	LowExpr(type, range, LowExprKind(LowExprKind.SpecialUnaryMath(kind, allocate(alloc, arg))));
LowExpr genBinary(
	ref Alloc alloc, LowType type, UriAndRange range, BuiltinBinary kind, LowExpr arg0, LowExpr arg1,
) =>
	LowExpr(type, range, LowExprKind(LowExprKind.SpecialBinary(kind, allocate!(LowExpr[2])(alloc, [arg0, arg1]))));
LowExpr genBinaryMath(
	ref Alloc alloc, LowType type, UriAndRange range, BuiltinBinaryMath kind, LowExpr arg0, LowExpr arg1,
) =>
	LowExpr(type, range, LowExprKind(LowExprKind.SpecialBinaryMath(kind, allocate!(LowExpr[2])(alloc, [arg0, arg1]))));
LowExpr genTernary(
	ref Alloc alloc,
	LowType type,
	UriAndRange range,
	BuiltinTernary kind,
	LowExpr arg0,
	LowExpr arg1,
	LowExpr arg2,
) =>
	LowExpr(type, range, LowExprKind(LowExprKind.SpecialTernary(
		kind, allocate!(LowExpr[3])(alloc, [arg0, arg1, arg2]))));
LowExpr gen4ary(
	ref Alloc alloc,
	LowType type,
	UriAndRange range,
	Builtin4ary kind,
	LowExpr arg0,
	LowExpr arg1,
	LowExpr arg2,
	LowExpr arg3,
) =>
	LowExpr(type, range, LowExprKind(LowExprKind.Special4ary(
		kind, allocate!(LowExpr[4])(alloc, [arg0, arg1, arg2, arg3]))));

LowExpr genAddPointer(ref Alloc alloc, LowType.PointerConst ptrType, UriAndRange range, LowExpr ptr, LowExpr added) =>
	genBinary(alloc, LowType(ptrType), range, BuiltinBinary.addPointerAndNat64, ptr, added);

LowExpr genLocalPointer(LowType type, UriAndRange range, LowLocal* local) =>
	LowExpr(type, range, LowExprKind(LowExprKind.LocalPointer(local)));

LowExpr genFunPointer(LowType type, UriAndRange range, ConcreteFun* fun) =>
	LowExpr(type, range, LowExprKind(Constant(Constant.FunPointer(fun))));
LowExpr genFunPointer(LowType type, UriAndRange range, LowFunIndex fun) =>
	LowExpr(type, range, LowExprKind(LowExprKind.FunPointer(fun)));

LowExpr genDrop(ref Alloc alloc, UriAndRange range, LowExpr a) =>
	a.type == voidType ? a : genUnary(alloc, voidType, range, BuiltinUnary.drop, a);

private LowExpr genDerefGcOrRawPointer(ref Alloc alloc, UriAndRange range, LowExpr ptr) =>
	genUnary(alloc, asPointee(ptr.type), range, BuiltinUnary.deref, ptr);

LowExpr genDerefGcPointer(ref Alloc alloc, UriAndRange range, LowExpr ptr) =>
	genDerefGcOrRawPointer(alloc, range, ptr);

LowExpr genDerefRawPointer(ref Alloc alloc, UriAndRange range, LowExpr ptr) =>
	genDerefGcOrRawPointer(alloc, range, ptr);

LowExpr genIf(ref Alloc alloc, UriAndRange range, LowExpr cond, LowExpr then, LowExpr else_) =>
	LowExpr(then.type, range, LowExprKind(allocate(alloc, LowExprKind.If(cond, then, else_))));

LowExpr genIncrPointer(ref Alloc alloc, UriAndRange range, LowType.PointerConst pointerType, LowExpr pointer) =>
	genAddPointer(alloc, pointerType, range, pointer, genConstantNat64(range, 1));

LowExpr genFalse(UriAndRange range) =>
	genConstantBool(range, false);
LowExpr genTrue(UriAndRange range) =>
	genConstantBool(range, true);
private LowExpr genConstantBool(UriAndRange range, bool value) =>
	genConstantIntegral(boolType, range, value);

LowExpr genConstantNat64(UriAndRange range, ulong value) =>
	genConstantIntegral(nat64Type, range, value);

private LowExpr genConstantIntegral(LowType type, UriAndRange range, ulong value) =>
	LowExpr(type, range, LowExprKind(Constant(IntegralValue(value))));

private LowExpr genNull(LowType type, UriAndRange range) =>
	LowExpr(type, range, LowExprKind(constantZero));

LowExpr genCallFunPointerNoGcRoots(LowType type, UriAndRange range, LowExpr* funPtr, SmallArray!LowExpr args) =>
	LowExpr(type, range, LowExprKind(LowExprKind.CallFunPointer(funPtr, args)));

LowExpr genCallNoGcRoots(LowType type, UriAndRange range, LowFunIndex called, LowExpr[] args) =>
	LowExpr(type, range, LowExprKind(LowExprKind.Call(called, small!LowExpr(args))));
LowExpr genCallNoGcRoots(ref Alloc alloc, LowType type, UriAndRange range, LowFunIndex called, in LowExpr[] args) =>
	genCallNoGcRoots(type, range, called, newArray(alloc, args));
LowExpr genSizeOf(in AllLowTypes allTypes, UriAndRange range, LowType t) =>
	genConstantNat64(range, typeSizeBytes(allTypes, t));

LowExpr genIdentifier(UriAndRange range, LowLocal* local) =>
	LowExpr(local.type, range, LowExprKind(LowExprKind.LocalGet(local)));

LowExpr genLocalSet(ref Alloc alloc, UriAndRange range, LowLocal* local, LowExpr value) =>
	LowExpr(voidType, range, LowExprKind(allocate(alloc, LowExprKind.LocalSet(local, value))));

LowExpr genWrapMulNat64(ref Alloc alloc, UriAndRange range, LowExpr left, LowExpr right) =>
	genBinary(alloc, nat64Type, range, BuiltinBinary.wrapMulNat64, left, right);

LowExpr genPointerEqual(ref Alloc alloc, UriAndRange range, LowExpr a, LowExpr b) =>
	genBinary(alloc, boolType, range, BuiltinBinary.eqPointer, a, b);

LowExpr genPointerEqualNull(ref Alloc alloc, UriAndRange range, LowExpr a) =>
	genPointerEqual(alloc, range, a, genNull(a.type, range));

LowExpr genPointerCast(ref Alloc alloc, LowType type, UriAndRange range, LowExpr inner) =>
	LowExpr(type, range, LowExprKind(allocate(alloc, LowExprKind.PointerCast(inner))));

LowExpr genCreateRecordNoGcRoots(ref Alloc alloc, LowType type, UriAndRange range, in LowExpr[] args) =>
	genCreateRecordNoGcRoots(type, range, newArray(alloc, args));
LowExpr genCreateRecordNoGcRoots(LowType type, UriAndRange range, LowExpr[] args) =>
	LowExpr(type, range, LowExprKind(LowExprKind.CreateRecord(args)));

LowExpr genRecordFieldGet(ref Alloc alloc, LowType type, in UriAndRange range, LowExpr record, size_t fieldIndex) =>
	LowExpr(type, range, LowExprKind(LowExprKind.RecordFieldGet(allocate(alloc, record), fieldIndex)));
LowExpr genRecordFieldPointer(ref Alloc alloc, LowType type, in UriAndRange range, LowExpr record, size_t fieldIndex) =>
	LowExpr(type, range, LowExprKind(LowExprKind.RecordFieldPointer(allocate(alloc, record), fieldIndex)));
LowExpr genRecordFieldSetNoGcRoot(
	ref Alloc alloc, in UriAndRange range, LowExpr record, size_t fieldIndex, LowExpr value,
) =>
	LowExpr(voidType, range, LowExprKind(allocate(alloc, LowExprKind.RecordFieldSet(record, fieldIndex, value))));

LowExpr genSeq(ref Alloc alloc, UriAndRange range, LowExpr first, LowExpr then) =>
	genBinary(alloc, then.type, range, BuiltinBinary.seq, first, then);
LowExpr genSeq(ref Alloc alloc, UriAndRange range, LowExpr line0, LowExpr line1, LowExpr line2) =>
	genSeq(alloc, range, line0, genSeq(alloc, range, line1, line2));
LowExpr genSeq(ref Alloc alloc, UriAndRange range, LowExpr line0, LowExpr line1, LowExpr line2, LowExpr line3) =>
	genSeq(alloc, range, line0, genSeq(alloc, range, line1, line2, line3));

LowExpr genWriteToPointer(ref Alloc alloc, UriAndRange range, LowExpr pointer, LowExpr value) =>
	genBinary(alloc, voidType, range, BuiltinBinary.writeToPointer, pointer, value);

LowExpr genVoid(UriAndRange source) =>
	genZeroed(voidType, source);

LowExpr genZeroed(LowType type, UriAndRange range) =>
	LowExpr(type, range, LowExprKind(constantZero));

LowLocal* genLocal(ref Alloc alloc, Symbol name, bool isMutable, uint index, LowType type) =>
	allocate(alloc, genLocalByValue(alloc, name, isMutable, index, type));
LowLocal genLocalByValue(ref Alloc alloc, Symbol name, bool isMutable, uint index, LowType type) =>
	LowLocal(LowLocalSource(allocate(alloc, LowLocalSource.Generated(name, isMutable))), index, type);

// 'local.type' should not contain GC roots
LowExpr genLetNoGcRoot(ref Alloc alloc, UriAndRange range, LowLocal* local, LowExpr init, LowExpr then) =>
	LowExpr(then.type, range, LowExprKind(allocate(alloc, LowExprKind.Let(local, init, then))));

LowExpr genLetTempConstNoGcRoot(
	ref Alloc alloc,
	UriAndRange range,
	uint localIndex,
	LowExpr value,
	in LowExpr delegate(LowExpr) @safe @nogc pure nothrow cbThen,
) {
	LowLocal* local = genLocal(alloc, symbol!"temp", isMutable: false, localIndex, value.type);
	return genLetNoGcRoot(alloc, range, local, value, cbThen(genIdentifier(range, local)));
}

LowExpr genSeqThenReturnFirstNoGcRoot(ref Alloc alloc, UriAndRange range, uint localIndex, LowExpr a, LowExpr b) =>
	genLetTempConstNoGcRoot(alloc, range, localIndex, a, (LowExpr getA) =>
		genSeq(alloc, range, b, getA));

LowExpr genGetArrayOrMutArraySize(ref Alloc alloc, UriAndRange range, LowExpr arr) =>
	genRecordFieldGet(alloc, nat64Type, range, arr, 0);

LowExpr genGetArrayOrMutArrayConstPointer(
	ref Alloc alloc,
	UriAndRange range,
	LowExpr arr,
	LowType elementPointerType,
	LowType constPointerType,
) {
	LowExpr value = genRecordFieldGet(alloc, elementPointerType, range, arr, 1);
	return constPointerType == elementPointerType ? value : genPointerCast(alloc, constPointerType, range, value);
}

LowType getElementPointerTypeFromArrayOrMutArrayType(in AllLowTypes allTypes, in LowRecord* arrRecord) {
	assert(arrRecord.fields.length == 2);
	assert(debugName(arrRecord.fields[0]) == symbol!"size");
	assert(debugName(arrRecord.fields[1]) == symbol!"pointer");
	LowType res = arrRecord.fields[1].type;
	assert(isPointerNonGc(res));
	return res;
}

@trusted LowExpr genLoop(ref Alloc alloc, LowType type, UriAndRange range, LowExpr body_) =>
	LowExpr(type, range, LowExprKind(allocate(alloc, LowExprKind.Loop(body_))));

LowExpr genLoopBreak(ref Alloc alloc, LowType type, UriAndRange range, LowExpr value) =>
	LowExpr(type, range, LowExprKind(allocate(alloc, LowExprKind.LoopBreak(value))));

LowExpr genLoopContinue(LowType type, UriAndRange range) =>
	LowExpr(type, range, LowExprKind(LowExprKind.LoopContinue()));

LowExpr genVarGet(LowType type, UriAndRange range, LowVarIndex var) =>
	LowExpr(type, range, LowExprKind(LowExprKind.VarGet(var)));

LowExpr genVarSet(ref Alloc alloc, UriAndRange range, LowVarIndex var, LowExpr value) =>
	LowExpr(voidType, range, LowExprKind(LowExprKind.VarSet(var, allocate(alloc, value))));
