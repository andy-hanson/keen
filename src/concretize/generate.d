module concretize.generate;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : getConstantArray;
import concretize.concretizeCtx :
	boolType,
	char8ArrayType,
	char32ArrayType,
	ConcreteLambdaImpl,
	ConcreteSumTypeCase,
	ConcretizeCtx,
	constantSymbol,
	getConcreteFun,
	getReferencedType,
	integralType,
	nat64Type,
	symbolType,
	voidType;
import model.concreteModel :
	BuiltinConcreteExpr,
	CallConcreteExpr,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteGeneratedLocalKind,
	ConcreteLocal,
	ConcreteLocalSource,
	ConcreteMatchUnionCase,
	ConcreteRecord,
	ConcreteStruct,
	ConcreteStructSourceInst,
	ConcreteType,
	ConcreteUnion,
	Constant,
	constantBool,
	ConstantUnion,
	constantZero,
	CreateArrayConcreteExpr,
	CreateRecordConcreteExpr,
	CreateUnionConcreteExpr,
	DropConcreteExpr,
	IfConcreteExpr,
	isVoid,
	LetConcreteExpr,
	LocalGetConcreteExpr,
	LocalPointerConcreteExpr,
	LocalSetConcreteExpr,
	LoopBreakConcreteExpr,
	LoopContinueConcreteExpr,
	LoopConcreteExpr,
	MatchEnumOrIntegralConcreteExpr,
	MatchUnionConcreteExpr,
	mustBeEnum,
	mustBeByVal,
	RecordFieldGetConcreteExpr,
	RecordFieldPointerConcreteExpr,
	RecordFieldSetConcreteExpr,
	SeqConcreteExpr,
	ThrowConcreteExpr,
	UnionAsConcreteExpr,
	UnionKindConcreteExpr,
	unwrapOptionType;
import model.integralValues : IntegralValue, IntegralValues, integralValuesRange, mapToIntegralValues;
import model.model :
	BuiltinBinary,
	BuiltinFun,
	BuiltinUnary,
	Called,
	EnumOrFlagsMember,
	IntegralType,
	Record,
	RecordField,
	RecordFieldCall;
import model.sourceRange : UriAndRange;
import util.alloc.alloc : Alloc;
import util.col.array :
	isEmpty,
	map,
	mapPointers,
	mapPointersWithIndex,
	mapWithIndex,
	mustHaveIndexOfPointer,
	newArray,
	newSmallArray,
	only,
	small,
	SmallArray;
import util.col.arrayBuilder : buildArray, Builder;
import util.conv : safeToUint;
import util.memory : allocate;
import util.opt : force, has, none, Opt, some;
import util.string : bytesOfString;
import util.symbol : Symbol;
import util.unicode : mustUnicodeDecode;

ConcreteExpr genConstant(ConcreteType type, UriAndRange range, Constant value) =>
	ConcreteExpr(type, range, ConcreteExprKind(value));

ConcreteExpr genConstantIntegral(ConcreteType type, UriAndRange range, IntegralValue value) =>
	genConstant(type, range, Constant(value));

ConcreteExpr genFalse(ref ConcretizeCtx ctx, UriAndRange range) =>
	genBool(ctx, range, false);

ConcreteExpr genTrue(ref ConcretizeCtx ctx, UriAndRange range) =>
	genBool(ctx, range, true);

private ConcreteExpr genBool(ref ConcretizeCtx ctx, UriAndRange range, bool value) =>
	genConstant(boolType(ctx), range, constantBool(value));

ConcreteExpr genCall(ref Alloc alloc, in UriAndRange range, ConcreteFun* called, in ConcreteExpr[] args) =>
	genCallNoAllocArgs(range, called, newArray(alloc, args));

ConcreteExpr genCallNoAllocArgs(in UriAndRange range, ConcreteFun* called, ConcreteExpr[] args) =>
	ConcreteExpr(called.returnType, range, genCallKindNoAllocArgs(called, args));

ConcreteExprKind genCallKindNoAllocArgs(ConcreteFun* called, ConcreteExpr[] args) =>
	ConcreteExprKind(CallConcreteExpr(called, small!ConcreteExpr(args)));

ConcreteExpr genIf(
	ref Alloc alloc, UriAndRange range, ConcreteExpr cond, ConcreteExpr then, ConcreteExpr else_,
) =>
	ConcreteExpr(then.type, range, ConcreteExprKind(allocate(alloc, IfConcreteExpr(cond, then, else_))));

ConcreteExpr genLoop(ref Alloc alloc, ConcreteType type, in UriAndRange range, ConcreteExpr body_) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc, LoopConcreteExpr(body_))));

ConcreteExpr genDoAndContinue(ref Alloc alloc, ConcreteType type, in UriAndRange range, ConcreteExpr a) =>
	genSeq(alloc, range, a, genContinue(type, range));

ConcreteExpr genSeq(ref Alloc alloc, in UriAndRange range, ConcreteExpr a, ConcreteExpr b) {
	assert(isVoid(a.type));
	return ConcreteExpr(b.type, range, ConcreteExprKind(allocate(alloc, SeqConcreteExpr(a, b))));
}

ConcreteExpr genDropThen(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genSeq(ctx.alloc, range, genDrop(ctx, range, a), b);

ConcreteExpr genContinue(ConcreteType type, in UriAndRange range) =>
	ConcreteExpr(type, range, ConcreteExprKind(LoopContinueConcreteExpr()));

ConcreteExpr genBreak(ref Alloc alloc, in UriAndRange range, ConcreteExpr value) =>
	ConcreteExpr(value.type, range, ConcreteExprKind(allocate(alloc, LoopBreakConcreteExpr(value))));

ConcreteExpr genCreateUnion(
	ref Alloc alloc,
	ConcreteType type,
	in UriAndRange range,
	size_t memberIndex,
	ConcreteExpr arg,
) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc, CreateUnionConcreteExpr(memberIndex, arg))));

ConcreteExpr genSome(ref ConcretizeCtx ctx, ConcreteType optionType, in UriAndRange range, ConcreteExpr arg) {
	assertIsOptionType(ctx, optionType);
	return genCreateUnion(ctx.alloc, optionType, range, 1, arg);
}
ConcreteExpr genConstantSome(ref ConcretizeCtx ctx, ConcreteType optionType, in UriAndRange range, Constant inner) {
	assertIsOptionType(ctx, optionType);
	return genConstant(optionType, range, Constant(allocate(ctx.alloc, ConstantUnion(1, inner))));
}
ConcreteExpr genNone(ref ConcretizeCtx ctx, ConcreteType optionType, in UriAndRange range) {
	assertIsOptionType(ctx, optionType);
	return genConstant(optionType, range, Constant(allocate(ctx.alloc, ConstantUnion(0, constantZero))));
}
ConcreteType unwrapOptionType(in ConcretizeCtx ctx, ConcreteType optionType) {
	assertIsOptionType(ctx, optionType);
	return only(mustBeByVal(optionType).source.as!ConcreteStructSourceInst.typeArgs);
}
private void assertIsOptionType(in ConcretizeCtx ctx, ConcreteType optionType) {
	assert(mustBeByVal(optionType).source.as!ConcreteStructSourceInst.decl == ctx.commonTypes.option);
}
ConcreteExpr genVoid(ref ConcretizeCtx ctx, in UriAndRange range) =>
	genConstant(voidType(ctx), range, constantZero);

ConcreteExpr genLet(
	ref Alloc alloc,
	ConcreteType type,
	in UriAndRange range,
	ConcreteLocal* local,
	ConcreteExpr value,
	ConcreteExpr then,
) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc, LetConcreteExpr(local, value, then))));

ConcreteExpr genDrop(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr inner) =>
	ConcreteExpr(voidType(ctx), range, ConcreteExprKind(allocate(ctx.alloc, DropConcreteExpr(inner))));

ConcreteExpr genLocalGet(in UriAndRange range, ConcreteLocal* local) =>
	ConcreteExpr(local.type, range, ConcreteExprKind(LocalGetConcreteExpr(local)));

ConcreteExpr genLocalPointer(ConcreteType type, in UriAndRange range, ConcreteLocal* local) =>
	ConcreteExpr(type, range, ConcreteExprKind(LocalPointerConcreteExpr(local)));

ConcreteExpr genLocalSet(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteLocal* local, ConcreteExpr value) =>
	ConcreteExpr(voidType(ctx), range, ConcreteExprKind(allocate(ctx.alloc, LocalSetConcreteExpr(local, value))));

ConcreteFunBody genRecordFieldCall(ref ConcretizeCtx ctx, ConcreteFun* fun, RecordFieldCall body_) {
	UriAndRange range = fun.range;
	ConcreteExpr* recordArg = allocate(ctx.alloc, genParamGet(range, &fun.params[0]));
	size_t fieldIndex = fieldIndexFromField(recordArg.type, body_.field);
	ConcreteStruct* fieldType = mustBeByVal(concreteFieldFromIndex(recordArg.type, fieldIndex).type);
	ConcreteExpr getFun = genRecordFieldGet(ConcreteType.byVal(fieldType), range, recordArg, fieldIndex);
	ConcreteType[] typeArgs = fieldType.source.as!ConcreteStructSourceInst.typeArgs;
	assert(typeArgs.length == 2);
	ConcreteFun* callFun = getConcreteFun(ctx, ctx.program.commonFuns.lambdaSubscript[body_.funKind], typeArgs, []);
	ConcreteExpr arg = () {
		switch (fun.params.length) {
			case 0:
				assert(false);
			case 1:
				return genVoid(ctx, range);
			case 2:
				return genParamGet(range, &fun.params[1]);
			default:
				ConcreteExpr[] args = mapPointers(ctx.alloc, fun.params[1 .. $], (ConcreteLocal* param) =>
					genParamGet(range, param));
				return genCreateRecord(callFun.params[1].type, range, args);
		}
	}();
	return ConcreteFunBody(genCall(ctx.alloc, range, callFun, [getFun, arg]));
}
size_t fieldIndexFromField(ConcreteType recordType, RecordField* field) =>
	mustHaveIndexOfPointer(
		recordType.struct_.source.as!ConcreteStructSourceInst.decl.body_.as!Record.fields,
		field);
private ConcreteField* concreteFieldFromIndex(ConcreteType recordType, size_t fieldIndex) =>
	&recordType.struct_.body_.as!ConcreteRecord.fields[fieldIndex];

ConcreteFunBody genUnionMemberGet(ref ConcretizeCtx ctx, ConcreteFun* cf, size_t memberIndex) {
	UriAndRange range = cf.range;
	ConcreteExpr* param = allocate(ctx.alloc, genParamGet(range, &only(cf.params)));
	ConcreteType memberType = unwrapOptionType(ctx, cf.returnType);
	return ConcreteFunBody(genIf(
		ctx.alloc,
		range,
		genEqualNat64(ctx, range, genUnionKind(ctx, range, param), genConstantNat64(ctx, range, memberIndex)),
		genSome(ctx, cf.returnType, range, genUnionAs(memberType, range, param, memberIndex)),
		genNone(ctx, cf.returnType, range)));
}

ConcreteExpr genConstantNat64(ref ConcretizeCtx ctx, in UriAndRange range, ulong value) =>
	genConstant(nat64Type(ctx), range, Constant(IntegralValue(value)));

ConcreteExpr genEqualNat64(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr left, ConcreteExpr right) =>
	genEqualIntegral(ctx, range, IntegralType.nat64, left, right);
ConcreteExpr genLessNat64(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr left, ConcreteExpr right) =>
	genLessIntegral(ctx, range, IntegralType.nat64, left, right);

ConcreteFunBody generateCallLambda(
	ref ConcretizeCtx ctx,
	ConcreteFun* fun,
	SmallArray!ConcreteType memberTypes,
	in ConcreteLambdaImpl[] impls,
) {
	UriAndRange range = UriAndRange.empty;
	assert(fun.params.length == 2);
	ConcreteExpr lambda = genParamGet(range, &fun.params[0]);
	ConcreteExpr arg = genParamGet(range, &fun.params[1]);
	return ConcreteFunBody(
		isEmpty(memberTypes)
			? genBogus(ctx, fun.returnType, range)
			: genMatchUnion(ctx, fun.returnType, range, memberTypes, lambda, (size_t i, ConcreteExpr closure) =>
				genCall(ctx.alloc, range, impls[i].impl, [closure, arg])));
}

ConcreteFunBody generateCallMethod(
	ref ConcretizeCtx ctx,
	ConcreteFun* fun,
	ConcreteStruct* sumType,
	in ConcreteSumTypeCase[] cases,
	size_t methodIndex,
) {
	UriAndRange range = fun.range;
	SmallArray!ConcreteType members = sumType.body_.as!ConcreteUnion.members;
	return isEmpty(members)
		? ConcreteFunBody(genThrowString(ctx, fun.returnType, range, "Called method of empty interface"))
		: ConcreteFunBody(genMatchUnion(
			ctx, fun.returnType, range, members,
			genParamGet(range, &fun.params[0]),
			(size_t i, ConcreteExpr member) {
				Opt!(ConcreteFun*) impl = cases[i].methodImpls[methodIndex];
				return has(impl)
					? genCallNoAllocArgs(
						range, force(impl),
						mapPointersWithIndex(ctx.alloc, fun.params, (size_t paramIndex, ConcreteLocal* param) =>
							paramIndex == 0 ? member : genParamGet(range, param)))
					: genBogus(ctx, fun.returnType, range);
			}));
}

ConcreteExpr genMatchEnumOrIntegral(
	ref Alloc alloc,
	ConcreteType type,
	UriAndRange range,
	ConcreteExpr matched,
	in ConcreteExpr delegate(ref EnumOrFlagsMember) @safe @nogc pure nothrow cb,
) {
	EnumOrFlagsMember[] members = mustBeEnum(matched.type);
	return genMatchEnumOrIntegral(
		alloc,
		type,
		range,
		matched,
		mapToIntegralValues!EnumOrFlagsMember(members, (ref EnumOrFlagsMember x) => x.value),
		map(alloc, members, cb));
}

ConcreteExpr genMatchEnumOrIntegral(
	ref Alloc alloc,
	ConcreteType type,
	UriAndRange range,
	ConcreteExpr matched,
	IntegralValues caseValues,
	ConcreteExpr[] cases,
	Opt!(ConcreteExpr*) else_ = none!(ConcreteExpr*),
) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc,
		MatchEnumOrIntegralConcreteExpr(matched, caseValues, cases, else_))));

ConcreteExpr genMatchUnion(
	ref ConcretizeCtx ctx,
	ConcreteType returnType,
	UriAndRange range,
	in SmallArray!ConcreteType memberTypes,
	ConcreteExpr union_,
	in ConcreteExpr delegate(size_t, ConcreteExpr) @safe @nogc pure nothrow cb,
) =>
	ConcreteExpr(returnType, range, ConcreteExprKind(allocate(ctx.alloc, MatchUnionConcreteExpr(
		union_,
		integralValuesRange(memberTypes.length),
		mapWithIndex!(ConcreteMatchUnionCase, ConcreteType)(
			ctx.alloc, memberTypes, (size_t memberIndex, ref ConcreteType memberType) {
				ConcreteLocal* local = allocate(ctx.alloc, ConcreteLocal(
					ConcreteLocalSource(ConcreteGeneratedLocalKind.member),
					memberType));
				return ConcreteMatchUnionCase(some(local), cb(memberIndex, genLocalGet(range, local)));
			}),
		none!(ConcreteExpr*)))));

ConcreteExpr genThrow(ref Alloc alloc, ConcreteType type, UriAndRange range, ConcreteExpr thrown) =>
	ConcreteExpr(type, range, genThrowKind(alloc, thrown));

ConcreteExpr genBogus(ref ConcretizeCtx ctx, ConcreteType type, UriAndRange range) =>
	ConcreteExpr(type, range, genBogusKind(ctx, range));
ConcreteExprKind genBogusKind(ref ConcretizeCtx ctx, in UriAndRange range) =>
	genThrowStringKind(ctx, range, "Reached compile error");

private ConcreteExprKind genThrowKind(ref Alloc alloc, ConcreteExpr thrown) =>
	ConcreteExprKind(allocate(alloc, ThrowConcreteExpr(thrown)));

ConcreteExpr genError(ref ConcretizeCtx ctx, UriAndRange range, string message) =>
	genCall(ctx.alloc, range, ctx.createErrorFunction, [genStringLiteral(ctx, range, message)]);

private ConcreteExpr genThrowString(ref ConcretizeCtx ctx, ConcreteType type, UriAndRange range, string message) =>
	genThrow(ctx.alloc, type, range, genError(ctx, range, message));

private ConcreteExprKind genThrowStringKind(ref ConcretizeCtx ctx, UriAndRange range, string message) =>
	genThrowKind(ctx.alloc, genError(ctx, range, message));

ConcreteExpr genStringLiteral(ref ConcretizeCtx ctx, UriAndRange range, in string value) =>
	ConcreteExpr(char8ArrayType(ctx), range, genStringLiteralKind(ctx, range, value));

ConcreteExprKind genStringLiteralKind(ref ConcretizeCtx ctx, UriAndRange range, in string value) =>
	genChar8Array(ctx, range, value).kind;

ConcreteExpr genChar8Array(ref ConcretizeCtx ctx, in UriAndRange range, in string value) {
	ConcreteType type = char8ArrayType(ctx);
	return genConstant(type, range, constantOfBytes(ctx, type, bytesOfString(value)));
}

Constant constantOfBytes(ref ConcretizeCtx ctx, ConcreteType arrayType, in ubyte[] bytes) {
	//TODO:PERF creating a Constant per byte is expensive
	Constant[] elements = map!(Constant, const ubyte)(ctx.alloc, bytes, (ref const ubyte a) =>
		Constant(IntegralValue(a)));
	return getConstantArray(ctx.alloc, ctx.allConstants, mustBeByVal(arrayType), elements);
}

ConcreteExpr genChar32Array(ref ConcretizeCtx ctx, in UriAndRange range, in string value) {
	ConcreteType type = char32ArrayType(ctx);
	return genConstant(type, range, char32ArrayConstant(ctx, type, value));
}
private Constant char32ArrayConstant(ref ConcretizeCtx ctx, ConcreteType type, in string value) =>
	getConstantArray(
		ctx.alloc, ctx.allConstants, mustBeByVal(type),
		buildArray!Constant(ctx.alloc, (scope ref Builder!Constant out_) {
			mustUnicodeDecode(value, (dchar x) {
				out_ ~= Constant(IntegralValue(x));
			});
		}));

ConcreteExpr genCallVariadic(ref Alloc alloc, UriAndRange range, ConcreteFun* called, ConcreteExpr[] args) =>
	genCall(alloc, range, called, [genCreateArray(alloc, only(called.params).type, range, args)]);

private ConcreteExpr genCreateArray(ref Alloc alloc, ConcreteType arrayType, UriAndRange range, ConcreteExpr[] args) =>
	ConcreteExpr(arrayType, range, ConcreteExprKind(CreateArrayConcreteExpr(args)));

private ConcreteExpr genCreateRecord(ref Alloc alloc, ConcreteType type, UriAndRange range, in ConcreteExpr[] args) =>
	genCreateRecord(type, range, newArray(alloc, args));
ConcreteExpr genCreateRecord(ConcreteType type, UriAndRange range, ConcreteExpr[] args) =>
	ConcreteExpr(type, range, ConcreteExprKind(CreateRecordConcreteExpr(args)));

ConcreteExpr genConstantSymbol(ref ConcretizeCtx ctx, UriAndRange range, Symbol value) =>
	genConstant(symbolType(ctx), range, constantSymbol(ctx, value));

ConcreteExpr genParamGet(UriAndRange range, ConcreteLocal* param) =>
	ConcreteExpr(param.type, range, ConcreteExprKind(LocalGetConcreteExpr(param)));

ConcreteExpr genRecordFieldGet(
	ConcreteType fieldType, UriAndRange range, ConcreteExpr* arg, size_t fieldIndex,
) =>
	ConcreteExpr(fieldType, range, ConcreteExprKind(RecordFieldGetConcreteExpr(arg, fieldIndex)));
ConcreteExpr genRecordFieldPointer(
	ConcreteType pointerType, UriAndRange range, ConcreteExpr* record, size_t fieldIndex,
) =>
	ConcreteExpr(pointerType, range, ConcreteExprKind(RecordFieldPointerConcreteExpr(record, fieldIndex)));
ConcreteExpr genRecordFieldSet(
	ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr record, size_t fieldIndex, ConcreteExpr value,
) =>
	ConcreteExpr(voidType(ctx), range, ConcreteExprKind(allocate(ctx.alloc,
		RecordFieldSetConcreteExpr(record, fieldIndex, value))));

ConcreteExpr genUnionKind(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr* arg) =>
	ConcreteExpr(nat64Type(ctx), range, ConcreteExprKind(UnionKindConcreteExpr(arg)));

ConcreteExpr genUnionAs(ConcreteType type, UriAndRange range, ConcreteExpr* arg, size_t memberIndex) =>
	ConcreteExpr(type, range, ConcreteExprKind(UnionAsConcreteExpr(arg, safeToUint(memberIndex))));

ConcreteExpr genAnd(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genIf(ctx.alloc, range, a, b, genFalse(ctx, range));

ConcreteExpr genOr(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genIf(ctx.alloc, range, a, genTrue(ctx, range), b);

ConcreteExpr genReferenceCreate(
	ref ConcretizeCtx ctx,
	ConcreteType referenceType,
	in UriAndRange range,
	ConcreteExpr value,
) =>
	genCreateRecord(ctx.alloc, referenceType, range, [value]);
ConcreteExpr genReferenceRead(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr reference) =>
	genRecordFieldGet(getReferencedType(ctx, reference.type), range, allocate(ctx.alloc, reference), 0);
ConcreteExpr genReferenceWrite(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr reference, ConcreteExpr value) {
	getReferencedType(ctx, reference.type); // assert that it's a reference type
	return genRecordFieldSet(ctx, range, reference, 0, value);
}

ConcreteExpr genEqualPointer(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genBuiltin(ctx.alloc, boolType(ctx), range, BuiltinFun(BuiltinBinary.equalPointer), [a, b]);

ConcreteExpr genEqualIntegral(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	IntegralType type,
	ConcreteExpr a,
	ConcreteExpr b,
) =>
	genBuiltin(ctx.alloc, boolType(ctx), range, BuiltinFun(builtinBinaryEqualIntegral(type)), [a, b]);

ConcreteExpr genLessIntegral(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	IntegralType type,
	ConcreteExpr a,
	ConcreteExpr b,
) =>
	genBuiltin(ctx.alloc, boolType(ctx), range, BuiltinFun(builtinBinaryLessIntegral(type)), [a, b]);

ConcreteExpr genIntersectIntegral(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	IntegralType type,
	ConcreteExpr a,
	ConcreteExpr b,
) =>
	genBuiltin(ctx.alloc, integralType(ctx, type), range, BuiltinFun(builtinBinaryIntersectIntegral(type)), [a, b]);

ConcreteExpr genUnionIntegral(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	IntegralType type,
	ConcreteExpr a,
	ConcreteExpr b,
) =>
	genBuiltin(ctx.alloc, integralType(ctx, type), range, BuiltinFun(builtinBinaryUnionIntegral(type)), [a, b]);

ConcreteExpr genNegateIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr a) =>
	genBuiltin(ctx.alloc, integralType(ctx, type), range, BuiltinFun(builtinUnaryNegateIntegral(type)), [a]);

private ConcreteExpr genBuiltin(
	ref Alloc alloc,
	ConcreteType type,
	UriAndRange range,
	BuiltinFun fun,
	in ConcreteExpr[] args,
) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc,
		BuiltinConcreteExpr(fun, newSmallArray(alloc, args)))));

private BuiltinBinary builtinBinaryEqualIntegral(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
			return BuiltinBinary.equalInt8;
		case IntegralType.int16:
			return BuiltinBinary.equalInt16;
		case IntegralType.int32:
			return BuiltinBinary.equalInt32;
		case IntegralType.int64:
			return BuiltinBinary.equalInt64;
		case IntegralType.nat8:
			return BuiltinBinary.equalNat8;
		case IntegralType.nat16:
			return BuiltinBinary.equalNat16;
		case IntegralType.nat32:
			return BuiltinBinary.equalNat32;
		case IntegralType.nat64:
			return BuiltinBinary.equalNat64;
	}
}

private BuiltinBinary builtinBinaryLessIntegral(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
			return BuiltinBinary.lessInt8;
		case IntegralType.int16:
			return BuiltinBinary.lessInt16;
		case IntegralType.int32:
			return BuiltinBinary.lessInt32;
		case IntegralType.int64:
			return BuiltinBinary.lessInt64;
		case IntegralType.nat8:
			return BuiltinBinary.lessNat8;
		case IntegralType.nat16:
			return BuiltinBinary.lessNat16;
		case IntegralType.nat32:
			return BuiltinBinary.lessNat32;
		case IntegralType.nat64:
			return BuiltinBinary.lessNat64;
	}
}

private BuiltinBinary builtinBinaryIntersectIntegral(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
			return BuiltinBinary.bitwiseAndInt8;
		case IntegralType.int16:
			return BuiltinBinary.bitwiseAndInt16;
		case IntegralType.int32:
			return BuiltinBinary.bitwiseAndInt32;
		case IntegralType.int64:
			return BuiltinBinary.bitwiseAndInt64;
		case IntegralType.nat8:
			return BuiltinBinary.bitwiseAndNat8;
		case IntegralType.nat16:
			return BuiltinBinary.bitwiseAndNat16;
		case IntegralType.nat32:
			return BuiltinBinary.bitwiseAndNat32;
		case IntegralType.nat64:
			return BuiltinBinary.bitwiseAndNat64;
	}
}

private BuiltinBinary builtinBinaryUnionIntegral(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
			return BuiltinBinary.bitwiseOrInt8;
		case IntegralType.int16:
			return BuiltinBinary.bitwiseOrInt16;
		case IntegralType.int32:
			return BuiltinBinary.bitwiseOrInt32;
		case IntegralType.int64:
			return BuiltinBinary.bitwiseOrInt64;
		case IntegralType.nat8:
			return BuiltinBinary.bitwiseOrNat8;
		case IntegralType.nat16:
			return BuiltinBinary.bitwiseOrNat16;
		case IntegralType.nat32:
			return BuiltinBinary.bitwiseOrNat32;
		case IntegralType.nat64:
			return BuiltinBinary.bitwiseOrNat64;
	}
}

private BuiltinUnary builtinUnaryNegateIntegral(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
		case IntegralType.int16:
		case IntegralType.int32:
		case IntegralType.int64:
			assert(false);
		case IntegralType.nat8:
			return BuiltinUnary.bitwiseNotNat8;
		case IntegralType.nat16:
			return BuiltinUnary.bitwiseNotNat16;
		case IntegralType.nat32:
			return BuiltinUnary.bitwiseNotNat32;
		case IntegralType.nat64:
			return BuiltinUnary.bitwiseNotNat64;
	}
}
