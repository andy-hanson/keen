module frontend.check.checkUtil;

@safe @nogc pure nothrow:

import frontend.check.checkCtx : addDiag, CheckCtx;
import frontend.check.maps : StructsAndAliasesMap;
import frontend.check.typeFromAst : AliasAllowed, checkDestructure, DestructureKind, typeFromAst;
import model.ast :
	DestructureAst,
	LiteralIntegralAndRange,
	ModifierKeyword,
	ModifierKeywordAst,
	NameAndRange,
	ParamsAst,
	TupleTypeAst,
	TypeAst,
	VarargsAst;
import model.integralValues : IntegralValue;
import model.model :
	BogusType,
	CommonTypes,
	Destructure,
	Diag,
	DiagExternInvalidName,
	DiagExternMissingLibraryName,
	DiagExternRedundant,
	DiagLiteralOverflow,
	DiagVarargsParamMustBeArray,
	FunBody,
	FunDecl,
	FunDeclSource,
	FunFlags,
	IntegralType,
	isBuiltinExtern,
	maxValue,
	minValue,
	Params,
	SpecInst,
	StructInst,
	Type,
	TypeContainer,
	TypeParamIndex,
	TypeParams,
	Varargs,
	Visibility;
import util.col.array : mapPointers, only, small;
import util.opt : force, has, none, Opt, optIf, optOrDefault, some;
import util.memory : allocate;
import util.symbol : Symbol, symbol;
import util.symbolSet : buildSymbolSet, emptySymbolSet, SymbolSet, symbolSet, SymbolSetBuilder;

FunDecl funDeclWithBody(
	FunDeclSource source,
	Visibility visibility,
	Symbol name,
	Type returnType,
	Params params,
	FunFlags flags,
	SymbolSet extern_,
	immutable(SpecInst*)[] specInsts,
	FunBody body_,
) {
	FunDecl res = FunDecl(
		source, visibility, name, returnType, params, flags, extern_, small!(immutable SpecInst*)(specInsts));
	res.body_ = body_;
	return res;
}

IntegralValue checkLiteralIntegralValue(ref CheckCtx ctx, IntegralType type, LiteralIntegralAndRange ast) {
	if (ast.literal.overflow || literalNatOrIntOverflows(type, ast.literal.isSigned, ast.literal.value))
		addDiag(ctx, ast.range, Diag(DiagLiteralOverflow(type)));
	return ast.literal.value;
}

private bool literalNatOrIntOverflows(IntegralType type, bool isSigned, IntegralValue value) =>
	isSigned
		? (value.asSigned < minValue(type) || (value.asSigned > 0 && value.asSigned > maxValue(type)))
		: value.asUnsigned > maxValue(type);

immutable struct ReturnTypeAndParams {
	Type returnType;
	Params params;
}
ReturnTypeAndParams checkReturnTypeAndParams(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	in TypeAst returnTypeAst,
	in ParamsAst paramsAst,
	TypeParams typeParams,
	in StructsAndAliasesMap structsAndAliasesMap,
) =>
	ReturnTypeAndParams(
		typeFromAst(
			ctx, commonTypes, structsAndAliasesMap, returnTypeAst, typeParams, AliasAllowed.yes),
		checkParams(ctx, commonTypes, typeContainer, paramsAst, structsAndAliasesMap, typeParams));

private Params checkParams(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	TypeContainer typeContainer,
	in ParamsAst ast,
	in StructsAndAliasesMap structsAndAliasesMap,
	TypeParams typeParamsScope,
) =>
	ast.matchWithPointers!Params(
		(DestructureAst[] asts) =>
			Params(mapPointers!(Destructure, DestructureAst)(ctx.alloc, asts, (DestructureAst* ast) =>
				checkDestructure(
					ctx, commonTypes, structsAndAliasesMap, typeContainer, typeParamsScope,
					ast, none!Type, DestructureKind.param))),
		(VarargsAst* varargs) {
			Destructure param = checkDestructure(
				ctx, commonTypes, structsAndAliasesMap, typeContainer, typeParamsScope,
				&varargs.param, none!Type, DestructureKind.param);
			Opt!Type elementType = param.type.matchIn!(Opt!Type)(
				(in BogusType _) =>
					some(Type.bogus),
				(in TypeParamIndex _) =>
					none!Type,
				(in StructInst x) =>
					x.decl == commonTypes.array
					? some(only(x.typeArgs))
					: none!Type);
			if (!has(elementType))
				addDiag(ctx, varargs.param.range, Diag(DiagVarargsParamMustBeArray()));
			return Params(allocate(ctx.alloc, Varargs(param, has(elementType) ? force(elementType) : Type.bogus)));
		});

SymbolSet getExternsFromModifier(ref CheckCtx ctx, in ModifierKeywordAst modifier, bool required) {
	assert(modifier.keyword == ModifierKeyword.extern_);
	if (has(modifier.typeArg))
		return optOrDefault!SymbolSet(tryGetExternsFromTypeArg(ctx, force(modifier.typeArg)), () =>
			required ? symbolSet(symbol!"bogus") : emptySymbolSet);
	else if (required) {
		addDiag(ctx, modifier.keywordRange, Diag(DiagExternMissingLibraryName()));
		return symbolSet(symbol!"bogus");
	} else
		return emptySymbolSet;
}

private Opt!SymbolSet tryGetExternsFromTypeArg(ref CheckCtx ctx, in TypeAst arg) {
	if (arg.isA!NameAndRange) {
		return some(symbolSet(checkExternNameOrBogus(ctx, arg.as!NameAndRange, emptySymbolSet)));
	} else if (arg.isA!(TupleTypeAst*)) {
		bool ok = true;
		SymbolSet res = buildSymbolSet((scope ref SymbolSetBuilder out_) {
			foreach (TypeAst member; arg.as!(TupleTypeAst*).members) {
				if (member.isA!NameAndRange)
					out_ ~= checkExternNameOrBogus(ctx, member.as!NameAndRange, emptySymbolSet);
				else
					ok = false;
			}
		});
		return optIf(ok, () => res);
	} else
		return none!SymbolSet;
}

private Symbol checkExternNameOrBogus(ref CheckCtx ctx, NameAndRange name, SymbolSet enclosingExterns) =>
	optOrDefault!Symbol(checkExternName(ctx, name, enclosingExterns), () => symbol!"bogus");
Opt!Symbol checkExternName(ref CheckCtx ctx, NameAndRange name, SymbolSet enclosingExterns) {
	Symbol res = name.name;
	if (isBuiltinExtern(res) || res in ctx.config.extern_) {
		if (res in enclosingExterns)
			addDiag(ctx, name.range, Diag(DiagExternRedundant(res)));
		return some(res);
	} else {
		addDiag(ctx, name.range, Diag(DiagExternInvalidName(res)));
		return none!Symbol;
	}
}
