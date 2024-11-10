module model.jsonOfConcreteModel;

@safe @nogc pure nothrow:

import frontend.storage : LineAndColumnGetters;
import model.concreteModel :
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteFunKey,
	ConcreteFunSource,
	ConcreteLocal,
	ConcreteLocalSource,
	ConcreteProgram,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructSource,
	ConcreteType,
	ConcreteVar,
	returnType;
import model.constant : Constant;
import model.jsonOfConstant : jsonOfConstant;
import model.jsonOfModel : jsonOfBuiltin;
import model.model : Local;
import util.alloc.alloc : Alloc;
import util.integralValues : IntegralValue, IntegralValues;
import util.json :
	field, Json, jsonObject, optionalArrayField, optionalField, optionalFlagField, jsonList, jsonString, kindField;
import util.sourceRange : jsonOfLineAndColumnRange;
import util.symbol : Symbol, symbol, symbolOfEnum;
import util.util : stringOfEnum;

Json jsonOfConcreteProgram(ref Alloc alloc, in LineAndColumnGetters lcg, in ConcreteProgram a) {
	Ctx ctx = Ctx(lcg);
	return jsonObject(alloc, [
		field!"structs"(jsonList!(ConcreteStruct*)(alloc, a.allStructs, (in ConcreteStruct* x) =>
			jsonOfConcreteStruct(alloc, *x))),
		field!"vars"(jsonList!(ConcreteVar*)(alloc, a.allVars, (in ConcreteVar* x) =>
			jsonOfConcreteVar(alloc, *x))),
		field!"funs"(jsonList!(ConcreteFun*)(alloc, a.allFuns, (in ConcreteFun* x) =>
			jsonOfConcreteFun(alloc, ctx, *x)))]);
}

private:

const struct Ctx {
	LineAndColumnGetters lineAndColumnGetters;
}

Json jsonOfConcreteStruct(ref Alloc alloc, in ConcreteStruct a) =>
	jsonObject(alloc, [
		field!"name"(jsonOfConcreteStructSource(alloc, a.source)),
		optionalFlagField!"mut"(a.isSelfMutable),
		field!"reference-kind"(stringOfEnum(a.defaultReferenceKind)),
		field!"body"(jsonOfConcreteStructBody(alloc, a.body_))]);

Json jsonOfConcreteStructSource(ref Alloc alloc, in ConcreteStructSource a) =>
	a.matchIn!Json(
		(in ConcreteStructSource.Bogus) =>
			jsonString!"BOGUS",
		(in ConcreteStructSource.Inst x) =>
			jsonString(x.decl.name),
		(in ConcreteStructSource.Lambda x) =>
			jsonObject(alloc, [
				kindField!"lambda",
				field!"containing"(jsonOfConcreteFunRef(alloc, *x.containingFun)),
				field!"index"(x.index)]));

public Json jsonOfConcreteStructRef(ref Alloc alloc, in ConcreteStruct a) =>
	jsonOfConcreteStructSource(alloc, a.source);

Json jsonOfConcreteStructBody(ref Alloc alloc, in ConcreteStructBody a) =>
	a.matchIn!Json(
		(in ConcreteStructBody.Builtin x) =>
			jsonOfConcreteStructBodyBuiltin(alloc, x),
		(in ConcreteStructBody.Enum x) =>
			//TODO:MORE DETAIL
			jsonString!"enum",
		(in ConcreteStructBody.Extern) =>
			jsonString!"extern",
		(in ConcreteStructBody.Flags x) =>
			//TODO:MORE DETAIL
			jsonString!"flags" ,
		(in ConcreteStructBody.Record x) =>
			jsonOfConcreteStructBodyRecord(alloc, x),
		(in ConcreteStructBody.Union x) =>
			jsonOfConcreteStructBodyUnion(alloc, x));

Json jsonOfConcreteStructBodyBuiltin(ref Alloc alloc, in ConcreteStructBody.Builtin a) =>
	jsonObject(alloc, [
		kindField!"builtin",
		field!"name"(stringOfEnum(a.kind)),
		optionalArrayField!("type-args", ConcreteType)(alloc, a.typeArgs, (in ConcreteType x) =>
			jsonOfConcreteType(alloc, x))]);

Json jsonOfConcreteType(ref Alloc alloc, in ConcreteType a) =>
	jsonObject(alloc, [
		field!"reference-kind"(stringOfEnum(a.reference)),
		field!"struct"(jsonOfConcreteStructRef(alloc, *a.struct_))]);

Json jsonOfConcreteStructBodyRecord(ref Alloc alloc, in ConcreteStructBody.Record a) =>
	jsonObject(alloc, [
		kindField!"record",
		field!"fields"(jsonList!ConcreteField(alloc, a.fields, (in ConcreteField x) =>
			jsonOfConcreteField(alloc, x)))]);

Json jsonOfConcreteField(ref Alloc alloc, in ConcreteField a) =>
	jsonObject(alloc, [
		field!"name"(a.debugName),
		field!"mutability"(stringOfEnum(a.mutability)),
		field!"type"(jsonOfConcreteType(alloc, a.type))]);

Json jsonOfConcreteStructBodyUnion(ref Alloc alloc, in ConcreteStructBody.Union a) =>
	jsonObject(alloc, [
		kindField!"union",
		field!"members"(jsonList!ConcreteType(alloc, a.members, (in ConcreteType x) =>
			jsonOfConcreteType(alloc, x)))]);

Json jsonOfConcreteVar(ref Alloc alloc, in ConcreteVar a) =>
	jsonObject(alloc, [
		field!"source"(a.source.name),
		field!"type"(jsonOfConcreteType(alloc, a.type))]);

Json jsonOfConcreteFun(ref Alloc alloc, in Ctx ctx, in ConcreteFun a) =>
	jsonObject(alloc, [
		field!"source"(jsonOfConcreteFunSource(alloc, a.source)),
		field!"return-type"(jsonOfConcreteType(alloc, a.returnType)),
		field!"params"(jsonList!ConcreteLocal(alloc, a.params, (in ConcreteLocal x) =>
			jsonOfConcreteLocalDeclare(alloc, x))),
		field!"body"(jsonOfConcreteFunBody(alloc, ctx, a.body_))]);

Json jsonOfConcreteFunSource(ref Alloc alloc, in ConcreteFunSource a) =>
	a.matchIn!Json(
		(in ConcreteFunKey x) =>
			jsonString(x.decl.name),
		(in ConcreteFunSource.Lambda x) =>
			jsonObject(alloc, [
				kindField!"lambda",
				field!"containing"(jsonOfConcreteFunRef(alloc, *x.containingFun)),
				field!"index"(x.index)]),
		(in ConcreteFunSource.Test) =>
			jsonString!"test",
		(in ConcreteFunSource.WrapMain) =>
			jsonString!"wrap-main");

public Json jsonOfConcreteFunRef(ref Alloc alloc, in ConcreteFun a) =>
	jsonOfConcreteFunSource(alloc, a.source);

Json jsonOfConcreteFunBody(ref Alloc alloc, in Ctx ctx, in ConcreteFunBody a) =>
	a.matchIn!Json(
		(in ConcreteFunBody.Builtin x) =>
			jsonOfConcreteFunBodyBuiltin(alloc, x),
		(in ConcreteFunBody.Extern) =>
			jsonString!"extern",
		(in ConcreteExpr x) =>
			jsonOfConcreteExpr(alloc, ctx, x),
		(in ConcreteFunBody.VarGet) =>
			jsonString!"var-get",
		(in ConcreteFunBody.VarSet) =>
			jsonString!"var-set",
		(in ConcreteFunBody.Deferred) =>
			assert(false));

Json jsonOfConcreteFunBodyBuiltin(ref Alloc alloc, in ConcreteFunBody.Builtin a) =>
	jsonObject(alloc, [
		kindField!"builtin",
		optionalArrayField!("type-args", ConcreteType)(alloc, a.typeArgs, (in ConcreteType x) =>
			jsonOfConcreteType(alloc, x))]);

Json jsonOfConcreteLocalDeclare(ref Alloc alloc, in ConcreteLocal a) =>
	jsonObject(alloc, [
		field!"name"(name(a.source)),
		field!"type"(jsonOfConcreteType(alloc, a.type))]);

Json jsonOfConcreteLocalRef(in ConcreteLocal a) =>
	jsonString(name(a.source));

Symbol name(in ConcreteLocalSource a) =>
	a.matchIn!Symbol(
		(in Local x) =>
			x.name,
		(in ConcreteLocalSource.Closure) =>
			symbol!"closure",
		(in ConcreteLocalSource.Generated x) =>
			symbolOfEnum(x));

Json jsonOfConcreteExpr(ref Alloc alloc, in Ctx ctx, in ConcreteExpr a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndColumnRange(alloc, ctx.lineAndColumnGetters[a.range].range)),
		field!"type"(jsonOfConcreteType(alloc, a.type)),
		field!"expr-kind"(jsonOfConcreteExprKind(alloc, ctx, a.kind))]);

Json jsonOfConcreteExprs(ref Alloc alloc, in Ctx ctx, in ConcreteExpr[] a) =>
	jsonList!ConcreteExpr(alloc, a, (in ConcreteExpr x) =>
		jsonOfConcreteExpr(alloc, ctx, x));

Json jsonOfConcreteExprKind(ref Alloc alloc, in Ctx ctx, in ConcreteExprKind a) =>
	a.matchIn!Json(
		(in ConcreteExprKind.Builtin x) =>
			jsonObject(alloc, [
				kindField!"builtin",
				field!"fun"(jsonOfBuiltin(alloc, x.fun)),
				field!"args"(jsonList!ConcreteExpr(alloc, x.args, (in ConcreteExpr arg) =>
					jsonOfConcreteExpr(alloc, ctx, arg)))]),
		(in ConcreteExprKind.Call x) =>
			jsonObject(alloc, [
				kindField!"call",
				field!"called"(jsonOfConcreteFunRef(alloc, *x.called)),
				field!"args"(jsonOfConcreteExprs(alloc, ctx, x.args))]),
		(in ConcreteExprKind.Cast x) =>
			jsonObject(alloc, [
				kindField!"cast",
				field!"inner"(jsonOfConcreteExpr(alloc, ctx, *x.inner))]),
		(in Constant x) =>
			jsonObject(alloc, [
				kindField!"constant",
				field!"value"(jsonOfConstant(alloc, x))]),
		(in ConcreteExprKind.CreateArray x) =>
			jsonObject(alloc, [
				kindField!"create-array",
				field!"args"(jsonOfConcreteExprs(alloc, ctx, x.args))]),
		(in ConcreteExprKind.CreateRecord x) =>
			jsonObject(alloc, [
				kindField!"create-record",
				field!"args"(jsonOfConcreteExprs(alloc, ctx, x.args))]),
		(in ConcreteExprKind.CreateUnion x) =>
			jsonObject(alloc, [
				kindField!"create-union",
				field!"member-index"(x.memberIndex),
				field!"arg"(jsonOfConcreteExpr(alloc, ctx, x.arg))]),
		(in ConcreteExprKind.Drop x) =>
			jsonObject(alloc, [
				kindField!"drop",
				field!"arg"(jsonOfConcreteExpr(alloc, ctx, x.arg))]),
		(in ConcreteExprKind.Finally x) =>
			jsonObject(alloc, [
				kindField!"finally",
				field!"right"(jsonOfConcreteExpr(alloc, ctx, x.right)),
				field!"below"(jsonOfConcreteExpr(alloc, ctx, x.below))]),
		(in ConcreteExprKind.If x) =>
			jsonObject(alloc, [
				kindField!"if",
				field!"condition"(jsonOfConcreteExpr(alloc, ctx, x.cond)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then)),
				field!"else"(jsonOfConcreteExpr(alloc, ctx, x.else_))]),
		(in ConcreteExprKind.Let x) =>
			jsonObject(alloc, [
				kindField!"let",
				field!"local"(jsonOfConcreteLocalDeclare(alloc, *x.local)),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then))]),
		(in ConcreteExprKind.LocalGet x) =>
			jsonObject(alloc, [
				kindField!"local-get",
				field!"local"(jsonOfConcreteLocalRef(*x.local))]),
		(in ConcreteExprKind.LocalPointer x) =>
			jsonObject(alloc, [
				kindField!"local-pointer",
				field!"local"(jsonOfConcreteLocalRef(*x.local))]),
		(in ConcreteExprKind.LocalSet x) =>
			jsonObject(alloc, [
				kindField!"local-set",
				field!"local"(jsonOfConcreteLocalRef(*x.local)),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value))]),
		(in ConcreteExprKind.Loop x) =>
			jsonObject(alloc, [
				kindField!"loop",
				field!"body"(jsonOfConcreteExpr(alloc, ctx, x.body_))]),
		(in ConcreteExprKind.LoopBreak x) =>
			jsonObject(alloc, [
				kindField!"break",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value))]),
		(in ConcreteExprKind.LoopContinue x) =>
			jsonObject(alloc, [kindField!"continue"]),
		(in ConcreteExprKind.MatchEnumOrIntegral x) =>
			jsonObject(alloc, [
				kindField!"match-integral",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.matched)),
				field!"case-values"(jsonOfIntegralValues(alloc, x.caseValues)),
				field!"case-exprs"(jsonOfConcreteExprs(alloc, ctx, x.caseExprs)),
				optionalField!("else", immutable ConcreteExpr*)(x.else_, (in immutable ConcreteExpr* else_) =>
					jsonOfConcreteExpr(alloc, ctx, *else_))]),
		(in ConcreteExprKind.MatchStringLike x) =>
			jsonObject(alloc, [
				kindField!"match-string-like",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.matched)),
				field!"cases"(jsonList!(ConcreteExprKind.MatchStringLike.Case)(
					alloc,
					x.cases,
					(in ConcreteExprKind.MatchStringLike.Case case_) =>
						jsonObject(alloc, [
							field!"value"(jsonOfConcreteExpr(alloc, ctx, case_.value)),
						field!"then"(jsonOfConcreteExpr(alloc, ctx, case_.then))]))),
				field!"else"(jsonOfConcreteExpr(alloc, ctx, x.else_))]),
		(in ConcreteExprKind.MatchUnion x) =>
			jsonObject(alloc, [
				kindField!"match-union",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.matched)),
				field!"member-indices"(jsonOfIntegralValues(alloc, x.memberIndices)),
				field!"cases"(jsonOfMatchUnionCases(alloc, ctx, x.cases))]),
		(in ConcreteExprKind.RecordFieldGet x) =>
			jsonObject(alloc, [
				kindField!"field-get",
				field!"record"(jsonOfConcreteExpr(alloc, ctx, *x.record)),
				field!"field-index"(x.fieldIndex)]),
		(in ConcreteExprKind.RecordFieldPointer x) =>
			jsonObject(alloc, [
				kindField!"field-pointer",
				field!"record"(jsonOfConcreteExpr(alloc, ctx, *x.record)),
				field!"field-index"(x.fieldIndex)]),
		(in ConcreteExprKind.RecordFieldSet x) =>
			jsonObject(alloc, [
				kindField!"field-set",
				field!"record"(jsonOfConcreteExpr(alloc, ctx, x.record)),
				field!"field-index"(x.fieldIndex),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value))]),
		(in ConcreteExprKind.Seq x) =>
			jsonObject(alloc, [
				kindField!"seq",
				field!"first"(jsonOfConcreteExpr(alloc, ctx, x.first)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then))]),
		(in ConcreteExprKind.Throw x) =>
			jsonObject(alloc, [
				kindField!"throw",
				field!"thrown"(jsonOfConcreteExpr(alloc, ctx, x.thrown))]),
		(in ConcreteExprKind.Try x) =>
			jsonObject(alloc, [
				kindField!"try",
				field!"tried"(jsonOfConcreteExpr(alloc, ctx, x.tried)),
				field!"member-indices"(jsonOfIntegralValues(alloc, x.exceptionMemberIndices)),
				field!"catch-cases"(jsonOfMatchUnionCases(alloc, ctx, x.catchCases))]),
		(in ConcreteExprKind.TryLet x) =>
			jsonObject(alloc, [
				kindField!"try-let",
				optionalField!("local", ConcreteLocal*)(x.local, (in ConcreteLocal* local) =>
					jsonOfConcreteLocalDeclare(alloc, *local)),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value)),
				field!"exception-member-index"(x.exceptionMemberIndex.asUnsigned),
				field!"catch"(jsonOfMatchUnionCase(alloc, ctx, x.catch_)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then))]),
		(in ConcreteExprKind.UnionAs x) =>
			jsonObject(alloc, [
				kindField!"union-as",
				field!"union"(jsonOfConcreteExpr(alloc, ctx, *x.union_)),
				field!"member-index"(x.memberIndex)]),
		(in ConcreteExprKind.UnionKind x) =>
			jsonObject(alloc, [
				kindField!"union-kind",
				field!"union"(jsonOfConcreteExpr(alloc, ctx, *x.union_))]));

Json jsonOfMatchUnionCases(ref Alloc alloc, in Ctx ctx, in ConcreteExprKind.MatchUnion.Case[] cases) =>
	jsonList!(ConcreteExprKind.MatchUnion.Case)(alloc, cases, (in ConcreteExprKind.MatchUnion.Case x) =>
		jsonOfMatchUnionCase(alloc, ctx, x));

Json jsonOfMatchUnionCase(ref Alloc alloc, in Ctx ctx, in ConcreteExprKind.MatchUnion.Case a) =>
	jsonObject(alloc, [
		optionalField!("local", ConcreteLocal*)(a.local, (in ConcreteLocal* local) =>
			jsonOfConcreteLocalDeclare(alloc, *local)),
		field!"then"(jsonOfConcreteExpr(alloc, ctx, a.then))]);

public Json jsonOfIntegralValues(ref Alloc alloc, in IntegralValues a) =>
	a.isRange0ToN
		? Json(a.length)
		: jsonList!IntegralValue(alloc, a, (in IntegralValue x) =>
			Json(x.value));
