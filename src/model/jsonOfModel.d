module model.jsonOfModel;

@safe @nogc pure nothrow:

import model.ast : ImportOrExportAst, NameAndRange;
import model.constant : Constant;
import model.jsonOfConstant : jsonOfConstant;
import model.model :
	AnyDecl,
	AssertOrForbidExpr,
	AutoFun,
	BogusCallExpr,
	BogusExpr,
	BogusWrongTypeExpr,
	Builtin4ary,
	BuiltinBinary,
	BuiltinBinaryLazy,
	BuiltinBinaryMath,
	BuiltinFun,
	BuiltinFunCallFunPointer,
	BuiltinFunInit,
	BuiltinFunInitKind,
	BuiltinSpec,
	BuiltinTernary,
	BuiltinType,
	BuiltinUnary,
	BuiltinUnaryMath,
	ByValOrRef,
	Called,
	CalledDecl,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	ClosureGetExpr,
	ClosureSetExpr,
	Condition,
	Destructure,
	DocComment,
	DocCommentReference,
	EnumOrFlagsMember,
	Expr,
	ExprAndType,
	ExprKind,
	ExprRef,
	ExternExpr,
	FinallyExpr,
	FlagsFunction,
	FunBody,
	FunDecl,
	FunFlags,
	FunInst,
	FunPointerExpr,
	IfExpr,
	ImportOrExport,
	IntegralType,
	JsFun,
	LambdaExpr,
	LetExpr,
	LiteralExpr,
	LiteralStringLikeExpr,
	Local,
	LocalGetExpr,
	LocalPointerExpr,
	LocalSetExpr,
	LocalMutability,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopExpr,
	LoopWhileOrUntilExpr,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchSumTypeCase,
	MatchSumTypeExpr,
	Module,
	nameFromNameReferentsPointer,
	NameReferents,
	Params,
	RecordField,
	RecordFieldPointerExpr,
	Purity,
	RecordFlags,
	SeqExpr,
	SpecDecl,
	StructAlias,
	Signature,
	SpecInst,
	StructBody,
	StructDecl,
	StructInst,
	stringOfVisibility,
	Test,
	ThrowExpr,
	TrustedExpr,
	toExprAndType,
	TryExpr,
	TryLetExpr,
	Type,
	TypedExpr,
	TypeParamIndex,
	TypeSize,
	VarDecl,
	VariableRef,
	SumTypeMembership,
	SumTypeMemberAndMethodImpls,
	Varargs,
	Visibility;
import util.alloc.alloc : Alloc;
import util.col.array : map, mapOp;
import util.col.arrayBuilder : buildArray, Builder;
import util.json :
	field,
	Json,
	jsonList,
	jsonListOfKeys,
	jsonNull,
	jsonObject,
	jsonString,
	optionalArrayField,
	optionalFlagField,
	optionalField,
	kindField;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : jsonOfLineAndColumnRange, LineAndColumnGetter, Range, UriAndRange;
import util.symbol : compareSymbolsNaturally, Symbol, symbol;
import util.symbolSet : SymbolSet;
import util.uri : stringOfUri;
import util.util : ptrTrustMe, stringOfEnum;
import versionInfo : VersionFun;

Json jsonOfModule(ref Alloc alloc, in LineAndColumnGetter lcg, in Module a) {
	Ctx ctx = Ctx(ptrTrustMe(a), lcg);
	return jsonObject(alloc, [
		field!"uri"(stringOfUri(alloc, a.uri)),
		docCommentField(alloc, ctx, a.docComment),
		optionalArrayField!("imports", ImportOrExport)(alloc, a.imports, (in ImportOrExport x) =>
			jsonOfImportOrExport(alloc, ctx, x)),
		optionalArrayField!("re-exports", ImportOrExport)(alloc, a.reExports, (in ImportOrExport x) =>
			jsonOfImportOrExport(alloc, ctx, x)),
		optionalArrayField!("aliases", StructAlias)(alloc, a.aliases, (ref StructAlias x) =>
			jsonOfStructAlias(alloc, ctx, x)),
		optionalArrayField!("structs", StructDecl)(alloc, a.structs, (ref StructDecl x) =>
			jsonOfStructDecl(alloc, ctx, x)),
		optionalArrayField!("vars", VarDecl)(alloc, a.vars, (ref VarDecl x) =>
			jsonOfVarDecl(alloc, ctx, x)),
		optionalArrayField!("specs", SpecDecl)(alloc, a.specs, (ref SpecDecl x) =>
			jsonOfSpecDecl(alloc, ctx, x)),
		optionalArrayField!("funs", FunDecl)(alloc, a.funs, (ref FunDecl x) =>
			jsonOfFunDecl(alloc, ctx, x)),
		optionalArrayField!("tests", Test)(alloc, a.tests, (ref Test x) =>
			jsonOfTest(alloc, ctx, x))]);
}

Json jsonOfBuiltin(ref Alloc alloc, in BuiltinFun a) =>
	a.matchIn!Json(
		(in BuiltinFunAllTests) =>
			jsonString!"all-tests",
		(in BuiltinUnary x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinUnaryMath x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinBinary x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinBinaryLazy x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinBinaryMath x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinTernary x) =>
			jsonString(stringOfEnum(x)),
		(in Builtin4ary x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinFunCallLambda) =>
			jsonString!"call-lambda",
		(in BuiltinFunCallFunPointer x) =>
			jsonString!"call-fun-pointer",
		(in Constant x) =>
			jsonOfConstant(alloc, x),
		(in BuiltinFunGcSafeValue) =>
			jsonString!"gc-safe-value",
		(in BuiltinFunInit x) {
			final switch (x.kind) {
				case BuiltinFunInitKind.global:
					return jsonString!"init-global";
				case BuiltinFunInitKind.perThread:
					return jsonString!"init-per-thread";
			}
		},
		(in JsFun x) =>
			jsonString(stringOfEnum(x)),
		(in BuiltinFunMarkRoot) =>
			jsonString!"mark-root",
		(in BuiltinFunMarkVisit) =>
			jsonString!"mark-visit",
		(in BuiltinFunNewEmptyOption) =>
			jsonString!"new-empty-option",
		(in BuiltinFunNewNonEmptyOption) =>
			jsonString!"new-non-empty-option",
		(in BuiltinFunPointerCast) =>
			jsonString!"pointer-cast",
		(in BuiltinFunSizeOf) =>
			jsonString!"size-of",
		(in BuiltinFunStaticSymbols) =>
			jsonString!"static-symbols",
		(in VersionFun x) =>
			jsonString(stringOfEnum(x)));

private:

Opt!(Json.ObjectField) docCommentField(ref Alloc alloc, in Ctx ctx, in DocComment a) =>
	optionalField!"doc"(!a.isEmpty, () =>
		jsonOfDocComment(alloc, ctx, a));
Json jsonOfDocComment(ref Alloc alloc, in Ctx ctx, in DocComment a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfLineAndColumnRange(alloc, ctx.lineAndColumnGetter[force(a.ast.range)])),
		optionalArrayField!("references", DocCommentReference)(alloc, a.references, (in DocCommentReference x) =>
			jsonOfDocCommentReference(alloc, ctx, x))]);
Json jsonOfDocCommentReference(ref Alloc alloc, in Ctx ctx, in DocCommentReference a) =>
	a.matchIn!Json(
		(in DocCommentReference.Bogus) =>
			jsonString("bogus"),
		(in CalledSpecSig x) =>
			jsonOfCalledSpecSig(alloc, ctx, x),
		(in EnumOrFlagsMember x) =>
			jsonObject(alloc, [kindField!"enum-member", field!"name"(x.name)]),
		(in FunDecl x) =>
			jsonObject(alloc, [kindField!"fun", field!"name"(x.name)]),
		(in Local x) =>
			jsonObject(alloc, [kindField!"local", field!"name"(x.name)]),
		(in RecordField x) =>
			jsonObject(alloc, [kindField!"record-field", field!"name"(x.name)]),
		(in Signature x) =>
			jsonObject(alloc, [kindField!"signature", field!"name"(x.name)]),
		(in StructAlias x) =>
			jsonObject(alloc, [kindField!"alias", field!"name"(x.name)]),
		(in StructDecl x) =>
			jsonObject(alloc, [kindField!"struct", field!"name"(x.name)]),
		(in SpecDecl x) =>
			jsonObject(alloc, [kindField!"spec", field!"name"(x.name)]),
		(in TypeParamIndex x) =>
			jsonObject(alloc, [kindField!"type-param", field!"index"(x.index)]),
		(in VarDecl x) =>
			jsonObject(alloc, [kindField!"var", field!"name"(x.name)]));

Json jsonOfUriAndRange(ref Alloc alloc, in Ctx ctx, in UriAndRange range) =>
	jsonObject(alloc, [
		field!"uri"(stringOfUri(alloc, range.uri)),
		field!"range"(jsonOfRange(alloc, ctx, range.range))]);

Json jsonOfRange(ref Alloc alloc, in Ctx ctx, in Range range) =>
	jsonOfLineAndColumnRange(alloc, ctx.lineAndColumnGetter[range]);

Json jsonOfImportOrExport(ref Alloc alloc, in Ctx ctx, in ImportOrExport a) =>
	jsonObject(alloc, [
		optionalField!("source", ImportOrExportAst*)(a.source, (in ImportOrExportAst* x) =>
			jsonOfRange(alloc, ctx, x.pathRange)),
		field!"module"(stringOfUri(alloc, a.module_.uri)),
		optionalField!"names"(a.hasImported, () =>
			jsonListOfKeys!(NameReferents*, Symbol, nameFromNameReferentsPointer)(
				alloc, a.imported,
				(in Symbol x, in Symbol y) => compareSymbolsNaturally(x, y),
				(in Symbol x) => jsonString(x)))]);

const struct Ctx {
	Module* curModule;
	LineAndColumnGetter lineAndColumnGetter;
}

Json jsonOfStructAlias(ref Alloc alloc, in Ctx ctx, ref StructAlias a) =>
	jsonObject(
		alloc,
		commonDeclFields(alloc, ctx, AnyDecl(&a)),
		[field!"target"(jsonOfStructInst(alloc, ctx, *a.target))]);

Json jsonOfStructDecl(ref Alloc alloc, in Ctx ctx, ref StructDecl a) =>
	jsonObject(
		alloc,
		commonDeclFields(alloc, ctx, AnyDecl(&a)),
		[
			optionalField!"purity"(a.purity != Purity.data, () => jsonString(stringOfEnum(a.purity))),
			optionalFlagField!"forced"(a.purityIsForced),
			field!"body"(jsonOfStructBody(alloc, ctx, a.body_)),
			field!"variants"(jsonList!SumTypeMembership(alloc, a.sumTypeMemberships, (in SumTypeMembership x) =>
				jsonOfSumTypeMembership(alloc, ctx, x)))]);

Json jsonOfStructBody(ref Alloc alloc, in Ctx ctx, ref StructBody a) =>
	a.match!Json(
		(StructBody.Bogus) =>
			jsonString("bogus"),
		(BuiltinType x) =>
			jsonString(stringOfEnum(x)),
		(ref StructBody.Enum x) =>
			jsonOfEnumOrFlags(alloc, ctx, "enum", x.storage, x.members),
		(StructBody.Extern x) =>
			jsonObject(alloc, [
				kindField!"extern",
				optionalField!("size", TypeSize)(x.size, (TypeSize size) =>
					jsonOfTypeSize(alloc, size))]),
		(StructBody.Flags x) =>
			jsonOfEnumOrFlags(alloc, ctx, "flags", x.storage, x.members),
		(StructBody.Record x) =>
			jsonOfRecord(alloc, ctx, x),
		(StructBody.SumType x) =>
			jsonOfVariant(alloc, ctx, x));

Json jsonOfEnumOrFlags(
	ref Alloc alloc,
	in Ctx ctx,
	string kind,
	IntegralType storage,
	in EnumOrFlagsMember[] members,
) =>
	jsonObject(alloc, [
		kindField(kind),
		field!"storage"(stringOfEnum(storage)),
		field!"members"(jsonList!EnumOrFlagsMember(alloc, members, (in EnumOrFlagsMember x) =>
			jsonOfEnumOrFlagsMember(alloc, ctx, x)))]);

Json jsonOfEnumOrFlagsMember(ref Alloc alloc, in Ctx ctx, in EnumOrFlagsMember a) =>
	jsonObject(alloc, [
		docCommentField(alloc, ctx, a.docComment),
		field!"value"(a.value.asUnsigned)]);

Json jsonOfTypeSize(ref Alloc alloc, in TypeSize a) =>
	jsonObject(alloc, [
		field!"size"(a.sizeBytes),
		field!"align"(a.alignmentBytes)]);

Json jsonOfRecord(ref Alloc alloc, in Ctx ctx, in StructBody.Record a) =>
	jsonObject(alloc, [
		kindField!"record",
		field!"flags"(jsonOfRecordFlags(alloc, ctx, a.flags)),
		field!"fields"(jsonList!RecordField(alloc, a.fields, (in RecordField x) =>
			jsonOfRecordField(alloc, ctx, x)))]);

Json jsonOfRecordFlags(ref Alloc alloc, in Ctx ctx, in RecordFlags a) =>
	jsonObject(alloc, [
		field!"new"(stringOfVisibility(a.newVisibility)),
		optionalFlagField!"nominal"(a.nominal),
		optionalFlagField!"packed"(a.packed),
		optionalField!("forced", ByValOrRef)(a.forcedByValOrRef, (in ByValOrRef x) =>
			jsonString(stringOfEnum(x)))]);

Json jsonOfRecordField(ref Alloc alloc, in Ctx ctx, in RecordField a) =>
	jsonObject(alloc, [
		docCommentField(alloc, ctx, a.docComment),
		field!"visibility"(stringOfVisibility(a.visibility)),
		optionalField!("mut", Visibility)(a.mutability, (in Visibility x) =>
			jsonString(stringOfVisibility(x))),
		field!"type"(jsonOfType(alloc, ctx, a.type))]);

Json jsonOfVariant(ref Alloc alloc, in Ctx ctx, in StructBody.SumType a) =>
	jsonObject(alloc, [
		kindField!"variant",
		field!"kind"(stringOfEnum(a.kind)),
		field!"listed-members"(
			jsonList!SumTypeMemberAndMethodImpls(alloc, a.listedMembers, (in SumTypeMemberAndMethodImpls m) =>
				jsonOfVariantMember(alloc, ctx, m))),
		field!"methods"(jsonOfSignatures(alloc, ctx, a.methods))]);

Json jsonOfVariantMember(ref Alloc alloc, in Ctx ctx, in SumTypeMemberAndMethodImpls a) =>
	jsonObject(alloc, [
		field!"member"(jsonOfStructInst(alloc, ctx, *a.member)),
		field!"method-impls"(jsonOfMethodImpls(alloc, ctx, a.methodImpls))]);

Json jsonOfSumTypeMembership(ref Alloc alloc, in Ctx ctx, in SumTypeMembership a) =>
	jsonObject(alloc, [
		field!"variant"(jsonOfStructInst(alloc, ctx, *a.sumType)),
		field!"method-impls"(jsonOfMethodImpls(alloc, ctx, a.methodImpls))]);

Json jsonOfMethodImpls(ref Alloc alloc, in Ctx ctx, in Opt!Called[] methodImpls) =>
	jsonList!(Opt!Called)(alloc, methodImpls, (in Opt!Called x) =>
		has(x) ? jsonOfCalled(alloc, ctx, force(x)) : jsonNull);

Json jsonOfVarDecl(ref Alloc alloc, in Ctx ctx, ref VarDecl a) =>
	jsonObject(alloc,
		commonDeclFields(alloc, ctx, AnyDecl(&a)),
		[
			field!"var-kind"(stringOfEnum(a.kind)),
			field!"type"(jsonOfType(alloc, ctx, a.type)),
			optionalField!("library-name", Symbol)(a.externLibraryName, (in Symbol x) => jsonString(x)),
		]);

Json jsonOfSpecDecl(ref Alloc alloc, in Ctx ctx, ref SpecDecl a) =>
	jsonObject(
		alloc,
		commonDeclFields(alloc, ctx, AnyDecl(&a)),
		[
			optionalField!("builtin", BuiltinSpec)(a.builtin, (in BuiltinSpec x) => jsonString(stringOfEnum(x))),
			field!"parents"(jsonList!(SpecInst*)(alloc, a.parents, (in SpecInst* x) =>
				jsonOfSpecInst(alloc, ctx, *x))),
			field!"sigs"(jsonOfSignatures(alloc, ctx, a.sigs)),
		]);

Json jsonOfSignatures(ref Alloc alloc, in Ctx ctx, in Signature[] a) =>
	jsonList!Signature(alloc, a, (in Signature x) =>
		jsonOfSignature(alloc, ctx, x));

Json jsonOfSignature(ref Alloc alloc, in Ctx ctx, in Signature a) =>
	jsonObject(alloc, [
		docCommentField(alloc, ctx, a.docComment),
		field!"where"(jsonOfLineAndColumnRange(alloc, ctx.lineAndColumnGetter[a.range.range])),
		field!"name"(a.name),
		field!"return-type"(jsonOfType(alloc, ctx, a.returnType)),
		field!"params"(jsonOfDestructures(alloc, ctx, a.params))]);

Json jsonOfFunDecl(ref Alloc alloc, in Ctx ctx, ref FunDecl a) =>
	jsonObject(
		alloc,
		commonDeclFields(alloc, ctx, AnyDecl(&a)),
		[
			field!"flags"(funFlags(alloc, a.flags)),
			field!"return-type"(jsonOfType(alloc, ctx, a.returnType)),
			field!"params"(jsonOfParams(alloc, ctx, a.params)),
			optionalArrayField!"specs"(alloc, a.specs, (ref SpecInst* x) =>
				jsonOfSpecInst(alloc, ctx, *x)),
			field!"body"(jsonOfFunBody(alloc, ctx, a.body_)),
		]);

Json jsonOfTest(ref Alloc alloc, in Ctx ctx, in Test a) =>
	jsonObject(alloc, [
		docCommentField(alloc, ctx, a.docComment),
		field!"body"(jsonOfExpr(alloc, ctx, a.body_))]);

Opt!(Json.ObjectField)[4] commonDeclFields(ref Alloc alloc, in Ctx ctx, in AnyDecl decl) =>
	[
		docCommentField(alloc, ctx, decl.docComment),
		field!"visibility"(stringOfVisibility(decl.visibility)),
		field!"name"(decl.name),
		optionalArrayField!("type-params", NameAndRange)(alloc, decl.typeParams, (in NameAndRange x) =>
			jsonOfTypeParam(alloc, x)),
	];

Json funFlags(ref Alloc alloc, in FunFlags a) {
	Opt!Symbol[4] symbols = [
		flag!"bare"(a.bare),
		flag!"summon"(a.summon),
		() {
			final switch (a.safety) {
				case FunFlags.Safety.safe:
					return none!Symbol;
				case FunFlags.Safety.trusted:
					return some(symbol!"trusted");
				case FunFlags.Safety.unsafe:
					return some(symbol!"unsafe");
			}
		}(),
		flag!"ok-if-unused"(a.okIfUnused),
	];
	return jsonList(mapOp!(Json, Opt!Symbol)(alloc, symbols, (ref Opt!Symbol x) =>
		has(x) ? some(jsonString(force(x))) : none!Json));
}

Opt!Symbol flag(string name)(bool a) =>
	a ? some(symbol!name) : none!Symbol;

Json jsonOfTypeParam(ref Alloc alloc, in NameAndRange a) =>
	jsonObject(alloc, [field!"name"(a.name)]);

Json jsonOfParams(ref Alloc alloc, in Ctx ctx, in Params a) =>
	a.matchIn!Json(
		(in Destructure[] params) =>
			jsonOfDestructures(alloc, ctx, params),
		(in Varargs v) =>
			jsonObject(alloc, [
				kindField!"varargs",
				field!"param"(jsonOfDestructure(alloc, ctx, v.param))]));

Json jsonOfDestructures(ref Alloc alloc, in Ctx ctx, in Destructure[] a) =>
	jsonList!Destructure(alloc, a, (in Destructure x) =>
		jsonOfDestructure(alloc, ctx, x));

Json jsonOfSpecInst(ref Alloc alloc, in Ctx ctx, in SpecInst a) =>
	jsonObject(alloc, [
		field!"name"(a.decl.name),
		optionalArrayField!("type-args", Type)(alloc, a.typeArgs, (in Type x) =>
			jsonOfType(alloc, ctx, x))]);

Json jsonOfFunBody(ref Alloc alloc, in Ctx ctx, in FunBody a) =>
	a.matchIn!Json(
		(in FunBody.Bogus) =>
			jsonString!"bogus" ,
		(in AutoFun _) =>
			jsonString!"auto",
		(in BuiltinFun x) =>
			jsonOfBuiltin(alloc, x),
		(in FunBody.CreateEnumOrFlags x) =>
			jsonObject(alloc, [kindField!"create-enum", field!"member"(x.member.name)]),
		(in FunBody.CreateExtern) =>
			jsonString!"new-extern",
		(in FunBody.CreateRecord) =>
			jsonString!"new-record",
		(in FunBody.CreateRecordAndConvertToSumType x) =>
			jsonObject(alloc, [kindField!"create-record-to-sum-type", field!"member"(x.member.decl.name)]),
		(in FunBody.CreateSumType x) =>
			jsonObject(alloc, [kindField!"create-sum-type"]),
		(in Expr x) =>
			jsonOfExpr(alloc, ctx, x),
		(in FunBody.Extern x) =>
			jsonObject(alloc, [
				kindField!"extern",
				field!"library-name"(x.libraryName)]),
		(in FunBody.FileImport x) =>
			jsonObject(alloc, [kindField!"file-import"]),
		(in FlagsFunction x) =>
			jsonObject(alloc, [
				kindField!"flags-fun",
				field!"fn"(stringOfEnum(x))]),
		(in FunBody.Method x) =>
			jsonObject(alloc, [kindField!"call-method", field!"method"(x.method.name)]),
		(in FunBody.RecordFieldCall x) =>
			jsonObject(alloc, [
				kindField!"field-call",
				field!"field"(x.field.name)]),
		(in FunBody.RecordFieldGet x) =>
			jsonObject(alloc, [
				kindField!"field-get",
				field!"field"(x.field.name)]),
		(in FunBody.RecordFieldPointer x) =>
			jsonObject(alloc, [
				kindField!"field-pointer",
				field!"field"(x.field.name)]),
		(in FunBody.RecordFieldSet x) =>
			jsonObject(alloc, [
				kindField!"field-set",
				field!"field"(x.field.name)]),
		(in FunBody.SumTypeMemberGet x) =>
			jsonObject(alloc, [kindField!"sum-type-member-get"]),
		(in FunBody.VarGet) =>
			jsonString!"var-get",
		(in FunBody.VarSet) =>
			jsonString!"var-set");

Json jsonOfType(ref Alloc alloc, in Ctx ctx, in Type a) =>
	a.matchIn!Json(
		(in BogusType) =>
			jsonString!"bogus" ,
		(in TypeParamIndex x) =>
			jsonObject(alloc, [
				kindField!"type-param",
				field!"index"(x.index)]),
		(in StructInst x) =>
			jsonOfStructInst(alloc, ctx, x));

Json jsonOfStructInst(ref Alloc alloc, in Ctx ctx, in StructInst a) =>
	jsonObject(alloc, [
		field!"name"(a.decl.name),
		optionalArrayField!("type-args", Type)(alloc, a.typeArgs, (in Type x) =>
			jsonOfType(alloc, ctx, x))]);

Json jsonOfExprs(ref Alloc alloc, in Ctx ctx, in Expr[] a) =>
	jsonList!Expr(alloc, a, (in Expr x) =>
		jsonOfExpr(alloc, ctx, x));

Json jsonOfExprAndType(ref Alloc alloc, in Ctx ctx, in ExprAndType a) =>
	jsonObject(alloc, [
		field!"expr"(jsonOfExpr(alloc, ctx, a.expr)),
		field!"type"(jsonOfType(alloc, ctx, a.type))]);

Json jsonOfExprRef(ref Alloc alloc, in Ctx ctx, in ExprRef a) =>
	jsonOfExprAndType(alloc, ctx, toExprAndType(a));

Json jsonOfExpr(ref Alloc alloc, in Ctx ctx, in Expr a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		field!"kind"(jsonOfExprKind(alloc, ctx, a.kind))]);

Json jsonOfExprKind(ref Alloc alloc, in Ctx ctx, in ExprKind a) =>
	a.matchIn!Json(
		(in AssertOrForbidExpr x) =>
			jsonObject(alloc, [
				kindField(x.isForbid ? "forbid" : "assert"),
				field!"condition"(jsonOfCondition(alloc, ctx, x.condition)),
				optionalField!("thrown", Expr*)(x.thrown, (in Expr* thrown) =>
					jsonOfExpr(alloc, ctx, *thrown))]),
		(in BogusCallExpr x) =>
			jsonObject(alloc, [
				kindField!"bogus-call",
				field!"candidates"(jsonList!CalledDecl(alloc, x.candidates, (in CalledDecl d) =>
					jsonOfCalledDecl(alloc, ctx, d))),
				field!"checked-args"(jsonList!ExprAndType(alloc, x.checkedArgs, (in ExprAndType e) =>
					jsonOfExprAndType(alloc, ctx, e)))]),
		(in BogusExpr _) =>
			jsonObject(alloc, [kindField!"bogus"]),
		(in BogusWrongTypeExpr x) =>
			jsonObject(alloc, [
				kindField!"bogus-wrong-type",
				field!"inner"(jsonOfExprRef(alloc, ctx, x.inner))]),
		(in CallExpr x) =>
			jsonObject(alloc, [
				kindField!"call",
				field!"called"(jsonOfCalled(alloc, ctx, x.called)),
				field!"args"(jsonOfExprs(alloc, ctx, x.args))]),
		(in CallOptionExpr x) =>
			jsonObject(alloc, [
				kindField!"option-call",
				field!"first-arg"(jsonOfExprAndType(alloc, ctx, x.firstArg)),
				field!"rest-args"(jsonList!Expr(alloc, x.restArgs, (in Expr arg) =>
					jsonOfExpr(alloc, ctx, arg))),
				field!"called"(jsonOfCalled(alloc, ctx, x.called))]),
		(in ClosureGetExpr x) =>
			jsonObject(alloc, [
				kindField!"closure-get",
				field!"index"(x.closureRef.index)]),
		(in ClosureSetExpr x) =>
			jsonObject(alloc, [
				kindField!"closure-set",
				field!"index"(x.closureRef.index)]),
		(in ExternExpr x) =>
			jsonObject(alloc, [
				kindField!"extern",
				field!"name"(jsonOfSymbolSet(alloc, x.names))]),
		(in FinallyExpr x) =>
			jsonObject(alloc, [
				kindField!"finally",
				field!"right"(jsonOfExpr(alloc, ctx, x.right)),
				field!"below"(jsonOfExpr(alloc, ctx, x.below))]),
		(in FunPointerExpr x) =>
			jsonObject(alloc, [
				kindField!"fun-pointer",
				field!"fun"(jsonOfCalled(alloc, ctx, x.called))]),
		(in IfExpr x) =>
			jsonObject(alloc, [
				kindField!"if",
				field!"condition"(jsonOfCondition(alloc, ctx, x.condition)),
				field!"true-branch"(jsonOfExpr(alloc, ctx, x.trueBranch)),
				field!"false-branch"(jsonOfExpr(alloc, ctx, x.falseBranch))]),
		(in LambdaExpr x) =>
			jsonObject(alloc, [
				kindField!"lambda",
				field!"param"(jsonOfDestructure(alloc, ctx, x.param)),
				field!"body"(jsonOfExpr(alloc, ctx, x.body_)),
				field!"closure"(jsonList!VariableRef(alloc, x.closure, (in VariableRef v) =>
					jsonString(v.name))),
				field!"fun-kind"(stringOfEnum(x.kind)),
				field!"return-type"(jsonOfType(alloc, ctx, x.returnType))]),
		(in LetExpr x) =>
			jsonObject(alloc, [
				kindField!"let",
				field!"destructure"(jsonOfDestructure(alloc, ctx, x.destructure)),
				field!"value"(jsonOfExpr(alloc, ctx, x.value)),
				field!"then"(jsonOfExpr(alloc, ctx, x.then))]),
		(in LiteralExpr x) =>
			jsonObject(alloc, [
				kindField!"literal",
				field!"value"(jsonOfConstant(alloc, x.value))]),
		(in LiteralStringLikeExpr x) =>
			jsonObject(alloc, [
				kindField!"string",
				field!"type"(jsonString(stringOfEnum(x.kind))),
				field!"value"(jsonString(alloc, x.value))]),
		(in LocalGetExpr x) =>
			jsonObject(alloc, [
				kindField!"local-get",
				field!"name"(x.local.name)]),
		(in LocalPointerExpr x) =>
			jsonObject(alloc, [
				kindField!"local-pointer",
				field!"name"(x.local.name)]),
		(in LocalSetExpr x) =>
			jsonObject(alloc, [
				kindField!"local-set",
				field!"name"(x.local.name),
				field!"value"(jsonOfExpr(alloc, ctx, *x.value))]),
		(in LoopExpr x) =>
			jsonObject(alloc, [
				kindField!"loop",
				field!"body"(jsonOfExpr(alloc, ctx, x.body_))]),
		(in LoopBreakExpr x) =>
			jsonObject(alloc, [
				kindField!"break",
				field!"value"(jsonOfExpr(alloc, ctx, x.value))]),
		(in LoopContinueExpr x) =>
			jsonObject(alloc, [kindField!"continue"]),
		(in LoopWhileOrUntilExpr x) =>
			jsonObject(alloc, [
				kindField(x.isUntil ? "until" : "while"),
				field!"condition"(jsonOfCondition(alloc, ctx, x.condition)),
				field!"body"(jsonOfExpr(alloc, ctx, x.body_)),
				field!"after"(jsonOfExpr(alloc, ctx, x.after))]),
		(in MatchEnumExpr x) =>
			jsonObject(alloc, [
				kindField!"match-enum",
				field!"matched"(jsonOfExprAndType(alloc, ctx, x.matched)),
				field!"cases"(jsonList!(MatchEnumExpr.Case)(alloc, x.cases, (in MatchEnumExpr.Case case_) =>
					jsonObject(alloc, [
						field!"member"(case_.member.name),
						field!"then"(jsonOfExpr(alloc, ctx, case_.then))]))),
				optionalField!("else", Expr)(x.else_, (in Expr else_) => jsonOfExpr(alloc, ctx, else_))]),
		(in MatchIntegralExpr x) =>
			jsonObject(alloc, [
				kindField!"match-integral",
				field!"matched"(jsonOfExprAndType(alloc, ctx, x.matched)),
				field!"cases"(jsonList!(MatchIntegralExpr.Case)(alloc, x.cases, (in MatchIntegralExpr.Case case_) =>
					jsonObject(alloc, [
						field!"value"(case_.value.value),
						field!"then"(jsonOfExpr(alloc, ctx, case_.then))]))),
				field!"else"(jsonOfExpr(alloc, ctx, x.else_))]),
		(in MatchStringLikeExpr x) =>
			jsonObject(alloc, [
				kindField!"match-string-like",
				field!"type"(stringOfEnum(x.kind)),
				field!"matched"(jsonOfExprAndType(alloc, ctx, x.matched)),
				field!"equals"(jsonOfCalled(alloc, ctx, x.equals)),
				field!"cases"(jsonList(map(alloc, x.cases, (ref MatchStringLikeExpr.Case case_) =>
					jsonObject(alloc, [
						field!"value"(case_.value),
						field!"then"(jsonOfExpr(alloc, ctx, case_.then))])))),
				field!"else"(jsonOfExpr(alloc, ctx, x.else_))]),
		(in MatchSumTypeExpr x) =>
			jsonObject(alloc, [
				kindField!"match-variant",
				field!"matched"(jsonOfExprAndType(alloc, ctx, x.matched)),
				field!"cases"(jsonOfMatchSumTypeCases(alloc, ctx, x.cases)),
				optionalField!("else", Expr*)(x.else_, (in Expr* y) => jsonOfExpr(alloc, ctx, *y))]),
		(in RecordFieldPointerExpr x) =>
			jsonObject(alloc, [
				kindField!"field-pointer",
				field!"target"(jsonOfExprAndType(alloc, ctx, x.target)),
				field!"field"(x.field.name)]),
		(in SeqExpr a) =>
			jsonObject(alloc, [
				kindField!"seq",
				field!"first"(jsonOfExpr(alloc, ctx, a.first)),
				field!"then"(jsonOfExpr(alloc, ctx, a.then))]),
		(in ThrowExpr a) =>
			jsonObject(alloc, [
				kindField!"throw",
				field!"thrown"(jsonOfExpr(alloc, ctx, a.thrown))]),
		(in TrustedExpr a) =>
			jsonObject(alloc, [
				kindField!"trusted",
				field!"inner"(jsonOfExpr(alloc, ctx, a.inner))]),
		(in TryExpr a) =>
			jsonObject(alloc, [
				kindField!"try",
				field!"tried"(jsonOfExpr(alloc, ctx, a.tried)),
				field!"catches"(jsonOfMatchSumTypeCases(alloc, ctx, a.catches))]),
		(in TryLetExpr a) =>
			jsonObject(alloc, [
				kindField!"try-let",
				field!"destructure"(jsonOfDestructure(alloc, ctx, a.destructure)),
				field!"value"(jsonOfExpr(alloc, ctx, a.value)),
				field!"catch"(jsonOfMatchSumTypeCase(alloc, ctx, a.catch_)),
				field!"then"(jsonOfExpr(alloc, ctx, a.then))]),
		(in TypedExpr a) =>
			jsonObject(alloc, [
				kindField!"typed",
				field!"inner"(jsonOfExpr(alloc, ctx, a.inner))]));

Json jsonOfCondition(ref Alloc alloc, in Ctx ctx, in Condition a) =>
	a.matchIn!Json(
		(in Expr x) =>
			jsonOfExpr(alloc, ctx, x),
		(in Condition.UnpackOption x) =>
			jsonObject(alloc, [
				field!"destructure"(jsonOfDestructure(alloc, ctx, x.destructure)),
				field!"option"(jsonOfExprAndType(alloc, ctx, x.option))]));

Json jsonOfDestructure(ref Alloc alloc, in Ctx ctx, in Destructure a) =>
	a.matchIn!Json(
		(in Destructure.Ignore _) =>
			jsonString!"_",
		(in Local x) =>
			jsonOfLocal(alloc, ctx, x),
		(in Destructure.Split split) =>
			jsonOfDestructureSplit(alloc, ctx, split));

Json jsonOfDestructureSplit(ref Alloc alloc, in Ctx ctx, in Destructure.Split a) =>
	jsonObject(alloc, [
		kindField!"split",
		field!"type"(jsonOfType(alloc, ctx, a.destructuredType)),
		field!"parts"(jsonOfDestructures(alloc, ctx, a.parts))]);

Json jsonOfLocal(ref Alloc alloc, in Ctx ctx, in Local a) =>
	jsonObject(alloc, [
		kindField!"local",
		field!"name"(a.name),
		field!"mutability"(jsonOfLocalMutability(alloc, ctx, a.mutability)),
		field!"type"(jsonOfType(alloc, ctx, a.type))]);
Json jsonOfLocalMutability(ref Alloc alloc, in Ctx ctx, in LocalMutability a) =>
	a.matchIn!Json(
		(in LocalMutability.Immutable) =>
			jsonString("immutable"),
		(in LocalMutability.MutableOnStack) =>
			jsonString("mutable-on-stack"),
		(in LocalMutability.MutableAllocated x) =>
			jsonObject(alloc, [
				kindField!"mutable-allocated",
				field!"reference-type"(jsonOfStructInst(alloc, ctx, *x.referenceType))]));

Json jsonOfCalled(ref Alloc alloc, in Ctx ctx, in Called a) =>
	a.matchIn!Json(
		(in Called.Bogus x) =>
			jsonObject(alloc, [
				kindField!"bogus",
				field!"decl"(x.decl.name),
				field!"return-type"(jsonOfType(alloc, ctx, x.returnType)),
				field!"param-types"(jsonList!Type(alloc, x.paramTypes, (in Type x) =>
					jsonOfType(alloc, ctx, x)))]),
		(in FunInst x) =>
			jsonOfFunInst(alloc, ctx, x),
		(in CalledSpecSig x) =>
			jsonOfCalledSpecSig(alloc, ctx, x));

Json jsonOfCalledDecl(ref Alloc alloc, in Ctx ctx, in CalledDecl a) =>
	a.matchIn!Json(
		(in FunDecl x) =>
			jsonOfFunDeclReference(alloc, ctx, x),
		(in CalledSpecSig x) =>
			jsonOfCalledSpecSig(alloc, ctx, x));

Json jsonOfFunDeclReference(ref Alloc alloc, in Ctx ctx, in FunDecl a) =>
	jsonObject(alloc, [
		field!"name"(a.name),
		field!"range"(jsonOfUriAndRange(alloc, ctx, a.range))]);

Json jsonOfFunInst(ref Alloc alloc, in Ctx ctx, in FunInst a) =>
	jsonObject(alloc, [
		field!"name"(a.decl.name),
		optionalArrayField!("type-args", Type)(alloc, a.typeArgs, (in Type x) =>
			jsonOfType(alloc, ctx, x)),
		optionalArrayField!("spec-impls", Called)(alloc, a.specImpls, (in Called x) =>
			jsonOfCalled(alloc, ctx, x))]);

Json jsonOfCalledSpecSig(ref Alloc alloc, in Ctx ctx, in CalledSpecSig a) =>
	jsonObject(alloc, [
		kindField!"spec-sig",
		field!"spec"(a.specInst.decl.name),
		field!"name"(a.name)]);

Json jsonOfMatchSumTypeCases(ref Alloc alloc, in Ctx ctx, in MatchSumTypeCase[] cases) =>
	jsonList!MatchSumTypeCase(alloc, cases, (in MatchSumTypeCase x) =>
		jsonOfMatchSumTypeCase(alloc, ctx, x));

Json jsonOfMatchSumTypeCase(ref Alloc alloc, in Ctx ctx, in MatchSumTypeCase a) =>
	jsonObject(alloc, [
		field!"member"(a.member.decl.name),
		field!"destructure"(jsonOfDestructure(alloc, ctx, a.destructure)),
		field!"then"(jsonOfExpr(alloc, ctx, a.then))]);

Json jsonOfSymbolSet(ref Alloc alloc, in SymbolSet a) =>
	Json(buildArray!Json(alloc, (scope ref Builder!Json out_) {
		foreach (Symbol x; a)
			out_ ~= Json(x);
	}));
