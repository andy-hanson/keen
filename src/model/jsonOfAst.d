module model.jsonOfAst;

@safe @nogc pure nothrow:

import model.ast :
	ArrowAccessAst,
	AssertOrForbidAst,
	AssertOrForbidThrownAst,
	AssignmentAst,
	AssignmentCallAst,
	BogusAst,
	CallAst,
	CallNamedAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	DestructureAst,
	DoAst,
	DocCommentAst,
	EmptyAst,
	EnumOrFlagsMemberAst,
	ExprAst,
	ExprAstKind,
	ExternAst,
	FieldMutabilityAst,
	FileAst,
	FinallyAst,
	ForAst,
	FunDeclAst,
	ModifierAst,
	IdentifierAst,
	IfAst,
	ImportOrExportAst,
	ImportOrExportAstKind,
	ImportsOrExportsAst,
	InterpolatedAst,
	LambdaAst,
	LetAst,
	LiteralFloatAst,
	LiteralIntegral,
	LiteralIntegralAndRange,
	LiteralStringAst,
	LoopAst,
	LoopBreakAst,
	LoopContinueAst,
	LoopWhileOrUntilAst,
	MatchAst,
	MatchElseAst,
	ModifierAst,
	NameAndRange,
	ParamsAst,
	ParenthesizedAst,
	PathOrRelPath,
	PtrAst,
	RecordOrUnionMemberAst,
	SeqAst,
	SharedAst,
	SpecDeclAst,
	SignatureAst,
	SpecUseAst,
	StructAliasAst,
	StructBodyAst,
	StructDeclAst,
	stringOfModifierKeyword,
	symbolForTypeAstSuffix,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	VarDeclAst,
	WithAst;
import model.model : Visibility;
import util.alloc.alloc : Alloc;
import util.json :
	field,
	Json,
	jsonObject,
	optionalArrayField,
	optionalField,
	Json,
	jsonInt,
	jsonList,
	jsonString,
	kindField;
import util.opt : force, Opt;
import util.sourceRange : jsonOfLineAndColumn, jsonOfLineAndColumnRange, LineAndColumnGetter, Pos, PosKind, Range;
import util.union_ : Union;
import util.uri : Path, RelPath, stringOfPath;
import util.util : stringOfEnum;
import util.writer : makeStringWithWriter;

Json jsonOfAst(ref Alloc alloc, in LineAndColumnGetter lineAndColumnGetter, in FileAst ast) {
	Ctx ctx = Ctx(lineAndColumnGetter);
	return jsonObject(alloc, [
		docCommentField(alloc, ctx, ast.docComment),
		optionalField!("imports", ImportsOrExportsAst)(ast.imports, (in ImportsOrExportsAst x) =>
			jsonOfImportsOrExports(alloc, ctx, x)),
		optionalField!("exports", ImportsOrExportsAst)(ast.reExports, (in ImportsOrExportsAst x) =>
			jsonOfImportsOrExports(alloc, ctx, x)),
		optionalArrayField!("regions", Range)(alloc, ast.regions, (in Range x) =>
			jsonOfRange(alloc, ctx, x)),
		optionalArrayField!("specs", SpecDeclAst)(alloc, ast.specs, (in SpecDeclAst a) =>
			jsonOfSpecDeclAst(alloc, ctx, a)),
		optionalArrayField!("aliases", StructAliasAst)(alloc, ast.structAliases, (in StructAliasAst a) =>
			jsonOfStructAliasAst(alloc, ctx, a)),
		optionalArrayField!("structs", StructDeclAst)(alloc, ast.structs, (in StructDeclAst a) =>
			jsonOfStructDeclAst(alloc, ctx, a)),
		optionalArrayField!("funs", FunDeclAst)(alloc, ast.funs, (in FunDeclAst a) =>
			jsonOfFunDeclAst(alloc, ctx, a)),
		optionalArrayField!("vars", VarDeclAst)(alloc, ast.vars, (in VarDeclAst a) =>
			jsonOfVarDeclAst(alloc, ctx, a))]);
}

private:

const struct Ctx {
	LineAndColumnGetter lineAndColumnGetter;
}

Opt!(Json.ObjectField) docCommentField(ref Alloc alloc, in Ctx ctx, in DocCommentAst a) =>
	optionalField!"doc"(!a.isEmpty, () =>
		jsonObject(alloc, [
			field!"range"(jsonOfRange(alloc, ctx, force(a.range))),
			field!"references"(jsonOfNameAndRangeArray(alloc, ctx, a.references))]));

Json jsonOfRange(ref Alloc alloc, in Ctx ctx, in Range a) =>
	jsonOfLineAndColumnRange(alloc, ctx.lineAndColumnGetter[a]);

Json jsonOfImportsOrExports(ref Alloc alloc, in Ctx ctx, in ImportsOrExportsAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		field!"imports"(jsonList!ImportOrExportAst(alloc, a.paths, (in ImportOrExportAst a) =>
			jsonOfImportOrExportAst(alloc, ctx, a)))]);

Json jsonOfImportOrExportAst(ref Alloc alloc, in Ctx ctx, in ImportOrExportAst a) =>
	jsonObject(alloc, [
		field!"path"(pathOrRelPathToJson(alloc, a.path)),
		field!"import-kind"(a.kind.matchIn!Json(
			(in ImportOrExportAstKind.ModuleWhole) =>
				jsonString!"whole",
			(in NameAndRange[] names) =>
				jsonObject(alloc, [field!"names"(jsonOfNameAndRangeArray(alloc, ctx, names))]),
			(in ImportOrExportAstKind.File f) =>
				jsonObject(alloc, [
					field!"name"(jsonOfNameAndRange(alloc, ctx, f.name)),
					field!"file-type"(stringOfEnum(f.type))])))]);

Json pathOrRelPathToJson(ref Alloc alloc, in PathOrRelPath a) =>
	a.match!Json(
		(Path global) =>
			jsonString(stringOfPath(alloc, global)),
		(RelPath relPath) =>
			jsonObject(alloc, [
				field!"n-parents"(relPath.nParents),
				field!"path"(stringOfPath(alloc, relPath.path))]));

Json jsonOfSpecDeclAst(ref Alloc alloc, in Ctx ctx, in SpecDeclAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		docCommentField(alloc, ctx, a.docComment),
		visibilityField(a.visibility_),
		field!"name"(jsonOfNameAndRange(alloc, ctx, a.name)),
		field!"modifiers"(jsonOfModifiers(alloc, ctx, a.modifiers)),
		maybeTypeParams(alloc, ctx, a.typeParams),
		field!"sigs"(jsonOfSignatureAsts(alloc, ctx, a.sigs))]);

Opt!(Json.ObjectField) visibilityField(Opt!Visibility a) =>
	optionalField!("visibility", Visibility)(a, (in Visibility x) =>
		jsonString(stringOfEnum(x)));

Json jsonOfSignatureAsts(ref Alloc alloc, in Ctx ctx, in SignatureAst[] a) =>
	jsonList!SignatureAst(alloc, a, (in SignatureAst x) =>
		jsonOfSignatureAst(alloc, ctx, x));
Json jsonOfSignatureAst(ref Alloc alloc, in Ctx ctx, in SignatureAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		docCommentField(alloc, ctx, a.docComment),
		field!"name"(a.name),
		field!"return-type"(jsonOfTypeAst(alloc, ctx, a.returnType)),
		field!"params"(jsonOfParamsAst(alloc, ctx, a.params))]);

Json jsonOfStructAliasAst(ref Alloc alloc, in Ctx ctx, in StructAliasAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		docCommentField(alloc, ctx, a.docComment),
		visibilityField(a.visibility_),
		field!"name"(jsonOfNameAndRange(alloc, ctx, a.name)),
		maybeTypeParams(alloc, ctx, a.typeParams),
		field!"target"(jsonOfTypeAst(alloc, ctx, a.target))]);

Json jsonOfEnumOrFlags(
	ref Alloc alloc,
	in Ctx ctx,
	string name,
	in Opt!ParamsAst params,
	in EnumOrFlagsMemberAst[] members,
) =>
	jsonObject(alloc, [
		kindField(name),
		optionalField!("params", ParamsAst)(params, (in ParamsAst x) =>
			jsonOfParamsAst(alloc, ctx, x)),
		field!"members"(jsonList!EnumOrFlagsMemberAst(
			alloc, members, (in EnumOrFlagsMemberAst x) =>
				jsonOfEnumOrFlagsMember(alloc, ctx, x)))]);

Json jsonOfEnumOrFlagsMember(ref Alloc alloc, in Ctx ctx, in EnumOrFlagsMemberAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		field!"name"(a.name),
		optionalField!("value", LiteralIntegralAndRange)(a.value, (in LiteralIntegralAndRange x) =>
			jsonOfLiteralIntegralAndRange(alloc, ctx, x))]);

Json jsonOfLiteralFloatAst(ref Alloc alloc, in LiteralFloatAst a) =>
	jsonObject(alloc, [
		kindField!"float",
		// Convert to a string to avoid losing long -> double conversion
		field!"long"(makeStringWithWriter(alloc, a.value.longValue)),
		field!"exponent"(makeStringWithWriter(alloc, a.value.exponent)),
		field!"overflow"(a.overflow)]);

Json jsonOfLiteralStringAst(ref Alloc alloc, in LiteralStringAst a) =>
	jsonObject(alloc, [
		kindField!"string",
		field!"value"(jsonString(alloc, a.value))]);

Json jsonOfLiteralIntegralAndRange(ref Alloc alloc, in Ctx ctx, in LiteralIntegralAndRange a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		field!"literal"(jsonOfLiteralIntegral(alloc, a.literal))]);

Json jsonOfLiteralIntegral(ref Alloc alloc, in LiteralIntegral a) =>
	jsonObject(alloc, [
		field!"is-signed"(a.isSigned),
		field!"overflow"(a.overflow),
		field!"value"(a.isSigned
			? makeStringWithWriter(alloc, a.value.asSigned)
			: makeStringWithWriter(alloc, a.value.asUnsigned))]);

Json jsonOfStructDeclAst(ref Alloc alloc, in Ctx ctx, in StructDeclAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		docCommentField(alloc, ctx, a.docComment),
		visibilityField(a.visibility_),
		maybeTypeParams(alloc, ctx, a.typeParams),
		field!"modifiers"(jsonOfModifiers(alloc, ctx, a.modifiers)),
		field!"body"(jsonOfStructBodyAst(alloc, ctx, a.body_))]);

Json jsonOfStructBodyAst(ref Alloc alloc, in Ctx ctx, in StructBodyAst a) =>
	a.matchIn!Json(
		(in StructBodyAst.Builtin) =>
			jsonString!"builtin" ,
		(in StructBodyAst.Enum e) =>
			jsonOfEnumOrFlags(alloc, ctx, "enum", e.params, e.members),
		(in StructBodyAst.Extern) =>
			jsonString!"extern",
		(in StructBodyAst.Flags e) =>
			jsonOfEnumOrFlags(alloc, ctx, "flags", e.params, e.members),
		(in StructBodyAst.Record a) =>
			jsonOfRecordAst(alloc, ctx, a),
		(in StructBodyAst.Variant x) =>
			jsonObject(alloc, [
				field!"kind"(stringOfEnum(x.kind)),
				field!"types"(jsonOfTypeAsts(alloc, ctx, x.types)),
				field!"methods"(jsonOfSignatureAsts(alloc, ctx, x.methods))]));

Json jsonOfRecordAst(ref Alloc alloc, in Ctx ctx, in StructBodyAst.Record a) =>
	jsonObject(alloc, [
		kindField!"record",
		optionalField!("params", ParamsAst)(a.params, (in ParamsAst x) => jsonOfParamsAst(alloc, ctx, x)),
		field!"fields"(jsonList!RecordOrUnionMemberAst(alloc, a.fields, (in RecordOrUnionMemberAst x) =>
			jsonOfRecordField(alloc, ctx, x)))]);

Json jsonOfRecordField(ref Alloc alloc, in Ctx ctx, in RecordOrUnionMemberAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		visibilityField(a.visibility_),
		field!"name"(jsonOfNameAndRange(alloc, ctx, a.name)),
		optionalField!("mutability", FieldMutabilityAst)(a.mutability, (in FieldMutabilityAst x) =>
			jsonObject(alloc, [
				field!"pos"(x.pos),
				visibilityField(x.visibility_)])),
		optionalField!("type", TypeAst)(a.type, (in TypeAst x) =>
			jsonOfTypeAst(alloc, ctx, x))]);

Opt!(Json.ObjectField) maybeTypeParams(ref Alloc alloc, in Ctx ctx, in NameAndRange[] typeParams) =>
	optionalArrayField!("type-params", NameAndRange)(alloc, typeParams, (in NameAndRange x) =>
		jsonOfNameAndRange(alloc, ctx, x));

Json jsonOfFunDeclAst(ref Alloc alloc, in Ctx ctx, in FunDeclAst a) =>
	jsonObject(alloc, [
		docCommentField(alloc, ctx, a.docComment),
		visibilityField(a.visibility_),
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		field!"name"(jsonOfNameAndRange(alloc, ctx, a.name)),
		maybeTypeParams(alloc, ctx, a.typeParams),
		field!"return"(jsonOfTypeAst(alloc, ctx, a.returnType)),
		field!"params"(jsonOfParamsAst(alloc, ctx, a.params)),
		field!"modifiers"(jsonOfModifiers(alloc, ctx, a.modifiers)),
		field!"body"(jsonOfExprAst(alloc, ctx, a.body_))]);

Json jsonOfParamsAst(ref Alloc alloc, in Ctx ctx, in ParamsAst a) =>
	a.matchIn!Json(
		(in DestructureAst[] params) =>
			jsonOfDestructureAsts(alloc, ctx, params),
		(in ParamsAst.Varargs v) =>
			jsonObject(alloc, [
				kindField!"varargs",
				field!"param"(jsonOfDestructureAst(alloc, ctx, v.param))]));


Json jsonOfModifiers(ref Alloc alloc, in Ctx ctx, in ModifierAst[] modifiers) =>
	jsonList!ModifierAst(alloc, modifiers, (in ModifierAst x) =>
		jsonOfModifierAst(alloc, ctx, x));

Json jsonOfModifierAst(ref Alloc alloc, in Ctx ctx, in ModifierAst a) =>
	a.matchIn!Json(
		(in ModifierAst.Keyword x) =>
			jsonObject(alloc, [
				kindField!"keyword",
				optionalField!("type-arg", TypeAst)(x.typeArg, (in TypeAst type) =>
					jsonOfTypeAst(alloc, ctx, type)),
				field!"keyword-pos"(x.keywordPos),
				field!"keyword"(stringOfModifierKeyword(x.keyword))]),
		(in SpecUseAst x) =>
			jsonOfSpecUseAst(alloc, ctx, x));

Json jsonOfSpecUseAst(ref Alloc alloc, in Ctx ctx, in SpecUseAst a) =>
	jsonObject(alloc, [
		kindField!"spec",
		optionalField!("type-arg", TypeAst)(a.typeArg, (in TypeAst x) =>
			jsonOfTypeAst(alloc, ctx, x)),
		field!"name"(jsonOfNameAndRange(alloc, ctx, a.name))]);

Json jsonOfTypeAst(ref Alloc alloc, in Ctx ctx, in TypeAst a) =>
	a.matchIn!Json(
		(in TypeAst.Bogus x) =>
			jsonObject(alloc, [
				kindField!"bogus",
				field!"range"(jsonOfRange(alloc, ctx, x.range))]),
		(in TypeAst.Fun x) =>
			jsonObject(alloc, [
				kindField!"fun",
				field!"return-type"(jsonOfTypeAst(alloc, ctx, x.returnType)),
				field!"kind"(stringOfEnum(x.kind)),
				field!"param"(jsonOfParamsAst(alloc, ctx, x.params))]),
		(in TypeAst.Map x) =>
			jsonObject(alloc, [
				kindField!"map",
				field!"key"(jsonOfTypeAst(alloc, ctx, x.v)),
				field!"value"(jsonOfTypeAst(alloc, ctx, x.k))]),
		(in NameAndRange x) =>
			jsonOfNameAndRange(alloc, ctx, x),
		(in TypeAst.SuffixName x) =>
			jsonObject(alloc, [
				kindField!"suffix",
				field!"left"(jsonOfTypeAst(alloc, ctx, x.left)),
				field!"name"(jsonOfNameAndRange(alloc, ctx, x.name))]),
		(in TypeAst.SuffixSpecial x) =>
			jsonObject(alloc, [
				kindField!"suffix-special",
				field!"left"(jsonOfTypeAst(alloc, ctx, x.left)),
				field!"suffix-pos"(x.suffixPos),
				field!"suffix"(symbolForTypeAstSuffix(x.kind))]),
		(in TypeAst.Tuple x) =>
			jsonObject(alloc, [
				kindField!"tuple",
				field!"range"(jsonOfRange(alloc, ctx, x.range)),
				field!"members"(jsonOfTypeAsts(alloc, ctx, x.members))]));

Json jsonOfTypeAsts(ref Alloc alloc, in Ctx ctx, in TypeAst[] a) =>
	jsonList!TypeAst(alloc, a, (in TypeAst x) =>
		jsonOfTypeAst(alloc, ctx, x));

Json jsonOfDestructureAsts(ref Alloc alloc, in Ctx ctx, in DestructureAst[] a) =>
	jsonList!DestructureAst(alloc, a, (in DestructureAst x) =>
		jsonOfDestructureAst(alloc, ctx, x));

Json jsonOfDestructureAst(ref Alloc alloc, in Ctx ctx, in DestructureAst a) =>
	a.matchIn!Json(
		(in DestructureAst.Single x) =>
			jsonObject(alloc, [
				kindField!"single",
				field!"name"(jsonOfNameAndRange(alloc, ctx, x.name)),
				optionalField!("mut", Pos)(x.mut, (in Pos y) => jsonInt(y)),
				optionalField!("type", TypeAst*)(x.type, (in TypeAst* t) =>
					jsonOfTypeAst(alloc, ctx, *t))]),
		(in DestructureAst.Void x) =>
			jsonObject(alloc, [
				kindField!"void",
				field!"range"(jsonOfRange(alloc, ctx, x.range))]),
		(in DestructureAst[] parts) =>
			jsonList!DestructureAst(alloc, parts, (in DestructureAst part) =>
				jsonOfDestructureAst(alloc, ctx, part)));

Json jsonOfExprAst(ref Alloc alloc, in Ctx ctx, in ExprAst ast) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, ast.range)),
		field!"kind"(jsonOfExprAstKind(alloc, ctx, ast.kind))]);

Json jsonOfExprAsts(ref Alloc alloc, in Ctx ctx, in ExprAst[] asts) =>
	jsonList!ExprAst(alloc, asts, (in ExprAst x) =>
		jsonOfExprAst(alloc, ctx, x));

Json jsonOfNameAndRangeArray(ref Alloc alloc, in Ctx ctx, in NameAndRange[] a) =>
	jsonList!NameAndRange(alloc, a, (in NameAndRange x) =>
		jsonOfNameAndRange(alloc, ctx, x));

Json jsonOfNameAndRange(ref Alloc alloc, in Ctx ctx, in NameAndRange a) =>
	jsonObject(alloc, [
		field!"start"(jsonOfLineAndColumn(alloc, ctx.lineAndColumnGetter[a.start, PosKind.startOfRange])),
		field!"name"(a.name)]);

Json jsonOfExprAstKind(ref Alloc alloc, in Ctx ctx, in ExprAstKind ast) =>
	ast.matchIn!Json(
		(in ArrowAccessAst e) =>
			jsonObject(alloc, [
				kindField!"arrow-access",
				field!"left"(jsonOfExprAst(alloc, ctx, *e.left)),
				field!"name"(jsonOfNameAndRange(alloc, ctx, e.name))]),
		(in AssertOrForbidAst e) =>
			jsonObject(alloc, [
				kindField(e.isForbid ? "forbid" : "assert"),
				field!"condition"(jsonOfConditionAst(alloc, ctx, e.condition)),
				optionalField!("thrown", AssertOrForbidThrownAst*)(e.thrown, (in AssertOrForbidThrownAst* thrown) =>
					jsonObject(alloc, [
						field!"colon"(thrown.colonPos),
						field!"expr"(jsonOfExprAst(alloc, ctx, thrown.expr))])),
				field!"after"(jsonOfExprAst(alloc, ctx, *e.after))]),
		(in AssignmentAst e) =>
			jsonObject(alloc, [
				kindField!"assign",
				field!"left"(jsonOfExprAst(alloc, ctx, e.left)),
				field!"right"(jsonOfExprAst(alloc, ctx, e.right))]),
		(in AssignmentCallAst e) =>
			jsonObject(alloc, [
				kindField!"assign-call",
				field!"left"(jsonOfExprAst(alloc, ctx, e.left)),
				field!"fun-name"(jsonOfNameAndRange(alloc, ctx, e.funName)),
				field!"right"(jsonOfExprAst(alloc, ctx, e.right))]),
		(in BogusAst _) =>
			jsonObject(alloc, [kindField!"bogus"]),
		(in CallAst e) =>
			jsonObject(alloc, [
				kindField!"call",
				field!"style"(stringOfEnum(e.style)),
				field!"fun-name"(jsonOfNameAndRange(alloc, ctx, e.funName)),
				optionalField!("type-arg", TypeAst*)(e.typeArg, (in TypeAst* x) =>
					jsonOfTypeAst(alloc, ctx, *x)),
				field!"args"(jsonOfExprAsts(alloc, ctx, e.args))]),
		(in CallNamedAst x) =>
			jsonObject(alloc, [
				kindField!"call-named",
				field!"names"(jsonOfNameAndRangeArray(alloc, ctx, x.names)),
				field!"args"(jsonOfExprAsts(alloc, ctx, x.args))]),
		(in DoAst x) =>
			jsonObject(alloc, [
				kindField!"do",
				field!"body"(jsonOfExprAst(alloc, ctx, *x.body_))]),
		(in EmptyAst _) =>
			jsonObject(alloc, [kindField!"empty"]),
		(in ExternAst x) =>
			jsonObject(alloc, [kindField!"extern", field!"name"(jsonOfNameAndRangeArray(alloc, ctx, x.names))]),
		(in FinallyAst x) =>
			jsonObject(alloc, [
				kindField!"finally",
				field!"right"(jsonOfExprAst(alloc, ctx, x.right)),
				field!"below"(jsonOfExprAst(alloc, ctx, x.below))]),
		(in ForAst x) =>
			jsonObject(alloc, [
				kindField!"for",
				field!"param"(jsonOfDestructureAst(alloc, ctx, x.param)),
				field!"collection"(jsonOfExprAst(alloc, ctx, x.collection)),
				field!"body"(jsonOfExprAst(alloc, ctx, x.body_)),
				field!"else"(jsonOfExprAst(alloc, ctx, x.else_))]),
		(in IdentifierAst a) =>
			jsonObject(alloc, [
				kindField!"identifier",
				field!"name"(a.name)]),
		(in IfAst e) @safe =>
			jsonObject(alloc, [
				kindField!"if",
				field!"if-kind"(stringOfEnum(e.kind)),
				field!"condition"(jsonOfConditionAst(alloc, ctx, e.condition)),
				field!"first-keyword"(e.firstKeywordPos),
				optionalField!("first-branch", ExprAst*)(e.firstBranch, (in ExprAst* x) =>
					jsonOfExprAst(alloc, ctx, *x)),
				optionalField!("second-keyword", Pos)(e.secondKeywordPos, (in Pos x) => Json(x)),
				optionalField!("second-branch", ExprAst*)(e.secondBranch, (in ExprAst* x) =>
					jsonOfExprAst(alloc, ctx, *x))]),
		(in InterpolatedAst x) =>
			jsonObject(alloc, [
				kindField!"interpolated",
				field!"parts"(jsonOfExprAsts(alloc, ctx, x.parts))]),
		(in LambdaAst x) =>
			jsonObject(alloc, [
				kindField!"lambda",
				field!"param"(jsonOfDestructureAst(alloc, ctx, x.param)),
				field!"body"(jsonOfExprAst(alloc, ctx, x.body_))]),
		(in LetAst a) =>
			jsonObject(alloc, [
				kindField!"let",
				field!"destructure"(jsonOfDestructureAst(alloc, ctx, a.destructure)),
				field!"value"(jsonOfExprAst(alloc, ctx, a.value)),
				field!"then"(jsonOfExprAst(alloc, ctx, a.then))]),
		(in LiteralFloatAst a) =>
			jsonOfLiteralFloatAst(alloc, a),
		(in LiteralIntegral a) =>
			jsonOfLiteralIntegral(alloc, a),
		(in LiteralStringAst a) =>
			jsonOfLiteralStringAst(alloc, a),
		(in LoopAst a) =>
			jsonObject(alloc, [
				kindField!"loop",
				field!"body"(jsonOfExprAst(alloc, ctx, a.body_))]),
		(in LoopBreakAst e) =>
			jsonObject(alloc, [
				kindField!"break",
				field!"value"(jsonOfExprAst(alloc, ctx, e.value))]),
		(in LoopContinueAst _) =>
			jsonObject(alloc, [kindField!"continue"]),
		(in LoopWhileOrUntilAst e) =>
			jsonObject(alloc, [
				kindField(e.isUntil ? "until" : "while"),
				field!"condition"(jsonOfConditionAst(alloc, ctx, e.condition)),
				field!"body"(jsonOfExprAst(alloc, ctx, e.body_)),
				field!"after"(jsonOfExprAst(alloc, ctx, e.after))]),
		(in MatchAst x) =>
			jsonObject(alloc, [
				kindField!"match",
				field!"matched"(jsonOfExprAst(alloc, ctx, *x.matched)),
				field!"cases"(jsonOfCaseAsts(alloc, ctx, x.cases)),
				optionalField!("else", MatchElseAst*)(x.else_, (in MatchElseAst* y) =>
					jsonObject(alloc, [
						field!"keyword-pos"(y.keywordPos),
						field!"expr"(jsonOfExprAst(alloc, ctx, y.expr))]))]),
		(in ParenthesizedAst x) =>
			jsonObject(alloc, [kindField!"paren", field!"inner"(jsonOfExprAst(alloc, ctx, x.inner))]),
		(in PtrAst a) =>
			jsonObject(alloc, [
				kindField!"pointer-to",
				field!"pointee"(jsonOfExprAst(alloc, ctx, a.inner))]),
		(in SeqAst a) =>
			jsonObject(alloc, [
				kindField!"seq",
				field!"first"(jsonOfExprAst(alloc, ctx, a.first)),
				field!"then"(jsonOfExprAst(alloc, ctx, a.then))]),
		(in SharedAst a) =>
			jsonObject(alloc, [
				kindField!"shared",
				field!"inner"(jsonOfExprAst(alloc, ctx, a.inner))]),
		(in ThrowAst x) =>
			jsonObject(alloc, [
				kindField!"throw",
				field!"thrown"(jsonOfExprAst(alloc, ctx, x.thrown))]),
		(in TrustedAst x) =>
			jsonObject(alloc, [
				kindField!"trusted",
				field!"inner"(jsonOfExprAst(alloc, ctx, x.inner))]),
		(in TryAst x) =>
			jsonObject(alloc, [
				kindField!"try",
				field!"tried"(jsonOfExprAst(alloc, ctx, *x.tried)),
				field!"catches"(jsonOfCaseAsts(alloc, ctx, x.catches))]),
		(in TryLetAst x) =>
			jsonObject(alloc, [
				kindField!"try-let",
				field!"destructure"(jsonOfDestructureAst(alloc, ctx, x.destructure)),
				field!"value"(jsonOfExprAst(alloc, ctx, x.value)),
				field!"catch-member"(jsonOfCaseMemberAst(alloc, ctx, x.catchMember)),
				field!"catch"(jsonOfExprAst(alloc, ctx, x.catch_)),
				field!"then"(jsonOfExprAst(alloc, ctx, x.then))]),
		(in TypedAst x) =>
			jsonObject(alloc, [
				kindField!"typed",
				field!"expr"(jsonOfExprAst(alloc, ctx, x.expr)),
				field!"type"(jsonOfTypeAst(alloc, ctx, x.type))]),
		(in WithAst x) =>
			jsonObject(alloc, [
				kindField!"with",
				field!"param"(jsonOfDestructureAst(alloc, ctx, x.param)),
				field!"arg"(jsonOfExprAst(alloc, ctx, x.arg)),
				field!"body"(jsonOfExprAst(alloc, ctx, x.body_))]));

Json jsonOfConditionAst(ref Alloc alloc, in Ctx ctx, in ConditionAst a) =>
	a.matchIn!Json(
		(in ExprAst x) =>
			jsonOfExprAst(alloc, ctx, x),
		(in ConditionAst.UnpackOption x) =>
			jsonObject(alloc, [
				field!"destructure"(jsonOfDestructureAst(alloc, ctx, x.destructure)),
				field!"option"(jsonOfExprAst(alloc, ctx, *x.option))]));

Json jsonOfCaseAsts(ref Alloc alloc, in Ctx ctx, in CaseAst[] a) =>
	jsonList!CaseAst(alloc, a, (in CaseAst x) =>
		jsonOfCaseAst(alloc, ctx, x));

Json jsonOfCaseAst(ref Alloc alloc, in Ctx ctx, in CaseAst a) =>
	jsonObject(alloc, [
		field!"keyword-pos"(a.keywordPos),
		field!"member"(jsonOfCaseMemberAst(alloc, ctx, a.member)),
		field!"then"(jsonOfExprAst(alloc, ctx, a.then))]);

Json jsonOfCaseMemberAst(ref Alloc alloc, in Ctx ctx, in CaseMemberAst a) =>
	a.matchIn!Json(
		(in CaseMemberAst.Name x) =>
			jsonObject(alloc, [
				field!"name"(jsonOfNameAndRange(alloc, ctx, x.name)),
				optionalField!("destructure", DestructureAst)(x.destructure, (in DestructureAst y) =>
					jsonOfDestructureAst(alloc, ctx, y))]),
		(in LiteralIntegralAndRange x) =>
			jsonObject(alloc, [
				kindField!"integral",
				field!"value"(jsonOfLiteralIntegralAndRange(alloc, ctx, x))]),
		(in CaseMemberAst.String x) =>
			jsonObject(alloc, [
				kindField!"string",
				field!"range"(jsonOfRange(alloc, ctx, x.range)),
				field!"value"(jsonString(alloc, x.value))]),
		(in CaseMemberAst.Bogus x) =>
			jsonObject(alloc, [
				kindField!"bogus",
				field!"range"(jsonOfRange(alloc, ctx, x.range))]));

Json jsonOfVarDeclAst(ref Alloc alloc, in Ctx ctx, in VarDeclAst a) =>
	jsonObject(alloc, [
		field!"range"(jsonOfRange(alloc, ctx, a.range)),
		docCommentField(alloc, ctx, a.docComment),
		visibilityField(a.visibility_),
		field!"name"(jsonOfNameAndRange(alloc, ctx, a.name)),
		maybeTypeParams(alloc, ctx, a.typeParams),
		field!"keyword-pos"(a.keywordPos),
		field!"kind"(stringOfEnum(a.kind)),
		field!"type"(jsonOfTypeAst(alloc, ctx, a.type)),
		field!"modifiers"(jsonOfModifiers(alloc, ctx, a.modifiers))]);
