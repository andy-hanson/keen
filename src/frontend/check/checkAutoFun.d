module frontend.check.checkAutoFun;

@safe @nogc pure nothrow:

import frontend.check.checkCall.checkCallSpecs : checkSpecSingleSigIgnoreParents;
import frontend.check.checkCtx : addDiag, CheckCtx, CommonModule;
import frontend.check.maps : FunsMap, SpecsMap;
import frontend.check.instantiate : instantiateSpec, instantiateStructInst, noDelayStructInsts;
import frontend.check.typeFromAst : getSpecFromCommonModule;
import model.diag : AutoFunName, Diag;
import model.model :
	arrayElementType,
	asIntegralType,
	AutoFun,
	BuiltinType,
	Called,
	CommonTypes,
	Destructure,
	FunBody,
	FunDecl,
	IntegralType,
	isArray,
	isEmpty,
	isOptionType,
	isSymbol,
	Local,
	mustUnwrapOptionType,
	Params,
	RecordField,
	SpecDecl,
	Signature,
	SpecInst,
	StructBody,
	StructDecl,
	StructInst,
	Type,
	VariantKind,
	VariantMemberAndMethodImpls;
import util.col.array : allSame, every, isEmpty, map, only;
import util.opt : force, has, none, Opt, optOrDefault, some;
import util.symbol : symbol;
import util.util : typeAs;

FunBody checkAutoFun(
	ref CheckCtx ctx,
	in CommonTypes commonTypes,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	FunDecl* fun,
) {
	FunBody wrong(Diag.AutoFunError diag) {
		addDiag(ctx, fun.nameRange.range, Diag(diag));
		return FunBody.bogus;
	}
	FunBody wrongParams(AutoFunName kind) =>
		wrong(Diag.AutoFunError(Diag.AutoFunError.WrongParams(kind)));
	FunBody wrongReturnType() =>
		wrong(Diag.AutoFunError(Diag.AutoFunError.WrongReturnType()));

	switch (fun.name.value) {
		case symbol!"==".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"equal", CommonModule.compare);
			Opt!Type paramType = getAutoFunParamType(ctx, AutoFunName.equals, fun, countParams: 2);
			return has(spec) && has(paramType)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, force(paramType), AutoFunName.equals, AutoFun.Kind.equals, force(spec),
					returnTypeOk: none!bool,
					countParams: 2)
				: FunBody.bogus;
		case symbol!"<=>".value:
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"compare", CommonModule.compare);
			Opt!Type paramType = getAutoFunParamType(ctx, AutoFunName.compare, fun, countParams: 2);
			return has(spec) && has(paramType)
				? checkAutoFunWithSpec(
					ctx, funsMap, fun, force(paramType), AutoFunName.compare, AutoFun.Kind.compare, force(spec),
					returnTypeOk: none!bool,
					countParams: 2)
				: FunBody.bogus;
		case symbol!"to".value:
			Opt!Type optParamType = getAutoFunParamType(ctx, AutoFunName.to, fun, countParams: 1);
			if (has(optParamType)) {
				Type paramType = force(optParamType);
				Opt!IntegralType returnedIntegral = asIntegralType(fun.returnType);
				if (isEnumOrFlagsOption(commonTypes, fun.returnType) && isSymbol(paramType)) {
					return FunBody(AutoFun(AutoFun.Kind.symbolToOptEnumOrFlags, []));
				} else if (has(returnedIntegral) && isEnumOrFlags(paramType)) {
					return force(returnedIntegral) != asEnumOrFlags(paramType).storage
						? wrong(Diag.AutoFunError(Diag.AutoFunError.EnumOrFlagsToWrongStorage(
							enumOrFlagsType: paramType.as!(StructInst*).decl,
							actualStorageType: asEnumOrFlags(paramType).storage,
							expectedStorageType: force(returnedIntegral),
						)))
						: FunBody(AutoFun(AutoFun.Kind.enumOrFlagsToIntegral, []));
				} else if (fun.returnType == Type(commonTypes.symbol) && isEnum(paramType))
					return FunBody(AutoFun(AutoFun.Kind.enumToSymbol, []));
				else if (isSymbolArray(fun.returnType) && isFlags(paramType))
					return checkAutoFunNotBare(ctx, fun)
						? FunBody(AutoFun(AutoFun.Kind.flagsToSymbolArray, []))
						: FunBody.bogus;
				else {
					Opt!(SpecDecl*) spec = getSpecFromCommonModule(
						ctx, specsMap, fun.nameRange.range, symbol!"to", CommonModule.misc);
					return has(spec) && checkAutoFunNotBare(ctx, fun)
						? checkAutoFunWithSpec(
							ctx, funsMap, fun, paramType, AutoFunName.to, AutoFun.Kind.toJson, force(spec),
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
				return FunBody(AutoFun(AutoFun.Kind.enumOrFlagsMembers, []));
		default:
			addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.WrongName())));
			return FunBody.bogus;
	}
}

private:

bool isEnumOrFlagsArray(in Type a) =>
	isArray(a) && isEnumOrFlags(arrayElementType(a));
bool isSymbolArray(in Type a) =>
	isArray(a) && isSymbol(arrayElementType(a));
bool isEnumOrFlagsOption(in CommonTypes commonTypes, in Type a) =>
	isOptionType(commonTypes, a) && isEnumOrFlags(mustUnwrapOptionType(commonTypes, a));

bool isEnum(in Type a) =>
	a.isA!(StructInst*) && a.as!(StructInst*).decl.body_.isA!(StructBody.Enum*);
bool isFlags(in Type a) =>
	a.isA!(StructInst*) && a.as!(StructInst*).decl.body_.isA!(StructBody.Flags);
bool isEnumOrFlags(in Type a) =>
	isEnum(a) || isFlags(a);
StructBody.Flags asEnumOrFlags(in Type a) {
	assert(isEnumOrFlags(a));
	if (isEnum(a)) {
		StructBody.Enum* e = asEnum(a);
		return StructBody.Flags(e.storage, e.members);
	} else
		return a.as!(StructInst*).decl.body_.as!(StructBody.Flags);
}
StructBody.Enum* asEnum(in Type a) =>
	a.as!(StructInst*).decl.body_.as!(StructBody.Enum*);

FunBody checkAutoFunWithSpec(
	ref CheckCtx ctx,
	in FunsMap funsMap,
	FunDecl* fun,
	Type paramType,
	AutoFunName funName,
	AutoFun.Kind funKind,
	SpecDecl* spec,
	Opt!bool returnTypeOk, // if none, use sig
	uint countParams,
	Opt!Type extraTypeArg = none!Type,
) {
	FunBody diag(Diag.AutoFunError x) {
		addDiag(ctx, fun.nameRange.range, Diag(x));
		return FunBody.bogus;
	}
	if (spec.sigs.length != 1)
		return diag(Diag.AutoFunError(Diag.AutoFunError.SpecCorrupt(spec.name)));
	Signature* sig = &only(spec.sigs);

	if (!isEnumFlagsRecordOrUnion(paramType))
		return diag(Diag.AutoFunError(Diag.AutoFunError.WrongParamType()));
	else if (!optOrDefault!bool(returnTypeOk, () => fun.returnType == sig.returnType))
		return diag(Diag.AutoFunError(Diag.AutoFunError.WrongReturnType(funName)));
	else {
		Called checkSpecSigForContainedType(Type type) => // TODO: SHORTER NAME ----------------------------------------------------------------------
			checkSpecSingleSigIgnoreParents(ctx, funsMap, fun, has(extraTypeArg)
				? instantiateSpec(ctx.instantiateCtx, spec, [force(extraTypeArg), type])
				: instantiateSpec(ctx.instantiateCtx, spec, [type]));
		StructInst* paramInst = paramType.as!(StructInst*);
		Called[] members = paramInst.decl.body_.match!(Called[])(
			(StructBody.Bogus) =>
				assert(false),
			(BuiltinType _) =>
				assert(false),
			(ref StructBody.Enum) =>
				typeAs!(Called[])([]),
			(StructBody.Extern) =>
				assert(false),
			(StructBody.Flags) =>
				typeAs!(Called[])([]),
			(StructBody.Record) =>
				map(ctx.alloc, paramInst.instantiatedTypes, (ref Type type) =>
					checkSpecSigForContainedType(type)),
			(ref StructBody.Union) =>
				map(ctx.alloc, paramInst.instantiatedTypes, (ref Type type) =>
					checkSpecSigForContainedType(type)),
			(StructBody.Variant v) =>
				map(ctx.alloc, v.listedMembers, (ref VariantMemberAndMethodImpls m) =>
					checkSpecSigForContainedType(Type(instantiateStructInst(ctx.instantiateCtx, *m.member, paramInst.typeArgs, noDelayStructInsts)))));
		return FunBody(AutoFun(funKind, members));
	}
}


bool checkAutoFunNotBare(ref CheckCtx ctx, FunDecl* fun) {
	if (fun.flags.bare) {
		addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.Bare())));
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
		(in Params.Varargs) =>
			none!Type);
	if (!has(res)) {
		addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.WrongParams(funName))));
		return none!Type;
	} else if (!isFullyVisible(ctx, force(res))) {
		addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.TypeNotFullyVisible())));
		return none!Type;
	} else if (!every!Destructure(fun.params.as!(Destructure[]), (in Destructure x) => x.isA!(Local*))) {
		addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.ParamNotSimple())));
		return none!Type;
	} else
		return res;
}

bool isEnumFlagsRecordOrUnion(in Type a) =>
	isEnumOrFlags(a) || isRecordOrUnion(a);
bool isRecordOrUnion(in Type a) =>
	a.isA!(StructInst*) && isRecordOrUnion(a.as!(StructInst*).decl.body_);
bool isRecordOrUnion(in StructBody a) =>
	a.isA!(StructBody.Record) || a.isA!(StructBody.Union*) || isUnion(a);
bool isUnion(in StructBody a) =>
	a.isA!(StructBody.Variant) && a.as!(StructBody.Variant).kind == VariantKind.union_;

bool isFullyVisible(in CheckCtx ctx, in Type a) {
	if (!a.isA!(StructInst*))
		return false;
	StructDecl* decl = a.as!(StructInst*).decl;
	return decl.moduleUri == ctx.curUri || decl.body_.matchIn!bool(
		(in StructBody.Bogus) =>
			true,
		(in BuiltinType _) =>
			true,
		(in StructBody.Enum) =>
			true,
		(in StructBody.Extern) =>
			false,
		(in StructBody.Flags) =>
			true,
		(in StructBody.Record record) =>
			every!RecordField(record.fields, (in RecordField x) =>
				x.visibility == decl.visibility),
		(in StructBody.Union) =>
			true,
		(in StructBody.Variant x) =>
			x.kind == VariantKind.union_);
}

bool isJson(in CheckCtx ctx, in Type a) =>
	a.isA!(StructInst*) &&
	a.as!(StructInst*).decl.moduleUri == ctx.commonUris[CommonModule.json] &&
	a.as!(StructInst*).decl.name == symbol!"json";
