module concretize.concretizeAutoFun;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : getConstantArray;
import concretize.concretizeCtx :
	boolType, ConcretizeCtx, constantSymbol, getConcreteType, integralType, symbolType, withConcretizeExprCtx;
import concretize.concretizeExpr : concretizeBogus, ConcretizeExprCtx, getConcreteFunFromCalled, getConcreteType;
import concretize.generate :
	genAnd,
	genCall,
	genCallVariadic,
	genCreateRecord,
	genConstant,
	genConstantIntegral,
	genConstantSymbol,
	genEqualNat64,
	genIdentifier,
	genIf,
	genMatchUnion,
	genNone,
	genParamGet,
	genRecordFieldGet,
	genSome,
	genStringLiteralForSymbol,
	genTrue,
	genUnionAs,
	genUnionKind;
import model.concreteModel :
	arrayElementType,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteLocal,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructSource,
	ConcreteType,
	mustBeByVal,
	unwrapOptionType;
import model.constant : Constant;
import model.model :
	AutoFun, BuiltinBinary, BuiltinFun, BuiltinUnary, Called, EnumOrFlagsMember, FlagsFunction, getAllFlagsValue, IntegralType, RecordField, StructBody, UnionMember;
import util.alloc.alloc : Alloc;
import util.col.array :
	allSame,
	foldRange,
	foldReverse,
	isEmpty,
	map,
	mapReduce,
	mapZipWithIndex,
	newArray,
	newSmallArray,
	only,
	sizeEq,
	sizeEq3,
	SmallArray;
import util.conv : safeToUint;
import util.integralValues : IntegralValue, integralValuesRange, mapToIntegralValues;
import util.memory : allocate;
import util.opt : force, has, none, Opt;
import util.sourceRange : UriAndRange;
import util.symbol : Symbol, symbol;
import util.util : todo; // -000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

ConcreteExpr concretizeAutoFun(ref ConcretizeExprCtx ctx, ref AutoFun a) {
	ConcreteExpr param0() =>
		genParamGet(ctx.curFun.range, &ctx.curFun.params[0]);
	ConcreteExpr param1() =>
		genParamGet(ctx.curFun.range, &ctx.curFun.params[1]);
	UriAndRange range() => ctx.curFun.range;
	final switch (a.kind) {
		case AutoFun.Kind.compare:
			ConcreteExpr compareIntegral(IntegralType storage) =>
				genCompareIntegral(
					ctx.concretizeCtx,
					ctx.curFun.returnType,
					range,
					storage,
					genCastIntegral(ctx.concretizeCtx, range, storage, param0()),
					genCastIntegral(ctx.concretizeCtx, range, storage, param1()));
			return handleEnumFlagsRecordOrUnion(
				sameType(ctx.curFun.params),
				(StructBody.Enum x) =>
					compareIntegral(x.storage),
				(StructBody.Flags x) =>
					compareIntegral(x.storage),
				(ConcreteStructBody.Record x) =>
					concretizeCompareRecord(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeCompareUnion(ctx, x.members, a.members));
		case AutoFun.Kind.enumOrFlagsMembers:
			Constant[] elements = map(ctx.alloc, enumOrFlagsMembers(arrayElementType(ctx.curFun.returnType)), (ref EnumOrFlagsMember member) =>
				Constant(member.value));
			Constant res = getConstantArray(ctx.alloc, ctx.allConstants, mustBeByVal(ctx.curFun.returnType), elements);
			return ConcreteExpr(ctx.curFun.returnType, range, ConcreteExprKind(res));
		case AutoFun.Kind.enumOrFlagsToIntegral:
			return genCast(ctx.alloc, ctx.curFun.returnType, range, param0());
		case AutoFun.Kind.enumToSymbol:
			return concretizeEnumToSymbol(ctx);
		case AutoFun.Kind.equals:
			return handleEnumFlagsRecordOrUnion(
				sameType(ctx.curFun.params),
				(StructBody.Enum x) =>
					concretizeEqualEnumOrFlags(ctx.concretizeCtx, range, x.storage, param0(), param1()),
				(StructBody.Flags x) =>
					concretizeEqualEnumOrFlags(ctx.concretizeCtx, range, x.storage, param0(), param1()),
				(ConcreteStructBody.Record x) =>
					concretizeEqualRecord(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeEqualUnion(ctx, x.members, a.members));
		case AutoFun.Kind.flagsToSymbolArray:
			return concretizeFlagsToSymbolArray(ctx);
		case AutoFun.Kind.toJson:
			return handleEnumFlagsRecordOrUnion(
				only(ctx.curFun.params).type,
				(StructBody.Enum x) =>
					concretizeEnumToJson(ctx),
				(StructBody.Flags) =>
					// This is a lot like converting to symbol[], but each symbol is wrapped in 'json' and then the whole array is
					todo!ConcreteExpr("FLAGS TO JSON"), // -0-0000000000000000000000000000000000000000000000000000000000000000000000000000
				(ConcreteStructBody.Record x) =>
					concretizeRecordToJson(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeUnionToJson(ctx, x.members, a.members));
		case AutoFun.Kind.symbolToOptEnum:
			return concretizeSymbolToOptEnum(ctx);
	}
}

ConcreteExpr concretizeFlagsFunction(ref ConcretizeCtx ctx, ConcreteFun* cf, FlagsFunction fn) {
	UriAndRange range = cf.range;
	ConcreteExpr param0() =>
		genParamGet(range, &cf.params[0]);
	ConcreteExpr param1() =>
		genParamGet(range, &cf.params[1]);
	ConcreteExpr castParam0(IntegralType storage) =>
		genCastIntegral(ctx, range, storage, param0);
	ConcreteExpr castParam1(IntegralType storage) =>
		genCastIntegral(ctx, range, storage, param1);
	ConcreteExpr castToFlags(ConcreteExpr x) =>
		genCast(ctx.alloc, cf.returnType, range, x);
	return withConcretizeExprCtx(ctx, cf, (ref ConcretizeExprCtx exprCtx) {
		final switch (fn) {
			case FlagsFunction.in_:
				// (x & y) == x
				IntegralType storage = integralTypeFromFlagsType(cf.params[0].type);
				ConcreteExpr p0 = castParam0(storage);
				return genEqualIntegral(
					ctx, range, storage,
					genIntersectIntegral(ctx, range, storage, p0, castParam1(storage)),
					p0);
			case FlagsFunction.intersect:
				IntegralType storage = integralTypeFromFlagsType(cf.params[0].type);
				return castToFlags(genIntersectIntegral(ctx, range, storage, castParam0(storage), castParam1(storage)));
			case FlagsFunction.negate:
				IntegralType storage = integralTypeFromFlagsType(cf.params[0].type);
				return castToFlags(
					genIntersectIntegral(
						ctx, range, storage,
						genNegateIntegral(ctx, range, storage, castParam0(storage)),
						genConstantIntegral(integralType(ctx, storage), range, getAllFlagsValue(mustBeFlags(cf.returnType)))));
			case FlagsFunction.none:
				IntegralType storage = integralTypeFromFlagsType(cf.returnType);
				return castToFlags(genConstantIntegral(integralType(ctx, storage), range, IntegralValue(0)));
			case FlagsFunction.union_:
				IntegralType storage = integralTypeFromFlagsType(cf.params[0].type);
				return castToFlags(genUnionIntegral(ctx, range, storage, castParam0(storage), castParam1(storage)));
		}
	});
}

private:

IntegralType integralTypeFromFlagsType(in ConcreteType a) =>
	mustBeByVal(a).body_.as!(ConcreteStructBody.Flags).storage;

SmallArray!EnumOrFlagsMember enumOrFlagsMembers(ConcreteType type) {
	StructBody body_ = mustBeByVal(type).source.as!(ConcreteStructSource.Inst).decl.body_;
	return body_.isA!(StructBody.Enum*) ? body_.as!(StructBody.Enum*).members : body_.as!(StructBody.Flags).members;
}

ConcreteExpr concretizeEqualEnumOrFlags(ref ConcretizeCtx ctx, UriAndRange range, IntegralType storage, ConcreteExpr arg0, ConcreteExpr arg1) =>
	genEqualIntegral(ctx, range, storage, genCastIntegral(ctx, range, storage, arg0), genCastIntegral(ctx, range, storage, arg1));

ConcreteExpr genEqualIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg0, ConcreteExpr arg1) =>
	genCall(ctx.alloc, range, ctx.equalIntegralFunctions[type], [arg0, arg1]);

ConcreteExpr genLessIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg0, ConcreteExpr arg1) =>
	genCall(ctx.alloc, range, ctx.lessIntegralFunctions[type], [arg0, arg1]);

ConcreteExpr genIntersectIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg0, ConcreteExpr arg1) =>
	genBuiltin(ctx.alloc, integralType(ctx, type), range, BuiltinFun(builtinBinaryIntersectIntegral(type)), [arg0, arg1]);

ConcreteExpr genUnionIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg0, ConcreteExpr arg1) =>
	genBuiltin(ctx.alloc, integralType(ctx, type), range, BuiltinFun(builtinBinaryUnionIntegral(type)), [arg0, arg1]);

ConcreteExpr genNegateIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg) =>
	genBuiltin(ctx.alloc, integralType(ctx, type), range, BuiltinFun(builtinUnaryNegateIntegral(type)), [arg]);

ConcreteExpr genBuiltin(ref Alloc alloc, ConcreteType type, UriAndRange range, BuiltinFun fun, in ConcreteExpr[] args) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.Builtin(fun, newSmallArray(alloc, args)))));

BuiltinBinary builtinBinaryIntersectIntegral(IntegralType type) {
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

BuiltinBinary builtinBinaryUnionIntegral(IntegralType type) {
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

BuiltinUnary builtinUnaryNegateIntegral(IntegralType type) {
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

private ConcreteExpr genCompareIntegral(
	ref ConcretizeCtx ctx,
	ConcreteType comparisonType,
	UriAndRange range,
	IntegralType type,
	ConcreteExpr arg0,
	ConcreteExpr arg1,
) =>
	// a < b ? less : b < a ? greater : equal
	genIf(
		ctx.alloc, range,
		genLessIntegral(ctx, range, type, arg0, arg1),
		genComparisonLess(comparisonType, range),
		genIf(
			ctx.alloc, range,
			genLessIntegral(ctx, range, type, arg1, arg0),
			genComparisonGreater(comparisonType, range),
			genComparisonEqual(comparisonType, range)));

private ConcreteExpr genCastIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg) =>
	genCast(ctx.alloc, integralType(ctx, type), range, arg);

private ConcreteExpr genCast(ref Alloc alloc, ConcreteType type, UriAndRange range, ConcreteExpr arg) =>
	ConcreteExpr(type, range, ConcreteExprKind(ConcreteExprKind.Cast(allocate(alloc, arg))));

private ConcreteExpr concretizeEnumToJson(ref ConcretizeExprCtx ctx) =>
	autoFunMatchEnum(ctx, (ref EnumOrFlagsMember x) =>
		genJsonOfString(ctx.concretizeCtx, ctx.curFun.range, genStringLiteralForSymbol(ctx.concretizeCtx, ctx.curFun.range, x.name)));

private ConcreteExpr concretizeEnumToSymbol(ref ConcretizeExprCtx ctx) =>
	autoFunMatchEnum(ctx, (ref EnumOrFlagsMember x) =>
		symbolForEnumMember(ctx.concretizeCtx, ctx.curFun.returnType, ctx.curFun.range, x));

ConcreteExpr concretizeFlagsToSymbolArray(ref ConcretizeExprCtx ctx) {
	// (a & x == 0 ? () : ("x",)) ~~ (a & y == 0 ? () : ("y",))
	UriAndRange range = ctx.curFun.range;
	ConcreteLocal* param = &only(ctx.curFun.params);
	EnumOrFlagsMember[] members = mustBeFlags(param.type).members;
	IntegralType storage = integralTypeFromFlagsType(param.type);
	ConcreteType storageType = integralType(ctx.concretizeCtx, storage);
	ConcreteExpr value = genCastIntegral(ctx.concretizeCtx, range, storage, genParamGet(ctx.curFun.range, param));
	ConcreteType arrayType = ctx.curFun.returnType;
	ConcreteStruct* arrayStruct = mustBeByVal(arrayType);
	ConcreteExpr emptyArray = genConstant(arrayType, range, getConstantArray(ctx.alloc, ctx.allConstants, arrayStruct, []));
	return isEmpty(members)
		? emptyArray
		: mapReduce!(ConcreteExpr, EnumOrFlagsMember)(
			members, 
			(ref EnumOrFlagsMember member) {
				// (value & x == 0) ? () : ("x",)
				ConcreteExpr test = genEqualIntegral(
					ctx.concretizeCtx, range, storage,
					genIntersectIntegral(ctx.concretizeCtx, range, storage, value, genConstantIntegral(storageType, range, member.value)),
					genConstantIntegral(storageType, range, IntegralValue(0)));
				ConcreteExpr array = genConstant(arrayType, range, getConstantArray(ctx.alloc, ctx.allConstants, arrayStruct, newArray(ctx.alloc, [
					constantSymbol(ctx.concretizeCtx, member.name)])));
				return genIf(ctx.alloc, range, test, emptyArray, array);
			},
			(ConcreteExpr x, ConcreteExpr y) =>
				genConcatSymbolArray(ctx.concretizeCtx, range, x, y));
}

ConcreteExpr genConcatSymbolArray(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genCall(ctx.alloc, range, ctx.concatSymbolArrayFunction, [a, b]);

private ConcreteExpr autoFunMatchEnum(ref ConcretizeExprCtx ctx, in ConcreteExpr delegate(ref EnumOrFlagsMember) @safe @nogc pure nothrow cb) {
	UriAndRange range = ctx.curFun.range;
	ConcreteType type = ctx.curFun.returnType;
	ConcreteLocal* param = &only(ctx.curFun.params);
	EnumOrFlagsMember[] members = mustBeEnum(param.type);
	//TODO: use 'gen' functions to simplify --------------------------------------------------------------------------------
	return ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc, ConcreteExprKind.MatchEnumOrIntegral(
		genParamGet(range, param),
		mapToIntegralValues!EnumOrFlagsMember(members, (ref EnumOrFlagsMember x) => x.value),
		map(ctx.alloc, members, cb),
		none!(ConcreteExpr*)))));
}

private EnumOrFlagsMember[] mustBeEnum(ConcreteType a) =>
	mustBeByVal(a).source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Enum*).members;
private ref StructBody.Flags mustBeFlags(ConcreteType a) =>
	mustBeByVal(a).source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Flags);

private ConcreteExpr concretizeSymbolToOptEnum(ref ConcretizeExprCtx ctx) {
	UriAndRange range = ctx.curFun.range;
	ConcreteType optionType = ctx.curFun.returnType;
	ConcreteType enumType = unwrapOptionType(ctx.concretizeCtx.commonTypes, optionType);
	ConcreteLocal* param = &only(ctx.curFun.params);
	ConcreteType symbolType = param.type;
	ConcreteExpr paramGet = genParamGet(range, param);
	return foldReverse!(ConcreteExpr, EnumOrFlagsMember)(
		genNone(ctx.concretizeCtx, optionType, range),
		mustBeEnum(enumType),
		(ConcreteExpr else_, ref EnumOrFlagsMember member) {
			// a == "foo" ? (foo,) : else_
			// TODO: USE HELPER FNS ---------------------------------------------------------------------------------------------
			ConcreteExpr eq = ConcreteExpr(
				boolType(ctx.concretizeCtx),
				range,
				ConcreteExprKind(ConcreteExprKind.Call(ctx.concretizeCtx.equalSymbolFunction, newSmallArray!ConcreteExpr(ctx.alloc, [
					paramGet,
					symbolForEnumMember(ctx.concretizeCtx, symbolType, range, member),
				]))));
			ConcreteExpr enumValue = genConstant(enumType, range, Constant(member.value));
			ConcreteExpr someEnumValue = genSome(ctx.concretizeCtx, optionType, range, enumValue);
			return ConcreteExpr(optionType, range, ConcreteExprKind(allocate(ctx.alloc, ConcreteExprKind.If(eq, someEnumValue, else_))));
		});
}

private ConcreteExpr symbolForEnumMember(
	ref ConcretizeCtx ctx,
	ConcreteType symbolType,
	UriAndRange range,
	in EnumOrFlagsMember member,
) =>
	genConstant(symbolType, range, constantSymbol(ctx, member.name));

ConcreteType sameType(ConcreteLocal[] params) {
	assert(allSame!(ConcreteType, ConcreteLocal)(params, (in ConcreteLocal x) => x.type));
	return params[0].type;
}

T handleEnumFlagsRecordOrUnion(T)(
	in ConcreteType type,
	in T delegate(StructBody.Enum) @safe @nogc pure nothrow cbEnum,
	in T delegate(StructBody.Flags) @safe @nogc pure nothrow cbFlags,
	in T delegate(ConcreteStructBody.Record) @safe @nogc pure nothrow cbRecord,
	in T delegate(ConcreteStructBody.Union) @safe @nogc pure nothrow cbUnion,
) =>
	type.struct_.body_.match!T(
		(ref ConcreteStructBody.Builtin) =>
			assert(false),
		(ConcreteStructBody.Enum) =>
			cbEnum(*type.struct_.source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Enum*)),
		(ConcreteStructBody.Extern) =>
			assert(false),
		(ConcreteStructBody.Flags) =>
			cbFlags(type.struct_.source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Flags)),
		cbRecord,
		cbUnion);

ConcreteExpr concretizeCompareRecord(ref ConcretizeExprCtx ctx, in ConcreteField[] fields, in Called[] fieldCompares) =>
	equalOrCompareRecord(
		ctx, fields, fieldCompares,
		() => genComparisonEqual(ctx.curFun.returnType, ctx.curFun.range),
		(ConcreteExpr x, ConcreteExpr y) => genCompareOr(ctx.alloc, ctx.curFun.range, x, y));

ConcreteExpr equalOrCompareRecord(
	ref ConcretizeExprCtx ctx,
	in ConcreteField[] fields,
	in Called[] fieldCalled,
	in ConcreteExpr delegate() @safe @nogc pure nothrow cbNoFields,
	in ConcreteExpr delegate(ConcreteExpr, ConcreteExpr) @safe @nogc pure nothrow cbFold,
) {
	assert(sizeEq(fields, fieldCalled));
	if (isEmpty(fields))
		return cbNoFields();
	else {
		UriAndRange range = ctx.curFun.range;
		ConcreteLocal[] params = ctx.curFun.params;
		assert(params.length == 2);
		ConcreteExpr* p0 = allocate(ctx.alloc, genIdentifier(range, &params[0]));
		ConcreteExpr* p1 = allocate(ctx.alloc, genIdentifier(range, &params[1]));
		return foldRange(
			fields.length,
			(size_t index) =>
				concretizeAndCall(ctx, fieldCalled[index], range, [
					genRecordFieldGet(fields[index].type, range, p0, index),
					genRecordFieldGet(fields[index].type, range, p1, index)]),
			cbFold);
	}
}

ConcreteExpr concretizeCompareUnion(
	ref ConcretizeExprCtx ctx,
	SmallArray!ConcreteType members,
	in Called[] memberCompares,
) {
	assert(sizeEq(members, memberCompares));
	UriAndRange range = ctx.curFun.range;
	if (members.length == 0)
		return genComparisonEqual(ctx.curFun.returnType, range);
	else {
		ConcreteLocal[] params = ctx.curFun.params;
		assert(params.length == 2);
		ConcreteExpr* p0 = allocate(ctx.alloc, genParamGet(range, &params[0]));
		ConcreteExpr* p1 = allocate(ctx.alloc, genParamGet(range, &params[1]));
		ConcreteExpr p0Kind = genUnionKind(ctx.concretizeCtx, range, p0);
		ConcreteExpr p1Kind = genUnionKind(ctx.concretizeCtx, range, p1);
		// p0.kind < p1.kind ? less : p1.kind < p0.kind ? greater : p0.kind match ...
		return genIf(
			ctx.alloc,
			range,
			genCall(ctx.alloc, range, ctx.concretizeCtx.lessNat64Function, [p0Kind, p1Kind]),
			genComparisonLess(ctx.curFun.returnType, range),
			genIf(
				ctx.alloc,
				range,
				genCall(ctx.alloc, range, ctx.concretizeCtx.lessNat64Function, [p1Kind, p0Kind]),
				genComparisonGreater(ctx.curFun.returnType, range),
				matchUnionsSameKind(ctx, range, p0, p1, members, memberCompares)));
	}
}

ConcreteExpr concretizeEqualRecord(ref ConcretizeExprCtx ctx, in ConcreteField[] fields, in Called[] fieldEquals) =>
	equalOrCompareRecord(
		ctx, fields, fieldEquals,
		() => genTrue(ctx.concretizeCtx, ctx.curFun.range),
		(ConcreteExpr x, ConcreteExpr y) => genAnd(ctx.concretizeCtx, ctx.curFun.range, x, y));

ConcreteExpr concretizeEqualUnion(
	ref ConcretizeExprCtx ctx,
	SmallArray!ConcreteType members,
	in Called[] memberEquals,
) {
	UriAndRange range = ctx.curFun.range;
	if (members.length == 0)
		return genTrue(ctx.concretizeCtx, range);
	else {
		ConcreteLocal[] params = ctx.curFun.params;
		assert(params.length == 2);
		ConcreteExpr* p0 = allocate(ctx.alloc, genParamGet(range, &params[0]));
		ConcreteExpr* p1 = allocate(ctx.alloc, genParamGet(range, &params[1]));
		return genAnd(
			ctx.concretizeCtx, range,
			genEqualNat64(
				ctx.concretizeCtx, range,
				genUnionKind(ctx.concretizeCtx, range, p0),
				genUnionKind(ctx.concretizeCtx, range, p1)),
			matchUnionsSameKind(ctx, range, p0, p1, members, memberEquals));
	}
}

// Caller should guarantee that unions have the same kind
ConcreteExpr matchUnionsSameKind(
	ref ConcretizeExprCtx ctx,
	UriAndRange range,
	ConcreteExpr* p0,
	ConcreteExpr* p1,
	in SmallArray!ConcreteType members,
	in Called[] calleds,
) {
	assert(sizeEq(members, calleds));
	return genMatchUnion(
		ctx.concretizeCtx, ctx.curFun.returnType, range, members, *p0,
		(size_t memberIndex, ConcreteExpr getMember) =>
			concretizeAndCall(ctx, calleds[memberIndex], range, [
				getMember,
				genUnionAs(getMember.type, range, p1, safeToUint(memberIndex))]));
}

ConcreteExpr concretizeRecordToJson(ref ConcretizeExprCtx ctx, in ConcreteField[] fields, in Called[] fieldToJson) {
	assert(sizeEq(fields, fieldToJson));
	UriAndRange range = ctx.curFun.range;
	ConcreteExpr* getParam = allocate(ctx.alloc, genParamGet(range, &only(ctx.curFun.params)));
	return genNewJson(ctx.concretizeCtx, range, mapZipWithIndex!(ConcreteExpr, RecordField, Called)(
		ctx.alloc, recordFieldsForNames(only(ctx.curFun.params).type), fieldToJson,
		(size_t fieldIndex, ref RecordField field, ref Called called) =>
			genSymbolJsonTuple(ctx.concretizeCtx, range, field.name, concretizeAndCall(ctx, called, range, [
				genRecordFieldGet(fields[fieldIndex].type, range, getParam, fieldIndex)]))));
}

ConcreteExpr concretizeUnionToJson(
	ref ConcretizeExprCtx ctx,
	in SmallArray!ConcreteType memberTypes,
	in Called[] memberToJson,
) {
	UriAndRange range = ctx.curFun.range;
	UnionMember[] members = unionMembersForNames(only(ctx.curFun.params).type);
	assert(sizeEq3(memberTypes, memberToJson, members));
	ConcreteExpr getParam = genParamGet(range, &only(ctx.curFun.params));
	return genNewJson(ctx.concretizeCtx, range, [
		genMatchUnion(
			ctx.concretizeCtx, symbolJsonTupleType(ctx.concretizeCtx), range, memberTypes, getParam,
			(size_t memberIndex, ConcreteExpr getMember) =>
				genSymbolJsonTuple(
					ctx.concretizeCtx, range, members[memberIndex].name,
					concretizeAndCall(ctx, memberToJson[memberIndex], range, [getMember])))]);
}

ref StructBody body_(ConcreteType a) =>
	a.struct_.source.as!(ConcreteStructSource.Inst).decl.body_;
// Discards concrete type info, so used only for names
RecordField[] recordFieldsForNames(ConcreteType a) =>
	body_(a).as!(StructBody.Record).fields;
UnionMember[] unionMembersForNames(ConcreteType a) =>
	body_(a).as!(StructBody.Union*).members;

ConcreteExpr concretizeAndCall(
	ref ConcretizeExprCtx ctx,
	Called called,
	UriAndRange range,
	in ConcreteExpr[] args,
) {
	Opt!(ConcreteFun*) fun = getConcreteFunFromCalled(ctx, called);
	return has(fun)
		? genCall(ctx.alloc, range, force(fun), args)
		: concretizeBogus(ctx.concretizeCtx, getConcreteType(ctx, called.returnType), range);
}

ConcreteExpr genJsonOfString(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr string_) =>
	genCall(ctx.alloc, range, ctx.toJsonFromStringFunction, newArray(ctx.alloc, [string_]));

ConcreteExpr genNewJson(ref ConcretizeCtx ctx, UriAndRange range, in ConcreteExpr[] elements) =>
	genCallVariadic(ctx.alloc, range, ctx.newJsonFromPairsFunction, newArray(ctx.alloc, elements));

ConcreteType symbolJsonTupleType(ref ConcretizeCtx ctx) =>
	arrayElementType(only(ctx.newJsonFromPairsFunction.params).type);

ConcreteExpr genSymbolJsonTuple(ref ConcretizeCtx ctx, UriAndRange range, Symbol symbol, ConcreteExpr value) =>
	genCreateRecord(ctx.alloc, symbolJsonTupleType(ctx), range, [genConstantSymbol(ctx, range, symbol), value]);

ConcreteExpr genComparisonLess(ConcreteType comparisonType, UriAndRange range) =>
	genConstant(comparisonType, range, Constant(IntegralValue(0)));
ConcreteExpr genComparisonEqual(ConcreteType comparisonType, UriAndRange range) =>
	genConstant(comparisonType, range, Constant(IntegralValue(1)));
ConcreteExpr genComparisonGreater(ConcreteType comparisonType, UriAndRange range) =>
	genConstant(comparisonType, range, Constant(IntegralValue(2)));

ConcreteExpr genCompareOr(ref Alloc alloc, UriAndRange range, ConcreteExpr a, ConcreteExpr b) {
	ConcreteType comparison = a.type;
	return ConcreteExpr(comparison, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.MatchEnumOrIntegral(
		a,
		integralValuesRange(3),
		newArray(alloc, [
			genConstant(comparison, range, Constant(IntegralValue(0))),
			b,
			genConstant(comparison, range, Constant(IntegralValue(2)))]),
		none!(ConcreteExpr*)))));
}
