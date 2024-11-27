module frontend.check.checkDocComments;

@safe @nogc pure nothrow:

import frontend.check.checkCall.candidates : eachFunInScope, FunsInScope;
import frontend.check.checkCtx : addDiag, CheckCtx, markUsed;
import frontend.check.maps : FunsMap, SpecsMap, StructsAndAliasesMap;
import frontend.check.instantiate : instantiateSpecWithOwnTypeParams;
import frontend.check.typeFromAst : structOrAliasFromName, tryFindSpec;
import model.ast : DocCommentAst, NameAndRange;
import model.model :
	AnyDecl,
	AutoFun,
	BuiltinFun,
	BuiltinType,
	CalledDecl,
	CalledSpecSig,
	CommonTypes,
	CreateEnumOrFlags,
	CreateExtern,
	CreateRecord,
	CreateRecordAndConvertToSumType,
	CreateSumType,
	Destructure,
	Diag,
	DiagNameNotFound,
	DiagNameNotFoundKind,
	DocCommentReference,
	DocCommentReferenceBogus,
	DocCommentReferences,
	EnumOrFlagsMember,
	emptySpecs,
	Enum,
	Expr,
	ExternType,
	firstLocal,
	Flags,
	FlagsFunction,
	FunBodyBogus,
	FunBodyExtern,
	FunBodyFileImport,
	FunBodyMethod,
	FunDecl,
	Local,
	paramsArray,
	Record,
	RecordField,
	RecordFieldCall,
	RecordFieldGet,
	RecordFieldPointer,
	RecordFieldSet,
	SpecDecl,
	Signature,
	Specs,
	StructAlias,
	StructBodyBogus,
	StructDecl,
	StructInst,
	StructOrAlias,
	SumType,
	SumTypeMemberGet,
	Test,
	TypeParamIndex,
	TypeParams,
	VarDecl,
	VarGet,
	VarSet;
import util.cell : Cell, cellGet, cellSet;
import util.col.array : first, firstWithIndex, map;
import util.comparison : Comparison;
import util.conv : safeToUshort, safeToUint;
import util.opt : force, has, none, Opt, optIf, optOrDefault,some;
import util.sourceRange : compareUriAndRange;
import util.symbol : Symbol;

void checkDocComments(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	StructAlias[] structAliases,
	StructDecl[] structs,
	SpecDecl[] specs,
	VarDecl[] vars,
	FunDecl[] funs,
	Test[] tests,
) {
	DocCommentReference checkRef(TypeParams typeParams, Specs specs, NameAndRange ast) =>
		checkDocCommentReference(ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, typeParams, specs, ast);
	DocCommentReference checkRefForSig(TypeParams typeParams, Specs specs, Destructure[] params, NameAndRange ast) =>
		optOrDefault!DocCommentReference(
			referenceInParams(params, ast.name),
			() => checkRef(typeParams, specs, ast));
	DocCommentReferences checkRefs(TypeParams typeParams, Specs specs, DocCommentAst ast) =>
		checkDocCommentReferences(ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, typeParams, specs, ast);
	DocCommentReferences checkRefsForDecl(AnyDecl decl) =>
		checkRefs(decl.typeParams, decl.specs, decl.docCommentAst);
	DocCommentReferences checkRefsForStruct(ref StructDecl struct_, DocCommentAst ast) =>
		checkRefs(struct_.typeParams, emptySpecs, ast);

	foreach (ref StructAlias x; structAliases)
		x.docCommentReferences = checkRefsForDecl(AnyDecl(&x));
	foreach (ref StructDecl struct_; structs) {
		struct_.docCommentReferences = checkRefsForDecl(AnyDecl(&struct_));
		struct_.body_.match!void(
			(StructBodyBogus _) {},
			(BuiltinType _) {},
			(ref Enum x) {
				foreach (ref EnumOrFlagsMember member; x.members)
					member.docCommentReferences = checkRefsForStruct(struct_, member.docCommentAst);
			},
			(ExternType _) {},
			(Flags x) {
				foreach (ref EnumOrFlagsMember member; x.members)
					member.docCommentReferences = checkRefsForStruct(struct_, member.docCommentAst);
			},
			(Record x) {
				foreach (ref RecordField field; x.fields)
					field.docCommentReferences = checkRefsForStruct(struct_, field.docCommentAst);
			},
			(SumType x) {
				foreach (ref Signature sig; x.methods)
					sig.docCommentReferences = map!(DocCommentReference, NameAndRange)(
						ctx.alloc, sig.docCommentAst.references, (ref NameAndRange ast) =>
							checkRefForSig(struct_.typeParams, emptySpecs, sig.params, ast));
			});
	}
	foreach (ref SpecDecl spec; specs) {
		spec.docCommentReferences = checkRefsForDecl(AnyDecl(&spec));
		foreach (ref Signature sig; spec.sigs) {
			sig.docCommentReferences = map!(DocCommentReference, NameAndRange)(
				ctx.alloc, sig.docCommentAst.references, (ref NameAndRange ast) =>
					optOrDefault!DocCommentReference(
						referenceSpecSig(ctx, &spec, ast.name),
						() => checkRefForSig(spec.typeParams, spec.parents, sig.params, ast)));
		}
	}
	foreach (ref VarDecl x; vars)
		x.docCommentReferences = checkRefsForDecl(AnyDecl(&x));
	foreach (ref FunDecl x; funs) {
		x.docCommentReferences = map!(DocCommentReference, NameAndRange)(
			ctx.alloc, x.docCommentAst.references, (ref NameAndRange ast) =>
				checkRefForSig(x.typeParams, x.specs, paramsArray(x.params), ast));
	}
	foreach (ref Test x; tests)
		x.docCommentReferences = checkRefsForDecl(AnyDecl(&x));
}

DocCommentReferences checkDocCommentReferences(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	TypeParams typeParams,
	Specs specs,
	DocCommentAst ast,
) =>
	map!(DocCommentReference, NameAndRange)(ctx.alloc, ast.references, (ref NameAndRange name) =>
		checkDocCommentReference(
			ctx, commonTypes, structsAndAliasesMap, specsMap, funsMap, typeParams, specs, name));

private:

DocCommentReference checkDocCommentReference(
	ref CheckCtx ctx,
	ref CommonTypes commonTypes,
	in StructsAndAliasesMap structsAndAliasesMap,
	in SpecsMap specsMap,
	in FunsMap funsMap,
	TypeParams typeParams,
	Specs specs,
	NameAndRange ast,
) {
	Symbol name = ast.name;
	return optOrDefault!DocCommentReference(
		referenceTypeParam(typeParams, name),
		() {
			Opt!StructOrAlias sa = structOrAliasFromName(ctx, name, ast.range, structsAndAliasesMap, noDiag: true);
			return optIf(has(sa), () => toDocCommentReference(force(sa)));
		},
		() {
			Opt!(SpecDecl*) spec = tryFindSpec(ctx, ast, specsMap, noDiag: true);
			return optIf(has(spec), () => DocCommentReference(force(spec)));
		},
		() => referenceFun(ctx, funsMap, specs, name),
		() {
			addDiag(ctx, ast.range, Diag(DiagNameNotFound(DiagNameNotFoundKind.docCommentReference, name)));
			return DocCommentReference(DocCommentReferenceBogus());
		});
}

Opt!DocCommentReference referenceTypeParam(NameAndRange[] typeParams, Symbol name) =>
	firstWithIndex!(DocCommentReference, NameAndRange)(typeParams, (size_t index, NameAndRange x) =>
		optIf(x.name == name, () => DocCommentReference(TypeParamIndex(safeToUint(index)))));

Opt!DocCommentReference referenceInParams(Destructure[] params, Symbol name) =>
	first!(DocCommentReference, Destructure)(params, (Destructure param) =>
		firstLocal!DocCommentReference(param, (Local* local) =>
			optIf(local.name == name, () => DocCommentReference(local))));

DocCommentReference toDocCommentReference(StructOrAlias a) =>
	a.matchWithPointers!DocCommentReference(
		(StructAlias* x) =>
			DocCommentReference(x),
		(StructDecl* x) =>
			DocCommentReference(x));

Opt!DocCommentReference referenceSpecSig(ref CheckCtx ctx, SpecDecl* curSpec, Symbol name) =>
	firstWithIndex!(DocCommentReference, Signature)(curSpec.sigs, (size_t index, Signature sig) =>
		optIf(sig.name == name, () =>
			DocCommentReference(CalledSpecSig(
				instantiateSpecWithOwnTypeParams(ctx.instantiateCtx, curSpec),
				safeToUshort(index)))));

Opt!DocCommentReference referenceFun(ref CheckCtx ctx, in FunsMap funsMap, Specs specs, Symbol name) {
	Opt!CalledDecl called = firstFunInScope(ctx, funsMap, specs, name);
	return optIf(has(called), () =>
		force(called).matchWithPointers!DocCommentReference(
			(FunDecl* x) {
				markUsed(ctx, x);
				return docCommentReferenceForFunDecl(x);
			},
			(CalledSpecSig x) =>
				DocCommentReference(x)));
}

DocCommentReference docCommentReferenceForFunDecl(FunDecl* a) {
	DocCommentReference fun = DocCommentReference(a);
	DocCommentReference returnStruct() =>
		DocCommentReference(a.returnType.as!(StructInst*).decl);
	return a.body_.match!DocCommentReference(
		(FunBodyBogus _) =>
			fun,
		(AutoFun _) =>
			fun,
		(BuiltinFun _) =>
			fun,
		(CreateEnumOrFlags x) =>
			DocCommentReference(x.member),
		(CreateExtern _) =>
			returnStruct(),
		(CreateRecord _) =>
			returnStruct(),
		(CreateRecordAndConvertToSumType x) =>
			DocCommentReference(x.member.decl),
		(CreateSumType _) =>
			returnStruct(),
		(Expr _) =>
			fun,
		(FunBodyExtern _) =>
			fun,
		(FunBodyFileImport _) =>
			fun,
		(FlagsFunction _) =>
			returnStruct(),
		(FunBodyMethod x) =>
			DocCommentReference(x.method),
		(RecordFieldCall x) =>
			DocCommentReference(x.field),
		(RecordFieldGet x) =>
			DocCommentReference(x.field),
		(RecordFieldPointer x) =>
			DocCommentReference(x.field),
		(RecordFieldSet x) =>
			DocCommentReference(x.field),
		(SumTypeMemberGet x) =>
			returnStruct(),
		(VarGet x) =>
			DocCommentReference(x.var),
		(VarSet x) =>
			DocCommentReference(x.var));
}

Opt!CalledDecl firstFunInScope(ref CheckCtx ctx, in FunsMap funsMap, Specs specs, Symbol name) {
	Cell!(Opt!CalledDecl) res = Cell!(Opt!CalledDecl)(none!CalledDecl);
	eachFunInScope(FunsInScope(specs, funsMap, ctx.importsAndReExports), name, (CalledDecl x) {
		if (!has(cellGet(res)) || compareUriAndRange(x.range, force(cellGet(res)).range) == Comparison.less)
			cellSet(res, some(x));
	});
	return cellGet(res);
}
