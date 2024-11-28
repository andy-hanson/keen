module model.jsonOfConcreteModel;

@safe @nogc pure nothrow:

import model.concreteModel :
	BuiltinConcreteExpr,
	CallConcreteExpr,
	CastConcreteExpr,
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteField,
	ConcreteFun,
	ConcreteFunBody,
	ConcreteFunKey,
	ConcreteFunSource,
	ConcreteGeneratedLocalKind,
	ConcreteLocal,
	ConcreteLocalSource,
	ConcreteMatchStringLikeCase,
	ConcreteMatchUnionCase,
	ConcreteProgram,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteStructSource,
	ConcreteType,
	ConcreteVar,
	Constant,
	ConstantArray,
	ConstantCString,
	ConstantFloat,
	ConstantFunPointer,
	ConstantPointer,
	ConstantRecord,
	ConstantUnion,
	ConstantZero,
	CreateArrayConcreteExpr,
	CreateRecordConcreteExpr,
	CreateUnionConcreteExpr,
	DropConcreteExpr,
	FinallyConcreteExpr,
	IfConcreteExpr,
	LetConcreteExpr,
	LocalGetConcreteExpr,
	LocalPointerConcreteExpr,
	LocalSetConcreteExpr,
	LoopConcreteExpr,
	LoopBreakConcreteExpr,
	LoopContinueConcreteExpr,
	MatchEnumOrIntegralConcreteExpr,
	MatchUnionConcreteExpr,
	MatchStringLikeConcreteExpr,
	name,
	RecordFieldGetConcreteExpr,
	RecordFieldPointerConcreteExpr,
	RecordFieldSetConcreteExpr,
	returnType,
	SeqConcreteExpr,
	ThrowConcreteExpr,
	TryConcreteExpr,
	TryLetConcreteExpr,
	UnionAsConcreteExpr,
	UnionKindConcreteExpr;
import model.jsonOfModel : jsonOfBuiltin;
import model.model : Local;
import util.alloc.alloc : Alloc;
import util.integralValues : IntegralValue, IntegralValues;
import util.json :
	field, Json, jsonObject, optionalArrayField, optionalField, optionalFlagField, jsonList, jsonString, kindField;
import util.sourceRange : jsonOfLineAndColumnRange, LineAndColumnGetters;
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
		(in ConcreteGeneratedLocalKind x) =>
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
		(in BuiltinConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"builtin",
				field!"fun"(jsonOfBuiltin(alloc, x.fun)),
				field!"args"(jsonList!ConcreteExpr(alloc, x.args, (in ConcreteExpr arg) =>
					jsonOfConcreteExpr(alloc, ctx, arg)))]),
		(in CallConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"call",
				field!"called"(jsonOfConcreteFunRef(alloc, *x.called)),
				field!"args"(jsonOfConcreteExprs(alloc, ctx, x.args))]),
		(in CastConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"cast",
				field!"inner"(jsonOfConcreteExpr(alloc, ctx, *x.inner))]),
		(in Constant x) =>
			jsonObject(alloc, [
				kindField!"constant",
				field!"value"(jsonOfConstant(alloc, x))]),
		(in CreateArrayConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"create-array",
				field!"args"(jsonOfConcreteExprs(alloc, ctx, x.args))]),
		(in CreateRecordConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"create-record",
				field!"args"(jsonOfConcreteExprs(alloc, ctx, x.args))]),
		(in CreateUnionConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"create-union",
				field!"member-index"(x.memberIndex),
				field!"arg"(jsonOfConcreteExpr(alloc, ctx, x.arg))]),
		(in DropConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"drop",
				field!"arg"(jsonOfConcreteExpr(alloc, ctx, x.arg))]),
		(in FinallyConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"finally",
				field!"right"(jsonOfConcreteExpr(alloc, ctx, x.right)),
				field!"below"(jsonOfConcreteExpr(alloc, ctx, x.below))]),
		(in IfConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"if",
				field!"condition"(jsonOfConcreteExpr(alloc, ctx, x.cond)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then)),
				field!"else"(jsonOfConcreteExpr(alloc, ctx, x.else_))]),
		(in LetConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"let",
				field!"local"(jsonOfConcreteLocalDeclare(alloc, *x.local)),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then))]),
		(in LocalGetConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"local-get",
				field!"local"(jsonOfConcreteLocalRef(*x.local))]),
		(in LocalPointerConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"local-pointer",
				field!"local"(jsonOfConcreteLocalRef(*x.local))]),
		(in LocalSetConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"local-set",
				field!"local"(jsonOfConcreteLocalRef(*x.local)),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value))]),
		(in LoopConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"loop",
				field!"body"(jsonOfConcreteExpr(alloc, ctx, x.body_))]),
		(in LoopBreakConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"break",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value))]),
		(in LoopContinueConcreteExpr x) =>
			jsonObject(alloc, [kindField!"continue"]),
		(in MatchEnumOrIntegralConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"match-integral",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.matched)),
				field!"case-values"(jsonOfIntegralValues(alloc, x.caseValues)),
				field!"case-exprs"(jsonOfConcreteExprs(alloc, ctx, x.caseExprs)),
				optionalField!("else", immutable ConcreteExpr*)(x.else_, (in immutable ConcreteExpr* else_) =>
					jsonOfConcreteExpr(alloc, ctx, *else_))]),
		(in MatchStringLikeConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"match-string-like",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.matched)),
				field!"cases"(jsonList!ConcreteMatchStringLikeCase(
					alloc,
					x.cases,
					(in ConcreteMatchStringLikeCase case_) =>
						jsonObject(alloc, [
							field!"value"(jsonOfConcreteExpr(alloc, ctx, case_.value)),
						field!"then"(jsonOfConcreteExpr(alloc, ctx, case_.then))]))),
				field!"else"(jsonOfConcreteExpr(alloc, ctx, x.else_))]),
		(in MatchUnionConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"match-union",
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.matched)),
				field!"member-indices"(jsonOfIntegralValues(alloc, x.memberIndices)),
				field!"cases"(jsonOfMatchUnionCases(alloc, ctx, x.cases))]),
		(in RecordFieldGetConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"field-get",
				field!"record"(jsonOfConcreteExpr(alloc, ctx, *x.record)),
				field!"field-index"(x.fieldIndex)]),
		(in RecordFieldPointerConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"field-pointer",
				field!"record"(jsonOfConcreteExpr(alloc, ctx, *x.record)),
				field!"field-index"(x.fieldIndex)]),
		(in RecordFieldSetConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"field-set",
				field!"record"(jsonOfConcreteExpr(alloc, ctx, x.record)),
				field!"field-index"(x.fieldIndex),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value))]),
		(in SeqConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"seq",
				field!"first"(jsonOfConcreteExpr(alloc, ctx, x.first)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then))]),
		(in ThrowConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"throw",
				field!"thrown"(jsonOfConcreteExpr(alloc, ctx, x.thrown))]),
		(in TryConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"try",
				field!"tried"(jsonOfConcreteExpr(alloc, ctx, x.tried)),
				field!"member-indices"(jsonOfIntegralValues(alloc, x.exceptionMemberIndices)),
				field!"catch-cases"(jsonOfMatchUnionCases(alloc, ctx, x.catchCases))]),
		(in TryLetConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"try-let",
				optionalField!("local", ConcreteLocal*)(x.local, (in ConcreteLocal* local) =>
					jsonOfConcreteLocalDeclare(alloc, *local)),
				field!"value"(jsonOfConcreteExpr(alloc, ctx, x.value)),
				field!"exception-member-index"(x.exceptionMemberIndex.asUnsigned),
				field!"catch"(jsonOfMatchUnionCase(alloc, ctx, x.catch_)),
				field!"then"(jsonOfConcreteExpr(alloc, ctx, x.then))]),
		(in UnionAsConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"union-as",
				field!"union"(jsonOfConcreteExpr(alloc, ctx, *x.union_)),
				field!"member-index"(x.memberIndex)]),
		(in UnionKindConcreteExpr x) =>
			jsonObject(alloc, [
				kindField!"union-kind",
				field!"union"(jsonOfConcreteExpr(alloc, ctx, *x.union_))]));

Json jsonOfMatchUnionCases(ref Alloc alloc, in Ctx ctx, in ConcreteMatchUnionCase[] cases) =>
	jsonList!ConcreteMatchUnionCase(alloc, cases, (in ConcreteMatchUnionCase x) =>
		jsonOfMatchUnionCase(alloc, ctx, x));

Json jsonOfMatchUnionCase(ref Alloc alloc, in Ctx ctx, in ConcreteMatchUnionCase a) =>
	jsonObject(alloc, [
		optionalField!("local", ConcreteLocal*)(a.local, (in ConcreteLocal* local) =>
			jsonOfConcreteLocalDeclare(alloc, *local)),
		field!"then"(jsonOfConcreteExpr(alloc, ctx, a.then))]);

public Json jsonOfIntegralValues(ref Alloc alloc, in IntegralValues a) =>
	a.isRange0ToN
		? Json(a.length)
		: jsonList!IntegralValue(alloc, a, (in IntegralValue x) =>
			Json(x.value));

public Json jsonOfConstant(ref Alloc alloc, in Constant a) =>
	a.matchIn!Json(
		(in ConstantArray x) =>
			jsonObject(alloc, [
				kindField!"array",
				field!"type-index"(x.typeIndex),
				field!"index"(x.index)]),
		(in ConstantCString x) =>
			jsonObject(alloc, [
				kindField!"c-string",
				field!"index"(x.index)]),
		(in ConstantFloat x) =>
			jsonObject(alloc, [
				kindField!"float",
				field!"value"(x.value)]),
		(in ConstantFunPointer x) =>
			jsonObject(alloc, [
				kindField!"fun-pointer",
				optionalField!("fun-name", Symbol)(name(*x.fun), (in Symbol name) => jsonString(name))]),
		(in IntegralValue x) =>
			jsonObject(alloc, [
				kindField!"integral",
				field!"value"(x.value)]),
		(in ConstantPointer x) =>
			jsonObject(alloc, [
				kindField!"pointer",
				field!"type-index"(x.typeIndex),
				field!"index"(x.index)]),
		(in ConstantRecord x) =>
			jsonObject(alloc, [
				kindField!"record",
				field!"args"(jsonList!Constant(alloc, x.args, (in Constant arg) =>
					jsonOfConstant(alloc, arg)))]),
		(in ConstantUnion x) =>
			jsonObject(alloc, [
				kindField!"union",
				field!"member-index"(x.memberIndex),
				field!"value"(jsonOfConstant(alloc, x.arg))]),
		(in ConstantZero _) =>
			jsonObject(alloc, [kindField!"zero"]));
