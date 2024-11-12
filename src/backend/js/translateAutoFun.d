module backend.js.translateAutoFun;

@safe @nogc pure nothrow:

import backend.js.translateExprCtx :
	ExprPos,
	ExprResult,
	genOptionNone,
	genOptionSome,
	makeCall,
	tempName,
	translateEnumValue,
	TranslateExprCtx,
	translateLocalGet,
	translateToBlockStatement;
import backend.js.jsAst :
	exprFunBody,
	genAnd,
	genArray,
	genBlockStatement,
	genBool,
	genCallAwait,
	genCallPropertySync,
	genConst,
	genEqEqEq,
	genIdentifier,
	genIf,
	genIn,
	genLess,
	genNew,
	genNotEqEq,
	genOr,
	genPropertyAccess,
	genReturn,
	genStringFromSymbol,
	genSwitch,
	genTernary,
	genThrowJsError,
	JsBlockStatement,
	JsExpr,
	JsExprOrBlockStatement,
	JsMemberName,
	JsName,
	JsStatement,
	JsSwitchStatement;
import backend.js.sourceMap : Source;
import backend.js.translateModuleCtx :
	funSource,
	TranslateModuleCtx,
	translateFunReference,
	translateStructReference;
import model.model :
	arrayElementType,
	AutoFun,
	BuiltinType,
	Called,
	Destructure,
	EnumOrFlagsMember,
	FunDecl,
	Local,
	mustBeEnumOrFlags,
	mustUnwrapOptionType,
	RecordField,
	StructBody,
	StructDecl,
	StructInst,
	Type,
	UnionMember;
import util.alloc.alloc : Alloc;
import util.col.array :
	foldRange,
	foldReverseWithIndex,
	isEmpty,
	map,
	mapReduce,
	mapWithIndex,
	newArray;
import util.col.arrayBuilder : add, ArrayBuilder;
import util.memory : allocate;
import util.symbol : Symbol, symbol;
import util.union_ : Union;

JsExprOrBlockStatement translateAutoFun(ref TranslateExprCtx ctx, FunDecl* fun, in AutoFun auto_) {
	Source source = funSource(ctx.ctx, fun);
	Destructure[] params = fun.params.as!(Destructure[]);
	JsExpr param(size_t i) =>
		translateLocalGet(source, params[i].as!(Local*));
	StructDecl* struct_() =>
		params[0].type.as!(StructInst*).decl;
	StructDecl* returnStruct = fun.returnType.as!(StructInst*).decl;
	final switch (auto_.kind) {
		case AutoFun.Kind.compare:
			assert(params.length == 2);
			return matchEnumFlagsRecordOrUnion(
				struct_,
				(in StructBody.Enum) =>
					translateCompareEnumOrFlags(ctx, source, returnStruct, param(0), param(1)),
				(in StructBody.Flags) =>
					translateCompareEnumOrFlags(ctx, source, returnStruct, param(0), param(1)),
				(in RecordField[] fields) =>
					translateCompareRecord(ctx, source, auto_, returnStruct, fields, param(0), param(1)),
				(in UnionMember[] members) =>
					translateCompareUnion(ctx, source, auto_, returnStruct, members, param(0), param(1)));
		case AutoFun.Kind.enumOrFlagsMembers:
			StructDecl* enumStruct = arrayElementType(fun.returnType).as!(StructInst*).decl;
			return exprFunBody(
				ctx.alloc,
				translateGetStatic(ctx.ctx, source, enumStruct, JsMemberName.special(symbol!"members")));
		case AutoFun.Kind.enumOrFlagsToIntegral:
			assert(params.length == 1);
			return exprFunBody(ctx.alloc, getEnumValue(ctx.alloc, source, param(0)));
		case AutoFun.Kind.enumToSymbol:
			assert(params.length == 1);
			return exprFunBody(ctx.alloc, getEnumName(ctx.alloc, source, param(0)));
		case AutoFun.Kind.equals:
			assert(params.length == 2);
			return matchEnumFlagsRecordOrUnion(
				struct_,
				(in StructBody.Enum) =>
					translateEqualEnumOrFlags(ctx, source, *struct_, param(0), param(1)),
				(in StructBody.Flags) =>
					translateEqualEnumOrFlags(ctx, source, *struct_, param(0), param(1)),
				(in RecordField[] fields) =>
					translateEqualRecord(ctx, source, auto_, fields, param(0), param(1)),
				(in UnionMember[] members) =>
					translateEqualUnion(ctx, source, auto_, members, param(0), param(1)));
		case AutoFun.Kind.flagsToSymbolArray:
			return exprFunBody(ctx.alloc, flagsToSymbolArray(ctx.ctx, source, struct_, param(0)));
		case AutoFun.Kind.symbolToOptEnumOrFlags:
			assert(params.length == 1);
			return symbolToOptEnumOrFlags(
				ctx, source, fun.returnType,
				mustBeEnumOrFlags(*mustUnwrapOptionType(ctx.commonTypes, fun.returnType).as!(StructInst*).decl),
				param(0));
		case AutoFun.Kind.toJson:
			assert(params.length == 1);
			return matchEnumFlagsRecordOrUnion(
				struct_,
				(in StructBody.Enum) =>
					translateEnumToJson(ctx, source, param(0)),
				(in StructBody.Flags) =>
					translateFlagsToJson(ctx, source, struct_, param(0)),
				(in RecordField[] fields) =>
					translateRecordToJson(ctx, source, auto_, fields, param(0)),
				(in UnionMember[] members) =>
					translateUnionToJson(ctx, source, auto_, members, param(0)));
	}
}

private:

JsExprOrBlockStatement symbolToOptEnumOrFlags(
	ref TranslateExprCtx ctx,
	in Source source,
	Type optionType,
	in EnumOrFlagsMember[] members,
	JsExpr param,
) =>
	JsExprOrBlockStatement(genBlockStatement(ctx.alloc, [
		genSwitch(
			source,
			allocate(ctx.alloc, param),
			map(ctx.alloc, members, (ref EnumOrFlagsMember member) =>
				JsSwitchStatement.Case(
					genStringFromSymbol(source, member.name),
					genBlockReturn(
						ctx.alloc,
						genOptionSome(ctx, source, optionType, translateEnumValue(ctx.ctx, source, member))))),
			genBlockReturn(ctx.alloc, genOptionNone(ctx, source, optionType)))]));

JsBlockStatement genBlockReturn(ref Alloc alloc, JsExpr expr) =>
	genBlockStatement(alloc, [genReturn(alloc, expr.source, expr)]);

JsExprOrBlockStatement translateFlagsToJson(
	ref TranslateExprCtx ctx,
	in Source source,
	StructDecl* flagsStruct,
	JsExpr param,
) =>
	exprFunBody(
		ctx.alloc,
		genJsonOfArray(
			ctx.ctx, source,
			flagsToArray(ctx.ctx, source, flagsStruct, param, (ref EnumOrFlagsMember member) =>
				genJsonOfString(ctx.ctx, source, genStringFromSymbol(source, member.name)))));

JsExpr flagsToSymbolArray(ref TranslateModuleCtx ctx, in Source source, StructDecl* flagsStruct, JsExpr param) =>
	flagsToArray(ctx, source, flagsStruct, param, (ref EnumOrFlagsMember member) =>
		genStringFromSymbol(source, member.name));

JsExpr flagsToArray(
	ref TranslateModuleCtx ctx,
	in Source source,
	StructDecl* flagsStruct,
	JsExpr param,
	in JsExpr delegate(ref EnumOrFlagsMember) @safe @nogc pure nothrow cb,
) {
	JsExpr getFlagsType = translateStructReference(ctx, source, flagsStruct);
	JsExpr emptyArray = genArray(source, []);
	// (F.x.in(a) ? ["x"] : []).concat(F.y.in(a) ? ["y"] : [])
	return mapReduce!(JsExpr, EnumOrFlagsMember)(
		flagsStruct.body_.as!(StructBody.Flags).members,
		(ref EnumOrFlagsMember member) =>
			genTernary(
				ctx.alloc,
				source,
				genCallPropertySync(
					ctx.alloc,
					source,
					genPropertyAccess(ctx.alloc, source, getFlagsType, JsMemberName.enumMember(member.name)),
					JsMemberName.special(symbol!"in"),
					[param]),
				genArray(ctx.alloc, source, [cb(member)]),
				emptyArray),
		(JsExpr x, JsExpr y) =>
			genCallPropertySync(ctx.alloc, source, x, JsMemberName.noPrefix(symbol!"concat"), [y]));
}

JsExprOrBlockStatement matchEnumFlagsRecordOrUnion(
	in StructDecl* struct_,
	in JsExprOrBlockStatement delegate(in StructBody.Enum) @safe @nogc pure nothrow cbEnum,
	in JsExprOrBlockStatement delegate(in StructBody.Flags) @safe @nogc pure nothrow cbFlags,
	in JsExprOrBlockStatement delegate(in RecordField[]) @safe @nogc pure nothrow cbRecord,
	in JsExprOrBlockStatement delegate(in UnionMember[]) @safe @nogc pure nothrow cbUnion,
) =>
	struct_.body_.matchIn!JsExprOrBlockStatement(
		(in StructBody.Bogus) =>
			assert(false),
		(in BuiltinType _) =>
			assert(false),
		cbEnum,
		(in StructBody.Extern) =>
			assert(false),
		cbFlags,
		(in StructBody.Record x) =>
			cbRecord(x.fields),
		(in StructBody.Union x) =>
			cbUnion(x.members),
		(in StructBody.Variant) =>
			assert(false));

JsExpr genCompareLess(ref TranslateModuleCtx ctx, in Source source, StructDecl* comparison) =>
	genGetEnumMember(ctx, source, comparison, symbol!"less");
JsExpr genCompareEqual(ref TranslateModuleCtx ctx, in Source source, StructDecl* comparison) =>
	genGetEnumMember(ctx, source, comparison, symbol!"equal");
JsExpr genCompareGreater(ref TranslateModuleCtx ctx, in Source source, StructDecl* comparison) =>
	genGetEnumMember(ctx, source, comparison, symbol!"greater");

JsExpr genGetEnumMember(ref TranslateModuleCtx ctx, in Source source, in StructDecl* struct_, Symbol name) =>
	translateGetStatic(ctx, source, struct_, JsMemberName.enumMember(name));

JsExpr translateGetStatic(ref TranslateModuleCtx ctx, in Source source, in StructDecl* struct_, JsMemberName name) =>
	genPropertyAccess(ctx.alloc, source, translateStructReference(ctx, source, struct_), name);

JsExprOrBlockStatement translateCompareRecord(
	ref TranslateExprCtx ctx,
	in Source source,
	in AutoFun auto_,
	StructDecl* comparison,
	in RecordField[] fields,
	JsExpr p0,
	JsExpr p1,
) {
	JsExpr equal = genCompareEqual(ctx.ctx, source, comparison);
	if (isEmpty(fields)) return exprFunBody(ctx.alloc, equal);
	/*
	const compareFoo = (p0, p1) => {
		const x = compareX(p0.x, p1.x)
		if (x !== Comparison.equal)
			return x
		const y = compareY(p0.y, p1.y)
		if (y !== Comparison.equal)
			return y
		return compareZ(p0.z, p1.z)
	}
	*/
	return JsExprOrBlockStatement(translateToBlockStatement(
		ctx.alloc,
		(scope ref ArrayBuilder!JsStatement out_, scope ExprPos pos) {
			foreach (size_t index, ref RecordField field; fields) {
				JsExpr compare = genCallCompareProperty(
					ctx, source, auto_.members[index], p0, p1, JsMemberName.recordField(field.name));
				if (index == fields.length - 1)
					add(ctx.alloc, out_, genReturn(ctx.alloc, source, compare));
				else {
					JsName name = tempName(ctx, field.name);
					add(ctx.alloc, out_, genConst(ctx.alloc, source, name, compare));
					add(ctx.alloc, out_, genIf(
						ctx.alloc,
						source,
						genNotEqEq(ctx.alloc, source, genIdentifier(source, name), equal),
						genReturn(ctx.alloc, source, genIdentifier(source, name))));
				}
			}
			return ExprResult.done;
		}));
}
JsExprOrBlockStatement translateCompareUnion(
	ref TranslateExprCtx ctx,
	in Source source,
	in AutoFun auto_,
	StructDecl* comparison,
	in UnionMember[] members,
	JsExpr p0,
	JsExpr p1,
) =>
	/*
	if ("x" in a)
		return "x" in b
			? compare(a.x, b.x)
			: less
	else if ("y" in a)
		return "y" in b
			? compare(a.y, b.y)
			// This needs to have a case for each preceding kind
			: "x" in b ? greater : less
	else
		throw
	*/
	matchUnionMembers(ctx, source, members, p0, (size_t memberIndex, ref UnionMember member) {
		JsExpr comparisonRef = translateStructReference(ctx.ctx, source, comparison);
		JsExpr greater = genPropertyAccess(ctx.alloc, source, comparisonRef, JsMemberName.enumMember(symbol!"greater"));
		JsExpr less = genPropertyAccess(ctx.alloc, source, comparisonRef, JsMemberName.enumMember(symbol!"less"));
		JsExpr then = genCallCompareProperty(
			ctx, source, auto_.members[memberIndex], p0, p1, JsMemberName.unionMember(member.name));
		JsExpr else_ = memberIndex == 0
			? less
			: genTernary(
				ctx.alloc,
				source,
				combineWithOr!UnionMember(ctx.alloc, source, members[0 .. memberIndex], (ref UnionMember x) =>
					genIn(ctx.alloc, source, JsMemberName.unionMember(x.name), p1)),
				greater, less);
		return genReturn(
			ctx.alloc,
			source,
			genTernary(
				ctx.alloc, source,
				genIn(ctx.alloc, source, JsMemberName.unionMember(member.name), p1),
				then, else_));
	});
JsExpr combineWithOr(T)(
	ref Alloc alloc,
	in Source source,
	in T[] xs,
	in JsExpr delegate(ref T) @safe @nogc pure nothrow cb,
) =>
	mapReduce!(JsExpr, T)(xs, cb, (JsExpr x, JsExpr y) => genOr(alloc, source, x, y));

JsExprOrBlockStatement translateCompareEnumOrFlags(
	ref TranslateExprCtx ctx,
	in Source source,
	StructDecl* comparison,
	JsExpr p0,
	JsExpr p1,
) {
	// p0.value < p1.value ? less : p1.value < p0.value ? greater : equal
	JsExpr v0 = getEnumValue(ctx.alloc, source, p0);
	JsExpr v1 = getEnumValue(ctx.alloc, source, p1);
	return exprFunBody(ctx.alloc, genTernary(
		ctx.alloc,
		source,
		genLess(ctx.alloc, source, v0, v1),
		genCompareLess(ctx.ctx, source, comparison),
		genTernary(
			ctx.alloc,
			source,
			genLess(ctx.alloc, source, v1, v0),
			genCompareGreater(ctx.ctx, source, comparison),
			genCompareEqual(ctx.ctx, source, comparison))));
}

JsExprOrBlockStatement translateEqualEnumOrFlags(
	ref TranslateExprCtx ctx,
	in Source source,
	in StructDecl decl,
	JsExpr p0,
	JsExpr p1,
) {
	if (decl.body_.isA!(StructBody.Flags))
		return exprFunBody(ctx.alloc, genEqEqEq(
			ctx.alloc, source,
			getEnumValue(ctx.alloc, source, p0),
			getEnumValue(ctx.alloc, source, p1)));
	else {
		assert(decl.body_.isA!(StructBody.Enum*));
		return exprFunBody(ctx.alloc, genEqEqEq(ctx.alloc, source, p0, p1));
	}
}

JsExpr getEnumValue(ref Alloc alloc, in Source source, JsExpr arg) =>
	genPropertyAccess(alloc, source, arg, JsMemberName.special(symbol!"value"));
JsExpr getEnumName(ref Alloc alloc, in Source source, JsExpr arg) =>
	genPropertyAccess(alloc, source, arg, JsMemberName.special(symbol!"name"));

JsExprOrBlockStatement translateEqualRecord(
	ref TranslateExprCtx ctx,
	in Source source,
	in AutoFun auto_,
	in RecordField[] fields,
	JsExpr p0,
	JsExpr p1,
) =>
	exprFunBody(ctx.alloc, isEmpty(fields)
		? genBool(source, true)
		: foldRange!JsExpr(
			fields.length,
			(size_t i) =>
				genCallCompareProperty(ctx, source, auto_.members[i], p0, p1, JsMemberName.recordField(fields[i].name)),
			(JsExpr x, JsExpr y) => genAnd(ctx.alloc, source, x, y)));
JsExprOrBlockStatement translateEqualUnion(
	ref TranslateExprCtx ctx,
	in Source source,
	in AutoFun auto_,
	in UnionMember[] members,
	JsExpr p0,
	JsExpr p1,
) =>
	matchUnionMembers(ctx, source, members, p0, (size_t memberIndex, ref UnionMember member) =>
		genReturn(ctx.alloc, source, genAnd(
			ctx.alloc,
			source,
			genIn(ctx.alloc, source, JsMemberName.unionMember(member.name), p1),
			genCallCompareProperty(
				ctx, source, auto_.members[memberIndex], p0, p1, JsMemberName.unionMember(member.name)))));
JsExpr genCallCompareProperty(
	ref TranslateExprCtx ctx,
	in Source source,
	Called called,
	JsExpr p0,
	JsExpr p1,
	JsMemberName name,
) =>
	makeCall(ctx, source, called, [
		genPropertyAccess(ctx.alloc, source, p0, name),
		genPropertyAccess(ctx.alloc, source, p1, name)]);

JsExprOrBlockStatement matchUnionMembers(
	ref TranslateExprCtx ctx,
	in Source source,
	in UnionMember[] members,
	JsExpr p0,
	in JsStatement delegate(size_t, ref UnionMember) @safe @nogc pure nothrow cbCase,
) =>
	JsExprOrBlockStatement(genBlockStatement(ctx.alloc, [
		foldReverseWithIndex!(JsStatement, UnionMember)(
			genThrowJsError(ctx.alloc, source, "Invalid union value"),
			members,
			(JsStatement else_, size_t index, ref UnionMember member) =>
				genIf(
					ctx.alloc,
					source,
					genIn(ctx.alloc, source, JsMemberName.unionMember(member.name), p0),
					cbCase(index, member), else_))]));

JsExprOrBlockStatement translateEnumToJson(ref TranslateExprCtx ctx, in Source source, JsExpr p0) =>
	exprFunBody(ctx.alloc, genJsonOfString(ctx.ctx, source, getEnumName(ctx.alloc, source, p0)));

JsExprOrBlockStatement translateRecordToJson(
	ref TranslateExprCtx ctx,
	in Source source,
	in AutoFun auto_,
	in RecordField[] fields,
	JsExpr p0,
) =>
	exprFunBody(ctx.alloc, genNewJson(
		ctx.ctx,
		source,
		mapWithIndex!(JsExpr, RecordField)(ctx.alloc, fields, (size_t i, ref RecordField field) =>
			genNewPair(
				ctx.ctx,
				source,
				genStringFromSymbol(source, field.name),
				makeCall(ctx, source, auto_.members[i], [
					genPropertyAccess(ctx.alloc, source, p0, JsMemberName.recordField(field.name))])))));
JsExprOrBlockStatement translateUnionToJson(
	ref TranslateExprCtx ctx,
	in Source source,
	in AutoFun auto_,
	in UnionMember[] members,
	JsExpr p0,
) =>
	matchUnionMembers(ctx, source, members, p0, (size_t memberIndex, ref UnionMember member) =>
		// return new_json(new_pair("foo", toJson(a.foo)))
		genReturn(ctx.alloc, source,
			genNewJson(ctx.ctx, source, newArray(ctx.alloc, [
				genNewPair(
					ctx.ctx,
					source,
					genStringFromSymbol(source, member.name),
					makeCall(ctx, source, auto_.members[memberIndex], [
						genPropertyAccess(ctx.alloc, source, p0, JsMemberName.unionMember(member.name))]))]))));
JsExpr genNewPair(ref TranslateModuleCtx ctx, in Source source, JsExpr a, JsExpr b) =>
	genNew(ctx.alloc, source, translateStructReference(ctx, source, ctx.commonTypes.pair), [a, b]);
JsExpr genNewJson(ref TranslateModuleCtx ctx, in Source source, JsExpr[] pairs) =>
	genCallAwait(
		ctx.alloc,
		source,
		allocate(
			ctx.alloc,
			translateFunReference(ctx, source, ctx.program.commonFuns.newJsonFromPairs.decl)),
		pairs);
JsExpr genJsonOfArray(ref TranslateModuleCtx ctx, in Source source, JsExpr array) =>
	genCallPropertySync(
		ctx.alloc, source,
		translateStructReference(ctx, source, jsonType(ctx)),
		JsMemberName.unionConstructor(symbol!"array"),
		[array]);
JsExpr genJsonOfString(ref TranslateModuleCtx ctx, in Source source, JsExpr string_) =>
	genCallPropertySync(
		ctx.alloc, source,
		translateStructReference(ctx, source, jsonType(ctx)),
		JsMemberName.unionConstructor(symbol!"string"),
		[string_]);
StructDecl* jsonType(in TranslateModuleCtx ctx) =>
	ctx.program.commonFuns.newJsonFromPairs.returnType.as!(StructInst*).decl;
