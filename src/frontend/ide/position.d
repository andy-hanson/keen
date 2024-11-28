module frontend.ide.position;

@safe @nogc pure nothrow:

import model.ast : ModifierKeyword, NameAndRange;
import model.integralValues : IntegralValue;
import model.model :
	AnyDecl,
	asTypeContainer,
	BogusCallExpr,
	CallExpr,
	CallOptionExpr,
	DocComment,
	DocCommentReference,
	emptySpecs,
	EnumOrFlagsMember,
	ExprRef,
	ExternExpr,
	FunDecl,
	FunPointerExpr,
	ImportOrExport,
	Local,
	MatchIntegralKind,
	Module,
	NameReferents,
	RecordField,
	SpecDecl,
	Specs,
	Signature,
	SignatureContainer,
	SpecInst,
	StructAlias,
	StructDecl,
	StructInst,
	Test,
	toTypeContainer,
	TypeContainer,
	TypeParamIndex,
	TypeWithContainer,
	VarDecl,
	Visibility;
import util.opt : Opt;
import util.symbol : Symbol;
import util.union_ : TaggedUnion, Union;
import util.uri : Uri;

immutable struct Position {
	Module* module_;
	PositionKind kind;
}

immutable struct ExprContainer {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(FunDecl*, Test*);

	LocalContainer toLocalContainer() return scope =>
		matchWithPointers!LocalContainer(
			(FunDecl* x) =>
				LocalContainer(x),
			(Test* x) =>
				LocalContainer(x));

	TypeContainer toTypeContainer() return scope =>
		toLocalContainer.toTypeContainer;

	Uri moduleUri() scope =>
		toTypeContainer.moduleUri;

	Specs specs() scope =>
		match!Specs(
			(ref FunDecl x) =>
				x.specs,
			(ref Test _) =>
				emptySpecs);

	DocComment docComment() return scope =>
		match!DocComment(
			(ref FunDecl x) =>
				x.docComment,
			(ref Test x) =>
				x.docComment);
}

immutable struct LocalContainer {
	@safe @nogc pure nothrow:
	// A SpecDecl* can contain parameters in its signatures, and a StructDecl* for a variant can too
	mixin TaggedUnion!(FunDecl*, Test*, SpecDecl*, StructDecl*);

	TypeContainer toTypeContainer() return scope =>
		matchWithPointers!TypeContainer(
			(FunDecl* x) =>
				TypeContainer(x),
			(Test* x) =>
				TypeContainer(x),
			(SpecDecl* x) =>
				TypeContainer(x),
			(StructDecl* x) =>
				TypeContainer(x));

	Uri moduleUri() scope =>
		toTypeContainer.moduleUri;

	NameAndRange[] typeParams() =>
		toTypeContainer.typeParams;
}

LocalContainer assertLocalContainer(DocCommentContainer a) =>
	a.matchWithPointers!LocalContainer(
		(AnyDecl x) =>
			assertLocalContainer(x),
		(EnumOrFlagsMember*) =>
			assert(false),
		(Module*) =>
			assert(false),
		(RecordField*) =>
			assert(false),
		(Signature* x) =>
			asLocalContainer(x.container));
LocalContainer assertLocalContainer(AnyDecl a) =>
	a.matchWithPointers!LocalContainer(
		(FunDecl* x) =>
			LocalContainer(x),
		(SpecDecl* x) =>
			LocalContainer(x),
		(StructAlias*) =>
			assert(false),
		(StructDecl* x) =>
			LocalContainer(x),
		(Test* x) =>
			LocalContainer(x),
		(VarDecl* x) =>
			assert(false));
LocalContainer asLocalContainer(SignatureContainer a) =>
	a.matchWithPointers!LocalContainer(
		(SpecDecl* x) =>
			LocalContainer(x),
		(StructDecl* x) =>
			LocalContainer(x));

immutable struct VisibilityContainer {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(FunDecl*, RecordField*, SpecDecl*, StructAlias*, StructDecl*, VarDecl*);

	Symbol name() scope =>
		matchIn!Symbol(
			(in FunDecl x) => x.name,
			(in RecordField x) => x.name,
			(in SpecDecl x) => x.name,
			(in StructAlias x) => x.name,
			(in StructDecl x) => x.name,
			(in VarDecl x) => x.name);

	Visibility visibility() scope =>
		matchIn!Visibility(
			(in FunDecl x) => x.visibility,
			(in RecordField x) => x.visibility,
			(in SpecDecl x) => x.visibility,
			(in StructAlias x) => x.visibility,
			(in StructDecl x) => x.visibility,
			(in VarDecl x) => x.visibility);
}

immutable struct DocCommentContainer {
	@safe @nogc pure nothrow:
	mixin Union!(AnyDecl, EnumOrFlagsMember*, Module*, RecordField*, Signature*);

	DocComment docComment() =>
		matchWithPointers!DocComment(
			(AnyDecl x) =>
				x.docComment,
			(EnumOrFlagsMember* x) =>
				x.docComment,
			(Module* x) =>
				x.docComment,
			(RecordField* x) =>
				x.docComment,
			(Signature* x) =>
				x.docComment);
}

// WARN: typeContainerFor(a).docComment is not always a.docComment
TypeContainer typeContainerFor(DocCommentContainer a) =>
	a.matchWithPointers!TypeContainer(
		(AnyDecl x) =>
			toTypeContainer(x),
		(EnumOrFlagsMember* x) =>
			TypeContainer(x.containingEnum),
		(Module* x) =>
			TypeContainer(x),
		(RecordField* x) =>
			TypeContainer(x.containingRecord),
		(Signature* x) =>
			asTypeContainer(x.container));

immutable struct PositionKind {
	mixin Union!(
		PositionDocRef,
		EnumOrFlagsMember*,
		ExpressionPosition,
		FunDecl*,
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
		RecordField*,
		PositionRecordFieldMutability,
		SpecDecl*,
		Signature*,
		PositionSpecUse,
		StructAlias*,
		StructDecl*,
		Test*,
		TypeWithContainer,
		TypeParamWithContainer,
		VarDecl*,
		PositionVisibilityMark);
}
immutable struct PositionDocRef {
	DocCommentContainer container;
	DocCommentReference ref_;
}
immutable struct PositionImportedModule {
	@safe @nogc pure nothrow:
	ImportOrExport* import_;

	Module* modulePtr() =>
		import_.modulePtr;
	ref Module module_() scope =>
		import_.module_;
}
immutable struct PositionImportedName {
	Module* exportingModule;
	Symbol name;
	Opt!(NameReferents*) referents;
}
// non-Modifier
enum PositionKeyword {
	alias_,
	builtin,
	enum_,
	extern_,
	flags,
	global,
	interface_,
	localMut,
	record,
	spec,
	threadLocal,
	underscore,
	union_,
	variant,
}
immutable struct PositionLocal {
	LocalContainer container;
	Local* local;
}
immutable struct PositionMatchEnumCase {
	EnumOrFlagsMember* member;
}
immutable struct PositionMatchIntegralCase {
	MatchIntegralKind kind;
	IntegralValue value;
}
immutable struct PositionMatchStringLikeCase {
	TypeWithContainer type;
	string value;
}
immutable struct PositionMatchSumTypeCase {
	ExprContainer container;
	StructInst* member;
}
immutable struct PositionModifier {
	TypeContainer container;
	ModifierKeyword modifier;
}
immutable struct PositionModifierExtern {
	Symbol libraryName;
}
immutable struct PositionModule {}
immutable struct PositionRecordFieldMutability {
	Opt!Visibility visibility;
}
immutable struct PositionSpecUse {
	TypeContainer container;
	SpecInst* spec;
}
immutable struct TypeParamWithContainer {
	TypeParamIndex typeParam;
	// Since this is never on a Module, use AnyDecl instead of TypeContainer
	AnyDecl container;
}
immutable struct PositionVisibilityMark {
	VisibilityContainer container;
}

immutable struct ExpressionPosition {
	ExprContainer container;
	ExprRef expr;
	ExpressionPositionKind kind;
}

immutable struct ExpressionPositionKind {
	mixin Union!(
		BogusCallExpr,
		CallExpr,
		CallOptionExpr,
		ExprKeyword,
		ExternExpr,
		FunPointerExpr,
		ExpressionPositionLiteral,
		LocalRef,
		LoopKeyword);
}
immutable struct ExpressionPositionLiteral {}
immutable struct LocalRef {
	LocalRefKind kind;
	Local* local;
}
enum LocalRefKind { get, set, closureGet, closureSet, pointer }
immutable struct LoopKeyword {
	LoopKeywordKind kind;
	ExprRef loop;
}
enum LoopKeywordKind { loop, break_, continue_ }

enum ExprKeyword {
	ampersand,
	assert_,
	colonColon,
	colonInAssertOrForbid,
	colonInFor,
	colonInIf,
	colonInWith,
	elif,
	else_,
	finally_,
	forbid,
	guardIfOrUnless,
	lambdaArrow,
	match,
	questionDotOrSubscript,
	questionEquals,
	throw_,
	trusted,
	try_,
	until,
	while_,
}
