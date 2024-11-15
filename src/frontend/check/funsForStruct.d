module frontend.check.funsForStruct;

@safe @nogc pure nothrow:

import frontend.check.checkCtx : CheckCtx;
import frontend.check.getCommonFuns : makeParam, makeParams, param;
import frontend.check.inferringType : FunType, getFunType;
import frontend.check.instantiate :
	InstantiateCtx,
	instantiateStructWithOwnTypeParams,
	instantiateStructNeverDelay,
	makeConstPointerType,
	makeMutPointerType,
	makeOptionType;
import model.model :
	asTuple,
	BuiltinType,
	ByValOrRef,
	CommonTypes,
	Destructure,
	DestructureIgnoreSource,
	isVoid,
	EnumOrFlagsMember,
	FlagsFunction,
	FunBody,
	FunDecl,
	FunDeclSource,
	FunFlags,
	Params,
	ParamShort,
	RecordField,
	Signature,
	SpecInst,
	StructBody,
	StructDecl,
	StructInst,
	Type,
	TypeParamIndex,
	VarDecl,
	VariantAndMethodImpls,
	VariantKind,
	VariantMemberAndMethodImpls,
	Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : withStackArray;
import util.col.array : count, isEmpty, map, mapWithFirst, prepend, small, sum;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder;
import util.conv : safeToUint;
import util.memory : allocate;
import util.opt : force, has, Opt, optEqual, some;
import util.symbol : prependSet, prependSetDeref, Symbol, symbol;
import util.symbolSet : emptySymbolSet, SymbolSet, symbolSet;

size_t countFunsForStructs(in CommonTypes commonTypes, in StructDecl[] structs) =>
	sum!StructDecl(structs, (in StructDecl x) => countFunsForStruct(commonTypes, x));

private size_t countFunsForStruct(in CommonTypes commonTypes, in StructDecl a) =>
	countFunsForVariantMembers(a) + a.body_.matchIn!size_t(
		(in StructBody.Bogus) =>
			0,
		(in BuiltinType _) =>
			0,
		(in StructBody.Enum x) =>
			// constructor for each member
			x.members.length,
		(in StructBody.Extern x) =>
			size_t(has(x.size) ? 1 : 0),
		(in StructBody.Flags x) =>
			// 'new', '~', '&', '|', 'in', and a constructor for each member
			5 + x.members.length,
		(in StructBody.Record x) {
			size_t forGetSet = sum!RecordField(x.fields, (in RecordField field) =>
				1 + has(field.mutability));
			size_t forCall = sum!RecordField(x.fields, (in RecordField field) =>
				fieldHasCaller(commonTypes, field.type));
			// byVal has get/set for pointer too
			return 1 + forGetSet * (recordIsAlwaysByVal(x) ? 2 : 1) + forCall;
		},
		(in StructBody.Variant x) =>
			x.methods.length + sum!VariantMemberAndMethodImpls(x.listedMembers, (in VariantMemberAndMethodImpls member) =>
				countFunsForVariantMember(x, *member.member.decl)));
private size_t countFunsForVariantMembers(in StructDecl a) =>
	sum!VariantAndMethodImpls(a.variants, (in VariantAndMethodImpls x) =>
		countFunsForVariantMember(x.variant.decl.body_.as!(StructBody.Variant), a));
private size_t countFunsForVariantMember(in StructBody.Variant variant, in StructDecl member) {
	// Records will also have a named constructor returning the variant
	size_t res = member.body_.isA!(StructBody.Record) ? 2 : 1;
	final switch (variant.kind) {
		case VariantKind.interface_:
			return res;
		case VariantKind.union_:
		case VariantKind.variant:
			return res + 1;
	}
}

size_t countFunsForVars(in VarDecl[] vars) =>
	vars.length * 2;

void addFunsForStruct(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
) {
	struct_.body_.match!void(
		(StructBody.Bogus) {},
		(BuiltinType _) {},
		(ref StructBody.Enum x) {
			addFunsForEnum(ctx, funsBuilder, commonTypes, struct_, x);
		},
		(StructBody.Extern x) {
			if (has(x.size))
				funsBuilder ~= newExtern(ctx.instantiateCtx, struct_);
		},
		(StructBody.Flags x) {
			addFunsForFlags(ctx, funsBuilder, commonTypes, struct_, x);
		},
		(StructBody.Record x) {
			addFunsForRecord(ctx, funsBuilder, commonTypes, struct_, x);
		},
		(StructBody.Variant x) {
			addFunsForVariant(ctx, funsBuilder, commonTypes, struct_, x);
		});
	addFunsForVariantMembers(ctx, funsBuilder, commonTypes, struct_);
}

private void addFunsForVariantMembers(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
) {
	foreach (VariantAndMethodImpls vm; struct_.variants) {
		addFunsForVariantMember(
			ctx, funsBuilder, commonTypes,
			sourceStruct: struct_,
			variant: vm.variant,
			memberType: instantiateStructWithOwnTypeParams(ctx.instantiateCtx, struct_));
	}
}

private void addFunsForVariantMember(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* sourceStruct,
	StructInst* variant,
	StructInst* memberType,
) {
	VariantKind variantKind = variant.decl.body_.as!(StructBody.Variant).kind;
	StructDecl* member = memberType.decl;
	// Convert from the type to a variant
	funsBuilder ~= funForStruct(
		sourceStruct,
		symbol!"to",
		Type(variant),
		makeParams(ctx.alloc, [param!"a"(Type(memberType))]),
		FunFlags.generatedBare,
		FunBody(FunBody.CreateVariant()));
	if (member.body_.isA!(StructBody.Record)) {
		ref StructBody.Record record() => member.body_.as!(StructBody.Record);
		funsBuilder ~= funForStruct(
			sourceStruct,
			member.name,
			Type(variant),
			recordConstructorParams(ctx.alloc, record),
			recordIsAlwaysByVal(record) ? FunFlags.generatedBare : FunFlags.generated,
			FunBody(FunBody.CreateRecordAndConvertToVariant(memberType)));
	}
	final switch (variantKind) {
		case VariantKind.interface_:
			break;
		case VariantKind.union_:
		case VariantKind.variant:
			funsBuilder ~= funForStruct(
				sourceStruct,
				member.name,
				Type(makeOptionType(ctx.instantiateCtx, commonTypes, Type(memberType))),
				makeParams(ctx.alloc, [param!"a"(Type(variant))]),
				FunFlags.generatedBare,
				FunBody(FunBody.VariantMemberGet()));
			break;
	}
}

void addFunsForVar(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	in CommonTypes commonTypes,
	VarDecl* var,
) {
	SymbolSet extern_ = has(var.externLibraryName) ? symbolSet(force(var.externLibraryName)) : emptySymbolSet;
	funsBuilder ~= basicFunDecl(
		FunDeclSource(var),
		var.visibility,
		var.name,
		var.type,
		Params([]),
		FunFlags.generatedBareUnsafe,
		extern_,
		FunBody(FunBody.VarGet(var)));
	funsBuilder ~= basicFunDecl(
		FunDeclSource(var),
		var.visibility,
		prependSet(var.name),
		Type(commonTypes.void_),
		makeParams(ctx.alloc, [param!"a"(var.type)]),
		FunFlags.generatedBareUnsafe,
		extern_,
		FunBody(FunBody.VarSet(var)));
}

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

private:

FunDecl funForStruct(
	StructDecl* struct_,
	Symbol name,
	Type returnType,
	Params params,
	FunFlags flags,
	FunBody body_,
) {
	assert(!flags.summon);
	return basicFunDecl(
		FunDeclSource(struct_),
		struct_.visibility,
		name,
		returnType,
		params,
		flags.withSummon(struct_.isSummon),
		struct_.externSet,
		body_);
}

FunDecl basicFunDecl(
	FunDeclSource source,
	Visibility visibility,
	Symbol name,
	Type returnType,
	Params params,
	FunFlags flags,
	SymbolSet extern_,
	FunBody body_,
) =>
	funDeclWithBody(source, visibility, name, returnType, params, flags, extern_, [], body_);

FunDecl newExtern(InstantiateCtx ctx, StructDecl* struct_) =>
	funForStruct(
		struct_,
		symbol!"new",
		Type(instantiateNonTemplateStructDeclNeverDelay(ctx, struct_)),
		Params([]),
		FunFlags.generatedBareUnsafe,
		FunBody(FunBody.CreateExtern()));

StructInst* instantiateNonTemplateStructDeclNeverDelay(InstantiateCtx ctx, StructDecl* structDecl) =>
	instantiateStructNeverDelay(ctx, structDecl, []);

bool recordIsAlwaysByVal(in StructBody.Record record) =>
	isEmpty(record.fields) || optEqual!ByValOrRef(record.flags.forcedByValOrRef, some(ByValOrRef.byVal));

void addFunsForEnum(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	ref StructBody.Enum enum_,
) {
	StructInst* inst = instantiateNonTemplateStructDeclNeverDelay(ctx.instantiateCtx, struct_);
	foreach (ref EnumOrFlagsMember member; enum_.members)
		funsBuilder ~= enumOrFlagsConstructor(ctx.alloc, struct_.visibility, inst, &member);
}

void addFunsForFlags(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	ref StructBody.Flags flags,
) {
	StructInst* inst = instantiateNonTemplateStructDeclNeverDelay(ctx.instantiateCtx, struct_);
	FunDecl make(Symbol name, Type returnType, in ParamShort[] params, FlagsFunction fun) =>
		funForStruct(
			struct_,
			name,
			returnType,
			makeParams(ctx.alloc, params),
			FunFlags.generatedBare,
			FunBody(fun));
	Type type = Type(inst);
	funsBuilder ~= make(symbol!"new", type, [], FlagsFunction.none);
	funsBuilder ~= make(symbol!"~", type, [param!"a"(type)], FlagsFunction.negate);
	funsBuilder ~= make(symbol!"|", type, [param!"a"(type), param!"b"(type)], FlagsFunction.union_);
	funsBuilder ~= make(symbol!"&", type, [param!"a"(type), param!"b"(type)], FlagsFunction.intersect);
	funsBuilder ~= make(symbol!"in", Type(commonTypes.bool_), [param!"a"(type), param!"b"(type)], FlagsFunction.in_);

	foreach (ref EnumOrFlagsMember member; flags.members)
		funsBuilder ~= enumOrFlagsConstructor(ctx.alloc, struct_.visibility, inst, &member);
}

FunDecl enumOrFlagsConstructor(ref Alloc alloc, Visibility visibility, StructInst* enum_, EnumOrFlagsMember* member) =>
	basicFunDecl(
		FunDeclSource(member),
		visibility,
		member.name,
		Type(enum_),
		Params([]),
		FunFlags.generatedBare.withSummon(enum_.decl.isSummon),
		enum_.decl.externSet,
		FunBody(FunBody.CreateEnumOrFlags(member)));

void addFunsForRecord(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	ref StructBody.Record record,
) {
	Type structType = instantiateStructWithTypeArgsFromParams(ctx, struct_);
	bool byVal = recordIsAlwaysByVal(record);
	addFunsForRecordConstructor(ctx, funsBuilder, commonTypes, struct_, record, structType, byVal);
	foreach (ref RecordField field; record.fields)
		addFunsForRecordField(ctx, funsBuilder, commonTypes, struct_, structType, byVal, &field);
}

Type instantiateStructWithTypeArgsFromParams(ref CheckCtx ctx, StructDecl* struct_) =>
	withStackArray!(Type, Type)(
		struct_.typeParams.length,
		(size_t i) => Type(TypeParamIndex(safeToUint(i))),
		(scope Type[] typeArgs) => Type(instantiateStructNeverDelay(ctx.instantiateCtx, struct_, typeArgs)));

void addFunsForRecordConstructor(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	ref StructBody.Record record,
	Type structType,
	bool byVal,
) {
	funsBuilder ~= funDeclWithBody(
		FunDeclSource(struct_),
		record.flags.newVisibility,
		record.flags.nominal ? struct_.name : symbol!"new",
		structType,
		recordConstructorParams(ctx.alloc, record),
		(byVal ? FunFlags.generatedBare : FunFlags.generated).withSummon(struct_.isSummon),
		struct_.externSet,
		[],
		FunBody(FunBody.CreateRecord()));
}

Params recordConstructorParams(ref Alloc alloc, ref StructBody.Record record) =>
	Params(map(alloc, record.fields, (ref RecordField x) =>
		makeParam(alloc, ParamShort(x.name, x.type))));

void addFunsForRecordField(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	Type recordType,
	bool recordIsByVal,
	RecordField* field,
) {
	funsBuilder ~= funDeclWithBody(
		FunDeclSource(field),
		field.visibility,
		field.name,
		field.type,
		makeParams(ctx.alloc, [param!"a"(recordType)]),
		FunFlags.generatedBare.withSummon(struct_.isSummon),
		struct_.externSet,
		[],
		FunBody(FunBody.RecordFieldGet(field)));

	void addRecordFieldPointer(Visibility visibility, Type recordPointer, Type fieldPointer) {
		funsBuilder ~= funDeclWithBody(
			FunDeclSource(field),
			visibility,
			field.name,
			fieldPointer,
			makeParams(ctx.alloc, [param!"a"(recordPointer)]),
			FunFlags.generatedBareUnsafe.withSummon(struct_.isSummon),
			struct_.externSet,
			[],
			FunBody(FunBody.RecordFieldPointer(field)));
	}

	maybeAddFieldCaller(ctx, funsBuilder, commonTypes, struct_, recordType, field);

	if (recordIsByVal)
		addRecordFieldPointer(
			field.visibility,
			Type(makeConstPointerType(ctx.instantiateCtx, commonTypes, recordType)),
			Type(makeConstPointerType(ctx.instantiateCtx, commonTypes, field.type)));

	if (has(field.mutability)) {
		Visibility setVisibility = force(field.mutability);
		Type recordMutPointer = Type(makeMutPointerType(ctx.instantiateCtx, commonTypes, recordType));
		if (recordIsByVal) {
			funsBuilder ~= funDeclWithBody(
				FunDeclSource(field),
				setVisibility,
				prependSetDeref(field.name),
				Type(commonTypes.void_),
				makeParams(ctx.alloc, [
					param!"a"(recordMutPointer),
					ParamShort(field.name, field.type),
				]),
				FunFlags.generatedBareUnsafe.withSummon(struct_.isSummon),
				struct_.externSet,
				[],
				FunBody(FunBody.RecordFieldSet(field)));
			addRecordFieldPointer(
				setVisibility,
				recordMutPointer,
				Type(makeMutPointerType(ctx.instantiateCtx, commonTypes, field.type)));
		} else
			funsBuilder ~= funDeclWithBody(
				FunDeclSource(field),
				setVisibility,
				prependSet(field.name),
				Type(commonTypes.void_),
				makeParams(ctx.alloc, [param!"a"(recordType), ParamShort(field.name, field.type)]),
				FunFlags.generatedBare.withSummon(struct_.isSummon),
				struct_.externSet,
				[],
				FunBody(FunBody.RecordFieldSet(field)));
	}
}

bool fieldHasCaller(in CommonTypes commonTypes, Type fieldType) {
	Opt!FunType optFunType = getFunType(commonTypes, fieldType);
	return has(optFunType);
}

void maybeAddFieldCaller(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	Type recordType,
	RecordField* field,
) {
	Opt!FunType optFunType = getFunType(commonTypes, field.type);
	if (has(optFunType)) {
		FunType funType = force(optFunType);
		Params params = paramsForFieldCaller(ctx.alloc, commonTypes, recordType, funType.paramType);
		funsBuilder ~= funDeclWithBody(
			FunDeclSource(field),
			field.visibility,
			field.name,
			funType.returnType,
			params,
			FunFlags.generated.withOkIfUnused.withSummon(struct_.isSummon),
			struct_.externSet,
			[],
			FunBody(FunBody.RecordFieldCall(field, funType.kind)));
	}
}

Params paramsForFieldCaller(ref Alloc alloc, ref CommonTypes commonTypes, Type recordType, Type paramType) {
	Opt!(Type[]) parts = asTuple(commonTypes, paramType);
	ParamShort paramA = param!"a"(recordType);
	return has(parts)
		? makeParams(alloc, mapWithFirst!(ParamShort, Type)(alloc, paramA, force(parts), (size_t i, ref Type type) =>
			ParamShort(symbolForParam(i), type)))
		: paramType == Type(commonTypes.void_)
		? makeParams(alloc, [paramA])
		: makeParams(alloc, [paramA, ParamShort(symbol!"param", paramType)]);
}

Symbol symbolForParam(size_t index) {
	final switch (index) {
		case 0: return symbol!"param0";
		case 1: return symbol!"param1";
		case 2: return symbol!"param2";
		case 3: return symbol!"param3";
		case 4: return symbol!"param4";
		case 5: return symbol!"param5";
		case 6: return symbol!"param6";
		case 7: return symbol!"param7";
		case 8: return symbol!"param8";
		case 9: return symbol!"param9";
	}
}

void addFunsForVariant(
	ref CheckCtx ctx,
	scope ref ExactSizeArrayBuilder!FunDecl funsBuilder,
	ref CommonTypes commonTypes,
	StructDecl* struct_,
	ref StructBody.Variant variant,
) {
	StructInst* variantInst = instantiateStructWithOwnTypeParams(ctx.instantiateCtx, struct_);

	foreach (ref VariantMemberAndMethodImpls x; variant.listedMembers)
		addFunsForVariantMember(
			ctx, funsBuilder, commonTypes,
			sourceStruct: struct_, variant: variantInst, memberType: x.member);

	foreach (ref Signature sig; variant.methods)
		funsBuilder ~= funDeclWithBody(
			FunDeclSource(&sig),
			struct_.visibility,
			sig.name,
			sig.returnType,
			Params(prepend(ctx.alloc,
				Destructure(allocate(ctx.alloc, Destructure.Ignore(
					DestructureIgnoreSource(struct_),
					sig.ast.range.start,
					Type(variantInst)))),
				sig.params)),
			FunFlags.generated.withSummon(struct_.isSummon),
			struct_.externSet,
			[],
			FunBody(FunBody.VariantMethod(&sig)));
}
