module frontend.check.checkAutoFun;

@safe @nogc pure nothrow:

import frontend.check.checkCall.checkCallSpecs : checkSpecSingleSigIgnoreParents;
import frontend.check.checkCtx : addDiag, CheckCtx, CommonModule;
import frontend.check.maps : FunsMap, SpecsMap;
import frontend.check.instantiate : instantiateSpec, instantiateType;
import frontend.check.typeFromAst : getSpecFromCommonModule;
import model.model :
	arrayElementType,
	asIntegralType,
	AutoFun,
	AutoFunKind,
	AutoFunName,
	BuiltinType,
	Called,
	Destructure,
	Diag,
	DiagAutoFunBare,
	DiagAutoFunEnumOrFlagsToWrongStorage,
	DiagAutoFunParamNotSimple,
	DiagAutoFunSpecCorrupt,
	DiagAutoFunTypeNotFullyVisible,
	DiagAutoFunWrongName,
	DiagAutoFunWrongParams,
	DiagAutoFunWrongParamType,
	DiagAutoFunWrongReturnType,
	Enum,
	ExternType,
	Flags,
	FunBody,
	FunDecl,
	IntegralType,
	isArray,
	isEmpty,
	isEnum,
	isFlags,
	isOptionType,
	isSymbol,
	Local,
	mustUnwrapOptionType,
	Record,
	RecordField,
	SpecDecl,
	Signature,
	StructBody,
	StructBodyBogus,
	StructDecl,
	StructInst,
	SumType,
	SumTypeKind,
	SumTypeMemberAndMethodImpls,
	Type,
	Varargs;
import util.col.array : allSame, every, isEmpty, map, only;
import util.opt : force, has, none, Opt, optOrDefault, some;
import util.symbol : symbol;
import util.util : typeAs;

FunBody checkAutoFun(ref CheckCtx ctx, in SpecsMap specsMap, in FunsMap funsMap, FunDecl* fun) {
	FunBody wrong(Diag diag) {
		addDiag(ctx, fun.nameRange.range, diag);
		return FunBody.bogus;
	}
	FunBody wrongParams(AutoFunName kind) =>
		wrong(Diag(DiagAutoFunWrongParams(kind)));
	FunBody wrongReturnType() =>
		wrong(Diag(DiagAutoFunWrongReturnType()));

	switch (fun.name.value) {
		case symbol!"==".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"equal", CommonModule.compare);
			Opt!Type paramType = getAutoFunParamType(ctx, AutoFunName.equals, fun, countParams: 2);
			return has(spec) && has(paramType)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, force(paramType), AutoFunName.equals, AutoFunKind.equals, force(spec),
					returnTypeOk: none!bool,
					countParams: 2)
				: FunBody.bogus;
		case symbol!"<=>".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"compare", CommonModule.compare);
			Opt!Type paramType = getAutoFunParamType(ctx, AutoFunName.compare, fun, countParams: 2);
			return has(spec) && has(paramType)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, force(paramType), AutoFunName.compare, AutoFunKind.compare, force(spec),
					returnTypeOk: none!bool,
					countParams: 2)
				: FunBody.bogus;
		case symbol!"to".value:
			Opt!Type optParamType = getAutoFunParamType(ctx, AutoFunName.to, fun, countParams: 1);
			if (has(optParamType)) {
				Type paramType = force(optParamType);
				Opt!IntegralType returnedIntegral = asIntegralType(fun.returnType);
				Opt!IntegralType paramIntegral = asIntegralType(paramType);
				if (isEnumOrFlagsOption(fun.returnType) && isSymbol(paramType))
					return FunBody(AutoFun(AutoFunKind.symbolToOptEnumOrFlags, []));
				else if (isEnumOrFlagsOption(fun.returnType) &&
						has(paramIntegral) &&
						force(paramIntegral) == asEnumOrFlags(mustUnwrapOptionType(fun.returnType)).storage) {
					return FunBody(AutoFun(AutoFunKind.integralToOptEnumOrFlags));
				} else if (has(returnedIntegral) && isEnumOrFlags(paramType)) {
					return force(returnedIntegral) != asEnumOrFlags(paramType).storage
						? wrong(Diag(DiagAutoFunEnumOrFlagsToWrongStorage(
							enumOrFlagsType: paramType.as!(StructInst*).decl,
							actualStorageType: asEnumOrFlags(paramType).storage,
							expectedStorageType: force(returnedIntegral),
						)))
						: FunBody(AutoFun(AutoFunKind.enumOrFlagsToIntegral, []));
				} else if (isSymbol(fun.returnType) && isEnum(paramType))
					return FunBody(AutoFun(AutoFunKind.enumToSymbol, []));
				else if (isSymbolArray(fun.returnType) && isFlags(paramType))
					return checkAutoFunNotBare(ctx, fun)
						? FunBody(AutoFun(AutoFunKind.flagsToSymbolArray, []))
						: FunBody.bogus;
				else {
					Opt!(SpecDecl*) spec = getSpecFromCommonModule(
						ctx, specsMap, fun.nameRange.range, symbol!"to", CommonModule.misc);
					return has(spec) && checkAutoFunNotBare(ctx, fun)
						? checkAutoFunWithSpec(
							ctx, funsMap, fun, paramType, AutoFunName.to, AutoFunKind.toJson, force(spec),
							returnTypeOk: some(isJson(ctx, fun.returnType)),
							countParams: 1,
							extraTypeArg: some(fun.returnType))
						: FunBody.bogus;
				}
			} else
				return FunBody.bogus;
		case symbol!"members".value:
			if (!isEmpty(fun.params))
				return wrongParams(AutoFunName.members);
			else if (!isEnumOrFlagsArray(fun.returnType))
				return wrongReturnType();
			else
				return FunBody(AutoFun(AutoFunKind.enumOrFlagsMembers, []));
		default:
			addDiag(ctx, fun.nameRange.range, Diag(DiagAutoFunWrongName()));
			return FunBody.bogus;
	}
}

private:

bool isEnumOrFlagsArray(in Type a) =>
	isArray(a) && isEnumOrFlags(arrayElementType(a));
bool isSymbolArray(in Type a) =>
	isArray(a) && isSymbol(arrayElementType(a));
bool isEnumOrFlagsOption(in Type a) =>
	isOptionType(a) && isEnumOrFlags(mustUnwrapOptionType(a));

bool isEnumOrFlags(in Type a) =>
	isEnum(a) || isFlags(a);
Flags asEnumOrFlags(in Type a) {
	assert(isEnumOrFlags(a));
	if (isEnum(a)) {
		Enum* e = asEnum(a);
		return Flags(e.storage, e.members);
	} else
		return a.as!(StructInst*).decl.body_.as!Flags;
}
Enum* asEnum(in Type a) =>
	a.as!(StructInst*).decl.body_.as!(Enum*);

FunBody checkAutoFunWithSpec(
	ref CheckCtx ctx,
	in FunsMap funsMap,
	FunDecl* fun,
	Type paramType,
	AutoFunName funName,
	AutoFunKind funKind,
	SpecDecl* spec,
	Opt!bool returnTypeOk, // if none, use sig
	uint countParams,
	Opt!Type extraTypeArg = none!Type,
) {
	FunBody diag(Diag x) {
		addDiag(ctx, fun.nameRange.range, x);
		return FunBody.bogus;
	}
	if (spec.sigs.length != 1)
		return diag(Diag(DiagAutoFunSpecCorrupt(spec.name)));
	Signature* sig = &only(spec.sigs);

	if (!isEnumFlagsRecordOrUnion(paramType))
		return diag(Diag(DiagAutoFunWrongParamType()));
	else if (!optOrDefault!bool(returnTypeOk, () => fun.returnType == sig.returnType))
		return diag(Diag(DiagAutoFunWrongReturnType(funName)));
	else {
		StructInst* paramInst = paramType.as!(StructInst*);
		Called checkSpecForComponent(Type declType) {
			Type instType = instantiateType(ctx.instantiateCtx, declType, paramInst.typeArgs);
			return checkSpecSingleSigIgnoreParents(ctx, funsMap, fun, has(extraTypeArg)
				? instantiateSpec(ctx.instantiateCtx, spec, [force(extraTypeArg), instType])
				: instantiateSpec(ctx.instantiateCtx, spec, [instType]));
		}
		Called[] members = paramInst.decl.body_.match!(Called[])(
			(StructBodyBogus _) =>
				assert(false),
			(BuiltinType _) =>
				assert(false),
			(ref Enum) =>
				typeAs!(Called[])([]),
			(ExternType _) =>
				assert(false),
			(Flags) =>
				typeAs!(Called[])([]),
			(Record x) =>
				map(ctx.alloc, x.fields, (ref RecordField field) =>
					checkSpecForComponent(field.type)),
			(SumType v) =>
				map(ctx.alloc, v.listedMembers, (ref SumTypeMemberAndMethodImpls m) =>
					checkSpecForComponent(Type(m.member))));
		return FunBody(AutoFun(funKind, members));
	}
}


bool checkAutoFunNotBare(ref CheckCtx ctx, FunDecl* fun) {
	if (fun.flags.bare) {
		addDiag(ctx, fun.nameRange.range, Diag(DiagAutoFunBare()));
		return false;
	} else
		return true;
}

Opt!Type getAutoFunParamType(ref CheckCtx ctx, AutoFunName funName, FunDecl* fun, uint countParams) {
	Opt!Type res = fun.params.matchIn!(Opt!Type)(
		(in Destructure[] params) =>
			params.length == countParams && allSame!(Type, Destructure)(params, (in Destructure x) => x.type)
				? some(params[0].type)
				: none!Type,
		(in Varargs _) =>
			none!Type);
	if (!has(res)) {
		addDiag(ctx, fun.nameRange.range, Diag(DiagAutoFunWrongParams(funName)));
		return none!Type;
	} else if (!isFullyVisible(ctx, force(res))) {
		addDiag(ctx, fun.nameRange.range, Diag(DiagAutoFunTypeNotFullyVisible()));
		return none!Type;
	} else if (!every!Destructure(fun.params.as!(Destructure[]), (in Destructure x) => x.isA!(Local*))) {
		addDiag(ctx, fun.nameRange.range, Diag(DiagAutoFunParamNotSimple()));
		return none!Type;
	} else
		return res;
}

bool isEnumFlagsRecordOrUnion(in Type a) =>
	isEnumOrFlags(a) || isRecordOrUnion(a);
bool isRecordOrUnion(in Type a) =>
	a.isA!(StructInst*) && isRecordOrUnion(a.as!(StructInst*).decl.body_);
bool isRecordOrUnion(in StructBody a) =>
	a.isA!Record || isUnion(a);
bool isUnion(in StructBody a) =>
	a.isA!SumType && a.as!SumType.kind == SumTypeKind.union_;

bool isFullyVisible(in CheckCtx ctx, in Type a) {
	if (!a.isA!(StructInst*))
		return false;
	StructDecl* decl = a.as!(StructInst*).decl;
	return decl.moduleUri == ctx.curUri || decl.body_.matchIn!bool(
		(in StructBodyBogus _) =>
			true,
		(in BuiltinType _) =>
			true,
		(in Enum _) =>
			true,
		(in ExternType _) =>
			false,
		(in Flags _) =>
			true,
		(in Record record) =>
			every!RecordField(record.fields, (in RecordField x) =>
				x.visibility == decl.visibility),
		(in SumType x) =>
			x.kind == SumTypeKind.union_);
}

bool isJson(in CheckCtx ctx, in Type a) =>
	a.isA!(StructInst*) &&
	a.as!(StructInst*).decl.moduleUri == ctx.commonUris[CommonModule.json] &&
	a.as!(StructInst*).decl.name == symbol!"json";
