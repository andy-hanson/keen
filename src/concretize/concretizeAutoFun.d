module concretize.concretizeAutoFun;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : getConstantArray, getConstantString;
import concretize.concretizeCtx :
	ConcretizeCtx,
	constantSymbol,
	getConcreteFun,
	getConcreteType,
	integralType,
	stringType,
	symbolType;
import concretize.concretizeExpr : ConcretizeExprCtx, getConcreteFunFromCalled, getConcreteType, withConcretizeExprCtx;
import concretize.generate :
	genAnd,
	genBogus,
	genCall,
	genCallVariadic,
	genConstantSome,
	genCreateRecord,
	genConstant,
	genConstantIntegral,
	genConstantSymbol,
	genEqualIntegral,
	genEqualNat64,
	genEqualPointer,
	genIf,
	genIntersectIntegral,
	genLessIntegral,
	genLessNat64,
	genLocalGet,
	genMatchEnumOrIntegral,
	genMatchUnion,
	genNegateIntegral,
	genNone,
	genParamGet,
	genRecordFieldGet,
	genSome,
	genTrue,
	genUnionAs,
	genUnionIntegral,
	genUnionKind;
import model.concreteModel :
	arrayElementType,
	CastConcreteExpr,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteLocal,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructSource,
	ConcreteType,
	isFlags,
	mustBeEnumOrFlags,
	mustBeFlags,
	mustBeByVal,
	unwrapOptionType;
import model.constant : Constant;
import model.model :
	asUnion,
	AutoFun,
	AutoFunKind,
	Called,
	EnumOrFlagsMember,
	FlagsFunction,
	getAllFlagsValue,
	IntegralType,
	RecordField,
	StructBody,
	SumTypeMemberAndMethodImpls;
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
	only,
	sizeEq,
	sizeEq3,
	SmallArray;
import util.conv : safeToUint;
import util.integralValues : IntegralValue;
import util.memory : allocate;
import util.opt : force, has, none, Opt;
import util.sourceRange : UriAndRange;
import util.symbol : Symbol, symbol;

ConcreteExpr concretizeAutoFun(ref ConcretizeExprCtx ctx, ref AutoFun a) {
	ConcreteExpr param0() =>
		genParamGet(ctx.curFun.range, &ctx.curFun.params[0]);
	ConcreteExpr param1() =>
		genParamGet(ctx.curFun.range, &ctx.curFun.params[1]);
	UriAndRange range() => ctx.curFun.range;
	final switch (a.kind) {
		case AutoFunKind.compare:
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
		case AutoFunKind.enumOrFlagsMembers:
			Constant[] elements = map(
				ctx.alloc,
				enumOrFlagsMembers(arrayElementType(ctx.curFun.returnType)),
				(ref EnumOrFlagsMember member) => Constant(member.value));
			Constant res = getConstantArray(ctx.alloc, ctx.allConstants, mustBeByVal(ctx.curFun.returnType), elements);
			return ConcreteExpr(ctx.curFun.returnType, range, ConcreteExprKind(res));
		case AutoFunKind.enumOrFlagsToIntegral:
			return genCast(ctx.alloc, ctx.curFun.returnType, range, param0());
		case AutoFunKind.enumToSymbol:
			return concretizeEnumToSymbol(ctx);
		case AutoFunKind.equals:
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
		case AutoFunKind.flagsToSymbolArray:
			return concretizeFlagsToSymbolArray(ctx);
		case AutoFunKind.integralToOptEnumOrFlags:
			return concretizeIntegralToOptEnumOrFlags(ctx);
		case AutoFunKind.symbolToOptEnumOrFlags:
			return concretizeSymbolToOptEnumOrFlags(ctx);
		case AutoFunKind.toJson:
			return handleEnumFlagsRecordOrUnion(
				only(ctx.curFun.params).type,
				(StructBody.Enum x) =>
					concretizeEnumToJson(ctx),
				(StructBody.Flags) =>
					concretizeFlagsToJson(ctx),
				(ConcreteStructBody.Record x) =>
					concretizeRecordToJson(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeUnionToJson(ctx, x.members, a.members));
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
				return genFlagsIn(ctx, range, storage, castParam0(storage), castParam1(storage));
			case FlagsFunction.intersect:
				IntegralType storage = integralTypeFromFlagsType(cf.params[0].type);
				return castToFlags(genIntersectIntegral(ctx, range, storage, castParam0(storage), castParam1(storage)));
			case FlagsFunction.negate:
				// ~x & all
				IntegralType storage = integralTypeFromFlagsType(cf.params[0].type);
				return castToFlags(
					genIntersectIntegral(
						ctx, range, storage,
						genNegateIntegral(ctx, range, storage, castParam0(storage)),
						getAllFlagsExpr(ctx, range, cf.returnType)));
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

ConcreteExpr getAllFlagsExpr(ref ConcretizeCtx ctx, UriAndRange range, ConcreteType flagsType) =>
	genConstantIntegral(
		integralType(ctx, integralTypeFromFlagsType(flagsType)),
		range,
		getAllFlagsValue(mustBeFlags(flagsType)));

// WARN: p0 is used twice, so it should be a param get (or other expression that has no side effect)
ConcreteExpr genFlagsIn(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	IntegralType storage,
	ConcreteExpr p0,
	ConcreteExpr p1,
) {
	assert(p0.type == p1.type);
	return genEqualIntegral(ctx, range, storage, genIntersectIntegral(ctx, range, storage, p0, p1), p0);
}

IntegralType integralTypeFromFlagsType(in ConcreteType a) =>
	mustBeByVal(a).body_.as!(ConcreteStructBody.Flags).storage;

SmallArray!EnumOrFlagsMember enumOrFlagsMembers(ConcreteType type) {
	StructBody body_ = mustBeByVal(type).source.as!(ConcreteStructSource.Inst).decl.body_;
	return body_.isA!(StructBody.Enum*) ? body_.as!(StructBody.Enum*).members : body_.as!(StructBody.Flags).members;
}

ConcreteExpr concretizeEqualEnumOrFlags(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	IntegralType storage,
	ConcreteExpr arg0,
	ConcreteExpr arg1,
) =>
	genEqualIntegral(
		ctx, range, storage,
		genCastIntegral(ctx, range, storage, arg0),
		genCastIntegral(ctx, range, storage, arg1));

ConcreteExpr genCompareIntegral(
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

ConcreteExpr genCastIntegral(ref ConcretizeCtx ctx, UriAndRange range, IntegralType type, ConcreteExpr arg) =>
	genCast(ctx.alloc, integralType(ctx, type), range, arg);

ConcreteExpr genCast(ref Alloc alloc, ConcreteType type, UriAndRange range, ConcreteExpr arg) =>
	ConcreteExpr(type, range, ConcreteExprKind(CastConcreteExpr(allocate(alloc, arg))));

ConcreteExpr concretizeEnumToJson(ref ConcretizeExprCtx ctx) =>
	autoFunMatchEnum(ctx, (ref EnumOrFlagsMember x) =>
		genConstant(
			ctx.curFun.returnType,
			ctx.curFun.range,
			constantJsonString(ctx.concretizeCtx, ctx.curFun.returnType, x.name)));

ConcreteExpr concretizeEnumToSymbol(ref ConcretizeExprCtx ctx) =>
	autoFunMatchEnum(ctx, (ref EnumOrFlagsMember x) =>
		symbolForEnumMember(ctx.concretizeCtx, ctx.curFun.returnType, ctx.curFun.range, x));

ConcreteExpr concretizeFlagsToJson(ref ConcretizeExprCtx ctx) {
	ConcreteFun* to = ctx.concretizeCtx.toJsonFromJsonArrayFunction;
	ConcreteType jsonArrayType = only(to.params).type;
	return genCall(ctx.alloc, ctx.curFun.range, to, [
		concretizeFlagsToArray(ctx, jsonArrayType, (ref EnumOrFlagsMember member) =>
			constantJsonString(ctx.concretizeCtx, ctx.curFun.returnType, member.name))]);
}

Constant constantJsonString(ref ConcretizeCtx ctx, ConcreteType jsonType, Symbol value) {
	ConcreteType[] members = mustBeByVal(jsonType).body_.as!(ConcreteStructBody.Union).members;
	size_t memberIndex = 3;
	ConcreteType string_ = stringType(ctx);
	assert(members[memberIndex] == string_);
	return Constant(allocate(ctx.alloc, Constant.Union(
		memberIndex,
		getConstantString(ctx.alloc, ctx.allConstants, mustBeByVal(string_), value))));
}

ConcreteExpr concretizeFlagsToSymbolArray(ref ConcretizeExprCtx ctx) =>
	concretizeFlagsToArray(ctx, ctx.curFun.returnType, (ref EnumOrFlagsMember member) =>
		constantSymbol(ctx.concretizeCtx, member.name));

ConcreteExpr concretizeFlagsToArray(
	ref ConcretizeExprCtx ctx,
	ConcreteType arrayType,
	in Constant delegate(ref EnumOrFlagsMember) @safe @nogc pure nothrow cb,
) {
	// (a & x == 0 ? () : ("x",)) ~~ (a & y == 0 ? () : ("y",))
	UriAndRange range = ctx.curFun.range;
	ConcreteLocal* param = &only(ctx.curFun.params);
	EnumOrFlagsMember[] members = mustBeFlags(param.type).members;
	IntegralType storage = integralTypeFromFlagsType(param.type);
	ConcreteType storageType = integralType(ctx.concretizeCtx, storage);
	ConcreteExpr value = genCastIntegral(ctx.concretizeCtx, range, storage, genParamGet(ctx.curFun.range, param));
	ConcreteStruct* arrayStruct = mustBeByVal(arrayType);
	ConcreteExpr emptyArray = genConstant(
		arrayType, range,
		getConstantArray(ctx.alloc, ctx.allConstants, arrayStruct, []));
	return isEmpty(members)
		? emptyArray
		: mapReduce!(ConcreteExpr, EnumOrFlagsMember)(
			members,
			(ref EnumOrFlagsMember member) {
				// (value & x == 0) ? () : ("x",)
				ConcreteExpr test = genEqualIntegral(
					ctx.concretizeCtx, range, storage,
					genIntersectIntegral(
						ctx.concretizeCtx, range, storage,
						value,
						genConstantIntegral(storageType, range, member.value)),
					genConstantIntegral(storageType, range, IntegralValue(0)));
				ConcreteExpr array = genConstant(
					arrayType, range,
					getConstantArray(ctx.alloc, ctx.allConstants, arrayStruct, newArray(ctx.alloc, [
						cb(member)])));
				return genIf(ctx.alloc, range, test, emptyArray, array);
			},
			(ConcreteExpr x, ConcreteExpr y) =>
				genConcatArray(ctx.concretizeCtx, range, x, y));
}

ConcreteExpr genConcatArray(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr a, ConcreteExpr b) {
	assert(a.type == b.type);
	return genCall(
		ctx.alloc, range,
		getConcreteFun(ctx, ctx.commonFuns.concatArrays, [arrayElementType(a.type)], []),
		[a, b]);
}

ConcreteExpr autoFunMatchEnum(
	ref ConcretizeExprCtx ctx,
	in ConcreteExpr delegate(ref EnumOrFlagsMember) @safe @nogc pure nothrow cb,
) =>
	genMatchEnumOrIntegral(
		ctx.alloc, ctx.curFun.returnType, ctx.curFun.range,
		genParamGet(ctx.curFun.range, &only(ctx.curFun.params)),
		cb);

ConcreteExpr concretizeIntegralToOptEnumOrFlags(ref ConcretizeExprCtx ctx) =>
	isFlags(unwrapOptionType(ctx.curFun.returnType))
		? concretizeIntegralToOptFlags(ctx)
		: concretizeConvertToOptEnumOrFlags(
			ctx, (UriAndRange range, ConcreteExpr paramGet, ref EnumOrFlagsMember member) =>
				genEqualIntegral(
					ctx.concretizeCtx, range, member.storage,
					paramGet,
					integralForEnumMember(ctx.concretizeCtx, range, member)));

ConcreteExpr concretizeIntegralToOptFlags(ref ConcretizeExprCtx ctx) {
	UriAndRange range = ctx.curFun.range;
	ConcreteType optionType = ctx.curFun.returnType;
	ConcreteType flagsType = unwrapOptionType(optionType);
	IntegralType storage = integralTypeFromFlagsType(flagsType);
	ConcreteExpr paramGet = genParamGet(range, &only(ctx.curFun.params));
	// a in all ? some(a) : none
	return genIf(
		ctx.alloc,
		range,
		genFlagsIn(ctx.concretizeCtx, range, storage, paramGet, getAllFlagsExpr(ctx.concretizeCtx, range, flagsType)),
		genSome(ctx.concretizeCtx, optionType, range, genCast(ctx.alloc, flagsType, range, paramGet)),
		genNone(ctx.concretizeCtx, optionType, range));
}

ConcreteExpr concretizeSymbolToOptEnumOrFlags(ref ConcretizeExprCtx ctx) =>
	concretizeConvertToOptEnumOrFlags(ctx, (UriAndRange range, ConcreteExpr paramGet, ref EnumOrFlagsMember member) =>
		genEqualPointer(
			ctx.concretizeCtx, range, paramGet,
			symbolForEnumMember(ctx.concretizeCtx, paramGet.type, range, member)));

ConcreteExpr concretizeConvertToOptEnumOrFlags(
	ref ConcretizeExprCtx ctx,
	in ConcreteExpr delegate(UriAndRange, ConcreteExpr, ref EnumOrFlagsMember) @safe @nogc pure nothrow cbTest,
) {
	UriAndRange range = ctx.curFun.range;
	ConcreteType optionType = ctx.curFun.returnType;
	ConcreteType enumType = unwrapOptionType(optionType);
	ConcreteExpr paramGet = genParamGet(range, &only(ctx.curFun.params));
	return foldReverse!(ConcreteExpr, EnumOrFlagsMember)(
		genNone(ctx.concretizeCtx, optionType, range),
		mustBeEnumOrFlags(enumType),
		(ConcreteExpr else_, ref EnumOrFlagsMember member) {
			// a == "foo" ? (foo,) : <<else>>
			ConcreteExpr eq = cbTest(range, paramGet, member);
			ConcreteExpr someEnumValue = genConstantSome(ctx.concretizeCtx, optionType, range, Constant(member.value));
			return genIf(ctx.alloc, range, eq, someEnumValue, else_);
		});
}

ConcreteExpr integralForEnumMember(
	ref ConcretizeCtx ctx,
	UriAndRange range,
	in EnumOrFlagsMember member,
) =>
	genConstantIntegral(integralType(ctx, member.storage), range, member.value);

ConcreteExpr symbolForEnumMember(
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
		ConcreteExpr* p0 = allocate(ctx.alloc, genLocalGet(range, &params[0]));
		ConcreteExpr* p1 = allocate(ctx.alloc, genLocalGet(range, &params[1]));
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
			genLessNat64(ctx.concretizeCtx, range, p0Kind, p1Kind),
			genComparisonLess(ctx.curFun.returnType, range),
			genIf(
				ctx.alloc,
				range,
				genLessNat64(ctx.concretizeCtx, range, p1Kind, p0Kind),
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
	SumTypeMemberAndMethodImpls[] members = unionMembersForNames(only(ctx.curFun.params).type);
	assert(sizeEq3(memberTypes, memberToJson, members));
	ConcreteExpr getParam = genParamGet(range, &only(ctx.curFun.params));
	return genNewJson(ctx.concretizeCtx, range, [
		genMatchUnion(
			ctx.concretizeCtx, symbolJsonTupleType(ctx.concretizeCtx), range, memberTypes, getParam,
			(size_t memberIndex, ConcreteExpr getMember) =>
				genSymbolJsonTuple(
					ctx.concretizeCtx, range, members[memberIndex].member.decl.name,
					concretizeAndCall(ctx, memberToJson[memberIndex], range, [getMember])))]);
}

ref StructBody body_(ConcreteType a) =>
	a.struct_.source.as!(ConcreteStructSource.Inst).decl.body_;
// Discards concrete type info, so used only for names
RecordField[] recordFieldsForNames(ConcreteType a) =>
	body_(a).as!(StructBody.Record).fields;
SumTypeMemberAndMethodImpls[] unionMembersForNames(ConcreteType a) =>
	asUnion(body_(a));

ConcreteExpr concretizeAndCall(
	ref ConcretizeExprCtx ctx,
	Called called,
	UriAndRange range,
	in ConcreteExpr[] args,
) {
	Opt!(ConcreteFun*) fun = getConcreteFunFromCalled(ctx, called);
	return has(fun)
		? genCall(ctx.alloc, range, force(fun), args)
		: genBogus(ctx.concretizeCtx, getConcreteType(ctx, called.returnType), range);
}

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

ConcreteExpr genCompareOr(ref Alloc alloc, UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genMatchEnumOrIntegral(alloc, a.type, range, a, (ref EnumOrFlagsMember x) =>
		x.value.value == 1 ? b : genConstant(a.type, range, Constant(x.value)));
