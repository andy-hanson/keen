module frontend.ide.getDefinition;

@safe @nogc pure nothrow:

import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.ideUtil : ReferenceCb;
import frontend.ide.position : Position, PositionKind;
import model.ast : ExprAst, LoopAst;
import model.diag : TypeContainer;
import model.model :
	CommonTypes,
	EnumOrFlagsMember,
	FunDecl,
	localMustHaveNameRange,
	Module,
	NameReferents,
	RecordField,
	SpecDecl,
	StructAlias,
	StructDecl,
	StructInst,
	StructOrAlias,
	Type,
	TypeParamIndex,
	VarDecl,
	UnionMember;
import util.alloc.alloc : Alloc;
import util.col.array : newArray, only;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, Opt;
import util.sourceRange : UriAndRange;
import util.uri : Uri;
import util.util : castNonScope_ref, typeAs;

UriAndRange[] getDefinitionForPosition(ref Alloc alloc, in CommonTypes commonTypes, in Position pos) {
	Opt!Target target = targetForPosition(commonTypes, pos.kind);
	return has(target)
		? buildArray!UriAndRange(alloc, (scope ref Builder!UriAndRange res) {
			definitionForTarget(pos.module_.uri, force(target), (in UriAndRange x) { res ~= x; });
		})
		: [];
}

UriAndRange[] getTypeDefinitionForPosition(ref Alloc alloc, in CommonTypes commonTypes, in Position pos) {
	Opt!Target target = targetForPosition(commonTypes, pos.kind);
	return has(target)
		? typeDefinitionForTarget(alloc, force(target))
		: [];
}

private:

// public for 'getReferences' only
public void definitionForTarget(Uri curUri, in Target a, in ReferenceCb cb) =>
	a.matchIn!void(
		(in EnumOrFlagsMember x) {
			cb(x.nameRange);
		},
		(in FunDecl x) {
			cb(x.nameRange);
		},
		(in PositionKind.ImportedName x) {
			definitionForImportedName(x, cb);
		},
		(in PositionKind.LocalPosition x) {
			cb(UriAndRange(x.container.moduleUri, localMustHaveNameRange(*x.local)));
		},
		(in Target.Loop x) {
			ExprAst* ast = x.loop.expr.ast;
			cb(UriAndRange(curUri, ast.kind.as!(LoopAst*).keywordRange(ast)));
		},
		(in Module x) {
			cb(x.range);
		},
		(in RecordField x) {
			cb(x.nameRange);
		},
		(in SpecDecl x) {
			cb(x.nameRange);
		},
		(in PositionKind.SpecSig x) {
			cb(x.sig.nameRange);
		},
		(in StructAlias x) {
			cb(x.nameRange);
		},
		(in StructDecl x) {
			cb(x.nameRange);
		},
		(in PositionKind.TypeParamWithContainer x) {
			cb(typeParamWithContainerRange(x));
		},
		(in UnionMember x) {
			cb(x.nameRange);
		},
		(in VarDecl x) {
			cb(x.nameRange);
		},
		(in PositionKind.VariantMethod x) {
			cb(x.method.nameRange);
		});

UriAndRange typeParamWithContainerRange(in PositionKind.TypeParamWithContainer a) =>
	UriAndRange(a.container.moduleUri, a.container.typeParams[a.typeParam.index].range);

void definitionForImportedName(in PositionKind.ImportedName a, in ReferenceCb cb) {
	if (has(a.referents)) {
		NameReferents nr = *force(a.referents);
		if (has(nr.structOrAlias))
			cb(force(nr.structOrAlias).range);
		if (has(nr.spec))
			cb(force(nr.spec).range);
		foreach (FunDecl* f; nr.funs)
			cb(f.range);
	}
}

UriAndRange[] typeDefinitionForTarget(ref Alloc alloc, in Target a) =>
	castNonScope_ref(a).matchWithPointers!(UriAndRange[])(
		(EnumOrFlagsMember* x) =>
			definitionForStruct(alloc, *x.containingEnum),
		(FunDecl* x) =>
			typeDefinitionForFunDecl(alloc, x),
		(PositionKind.ImportedName x) {
			if (has(x.referents)) {
				NameReferents* refs = force(x.referents);
				return has(refs.structOrAlias)
					? typeDefinitionForStructOrAlias(alloc, force(refs.structOrAlias))
					: refs.funs.length == 1
					? typeDefinitionForFunDecl(alloc, only(refs.funs))
					: [];
			} else
				return typeAs!(UriAndRange[])([]);
		},
		(PositionKind.LocalPosition x) =>
			definitionForType(alloc, x.container.toTypeContainer, x.local.type),
		(Target.Loop x) =>
			definitionForType(alloc, x.container.toTypeContainer, x.loop.type),
		(Module* x) =>
			typeAs!(UriAndRange[])([]),
		(RecordField* x) =>
			definitionForType(alloc, TypeContainer(x.containingRecord), x.type),
		(SpecDecl* x) =>
			typeAs!(UriAndRange[])([]),
		(PositionKind.SpecSig x) =>
			definitionForType(alloc, TypeContainer(x.spec), x.sig.returnType),
		(StructAlias* x) =>
			typeDefinitionForStructAlias(alloc, *x),
		(StructDecl* x) =>
			definitionForStruct(alloc, *x),
		(PositionKind.TypeParamWithContainer x) =>
			newArray(alloc, [typeParamWithContainerRange(x)]),
		(UnionMember* x) =>
			x.hasValue
				? definitionForType(alloc, TypeContainer(x.containingUnion), x.type)
				: [],
		(VarDecl* x) =>
			definitionForType(alloc, TypeContainer(x), x.type),
		(PositionKind.VariantMethod x) =>
			definitionForType(alloc, TypeContainer(x.variant), x.method.returnType));

UriAndRange[] typeDefinitionForStructOrAlias(ref Alloc alloc, in StructOrAlias a) =>
	a.matchIn!(UriAndRange[])(
		(in StructAlias x) =>
			typeDefinitionForStructAlias(alloc, x),
		(in StructDecl x) =>
			definitionForStruct(alloc, x));

UriAndRange[] typeDefinitionForStructAlias(ref Alloc alloc, in StructAlias a) =>
	definitionForStruct(alloc, *a.target.decl);

UriAndRange[] definitionForStruct(ref Alloc alloc, in StructDecl a) =>
	newArray(alloc, [a.nameRange]);

UriAndRange[] typeDefinitionForFunDecl(ref Alloc alloc, in FunDecl* a) =>
	definitionForType(alloc, TypeContainer(a), a.returnType);

UriAndRange[] definitionForType(ref Alloc alloc, in TypeContainer typeContainer, in Type a) =>
	a.matchIn!(UriAndRange[])(
		(in Type.Bogus) =>
			typeAs!(UriAndRange[])([]),
		(in TypeParamIndex x) =>
			newArray(alloc, [typeParamWithContainerRange(PositionKind.TypeParamWithContainer(x, typeContainer))]),
		(in StructInst x) =>
			definitionForStruct(alloc, *x.decl));
