module model.jsonOfConstant;

@safe @nogc pure nothrow:

import model.concreteModel : name;
import model.constant :
	Constant,
	ConstantArray,
	ConstantCString,
	ConstantFloat,
	ConstantFunPointer,
	ConstantPointer,
	ConstantRecord,
	ConstantUnion,
	ConstantZero;
import util.alloc.alloc : Alloc;
import util.integralValues : IntegralValue;
import util.json : field, jsonObject, optionalField, Json, jsonList, jsonString, kindField;
import util.symbol : Symbol;

Json jsonOfConstant(ref Alloc alloc, in Constant a) =>
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
