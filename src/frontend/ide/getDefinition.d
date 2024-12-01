module frontend.ide.getDefinition;

@safe @nogc pure nothrow:

import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.ideUtil : ReferenceCb;
import frontend.ide.position : Position, PositionImportedName, PositionLocal, TypeParamWithContainer;
import model.ast : LoopAst;
import model.model :
	asTypeContainer,
	BogusType,
	EnumOrFlagsMember,
	forbidModule,
	FunDecl,
	localMustHaveNameRange,
	LoopExpr,
	Module,
	NameReferents,
	Program,
	RecordField,
	Signature,
	SpecDecl,
	StructAlias,
	StructDecl,
	StructInst,
	StructOrAlias,
	Type,
	TypeContainer,
	TypeParamIndex,
	VarDecl;
import model.sourceRange : UriAndLineAndCharacterRange, UriAndRange;
import util.alloc.alloc : Alloc;
import util.col.array : only;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, Opt;
import util.uri : Uri;
import util.util : castNonScope_ref;

UriAndLineAndCharacterRange[] getDefinitionForPosition(ref Alloc alloc, in Program program, in Position pos) {
	Opt!Target target = targetForPosition(pos);
	return has(target)
		? buildArray!UriAndLineAndCharacterRange(alloc, (scope ref Builder!UriAndLineAndCharacterRange res) {
			definitionForTarget(pos.module_.uri, force(target), (in UriAndRange x) {
				res ~= program.lineAndCharacterGetters[x];
			});
		})
		: [];
}

UriAndLineAndCharacterRange[] getTypeDefinitionForPosition(ref Alloc alloc, in Program program, in Position pos) =>
	buildArray!UriAndLineAndCharacterRange(alloc, (scope ref Builder!UriAndLineAndCharacterRange res) {
		Opt!Target target = targetForPosition(pos);
		if (has(target))
			typeDefinitionForTarget(force(target), (in UriAndRange x) {
				res ~= program.lineAndCharacterGetters[x];
			});
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
		(in PositionImportedName x) {
			definitionForImportedName(x, cb);
		},
		(in PositionLocal x) {
			cb(UriAndRange(x.container.moduleUri, localMustHaveNameRange(*x.local)));
		},
		(in Target.Loop x) {
			cb(UriAndRange(curUri, x.loop.ast.keywordRange));
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
		(in Signature x) {
			cb(x.nameRange);
		},
		(in StructAlias x) {
			cb(x.nameRange);
		},
		(in StructDecl x) {
			cb(x.nameRange);
		},
		(in TypeParamWithContainer x) {
			cb(typeParamWithContainerRange(x));
		},
		(in VarDecl x) {
			cb(x.nameRange);
		});

UriAndRange typeParamWithContainerRange(in TypeParamWithContainer a) =>
	UriAndRange(a.container.moduleUri, a.container.typeParams[a.typeParam.index].range);

void definitionForImportedName(in PositionImportedName a, in ReferenceCb cb) {
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
		(PositionImportedName x) {
			if (has(x.referents)) {
				NameReferents* refs = force(x.referents);
				if (has(refs.structOrAlias))
					typeDefinitionForStructOrAlias(force(refs.structOrAlias), cb);
				else if (refs.funs.length == 1)
					typeDefinitionForFunDecl(only(refs.funs), cb);
			}
		},
		(PositionLocal x) {
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
		(Signature* x) {
			definitionForType(asTypeContainer(x.container), x.returnType, cb);
		},
		(StructAlias* x) {
			typeDefinitionForStructAlias(*x, cb);
		},
		(StructDecl* x) {
			definitionForStruct(*x, cb);
		},
		(TypeParamWithContainer x) {
			cb(typeParamWithContainerRange(x));
		},
		(VarDecl* x) {
			definitionForType(TypeContainer(x), x.type, cb);
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
		(in BogusType _) {},
		(in TypeParamIndex x) {
			cb(typeParamWithContainerRange(TypeParamWithContainer(x, forbidModule(typeContainer))));
		},
		(in StructInst x) {
			definitionForStruct(*x.decl, cb);
		});
