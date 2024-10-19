module frontend.ide.position;

@safe @nogc pure nothrow:

import model.ast : ModifierKeyword, NameAndRange;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	BogusCallExpr,
	CallExpr,
	CallOptionExpr,
	emptySpecs,
	EnumOrFlagsMember,
	ExprRef,
	ExternExpr,
	FunDecl,
	FunDeclSource,
	FunPointerExpr,
	ImportOrExport,
	Local,
	MatchIntegralExpr,
	Module,
	NameReferents,
	RecordField,
	SpecDecl,
	Specs,
	Signature,
	SpecInst,
	StructAlias,
	StructDecl,
	StructInst,
	Test,
	TypeParamIndex,
	UnionMember,
	VarDecl,
	Visibility;
import util.integralValues : IntegralValue;
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

immutable struct PositionKind {
	immutable struct ImportedModule {
		@safe @nogc pure nothrow:
		ImportOrExport* import_;

		Module* modulePtr() =>
			import_.modulePtr;
		ref Module module_() scope =>
			import_.module_;
	}
	immutable struct ImportedName {
		Module* exportingModule;
		Symbol name;
		Opt!(NameReferents*) referents;
	}
	// non-Modifier
	immutable struct Keyword {
		enum Kind {
			alias_,
			builtin,
			enum_,
			extern_,
			flags,
			global,
			localMut,
			record,
			spec,
			threadLocal,
			underscore,
			union_,
			variant,
			variantMember,
		}
		Kind kind;
	}
	immutable struct LocalPosition {
		LocalContainer container;
		Local* local;
	}
	immutable struct MatchEnumCase {
		EnumOrFlagsMember* member;
	}
	immutable struct MatchIntegralCase {
		MatchIntegralExpr.Kind kind;
		IntegralValue value;
	}
	immutable struct MatchStringLikeCase {
		TypeWithContainer type;
		string value;
	}
	immutable struct MatchUnionCase {
		UnionMember* member;
	}
	immutable struct MatchVariantCase {
		ExprContainer container;
		StructInst* member;
	}
	immutable struct Modifier {
		TypeContainer container;
		ModifierKeyword modifier;
	}
	immutable struct ModifierExtern {
		Symbol libraryName;
	}
	immutable struct ModulePosition {}
	immutable struct RecordFieldMutability {
		Opt!Visibility visibility;
	}
	immutable struct SpecSig {
		SpecDecl* spec;
		Signature* sig;
	}
	immutable struct SpecUse {
		TypeContainer container;
		SpecInst* spec;
	}
	immutable struct TypeParamWithContainer {
		TypeParamIndex typeParam;
		TypeContainer container;
	}
	alias VariantMethod = FunDeclSource.VariantMethod;
	immutable struct VisibilityMark {
		VisibilityContainer container;
	}

	mixin Union!(
		EnumOrFlagsMember*,
		ExpressionPosition,
		FunDecl*,
		ImportedModule,
		ImportedName,
		Keyword,
		LocalPosition,
		MatchEnumCase,
		MatchIntegralCase,
		MatchStringLikeCase,
		MatchUnionCase,
		MatchVariantCase,
		Modifier,
		ModifierExtern,
		ModulePosition,
		RecordField*,
		RecordFieldMutability,
		SpecDecl*,
		SpecSig,
		SpecUse,
		StructAlias*,
		StructDecl*,
		Test*,
		TypeWithContainer,
		TypeParamWithContainer,
		UnionMember*,
		VarDecl*,
		VariantMethod,
		VisibilityMark);
}

immutable struct ExpressionPosition {
	ExprContainer container;
	ExprRef expr;
	ExpressionPositionKind kind;
}

immutable struct ExpressionPositionKind {
	immutable struct Literal {}
	immutable struct LocalRef {
		enum Kind { get, set, closureGet, closureSet, pointer }
		Kind kind;
		Local* local;
	}
	immutable struct LoopKeyword {
		enum Kind { loop, break_, continue_ }
		Kind kind;
		ExprRef loop;
	}
	mixin Union!(
		BogusCallExpr,
		CallExpr,
		CallOptionExpr,
		ExprKeyword,
		ExternExpr,
		FunPointerExpr,
		Literal,
		LocalRef,
		LoopKeyword);
}

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
