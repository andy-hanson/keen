module frontend.check.checkStructBodies;

@safe @nogc pure nothrow:

import frontend.check.checkCall.checkCall : findFunctionForReturnAndParamTypes;
import frontend.check.checkCall.candidates : funsInNonExprScope;
import frontend.check.checkCtx :
	addDiag,
	addDiagAssertSameUri,
	CheckCtx,
	checkNoTypeParams,
	visibilityFromDefaultWithDiag,
	visibilityFromExplicitTopLevel;
import frontend.check.checkFuns : checkReturnTypeAndParams, getExternsFromModifier, ReturnTypeAndParams;
import frontend.check.exprCtx : LocalsInfo;
import frontend.check.instantiate : DelayStructInsts, instantiateStructWithOwnTypeParams, instantiateTypeNoDelay, MayDelayStructInsts;
import frontend.check.maps : FunsMap, StructsAndAliasesMap;
import frontend.check.typeFromAst : AliasAllowed, checkTypeParams, typeFromAst;
import model.ast :
	DestructureAst,
	EnumOrFlagsMemberAst,
	FieldMutabilityAst,
	LiteralIntegralAndRange,
	ModifierAst,
	ModifierKeyword,
	NameAndRange,
	ParamsAst,
	RecordOrUnionMemberAst,
	SignatureAst,
	SpecUseAst,
	StructBodyAst,
	StructDeclAst,
	TypeAst,
	VisibilityAndRange;
import model.concreteModel : TypeSize;
import model.diag : Diag, DeclKind;
import model.model :
	asTypeContainer,
	BuiltinType,
	ByValOrRef,
	Called,
	CommonTypes,
	Destructure,
	emptyTypeParams,
	EnumOrFlagsMember,
	EnumMemberSource,
	FunFlags,
	FunInst,
	IntegralType,
	IntegralTypes,
	isLinkagePossiblyCompatible,
	isPurityAlwaysCompatible,
	isPurityPossiblyCompatible,
	isSigned,
	leastVisibility,
	Linkage,
	linkageRange,
	maxValue,
	minValue,
	nameOfEnumOrFlagsMember,
	Params,
	Purity,
	purityRange,
	RecordField,
	RecordOrUnionMemberSource,
	RecordFlags,
	ReturnAndParamTypes,
	Signature,
	SignatureContainer,
	StructBody,
	StructDecl,
	StructDeclSource,
	StructInst,
	Type,
	TypeContainer,
	TypeParamIndex,
	TypeParams,
	VariantAndMethodImpls,
	VariantMemberAndMethodImpls,
	Visibility;
import util.alloc.stackAlloc : withStackArray;
import util.col.array :
	arrayOfSingle,
	eachPair,
	emptySmallArray,
	exists,
	fold,
	isEmpty,
	map,
	mapOpPointers,
	mapOpPointersWithSoFar,
	mapPointers,
	small,
	SmallArray,
	zipPtrFirst;
import util.col.hashTable : HashTable, makeHashTable;
import util.integralValues : IntegralValue;
import util.memory : allocate;
import util.opt : force, has, MutOpt, none, noneMut, Opt, optFromMut, optIf, some, someMut;
import util.sourceRange : Range;
import util.symbol : Symbol, symbol;
import util.symbolSet : emptySymbolSet, SymbolSet, symbolSet;
import util.util : enumConvertOrAssert, isMultipleOf, ptrTrustMe, todo;

void modifierTypeArgInvalid(ref CheckCtx ctx, in ModifierAst.Keyword modifier) {
	if (has(modifier.typeArg)) {
		addDiag(ctx, modifier.range, Diag(Diag.ModifierTypeArgInvalid(modifier.keyword)));
	}
}
void modifierTypeArgInvalid(ref CheckCtx ctx, in MutOpt!(ModifierAst.Keyword*)[] modifiers) {
	foreach (const MutOpt!(ModifierAst.Keyword*) modifier; modifiers)
		if (has(modifier))
			modifierTypeArgInvalid(ctx, *force(modifier));
}


StructDecl[] checkStructsInitial(ref CheckCtx ctx, in StructDeclAst[] asts) =>
	mapPointers!(StructDecl, StructDeclAst)(ctx.alloc, asts, (StructDeclAst* ast) {
		checkTypeParams(ctx, ast.typeParams);
		StructModifiers m = getStructModifiers(ctx, getDeclKind(ast.body_), ast.modifiers);
		return StructDecl(
			StructDeclSource(ast),
			ctx.curUri,
			visibilityFromExplicitTopLevel(ast.visibility),
			m.extern_,
			m.isSummon,
			m.purityAndForced.purity,
			m.purityAndForced.forced);
	});

void checkStructBodies(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	ref StructDecl[] structs,
	in StructDeclAst[] asts,
) {
	zipPtrFirst!(StructDecl, StructDeclAst)(structs, asts, (StructDecl* struct_, ref StructDeclAst ast) {
		struct_.variants = checkVariantMembersInitial(
			ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, ast);
		struct_.body_ = ast.body_.match!StructBody(
			(StructBodyAst.Builtin) {
				checkOnlyCommonModifiers(ctx, DeclKind.builtin, ast.modifiers);
				return StructBody(getBuiltinType(ctx, struct_));
			},
			(StructBodyAst.Enum x) {
				checkNoTypeParams(ctx, ast.typeParams, DeclKind.enum_);
				IntegralType storage = checkEnumOrFlagsModifiers(
					ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, DeclKind.enum_, ast.modifiers,
					isFlags: false);
				return checkEnum(
					ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, ast.range, x, storage);
			},
			(StructBodyAst.Extern x) =>
				StructBody(checkExtern(ctx, ast, x)),
			(StructBodyAst.Flags x) {
				checkNoTypeParams(ctx, ast.typeParams, DeclKind.flags);
				IntegralType storage = checkEnumOrFlagsModifiers(
					ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, DeclKind.flags, ast.modifiers,
					isFlags: false);
				return StructBody(checkFlags(
					ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, ast.range, x, storage));
			},
			(StructBodyAst.Record x) =>
				StructBody(checkRecord(
					ctx, commonTypes, structsAndAliasesMap, struct_, ast.modifiers, x, delayStructInsts)),
			(StructBodyAst.Variant x) {
				checkOnlyCommonModifiers(ctx, DeclKind.variant, ast.modifiers);
				SmallArray!VariantMemberAndMethodImpls listedMembers = checkVariantListedMembersInitial(ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, x);
				SmallArray!Signature sigs = checkSignatures(
					ctx, commonTypes, structsAndAliasesMap, SignatureContainer(struct_), ast.typeParams, x.methods,
					someMut(ptrTrustMe(delayStructInsts)));
				return StructBody(StructBody.Variant(x.kind, listedMembers, sigs));
			});
	});
}

SmallArray!Signature checkSignatures(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	SignatureContainer container,
	TypeParams typeParams,
	SmallArray!SignatureAst asts,
	MayDelayStructInsts delayStructInsts,
) =>
	mapPointers!(Signature, SignatureAst)(ctx.alloc, asts, (SignatureAst* x) {
		ReturnTypeAndParams rp = checkReturnTypeAndParams(
			ctx, commonTypes, asTypeContainer(container), x.returnType, x.params,
			typeParams, structsAndAliasesMap, delayStructInsts);
		Destructure[] params = rp.params.matchWithPointers!(Destructure[])(
			(Destructure[] x) =>
				x,
			(Params.Varargs* x) {
				addDiag(ctx, x.param.range, Diag(Diag.SpecSigCantBeVariadic()));
				return arrayOfSingle(&x.param);
			});
		return Signature(container, x, rp.returnType, small!Destructure(params));
	});

private SmallArray!VariantMemberAndMethodImpls checkVariantListedMembersInitial(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* variant_,
	ref StructBodyAst.Variant ast,
) =>
	mapOpPointers!(VariantMemberAndMethodImpls, TypeAst)(ctx.alloc, ast.types, (TypeAst* typeAst) {
		Type type = typeFromAst(ctx, commonTypes, structsAndAliasesMap, *typeAst, variant_.typeParams, someMut(ptrTrustMe(delayStructInsts)), AliasAllowed.yes);
		if (type.isA!(StructInst*)) {
			return some(VariantMemberAndMethodImpls(typeAst, type.as!(StructInst*)));
		} else {
			if (!type.isBogus) todo!void("DIAG: Type parameter not allowed as a variant member"); // -----------------------------------------------------------------
			return none!VariantMemberAndMethodImpls;
		}
	});

private SmallArray!VariantAndMethodImpls checkVariantMembersInitial( // TODO: this is confusingly named. This checks 'variant-member' modifiers on a type.
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* struct_,
	ref StructDeclAst ast,
) =>
	mapOpPointersWithSoFar!(VariantAndMethodImpls, ModifierAst)(
		ctx.alloc, ast.modifiers, (ModifierAst* mod, in VariantAndMethodImpls[] soFar) {
			Opt!VariantAndMethodImpls res = getVariantMemberTypeFromModifier(
				ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, mod);
			if (has(res)) {
				if (struct_.isTemplate) {
					addDiag(ctx, mod.range, Diag(Diag.VariantMemberIsTemplate(struct_)));
					return none!VariantAndMethodImpls;
				}
				if (exists!VariantAndMethodImpls(soFar, (in VariantAndMethodImpls x) =>
					x.variant.decl == force(res).variant.decl)) {
					addDiag(ctx, mod.range, Diag(Diag.VariantMemberMultiple(struct_, force(res).variant.decl)));
					return none!VariantAndMethodImpls;
				}
			}
			return res;
		});

private Opt!VariantAndMethodImpls getVariantMemberTypeFromModifier(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* struct_,
	ModifierAst* mod,
) {
	if (mod.isA!(ModifierAst.Keyword)) {
		ModifierAst.Keyword* kw = &mod.as!(ModifierAst.Keyword)();
		if (kw.keyword == ModifierKeyword.variantMember) {
			if (has(kw.typeArg)) {
				Type type = typeFromAst(
					ctx, commonTypes, structsAndAliasesMap,
					force(kw.typeArg), struct_.typeParams, someMut(ptrTrustMe(delayStructInsts)), AliasAllowed.yes);
				if (type.isA!(StructInst*) && type.as!(StructInst*).decl.body_.isA!(StructBody.Variant))
					return some(VariantAndMethodImpls(kw, type.as!(StructInst*)));
				else {
					if (!type.isBogus)
						addDiag(ctx, kw.range, Diag(Diag.VariantMemberOfNonVariant(struct_, type)));
					return none!VariantAndMethodImpls;
				}
			} else {
				addDiag(ctx, kw.range, Diag(Diag.VariantMemberMissingVariant()));
				return none!VariantAndMethodImpls;
			}
		} else
			return none!VariantAndMethodImpls;
	} else
		return none!VariantAndMethodImpls;
}

void checkVariantMethodImpls(ref CheckCtx ctx, ref CommonTypes commonTypes, FunsMap funsMap, StructDecl[] structs) {
	foreach (ref StructDecl struct_; structs) {
		if (struct_.body_.isA!(StructBody.Variant)) {
			foreach (ref VariantMemberAndMethodImpls x; struct_.body_.as!(StructBody.Variant).listedMembers) {
				// TODO: test purity -----------------------------------------------------------------------------------------------------------------------
				x.methodImpls = checkMethodImplsForVariant(
					ctx, commonTypes, funsMap,
					TypeContainer(&struct_), x.member, x.ast.range,
					instantiateStructWithOwnTypeParams(ctx.instantiateCtx, &struct_),
					struct_.body_.as!(StructBody.Variant).methods);
			}
		}

		foreach (ref VariantAndMethodImpls variant; struct_.variants) {
			StructInst* memberType = instantiateStructWithOwnTypeParams(ctx.instantiateCtx, &struct_);
			if (!isPurityAlwaysCompatible(referencer: variant.variant.purityRange, referenced: struct_.purity))
				addDiag(ctx, variant.ast.range, Diag(Diag.PurityWorseThanVariant(&struct_, variant.variant)));
			variant.methodImpls = checkMethodImplsForVariant(
				ctx, commonTypes, funsMap, TypeContainer(&struct_), memberType, variant.ast.range, variant.variant, variant.variantDeclMethods);
		}
	}
}

private:

SmallArray!(Opt!Called) checkMethodImplsForVariant(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	FunsMap funsMap,
	TypeContainer typeContainer,
	StructInst* memberType,
	Range diagRange,
	StructInst* variant,
	SmallArray!Signature methodDecls,
) {
	StructDecl* member = memberType.decl;
	return map!(Opt!Called, Signature)(ctx.alloc, methodDecls, (ref Signature sig) =>
		withStackArray(
			sig.params.length + 2,
			(size_t i) =>
				i == 0
					? instantiateTypeNoDelay(ctx.instantiateCtx, sig.returnType, variant.typeArgs)
					: i == 1
					? Type(memberType)
					: instantiateTypeNoDelay(ctx.instantiateCtx, sig.params[i - 2].type, variant.typeArgs),
			(scope Type[] types) {
				Opt!Called called = findFunctionForReturnAndParamTypes(
					ctx, commonTypes, typeContainer,
					funsInNonExprScope(ctx, funsMap),
					FunFlags.none.withSummon(member.isSummon),
					member.externSet,
					LocalsInfo(),
					sig.name,
					diagRange,
					none!Type,
					ReturnAndParamTypes(small!Type(types)),
					() => false);
				if (has(called) &&
					force(called).isA!(FunInst*) &&
					force(called).as!(FunInst*).decl.visibility < member.visibility)
					addDiag(ctx, diagRange, Diag(Diag.VariantMethodImplVisibility(member, variant, force(called).as!(FunInst*))));
				return called;
			}));
}

StructBody.Extern checkExtern(ref CheckCtx ctx, in StructDeclAst declAst, in StructBodyAst.Extern bodyAst) {
	checkNoTypeParams(ctx, declAst.typeParams, DeclKind.extern_);
	checkOnlyCommonModifiers(ctx, DeclKind.extern_, declAst.modifiers);
	return StructBody.Extern(getExternTypeSize(ctx, declAst, bodyAst));
}

Opt!TypeSize getExternTypeSize(ref CheckCtx ctx, in StructDeclAst declAst, in StructBodyAst.Extern bodyAst) {
	if (has(bodyAst.size)) {
		uint size = getSizeValue(ctx, *force(bodyAst.size));
		uint default_ = defaultAlignment(size);
		uint alignment = () {
			if (has(bodyAst.alignment)) {
				uint alignment = getSizeValue(ctx, *force(bodyAst.alignment));
				if (isValidAlignment(alignment)) {
					if (alignment == default_)
						addDiag(ctx, force(bodyAst.alignment).range, Diag(
							Diag.ExternTypeError(Diag.ExternTypeError.Reason.alignmentIsDefault)));
					return alignment;
				} else {
					addDiag(ctx, force(bodyAst.alignment).range, Diag(
						Diag.ExternTypeError(Diag.ExternTypeError.Reason.badAlignment)));
					return default_;
				}
			} else
				return default_;
		}();
		return some(TypeSize(size, alignment));
	} else {
		assert(!has(bodyAst.alignment));
		return none!TypeSize;
	}
}

uint getSizeValue(ref CheckCtx ctx, in LiteralIntegralAndRange ast) =>
	cast(uint) checkLiteralIntegral(ctx, IntegralType.nat32, ast).asUnsigned;

bool isValidAlignment(uint alignment) {
	switch (alignment) {
		case 1:
		case 2:
		case 4:
		case 8:
		case 16:
			return true;
		default:
			return false;
	}
}

uint defaultAlignment(size_t size) =>
	size == 0 ? 0 :
	isMultipleOf(size, 8) ? 8 :
	isMultipleOf(size, 4) ? 4 :
	isMultipleOf(size, 2) ? 2 :
	1;

immutable struct StructModifiers {
	Opt!SymbolSet extern_;
	bool isSummon;
	PurityAndForced purityAndForced;
}

immutable struct PurityAndForced {
	Purity purity;
	bool forced;
}

// Note: purity is taken for granted here, and verified later when we check the body.
StructModifiers getStructModifiers(ref CheckCtx ctx, DeclKind declKind, ModifierAst[] modifiers) {
	StructModifierAsts accum = accumulateStructModifiers(ctx, modifiers);
	Opt!SymbolSet extern_ = () {
		Opt!SymbolSet defaultExtern = declKind == DeclKind.extern_ ? some(emptySymbolSet) : none!SymbolSet;
		if (has(accum.extern_)) {
			ModifierAst.Keyword keyword = *force(accum.extern_);
			SymbolSet set = getExternsFromModifier(ctx, keyword, required: false);
			if (has(defaultExtern))
				addDiag(ctx, keyword.keywordRange, Diag(
					Diag.ModifierRedundantDueToDeclKind(keyword.keyword, declKind)));
			return some(set);
		} else
			return defaultExtern;
	}();
	bool isSummon = () {
		if (has(accum.summon))
			modifierTypeArgInvalid(ctx, *force(accum.summon));
		return has(accum.summon);
	}();
	PurityAndForced purity = () {
		Purity defaultPurity = defaultPurity(declKind);
		if (has(accum.purityAndForced)) {
			ModifierAst.Keyword keyword = *force(accum.purityAndForced);
			Opt!PurityAndForced opt = purityAndForcedFromModifier(keyword.keyword);
			PurityAndForced pf = force(opt);
			if (pf.purity == defaultPurity)
				addDiag(ctx, keyword.keywordRange, Diag(
					Diag.ModifierRedundantDueToDeclKind(keyword.keyword, declKind)));
			return pf;
		} else
			return PurityAndForced(defaultPurity, false);
	}();
	return StructModifiers(extern_, isSummon, purity);
}

immutable struct StructModifierAsts {
	Opt!(ModifierAst.Keyword*) extern_;
	Opt!(ModifierAst.Keyword*) summon;
	Opt!(ModifierAst.Keyword*) purityAndForced;
}
StructModifierAsts accumulateStructModifiers(ref CheckCtx ctx, ModifierAst[] modifiers) {
	MutOpt!(ModifierAst.Keyword*) extern_;
	MutOpt!(ModifierAst.Keyword*) summon;
	MutOpt!(ModifierAst.Keyword*) purityAndForced;
	foreach (ref ModifierAst modifier; modifiers) {
		if (isCommonModifier(modifier)) {
			ModifierAst.Keyword* kw = &modifier.as!(ModifierAst.Keyword)();
			if (kw.keyword != ModifierKeyword.variantMember)
				accumulateModifier(
					ctx,
					kw.keyword == ModifierKeyword.extern_
						? extern_
						: kw.keyword == ModifierKeyword.summon
						? summon
						: purityAndForced,
					kw);
		} // else already warned in 'checkOnlyCommonModifiers'
	}
	modifierTypeArgInvalid(ctx, [purityAndForced]);
	return StructModifierAsts(
		extern_: optFromMut!(ModifierAst.Keyword*)(extern_),
		summon: optFromMut!(ModifierAst.Keyword*)(summon),
		purityAndForced: optFromMut!(ModifierAst.Keyword*)(purityAndForced));
}

Purity defaultPurity(DeclKind a) {
	final switch (a) {
		case DeclKind.builtin:
		case DeclKind.enum_:
		case DeclKind.flags:
		case DeclKind.record:
		case DeclKind.variant:
			return Purity.data;
		case DeclKind.extern_:
			return Purity.mut;
		case DeclKind.alias_:
		case DeclKind.externFunction:
		case DeclKind.function_:
		case DeclKind.global:
		case DeclKind.test:
		case DeclKind.spec:
		case DeclKind.threadLocal:
			assert(false);
	}
}

DeclKind getDeclKind(in StructBodyAst a) =>
	a.matchIn!DeclKind(
		(in StructBodyAst.Builtin) =>
			DeclKind.builtin,
		(in StructBodyAst.Enum) =>
			DeclKind.enum_,
		(in StructBodyAst.Extern) =>
			DeclKind.extern_,
		(in StructBodyAst.Flags) =>
			DeclKind.flags,
		(in StructBodyAst.Record) =>
			DeclKind.record,
		(in StructBodyAst.Variant) =>
			DeclKind.variant);

Opt!PurityAndForced purityAndForcedFromModifier(ModifierKeyword a) {
	switch (a) {
		case ModifierKeyword.data:
			return some(PurityAndForced(Purity.data, false));
		case ModifierKeyword.forceShared:
			return some(PurityAndForced(Purity.shared_, true));
		case ModifierKeyword.mut:
			return some(PurityAndForced(Purity.mut, false));
		case ModifierKeyword.shared_:
			return some(PurityAndForced(Purity.shared_, false));
		default:
			return none!PurityAndForced;
	}
}

void checkOnlyCommonModifiers(ref CheckCtx ctx, DeclKind declKind, in ModifierAst[] modifiers) {
	foreach (ref ModifierAst modifier; modifiers)
		if (!isCommonModifier(modifier))
			addDiag(ctx, modifier.range, modifier.matchIn!Diag(
				(in ModifierAst.Keyword x) =>
					x.keyword == ModifierKeyword.byVal
						? Diag(Diag.ModifierRedundantDueToDeclKind(x.keyword, declKind))
						: Diag(Diag.ModifierInvalid(x.keyword, declKind)),
				(in SpecUseAst _) =>
					Diag(Diag.SpecUseInvalid(declKind))));
}

bool isCommonModifier(in ModifierAst a) =>
	a.matchIn!bool(
		(in ModifierAst.Keyword x) =>
			x.keyword == ModifierKeyword.extern_ ||
			x.keyword == ModifierKeyword.summon ||
			x.keyword == ModifierKeyword.variantMember ||
			has(purityAndForcedFromModifier(x.keyword)),
		(in SpecUseAst _) =>
			false);

StructBody checkEnum(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* struct_,
	in Range range,
	in StructBodyAst.Enum e,
	IntegralType storage,
) {
	EnumOrFlagsMembers members = checkEnumOrFlagsMembers(
		ctx, commonTypes, structsAndAliasesMap, delayStructInsts,
		struct_, range, e.params, e.members, Diag.DuplicateDeclaration.Kind.enumMember, storage,
		(Opt!IntegralValue lastValue) =>
			has(lastValue)
				? ValueAndOverflow(
					IntegralValue(force(lastValue).value + 1),
					force(lastValue).asUnsigned() == maxValue(storage))
				: ValueAndOverflow(IntegralValue(0), false));
	if (isEmpty(members.members))
		addDiag(ctx, range, Diag(Diag.EmptyEnumOrUnion()));
	return StructBody(allocate(ctx.alloc, StructBody.Enum(storage, members.members, members.membersByName)));
}

StructBody.Flags checkFlags(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* struct_,
	in Range range,
	in StructBodyAst.Flags f,
	IntegralType storage,
) =>
	StructBody.Flags(storage, checkEnumOrFlagsMembers(
		ctx, commonTypes, structsAndAliasesMap, delayStructInsts,
		struct_, range, f.params, f.members, Diag.DuplicateDeclaration.Kind.flagsMember, storage,
		(Opt!IntegralValue lastValue) =>
			has(lastValue)
				? ValueAndOverflow(
					//TODO: if the last value isn't a power of 2, there should be a diagnostic
					IntegralValue(force(lastValue).value * 2),
					force(lastValue).value >= maxValue(storage) / 2)
				: ValueAndOverflow(IntegralValue(1), false)
	).members);

immutable struct ValueAndOverflow {
	IntegralValue value;
	bool overflow;
}

immutable struct EnumOrFlagsMembers {
	SmallArray!EnumOrFlagsMember members;
	HashTable!(EnumOrFlagsMember*, Symbol, nameOfEnumOrFlagsMember) membersByName; // TODO: SmallHashTable
}
EnumOrFlagsMembers checkEnumOrFlagsMembers(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* struct_,
	in Range range,
	in Opt!ParamsAst paramsAst,
	in EnumOrFlagsMemberAst[] memberAsts,
	Diag.DuplicateDeclaration.Kind memberKind,
	IntegralType storage,
	in ValueAndOverflow delegate(Opt!IntegralValue) @safe @nogc pure nothrow cbGetNextValue,
) {
	if (has(paramsAst) && !isEmpty(memberAsts)) {
		addDiag(ctx, struct_.nameRange.range, Diag(
			Diag.StructParamsSyntaxError(struct_, Diag.StructParamsSyntaxError.Reason.hasParamsAndFields)));
		return EnumOrFlagsMembers(
			emptySmallArray!EnumOrFlagsMember,
			HashTable!(EnumOrFlagsMember*, Symbol, nameOfEnumOrFlagsMember)());
	}

	MutOpt!long lastValue = noneMut!long;

	scope CbEnumValue cbValue = (Range range, Opt!LiteralIntegralAndRange literal) {
		IntegralValue value = () {
			if (has(literal))
				return checkLiteralIntegral(ctx, storage, force(literal));
			else {
				ValueAndOverflow valueAndOverflow = cbGetNextValue(optIf!IntegralValue(has(lastValue), () =>
					IntegralValue(force(lastValue))));
				if (valueAndOverflow.overflow)
					addDiag(ctx, range, Diag(Diag.LiteralOverflow(storage)));
				return valueAndOverflow.value;
			}
		}();
		lastValue = someMut!long(value.value);
		return value;
	};

	SmallArray!EnumOrFlagsMember members = has(paramsAst)
		? enumOrFlagsMembersFromParams(ctx, struct_, force(paramsAst), cbValue)
		: mapPointers(ctx.alloc, memberAsts, (EnumOrFlagsMemberAst* x) =>
			EnumOrFlagsMember(EnumMemberSource(x), struct_, cbValue(x.range, x.value)));

	HashTable!(EnumOrFlagsMember*, Symbol, nameOfEnumOrFlagsMember) membersByName =
		makeHashTable!(EnumOrFlagsMember, Symbol, nameOfEnumOrFlagsMember)(
			ctx.alloc, members, (EnumOrFlagsMember* duplicate) {
				addDiag(ctx, duplicate.nameRange.range, Diag(Diag.DuplicateDeclaration(memberKind, duplicate.name)));
			});
	eachPair!(EnumOrFlagsMember)(members, (in EnumOrFlagsMember a, in EnumOrFlagsMember b) {
		if (a.value == b.value)
			addDiag(ctx, b.range, Diag(
				Diag.EnumDuplicateValue(isSigned(storage), b.value.value)));
	});
	return EnumOrFlagsMembers(members, membersByName);
}

public IntegralValue checkLiteralIntegral(ref CheckCtx ctx, IntegralType type, LiteralIntegralAndRange ast) {
	if (ast.literal.overflow || literalNatOrIntOverflows(type, ast.literal.isSigned, ast.literal.value))
		addDiag(ctx, ast.range, Diag(Diag.LiteralOverflow(type)));
	return ast.literal.value;
}

bool literalNatOrIntOverflows(IntegralType type, bool isSigned, IntegralValue value) =>
	isSigned
		? (value.asSigned < minValue(type) || (value.asSigned > 0 && value.asSigned > maxValue(type)))
		: value.asUnsigned > maxValue(type);

alias CbEnumValue = IntegralValue delegate(Range range, Opt!LiteralIntegralAndRange) @safe @nogc pure nothrow;

SmallArray!EnumOrFlagsMember enumOrFlagsMembersFromParams(
	ref CheckCtx ctx,
	StructDecl* enumOrFlags,
	in ParamsAst params,
	in CbEnumValue cbValue,
) =>
	params.match!(SmallArray!EnumOrFlagsMember)(
		(DestructureAst[] destructures) =>
			mapOpPointers!(EnumOrFlagsMember, DestructureAst)(
				ctx.alloc, small!DestructureAst(destructures), (DestructureAst* x) =>
					enumMemberFromParam(ctx, enumOrFlags, x, cbValue(x.range, none!LiteralIntegralAndRange))),
		(ref ParamsAst.Varargs x) {
			addDiag(ctx, x.param.range, Diag(
				Diag.StructParamsSyntaxError(enumOrFlags, Diag.StructParamsSyntaxError.Reason.variadic)));
			return emptySmallArray!EnumOrFlagsMember;
		});

IntegralType defaultEnumBackingType() =>
	IntegralType.nat32;

IntegralType getEnumTypeFromType(
	ref CheckCtx ctx,
	StructDecl* struct_,
	in Range range,
	in CommonTypes commonTypes,
	in Type type,
) {
	IntegralTypes integrals = commonTypes.integrals;
	return type.matchWithPointers!IntegralType(
		(Type.Bogus) =>
			defaultEnumBackingType(),
		(TypeParamIndex _) =>
			// enums can't have type params
			assert(false),
		(StructInst* x) =>
			x == integrals.int8
				? IntegralType.int8
				: x == integrals.int16
				? IntegralType.int16
				: x == integrals.int32
				? IntegralType.int32
				: x == integrals.int64
				? IntegralType.int64
				: x == integrals.nat8
				? IntegralType.nat8
				: x == integrals.nat16
				? IntegralType.nat16
				: x == integrals.nat32
				? IntegralType.nat32
				: x == integrals.nat64
				? IntegralType.nat64
				: (() {
					addDiag(ctx, range, Diag(Diag.EnumBackingTypeInvalid(struct_, Type(x))));
					return defaultEnumBackingType();
				})());
}

StructBody.Record checkRecord(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	StructDecl* struct_,
	ModifierAst[] modifierAsts,
	ref StructBodyAst.Record ast,
	scope ref DelayStructInsts delayStructInsts,
) {
	RecordModifiers modifiers = accumulateRecordModifiers(ctx, modifierAsts);
	bool externForcesByVal = struct_.linkage != Linkage.internal && struct_.externSet != symbolSet(symbol!"js");
	Opt!ByValOrRef valOrRef = externForcesByVal
		? some(ByValOrRef.byVal)
		: has(modifiers.byValOrRef)
		? some(enumConvertOrAssert!ByValOrRef(force(modifiers.byValOrRef).keyword))
		: none!ByValOrRef;
	if (externForcesByVal && has(modifiers.byValOrRef))
		addDiag(ctx, force(modifiers.byValOrRef).keywordRange, Diag(Diag.ExternRecordImplicitlyByVal(struct_)));

	SmallArray!RecordField fields = checkRecordOrUnionMembers!RecordField(
		ctx, struct_, ast.params, ast.fields, Diag.DuplicateDeclaration.Kind.recordField,
		(RecordOrUnionMemberAstCommon fieldAst) =>
			checkRecordField(ctx, commonTypes, structsAndAliasesMap, delayStructInsts, struct_, fieldAst));
	RecordFlags flags = RecordFlags(
		newVisibility: recordNewVisibility(ctx, struct_, fields, modifiers),
		nominal: has(modifiers.nominal),
		packed: has(modifiers.packed),
		forcedByValOrRef: valOrRef);
	return StructBody.Record(flags, fields);
}

// Shared in common between DestructureAst.Single and RecordOrUnionMemberAst
struct RecordOrUnionMemberAstCommon {
	RecordOrUnionMemberSource source;
	Opt!VisibilityAndRange visibility;
	NameAndRange name;
	Opt!FieldMutabilityAst mutability;
	Opt!TypeAst type;
}

alias CbCheckMember(Member) = Member delegate(RecordOrUnionMemberAstCommon) @safe @nogc pure nothrow;

SmallArray!Member checkRecordOrUnionMembers(Member)( // TODO: this will only be for record now? -----------------------------
	ref CheckCtx ctx,
	StructDecl* struct_,
	Opt!ParamsAst params,
	SmallArray!RecordOrUnionMemberAst memberAsts,
	Diag.DuplicateDeclaration.Kind duplicateDeclarationKind,
	in CbCheckMember!Member cbCheckMember,
) {
	if (has(params) && !isEmpty(memberAsts))
		addDiag(ctx, struct_.nameRange.range, Diag(
			Diag.StructParamsSyntaxError(struct_, Diag.StructParamsSyntaxError.Reason.hasParamsAndFields)));
	SmallArray!Member res = has(params)
		? recordOrUnionMembersFromParams!Member(ctx, struct_, force(params), cbCheckMember)
		: mapPointers!(Member, RecordOrUnionMemberAst)(
			ctx.alloc, memberAsts, (RecordOrUnionMemberAst* x) =>
				cbCheckMember(RecordOrUnionMemberAstCommon(
					RecordOrUnionMemberSource(x), x.visibility, x.name, x.mutability, x.type)));
	eachPair!Member(res, (in Member a, in Member b) {
		if (a.name == b.name)
			addDiag(ctx, b.range, Diag(Diag.DuplicateDeclaration(duplicateDeclarationKind, a.name)));
	});
	return res;
}

SmallArray!Member recordOrUnionMembersFromParams(Member)(
	ref CheckCtx ctx,
	StructDecl* struct_,
	ParamsAst ast,
	in CbCheckMember!Member cbCheckMember,
) =>
	ast.match!(SmallArray!Member)(
		(DestructureAst[] destructures) =>
			mapOpPointers!(Member, DestructureAst)(
				ctx.alloc, small!DestructureAst(destructures), (DestructureAst* param) =>
					recordOrUnionMemberFromParam!Member(ctx, struct_, param, cbCheckMember)),
		(ref ParamsAst.Varargs x) {
			addDiag(ctx, x.param.range, Diag(
				Diag.StructParamsSyntaxError(struct_, Diag.StructParamsSyntaxError.Reason.variadic)));
			return emptySmallArray!Member;
		});

Opt!EnumOrFlagsMember enumMemberFromParam(
	ref CheckCtx ctx,
	StructDecl* enum_,
	DestructureAst* ast,
	IntegralValue value,
) {
	if (ast.isA!(DestructureAst.Single)) {
		DestructureAst.Single* single = &ast.as!(DestructureAst.Single)();
		if (has(single.mut)) {
			Opt!Range mutRange = single.mutRange;
			addDiag(ctx, force(mutRange), Diag(
				Diag.UnsupportedSyntax(Diag.UnsupportedSyntax.Reason.enumMemberMutability)));
		}
		if (has(single.type))
			addDiag(ctx, force(single.type).range, Diag(
				Diag.UnsupportedSyntax(Diag.UnsupportedSyntax.Reason.enumMemberType)));
		return some(EnumOrFlagsMember(EnumMemberSource(single), enum_, value));
	} else {
		addDiag(ctx, ast.range, Diag(
			Diag.StructParamsSyntaxError(enum_, Diag.StructParamsSyntaxError.Reason.destructure)));
		return none!EnumOrFlagsMember;
	}
}

Opt!Member recordOrUnionMemberFromParam(Member)(
	ref CheckCtx ctx,
	StructDecl* struct_,
	DestructureAst* ast,
	in CbCheckMember!Member cbCheckMember,
) {
	if (ast.isA!(DestructureAst.Single)) {
		DestructureAst.Single* single = &ast.as!(DestructureAst.Single)();
		return some(cbCheckMember(RecordOrUnionMemberAstCommon(
			RecordOrUnionMemberSource(single),
			none!VisibilityAndRange,
			single.name,
			has(single.mut) ? some(FieldMutabilityAst(force(single.mut), none!Visibility)) : none!FieldMutabilityAst,
			has(single.type) ? some(*force(single.type)) : none!TypeAst)));
	} else {
		addDiag(ctx, ast.range, Diag(
			Diag.StructParamsSyntaxError(struct_, Diag.StructParamsSyntaxError.Reason.destructure)));
		return none!Member;
	}
}

RecordField checkRecordField(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* record,
	RecordOrUnionMemberAstCommon ast,
) {
	Symbol name = ast.name.name;
	Type memberType = has(ast.type)
		? typeFromAst(
			ctx, commonTypes, structsAndAliasesMap, force(ast.type),
			record.typeParams, someMut(ptrTrustMe(delayStructInsts)), AliasAllowed.yes)
		: () {
			addDiag(ctx, ast.name.range, Diag(Diag.RecordFieldNeedsType(name)));
			return Type.bogus;
		}();
	checkReferenceLinkageAndPurity(ctx, record, ast.source.range, memberType);

	if (has(ast.mutability) && record.purity != Purity.mut && !record.purityIsForced)
		addDiag(ctx, force(ast.mutability).range, Diag(Diag.MutFieldNotAllowed()));
	Visibility visibility = visibilityFromDefaultWithDiag(ctx, record.visibility, ast.visibility,
		Diag.VisibilityWarning.Kind(Diag.VisibilityWarning.Kind.Field(record, name)));
	Opt!Visibility mutability = has(ast.mutability)
		? some(visibilityFromDefaultWithDiag(
			ctx, visibility, force(ast.mutability).visibility,
			Diag.VisibilityWarning.Kind(Diag.VisibilityWarning.Kind.FieldMutability(name))))
		: none!Visibility;
	return RecordField(ast.source, record, visibility, mutability, memberType);
}

IntegralType checkEnumOrFlagsModifiers(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	ref StructsAndAliasesMap structsAndAliasesMap,
	scope ref DelayStructInsts delayStructInsts,
	StructDecl* struct_,
	DeclKind declKind,
	ModifierAst[] modifiers,
	bool isFlags,
) {
	MutOpt!(ModifierAst.Keyword*) storage;
	foreach (ref ModifierAst modifier; modifiers) {
		if (!isCommonModifier(modifier)) {
			if (modifier.isA!(ModifierAst.Keyword)) {
				ModifierAst.Keyword* x = &modifier.as!(ModifierAst.Keyword)();
				if (x.keyword == ModifierKeyword.storage) {
					if (has(storage))
						addDiag(ctx, x.keywordRange, Diag(Diag.ModifierDuplicate(ModifierKeyword.storage)));
					else
						storage = someMut(x);
				} else
					addDiag(ctx, x.keywordRange, x.keyword == ModifierKeyword.byVal
						? Diag(Diag.ModifierRedundantDueToDeclKind(x.keyword, declKind))
						: Diag(Diag.ModifierInvalid(x.keyword, declKind)));
			} else
				addDiag(ctx, modifier.range, Diag(Diag.SpecUseInvalid(declKind)));
		}
	}

	if (has(storage)) {
		ModifierAst.Keyword* x = force(storage);
		if (has(x.typeArg)) {
			Type type = typeFromAst(
				ctx, commonTypes, structsAndAliasesMap,
				force(x.typeArg), emptyTypeParams, someMut(ptrTrustMe(delayStructInsts)), AliasAllowed.yes);
			IntegralType res = getEnumTypeFromType(ctx, struct_, force(x.typeArg).range, commonTypes, type);
			if (isFlags && isSigned(res))
				addDiag(ctx, x.keywordRange, Diag(Diag.FlagsSigned()));
			return res;
		} else {
			addDiag(ctx, x.keywordRange, Diag(Diag.StorageMissingType()));
			return IntegralType.nat32;
		}
	} else
		return IntegralType.nat32;
}

immutable struct RecordModifiers {
	Opt!(ModifierAst.Keyword*) byValOrRef;
	Opt!(ModifierAst.Keyword*) newVisibility;
	Opt!(ModifierAst.Keyword*) nominal;
	Opt!(ModifierAst.Keyword*) packed;
}

void accumulateModifier(ref CheckCtx ctx, ref MutOpt!(ModifierAst.Keyword*) old, ModifierAst.Keyword* new_) {
	if (has(old)) {
		ModifierKeyword oldKeyword = force(old).keyword;
		addDiag(ctx, new_.keywordRange, new_.keyword == oldKeyword
			? Diag(Diag.ModifierDuplicate(new_.keyword))
			: Diag(Diag.ModifierConflict(oldKeyword, new_.keyword)));
	}
	old = someMut(new_);
}

RecordModifiers accumulateRecordModifiers(ref CheckCtx ctx, ModifierAst[] modifiers) {
	MutOpt!(ModifierAst.Keyword*) byValOrRef;
	MutOpt!(ModifierAst.Keyword*) newVisibility;
	MutOpt!(ModifierAst.Keyword*) nominal;
	MutOpt!(ModifierAst.Keyword*) packed;

	foreach (ref ModifierAst modifier; modifiers) {
		if (modifier.isA!(ModifierAst.Keyword)) {
			ModifierAst.Keyword* x = &modifier.as!(ModifierAst.Keyword)();
			switch (x.keyword) {
				case ModifierKeyword.byRef:
				case ModifierKeyword.byVal:
					accumulateModifier(ctx, byValOrRef, x);
					break;
				case ModifierKeyword.newInternal:
				case ModifierKeyword.newPrivate:
				case ModifierKeyword.newPublic:
					accumulateModifier(ctx, newVisibility, x);
					break;
				case ModifierKeyword.nominal:
					accumulateModifier(ctx, nominal, x);
					break;
				case ModifierKeyword.packed:
					accumulateModifier(ctx, packed, x);
					break;
				default:
					if (!isCommonModifier(modifier))
						addDiag(ctx, x.keywordRange, Diag(Diag.ModifierInvalid(x.keyword, DeclKind.record)));
					break;
			}
		} else
			addDiag(ctx, modifier.range, Diag(Diag.SpecUseInvalid(DeclKind.record)));
	}
	modifierTypeArgInvalid(ctx, [byValOrRef, newVisibility, nominal, packed]);
	return RecordModifiers(
		byValOrRef: optFromMut!(ModifierAst.Keyword*)(byValOrRef),
		newVisibility: optFromMut!(ModifierAst.Keyword*)(newVisibility),
		nominal: optFromMut!(ModifierAst.Keyword*)(nominal),
		packed: optFromMut!(ModifierAst.Keyword*)(packed));
}

void checkReferenceLinkageAndPurity(ref CheckCtx ctx, StructDecl* struct_, in Range range, Type referencedType) {
	if (!isLinkagePossiblyCompatible(struct_.linkage, linkageRange(referencedType)))
		addDiag(ctx, range, Diag(Diag.LinkageWorseThanContainingType(struct_, referencedType)));
	checkReferencePurity(ctx, struct_, range, referencedType);
}

void checkReferencePurity(ref CheckCtx ctx, StructDecl* struct_, in Range range, Type referencedType) {
	if (!isPurityPossiblyCompatible(referencer: struct_.purity, referenced: purityRange(referencedType)) &&
		!struct_.purityIsForced)
		addDiag(ctx, range, Diag(Diag.PurityWorseThanParent(struct_, referencedType)));
}

Visibility recordNewVisibility(
	ref CheckCtx ctx,
	StructDecl* record,
	in RecordField[] fields,
	in RecordModifiers modifiers,
) {
	Visibility default_ = fold!(Visibility, RecordField)(
		record.visibility, fields, (Visibility cur, in RecordField field) =>
			leastVisibility(cur, field.visibility));
	Opt!VisibilityAndRange explicit = has(modifiers.newVisibility)
		? some(VisibilityAndRange(
			visibilityFromNewVisibility(force(modifiers.newVisibility).keyword),
			force(modifiers.newVisibility).keywordPos))
		: none!VisibilityAndRange;
	return visibilityFromDefaultWithDiag(ctx, default_, explicit, Diag.VisibilityWarning.Kind(
		Diag.VisibilityWarning.Kind.New(record)));
}

Visibility visibilityFromNewVisibility(ModifierKeyword a) {
	switch (a) {
		case ModifierKeyword.newPrivate:
			return Visibility.private_;
		case ModifierKeyword.newInternal:
			return Visibility.internal;
		case ModifierKeyword.newPublic:
			return Visibility.public_;
		default:
			assert(false);
	}
}

BuiltinType getBuiltinType(scope ref CheckCtx ctx, StructDecl* struct_) {
	switch (struct_.name.value) {
		case symbol!"array".value:
			return BuiltinType.array;
		case symbol!"bool".value:
			return BuiltinType.bool_;
		case symbol!"char8".value:
			return BuiltinType.char8;
		case symbol!"char32".value:
			return BuiltinType.char32;
		case symbol!"float32".value:
			return BuiltinType.float32;
		case symbol!"float64".value:
			return BuiltinType.float64;
		case symbol!"fun-data".value:
		case symbol!"fun-shared".value:
		case symbol!"fun-mut".value:
			return BuiltinType.lambda;
		case symbol!"fun-pointer".value:
			return BuiltinType.funPointer;
		case symbol!"future".value:
			return BuiltinType.future;
		case symbol!"int8".value:
			return BuiltinType.int8;
		case symbol!"int16".value:
			return BuiltinType.int16;
		case symbol!"int32".value:
			return BuiltinType.int32;
		case symbol!"int64".value:
			return BuiltinType.int64;
		case symbol!"js-any".value:
			return BuiltinType.jsAny;
		case symbol!"mut-array".value:
			return BuiltinType.mutArray;
		case symbol!"mut-slice".value:
			return BuiltinType.mutSlice;
		case symbol!"nat8".value:
			return BuiltinType.nat8;
		case symbol!"nat16".value:
			return BuiltinType.nat16;
		case symbol!"nat32".value:
			return BuiltinType.nat32;
		case symbol!"nat64".value:
			return BuiltinType.nat64;
		case symbol!"catch-point".value:
			return BuiltinType.catchPoint;
		case symbol!"const-pointer".value:
			return BuiltinType.pointerConst;
		case symbol!"mut-pointer".value:
			return BuiltinType.pointerMut;
		case symbol!"option".value:
			return BuiltinType.option;
		case symbol!"string".value:
			return BuiltinType.string_;
		case symbol!"symbol".value:
			return BuiltinType.symbol;
		case symbol!"void".value:
			return BuiltinType.void_;
		default:
			addDiagAssertSameUri(ctx, struct_.nameRange, Diag(
				Diag.BuiltinUnsupported(Diag.BuiltinUnsupported.Kind.type, struct_.name)));
			return BuiltinType.void_;
	}
}
