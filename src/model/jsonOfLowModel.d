module model.jsonOfLowModel;

@safe @nogc pure nothrow:

import model.concreteModel : ConcreteFun;
import model.constant : Constant;
import model.jsonOfConstant : jsonOfConstant;
import model.lowModel :
	AbortLowExpr,
	CallLowExpr,
	CallFunPointerLowExpr,
	CreateRecordLowExpr,
	CreateUnionLowExpr,
	debugName,
	FunPointerLowExpr,
	IfLowExpr,
	InitLowExpr,
	LetLowExpr,
	LocalGetLowExpr,
	LocalPointerLowExpr,
	LocalSetLowExpr,
	LoopBreakLowExpr,
	LoopContinueLowExpr,
	LoopLowExpr,
	LowExpr,
	LowExprKind,
	LowExternType,
	LowExternTypeIndex,
	LowField,
	LowFun,
	LowFunBody,
	LowFunExprBody,
	LowFunIndex,
	LowFunPointerType,
	LowFunPointerTypeIndex,
	LowFunSource,
	LowLocal,
	LowLocalSource,
	LowProgram,
	LowRecord,
	LowRecordIndex,
	LowType,
	LowUnion,
	LowUnionIndex,
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
import model.model : Local;
import model.jsonOfConcreteModel : jsonOfConcreteFunRef, jsonOfConcreteStructRef, jsonOfIntegralValues;
import util.alloc.alloc : Alloc;
import util.json : field, jsonObject, Json, jsonList, jsonString, kindField;
import util.sourceRange : jsonOfLineAndColumnRange, LineAndColumnGetters;
import util.util : castNonScope, stringOfEnum;

Json jsonOfLowProgram(ref Alloc alloc, in LineAndColumnGetters lineAndColumnGetters, in LowProgram a) {
	Ctx ctx = Ctx(lineAndColumnGetters);
	return jsonObject(alloc, [
		field!"extern"(
			jsonList!(LowExternTypeIndex, LowExternType)(alloc, a.allExternTypes, (in LowExternType x) =>
				jsonOfExternType(alloc, x))),
		field!"fun-pointers"(jsonList!(LowFunPointerTypeIndex, LowFunPointerType)(
			alloc, a.allFunPointerTypes, (in LowFunPointerType x) =>
				jsonOfLowFunPointerType(alloc, x))),
		field!"records"(jsonList!(LowRecordIndex, LowRecord)(alloc, a.allRecords, (in LowRecord x) =>
			jsonOfLowRecord(alloc, x))),
		field!"unions"(jsonList!(LowUnionIndex, LowUnion)(alloc, a.allUnions, (in LowUnion x) =>
			jsonOfLowUnion(alloc, x))),
		field!"funs"(jsonList!(LowFunIndex, LowFun)(alloc, a.allFuns, (in LowFun x) =>
			jsonOfLowFun(alloc, ctx, x))),
		field!"main"(a.main.index)]);
}

private:

const struct Ctx {
	LineAndColumnGetters lineAndColumnGetters;
}

Json jsonOfLowType(ref Alloc alloc, in LowType a) =>
	a.matchIn!Json(
		(in LowExternType x) =>
			jsonObject(alloc, [kindField!"extern", field!"source"(jsonOfConcreteStructRef(alloc, *x.source))]),
		(in LowFunPointerType x) =>
			jsonObject(alloc, [kindField!"fun-pointer", field!"source"(jsonOfConcreteStructRef(alloc, *x.source))]),
		(in PrimitiveType x) =>
			jsonString(stringOfEnum(x)),
		(in LowType.PointerGc x) =>
			jsonObject(alloc, [kindField!"pointer-gc", field!"pointee"(jsonOfLowType(alloc, *x.pointee))]),
		(in LowType.PointerConst x) =>
			jsonObject(alloc, [kindField!"pointer-const", field!"pointee"(jsonOfLowType(alloc, *x.pointee))]),
		(in LowType.PointerMut x) =>
			jsonObject(alloc, [kindField!"pointer-mut", field!"pointee"(jsonOfLowType(alloc, *x.pointee))]),
		(in LowRecord x) =>
			jsonObject(alloc, [kindField!"record", field!"source"(jsonOfConcreteStructRef(alloc, *x.source))]),
		(in LowUnion x) =>
			jsonObject(alloc, [kindField!"union", field!"source"(jsonOfConcreteStructRef(alloc, *x.source))]));

Json jsonOfExternType(ref Alloc alloc, in LowExternType a) =>
	jsonObject(alloc, [field!"source"(jsonOfConcreteStructRef(alloc, *a.source))]);

Json jsonOfLowFunPointerType(ref Alloc alloc, in LowFunPointerType a) =>
	jsonObject(alloc, [
		field!"source"(jsonOfConcreteStructRef(alloc, *a.source)),
		field!"return-type"(jsonOfLowType(alloc, a.returnType)),
		field!"param-types"(jsonList!LowType(alloc, a.paramTypes, (in LowType x) =>
			jsonOfLowType(alloc, x)))]);

Json jsonOfLowRecord(ref Alloc alloc, in LowRecord a) =>
	jsonObject(alloc, [
		field!"source"(jsonOfConcreteStructRef(alloc, *a.source)),
		field!"fields"(jsonList!LowField(alloc, a.fields, (in LowField x) =>
			jsonObject(alloc, [
				field!"name"(debugName(x)),
				field!"type"(jsonOfLowType(alloc, x.type))])))]);

Json jsonOfLowUnion(ref Alloc alloc, in LowUnion a) =>
	jsonObject(alloc, [
		field!"source"(jsonOfConcreteStructRef(alloc, *a.source)),
		field!"members"(jsonList!LowType(alloc, a.members, (in LowType x) =>
			jsonOfLowType(alloc, x)))]);

Json jsonOfLowFun(ref Alloc alloc, in Ctx ctx, in LowFun a) =>
	jsonObject(alloc, [
		field!"source"(jsonOfLowFunSource(alloc, a.source)),
		field!"return-type"(jsonOfLowType(alloc, a.returnType)),
		field!"params"(jsonList!LowLocal(alloc, a.params, (in LowLocal x) =>
			jsonOfLowLocal(alloc, x))),
		field!"body"(jsonOfLowFunBody(alloc, ctx, a.body_))]);

Json jsonOfLowFunSource(ref Alloc alloc, in LowFunSource a) =>
	a.matchIn!Json(
		(in ConcreteFun x) =>
			jsonOfConcreteFunRef(alloc, x),
		(in LowFunSource.Generated x) =>
			jsonObject(alloc, [kindField!"generated", field!"name"(x.name)]));

Json jsonOfLowFunBody(ref Alloc alloc, in Ctx ctx, in LowFunBody a) =>
	a.matchIn!Json(
		(in LowFunBody.Extern) =>
			jsonString!"extern",
		(in LowFunExprBody x) =>
			jsonOfLowExpr(alloc, ctx, x.expr));

Json jsonOfLowLocal(ref Alloc alloc, in LowLocal a) =>
	jsonObject(alloc, [
		field!"source"(jsonOfLowLocalSource(alloc, a.source)),
		field!"index"(a.index),
		field!"type"(jsonOfLowType(alloc, a.type))]);

Json jsonOfLowLocalSource(ref Alloc alloc, in LowLocalSource a) =>
	a.matchIn!Json(
		(in Local x) =>
			jsonString(x.name),
		(in LowLocalSource.Generated x) =>
			jsonObject(alloc, [kindField!"generated", field!"name"(x.name), field!"mutable"(x.isMutable)]));

Json jsonOfLowExpr(ref Alloc alloc, in Ctx ctx, in LowExpr a) =>
	jsonObject(alloc, [
		field!"type"(jsonOfLowType(alloc, a.type)),
		field!"source"(jsonOfLineAndColumnRange(alloc, ctx.lineAndColumnGetters[a.source].range)),
		field!"expr-kind"(jsonOfLowExprKind(alloc, ctx, a.kind))]);

Json jsonOfLowExprs(ref Alloc alloc, in Ctx ctx, in LowExpr[] a) =>
	jsonList!LowExpr(alloc, a, (in LowExpr x) =>
		jsonOfLowExpr(alloc, ctx, x));

Json jsonOfLowExprKind(ref Alloc alloc, in Ctx ctx, in LowExprKind a) =>
	a.matchIn!Json(
		(in AbortLowExpr x) =>
			jsonObject(alloc, [kindField!"abort"]),
		(in CallLowExpr x) =>
			jsonObject(alloc, [
				kindField!"call",
				field!"called"(x.called.index),
				field!"args"(jsonOfLowExprs(alloc, ctx, x.args))]),
		(in CallFunPointerLowExpr x) =>
			jsonObject(alloc, [
				kindField!"call-fun-pointer",
				field!"fun-pointer"(jsonOfLowExpr(alloc, ctx, *x.funPtr)),
				field!"args"(jsonOfLowExprs(alloc, ctx, x.args))]),
		(in CreateRecordLowExpr x) =>
			jsonObject(alloc, [
				kindField!"create-record",
				field!"args"(jsonOfLowExprs(alloc, ctx, x.args))]),
		(in CreateUnionLowExpr x) =>
			jsonObject(alloc, [
				kindField!"create-union",
				field!"member-index"(x.memberIndex),
				field!"arg"(jsonOfLowExpr(alloc, ctx, x.arg))]),
		(in FunPointerLowExpr x) =>
			jsonObject(alloc, [
				kindField!"fun-pointer",
				field!"fun"(x.fun.index)]),
		(in IfLowExpr x) =>
			jsonObject(alloc, [
				kindField!"if",
				field!"condition"(jsonOfLowExpr(alloc, ctx, x.cond)),
				field!"then"(jsonOfLowExpr(alloc, ctx, x.then)),
				field!"else"(jsonOfLowExpr(alloc, ctx, x.else_))]),
		(in InitLowExpr x) =>
			jsonObject(alloc, [
				kindField!"init",
				field!"which"(stringOfEnum(x.kind))]),
		(in LetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"let",
				field!"local"(jsonOfLowLocal(alloc, *x.local)),
				field!"value"(jsonOfLowExpr(alloc, ctx, x.value)),
				field!"then"(jsonOfLowExpr(alloc, ctx, x.then))]),
		(in LocalGetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"local-get",
				field!"source"(jsonOfLowLocalSource(alloc, x.local.source))]),
		(in LocalPointerLowExpr x) =>
			jsonObject(alloc, [
				kindField!"local-pointer",
				field!"local"(jsonOfLowLocalSource(alloc, x.local.source))]),
		(in LocalSetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"local-set",
				field!"source"(jsonOfLowLocalSource(alloc, x.local.source)),
				field!"value"(jsonOfLowExpr(alloc, ctx, x.value))]),
		(in LoopLowExpr x) =>
			jsonObject(alloc, [
				kindField!"loop",
				field!"body"(jsonOfLowExpr(alloc, ctx, x.body_))]),
		(in LoopBreakLowExpr x) =>
			jsonObject(alloc, [
				kindField!"break",
				field!"value"(jsonOfLowExpr(alloc, ctx, x.value))]),
		(in LoopContinueLowExpr _) =>
			jsonObject(alloc, [kindField!"continue"]),
		(in PointerCastLowExpr x) =>
			jsonObject(alloc, [
				kindField!"pointer-cast",
				field!"target"(jsonOfLowExpr(alloc, ctx, x.target))]),
		(in RecordFieldGetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"get-field",
				field!"target"(jsonOfLowExpr(alloc, ctx, *x.target)),
				field!"field-index"(x.fieldIndex)]),
		(in RecordFieldPointerLowExpr x) =>
			jsonObject(alloc, [
				kindField!"field-pointer",
				field!"target"(jsonOfLowExpr(alloc, ctx, *x.target)),
				field!"field-index"(x.fieldIndex)]),
				(in RecordFieldSetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"set-field",
				field!"target"(jsonOfLowExpr(alloc, ctx, x.target)),
				field!"field-index"(x.fieldIndex),
				field!"value"(jsonOfLowExpr(alloc, ctx, x.value))]),
		(in Constant x) =>
			jsonObject(alloc, [
				kindField!"constant",
				field!"constant"(jsonOfConstant(alloc, x))]),
		(in SpecialUnaryLowExpr x) =>
			jsonObject(alloc, [
				kindField!"unary",
				field!"operation"(stringOfEnum(x.kind)),
				field!"arg"(jsonOfLowExpr(alloc, ctx, x.arg))]),
		(in SpecialUnaryMathLowExpr x) =>
			jsonObject(alloc, [
				kindField!"unary-math",
				field!"fun"(stringOfEnum(x.kind)),
				field!"arg"(jsonOfLowExpr(alloc, ctx, x.arg))]),
		(in SpecialBinaryLowExpr x) =>
			jsonObject(alloc, [
				kindField!"binary",
				field!"operation"(stringOfEnum(x.kind)),
				field!"args"(jsonList!LowExpr(alloc, castNonScope(x.args), (in LowExpr e) =>
					jsonOfLowExpr(alloc, ctx, e)))]),
		(in SpecialBinaryMathLowExpr x) =>
			jsonObject(alloc, [
				kindField!"binary-math",
				field!"fun"(stringOfEnum(x.kind)),
				field!"args"(jsonList!LowExpr(alloc, castNonScope(x.args), (in LowExpr e) =>
					jsonOfLowExpr(alloc, ctx, e)))]),
		(in SpecialTernaryLowExpr x) =>
			jsonObject(alloc, [
				kindField!"ternary",
				field!"operation"(stringOfEnum(x.kind)),
				field!"args"(jsonList!LowExpr(alloc, castNonScope(x.args), (in LowExpr e) =>
					jsonOfLowExpr(alloc, ctx, e)))]),
		(in Special4aryLowExpr x) =>
			jsonObject(alloc, [
				kindField!"4ary",
				field!"operation"(stringOfEnum(x.kind)),
				field!"args"(jsonList!LowExpr(alloc, castNonScope(x.args), (in LowExpr e) =>
					jsonOfLowExpr(alloc, ctx, e)))]),
		(in SwitchLowExpr x) =>
			jsonObject(alloc, [
				kindField!"switch",
				field!"value"(jsonOfLowExpr(alloc, ctx, x.value)),
				field!"case-values"(jsonOfIntegralValues(alloc, x.caseValues)),
				field!"case-exprs"(jsonOfLowExprs(alloc, ctx, x.caseExprs))]),
		(in TailRecurLowExpr x) =>
			jsonObject(alloc, [
				kindField!"tail-recur",
				field!"updates"(jsonList!UpdateParam(alloc, x.updateParams, (in UpdateParam updateParam) =>
					jsonObject(alloc, [
						field!"param"(jsonOfLowLocalSource(alloc, updateParam.param.source)),
						field!"value"(jsonOfLowExpr(alloc, ctx, updateParam.newValue)),
					])))]),
		(in UnionAsLowExpr x) =>
			jsonObject(alloc, [
				kindField!"union-as",
				field!"union"(jsonOfLowExpr(alloc, ctx, *x.union_)),
				field!"member-index"(x.memberIndex)]),
		(in UnionKindLowExpr x) =>
			jsonObject(alloc, [
				kindField!"union-kind",
				field!"union"(jsonOfLowExpr(alloc, ctx, *x.union_))]),
		(in VarGetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"var-get",
				field!"var"(x.varIndex.index)]),
		(in VarSetLowExpr x) =>
			jsonObject(alloc, [
				kindField!"var-set",
				field!"var"(x.varIndex.index),
				field!"value"(jsonOfLowExpr(alloc, ctx, *x.value))]));
