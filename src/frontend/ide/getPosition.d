module frontend.ide.getPosition;

@safe @nogc pure nothrow:

import frontend.ide.ideUtil : findInPackedTypeArgs, eachTypeComponent, specsMatch;
import frontend.ide.position :
	ExpressionPosition,
	ExpressionPositionKind,
	ExprContainer,
	ExprKeyword,
	LocalContainer,
	Position,
	PositionKind,
	VisibilityContainer;
import model.ast :
	ArrowAccessAst,
	AssertOrForbidAst,
	AssignmentAst,
	AssignmentCallAst,
	CallAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	DestructureAst,
	IdentifierAst,
	ImportOrExportAstKind,
	EnumOrFlagsMemberAst,
	ExprAst,
	FinallyAst,
	ForAst,
	FunDeclAst,
	ModifierAst,
	IfAst,
	ImportOrExportAst,
	LambdaAst,
	LetAst,
	LoopAst,
	LoopBreakAst,
	LoopWhileOrUntilAst,
	MatchAst,
	ModifierKeyword,
	NameAndRange,
	paramsArray,
	ParamsAst,
	PtrAst,
	RecordOrUnionMemberAst,
	SignatureAst,
	SpecUseAst,
	StructBodyAst,
	StructDeclAst,
	TestAst,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	VisibilityAndRange,
	WithAst;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	AssertOrForbidExpr,
	BogusCallExpr,
	BogusExpr,
	BuiltinType,
	CallExpr,
	CallOptionExpr,
	ClosureGetExpr,
	ClosureSetExpr,
	CommonTypes,
	Condition,
	Destructure,
	EnumOrFlagsMember,
	Expr,
	ExprRef,
	ExternExpr,
	FinallyExpr,
	findDirectChildExpr,
	FunBody,
	funBodyExprRef,
	FunDecl,
	FunDeclSource,
	FunPointerExpr,
	IfExpr,
	ImportedReferents,
	ImportOrExport,
	IntegralType,
	LambdaExpr,
	LetExpr,
	LiteralExpr,
	LiteralStringLikeExpr,
	Local,
	LocalGetExpr,
	LocalPointerExpr,
	LocalSetExpr,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopExpr,
	LoopWhileOrUntilExpr,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchUnionExpr,
	MatchVariantExpr,
	Module,
	Params,
	Program,
	RecordFieldPointerExpr,
	RecordField,
	SeqExpr,
	SpecInst,
	Specs,
	StructBody,
	SpecDecl,
	Signature,
	StructAlias,
	StructDecl,
	Test,
	testBodyExprRef,
	ThrowExpr,
	TrustedExpr,
	TryExpr,
	TryLetExpr,
	Type,
	TypedExpr,
	TypeParamIndex,
	UnionMember,
	VarDecl;
import model.model : paramsArray, StructDeclSource;
import util.col.array :
	findIndex,
	first,
	firstPointer,
	firstZip,
	firstZipIfSizeEq,
	firstZipPointerFirst,
	isEmpty,
	SmallArray;
import util.col.stackMap : StackMap, stackMapAdd, stackMapMustGet, withStackMap;
import util.conv : safeToUint;
import util.opt : force, has, none, Opt, optIf, optOr, optOr, optOrDefault, some;
import util.sourceRange : combineRanges, LineAndColumnGetter, Pos, PosKind, Range;
import util.union_ : TaggedUnion, Union;
import util.util : enumConvert, stringOfEnum;

enum GetPositionKind {
	// For hover, go to definition, get references: Expect cursor exactly on the thing.
	target,
	// For signature help, the cursor may be to the right of the call.
	signatureHelp,
}
Opt!Position getPosition(ref Program program, Module* module_, Pos pos, GetPositionKind posKind) {
	Ctx ctx = Ctx(program.commonTypesPtr);
	Opt!PositionKind kind = getPositionKind(ctx, *module_, pos, posKind);
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

Opt!PositionKind getPositionKind(in Ctx ctx, ref Module module_, Pos pos, GetPositionKind posKind) =>
	optOr!PositionKind(
		positionInImportsOrExports(module_.imports, pos),
		() => positionInImportsOrExports(module_.reExports, pos),
		() => firstPointer!(PositionKind, StructAlias)(module_.aliases, (StructAlias* x) =>
			hasPos(x.range.range, pos)
				? positionInAlias(x, pos)
				: none!PositionKind),
		() => firstPointer!(PositionKind, StructDecl)(module_.structs, (StructDecl* x) =>
			hasPos(x.range.range, pos)
				? positionInStruct(ctx, x, pos)
				: none!PositionKind),
		() => firstPointer!(PositionKind, VarDecl)(module_.vars, (VarDecl* x) =>
			hasPos(x.range.range, pos)
				? positionInVar(x, pos)
				: none!PositionKind),
		() => firstPointer!(PositionKind, SpecDecl)(module_.specs, (SpecDecl* x) =>
			hasPos(x.range.range, pos)
				? positionInSpec(x, pos)
				: none!PositionKind),
		() => firstPointer!(PositionKind, FunDecl)(module_.funs, (FunDecl* x) =>
			x.source.isA!(FunDeclSource.Ast)
				? positionInFun(ctx, x, x.source.as!(FunDeclSource.Ast).ast, pos, posKind)
				: none!PositionKind),
		() => firstPointer!(PositionKind, Test)(module_.tests, (Test* x) =>
			hasPos(x.ast.range, pos)
				? positionInTest(ctx, x, *x.ast, pos, posKind)
				: none!PositionKind));

Opt!PositionKind positionInFun(in Ctx ctx, FunDecl* a, in FunDeclAst* ast, Pos pos, GetPositionKind posKind) =>
	optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), ast.visibility, pos),
		() => optIf(hasPos(ast.name.range, pos), () => PositionKind(a)),
		() => positionInTypeParams(TypeContainer(a), ast.typeParams, pos),
		() => positionInType(TypeContainer(a), a.returnType, ast.returnType, pos),
		() => positionInParams(LocalContainer(a), a.params, ast.params, pos),
		() => positionInModifiers(TypeContainer(a), some(a.specs), ast.modifiers, pos),
		() => a.body_.isA!Expr
			? positionInExpr(ctx, ExprContainer(a), funBodyExprRef(a), pos, posKind)
			: none!PositionKind);

Opt!PositionKind positionInTest(ref Ctx ctx, Test* a, in TestAst ast, Pos pos, GetPositionKind posKind) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordRange, pos), () => PositionKind(a)),
		() => positionInExpr(ctx, ExprContainer(a), testBodyExprRef(ctx.commonTypes, a), pos, posKind));

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
		(in ModifierAst.Keyword x) {
			switch (x.keyword) {
				case ModifierKeyword.extern_:
					return some(container.isA!(FunDecl*) && container.as!(FunDecl*).body_.isA!(FunBody.Extern)
						? PositionKind(PositionKind.ModifierExtern(
							container.as!(FunDecl*).body_.as!(FunBody.Extern).libraryName))
						: PositionKind(PositionKind.Modifier(container, x.keyword)));
				default:
					return some(PositionKind(PositionKind.Modifier(container, x.keyword)));
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
						PositionKind(PositionKind.SpecUse(container, force(specs)[specIndex]))));
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
		DestructureAst.Single ast = destructureAst.as!(DestructureAst.Single);
		return hasPos(ast.range, pos)
			? optOr!PositionKind(
				optIf(hasPos(ast.nameRange, pos), cbName),
				() => optIf(optHasPos(ast.mutRange, pos), () =>
					PositionKind(PositionKind.Keyword(PositionKind.Keyword.Kind.localMut))),
				() => has(ast.type)
					? positionInType( container.toTypeContainer(), type, *force(ast.type), pos)
					: none!PositionKind)
			: none!PositionKind;
	}
	return a.matchWithPointers!(Opt!PositionKind)(
		(Destructure.Ignore* x) =>
			destructureAst.isA!(DestructureAst.Void)
				? none!PositionKind
				: handleSingle(x.type, () => PositionKind(PositionKind.Keyword(PositionKind.Keyword.Kind.underscore))),
		(Local* x) =>
			handleSingle(x.type, () => PositionKind(PositionKind.LocalPosition(container, x))),
		(Destructure.Split* x) =>
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
				(in ImportOrExportAstKind.ModuleWhole) =>
					some(PositionKind(PositionKind.ImportedModule(&im))),
				(in NameAndRange[] names) =>
					hasPos(force(im.source).pathRange, pos)
						? some(PositionKind(PositionKind.ImportedModule(&im)))
						: positionInImportedNames(im.modulePtr, names, im.imported, pos),
				(in ImportOrExportAstKind.File) =>
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
			PositionKind(PositionKind.ImportedName(module_, x.name, imported[x.name]))));

Opt!PositionKind positionInVar(VarDecl* a, Pos pos) =>
	optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), a.ast.visibility, pos),
		() => optIf(hasPos(a.nameRange.range, pos), () => PositionKind(a)),
		() => optIf(hasPos(a.ast.keywordRange, pos), () =>
			PositionKind(PositionKind.Keyword(enumConvert!(PositionKind.Keyword.Kind)(a.kind)))),
		() => positionInType(TypeContainer(a), a.type, a.ast.type, pos));

Opt!PositionKind positionInAlias(StructAlias* a, Pos pos) =>
	optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), a.ast.visibility, pos),
		() => optIf(hasPos(a.nameRange.range, pos), () => PositionKind(a)),
		() => optIf(hasPos(a.ast.keywordRange, pos), () =>
			PositionKind(PositionKind.Keyword(PositionKind.Keyword.Kind.alias_))),
		() => positionInType(TypeContainer(a), Type(a.target), a.ast.target, pos));

Opt!PositionKind positionInStruct(in Ctx ctx, StructDecl* a, Pos pos) =>
	a.source.matchIn!(Opt!PositionKind)(
		(in StructDeclAst x) =>
			positionInStruct(ctx, a, x, pos),
		(in StructDeclSource.Bogus) =>
			none!PositionKind);

Opt!PositionKind positionInStruct(in Ctx ctx, StructDecl* a, in StructDeclAst ast, Pos pos) =>
	optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), ast.visibility, pos),
		() => optIf(hasPos(a.nameRange.range, pos), () => PositionKind(a)),
		() => optIf(hasPos(ast.keywordRange, pos), () =>
			PositionKind(PositionKind.Keyword(keywordKindForStructBody(ast.body_)))),
		() => positionInTypeParams(TypeContainer(a), ast.typeParams, pos),
		() => positionInModifiers(TypeContainer(a), none!Specs, ast.modifiers, pos),
		() => positionInStructBody(ctx, a, a.body_, ast.body_, pos));

PositionKind.Keyword.Kind keywordKindForStructBody(in StructBodyAst a) =>
	a.matchIn!(PositionKind.Keyword.Kind)(
		(in StructBodyAst.Builtin) =>
			PositionKind.Keyword.Kind.builtin,
		(in StructBodyAst.Enum) =>
			PositionKind.Keyword.Kind.enum_,
		(in StructBodyAst.Extern) =>
			PositionKind.Keyword.Kind.extern_,
		(in StructBodyAst.Flags) =>
			PositionKind.Keyword.Kind.flags,
		(in StructBodyAst.Record) =>
			PositionKind.Keyword.Kind.record,
		(in StructBodyAst.Union) =>
			PositionKind.Keyword.Kind.union_,
		(in StructBodyAst.Variant) =>
			PositionKind.Keyword.Kind.variant);

Opt!PositionKind positionInVisibility(VisibilityContainer a, in Opt!VisibilityAndRange visibility, Pos pos) =>
	has(visibility) && hasPos(force(visibility).range, pos)
		? some(PositionKind(PositionKind.VisibilityMark(a)))
		: none!PositionKind;

Opt!PositionKind positionInTypeParams(TypeContainer container, in NameAndRange[] asts, Pos pos) {
	Opt!size_t index = findIndex!NameAndRange(asts, (in NameAndRange x) => hasPos(x.range, pos));
	return optIf(has(index), () =>
		PositionKind(PositionKind.TypeParamWithContainer(TypeParamIndex(safeToUint(force(index))), container)));
}

Opt!PositionKind positionInSpec(SpecDecl* a, Pos pos) =>
	optOr!PositionKind(
		positionInVisibility(VisibilityContainer(a), a.ast.visibility, pos),
		() => optIf(hasPos(a.ast.name.range, pos), () => PositionKind(a)),
		() => positionInTypeParams(TypeContainer(a), a.ast.typeParams, pos),
		() => optIf(hasPos(a.ast.keywordRange, pos), () =>
			PositionKind(PositionKind.Keyword(PositionKind.Keyword.Kind.spec))),
		() => positionInModifiers(TypeContainer(a), some(a.parents), a.ast.modifiers, pos),
		() => positionInSignatures(SpecOrVariant(a), a.sigs, a.ast.sigs, pos));

immutable struct SpecOrVariant { mixin TaggedUnion!(SpecDecl*, StructDecl*); }
TypeContainer toTypeContainer(SpecOrVariant a) =>
	toLocalContainer(a).toTypeContainer;
LocalContainer toLocalContainer(SpecOrVariant a) =>
	a.matchWithPointers!LocalContainer(
		(SpecDecl* x) => LocalContainer(x),
		(StructDecl* x) => LocalContainer(x));
PositionKind toPositionKind(SpecOrVariant a, Signature* sig) =>
	a.matchWithPointers!PositionKind(
		(SpecDecl* x) => PositionKind(PositionKind.SpecSig(x, sig)),
		(StructDecl* x) => PositionKind(PositionKind.VariantMethod(x, sig)));

Opt!PositionKind positionInSignatures(
	SpecOrVariant container,
	Signature[] signatures,
	SignatureAst[] signatureAsts,
	Pos pos,
) =>
	firstZipPointerFirst!(PositionKind, Signature, SignatureAst)(
		signatures, signatureAsts, (Signature* sig, SignatureAst sigAst) =>
			positionInSignature(container, sig, sigAst, pos));

Opt!PositionKind positionInSignature(
	SpecOrVariant container,
	Signature* sig,
	in SignatureAst ast,
	Pos pos,
) =>
	hasPos(ast.range, pos)
		? optOr!PositionKind(
			optIf(hasPos(ast.nameAndRange.range, pos), () =>
				toPositionKind(container, sig)),
			() => positionInType(toTypeContainer(container), sig.returnType, ast.returnType, pos),
			() => positionInParams(toLocalContainer(container), Params(sig.params), ast.params, pos))
		: none!PositionKind;

Opt!PositionKind positionInStructBody(
	in Ctx ctx,
	StructDecl* decl,
	ref StructBody body_,
	in StructBodyAst ast,
	Pos pos,
) =>
	body_.match!(Opt!PositionKind)(
		(StructBody.Bogus) =>
			none!PositionKind,
		(BuiltinType _) =>
			none!PositionKind,
		(ref StructBody.Enum x) =>
			positionInEnumOrFlagsBody(
				ctx, decl, x.storage, x.members,
				ast.as!(StructBodyAst.Enum).params, ast.as!(StructBodyAst.Enum).members,
				pos),
		(StructBody.Extern) =>
			none!PositionKind,
		(StructBody.Flags x) =>
			positionInEnumOrFlagsBody(
				ctx, decl, x.storage, x.members,
				ast.as!(StructBodyAst.Flags).params, ast.as!(StructBodyAst.Flags).members,
				pos),
		(StructBody.Record x) =>
			positionInRecordOrUnionBody!RecordField(
				ctx, decl, x.fields,
				ast.as!(StructBodyAst.Record).params,
				ast.as!(StructBodyAst.Record).fields,
				pos,
				cbMemberPosition: (RecordField* field) =>
					PositionKind(field),
				cbVisibilityContainer: (RecordField* field) =>
					some(VisibilityContainer(field)),
				cbMutabilityPosition: (RecordField* field) =>
					some(PositionKind(PositionKind.RecordFieldMutability(field.mutability)))),
		(ref StructBody.Union x) =>
			positionInRecordOrUnionBody!UnionMember(
				ctx, decl, x.members,
				ast.as!(StructBodyAst.Union).params,
				ast.as!(StructBodyAst.Union).members,
				pos,
				cbMemberPosition: (UnionMember* member) =>
					PositionKind(member),
				cbVisibilityContainer: (UnionMember*) =>
					none!VisibilityContainer,
				cbMutabilityPosition: (UnionMember*) =>
					none!PositionKind),
		(StructBody.Variant x) =>
			positionInSignatures(SpecOrVariant(decl), x.methods, ast.as!(StructBodyAst.Variant).methods, pos));

Opt!PositionKind positionInRecordOrUnionBody(Member)(
	in Ctx ctx,
	StructDecl* decl,
	in Member[] members,
	Opt!ParamsAst paramsAst,
	SmallArray!RecordOrUnionMemberAst memberAsts,
	Pos pos,
	in PositionKind delegate(Member*) @safe @nogc pure nothrow cbMemberPosition,
	in Opt!VisibilityContainer delegate(Member*) @safe @nogc pure nothrow cbVisibilityContainer,
	in Opt!PositionKind delegate(Member*) @safe @nogc pure nothrow cbMutabilityPosition,
) =>
	isEmpty(members)
		? none!PositionKind
		: has(paramsAst)
		? firstZipPointerFirst!(PositionKind, Member, DestructureAst)(
			members, force(paramsAst).as!(DestructureAst[]), (Member* member, DestructureAst param) =>
				positionInRecordOrUnionMemberParameter!Member(
					decl, member, param.as!(DestructureAst.Single), pos, cbMemberPosition, cbMutabilityPosition))
		: firstZipPointerFirst!(PositionKind, Member, RecordOrUnionMemberAst)(
			members, memberAsts, (Member* member, RecordOrUnionMemberAst memberAst) =>
				positionInRecordOrUnionMember!Member(
					decl, member, memberAst, pos, cbMemberPosition, cbVisibilityContainer, cbMutabilityPosition));

Opt!PositionKind positionInRecordOrUnionMemberParameter(Member)(
	StructDecl* decl,
	Member* member,
	in DestructureAst.Single param,
	Pos pos,
	in PositionKind delegate(Member*) @safe @nogc pure nothrow cbMemberPosition,
	in Opt!PositionKind delegate(Member*) @safe @nogc pure nothrow cbMutabilityPosition,
) =>
	optOr!PositionKind(
		optIf(hasPos(param.name.range, pos), () => cbMemberPosition(member)),
		() {
			Opt!Range mutRange = param.mutRange;
			return has(mutRange) && hasPos(force(mutRange), pos) ? cbMutabilityPosition(member) : none!PositionKind;
		},
		() => has(param.type)
			? positionInType(TypeContainer(decl), member.type, *force(param.type), pos)
			: none!PositionKind);

Opt!PositionKind positionInRecordOrUnionMember(Member)(
	StructDecl* decl,
	Member* member,
	in RecordOrUnionMemberAst memberAst,
	Pos pos,
	in PositionKind delegate(Member*) @safe @nogc pure nothrow cbMemberPosition,
	in Opt!VisibilityContainer delegate(Member*) @safe @nogc pure nothrow cbVisibilityContainer,
	in Opt!PositionKind delegate(Member*) @safe @nogc pure nothrow cbMutabilityPosition,
) =>
	optOr!PositionKind(
		() {
			Opt!VisibilityContainer container = cbVisibilityContainer(member);
			return has(container)
				? positionInVisibility(force(container), memberAst.visibility, pos)
				: none!PositionKind;
		}(),
		() => optIf(hasPos(memberAst.name.range, pos), () => cbMemberPosition(member)),
		() => has(memberAst.mutability) && hasPos(force(memberAst.mutability).range, pos)
			? cbMutabilityPosition(member)
			: none!PositionKind,
		() => has(memberAst.type)
			? positionInType(TypeContainer(decl), member.type, force(memberAst.type), pos)
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
				optIf(hasPos(memberAst.nameRange, pos), () => PositionKind(member)));

Opt!PositionKind positionInExpr(ref Ctx ctx, ExprContainer container, ExprRef a, Pos pos, GetPositionKind posKind) {
	ExprCtx exprCtx = ExprCtx(ctx.commonTypesPtr, container);
	return withStackMap!(Opt!PositionKind, LoopExpr*, ExprRef)((ref Loops loops) =>
		positionInExprRecur(exprCtx, loops, a, pos, posKind));
}

const struct ExprCtx {
	@safe @nogc pure nothrow:

	CommonTypes* commonTypesPtr;
	ExprContainer container;

	ref CommonTypes commonTypes() return scope =>
		*commonTypesPtr;
}

alias Loops = const StackMap!(LoopExpr*, ExprRef);

Opt!PositionKind positionInExprRecur(ref ExprCtx ctx, ref Loops loops, ExprRef a, Pos pos, GetPositionKind posKind) =>
	hasPos(a.expr.range, pos)
		? optOr!PositionKind(positionAtExpr(ctx, loops, a, pos, posKind), () {
			if (a.expr.kind.isA!(LoopExpr*)) {
				Loops inner = stackMapAdd(loops, a.expr.kind.as!(LoopExpr*), a);
				return positionInExprChild(ctx, inner, a, pos, posKind);
			} else
				return positionInExprChild(ctx, loops, a, pos, posKind);
		})
		: none!PositionKind;

Opt!PositionKind positionInExprChild(ref ExprCtx ctx, ref Loops loops, ExprRef a, Pos pos, GetPositionKind posKind) =>
	findDirectChildExpr!PositionKind(ctx.commonTypes, a, (ExprRef child) =>
		positionInExprRecur(ctx, loops, child, pos, posKind));

Opt!PositionKind positionAtExpr(ref ExprCtx ctx, ref Loops loops, ExprRef a, Pos pos, GetPositionKind posKind) {
	ExprAst* ast = a.expr.ast;
	PositionKind expressionPosition(ExpressionPositionKind x) =>
		PositionKind(ExpressionPosition(ctx.container, a, x));
	Opt!PositionKind inDestructure(in Destructure x, in DestructureAst y) =>
		positionInDestructure(ctx, x, y, pos);
	PositionKind keyword(ExprKeyword k) =>
		expressionPosition(ExpressionPositionKind(k));
	Opt!PositionKind keywordAt(Range range, ExprKeyword k, ) =>
		optIf(hasPos(range, pos), () => keyword(k));
	PositionKind local(ExpressionPositionKind.LocalRef.Kind kind, Local* local) =>
		expressionPosition(ExpressionPositionKind(ExpressionPositionKind.LocalRef(kind, local)));
	PositionKind loopKeyword(ExpressionPositionKind.LoopKeyword.Kind kind, LoopExpr* loop) =>
		expressionPosition(ExpressionPositionKind(
			ExpressionPositionKind.LoopKeyword(kind, stackMapMustGet(loops, loop))));
	Opt!PositionKind call(ExpressionPositionKind kind) {
		bool ok = () {
			final switch (posKind) {
				case GetPositionKind.target:
					return posIsAtCall(*ast, pos);
				case GetPositionKind.signatureHelp:
					return true;
			}
		}();
		return optIf(ok, () => expressionPosition(kind));
	}

	return a.expr.kind.match!(Opt!PositionKind)(
		(ref AssertOrForbidExpr x) {
			AssertOrForbidAst assert_ = ast.kind.as!AssertOrForbidAst;
			return optOr!PositionKind(
				keywordAt(assert_.keywordRange(ast), x.isForbid ? ExprKeyword.forbid : ExprKeyword.assert_),
				() => positionAtCondition(ctx, x.condition, a, assert_.condition, pos),
				() => has(assert_.thrown)
					? keywordAt(force(assert_.thrown).colonRange, ExprKeyword.colonInAssertOrForbid)
					: none!PositionKind);
		},
		(BogusCallExpr x) =>
			call(ExpressionPositionKind(x)),
		(BogusExpr _) =>
			none!PositionKind,
		(CallExpr x) =>
			call(ExpressionPositionKind(x)),
		(ref CallOptionExpr x) =>
			optOr!PositionKind(
				keywordAt(force(ast.kind.as!CallAst.keywordRange), ExprKeyword.questionDotOrSubscript),
				() => optIf(posIsAtCall(*ast, pos), () =>
					expressionPosition(ExpressionPositionKind(x)))),
		(ClosureGetExpr x) =>
			some(local(ExpressionPositionKind.LocalRef.Kind.closureGet, x.local)),
		(ClosureSetExpr x) =>
			optIf(isAtAssignment(ast, pos), () =>
				local(ExpressionPositionKind.LocalRef.Kind.closureSet, x.local)),
		(ExternExpr x) =>
			some(expressionPosition(ExpressionPositionKind(x))),
		(ref FinallyExpr x) =>
			keywordAt(ast.kind.as!(FinallyAst*).finallyKeywordRange(ast), ExprKeyword.finally_),
		(FunPointerExpr x) =>
			some(expressionPosition(ExpressionPositionKind(x))),
		(ref IfExpr x) {
			IfAst if_ = ast.kind.as!IfAst;
			return optOr!PositionKind(
				keywordAt(if_.firstKeywordRange, ExprKeyword.guardIfOrUnless),
				() => positionAtCondition(ctx, x.condition, a, if_.condition, pos),
				() => has(if_.secondKeywordRange)
					? keywordAt(force(if_.secondKeywordRange), ifSecondKeyword(if_.kind))
					: none!PositionKind);
		},
		(ref LambdaExpr x) {
			if (ast.kind.isA!(LambdaAst*)) {
				LambdaAst* lambda = ast.kind.as!(LambdaAst*);
				return optOr!PositionKind(
					keywordAt(lambda.arrowRange, ExprKeyword.lambdaArrow),
					() => inDestructure(x.param, lambda.param));
			} else if (ast.kind.isA!(ForAst*)) {
				ForAst* for_ = ast.kind.as!(ForAst*);
				// 'for' keyword is handled in the CallExpr
				return optOr!PositionKind(
					x.isIgnore ? none!PositionKind : inDestructure(x.param, for_.param),
					() => keywordAt(for_.colonRange, ExprKeyword.colonInFor));
			} else if (ast.kind.isA!(WithAst*)) {
				// 'with' keyword is handled in the CallExpr
				WithAst* with_ = ast.kind.as!(WithAst*);
				return optOr!PositionKind(
					inDestructure(x.param, with_.param),
					() => keywordAt(with_.colonRange, ExprKeyword.colonInWith));
			} else
				return none!PositionKind;
		},
		(ref LetExpr x) =>
			inDestructure(x.destructure, ast.kind.as!(LetAst*).destructure),
		(LiteralExpr _) =>
			some(expressionPosition(ExpressionPositionKind(ExpressionPositionKind.Literal()))),
		(LiteralStringLikeExpr _) =>
			some(expressionPosition(ExpressionPositionKind(ExpressionPositionKind.Literal()))),
		(LocalGetExpr x) =>
			some(local(ExpressionPositionKind.LocalRef.Kind.get, x.local)),
		(LocalPointerExpr x) =>
			some(optOrDefault!PositionKind(
				keywordAt(ast.kind.as!(PtrAst*).keywordRange(ast), ExprKeyword.ampersand),
				() => local(ExpressionPositionKind.LocalRef.Kind.pointer, x.local))),
		(LocalSetExpr x) =>
			optIf(isAtAssignment(ast, pos), () =>
				local(ExpressionPositionKind.LocalRef.Kind.set, x.local)),
		(ref LoopExpr x) =>
			hasPos(ast.kind.as!(LoopAst*).keywordRange(ast), pos)
				? some(expressionPosition(ExpressionPositionKind(
					ExpressionPositionKind.LoopKeyword(ExpressionPositionKind.LoopKeyword.Kind.loop, a))))
				: none!PositionKind,
		(ref LoopBreakExpr x) =>
			optIf(hasPos(ast.kind.as!(LoopBreakAst*).keywordRange(ast), pos), () =>
				loopKeyword(ExpressionPositionKind.LoopKeyword.Kind.break_, x.loop)),
		(LoopContinueExpr x) =>
			some(loopKeyword(ExpressionPositionKind.LoopKeyword.Kind.continue_, x.loop)),
		(ref LoopWhileOrUntilExpr x) {
			LoopWhileOrUntilAst* loop = ast.kind.as!(LoopWhileOrUntilAst*);
			return optOr!PositionKind(
				keywordAt(
					loop.keywordRange(ast),
					x.isUntil ? ExprKeyword.until : ExprKeyword.while_),
				() => positionAtCondition(ctx, x.condition, a, loop.condition, pos));
		},
		(ref MatchEnumExpr x) =>
			positionAtMatchEnum(ctx, a, x, ast.kind.as!MatchAst, pos),
		(ref MatchIntegralExpr x) =>
			positionAtMatchIntegral(ctx, a, x, ast.kind.as!MatchAst, pos),
		(ref MatchStringLikeExpr x) =>
			positionAtMatchStringLike(ctx, a, x, ast.kind.as!MatchAst, pos),
		(ref MatchUnionExpr x) =>
			positionAtMatchUnion(ctx, a, x, ast.kind.as!MatchAst, pos),
		(ref MatchVariantExpr x) =>
			positionAtMatchVariant(ctx, a, x, ast.kind.as!MatchAst, pos),
		(ref RecordFieldPointerExpr x) =>
			keywordAt(ast.kind.as!(PtrAst*).keywordRange(ast), ExprKeyword.ampersand),
		(ref SeqExpr x) =>
			none!PositionKind,
		(ref ThrowExpr x) =>
			keywordAt(ast.kind.as!(ThrowAst*).keywordRange(ast), ExprKeyword.throw_),
		(ref TrustedExpr x) =>
			keywordAt(ast.kind.as!(TrustedAst*).keywordRange(ast), ExprKeyword.trusted),
		(ref TryExpr x) =>
			positionAtTry(ctx, a, x, ast.kind.as!TryAst, pos),
		(ref TryLetExpr x) =>
			positionAtTryLet(ctx, a, x, ast.kind.as!(TryLetAst*), pos),
		(ref TypedExpr x) {
			TypedAst* tAst = ast.kind.as!(TypedAst*);
			return optOr!PositionKind(
				keywordAt(tAst.keywordRange, ExprKeyword.colonColon),
				() => positionInType(ctx.container.toTypeContainer, a.type, tAst.type, pos));
		});
}

ExprKeyword ifSecondKeyword(IfAst.Kind kind) {
	final switch (kind) {
		case IfAst.Kind.guardWithColon:
		case IfAst.Kind.ternaryWithElse:
			return ExprKeyword.colonInIf;
		case IfAst.Kind.ifElif:
			return ExprKeyword.elif;
		case IfAst.Kind.ifElse:
			return ExprKeyword.else_;
		case IfAst.Kind.guardWithoutColon:
		case IfAst.Kind.ifWithoutElse:
		case IfAst.Kind.ternaryWithoutElse:
		case IfAst.Kind.unless:
			assert(0);
	}
}

Opt!PositionKind positionAtCondition(
	in ExprCtx ctx,
	in Condition condition,
	ExprRef source,
	in ConditionAst ast,
	Pos pos,
) =>
	condition.matchIn!(Opt!PositionKind)(
		(in Expr _) =>
			none!PositionKind,
		(in Condition.UnpackOption x) {
			ConditionAst.UnpackOption* unpackAst = ast.as!(ConditionAst.UnpackOption*);
			return optOr!PositionKind(
				positionInDestructure(ctx, x.destructure, unpackAst.destructure, pos),
				() => optIf(hasPos(unpackAst.questionEqualsRange, pos), () =>
					PositionKind(ExpressionPosition(ctx.container, source, ExpressionPositionKind(
						ExprKeyword.questionEquals)))));
		});

bool isAtAssignment(in ExprAst* ast, Pos pos) {
	if (ast.kind.isA!(AssignmentAst*)) {
		AssignmentAst* assign = ast.kind.as!(AssignmentAst*);
		return hasPos(assign.left.range, pos) || hasPos(assign.keywordRange, pos);
	} else if (ast.kind.isA!AssignmentCallAst) {
		AssignmentCallAst call = ast.kind.as!AssignmentCallAst;
		return hasPos(call.left.range, pos) || hasPos(call.keywordRange, pos);
	} else
		assert(false);
}

bool posIsAtCall(in ExprAst a, Pos pos) {
	if (a.kind.isA!CallAst) {
		CallAst call = a.kind.as!CallAst;
		final switch (call.style) {
			case CallAst.Style.comma:
			case CallAst.Style.emptyParens:
			case CallAst.Style.subscript:
			case CallAst.Style.questionSubscript:
				return false;
			case CallAst.Style.augment:
			case CallAst.Style.dot:
			case CallAst.Style.infix:
			case CallAst.Style.prefixBang:
			case CallAst.Style.prefixOperator:
			case CallAst.Style.questionDot:
			case CallAst.Style.single:
			case CallAst.Style.suffixBang:
				return hasPos(call.funName.range, pos);
		}
	} else if (a.kind.isA!IdentifierAst)
		return hasPos(a.range, pos);
	else if (a.kind.isA!(ForAst*))
		// Handle the colon when handling the LambdaExpr
		return hasPos(a.kind.as!(ForAst*).forKeywordRange(a), pos);
	else if (a.kind.isA!(WithAst*))
		return hasPos(a.kind.as!(WithAst*).withKeywordRange(a), pos);
	else if (a.kind.isA!ArrowAccessAst)
		return hasPos(a.kind.as!ArrowAccessAst.arrowAndNameRange, pos);
	else
		// For InterpolatedAst, we don't want to get the call position, we want position at the args instead.
		return false;
}

Opt!PositionKind positionAtMatchEnum(in ExprCtx ctx, ExprRef expr, ref MatchEnumExpr a, ref MatchAst ast, Pos pos) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchEnumExpr.Case, CaseAst)(
			a.cases, ast.cases,
			(MatchEnumExpr.Case case_, CaseAst caseAst) =>
				optIf(hasPos(caseAst.keywordAndMemberNameRange, pos), () =>
					PositionKind(PositionKind.MatchEnumCase(case_.member)))));

Opt!PositionKind positionAtMatchIntegral(
	in ExprCtx ctx,
	ExprRef expr,
	ref MatchIntegralExpr a,
	ref MatchAst ast,
	Pos pos,
) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchIntegralExpr.Case, CaseAst)(
			a.cases, ast.cases,
			(MatchIntegralExpr.Case case_, CaseAst caseAst) =>
				optIf(hasPos(caseAst.keywordAndMemberNameRange, pos), () =>
					PositionKind(PositionKind.MatchIntegralCase(a.kind, case_.value)))));

Opt!PositionKind positionAtMatchStringLike(
	in ExprCtx ctx,
	ExprRef expr,
	ref MatchStringLikeExpr a,
	ref MatchAst ast,
	Pos pos,
) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchStringLikeExpr.Case, CaseAst)(
			a.cases, ast.cases,
			(MatchStringLikeExpr.Case case_, CaseAst caseAst) =>
				optIf(hasPos(caseAst.keywordAndMemberNameRange, pos), () =>
					PositionKind(PositionKind.MatchStringLikeCase(
						TypeWithContainer(a.matched.type, ctx.container.toTypeContainer),
						case_.value)))));

Opt!PositionKind positionAtMatchUnion(ref ExprCtx ctx, ExprRef expr, ref MatchUnionExpr a, ref MatchAst ast, Pos pos) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, ast, pos),
		() => firstZipIfSizeEq!(PositionKind, MatchUnionExpr.Case, CaseAst)(
			a.cases, ast.cases,
			(MatchUnionExpr.Case case_, CaseAst caseAst) =>
				positionAtMatchUnionCase(ctx, case_, caseAst, pos)));

Opt!PositionKind positionAtMatchUnionCase(ref ExprCtx ctx, MatchUnionExpr.Case case_, CaseAst ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordAndMemberNameRange, pos), () =>
			PositionKind(PositionKind.MatchUnionCase(case_.member))),
		() => positionInMatchCaseDestructure(ctx, case_.destructure, ast.member, pos));

Opt!PositionKind positionAtMatchVariant(
	ref ExprCtx ctx,
	ExprRef expr,
	ref MatchVariantExpr a,
	in MatchAst ast,
	Pos pos,
) =>
	optOr!PositionKind(
		positionAtMatchKeyword(ctx, expr, ast, pos),
		() => positionAtMatchVariantCases(ctx, a.cases, ast.cases, pos));

Opt!PositionKind positionAtMatchVariantCases(
	ref ExprCtx ctx,
	in MatchVariantExpr.Case[] cases,
	in CaseAst[] caseAsts,
	Pos pos,
) =>
	firstZipIfSizeEq!(PositionKind, MatchVariantExpr.Case, CaseAst)(
		cases, caseAsts,
		(MatchVariantExpr.Case case_, CaseAst caseAst) =>
			positionAtMatchVariantCase(ctx, case_, caseAst, pos));

Opt!PositionKind positionAtMatchVariantCase(ref ExprCtx ctx, MatchVariantExpr.Case case_, CaseAst ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordAndMemberNameRange, pos), () =>
			PositionKind(PositionKind.MatchVariantCase(ctx.container, case_.member))),
		() => positionInMatchCaseDestructure(ctx, case_.destructure, ast.member, pos));

Opt!PositionKind positionInMatchCaseDestructure(
	ref ExprCtx ctx,
	in Destructure destructure,
	in CaseMemberAst ast,
	Pos pos,
) =>
	ast.isA!(CaseMemberAst.Name) && has(ast.as!(CaseMemberAst.Name).destructure)
		? positionInDestructure(ctx, destructure, force(ast.as!(CaseMemberAst.Name).destructure), pos)
		: none!PositionKind;

Opt!PositionKind positionAtMatchKeyword(in ExprCtx ctx, ExprRef matchExpr, in MatchAst ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.keywordRange(matchExpr.expr.ast), pos), () =>
			PositionKind(ExpressionPosition(ctx.container, matchExpr, ExpressionPositionKind(ExprKeyword.match)))),
		() => optIf(has(ast.else_) && hasPos(force(ast.else_).keywordRange, pos), () =>
			PositionKind(ExpressionPosition(ctx.container, matchExpr, ExpressionPositionKind(ExprKeyword.else_)))));

Opt!PositionKind positionAtTry(in ExprCtx ctx, ExprRef expr, ref TryExpr a, TryAst ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.tryKeywordRange(expr.expr.ast), pos), () =>
			PositionKind(ExpressionPosition(ctx.container, expr, ExpressionPositionKind(ExprKeyword.try_)))),
		() => positionAtMatchVariantCases(ctx, a.catches, ast.catches, pos));

Opt!PositionKind positionAtTryLet(in ExprCtx ctx, ExprRef expr, ref TryLetExpr a, TryLetAst* ast, Pos pos) =>
	optOr!PositionKind(
		optIf(hasPos(ast.tryKeywordRange(expr.expr.ast), pos), () =>
			PositionKind(ExpressionPosition(ctx.container, expr, ExpressionPositionKind(ExprKeyword.try_)))),
		() => positionInDestructure(ctx, a.destructure, ast.destructure, pos),
		() => optIf(hasPos(combineRanges(ast.catchKeywordRange, ast.catchMember.nameRange), pos), () =>
			PositionKind(PositionKind.MatchVariantCase(ctx.container, a.catch_.member))),
		() => positionInMatchCaseDestructure(ctx, a.catch_.destructure, ast.catchMember, pos));

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
		(in TypeAst.Bogus) =>
			none!PositionKind,
		(in TypeAst.Fun x) =>
			optIf(hasPos(x.kindRange, pos), () => here),
		(in TypeAst.Map x) =>
			none!PositionKind,
		(in NameAndRange x) =>
			some(here),
		(in TypeAst.SuffixName x) =>
			optIf(hasPos(x.name.range, pos), () => here),
		(in TypeAst.SuffixSpecial x) =>
			optIf(hasPos(x.suffixRange, pos), () => here),
		(in TypeAst.Tuple) =>
			none!PositionKind);
}

bool optHasPos(in Opt!Range a, Pos p) =>
	has(a) && hasPos(force(a), p);
