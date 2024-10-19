module frontend.ide.getDefinition;

@safe @nogc pure nothrow:

import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.ideUtil : ReferenceCb;
import frontend.ide.position : Position, PositionKind;
import frontend.storage : LineAndCharacterGetters;
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
import util.col.array : only;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, Opt;
import util.sourceRange : UriAndLineAndCharacterRange, UriAndRange;
import util.uri : Uri;
import util.util : castNonScope_ref;

UriAndLineAndCharacterRange[] getDefinitionForPosition(ref Alloc alloc, in CommonTypes commonTypes, in LineAndCharacterGetters lcgs, in Position pos) {
	Opt!Target target = targetForPosition(commonTypes, pos);
	return has(target)
		? buildArray!UriAndLineAndCharacterRange(alloc, (scope ref Builder!UriAndLineAndCharacterRange res) {
			definitionForTarget(pos.module_.uri, force(target), (in UriAndRange x) { res ~= lcgs[x]; });
		})
		: [];
}

UriAndLineAndCharacterRange[] getTypeDefinitionForPosition(ref Alloc alloc, in CommonTypes commonTypes, in LineAndCharacterGetters lcgs, in Position pos) =>
	buildArray!UriAndLineAndCharacterRange(alloc, (scope ref Builder!UriAndLineAndCharacterRange res) {
		Opt!Target target = targetForPosition(commonTypes, pos);
		if (has(target))
			typeDefinitionForTarget(force(target), (in UriAndRange x) { res ~= lcgs[x]; });
	});

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

void typeDefinitionForTarget(in Target a, in ReferenceCb cb) {
	castNonScope_ref(a).matchWithPointers!void(
		(EnumOrFlagsMember* x) {
			definitionForStruct(*x.containingEnum, cb);
		},
		(FunDecl* x) {
			typeDefinitionForFunDecl(x, cb);
		},
		(PositionKind.ImportedName x) {
			if (has(x.referents)) {
				NameReferents* refs = force(x.referents);
				if (has(refs.structOrAlias))
					typeDefinitionForStructOrAlias(force(refs.structOrAlias), cb);
				else if (refs.funs.length == 1)
					typeDefinitionForFunDecl(only(refs.funs), cb);
			}
		},
		(PositionKind.LocalPosition x) {
			definitionForType(x.container.toTypeContainer, x.local.type, cb);
		},
		(Target.Loop x) {
			definitionForType(x.container.toTypeContainer, x.loop.type, cb);
		},
		(Module* x) {},
		(RecordField* x) {
			definitionForType(TypeContainer(x.containingRecord), x.type, cb);
		},
		(SpecDecl* x) {},
		(PositionKind.SpecSig x) {
			definitionForType(TypeContainer(x.spec), x.sig.returnType, cb);
		},
		(StructAlias* x) {
			typeDefinitionForStructAlias(*x, cb);
		},
		(StructDecl* x) {
			definitionForStruct(*x, cb);
		},
		(PositionKind.TypeParamWithContainer x) {
			cb(typeParamWithContainerRange(x));
		},
		(UnionMember* x) {
			if (x.hasValue)
				definitionForType(TypeContainer(x.containingUnion), x.type, cb);
		},
		(VarDecl* x) {
			definitionForType(TypeContainer(x), x.type, cb);
		},
		(PositionKind.VariantMethod x) {
			definitionForType(TypeContainer(x.variant), x.method.returnType, cb);
		});
}

void typeDefinitionForStructOrAlias(in StructOrAlias a, in ReferenceCb cb) {
	a.matchIn!void(
		(in StructAlias x) {
			typeDefinitionForStructAlias(x, cb);
		},
		(in StructDecl x) {
			definitionForStruct(x, cb);
		});
}

void typeDefinitionForStructAlias(in StructAlias a, in ReferenceCb cb) {
	definitionForStruct(*a.target.decl, cb);
}

void definitionForStruct(in StructDecl a, in ReferenceCb cb) {
	cb(a.nameRange);
}

void typeDefinitionForFunDecl(in FunDecl* a, in ReferenceCb cb) {
	definitionForType(TypeContainer(a), a.returnType, cb);
}

void definitionForType(in TypeContainer typeContainer, in Type a, in ReferenceCb cb) =>
	a.matchIn!void(
		(in Type.Bogus) {},
		(in TypeParamIndex x) {
			cb(typeParamWithContainerRange(PositionKind.TypeParamWithContainer(x, typeContainer)));
		},
		(in StructInst x) {
			definitionForStruct(*x.decl, cb);
		});
