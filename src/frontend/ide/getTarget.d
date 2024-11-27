module frontend.ide.getTarget;

@safe @nogc pure nothrow:

import frontend.ide.position :
	assertLocalContainer,
	ExprContainer,
	ExpressionPosition,
	ExpressionPositionLiteral,
	ExprKeyword,
	LocalRef,
	LoopKeyword,
	Position,
	PositionDocRef,
	PositionImportedModule,
	PositionImportedName,
	PositionKeyword,
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
	typeContainerFor,
	TypeParamWithContainer;
import model.model :
	AutoFun,
	BogusCallExpr,
	BogusType,
	BuiltinFun,
	Called,
	CalledDecl,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	Destructure,
	DocCommentReferenceBogus,
	EnumOrFlagsMember,
	Expr,
	ExprRef,
	ExternExpr,
	FlagsFunction,
	forbidModule,
	FunBody,
	FunDecl,
	FunInst,
	FunPointerExpr,
	Local,
	Module,
	mustUnwrapOptionType,
	RecordField,
	Signature,
	SpecDecl,
	StructAlias,
	StructDecl,
	StructInst,
	Test,
	TypeParamIndex,
	TypeWithContainer,
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
		PositionImportedName,
		PositionLocal,
		Loop,
		Module*,
		RecordField*,
		SpecDecl*,
		Signature*,
		StructAlias*,
		StructDecl*,
		TypeParamWithContainer,
		VarDecl*);
}

Opt!Target targetForPosition(Position pos) =>
	pos.kind.matchWithPointers!(Opt!Target)(
		(PositionDocRef docRef) =>
			docRef.ref_.matchWithPointers!(Opt!Target)(
				(DocCommentReferenceBogus _) =>
					none!Target,
				(CalledSpecSig x) =>
					some(Target(x.nonInstantiatedSig)),
				(EnumOrFlagsMember* x) =>
					some(Target(x)),
				(FunDecl* x) =>
					some(Target(x)),
				(Local* x) =>
					some(Target(PositionLocal(assertLocalContainer(docRef.container), x))),
				(RecordField* x) =>
					some(Target(x)),
				(Signature* x) =>
					some(Target(x)),
				(StructAlias* x) =>
					some(Target(x)),
				(StructDecl* x) =>
					some(Target(x)),
				(SpecDecl* x) =>
					some(Target(x)),
				(TypeParamIndex x) =>
					some(Target(TypeParamWithContainer(x, forbidModule(typeContainerFor(docRef.container))))),
				(VarDecl* x) =>
					some(Target(x))),
		(EnumOrFlagsMember* x) =>
			some(Target(x)),
		(ExpressionPosition x) =>
			exprTarget(x),
		(FunDecl* x) =>
			some(Target(x)),
		(PositionImportedModule x) =>
			some(Target(x.modulePtr)),
		(PositionImportedName x) =>
			some(Target(x)),
		(PositionKeyword _) =>
			none!Target,
		(PositionLocal x) =>
			some(Target(x)),
		(PositionMatchEnumCase x) =>
			some(Target(x.member)),
		(PositionMatchIntegralCase x) =>
			none!Target,
		(PositionMatchStringLikeCase x) =>
			none!Target,
		(PositionMatchSumTypeCase x) =>
			some(Target(x.member.decl)),
		(PositionModifier _) =>
			none!Target,
		(PositionModifierExtern _) =>
			none!Target,
		(PositionModule _) =>
			some(Target(pos.module_)),
		(RecordField* x) =>
			some(Target(x)),
		(PositionRecordFieldMutability _) =>
			none!Target,
		(SpecDecl* x) =>
			some(Target(x)),
		(Signature* x) =>
			some(Target(x)),
		(PositionSpecUse x) =>
			some(Target(x.spec.decl)),
		(StructAlias* x) =>
			some(Target(x)),
		(StructDecl* x) =>
			some(Target(x)),
		(Test*) =>
			none!Target,
		(TypeWithContainer x) =>
			x.type.matchWithPointers!(Opt!Target)(
				(BogusType _) =>
					none!Target,
				(TypeParamIndex p) =>
					some(Target(TypeParamWithContainer(p, forbidModule(x.container)))),
				(StructInst* x) =>
					some(Target(x.decl))),
		(TypeParamWithContainer x) =>
			some(Target(x)),
		(VarDecl* x) =>
			some(Target(x)),
		(PositionVisibilityMark _) =>
			none!Target);

private:

Opt!Target exprTarget(ExpressionPosition a) =>
	a.kind.match!(Opt!Target)(
		(BogusCallExpr x) =>
			optIf(x.candidates.length == 1, () =>
				calledDeclTarget(only(x.candidates))),
		(CallExpr x) =>
			calledTarget(x.called),
		(CallOptionExpr x) =>
			calledTarget(x.called),
		(ExprKeyword x) =>
			none!Target,
		(ExternExpr _) =>
			none!Target,
		(FunPointerExpr x) =>
			calledTarget(x.called),
		(ExpressionPositionLiteral _) =>
			none!Target,
		(LocalRef x) =>
			some(Target(PositionLocal(a.container.toLocalContainer, x.local))),
		(LoopKeyword x) =>
			some(Target(Target.Loop(a.container, x.loop))));

Target calledDeclTarget(ref CalledDecl a) =>
	a.matchWithPointers!Target(
		(FunDecl* x) =>
			funDeclTarget(x),
		(CalledSpecSig x) =>
			Target(x.nonInstantiatedSig));

Opt!Target calledTarget(ref Called a) =>
	a.match!(Opt!Target)(
		(ref Called.Bogus) =>
			none!Target,
		(ref FunInst funInst) =>
			some(funDeclTarget(funInst.decl)),
		(CalledSpecSig x) =>
			some(Target(x.nonInstantiatedSig)));

Target funDeclTarget(FunDecl* a) =>
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
		(FunBody.CreateRecordAndConvertToSumType x) =>
			Target(x.member.decl),
		(FunBody.CreateSumType x) =>
			Target(only(a.params.as!(Destructure[])).type.as!(StructInst*).decl),
		(Expr _) =>
			Target(a),
		(FunBody.Extern) =>
			Target(a),
		(FunBody.FileImport) =>
			// TODO: Target for a file showing all imports
			Target(a),
		(FlagsFunction x) =>
			returnTypeTarget(a),
		(FunBody.Method x) =>
			Target(x.method),
		(FunBody.RecordFieldCall x) =>
			Target(x.field),
		(FunBody.RecordFieldGet x) =>
			Target(x.field),
		(FunBody.RecordFieldPointer x) =>
			Target(x.field),
		(FunBody.RecordFieldSet x) =>
			Target(x.field),
		(FunBody.SumTypeMemberGet) =>
			Target(mustUnwrapOptionType(a.returnType).as!(StructInst*).decl),
		(FunBody.VarGet x) =>
			Target(x.var),
		(FunBody.VarSet x) =>
			Target(x.var));

Target returnTypeTarget(FunDecl* fun) =>
	Target(fun.returnType.as!(StructInst*).decl);
