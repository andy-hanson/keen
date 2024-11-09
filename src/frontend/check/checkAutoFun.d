module frontend.check.checkAutoFun;

@safe @nogc pure nothrow:

import frontend.check.checkCall.checkCallSpecs : checkSpecSingleSigIgnoreParents;
import frontend.check.checkCtx : addDiag, CheckCtx, CommonModule;
import frontend.check.maps : FunsMap, SpecsMap;
import frontend.check.instantiate : instantiateSpec;
import frontend.check.typeFromAst : getSpecFromCommonModule;
import model.diag : AutoFunName, Diag;
import model.model :
	arrayElementType,
	asIntegralType,
	AutoFun,
	BuiltinType,
	CommonTypes,
	Destructure,
	FunBody,
	FunDecl,
	IntegralType,
	isArray,
	isEmpty,
	isSymbol,
	Params,
	RecordField,
	SpecDecl,
	Signature,
	SpecInst,
	StructBody,
	StructDecl,
	StructInst,
	Type;
import util.col.array : allSame, every, isEmpty, map, only;
import util.opt : force, has, none, Opt, optIf, optOr, optOrDefault, some;
import util.symbol : symbol;
import util.util : todo; // ------------------------------------------------------------------------------------------------------------

FunBody checkAutoFun(ref CheckCtx ctx, in CommonTypes commonTypes, in SpecsMap specsMap, in FunsMap funsMap, FunDecl* fun) {
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
			return has(spec)
				? checkAutoFunWithSpec( // TODO: this redundantly checks param type ---------------------------------------------
					ctx, funsMap, fun, AutoFunName.equals, AutoFun.Kind.equals, force(spec),
					returnTypeOk: none!bool,
					countParams: 2,
					allowBare: true)
				: FunBody.bogus;
		case symbol!"<=>".value:
			Opt!Type optParamType = getAutoFunParamType(fun, countParams: 2);
			Opt!(SpecDecl*) spec = getSpecFromCommonModule(
				ctx, specsMap, fun.nameRange.range, symbol!"compare", CommonModule.compare);
			return has(spec)
				? checkAutoFunWithSpec( // TODO: this redundantly checks param type ---------------------------------------------
					ctx, funsMap, fun, AutoFunName.compare, AutoFun.Kind.compare, force(spec),
					returnTypeOk: none!bool,
					countParams: 2,
					allowBare: true)
				: FunBody.bogus;
		case symbol!"to".value:
			Opt!Type optParamType = getAutoFunParamType(fun, countParams: 1);
			if (has(optParamType)) {
				Type paramType = force(optParamType);
				Opt!Type returnedOption = asOptionType(commonTypes, fun.returnType);
				Opt!IntegralType returnedIntegral = asIntegralType(fun.returnType);
				if (has(returnedOption) && isEnum(force(returnedOption)) && isSymbol(paramType)) {
					return FunBody(AutoFun(AutoFun.Kind.symbolToOptEnum, []));
				} else if (has(returnedIntegral) && isEnumOrFlags(paramType)) {
					return checkAutoFunEnumOrFlagsToIntegral(ctx, fun, force(returnedIntegral), paramType);
				} else if (fun.returnType == Type(commonTypes.symbol) && isEnum(paramType)) {
					return checkAutoFunEnumToSymbol(ctx, fun, paramType);
				} else {
					Opt!(SpecDecl*) spec = getSpecFromCommonModule(
						ctx, specsMap, fun.nameRange.range, symbol!"to", CommonModule.misc);
					return has(spec)
						? checkAutoFunWithSpec( // TODO: this redundantly checks the param type =========================================
							ctx, funsMap, fun, AutoFunName.to, AutoFun.Kind.toJson, force(spec),
							returnTypeOk: some(isJson(ctx, fun.returnType)),
							countParams: 1,
							allowBare: false,
							extraTypeArg: some(fun.returnType))
						: FunBody.bogus;
				}
			} else
				return wrongParams(AutoFunName.to);
		case symbol!"members".value:
			if (!isEmpty(fun.params))
				return wrongParams(AutoFunName.members);
			else if (isArray(fun.returnType) && isEnumOrFlags(arrayElementType(fun.returnType)))
				return FunBody(AutoFun(AutoFun.Kind.enumOrFlagsMembers, []));
			else
				return wrongReturnType();
		default:
			addDiag(ctx, fun.nameRange.range, Diag(Diag.AutoFunError(Diag.AutoFunError.WrongName())));
			return FunBody.bogus;
	}
}

private:

Opt!Type asOptionType(in CommonTypes commonTypes, in Type a) { // TODO: doesn' this exist somewhere else already?????????????????????????
	if (a.isA!(StructInst*)) {
		StructInst* inst = a.as!(StructInst*);
		return optIf(inst.decl == commonTypes.option, () => only(inst.typeArgs));
	} else
		return none!Type;
}

FunBody checkAutoFunEnumOrFlagsToIntegral(ref CheckCtx ctx, FunDecl* fun, IntegralType returnType, Type paramType) {
	Opt!(Diag.AutoFunError) diag = checkForAutoFunError(ctx, fun, AutoFunName.to, some(paramType), allowBare: true); // TODO: dup code. ....
	if (has(diag)) {
		addDiag(ctx, fun.nameRange.range, Diag(force(diag)));
		return FunBody.bogus;
	} else if (returnType != asEnumOrFlags(paramType).storage) {
		todo!void("DIAG: enum to integral does not match storage type");
		return FunBody.bogus;
	} else
		return FunBody(AutoFun(AutoFun.Kind.enumOrFlagsToIntegral, []));
}

FunBody checkAutoFunEnumToSymbol(ref CheckCtx ctx, FunDecl* fun, Type paramType) {
	Opt!(Diag.AutoFunError) diag = checkForAutoFunError(ctx, fun, AutoFunName.to, some(paramType), allowBare: true);
	if (has(diag)) {
		addDiag(ctx, fun.nameRange.range, Diag(force(diag)));
		return FunBody.bogus;
	} else {
		if (!isEnum(only(fun.params.as!(Destructure[])).type)) {
			todo!void("DIAG: 'to symbol' only works for enum"); // ---------------------------------------------------------------
		}
		return FunBody(AutoFun(AutoFun.Kind.enumToSymbol, []));
	}
}

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
	AutoFunName funName,
	AutoFun.Kind funKind,
	SpecDecl* spec,
	Opt!bool returnTypeOk, // if none, use sig
	uint countParams,
	bool allowBare,
	Opt!Type extraTypeArg = none!Type,
) {
	FunBody diag(Diag.AutoFunError x) {
		addDiag(ctx, fun.nameRange.range, Diag(x));
		return FunBody.bogus;
	}
	if (spec.sigs.length != 1)
		return diag(Diag.AutoFunError(Diag.AutoFunError.SpecCorrupt(spec.name)));
	Signature* sig = &only(spec.sigs);
	Opt!Type paramType = getAutoFunParamType(fun, countParams);
	Opt!(Diag.AutoFunError) err = optOr!(Diag.AutoFunError)(
		checkForAutoFunError(ctx, fun, funName, paramType, allowBare),
		() => !optOrDefault!bool(returnTypeOk, () => fun.returnType == sig.returnType)
			? some(Diag.AutoFunError(Diag.AutoFunError.WrongReturnType(funName)))
			: !isEnumFlagsRecordOrUnion(force(paramType))
			? some(Diag.AutoFunError(Diag.AutoFunError.WrongParamType()))
			: none!(Diag.AutoFunError));
	return has(err)
		? diag(force(err))
		: FunBody(AutoFun(funKind, map(ctx.alloc, force(paramType).as!(StructInst*).instantiatedTypes, (ref Type type) {
			SpecInst* inst = has(extraTypeArg)
				? instantiateSpec(ctx.instantiateCtx, spec, [force(extraTypeArg), type])
				: instantiateSpec(ctx.instantiateCtx, spec, [type]);
			return checkSpecSingleSigIgnoreParents(ctx, funsMap, fun, inst);
		})));
}

Opt!(Diag.AutoFunError) checkForAutoFunError(in CheckCtx ctx, FunDecl* fun, AutoFunName funName, in Opt!Type paramType, bool allowBare) =>
	!has(paramType)
		? some(Diag.AutoFunError(Diag.AutoFunError.WrongParams(funName)))
		: !isFullyVisible(ctx, force(paramType))
		? some(Diag.AutoFunError(Diag.AutoFunError.TypeNotFullyVisible()))
		: !allowBare && fun.flags.bare
		? some(Diag.AutoFunError(Diag.AutoFunError.Bare()))
		: none!(Diag.AutoFunError);

Opt!Type getAutoFunParamType(FunDecl* fun, uint countParams) =>
	fun.params.matchIn!(Opt!Type)(
		(in Destructure[] params) =>
			params.length == countParams && allSame!(Type, Destructure)(params, (in Destructure x) => x.type)
				? some(params[0].type)
				: none!Type,
		(in Params.Varargs) =>
			none!Type);

bool isEnumFlagsRecordOrUnion(in Type a) =>
	isEnumOrFlags(a) || ( // TODO:NEATER ----------------------------------------------------------------------------------------------------------
	a.isA!(StructInst*) && (
		a.as!(StructInst*).decl.body_.isA!(StructBody.Record) || a.as!(StructInst*).decl.body_.isA!(StructBody.Union*)));

bool isFullyVisible(in CheckCtx ctx, in Type a) {
	StructDecl* decl = a.as!(StructInst*).decl;
	return decl.moduleUri == ctx.curUri || decl.body_.matchIn!bool(
		(in StructBody.Bogus) =>
			true,
		(in BuiltinType _) =>
			false,
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
		(in StructBody.Variant) =>
			false);
}

bool isJson(in CheckCtx ctx, in Type a) =>
	a.isA!(StructInst*) &&
	a.as!(StructInst*).decl.moduleUri == ctx.commonUris[CommonModule.json] &&
	a.as!(StructInst*).decl.name == symbol!"json";
