module frontend.ide.getTarget;

@safe @nogc pure nothrow:

import frontend.ide.position :
	assertLocalContainer, ExprContainer, ExpressionPosition, ExpressionPositionKind, ExprKeyword, Position, PositionKind, typeContainerFor;
import model.model :
	AutoFun,
	BogusCallExpr,
	BuiltinFun,
	Called,
	CalledDecl,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	CommonTypes,
	Destructure,
	DocCommentReference,
	EnumOrFlagsFunction,
	EnumOrFlagsMember,
	Expr,
	ExprRef,
	ExternExpr,
	forbidModule,
	FunBody,
	FunDecl,
	FunDeclSource,
	FunInst,
	FunPointerExpr,
	Local,
	Module,
	mustUnwrapOptionType,
	RecordField,
	SpecDecl,
	StructAlias,
	StructDecl,
	StructInst,
	Test,
	TypeParamIndex,
	TypeWithContainer,
	UnionMember,
	VarDecl;
import util.col.array : only;
import util.opt : none, Opt, optIf, some;
import util.union_ : Union;

immutable struct Target {
	immutable struct Loop {
		ExprContainer container;
		ExprRef loop;
	}

	mixin Union!(
		EnumOrFlagsMember*,
		FunDecl*,
		PositionKind.ImportedName,
		PositionKind.LocalPosition,
		Loop,
		Module*,
		RecordField*,
		SpecDecl*,
		PositionKind.SpecSig,
		StructAlias*,
		StructDecl*,
		PositionKind.TypeParamWithContainer,
		UnionMember*,
		VarDecl*,
		PositionKind.VariantMethod,
	);
}

Opt!Target targetForPosition(in CommonTypes commonTypes, Position pos) =>
	pos.kind.matchWithPointers!(Opt!Target)(
		(PositionKind.DocRef docRef) =>
			docRef.ref_.matchWithPointers!(Opt!Target)(
				(DocCommentReference.Bogus) =>
					none!Target,
				(CalledSpecSig x) =>
					some(calledSpecSigTarget(x)),
				(FunDecl* x) =>
					some(Target(x)),
				(Local* x) =>
					some(Target(PositionKind.LocalPosition(assertLocalContainer(docRef.container), x))),
				(StructAlias* x) =>
					some(Target(x)),
				(StructDecl* x) =>
					some(Target(x)),
				(SpecDecl* x) =>
					some(Target(x)),
				(TypeParamIndex x) =>
					some(Target(PositionKind.TypeParamWithContainer(x, forbidModule(typeContainerFor(docRef.container)))))),
		(EnumOrFlagsMember* x) =>
			some(Target(x)),
		(ExpressionPosition x) =>
			exprTarget(commonTypes, x),
		(FunDecl* x) =>
			some(Target(x)),
		(PositionKind.ImportedModule x) =>
			some(Target(x.modulePtr)),
		(PositionKind.ImportedName x) =>
			some(Target(x)),
		(PositionKind.Keyword _) =>
			none!Target,
		(PositionKind.LocalPosition x) =>
			some(Target(x)),
		(PositionKind.MatchEnumCase x) =>
			some(Target(x.member)),
		(PositionKind.MatchIntegralCase x) =>
			none!Target,
		(PositionKind.MatchStringLikeCase x) =>
			none!Target,
		(PositionKind.MatchUnionCase x) =>
			some(Target(x.member)),
		(PositionKind.MatchVariantCase x) =>
			some(Target(x.member.decl)),
		(PositionKind.Modifier) =>
			none!Target,
		(PositionKind.ModifierExtern) =>
			none!Target,
		(PositionKind.ModulePosition) =>
			some(Target(pos.module_)),
		(RecordField* x) =>
			some(Target(x)),
		(PositionKind.RecordFieldMutability) =>
			none!Target,
		(SpecDecl* x) =>
			some(Target(x)),
		(PositionKind.SpecSig x) =>
			some(Target(x)),
		(PositionKind.SpecUse x) =>
			some(Target(x.spec.decl)),
		(StructAlias* x) =>
			some(Target(x)),
		(StructDecl* x) =>
			some(Target(x)),
		(Test*) =>
			none!Target,
		(TypeWithContainer x) =>
			x.type.matchWithPointers!(Opt!Target)(
				(Bogus) =>
					none!Target,
				(TypeParamIndex p) =>
					some(Target(PositionKind.TypeParamWithContainer(p, forbidModule(x.container)))),
				(StructInst* x) =>
					some(Target(x.decl))),
		(PositionKind.TypeParamWithContainer x) =>
			some(Target(x)),
		(UnionMember* x) =>
			some(Target(x)),
		(VarDecl* x) =>
			some(Target(x)),
		(PositionKind.VariantMethod x) =>
			some(Target(x)),
		(PositionKind.VisibilityMark) =>
			none!Target);

private:

Opt!Target exprTarget(in CommonTypes commonTypes, ExpressionPosition a) =>
	a.kind.match!(Opt!Target)(
		(BogusCallExpr x) =>
			optIf(x.candidates.length == 1, () =>
				calledDeclTarget(commonTypes, only(x.candidates))),
		(CallExpr x) =>
			calledTarget(commonTypes, x.called),
		(CallOptionExpr x) =>
			calledTarget(commonTypes, x.called),
		(ExprKeyword x) =>
			none!Target,
		(ExternExpr _) =>
			none!Target,
		(FunPointerExpr x) =>
			calledTarget(commonTypes, x.called),
		(ExpressionPositionKind.Literal) =>
			none!Target,
		(ExpressionPositionKind.LocalRef x) =>
			some(Target(PositionKind.LocalPosition(a.container.toLocalContainer, x.local))),
		(ExpressionPositionKind.LoopKeyword x) =>
			some(Target(Target.Loop(a.container, x.loop))));

Target calledDeclTarget(in CommonTypes commonTypes, ref CalledDecl a) =>
	a.matchWithPointers!Target(
		(FunDecl* x) =>
			funDeclTarget(commonTypes, x),
		(CalledSpecSig x) =>
			calledSpecSigTarget(x));

Opt!Target calledTarget(in CommonTypes commonTypes, ref Called a) =>
	a.match!(Opt!Target)(
		(ref Called.Bogus) =>
			none!Target,
		(ref FunInst funInst) =>
			some(funDeclTarget(commonTypes, funInst.decl)),
		(CalledSpecSig x) =>
			some(calledSpecSigTarget(x)));

Target calledSpecSigTarget(CalledSpecSig a) =>
	Target(PositionKind.SpecSig(a.specInst.decl, a.nonInstantiatedSig));

Target funDeclTarget(in CommonTypes commonTypes, FunDecl* a) =>
	a.body_.match!Target(
		(FunBody.Bogus) =>
			Target(a),
		(AutoFun _) =>
			Target(a),
		(BuiltinFun _) =>
			Target(a),
		(FunBody.CreateEnumOrFlags x) =>
			// goto the enum member
			Target(x.member),
		(FunBody.CreateExtern) =>
			// goto the return type
			returnTypeTarget(a),
		(FunBody.CreateRecord) =>
			returnTypeTarget(a),
		(FunBody.CreateRecordAndConvertToVariant x) =>
			Target(x.member.decl),
		(FunBody.CreateUnion) =>
			// TODO: goto the particular union member
			returnTypeTarget(a),
		(FunBody.CreateVariant x) =>
			Target(only(a.params.as!(Destructure[])).type.as!(StructInst*).decl),
		(EnumOrFlagsFunction x) =>
			returnTypeTarget(a),
		(Expr _) =>
			Target(a),
		(FunBody.Extern) =>
			Target(a),
		(FunBody.FileImport) =>
			// TODO: Target for a file showing all imports
			Target(a),
		(FunBody.RecordFieldCall x) =>
			Target(x.field),
		(FunBody.RecordFieldGet x) =>
			Target(x.field),
		(FunBody.RecordFieldPointer x) =>
			Target(x.field),
		(FunBody.RecordFieldSet x) =>
			Target(x.field),
		(FunBody.UnionMemberGet x) =>
			Target(x.member),
		(FunBody.VarGet x) =>
			Target(x.var),
		(FunBody.VariantMemberGet) =>
			Target(mustUnwrapOptionType(commonTypes, a.returnType).as!(StructInst*).decl),
		(FunBody.VariantMethod x) =>
			Target(a.source.as!(FunDeclSource.VariantMethod)),
		(FunBody.VarSet x) =>
			Target(x.var));

Target returnTypeTarget(FunDecl* fun) =>
	Target(fun.returnType.as!(StructInst*).decl);
