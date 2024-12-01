module frontend.ide.getPosition;

@safe @nogc pure nothrow:

import frontend.ide.ideUtil : findInPackedTypeArgs, eachTypeComponent, specsMatch;
import frontend.ide.position :
	asLocalContainer,
	DocCommentContainer,
	ExpressionPosition,
	ExpressionPositionKind,
	ExprContainer,
	ExpressionPositionLiteral,
	ExprKeyword,
	LocalContainer,
	LocalRef,
	LocalRefKind,
	LoopKeyword,
	LoopKeywordKind,
	Position,
	PositionDocRef,
	PositionImportedModule,
	PositionImportedName,
	PositionKeyword,
	PositionKind,
	PositionLocal,
	PositionMatchEnumCase,
	PositionMatchIntegralCase,
	PositionMatchStringLikeCase,
	PositionMatchSumTypeCase,
	PositionModifier,
	PositionModifierExtern,
	PositionModule,
	PositionRecordFieldMutability,
	PositionSpecUse,
	PositionVisibilityMark,
	TypeParamWithContainer,
	VisibilityContainer;
import frontend.parse.lexWhitespace : walkBackwardsForPosition;
import lib.lsp.lspTypes : TextDocumentPositionParams;
import model.ast :
	ArrowAccessAst,
	AsNameAst,
	AssignmentAst,
	AssignmentCallAst,
	BogusTypeAst,
	BuiltinTypeAst,
	CallAst,
	CallAstStyle,
	CallNamedAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	DestructureAst,
	EnumAst,
	ExternTypeAst,
	FlagsAst,
	EmptyAst,
	EnumOrFlagsMemberAst,
	ForAst,
	FunDeclAst,
	FunTypeAst,
	InterpolatedAst,
	ModifierAst,
	IfAst,
	IfAstKind,
	ImportFileAst,
	ImportOrExportAst,
	ImportWholeModuleAst,
	LambdaAst,
	LoopBreakAst,
	LoopContinueAst,
	MapTypeAst,
	MatchAst,
	ModifierKeyword,
	ModifierKeywordAst,
	NameAndRange,
	paramsArray,
	ParamsAst,
	RecordAst,
	RecordFieldAst,
	SignatureAst,
	SingleDestructureAst,
	SpecUseAst,
	StructBodyAst,
	StructDeclAst,
	SuffixNameTypeAst,
	SuffixSpecialTypeAst,
	SumTypeAst,
	TestAst,
	TupleTypeAst,
	TypeAst,
	UnpackOptionAst,
	VisibilityAndRange,
	VoidDestructureAst,
	WithAst;
import model.model :
	AnyDecl,
	AssertOrForbidExpr,
	asTypeContainer,
	BogusCallExpr,
	BogusExpr,
	BogusWrongTypeExpr,
	BuiltinType,
	CallExpr,
	CallExprSource,
	CallOptionExpr,
	ClosureGetExpr,
	ClosureSetExpr,
	CommonTypes,
	Condition,
	Destructure,
	DestructureIgnore,
	DestructureSplit,
	Enum,
	EnumOrFlagsMember,
	Expr,
	ExternExpr,
	ExternType,
	FinallyExpr,
	findDirectChildExpr,
	Flags,
	FunBodyExtern,
	FunDecl,
	FunPointerExpr,
	FunSourceAst,
	IfExpr,
	ImportedReferents,
	ImportOrExport,
	IntegralType,
	LambdaExpr,
	LetExpr,
	LiteralFloatExpr,
	LiteralIntegralExpr,
	LiteralStringLikeExpr,
	Local,
	LocalGetExpr,
	LocalPointerExpr,
	LocalSetExpr,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopExpr,
	LoopWhileOrUntilExpr,
	MatchEnumCase,
	MatchEnumExpr,
	MatchIntegralCase,
	MatchIntegralExpr,
	MatchStringLikeCase,
	MatchStringLikeExpr,
	MatchSumTypeCase,
	MatchSumTypeExpr,
	Module,
	moduleAtUri,
	Params,
	paramsArray,
	Program,
	Record,
	RecordFieldPointerExpr,
	RecordField,
	SeqExpr,
	Signature,
	SpecDecl,
	SpecInst,
	Specs,
	StructBody,
	StructBodyBogus,
	StructDeclSourceBogus,
	StructAlias,
	StructDecl,
	SumType,
	SumTypeKind,
	SumTypeMemberAndMethodImpls,
	Test,
	ThrowExpr,
	TrustedExpr,
	TryExpr,
	TryLetExpr,
	Type,
	TypeContainer,
	TypedExpr,
	TypeParamIndex,
	TypeWithContainer,
	UnpackOption,
	VarDecl;
import model.sourceRange : combineRanges, Pos, Range;
import util.col.array : findIndex, first, firstPointer, firstZip, firstZipIfSizeEq, firstZipPointerFirst, isEmpty;
import util.col.stackMap : StackMap, stackMapAdd, stackMapMustGet, withStackMap;
import util.conv : safeToUint;
import util.opt : force, has, none, Opt, optIf, optOr, optOr, optOrDefault, some;
import util.util : enumConvert;

enum GetPositionKind {
	// Expect cursor exactly on the thing. Used for requests like hover.
	exact,
	// The cursor may be to the right of the thing; used for speculative requests such as completions.
	after,
}
Opt!Position getPosition(ref Program program, TextDocumentPositionParams where, GetPositionKind posKind) {
	Pos pos = program.lineAndCharacterGetters[where];
	Pos posAdjusted = () {
		final switch (posKind) {
			case GetPositionKind.exact:
				return pos;
			case GetPositionKind.after:
				return walkBackwardsForPosition(program.fileContentGetters[where.uri], pos);
		}
	}();
	Ctx ctx = Ctx(program.commonTypesPtr);
	Module* module_ = moduleAtUri(program, where.uri);
	Opt!PositionKind kind = getPositionKind(ctx, module_, posAdjusted, posKind);
	return optIf(has(kind), () => Position(module_, force(kind)));
}

private:

bool hasPos(Range range, Pos pos) =>
	range.start <= pos && pos <= range.end;

const struct Ctx {
	@safe @nogc pure nothrow:
	CommonTypes* commonTypesPtr;

	ref CommonTypes commonTypes() return scope =>
		*commonTypesPtr;
}

Opt!PositionKind getPositionKind(in Ctx ctx, Module* module_, Pos pos, GetPositionKind posKind) =>
	optOr!PositionKind(
		positionInDocComment(DocCommentContainer(module_), pos),
		() => positionInImportsOrExports(module_.imports, pos),
		() => positionInImportsOrExports(module_.reExports, pos),
		() => firstPointer!(PositionKind, StructAlias)(module_.aliases, (StructAlias* x) =>
			positionInAlias(x, pos)),
		() => firstPointer!(PositionKind, StructDecl)(module_.structs, (StructDecl* x) =>
			positionInStruct(ctx, x, pos)),
		() => firstPointer!(PositionKind, VarDecl)(module_.vars, (VarDecl* x) =>
			positionInVar(x, pos)),
		() => firstPointer!(PositionKind, SpecDecl)(module_.specs, (SpecDecl* x) =>
			positionInSpec(x, pos)),
		() => firstPointer!(PositionKind, FunDecl)(module_.funs, (FunDecl* x) =>
			x.source.isA!FunSourceAst
				? positionInFun(ctx, x, x.source.as!FunSourceAst.ast, pos, posKind)
				: none!PositionKind),
		() => firstPointer!(PositionKind, Test)(module_.tests, (Test* x) =>
			positionInTest(ctx, x, *x.ast, pos, posKind)),
		// We need a definition at position 0, because inlay hints for "Used by" have that as their location.
		() => optIf(pos == 0, () => PositionKind(PositionModule())));

Opt!PositionKind positionInDocComment(DocCommentContainer a, Pos pos) {
	Opt!size_t index = findIndex!NameAndRange(a.docComment.ast.references, (in NameAndRange x) =>
		hasPos(x.range, pos));
	return optIf(has(index), () =>
		PositionKind(PositionDocRef(a, a.docComment.references[force(index)])));
}

Opt!PositionKind positionInFun(in Ctx ctx, FunDecl* a, in FunDeclAst* ast, Pos pos, GetPositionKind posKind) =>
	positionInDecl(AnyDecl(a), pos, () => optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), ast.visibility, pos),
		() => optIf(hasPos(ast.name.range, pos), () => PositionKind(a)),
		() => positionInTypeParams(AnyDecl(a), ast.typeParams, pos),
		() => positionInType(TypeContainer(a), a.returnType, ast.returnType, pos),
		() => positionInParams(LocalContainer(a), a.params, ast.params, pos),
		() => positionInModifiers(TypeContainer(a), some(a.specs), ast.modifiers, pos),
		() => a.body_.isA!Expr
			? positionInExpr(ctx, ExprContainer(a), &a.body_.as!Expr(), pos, posKind)
			: none!PositionKind));

Opt!PositionKind positionInTest(ref Ctx ctx, Test* a, in TestAst ast, Pos pos, GetPositionKind posKind) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordRange, pos), () => PositionKind(a)),
		() => positionInExpr(ctx, ExprContainer(a), &a.body_, pos, posKind));

Opt!PositionKind positionInParams(LocalContainer container, in Params params, in ParamsAst ast, Pos pos) =>
	firstZip!(PositionKind, Destructure, DestructureAst)(
		paramsArray(params), paramsArray(ast), (Destructure x, DestructureAst y) =>
			positionInDestructure(container, x, y, pos));

Opt!PositionKind positionInModifiers(TypeContainer container, in Opt!Specs specs, in ModifierAst[] modifiers, Pos pos) {
	Opt!size_t index = findIndex!ModifierAst(modifiers, (in ModifierAst modifier) =>
		hasPos(modifier.range, pos));
	return has(index)
		? positionInModifier(container, specs, modifiers, force(index), pos)
		: none!PositionKind;
}

Opt!PositionKind positionInModifier(
	TypeContainer container,
	in Opt!Specs specs,
	in ModifierAst[] modifiers,
	size_t index,
	Pos pos,
) =>
	modifiers[index].matchIn!(Opt!PositionKind)(
		(in ModifierKeywordAst x) {
			switch (x.keyword) {
				case ModifierKeyword.extern_:
					return some(container.isA!(FunDecl*) && container.as!(FunDecl*).body_.isA!FunBodyExtern
						? PositionKind(PositionModifierExtern(
							container.as!(FunDecl*).body_.as!FunBodyExtern.libraryName))
						: PositionKind(PositionModifier(container, x.keyword)));
				default:
					return some(PositionKind(PositionModifier(container, x.keyword)));
			}
		},
		(in SpecUseAst ast) {
			if (has(specs) && specsMatch(force(specs), modifiers)) {
				// Find the corresponding spec
				size_t specIndex = 0;
				foreach (ref ModifierAst prevModifier; modifiers[0 .. index])
					if (prevModifier.isA!SpecUseAst)
						specIndex++;

				SpecInst* spec = force(specs)[specIndex];
				return optOr!PositionKind(
					findInPackedTypeArgs!PositionKind(spec.typeArgs, ast.typeArg, (in Type t, in TypeAst a) =>
						positionInType(container, t, a, pos)),
					() => optIf(hasPos(ast.nameRange, pos), () =>
						PositionKind(PositionSpecUse(container, force(specs)[specIndex]))));
			} else
				return none!PositionKind;
		});

Opt!PositionKind positionInDestructure(ref ExprCtx ctx, in Destructure a, in DestructureAst ast, Pos pos) =>
	positionInDestructure(ctx.container.toLocalContainer, a, ast, pos);

Opt!PositionKind positionInDestructure(
	LocalContainer container,
	in Destructure a,
	in DestructureAst destructureAst,
	Pos pos,
) {
	Opt!PositionKind handleSingle(Type type, in PositionKind delegate() @safe @nogc pure nothrow cbName) {
		SingleDestructureAst ast = destructureAst.as!SingleDestructureAst;
		return hasPos(ast.range, pos)
			? optOr!PositionKind(
				optIf(hasPos(ast.nameRange, pos), cbName),
				() => optIf(optHasPos(ast.mutRange, pos), () =>
					PositionKind(PositionKeyword.localMut)),
				() => has(ast.type)
					? positionInType( container.toTypeContainer(), type, *force(ast.type), pos)
					: none!PositionKind)
			: none!PositionKind;
	}
	return a.matchWithPointers!(Opt!PositionKind)(
		(DestructureIgnore* x) =>
			destructureAst.isA!VoidDestructureAst
				? none!PositionKind
				: handleSingle(x.type, () => PositionKind(PositionKeyword.underscore)),
		(Local* x) =>
			handleSingle(x.type, () => PositionKind(PositionLocal(container, x))),
		(DestructureSplit* x) =>
			isEmpty(x.parts)
				? none!PositionKind
				: firstZip!(PositionKind, Destructure, DestructureAst)(
					x.parts, destructureAst.as!(DestructureAst[]), (Destructure part, DestructureAst partAst) =>
						positionInDestructure( container, part, partAst, pos)));
}

Opt!PositionKind positionInImportsOrExports(ImportOrExport[] importsOrExports, Pos pos) {
	foreach (ref ImportOrExport im; importsOrExports)
		if (!im.isStd && hasPos(force(im.source).range, pos)) {
			ImportOrExportAst* source = force(im.source);
			return source.kind.matchIn!(Opt!PositionKind)(
				(in ImportWholeModuleAst _) =>
					some(PositionKind(PositionImportedModule(&im))),
				(in NameAndRange[] names) =>
					hasPos(force(im.source).pathRange, pos)
						? some(PositionKind(PositionImportedModule(&im)))
						: positionInImportedNames(im.modulePtr, names, im.imported, pos),
				(in ImportFileAst _) =>
					assert(false));
		}
	return none!PositionKind;
}

Opt!PositionKind positionInImportedNames(
	Module* module_,
	in NameAndRange[] names,
	in ImportedReferents imported,
	Pos pos,
) =>
	first!(PositionKind, NameAndRange)(names, (NameAndRange x) =>
		optIf(hasPos(x.range, pos), () =>
			PositionKind(PositionImportedName(module_, x.name, imported[x.name]))));

Opt!PositionKind positionInDecl(AnyDecl a, Pos pos, in Opt!PositionKind delegate() @safe @nogc pure nothrow cb) =>
	optOr!PositionKind(
		positionInDocComment(DocCommentContainer(a), pos),
		() => hasPos(a.range.range, pos) ? cb() : none!PositionKind);

Opt!PositionKind positionInVar(VarDecl* a, Pos pos) =>
	positionInDecl(AnyDecl(a), pos, () => optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), a.ast.visibility, pos),
		() => optIf(hasPos(a.nameRange.range, pos), () => PositionKind(a)),
		() => optIf(hasPos(a.ast.keywordRange, pos), () =>
			PositionKind(enumConvert!PositionKeyword(a.kind))),
		() => positionInType(TypeContainer(a), a.type, a.ast.type, pos)));

Opt!PositionKind positionInAlias(StructAlias* a, Pos pos) =>
	positionInDecl(AnyDecl(a), pos, () => optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), a.ast.visibility, pos),
		() => optIf(hasPos(a.nameRange.range, pos), () => PositionKind(a)),
		() => optIf(hasPos(a.ast.keywordRange, pos), () =>
			PositionKind(PositionKeyword.alias_)),
		() => positionInType(TypeContainer(a), Type(a.target), a.ast.target, pos)));

Opt!PositionKind positionInStruct(in Ctx ctx, StructDecl* a, Pos pos) =>
	a.source.matchIn!(Opt!PositionKind)(
		(in StructDeclAst x) =>
			positionInStruct(ctx, a, x, pos),
		(in StructDeclSourceBogus _) =>
			none!PositionKind);

Opt!PositionKind positionInStruct(in Ctx ctx, StructDecl* a, in StructDeclAst ast, Pos pos) =>
	positionInDecl(AnyDecl(a), pos, () => optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), ast.visibility, pos),
		() => optIf(hasPos(a.nameRange.range, pos), () => PositionKind(a)),
		() => optIf(hasPos(ast.keywordRange, pos), () =>
			PositionKind(keywordKindForStructBody(ast.body_))),
		() => positionInTypeParams(AnyDecl(a), ast.typeParams, pos),
		() => positionInModifiers(TypeContainer(a), none!Specs, ast.modifiers, pos),
		() => positionInStructBody(ctx, a, a.body_, ast.body_, pos)));

PositionKeyword keywordKindForStructBody(in StructBodyAst a) =>
	a.matchIn!PositionKeyword(
		(in BuiltinTypeAst _) =>
			PositionKeyword.builtin,
		(in EnumAst _) =>
			PositionKeyword.enum_,
		(in ExternTypeAst _) =>
			PositionKeyword.extern_,
		(in FlagsAst _) =>
			PositionKeyword.flags,
		(in RecordAst _) =>
			PositionKeyword.record,
		(in SumTypeAst x) =>
			enumConvert!(PositionKeyword, SumTypeKind)(x.kind));

Opt!PositionKind positionInVisibility(VisibilityContainer a, in Opt!VisibilityAndRange visibility, Pos pos) =>
	optIf(has(visibility) && hasPos(force(visibility).range, pos), () =>
		PositionKind(PositionVisibilityMark(a)));

Opt!PositionKind positionInTypeParams(AnyDecl container, in NameAndRange[] asts, Pos pos) {
	Opt!size_t index = findIndex!NameAndRange(asts, (in NameAndRange x) => hasPos(x.range, pos));
	return optIf(has(index), () =>
		PositionKind(TypeParamWithContainer(TypeParamIndex(safeToUint(force(index))), container)));
}

Opt!PositionKind positionInSpec(SpecDecl* a, Pos pos) =>
	positionInDecl(AnyDecl(a), pos, () => optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), a.ast.visibility, pos),
		() => optIf(hasPos(a.ast.name.range, pos), () => PositionKind(a)),
		() => positionInTypeParams(AnyDecl(a), a.ast.typeParams, pos),
		() => optIf(hasPos(a.ast.keywordRange, pos), () => PositionKind(PositionKeyword.spec)),
		() => positionInModifiers(TypeContainer(a), some(a.parents), a.ast.modifiers, pos),
		() => positionInSignatures(a.sigs, a.ast.sigs, pos)));

Opt!PositionKind positionInSignatures(Signature[] signatures, SignatureAst[] signatureAsts, Pos pos) =>
	firstZipPointerFirst!(PositionKind, Signature, SignatureAst)(
		signatures, signatureAsts, (Signature* sig, SignatureAst sigAst) =>
			positionInSignature(sig, sigAst, pos));

Opt!PositionKind positionInSignature(Signature* sig, in SignatureAst ast, Pos pos) =>
	optOr!PositionKind(
		positionInDocComment(DocCommentContainer(sig), pos),
		() => optIf(hasPos(ast.nameAndRange.range, pos), () =>
			PositionKind(sig)),
		() => positionInType(asTypeContainer(sig.container), sig.returnType, ast.returnType, pos),
		() => positionInParams(asLocalContainer(sig.container), Params(sig.params), ast.params, pos));

Opt!PositionKind positionInStructBody(
	in Ctx ctx,
	StructDecl* decl,
	ref StructBody body_,
	in StructBodyAst ast,
	Pos pos,
) =>
	body_.match!(Opt!PositionKind)(
		(StructBodyBogus _) =>
			none!PositionKind,
		(BuiltinType _) =>
			none!PositionKind,
		(ref Enum x) =>
			positionInEnumOrFlagsBody(
				ctx, decl, x.storage, x.members,
				ast.as!EnumAst.params, ast.as!EnumAst.members,
				pos),
		(ExternType _) =>
			none!PositionKind,
		(Flags x) =>
			positionInEnumOrFlagsBody(
				ctx, decl, x.storage, x.members,
				ast.as!FlagsAst.params, ast.as!FlagsAst.members,
				pos),
		(Record x) =>
			positionInRecord(ctx, decl, x.fields, ast.as!RecordAst, pos),
		(SumType x) =>
			positionInVariant(decl, x, ast.as!SumTypeAst, pos));

Opt!PositionKind positionInVariant(StructDecl* decl, SumType a, in SumTypeAst ast, Pos pos) =>
	optOr!PositionKind(
		firstZipIfSizeEq!(PositionKind, TypeAst, SumTypeMemberAndMethodImpls)(
			ast.types, a.listedMembers, (TypeAst typeAst, SumTypeMemberAndMethodImpls x) =>
				positionInType(TypeContainer(decl), Type(x.member), typeAst, pos)),
		() => positionInSignatures(a.methods, ast.methods, pos));

Opt!PositionKind positionInRecord(
	in Ctx ctx,
	StructDecl* decl,
	in RecordField[] members,
	ref RecordAst ast,
	Pos pos,
) =>
	isEmpty(members)
		? none!PositionKind
		: has(ast.params)
		? firstZipPointerFirst!(PositionKind, RecordField, DestructureAst)(
			members, force(ast.params).as!(DestructureAst[]), (RecordField* field, DestructureAst param) =>
				positionInRecordFieldParameter(decl, field, param.as!SingleDestructureAst, pos))
		: firstZipPointerFirst!(PositionKind, RecordField, RecordFieldAst)(
			members, ast.fields, (RecordField* field, RecordFieldAst fieldAst) =>
				positionInRecordField(decl, field, fieldAst, pos));

Opt!PositionKind positionInRecordFieldParameter(
	StructDecl* decl,
	RecordField* field,
	in SingleDestructureAst param,
	Pos pos,
) =>
	optOr!PositionKind(
		optIf(hasPos(param.name.range, pos), () => PositionKind(field)),
		() {
			Opt!Range mutRange = param.mutRange;
			return optIf(has(mutRange) && hasPos(force(mutRange), pos), () =>
				PositionKind(PositionRecordFieldMutability(field.mutability)));
		},
		() => has(param.type)
			? positionInType(TypeContainer(decl), field.type, *force(param.type), pos)
			: none!PositionKind);

Opt!PositionKind positionInRecordField(StructDecl* decl, RecordField* field, in RecordFieldAst memberAst, Pos pos) =>
	optOr!PositionKind(
		positionInDocComment(DocCommentContainer(field), pos),
		() => positionInVisibility(VisibilityContainer(field), memberAst.visibility, pos),
		() => optIf(hasPos(memberAst.name.range, pos), () => PositionKind(field)),
		() => optIf(has(memberAst.mutability) && hasPos(force(memberAst.mutability).range, pos), () =>
			PositionKind(PositionRecordFieldMutability(field.mutability))),
		() => has(memberAst.type)
			? positionInType(TypeContainer(decl), field.type, force(memberAst.type), pos)
			: none!PositionKind);

Opt!PositionKind positionInEnumOrFlagsBody(
	in Ctx ctx,
	StructDecl* decl,
	IntegralType storage,
	in EnumOrFlagsMember[] members,
	in Opt!ParamsAst paramsAst,
	in EnumOrFlagsMemberAst[] memberAsts,
	Pos pos
) =>
	isEmpty(members)
		? none!PositionKind
		: has(paramsAst)
		? firstZipPointerFirst!(PositionKind, EnumOrFlagsMember, DestructureAst)(
			members, force(paramsAst).as!(DestructureAst[]), (EnumOrFlagsMember* member, DestructureAst param) =>
				optIf(hasPos(param.range, pos), () => PositionKind(member)))
		: firstZipPointerFirst!(PositionKind, EnumOrFlagsMember, EnumOrFlagsMemberAst)(
			members, memberAsts, (EnumOrFlagsMember* member, EnumOrFlagsMemberAst memberAst) =>
				positionInEnumOrFlagsMember(member, memberAst, pos));

Opt!PositionKind positionInEnumOrFlagsMember(EnumOrFlagsMember* member, EnumOrFlagsMemberAst ast, Pos pos) =>
	optOr!PositionKind(
		positionInDocComment(DocCommentContainer(member), pos),
		() => optIf(hasPos(ast.nameRange, pos), () => PositionKind(member)));

Opt!PositionKind positionInExpr(ref Ctx ctx, ExprContainer container, Expr* a, Pos pos, GetPositionKind posKind) {
	ExprCtx exprCtx = ExprCtx(ctx.commonTypesPtr, container);
	return positionInExprRecur(exprCtx, a, pos, posKind);
}

const struct ExprCtx {
	@safe @nogc pure nothrow:

	CommonTypes* commonTypesPtr;
	ExprContainer container;

	ref CommonTypes commonTypes() return scope =>
		*commonTypesPtr;
}

Opt!PositionKind positionInExprRecur(ref ExprCtx ctx, Expr* a, Pos pos, GetPositionKind posKind) =>
	hasPos(a.range, pos)
		? optOr!PositionKind(positionAtExpr(ctx, a, pos, posKind), () =>
			positionInExprChild(ctx, *a, pos, posKind))
		: none!PositionKind;

Opt!PositionKind positionInExprChild(ref ExprCtx ctx, ref Expr a, Pos pos, GetPositionKind posKind) =>
	findDirectChildExpr!PositionKind(a, (Expr* child) =>
		positionInExprRecur(ctx, child, pos, posKind));

Opt!PositionKind positionAtExpr(ref ExprCtx ctx, Expr* a, Pos pos, GetPositionKind posKind) {
	PositionKind expressionPosition(ExpressionPositionKind x) =>
		PositionKind(ExpressionPosition(ctx.container, a, x));
	Opt!PositionKind inDestructure(in Destructure x, in DestructureAst y) =>
		positionInDestructure(ctx, x, y, pos);
	PositionKind keyword(ExprKeyword k) =>
		expressionPosition(ExpressionPositionKind(k));
	Opt!PositionKind keywordAt(Range range, ExprKeyword k, ) =>
		optIf(hasPos(range, pos), () => keyword(k));
	PositionKind local(LocalRefKind kind, Local* local) =>
		expressionPosition(ExpressionPositionKind(LocalRef(kind, local)));
	PositionKind loopKeyword(LoopKeywordKind kind, LoopExpr* loop) =>
		expressionPosition(ExpressionPositionKind(LoopKeyword(kind, loop)));
	Opt!PositionKind call(CallExprSource ast, ExpressionPositionKind kind) {
		bool ok = () {
			final switch (posKind) {
				case GetPositionKind.exact:
					return posIsAtCall(ast, pos);
				case GetPositionKind.after:
					return true;
			}
		}();
		return optIf(ok, () => expressionPosition(kind));
	}

	return a.matchWithPointers!(Opt!PositionKind)(
		(AssertOrForbidExpr* x) =>
			optOr!PositionKind(
				keywordAt(x.ast.keywordRange, x.isForbid ? ExprKeyword.forbid : ExprKeyword.assert_),
				() => positionAtCondition(ctx, x.condition, a, x.ast.condition, pos),
				() => has(x.ast.thrown)
					? keywordAt(force(x.ast.thrown).colonRange, ExprKeyword.colonInAssertOrForbid)
					: none!PositionKind),
		(BogusCallExpr* x) =>
			call(x.ast, ExpressionPositionKind(x)),
		(BogusExpr _) =>
			none!PositionKind,
		(BogusWrongTypeExpr _) =>
			none!PositionKind,
		(CallExpr x) =>
			call(x.ast, ExpressionPositionKind(&a.as!CallExpr())),
		(CallOptionExpr x) =>
			optOr!PositionKind(
				keywordAt(force(x.ast.keywordRange), ExprKeyword.questionDotOrSubscript),
				() => optIf(posIsAtCall(*x.ast, pos), () =>
					expressionPosition(ExpressionPositionKind(&a.as!CallOptionExpr())))),
		(ClosureGetExpr x) =>
			some(local(LocalRefKind.closureGet, x.local)),
		(ClosureSetExpr x) =>
			optIf(hasPos(x.assigneeRange, pos), () =>
				local(LocalRefKind.closureSet, x.local)),
		(ExternExpr x) =>
			some(expressionPosition(ExpressionPositionKind(&a.as!ExternExpr()))),
		(FinallyExpr* x) =>
			keywordAt(x.ast.finallyKeywordRange, ExprKeyword.finally_),
		(FunPointerExpr x) =>
			some(expressionPosition(ExpressionPositionKind(&a.as!FunPointerExpr()))),
		(IfExpr* x) =>
			optOr!PositionKind(
				keywordAt(x.ast.firstKeywordRange, ExprKeyword.guardIfOrUnless),
				() => positionAtCondition(ctx, x.condition, a, x.ast.condition, pos),
				() => has(x.ast.secondKeywordRange)
					? keywordAt(force(x.ast.secondKeywordRange), ifSecondKeyword(x.ast.kind))
					: none!PositionKind),
		(LambdaExpr* x) =>
			x.ast.matchIn!(Opt!PositionKind)(
				(in ForAst ast) =>
					// 'for' keyword is handled in the CallExpr
					optOr!PositionKind(
						x.isIgnore ? none!PositionKind : inDestructure(x.param, ast.param),
						() => keywordAt(ast.colonRange, ExprKeyword.colonInFor)),
				(in LambdaAst ast) =>
					optOr!PositionKind(
						keywordAt(ast.arrowRange, ExprKeyword.lambdaArrow),
						() => inDestructure(x.param, ast.param)),
				(in WithAst ast) =>
					// 'with' keyword is handled in the CallExpr
					optOr!PositionKind(
						inDestructure(x.param, ast.param),
						() => keywordAt(ast.colonRange, ExprKeyword.colonInWith))),
		(LetExpr* x) =>
			inDestructure(x.destructure, x.ast.destructure),
		(LiteralFloatExpr _) =>
			some(expressionPosition(ExpressionPositionKind(ExpressionPositionLiteral()))),
		(LiteralIntegralExpr _) =>
			some(expressionPosition(ExpressionPositionKind(ExpressionPositionLiteral()))),
		(LiteralStringLikeExpr _) =>
			some(expressionPosition(ExpressionPositionKind(ExpressionPositionLiteral()))),
		(LocalGetExpr x) =>
			some(local(LocalRefKind.get, x.local)),
		(LocalPointerExpr x) =>
			some(optOrDefault!PositionKind(
				keywordAt(x.ast.keywordRange, ExprKeyword.ampersand),
				() => local(LocalRefKind.pointer, x.local))),
		(LocalSetExpr x) =>
			optIf(hasPos(x.assigneeRange, pos), () =>
				local(LocalRefKind.set, x.local)),
		(LoopExpr* x) =>
			optIf(hasPos(x.ast.keywordRange, pos), () =>
				expressionPosition(ExpressionPositionKind(LoopKeyword(LoopKeywordKind.loop, x)))),
		(LoopBreakExpr* x) =>
			optIf(hasPos(x.ast.keywordRange, pos), () =>
				loopKeyword(LoopKeywordKind.break_, x.loop)),
		(LoopContinueExpr x) =>
			some(loopKeyword(LoopKeywordKind.continue_, x.loop)),
		(LoopWhileOrUntilExpr* x) =>
			optOr!PositionKind(
				keywordAt(
					x.ast.keywordRange,
					x.isUntil ? ExprKeyword.until : ExprKeyword.while_),
				() => positionAtCondition(ctx, x.condition, a, x.ast.condition, pos)),
		(MatchEnumExpr* x) =>
			positionAtMatchEnum(ctx, a, *x, pos),
		(MatchIntegralExpr* x) =>
			positionAtMatchIntegral(ctx, a, *x, pos),
		(MatchStringLikeExpr* x) =>
			positionAtMatchStringLike(ctx, a, *x, pos),
		(MatchSumTypeExpr* x) =>
			positionAtMatchSumType(ctx, a, *x, pos),
		(RecordFieldPointerExpr* x) =>
			keywordAt(x.ast.keywordRange, ExprKeyword.ampersand),
		(SeqExpr* x) =>
			none!PositionKind,
		(ThrowExpr* x) =>
			keywordAt(x.ast.keywordRange, ExprKeyword.throw_),
		(TrustedExpr* x) =>
			keywordAt(x.ast.keywordRange, ExprKeyword.trusted),
		(TryExpr* x) =>
			positionAtTry(ctx, a, *x, pos),
		(TryLetExpr* x) =>
			positionAtTryLet(ctx, a, *x, pos),
		(TypedExpr* x) =>
			optOr!PositionKind(
				keywordAt(x.ast.keywordRange, ExprKeyword.colonColon),
				() => positionInType(ctx.container.toTypeContainer, a.type(ctx.commonTypes), x.ast.type, pos)));
}

ExprKeyword ifSecondKeyword(IfAstKind kind) {
	final switch (kind) {
		case IfAstKind.guardWithColon:
		case IfAstKind.ternaryWithElse:
			return ExprKeyword.colonInIf;
		case IfAstKind.ifElif:
			return ExprKeyword.elif;
		case IfAstKind.ifElse:
			return ExprKeyword.elseAfterIf;
		case IfAstKind.guardWithoutColon:
		case IfAstKind.ifWithoutElse:
		case IfAstKind.ternaryWithoutElse:
		case IfAstKind.unless:
			assert(0);
	}
}

Opt!PositionKind positionAtCondition(
	in ExprCtx ctx,
	in Condition condition,
	Expr* source,
	in ConditionAst ast,
	Pos pos,
) =>
	condition.matchIn!(Opt!PositionKind)(
		(in Expr _) =>
			none!PositionKind,
		(in UnpackOption x) {
			UnpackOptionAst* unpackAst = ast.as!(UnpackOptionAst*);
			return optOr!PositionKind(
				positionInDestructure(ctx, x.destructure, unpackAst.destructure, pos),
				() => optIf(hasPos(unpackAst.questionEqualsRange, pos), () =>
					PositionKind(ExpressionPosition(ctx.container, source, ExpressionPositionKind(
						ExprKeyword.questionEquals)))));
		});

bool posIsAtCall(in CallExprSource a, Pos pos) =>
	hasPos(rangeForPosIsAtCall(a), pos);
bool posIsAtCall(in CallAst ast, Pos pos) =>
	hasPos(rangeForPosIsAtCall(ast), pos);
Range rangeForPosIsAtCall(in CallExprSource a) =>
	a.matchIn!Range(
		(in ArrowAccessAst x) =>
			x.arrowAndNameRange,
		(in AssignmentAst x) =>
			Range.empty, // TODO
		(in AssignmentCallAst x) =>
			Range.empty, // TODO
		(in CallAst x) =>
			rangeForPosIsAtCall(x),
		(in CallNamedAst x) =>
			Range.empty, // TODO
		(in EmptyAst x) =>
			Range.empty,
		(in ForAst x) =>
			// Handle the colon when handling the LambdaExpr
			x.forKeywordRange,
		(in IfAst x) =>
			Range.empty,
		(in InterpolatedAst x) =>
			// This is the call to `interpolate` or `show`, which we don't have a position for.
			Range.empty,
		(in LoopBreakAst x) =>
			x.range,
		(in LoopContinueAst x) =>
			x.range,
		(in NameAndRange x) =>
			x.range,
		(in WithAst x) =>
			x.withKeywordRange);
Range rangeForPosIsAtCall(in CallAst ast) {
	final switch (ast.style) {
		case CallAstStyle.comma:
		case CallAstStyle.emptyParens:
		case CallAstStyle.subscript:
		case CallAstStyle.questionSubscript:
			return Range.empty;
		case CallAstStyle.augment:
		case CallAstStyle.dot:
		case CallAstStyle.infix:
		case CallAstStyle.prefixBang:
		case CallAstStyle.prefixOperator:
		case CallAstStyle.questionDot:
		case CallAstStyle.single:
		case CallAstStyle.suffixBang:
			return ast.funName.range;
	}
}

Opt!PositionKind positionAtMatchEnum(in ExprCtx ctx, Expr* expr, ref MatchEnumExpr a, Pos pos) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, *a.ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchEnumCase, CaseAst)(
			a.cases, a.ast.cases,
			(MatchEnumCase case_, CaseAst caseAst) =>
				optIf(hasPos(caseAst.keywordAndMemberNameRange, pos), () =>
					PositionKind(PositionMatchEnumCase(case_.member)))));

Opt!PositionKind positionAtMatchIntegral(in ExprCtx ctx, Expr* expr, ref MatchIntegralExpr a, Pos pos) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, *a.ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchIntegralCase, CaseAst)(
			a.cases, a.ast.cases,
			(MatchIntegralCase case_, CaseAst caseAst) =>
				optIf(hasPos(caseAst.keywordAndMemberNameRange, pos), () =>
					PositionKind(PositionMatchIntegralCase(a.integralType, case_.value)))));

Opt!PositionKind positionAtMatchStringLike(in ExprCtx ctx, Expr* expr, ref MatchStringLikeExpr a, Pos pos) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, *a.ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchStringLikeCase, CaseAst)(
			a.cases, a.ast.cases,
			(MatchStringLikeCase case_, CaseAst caseAst) =>
				optIf(hasPos(caseAst.keywordAndMemberNameRange, pos), () =>
					PositionKind(PositionMatchStringLikeCase(
						TypeWithContainer(Type(a.matchedType), ctx.container.toTypeContainer),
						case_.value)))));

Opt!PositionKind positionAtMatchSumType(ref ExprCtx ctx, Expr* expr, ref MatchSumTypeExpr a, Pos pos) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, *a.ast, pos),
		() => positionAtMatchSumTypeCases(ctx, a.cases, a.ast.cases, pos));

Opt!PositionKind positionAtMatchSumTypeCases(
	ref ExprCtx ctx,
	in MatchSumTypeCase[] cases,
	in CaseAst[] caseAsts,
	Pos pos,
) =>
	firstZipIfSizeEq!(PositionKind, MatchSumTypeCase, CaseAst)(
		cases, caseAsts,
		(MatchSumTypeCase case_, CaseAst caseAst) =>
			positionAtMatchSumTypeCase(ctx, case_, caseAst, pos));

Opt!PositionKind positionAtMatchSumTypeCase(ref ExprCtx ctx, MatchSumTypeCase case_, CaseAst ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordAndMemberNameRange, pos), () =>
			PositionKind(PositionMatchSumTypeCase(ctx.container, case_.member))),
		() => positionInMatchCaseDestructure(ctx, case_.destructure, ast.member, pos));

Opt!PositionKind positionInMatchCaseDestructure(
	ref ExprCtx ctx,
	in Destructure destructure,
	in CaseMemberAst ast,
	Pos pos,
) =>
	ast.isA!AsNameAst && has(ast.as!AsNameAst.destructure)
		? positionInDestructure(ctx, destructure, force(ast.as!AsNameAst.destructure), pos)
		: none!PositionKind;

Opt!PositionKind positionAtMatchKeyword(in ExprCtx ctx, Expr* matchExpr, in MatchAst ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordRange, pos), () =>
			PositionKind(ExpressionPosition(ctx.container, matchExpr, ExpressionPositionKind(ExprKeyword.match)))),
		() => optIf(has(ast.else_) && hasPos(force(ast.else_).keywordRange, pos), () =>
			PositionKind(ExpressionPosition(ctx.container, matchExpr, ExpressionPositionKind(ExprKeyword.elseAfterMatch)))));

Opt!PositionKind positionAtTry(in ExprCtx ctx, Expr* expr, ref TryExpr a, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(a.ast.tryKeywordRange, pos), () =>
			PositionKind(ExpressionPosition(ctx.container, expr, ExpressionPositionKind(ExprKeyword.try_)))),
		() => positionAtMatchSumTypeCases(ctx, a.catches, a.ast.catches, pos));

Opt!PositionKind positionAtTryLet(in ExprCtx ctx, Expr* expr, ref TryLetExpr a, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(a.ast.tryKeywordRange, pos), () =>
			PositionKind(ExpressionPosition(ctx.container, expr, ExpressionPositionKind(ExprKeyword.try_)))),
		() => positionInDestructure(ctx, a.destructure, a.ast.destructure, pos),
		() => optIf(hasPos(combineRanges(a.ast.catchKeywordRange, a.ast.catchMember.nameRange), pos), () =>
			PositionKind(PositionMatchSumTypeCase(ctx.container, a.catch_.member))),
		() => positionInMatchCaseDestructure(ctx, a.catch_.destructure, a.ast.catchMember, pos));

Opt!PositionKind positionInType(TypeContainer container, Type type, in TypeAst ast, Pos pos) =>
	hasPos(ast.range, pos)
		? optOr!PositionKind(
			eachTypeComponent!PositionKind(type, ast, (in Type t, in TypeAst a) =>
				positionInType(container, t, a, pos)),
			() => positionInTypeNotArgs(container, type, ast, pos))
		: none!PositionKind;

Opt!PositionKind positionInTypeNotArgs(TypeContainer container, Type type, in TypeAst ast, Pos pos) {
	PositionKind here = PositionKind(TypeWithContainer(type, container));
	return ast.matchIn!(Opt!PositionKind)(
		(in BogusTypeAst _) =>
			none!PositionKind,
		(in FunTypeAst x) =>
			optIf(hasPos(x.kindRange, pos), () => here),
		(in MapTypeAst x) =>
			none!PositionKind,
		(in NameAndRange x) =>
			some(here),
		(in SuffixNameTypeAst x) =>
			optIf(hasPos(x.name.range, pos), () => here),
		(in SuffixSpecialTypeAst x) =>
			optIf(hasPos(x.suffixRange, pos), () => here),
		(in TupleTypeAst _) =>
			none!PositionKind);
}

bool optHasPos(in Opt!Range a, Pos p) =>
	has(a) && hasPos(force(a), p);
