module frontend.ide.getReferences;

@safe @nogc pure nothrow:

import frontend.ide.getDefinition : definitionForTarget;
import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.ideUtil :
	compareUriAndLineAndCharacterRangeNaturally,
	eachFunSpec,
	eachSpecParent,
	eachTypeComponent,
	eachPackedTypeArg,
	ReferenceCb,
	TypeCb;
import frontend.ide.importReferences : eachModuleReferencing, eachNamedImport, referencesForModule, UriAndName;
import frontend.ide.position : ExprContainer, Position, PositionKind;
import lib.lsp.lspTypes : DocumentHighlight, DocumentHighlightKind, DocumentHighlightResult;
import model.ast :
	AssertOrForbidAst,
	AssignmentAst,
	AssignmentCallAst,
	CallAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	DestructureAst,
	ExprAst,
	ExprAstKind,
	ForAst,
	FunDeclAst,
	IfAst,
	LambdaAst,
	LetAst,
	LiteralIntegralAndRange,
	LoopWhileOrUntilAst,
	MatchAst,
	ModifierAst,
	ModifierKeyword,
	NameAndRange,
	ParamsAst,
	paramsArray,
	RecordOrUnionMemberAst,
	SpecUseAst,
	StructBodyAst,
	StructDeclAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	WithAst;
import model.model :
	AssertOrForbidExpr,
	BogusCallExpr,
	BogusExpr,
	BogusWrongTypeExpr,
	BuiltinType,
	Called,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	caseNameRange,
	ClosureGetExpr,
	ClosureSetExpr,
	CommonTypes,
	Condition,
	Destructure,
	DocComment,
	DocCommentReference,
	eachDescendentExprExcluding,
	eachDescendentExprIncluding,
	EnumOrFlagsMember,
	Expr,
	ExprKind,
	ExprRef,
	ExternExpr,
	FinallyExpr,
	FunBody,
	funBodyExprRef,
	FunDecl,
	FunDeclSource,
	FunInst,
	FunPointerExpr,
	getCalledAtExpr,
	greatestVisibility,
	IfExpr,
	ImportOrExport,
	IntegralType,
	IsImportOrExport,
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
	moduleAtUri,
	mustFindFunNamed,
	NameReferents,
	Params,
	paramsArray,
	Program,
	RecordField,
	RecordFieldPointerExpr,
	SeqExpr,
	SpecDecl,
	Signature,
	SpecInst,
	StructAlias,
	StructBody,
	StructDecl,
	StructDeclSource,
	StructInst,
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
	VarDecl,
	VariantAndMethodImpls,
	variantMethodCaller,
	Visibility;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : MaxStackArray, withMaxStackArray, withStackArray;
import util.col.array : allSame, contains, fold, isEmpty, only, zip, zipIfSizeEq, zipIfSizeEqFilterFirst;
import util.col.arrayBuilder : buildArray, Builder, buildSortedArray;
import util.opt : force, has, none, Opt, optIf, some;
import util.sourceRange : Range, UriAndLineAndCharacterRange, UriAndRange;
import util.symbol : Symbol;
import util.uri : Uri;

Opt!DocumentHighlightResult getDocumentHighlightsForPosition(ref Alloc alloc, in Program program, in Position pos) {
	Opt!Target target = targetForPosition(program.commonTypes, pos);
	return optIf(has(target), () =>
		DocumentHighlightResult(
			pos.module_.uri,
			buildArray!DocumentHighlight(alloc, (scope ref Builder!DocumentHighlight res) {
				eachReferenceForTarget(
					program,
					pos.module_.uri,
					force(target),
					IncludeImports.include,
					(in UriAndRange x) {
						if (x.uri == pos.module_.uri)
							res ~= DocumentHighlight(
								program.lineAndCharacterGetters[x].range,
								DocumentHighlightKind.Read);
					});
			})));
}

UriAndLineAndCharacterRange[] getReferencesForPosition(ref Alloc alloc, in Program program, in Position pos) {
	Opt!Target target = targetForPosition(program.commonTypes, pos);
	return has(target)
		? buildSortedArray!(UriAndLineAndCharacterRange, compareUriAndLineAndCharacterRangeNaturally)(
			alloc, (scope ref Builder!UriAndLineAndCharacterRange res) {
				eachReferenceForTarget(
					program, pos.module_.uri, force(target), IncludeImports.exclude,
					(in UriAndRange x) {
						res ~= program.lineAndCharacterGetters[x];
					});
			})
		: [];
}

enum IncludeImports { exclude, include }
void eachReferenceForTarget(
	in Program program,
	Uri curUri,
	in Target target,
	IncludeImports includeImports,
	in ReferenceCb cb,
) {
	Opt!UriAndName importable = asUriAndName(target);
	if (has(importable)) {
		eachNamedImport(
			program,
			moduleAtUri(program, force(importable).moduleUri),
			force(importable).name,
			(in UriAndRange where, IsImportOrExport _) {
				cb(where);
			});
	}
	definitionForTarget(curUri, target, cb);
	referencesForTarget(program, curUri, target, cb);
}

private Opt!UriAndName asUriAndName(Target a) =>
	a.matchIn!(Opt!UriAndName)(
		(in EnumOrFlagsMember x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in FunDecl x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in PositionKind.ImportedName x) =>
			none!UriAndName, // this would be redundant
		(in PositionKind.LocalPosition x) =>
			none!UriAndName,
		(in Target.Loop _) =>
			none!UriAndName,
		(in Module _) =>
			none!UriAndName,
		(in RecordField x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in SpecDecl x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in Signature x) =>
			// A spec signature can't be imported, only a variant method (through its calling function)
			optIf(x.container.isA!(StructDecl*), () =>
				UriAndName(x.moduleUri, x.name)),
		(in StructAlias x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in StructDecl x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in PositionKind.TypeParamWithContainer x) =>
			none!UriAndName,
		(in UnionMember x) =>
			some(UriAndName(x.moduleUri, x.name)),
		(in VarDecl x) =>
			some(UriAndName(x.moduleUri, x.name)));

private:

void referencesForTarget(in Program program, Uri curUri, in Target a, in ReferenceCb cb) =>
	a.matchWithPointers!void(
		(EnumOrFlagsMember* x) {
			referencesForEnumOrFlagsMember(program, x, cb);
		},
		(FunDecl* x) {
			referencesForFunDecl(program, x, cb);
		},
		(PositionKind.ImportedName x) {
			referencesForImportedName(program, x, cb);
		},
		(PositionKind.LocalPosition x) {
			referencesForLocal(program, curUri, x, cb);
		},
		(Target.Loop x) {
			referencesForLoop(program.commonTypes, curUri, x, cb);
		},
		(Module* x) {
			referencesForModule(program, x, cb);
		},
		(RecordField* x) {
			referencesForRecordField(program, *x, cb);
		},
		(SpecDecl* x) {
			referencesForSpecDecl(program, x, cb);
		},
		(Signature* x) {
			referencesForSignature(program, x, cb);
		},
		(StructAlias* x) {
			referencesForStructAlias(program, x, cb);
		},
		(StructDecl* x) {
			referencesForStructDecl(program, x, cb);
		},
		(PositionKind.TypeParamWithContainer x) {
			referencesForTypeParam(program.commonTypes, curUri, x, cb);
		},
		(UnionMember* x) {
			referencesForUnionMember(program, x, cb);
		},
		(VarDecl* x) {
			referencesForVarDecl(program, x, cb);
		});

void referencesForStructAlias(in Program program, in StructAlias* a, in ReferenceCb cb) {
	eachTypeInProgram(
		program, a.visibility, a.moduleUri,
		(in Module module_, in NameAndRange ast, in DocCommentReference ref_) {
			if (ref_.isA!(StructAlias*) && ref_.as!(StructAlias*) == a)
				cb(UriAndRange(module_.uri, ast.range));
		},
		(in Module module_, in Type t, in TypeAst ast) {
			if (t.isA!(StructInst*) &&
				t.as!(StructInst*) == a.target &&
				ast.isA!NameAndRange && ast.as!NameAndRange.name == a.name)
				cb(UriAndRange(module_.uri, ast.range));
		});
}

void referencesForImportedName(in Program program, in PositionKind.ImportedName a, in ReferenceCb cb) {
	eachNamedImport(program, a.exportingModule, a.name, (in UriAndRange where, IsImportOrExport _) {
		cb(where);
	});
	if (has(a.referents)) {
		NameReferents nr = *force(a.referents);
		if (has(nr.structOrAlias))
			force(nr.structOrAlias).matchWithPointers!void(
				(StructAlias* x) {
					referencesForStructAlias(program, x, cb);
				},
				(StructDecl* x) {
					referencesForStructDecl(program, x, cb);
				});
		if (has(nr.spec))
			referencesForSpecDecl(program, force(nr.spec), cb);
		referencesForFunDecls(program, nr.funs, cb);
	}
}

void referencesForLocal(in Program program, Uri curUri, in PositionKind.LocalPosition a, in ReferenceCb cb) {
	Opt!ContainerAndBody body_ = a.container.matchWithPointers!(Opt!ContainerAndBody)(
		(FunDecl* x) =>
			x.body_.isA!Expr
				? some(ContainerAndBody(ExprContainer(x), funBodyExprRef(x)))
				: none!ContainerAndBody,
		(Test* x) =>
			some(ContainerAndBody(ExprContainer(x), testBodyExprRef(program.commonTypes, x))),
		(SpecDecl*) =>
			none!ContainerAndBody,
		(StructDecl*) =>
			none!ContainerAndBody);
	if (has(body_)) {
		eachDocCommentReference(
			force(body_).container.docComment,
			(ref NameAndRange ast, ref DocCommentReference ref_) {
				if (ref_.isA!(Local*) && ref_.as!(Local*) == a.local)
					cb(UriAndRange(curUri, ast.range));
			});
		eachDescendentExprIncluding(program.commonTypes, force(body_).body_, (ExprRef x) {
			Opt!(Local*) itsLocal = exprLocalReference(x.expr.kind);
			if (has(itsLocal) && force(itsLocal) == a.local && !x.expr.ast.kind.isA!AssignmentCallAst)
				cb(UriAndRange(force(body_).container.moduleUri, x.expr.range));
		});
	}
}
immutable struct ContainerAndBody {
	ExprContainer container;
	ExprRef body_;
}

Opt!(Local*) exprLocalReference(ExprKind a) =>
	a.isA!(ClosureGetExpr)
		? some(a.as!ClosureGetExpr.local)
		: a.isA!(ClosureSetExpr)
		? some(a.as!ClosureSetExpr.local)
		: a.isA!LocalGetExpr
		? some(a.as!LocalGetExpr.local)
		: a.isA!LocalSetExpr
		? some(a.as!LocalSetExpr.local)
		: none!(Local*);

void referencesForLoop(ref CommonTypes commonTypes, Uri curUri, in Target.Loop a, in ReferenceCb cb) {
	eachDescendentExprExcluding(commonTypes, a.loop, (ExprRef child) {
		if (child.expr.kind.isA!(LoopBreakExpr*) || child.expr.kind.isA!LoopContinueExpr)
			cb(UriAndRange(curUri, child.expr.range));
	});
}

void referencesForTypeParam(
	ref CommonTypes commonTypes,
	Uri curUri,
	in PositionKind.TypeParamWithContainer a,
	in ReferenceCb refCb,
) {
	eachDocCommentReference(a.container.docComment, (ref NameAndRange ast, ref DocCommentReference ref_) {
		if (ref_.isA!TypeParamIndex && ref_.as!TypeParamIndex == a.typeParam)
			refCb(UriAndRange(curUri, ast.range));
	});
	scope TypeCb typeCb = (in Type type, in TypeAst ast) {
		if (type == Type(a.typeParam))
			refCb(UriAndRange(curUri, ast.range));
	};
	a.container.match!void(
		(ref FunDecl x) =>
			eachTypeInFun(commonTypes, x, typeCb),
		(ref SpecDecl x) =>
			eachTypeInSpec(x, typeCb),
		(ref StructAlias x) =>
			assert(false),
		(ref StructDecl x) =>
			eachTypeInStruct(commonTypes, x, typeCb),
		(ref Test _) =>
			assert(false),
		(ref VarDecl _) =>
			assert(false));
}

void eachTypeInModule(ref CommonTypes commonTypes, in Module a, in TypeCb cb) {
	foreach (ref StructDecl x; a.structs)
		eachTypeInStruct(commonTypes, x, cb);
	foreach (ref VarDecl x; a.vars)
		cb(x.type, x.ast.type);
	foreach (ref SpecDecl x; a.specs)
		eachTypeInSpec(x, cb);
	foreach (ref FunDecl x; a.funs)
		eachTypeInFun(commonTypes, x, cb);
	foreach (ref Test x; a.tests)
		eachTypeInExpr(commonTypes, testBodyExprRef(commonTypes, &x), cb);
}

void eachTypeInFun(ref CommonTypes commonTypes, ref FunDecl a, in TypeCb cb) {
	if (a.source.isA!(FunDeclSource.Ast)) {
		FunDeclAst* ast = a.source.as!(FunDeclSource.Ast).ast;
		cb(a.returnType, ast.returnType);
		eachTypeInParams(a.params, ast.params, cb);
		eachFunSpec(a, (SpecInst* spec, in SpecUseAst specAst) {
			eachPackedTypeArg(spec.typeArgs, specAst.typeArg, cb);
		});
		if (a.body_.isA!Expr)
			eachTypeInExpr(commonTypes, funBodyExprRef(&a), cb);
	}
}

void eachTypeInSpec(in SpecDecl a, in TypeCb cb) {
	eachSpecParent(a, (SpecInst* parent, in SpecUseAst ast) {
		eachPackedTypeArg(parent.typeArgs, ast.typeArg, cb);
	});
	foreach (ref Signature sig; a.sigs) {
		cb(sig.returnType, sig.ast.returnType);
		eachTypeInParams(Params(sig.params), sig.ast.params, cb);
	}
}

void eachTypeInStruct(ref CommonTypes commonTypes, in StructDecl a, in TypeCb cb) =>
	a.source.matchIn!void(
		(in StructDeclAst x) {
			eachTypeInStructModifiers(a.variants, x.modifiers, cb);
			eachTypeInStructBody(commonTypes, a.body_, x, x.body_, cb);
		},
		(in StructDeclSource.Bogus) {});
void eachTypeInStructModifiers(
	in VariantAndMethodImpls[] variants,
	in ModifierAst[] modifiers,
	in TypeCb cb,
) {
	zipIfSizeEqFilterFirst!(ModifierAst, VariantAndMethodImpls)(
		modifiers,
		variants,
		(in ModifierAst mod) =>
			mod.isA!(ModifierAst.Keyword) && mod.as!(ModifierAst.Keyword).keyword == ModifierKeyword.variantMember,
		(in ModifierAst mod, in VariantAndMethodImpls x) {
			cb(Type(x.variant), force(mod.as!(ModifierAst.Keyword).typeArg));
		});
}
void eachTypeInStructBody(
	ref CommonTypes commonTypes,
	in StructBody body_,
	in StructDeclAst structAst,
	in StructBodyAst ast,
	in TypeCb cb,
) {
	body_.matchIn!void(
		(in StructBody.Bogus) {},
		(in BuiltinType _) {},
		(in StructBody.Enum x) {
			eachTypeInEnumOrFlags(commonTypes, structAst, x.storage, cb);
		},
		(in StructBody.Extern) {},
		(in StructBody.Flags x) {
			eachTypeInEnumOrFlags(commonTypes, structAst, x.storage, cb);
		},
		(in StructBody.Record x) {
			eachTypeInRecordOrUnion!RecordField(
				x.fields, ast.as!(StructBodyAst.Record).params, ast.as!(StructBodyAst.Record).fields, cb);
		},
		(in StructBody.Union x) {
			eachTypeInRecordOrUnion!UnionMember(
				x.members, ast.as!(StructBodyAst.Union).params, ast.as!(StructBodyAst.Union).members, cb);
		},
		(in StructBody.Variant) {});
}
void eachTypeInEnumOrFlags(ref CommonTypes commonTypes, in StructDeclAst struct_, IntegralType storage, in TypeCb cb) {
	foreach (ref ModifierAst modifier; struct_.modifiers)
		if (modifier.isA!(ModifierAst.Keyword)) {
			ModifierAst.Keyword keyword = modifier.as!(ModifierAst.Keyword);
			if (keyword.keyword == ModifierKeyword.storage && has(keyword.typeArg))
				cb(Type(commonTypes.integrals[storage]), force(keyword.typeArg));
		}
}
void eachTypeInRecordOrUnion(Member)(
	in Member[] members,
	in Opt!ParamsAst params,
	in RecordOrUnionMemberAst[] asts,
	in TypeCb cb,
) {
	if (has(params))
		zip!(Member, DestructureAst)(
			members, force(params).as!(DestructureAst[]), (ref Member member, ref DestructureAst ast) {
				if (ast.isA!(DestructureAst.Single)) {
					Opt!(TypeAst*) typeAst = ast.as!(DestructureAst.Single).type;
					if (has(typeAst))
						cb(member.type, *force(typeAst));
				}
			});
	else
		zip!(Member, RecordOrUnionMemberAst)(members, asts, (ref Member member, ref RecordOrUnionMemberAst ast) {
			if (has(ast.type))
				cb(member.type, force(ast.type));
		});
}

void eachTypeInParams(in Params a, in ParamsAst asts, in TypeCb cb) {
	zip!(Destructure, DestructureAst)(paramsArray(a), paramsArray(asts), (ref Destructure x, ref DestructureAst ast) {
		eachTypeInDestructure(x, ast, cb);
	});
}

void eachTypeInDestructure(in Destructure a, in DestructureAst ast, in TypeCb cb) {
	void handleSingle(in Type type) {
		Opt!(TypeAst*) typeAst = ast.as!(DestructureAst.Single).type;
		if (has(typeAst))
			cb(type, *force(typeAst));
	}

	a.matchIn!void(
		(in Destructure.Ignore x) {
			if (!ast.isA!(DestructureAst.Void))
				handleSingle(x.type);
		},
		(in Local x) {
			handleSingle(x.type);
		},
		(in Destructure.Split x) {
			zip(x.parts, ast.as!(DestructureAst[]), (ref Destructure part, ref DestructureAst partAst) {
				eachTypeInDestructure(part, partAst, cb);
			});
		});
}

void eachTypeInExpr(ref CommonTypes commonTypes, ExprRef expr, in TypeCb cb) {
	eachDescendentExprIncluding(commonTypes, expr, (ExprRef x) {
		eachTypeDirectlyInExpr(x, cb);
	});
}

void eachTypeDirectlyInExpr(ExprRef a, in TypeCb cb) {
	ExprAstKind astKind() =>
		a.expr.ast.kind;
	a.expr.kind.matchIn!void(
		(in AssertOrForbidExpr x) {
			eachTypeInCondition(x.condition, astKind.as!AssertOrForbidAst.condition, cb);
		},
		(in BogusCallExpr _) {},
		(in BogusExpr _) {},
		(in BogusWrongTypeExpr _) {},
		(in CallExpr x) {
			if (astKind.isA!CallAst) {
				Opt!(TypeAst*) typeArg = astKind.as!CallAst.typeArg;
				if (has(typeArg))
					eachPackedTypeArg(x.called.as!(FunInst*).typeArgs, *force(typeArg), cb);
			}
		},
		(in CallOptionExpr _) {},
		(in ClosureGetExpr _) {},
		(in ClosureSetExpr _) {},
		(in ExternExpr _) {},
		(in FinallyExpr _) {},
		(in FunPointerExpr _) {},
		(in IfExpr x) {
			eachTypeInCondition(x.condition, astKind.as!IfAst.condition, cb);
		},
		(in LambdaExpr x) {
			if (!x.isIgnore) {
				DestructureAst param = astKind.isA!(ForAst*)
					? astKind.as!(ForAst*).param
					: astKind.isA!(WithAst*)
					? astKind.as!(WithAst*).param
					: astKind.as!(LambdaAst*).param;
				eachTypeInDestructure(x.param, param, cb);
			}
		},
		(in LetExpr x) {
			eachTypeInDestructure(x.destructure, astKind.as!(LetAst*).destructure, cb);
		},
		(in LiteralExpr _) {},
		(in LiteralStringLikeExpr _) {},
		(in LocalGetExpr _) {},
		(in LocalPointerExpr _) {},
		(in LocalSetExpr _) {},
		(in LoopExpr _) {},
		(in LoopBreakExpr _) {},
		(in LoopContinueExpr _) {},
		(in LoopWhileOrUntilExpr x) {
			eachTypeInCondition(x.condition, astKind.as!(LoopWhileOrUntilAst*).condition, cb);
		},
		(in MatchEnumExpr _) {},
		(in MatchIntegralExpr _) {},
		(in MatchStringLikeExpr _) {},
		(in MatchUnionExpr x) {
			eachTypeInMatchUnionOrVariant!(MatchUnionExpr.Case)(x.cases, astKind.as!MatchAst.cases, cb);
		},
		(in MatchVariantExpr x) {
			eachTypeInMatchUnionOrVariant!(MatchVariantExpr.Case)(x.cases, astKind.as!MatchAst.cases, cb);
		},
		(in RecordFieldPointerExpr _) {},
		(in SeqExpr _) {},
		(in ThrowExpr _) {},
		(in TrustedExpr _) {},
		(in TryExpr x) {
			eachTypeInMatchUnionOrVariant!(MatchVariantExpr.Case)(x.catches, astKind.as!(TryAst).catches, cb);
		},
		(in TryLetExpr x) {
			eachTypeInMatchUnionOrVariantCase!(MatchVariantExpr.Case)(
				x.catch_, astKind.as!(TryLetAst*).catchMember, cb);
		},
		(in TypedExpr x) =>
			cb(a.type, astKind.as!(TypedAst*).type));
}

void eachTypeInMatchUnionOrVariant(Case)(in Case[] cases, in CaseAst[] caseAsts, in TypeCb cb) {
	zipIfSizeEq!(Case, CaseAst)(cases, caseAsts, (ref Case case_, ref CaseAst caseAst) {
		eachTypeInMatchUnionOrVariantCase(case_, caseAst.member, cb);
	});
}

void eachTypeInMatchUnionOrVariantCase(Case)(in Case case_, in CaseMemberAst memberAst, in TypeCb cb) {
	memberAst.matchIn!void(
			(in CaseMemberAst.Name x) {
				if (has(x.destructure)) {
					eachTypeInDestructure(case_.destructure, force(x.destructure), cb);
				}
			},
			(in LiteralIntegralAndRange _) {},
			(in CaseMemberAst.String _) {},
			(in CaseMemberAst.Bogus) {});
}

void eachTypeInCondition(in Condition condition, in ConditionAst ast, in TypeCb cb) {
	condition.matchIn!void(
		(in Expr _) {},
		(in Condition.UnpackOption x) {
			eachTypeInDestructure(x.destructure, ast.as!(ConditionAst.UnpackOption*).destructure, cb);
		});
}

void referencesForFunDecl(in Program program, FunDecl* decl, in ReferenceCb cb) {
	referencesForFunDecls(program, [decl], cb);
}

void referencesForFunDecls(in Program program, in FunDecl*[] decls, in ReferenceCb cb) {
	if (!isEmpty(decls)) {
		Visibility maxVisibility = fold(Visibility.private_, decls, (Visibility a, in FunDecl* b) =>
			greatestVisibility(a, b.visibility));
		assert(allSame!(Uri, FunDecl*)(decls, (in FunDecl* x) => x.moduleUri));
		Module* itsModule = moduleAtUri(program, decls[0].moduleUri);
		eachExprThatMayReference(
			program, maxVisibility, itsModule,
			(in Module module_, in NameAndRange ast, in DocCommentReference ref_) {
				if (ref_.isA!(FunDecl*) && contains(decls, ref_.as!(FunDecl*)))
					cb(UriAndRange(module_.uri, ast.range));
			},
			(in Module module_, ExprRef x) {
				eachFunReferenceAtExpr(module_, x, decls, cb);
			});
	}
}

alias CbDocCommentReference = void delegate(
	in Module,
	in NameAndRange,
	in DocCommentReference,
) @safe @nogc pure nothrow;
void eachDocCommentReference(in Module module_, in CbDocCommentReference cb) {
	eachDocComment(module_, (DocComment x) {
		eachDocCommentReference(x, (ref NameAndRange ast, ref DocCommentReference ref_) {
			cb(module_, ast, ref_);
		});
	});
}

void eachDocCommentReference(
	in DocComment a,
	in void delegate(ref NameAndRange, ref DocCommentReference) @safe @nogc pure nothrow cb,
) {
	zip!(NameAndRange, DocCommentReference)(a.ast.references, a.references, cb);
}

void eachDocComment(in Module module_, in void delegate(DocComment) @safe @nogc pure nothrow cb) {
	cb(module_.docComment);
	foreach (StructAlias x; module_.aliases)
		cb(x.docComment);
	foreach (StructDecl x; module_.structs) {
		cb(x.docComment);
		x.body_.match!void(
			(StructBody.Bogus) {},
			(BuiltinType _) {},
			(ref StructBody.Enum enum_) {
				foreach (EnumOrFlagsMember member; enum_.members)
					cb(member.docComment);
			},
			(StructBody.Extern) {},
			(StructBody.Flags flags) {
				foreach (EnumOrFlagsMember member; flags.members)
					cb(member.docComment);
			},
			(StructBody.Record record) {
				foreach (ref RecordField field; record.fields)
					cb(field.docComment);
			},
			(ref StructBody.Union union_) {
				foreach (ref UnionMember member; union_.members)
					cb(member.docComment);
			},
			(StructBody.Variant variant) {
				foreach (Signature method; variant.methods)
					cb(method.docComment);
			});
	}
	foreach (VarDecl x; module_.vars)
		cb(x.docComment);
	foreach (SpecDecl x; module_.specs) {
		cb(x.docComment);
		foreach (Signature sig; x.sigs)
			cb(sig.docComment);
	}
	foreach (FunDecl x; module_.funs)
		cb(x.docComment);
	foreach (Test x; module_.tests)
		cb(x.docComment);
}

void eachFunReferenceAtExpr(in Module module_, in ExprRef x, in FunDecl*[] decls, in ReferenceCb cb) {
	Opt!Called called = getCalledAtExpr(x.expr.kind);
	if (has(called) && force(called).isA!(FunInst*) && contains(decls, force(called).as!(FunInst*).decl))
		cb(UriAndRange(module_.uri, callNameRange(*x.expr.ast)));
}

Range callNameRange(in ExprAst a) {
	ExprAstKind kind = a.kind;
	return kind.isA!(AssignmentAst*)
		? kind.as!(AssignmentAst*).left.range
		: kind.isA!AssignmentCallAst
		? kind.as!AssignmentCallAst.funName.range
		: kind.isA!CallAst
		? kind.as!CallAst.funName.range
		: kind.isA!(ForAst*)
		? kind.as!(ForAst*).forKeywordRange(a)
		: kind.isA!(WithAst*)
		? kind.as!(WithAst*).withKeywordRange(a)
		: a.range;
}

void eachExprThatMayReference(
	in Program program,
	Visibility visibility,
	Module* module_,
	in CbDocCommentReference cbDocCommentReference,
	in void delegate(in Module, ExprRef) @safe @nogc pure nothrow cb,
) {
	eachModuleThatMayReference(program, visibility, module_, (in Module module_) {
		eachDocCommentReference(module_, cbDocCommentReference);
		foreach (ref FunDecl fun; module_.funs)
			if (fun.body_.isA!Expr)
				eachDescendentExprIncluding(program.commonTypes, funBodyExprRef(&fun), (ExprRef x) {
					cb(module_, x);
				});
		foreach (ref Test test; module_.tests)
			eachDescendentExprIncluding(program.commonTypes, testBodyExprRef(program.commonTypes, &test), (ExprRef x) {
				cb(module_, x);
			});
	});
}

void eachModuleThatMayReference(
	in Program program,
	Visibility visibility,
	Module* containingModule,
	in void delegate(in Module) @safe @nogc pure nothrow cb,
) {
	cb(*containingModule);
	if (visibility != Visibility.private_)
		eachModuleReferencing(program, containingModule, (in Module x, IsImportOrExport _, in ImportOrExport _2) {
			cb(x);
		});
}

void referencesForSignature(in Program program, in Signature* a, in ReferenceCb cb) {
	a.container.match!void(
		(ref SpecDecl spec) {
			eachExprThatMayReference(
				program, spec.visibility, moduleAtUri(program, a.moduleUri),
				(in Module module_, in NameAndRange ast, in DocCommentReference x) {
					if (x.isA!(Signature*) && x.as!(Signature*) == a)
						cb(UriAndRange(module_.uri, ast.range));
				},
				(in Module module_, ExprRef x) {
					Opt!Called optCalled = getCalledAtExpr(x.expr.kind);
					if (has(optCalled)) {
						Called called = force(optCalled);
						if (called.isA!(CalledSpecSig) && called.as!(CalledSpecSig).nonInstantiatedSig == a)
							cb(UriAndRange(module_.uri, callNameRange(*x.expr.ast)));
					}
				});
		},
		(ref StructDecl variant) {
			referencesForFunDecl(program, variantMethodCaller(program, a), cb);
			// TODO: Also find all structs that implement the variant and their implementations for this sig.
		});
}

void referencesForRecordField(in Program program, in RecordField field, in ReferenceCb cb) {
	withRecordFieldFunctions(program, field, (in FunDecl*[] funs) {
		referencesForFunDecls(program, funs, cb);
	});
}

void referencesForEnumOrFlagsMember(in Program program, in EnumOrFlagsMember* member, in ReferenceCb cb) {
	StructDecl* enum_ = member.containingEnum;
	Module* declaringModule = moduleAtUri(program, enum_.moduleUri);
	FunDecl* ctor = mustFindFunNamed(declaringModule, member.name, (in FunDecl fun) =>
		fun.body_.isA!(FunBody.CreateEnumOrFlags) && fun.body_.as!(FunBody.CreateEnumOrFlags).member == member);
	eachExprThatMayReference(
		program, member.visibility, declaringModule,
		(in Module module_, in NameAndRange ast, in DocCommentReference x) {
			if (x.isA!(EnumOrFlagsMember*) && x.as!(EnumOrFlagsMember*) == member)
				cb(UriAndRange(module_.uri, ast.range));
		},
		(in Module m, ExprRef x) {
			if (x.expr.kind.isA!(MatchEnumExpr*)) {
				MatchEnumExpr* matchEnum = x.expr.kind.as!(MatchEnumExpr*);
				if (matchEnum.enum_ == enum_)
					foreach (size_t caseIndex, MatchEnumExpr.Case case_; matchEnum.cases)
						if (case_.member == member)
							cb(UriAndRange(m.uri, caseNameRange(*x.expr, caseIndex)));
			} else
				eachFunReferenceAtExpr(m, x, [ctor], cb);
		});
}

void referencesForUnionMember(in Program program, in UnionMember* member, in ReferenceCb cb) {
	StructDecl* union_ = member.containingUnion;
	Module* declaringModule = moduleAtUri(program, union_.moduleUri);
	FunDecl* ctor = mustFindFunNamed(declaringModule, member.name, (in FunDecl fun) =>
		fun.body_.isA!(FunBody.CreateUnion) && fun.body_.as!(FunBody.CreateUnion).member == member);
	Opt!(FunDecl*) getter = optIf(member.hasValue, () =>
		mustFindFunNamed(declaringModule, member.name, (in FunDecl fun) =>
			fun.body_.isA!(FunBody.UnionMemberGet) && fun.body_.as!(FunBody.UnionMemberGet).member == member));
	withStackArray!(immutable FunDecl*)(ctor, getter, (in FunDecl*[] funs) {
		eachExprThatMayReference(
			program, member.visibility, declaringModule,
			(in Module module_, in NameAndRange ast, in DocCommentReference x) {
				if (x.isA!(FunDecl*) && contains(funs, x.as!(FunDecl*)))
					cb(UriAndRange(module_.uri, ast.range));
			},
			(in Module m, ExprRef x) {
				if (x.expr.kind.isA!(MatchUnionExpr*)) {
					MatchUnionExpr* matchUnion = x.expr.kind.as!(MatchUnionExpr*);
					if (matchUnion.union_.decl == union_) {
						foreach (size_t caseIndex, ref MatchUnionExpr.Case case_; matchUnion.cases) {
							if (case_.member == member)
								cb(UriAndRange(m.uri, caseNameRange(*x.expr, caseIndex)));
						}
					}
				} else
					eachFunReferenceAtExpr(m, x, funs, cb);
			});
	});
}

void referencesForVarDecl(in Program program, in VarDecl* a, in ReferenceCb cb) {
	// Find references to get/set
	Module* declaringModule = moduleAtUri(program, a.moduleUri);
	FunDecl*[2] funs = mustFindFunsNamed(declaringModule, a.name, (in FunDecl x) =>
		(x.body_.isA!(FunBody.VarGet) && x.body_.as!(FunBody.VarGet).var == a) ||
		(x.body_.isA!(FunBody.VarSet) && x.body_.as!(FunBody.VarSet).var == a));
	referencesForFunDecls(program, funs, cb);
}

void withRecordFieldFunctions(
	in Program program,
	in RecordField field,
	in void delegate(in FunDecl*[]) @safe @nogc pure nothrow cb,
) =>
	withMaxStackArray!(void, FunDecl*)(3, (scope ref MaxStackArray!(FunDecl*) res) {
		eachFunNamed(moduleAtUri(program, field.containingRecord.moduleUri), field.name, (FunDecl* fun) {
			if (isRecordFieldFunction(fun.body_)) {
				Type paramType = only(fun.params.as!(Destructure[])).type;
				// TODO: for RecordFieldPointer we need to look for pointer to the struct
				if (paramType.isA!(StructInst*) && paramType.as!(StructInst*).decl == field.containingRecord)
					res ~= fun;
			}
		});
		cb(res.finish);
	});

FunDecl*[2] mustFindFunsNamed(
	in Module* module_,
	Symbol name,
	in bool delegate(in FunDecl) @safe @nogc pure nothrow cb,
) {
	FunDecl*[2] res;
	size_t found;
	foreach (ref FunDecl x; module_.funs) {
		if (cb(x)) {
			res[found] = &x;
			found++;
		}
	}
	assert(found == 2);
	return res;
}

void eachFunNamed(in Module* module_, Symbol name, in void delegate(FunDecl*) @safe @nogc pure nothrow cb) {
	foreach (ref FunDecl fun; module_.funs)
		if (fun.name == name)
			cb(&fun);
}

bool isRecordFieldFunction(in FunBody a) =>
	a.isA!(FunBody.RecordFieldGet) || a.isA!(FunBody.RecordFieldPointer) || a.isA!(FunBody.RecordFieldSet);

void referencesForSpecDecl(in Program program, in SpecDecl* a, in ReferenceCb refCb) {
	eachModuleThatMayReference(program, a.visibility, moduleAtUri(program, a.moduleUri), (in Module module_) {
		eachDocCommentReference(module_, (in Module module_, in NameAndRange ast, in DocCommentReference ref_) {
			if (ref_.isA!(SpecDecl*) && ref_.as!(SpecDecl*) == a)
				refCb(UriAndRange(module_.uri, ast.range));
		});
		scope void delegate(SpecInst*, in SpecUseAst) @safe @nogc pure nothrow cb = (spec, ast) {
			if (spec.decl == a)
				refCb(UriAndRange(module_.uri, ast.range));
		};
		foreach (ref SpecDecl spec; module_.specs)
			eachSpecParent(spec, cb);
		foreach (ref FunDecl fun; module_.funs)
			eachFunSpec(fun, cb);
	});
}

void referencesForStructDecl(in Program program, in StructDecl* a, in ReferenceCb cb) {
	eachTypeInProgram(
		program,
		a.visibility,
		a.moduleUri,
		(in Module module_, in NameAndRange ast, in DocCommentReference ref_) {
			if (ref_.isA!(StructDecl*) && ref_.as!(StructDecl*) == a)
				cb(UriAndRange(module_.uri, ast.range));
		},
		(in Module module_, in Type type, in TypeAst ast) {
			if (type.isA!(StructInst*) && type.as!(StructInst*).decl == a)
				cb(UriAndRange(module_.uri, ast.nameRangeOrRange));
		});
}

void eachTypeInProgram(
	in Program program,
	Visibility visibility,
	Uri moduleUri,
	in CbDocCommentReference cbDocCommentReference,
	in void delegate(in Module, in Type, in TypeAst) @safe @nogc pure nothrow cb,
) {
	eachModuleThatMayReference(program, visibility, moduleAtUri(program, moduleUri), (in Module module_) {
		eachDocCommentReference(module_, cbDocCommentReference);
		eachTypeInModule(program.commonTypes, module_, (in Type type, in TypeAst ast) {
			eachTypeInType(type, ast, (in Type typeInner, in TypeAst astInner) {
				cb(module_, typeInner, astInner);
			});
		});
	});
}
void eachTypeInType(in Type a, in TypeAst ast, in TypeCb cb) {
	cb(a, ast);
	Opt!bool res = eachTypeComponent!bool(a, ast, (in Type x, in TypeAst y) {
		eachTypeInType(x, y, cb);
		return none!bool;
	});
	assert(!has(res));
}
