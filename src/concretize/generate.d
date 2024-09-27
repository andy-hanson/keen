module concretize.generate;

@safe @nogc pure nothrow:

import concretize.allConstantsBuilder : getConstantArray;
import concretize.concretizeCtx :
	boolType,
	char8ArrayType,
	char32ArrayType,
	ConcreteLambdaImpl,
	ConcreteVariantMemberAndMethodImpls,
	ConcretizeCtx,
	constantOfBytes,
	constantSymbol,
	getConcreteFun,
	getReferencedType,
	nat64Type,
	symbolType,
	voidType;
import concretize.concretizeExpr : concretizeBogus, ConcretizeExprCtx, getConcreteFunFromCalled, getConcreteType;
import model.concreteModel :
	arrayElementType,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteLocal,
	ConcreteLocalSource,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructSource,
	ConcreteType,
	isVoid,
	mustBeByVal;
import model.constant : Constant, constantBool, constantZero;
import model.model : AutoFun, Called, EnumOrFlagsMember, FunBody, RecordField, StructBody, UnionMember;
import util.alloc.alloc : Alloc;
import util.col.array :
	allSame,
	foldRange,
	isEmpty,
	map,
	mapPointers,
	mapPointersWithIndex,
	mapWithIndex,
	mapZipWithIndex,
	mustHaveIndexOfPointer,
	newArray,
	newSmallArray,
	only,
	only2,
	sizeEq,
	sizeEq3,
	small,
	SmallArray;
import util.col.arrayBuilder : buildArray, Builder;
import util.conv : safeToUint;
import util.integralValues : IntegralValue, integralValuesRange;
import util.memory : allocate;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : UriAndRange;
import util.string : bytesOfString;
import util.symbol : Symbol, symbol;
import util.unicode : mustUnicodeDecode;

ConcreteExpr genConstant(ConcreteType type, UriAndRange range, Constant value) =>
	ConcreteExpr(type, range, ConcreteExprKind(value));

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
	ConcreteExprKind(ConcreteExprKind.Call(called, small!ConcreteExpr(args)));

private ConcreteExpr genIf(
	ref Alloc alloc, UriAndRange range, ConcreteExpr cond, ConcreteExpr then, ConcreteExpr else_,
) =>
	ConcreteExpr(then.type, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.If(cond, then, else_))));

ConcreteExpr genLoop(ref ConcretizeExprCtx ctx, ConcreteType type, in UriAndRange range, ConcreteExpr body_) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(ctx.alloc, ConcreteExprKind.Loop(body_))));

ConcreteExpr genDoAndContinue(ref Alloc alloc, ConcreteType type, in UriAndRange range, ConcreteExpr a) =>
	genSeq(alloc, range, a, genContinue(type, range));

ConcreteExpr genSeq(ref Alloc alloc, in UriAndRange range, ConcreteExpr a, ConcreteExpr b) {
	assert(isVoid(a.type));
	return ConcreteExpr(b.type, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.Seq(a, b))));
}

ConcreteExpr genDropAnd(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr a, ConcreteExpr b) =>
	genSeq(ctx.alloc, range, genDrop(ctx, range, a), b);

ConcreteExpr genContinue(ConcreteType type, in UriAndRange range) =>
	ConcreteExpr(type, range, ConcreteExprKind(ConcreteExprKind.LoopContinue()));

ConcreteExpr genBreak(ref Alloc alloc, in UriAndRange range, ConcreteExpr value) =>
	ConcreteExpr(value.type, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.LoopBreak(value))));

ConcreteExpr genCreateUnion(
	ref Alloc alloc,
	ConcreteType type,
	in UriAndRange range,
	size_t memberIndex,
	ConcreteExpr arg,
) =>
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.CreateUnion(memberIndex, arg))));

ConcreteExpr genSome(ref ConcretizeCtx ctx, ConcreteType optionType, in UriAndRange range, ConcreteExpr arg) {
	assertIsOptionType(ctx, optionType);
	return genCreateUnion(ctx.alloc, optionType, range, 1, arg);
}
ConcreteExpr genNone(ref ConcretizeCtx ctx, ConcreteType optionType, in UriAndRange range) {
	assertIsOptionType(ctx, optionType);
	return genConstant(optionType, range, Constant(allocate(ctx.alloc, Constant.Union(0, constantZero))));
}
ConcreteType unwrapOptionType(in ConcretizeCtx ctx, ConcreteType optionType) {
	assertIsOptionType(ctx, optionType);
	return only(mustBeByVal(optionType).source.as!(ConcreteStructSource.Inst).typeArgs);
}
private void assertIsOptionType(in ConcretizeCtx ctx, ConcreteType optionType) {
	assert(mustBeByVal(optionType).source.as!(ConcreteStructSource.Inst).decl == ctx.commonTypes.option);
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
	ConcreteExpr(type, range, ConcreteExprKind(allocate(alloc, ConcreteExprKind.Let(local, value, then))));

ConcreteExpr genDrop(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr inner) =>
	ConcreteExpr(voidType(ctx), range, ConcreteExprKind(allocate(ctx.alloc, ConcreteExprKind.Drop(inner))));

ConcreteExpr genIdentifier(in UriAndRange range, ConcreteLocal* local) =>
	ConcreteExpr(local.type, range, ConcreteExprKind(ConcreteExprKind.LocalGet(local)));

ConcreteExpr genLocalPointer(ConcreteType type, in UriAndRange range, ConcreteLocal* local) =>
	ConcreteExpr(type, range, ConcreteExprKind(ConcreteExprKind.LocalPointer(local)));

ConcreteExpr genLocalSet(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteLocal* local, ConcreteExpr value) =>
	ConcreteExpr(voidType(ctx), range, ConcreteExprKind(allocate(ctx.alloc, ConcreteExprKind.LocalSet(local, value))));

ConcreteFunBody genRecordFieldCall(ref ConcretizeCtx ctx, ConcreteFun* fun, FunBody.RecordFieldCall body_) {
	UriAndRange range = fun.range;
	ConcreteExpr* recordArg = allocate(ctx.alloc, genParamGet(range, &fun.params[0]));
	size_t fieldIndex = fieldIndexFromField(recordArg.type, body_.field);
	ConcreteStruct* fieldType = mustBeByVal(concreteFieldFromIndex(recordArg.type, fieldIndex).type);
	ConcreteExpr getFun = genRecordFieldGet(ConcreteType.byVal(fieldType), range, recordArg, fieldIndex);
	ConcreteType[] typeArgs = fieldType.source.as!(ConcreteStructSource.Inst).typeArgs;
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
		recordType.struct_.source.as!(ConcreteStructSource.Inst).decl.body_.as!(StructBody.Record).fields,
		field);
private ConcreteField* concreteFieldFromIndex(ConcreteType recordType, size_t fieldIndex) =>
	&recordType.struct_.body_.as!(ConcreteStructBody.Record).fields[fieldIndex];

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

ConcreteFunBody bodyForEnumOrFlagsMembers(ref ConcretizeCtx ctx, ConcreteType returnType) {
	// First type arg is 'symbol'
	ConcreteType enumOrFlagsType =
		only2(mustBeByVal(arrayElementType(returnType)).source.as!(ConcreteStructSource.Inst).typeArgs)[1];
	Constant[] elements = map(ctx.alloc, enumOrFlagsMembers(enumOrFlagsType), (ref EnumOrFlagsMember member) =>
		Constant(Constant.Record(newSmallArray!Constant(ctx.alloc, [
			constantSymbol(ctx, member.name),
			Constant(IntegralValue(member.value.value))]))));
	Constant arr = getConstantArray(ctx.alloc, ctx.allConstants, mustBeByVal(returnType), elements);
	return ConcreteFunBody(ConcreteExpr(returnType, UriAndRange.empty, ConcreteExprKind(arr)));
}

private SmallArray!EnumOrFlagsMember enumOrFlagsMembers(ConcreteType type) {
	StructBody body_ = mustBeByVal(type).source.as!(ConcreteStructSource.Inst).decl.body_;
	return body_.isA!(StructBody.Enum*) ? body_.as!(StructBody.Enum*).members : body_.as!(StructBody.Flags).members;
}

ConcreteExpr concretizeAutoFun(ref ConcretizeExprCtx ctx, ref AutoFun a) {
	final switch (a.kind) {
		case AutoFun.Kind.compare:
			return handleRecordOrUnion(
				sameType(ctx.curFun.params),
				(ConcreteStructBody.Record x) =>
					concretizeCompareRecord(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeCompareUnion(ctx, x.members, a.members));
		case AutoFun.Kind.equals:
			return handleRecordOrUnion(
				sameType(ctx.curFun.params),
				(ConcreteStructBody.Record x) =>
					concretizeEqualRecord(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeEqualUnion(ctx, x.members, a.members));
		case AutoFun.Kind.toJson:
			return handleRecordOrUnion(
				only(ctx.curFun.params).type,
				(ConcreteStructBody.Record x) =>
					concretizeRecordToJson(ctx, x.fields, a.members),
				(ConcreteStructBody.Union x) =>
					concretizeUnionToJson(ctx, x.members, a.members));
	}
}

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
		genMatchUnion(ctx, fun.returnType, range, memberTypes, lambda, (size_t i, ConcreteExpr closure) =>
			genCall(ctx.alloc, range, impls[i].impl, [closure, arg])));
}

ConcreteFunBody generateCallVariantMethod(
	ref ConcretizeCtx ctx,
	ConcreteFun* fun,
	ConcreteStruct* variant,
	in ConcreteVariantMemberAndMethodImpls[] impls,
	size_t methodIndex,
) {
	UriAndRange range = fun.range;
	SmallArray!ConcreteType members = variant.body_.as!(ConcreteStructBody.Union).members;
	return isEmpty(members)
		? ConcreteFunBody(genThrowString(ctx, fun.returnType, range, "Called method of empty variant"))
		: ConcreteFunBody(genMatchUnion(
			ctx, fun.returnType, range, members,
			genParamGet(range, &fun.params[0]),
			(size_t i, ConcreteExpr member) {
				Opt!(ConcreteFun*) impl = impls[i].methodImpls[methodIndex];
				return has(impl)
					? genCallNoAllocArgs(
						range, force(impl),
						mapPointersWithIndex(ctx.alloc, fun.params, (size_t paramIndex, ConcreteLocal* param) =>
							paramIndex == 0 ? member : genParamGet(range, param)))
					: concretizeBogus(ctx, fun.returnType, range);
			}));
}

ConcreteExpr genThrow(ref Alloc alloc, ConcreteType type, UriAndRange range, ConcreteExpr thrown) =>
	ConcreteExpr(type, range, genThrowKind(alloc, thrown));

private ConcreteExprKind genThrowKind(ref Alloc alloc, ConcreteExpr thrown) =>
	ConcreteExprKind(allocate(alloc, ConcreteExprKind.Throw(thrown)));

ConcreteExpr genError(ref ConcretizeCtx ctx, UriAndRange range, string message) =>
	genCall(ctx.alloc, range, ctx.createErrorFunction, [genStringLiteral(ctx, range, message)]);

ConcreteExpr genThrowString(ref ConcretizeCtx ctx, ConcreteType type, UriAndRange range, string message) =>
	genThrow(ctx.alloc, type, range, genError(ctx, range, message));

ConcreteExprKind genThrowStringKind(ref ConcretizeCtx ctx, UriAndRange range, string message) =>
	genThrowKind(ctx.alloc, genError(ctx, range, message));

ConcreteExpr genStringLiteral(ref ConcretizeCtx ctx, UriAndRange range, in string value) =>
	ConcreteExpr(char8ArrayType(ctx), range, genStringLiteralKind(ctx, range, value));

ConcreteExprKind genStringLiteralKind(ref ConcretizeCtx ctx, UriAndRange range, in string value) =>
	genChar8Array(ctx, range, value).kind;

ConcreteExpr genChar8Array(ref ConcretizeCtx ctx, in UriAndRange range, in string value) {
	ConcreteType type = char8ArrayType(ctx);
	return genConstant(type, range, constantOfBytes(ctx, type, bytesOfString(value)));
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

private ConcreteExpr genCallVariadic(ref Alloc alloc, UriAndRange range, ConcreteFun* called, ConcreteExpr[] args) =>
	genCall(alloc, range, called, [genCreateArray(alloc, only(called.params).type, range, args)]);

private ConcreteExpr genCreateArray(ref Alloc alloc, ConcreteType arrayType, UriAndRange range, ConcreteExpr[] args) =>
	ConcreteExpr(arrayType, range, ConcreteExprKind(ConcreteExprKind.CreateArray(args)));

private ConcreteExpr genCreateRecord(ref Alloc alloc, ConcreteType type, UriAndRange range, in ConcreteExpr[] args) =>
	genCreateRecord(type, range, newArray(alloc, args));
ConcreteExpr genCreateRecord(ConcreteType type, UriAndRange range, ConcreteExpr[] args) =>
	ConcreteExpr(type, range, ConcreteExprKind(ConcreteExprKind.CreateRecord(args)));

private ConcreteExpr genConstantSymbol(ref ConcretizeCtx ctx, UriAndRange range, Symbol value) =>
	genConstant(symbolType(ctx), range, constantSymbol(ctx, value));

ConcreteExpr genParamGet(UriAndRange range, ConcreteLocal* param) =>
	ConcreteExpr(param.type, range, ConcreteExprKind(ConcreteExprKind.LocalGet(param)));

ConcreteExpr genRecordFieldGet(
	ConcreteType fieldType, UriAndRange range, ConcreteExpr* arg, size_t fieldIndex,
) =>
	ConcreteExpr(fieldType, range, ConcreteExprKind(ConcreteExprKind.RecordFieldGet(arg, fieldIndex)));
ConcreteExpr genRecordFieldPointer(
	ConcreteType pointerType, UriAndRange range, ConcreteExpr* record, size_t fieldIndex,
) =>
	ConcreteExpr(pointerType, range, ConcreteExprKind(ConcreteExprKind.RecordFieldPointer(record, fieldIndex)));
ConcreteExpr genRecordFieldSet(
	ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr record, size_t fieldIndex, ConcreteExpr value,
) =>
	ConcreteExpr(voidType(ctx), range, ConcreteExprKind(allocate(ctx.alloc,
		ConcreteExprKind.RecordFieldSet(record, fieldIndex, value))));

ConcreteExpr genUnionKind(ref ConcretizeCtx ctx, UriAndRange range, ConcreteExpr* arg) =>
	ConcreteExpr(nat64Type(ctx), range, ConcreteExprKind(ConcreteExprKind.UnionKind(arg)));

ConcreteExpr genUnionAs(ConcreteType type, UriAndRange range, ConcreteExpr* arg, size_t memberIndex) =>
	ConcreteExpr(type, range, ConcreteExprKind(ConcreteExprKind.UnionAs(arg, safeToUint(memberIndex))));

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

private:

ConcreteType sameType(ConcreteLocal[] params) {
	assert(allSame!(ConcreteType, ConcreteLocal)(params, (in ConcreteLocal x) => x.type));
	return params[0].type;
}

T handleRecordOrUnion(T)(
	in ConcreteType type,
	in T delegate(ConcreteStructBody.Record) @safe @nogc pure nothrow cbRecord,
	in T delegate(ConcreteStructBody.Union) @safe @nogc pure nothrow cbUnion,
) {
	ConcreteStruct* s = type.struct_;
	return s.body_.isA!(ConcreteStructBody.Record)
		? cbRecord(s.body_.as!(ConcreteStructBody.Record))
		: s.body_.isA!(ConcreteStructBody.Union)
		? cbUnion(s.body_.as!(ConcreteStructBody.Union))
		: assert(false);
}

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

ConcreteExpr genConstantNat64(ref ConcretizeCtx ctx, in UriAndRange range, ulong value) =>
	genConstant(nat64Type(ctx), range, Constant(IntegralValue(value)));

ConcreteExpr genEqualNat64(ref ConcretizeCtx ctx, in UriAndRange range, ConcreteExpr left, ConcreteExpr right) =>
	genCall(ctx.alloc, range, ctx.equalNat64Function, [left, right]);

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

ConcreteExpr genMatchUnion(
	ref ConcretizeCtx ctx,
	ConcreteType returnType,
	UriAndRange range,
	in SmallArray!ConcreteType memberTypes,
	ConcreteExpr union_,
	in ConcreteExpr delegate(size_t, ConcreteExpr) @safe @nogc pure nothrow cb,
) =>
	ConcreteExpr(returnType, range, ConcreteExprKind(allocate(ctx.alloc, ConcreteExprKind.MatchUnion(
		union_,
		integralValuesRange(memberTypes.length),
		mapWithIndex!(ConcreteExprKind.MatchUnion.Case, ConcreteType)(
			ctx.alloc, memberTypes, (size_t memberIndex, ref ConcreteType memberType) {
				ConcreteLocal* local = allocate(ctx.alloc, ConcreteLocal(
					ConcreteLocalSource(ConcreteLocalSource.Generated(ConcreteLocalSource.Generated.member)),
					memberType));
				return ConcreteExprKind.MatchUnion.Case(some(local), cb(memberIndex, genIdentifier(range, local)));
			}),
		none!(ConcreteExpr*)))));

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
