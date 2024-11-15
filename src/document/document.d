module document.document;

@safe @nogc pure nothrow:

import frontend.showModel : ShowModelCtx;
import frontend.storage : FileContentGetters;
import model.ast : NameAndRange;
import model.concreteModel : TypeSize;
import model.model :
	BuiltinType,
	Destructure,
	DocComment,
	EnumOrFlagsMember,
	FunBody,
	FunDecl,
	Module,
	moduleAtUri,
	NameReferents,
	Params,
	paramsArray,
	Program,
	Purity,
	RecordField,
	SpecDecl,
	Signature,
	SpecInst,
	StructAlias,
	StructBody,
	StructDecl,
	StructInst,
	StructOrAlias,
	Type,
	TypeParamIndex,
	TypeParams,
	VarDecl,
	VariantAndMethodImpls,
	VarKind,
	Visibility;
import util.alloc.alloc : Alloc;
import util.col.array : exists, indexOf, isEmpty, map, mapOp;
import util.col.arrayBuilder : arrayBuilderSort, buildArray, Builder;
import util.comparison : Comparison;
import util.json :
	field,
	Json,
	jsonObject,
	optionalArrayField,
	optionalFlagField,
	optionalField,
	jsonList,
	jsonString,
	kindField;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : compareUriAndRange, UriAndRange;
import util.string : isWhitespace;
import util.symbol : Symbol, symbol;
import util.uri : stringOfUri, Uri;
import util.util : ptrTrustMe, stringOfEnum;
import util.writer : makeStringWithWriter, Writer;

Json documentModules(ref Alloc alloc, in Program program, in ShowModelCtx showCtx, in Uri[] moduleUris) {
	Ctx ctx = Ctx(ptrTrustMe(alloc), showCtx.fileContentGetters);
	return jsonObject(alloc, [
		field!"modules"(jsonList!Uri(alloc, moduleUris, (in Uri x) =>
			documentModule(ctx, program, *moduleAtUri(program, x))))]);
}

private:

struct Ctx {
	@safe @nogc pure nothrow:
	Alloc* allocPtr;
	FileContentGetters fileContentGetters;

	ref Alloc alloc() =>
		*allocPtr;
}

Json documentModule(ref Ctx ctx, in Program program, in Module a) {
	DocExport[] exports = buildArray!DocExport(ctx.alloc, (scope ref Builder!DocExport res) {
		// Use 'exports' instead of direct module members so it accounts for re-exports
		foreach (NameReferents referents; a.exports) {
			if (has(referents.structOrAlias) && force(referents.structOrAlias).visibility == Visibility.public_)
				res ~= documentStructOrAlias(ctx, force(referents.structOrAlias));
			if (has(referents.spec) && force(referents.spec).visibility == Visibility.public_)
				res ~= documentSpec(ctx, *force(referents.spec));
			foreach (FunDecl* fun; referents.funs)
				if (fun.visibility == Visibility.public_) {
					if (fun.isGenerated) {
						if (fun.body_.isA!(FunBody.VarGet))
							res ~= documentVarDecl(ctx, *fun.body_.as!(FunBody.VarGet).var);
					} else
						res ~= documentFun(ctx, *fun);
				}
		}
		arrayBuilderSort!(DocExport, compareDocExport)(res);
	});
	return jsonObject(ctx.alloc, [
		field!"uri"(stringOfUri(ctx.alloc, a.uri)),
		docCommentField(ctx, a.uri, a.docComment),
		field!"exports"(jsonList!DocExport(ctx.alloc, exports, (in DocExport x) => x.json))]);
}

immutable struct DocExport {
	UriAndRange range;
	Json json;
}
Comparison compareDocExport(in DocExport a, in DocExport b) =>
	compareUriAndRange(a.range, b.range);

DocExport documentExport(
	ref Ctx ctx,
	UriAndRange range,
	Symbol name,
	in DocComment docComment,
	in TypeParams typeParams,
	Json value,
) =>
	DocExport(range, jsonObject(ctx.alloc, [
		field!"name"(name),
		docCommentField(ctx, range.uri, docComment),
		optionalArrayField!("type-params", NameAndRange)(ctx.alloc, typeParams, (in NameAndRange x) =>
			jsonObject(ctx.alloc, [field!"name"(x.name)])),
		field!"value"(value)]));

Opt!(Json.ObjectField) docCommentField(ref Ctx ctx, Uri uri, in DocComment docComment) =>
	optionalField!"doc"(!docComment.isEmpty, () =>
		jsonString(docCommentString(ctx.alloc, ctx.fileContentGetters, uri, docComment)));

public string docCommentString(ref Alloc alloc, in FileContentGetters fileContents, Uri uri, in DocComment a) =>
	a.isEmpty
		? ""
		: stripDocComment(alloc, fileContents[UriAndRange(uri, force(a.ast.range))]);
string stripDocComment(ref Alloc alloc, string a) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		while (!isEmpty(a)) {
			while (!isEmpty(a) && isWhitespaceOrBar(a[0]))
				a = a[1 .. $];
			while (!isEmpty(a) && a[0] != '\n') {
				writer ~= a[0];
				a = a[1 .. $];
			}
			if (!isEmpty(a) && a[0] == '\n') {
				writer ~= '\n';
				a = a[1 .. $];
			}
		}
	});
bool isWhitespaceOrBar(char a) =>
	isWhitespace(a) || a == '|';

DocExport documentStructOrAlias(ref Ctx ctx, in StructOrAlias a) =>
	a.matchIn!DocExport(
		(in StructAlias x) =>
			documentStructAlias(ctx, x),
		(in StructDecl x) =>
			documentStructDecl(ctx, x));

DocExport documentStructAlias(ref Ctx ctx, in StructAlias a) =>
	documentExport(ctx, a.range, a.name, a.docComment, a.typeParams, jsonObject(ctx.alloc, [
		kindField!"alias",
		field!"target"(documentStructInst(ctx, a.typeParams, *a.target))]));

DocExport documentStructDecl(ref Ctx ctx, in StructDecl a) {
	Opt!(Json.ObjectField) variantsField = optionalArrayField!("variants", VariantAndMethodImpls)(
		ctx.alloc, a.variants, (in VariantAndMethodImpls x) =>
			documentStructInst(ctx, a.typeParams, *x.variant));
	return documentExport(ctx, a.range, a.name, a.docComment, a.typeParams, a.body_.matchIn!Json(
		(in StructBody.Bogus) =>
			assert(false),
		(in BuiltinType _) =>
			jsonObject(ctx.alloc, [kindField!"builtin", variantsField]),
		(in StructBody.Enum x) =>
			jsonObject(ctx.alloc, [
				kindField!"enum",
				field!"members"(jsonOfEnumMembers(ctx.alloc, x.members)), variantsField]),
		(in StructBody.Extern x) =>
			jsonObject(ctx.alloc, [
				kindField!"extern",
				optionalField!("size", TypeSize)(x.size, (TypeSize size) =>
					jsonObject(ctx.alloc, [
						field!"size"(size.sizeBytes),
						field!"alignment"(size.alignmentBytes)])),
				variantsField]),
		(in StructBody.Flags x) =>
			jsonObject(ctx.alloc, [
				kindField!"flags",
				field!"members"(jsonOfEnumMembers(ctx.alloc, x.members)), variantsField]),
		(in StructBody.Record x) =>
			documentRecord(ctx, a, x, variantsField),
		(in StructBody.Variant x) =>
			documentVariant(ctx, a, x, variantsField)));
}

Json jsonOfEnumMembers(ref Alloc alloc, in EnumOrFlagsMember[] members) =>
	jsonList!EnumOrFlagsMember(alloc, members, (in EnumOrFlagsMember member) =>
		jsonString(member.name));

Json documentRecord(ref Ctx ctx, in StructDecl decl, in StructBody.Record a, Opt!(Json.ObjectField) variantsField) =>
	jsonObject(ctx.alloc, [
		kindField!"record",
		maybePurity(ctx.alloc, decl),
		optionalFlagField!"has-non-public-fields"(hasNonPublicFields(a)),
		optionalFlagField!"nominal"(a.flags.nominal),
		field!"fields"(jsonList(
			mapOp!(Json, RecordField)(ctx.alloc, a.fields, (ref RecordField field) =>
				documentRecordField(ctx, decl.typeParams, field)))),
		variantsField]);

Opt!(Json.ObjectField) maybePurity(ref Alloc alloc, in StructDecl decl) =>
	optionalField!"purity"(decl.purity != Purity.data, () => jsonString(stringOfEnum(decl.purity)));

bool hasNonPublicFields(in StructBody.Record a) =>
	exists!RecordField(a.fields, (in RecordField x) {
		final switch (x.visibility) {
			case Visibility.private_:
			case Visibility.internal:
				return true;
			case Visibility.public_:
				return false;
		}
	});

Json documentVariant(
	ref Ctx ctx,
	in StructDecl decl,
	in StructBody.Variant a,
	Opt!(Json.ObjectField) variantsField,
) =>
	jsonObject(ctx.alloc, [
		kindField!"variant",
		maybePurity(ctx.alloc, decl),
		variantsField,
		field!"methods"(documentSignatures(ctx, decl.typeParams, a.methods))]);

Opt!Json documentRecordField(ref Ctx ctx, in TypeParams typeParams, in RecordField a) {
	final switch (a.visibility) {
		case Visibility.private_:
		case Visibility.internal:
			return none!Json;
		case Visibility.public_:
			return some(jsonObject(ctx.alloc, [
				field!"name"(a.name),
				field!"type"(documentTypeRef(ctx, typeParams, a.type)),
				optionalFlagField!"mut"(has(a.mutability) && force(a.mutability) == Visibility.public_)]));
	}
}

DocExport documentSpec(ref Ctx ctx, in SpecDecl a) =>
	documentExport(ctx, a.range, a.name, a.docComment, a.typeParams, jsonObject(ctx.alloc, [
		kindField!"spec",
		optionalFlagField!"builtin"(has(a.builtin)),
		field!"parents"(jsonList(map(ctx.alloc, a.parents, (ref immutable SpecInst* x) =>
			documentSpecInst(ctx, a.typeParams, *x)))),
		field!"sigs"(documentSignatures(ctx, a.typeParams, a.sigs))]));

Json documentSignatures(ref Ctx ctx, in TypeParams typeParams, in Signature[] a) =>
	jsonList!Signature(ctx.alloc, a, (in Signature x) =>
			documentSignature(ctx, typeParams, x));

Json documentSignature(ref Ctx ctx, in TypeParams typeParams, in Signature a) =>
	jsonObject(ctx.alloc, [
		docCommentField(ctx, a.moduleUri, a.docComment),
		field!"container"(a.container.name),
		field!"name"(a.name),
		field!"return-type"(documentTypeRef(ctx, typeParams, a.returnType)),
		field!"params"(documentParamDestructures(ctx, typeParams, a.params))]);

DocExport documentVarDecl(ref Ctx ctx, in VarDecl a) =>
	documentExport(ctx, a.range, a.name, a.docComment, a.typeParams, jsonObject(ctx.alloc, [
		kindField(stringOfVarDeclKind(a.kind)),
		field!"type"(documentTypeRef(ctx, a.typeParams, a.type))]));

string stringOfVarDeclKind(VarKind kind) {
	final switch (kind) {
		case VarKind.global:
			return "global";
		case VarKind.threadLocal:
			return "thread-local";
	}
}

DocExport documentFun(ref Ctx ctx, in FunDecl a) =>
	documentExport(ctx, a.range, a.name, a.docComment, a.typeParams, jsonObject(ctx.alloc, [
		kindField!"fun",
		field!"return-type"(documentTypeRef(ctx, a.typeParams, a.returnType)),
		documentParams(ctx, a.typeParams, a.params),
		optionalFlagField!"variadic"(a.isVariadic),
		optionalArrayField!"specs"(documentSpecs(ctx, a))]));

Json[] documentSpecs(ref Ctx ctx, in FunDecl a) =>
	buildArray!Json(ctx.alloc, (scope ref Builder!Json res) {
		if (a.isBare)
			res ~= jsonOfSpecialSpec(ctx, symbol!"bare");
		if (a.isSummon)
			res ~= jsonOfSpecialSpec(ctx, symbol!"summon");
		if (a.isUnsafe)
			res ~= jsonOfSpecialSpec(ctx, symbol!"unsafe");
		foreach (SpecInst* spec; a.specs)
			res ~= documentSpecInst(ctx, a.typeParams, *spec);
	});

Json jsonOfSpecialSpec(ref Ctx ctx, Symbol name) =>
	jsonObject(ctx.alloc, [kindField!"special", field!"name"(name)]);

Opt!(Json.ObjectField) documentParams(ref Ctx ctx, in TypeParams typeParams, in Params params) =>
	field!"params"(documentParamDestructures(ctx, typeParams, paramsArray(params)));

Json documentParamDestructures(ref Ctx ctx, in TypeParams typeParams, in Destructure[] a) =>
	jsonList!Destructure(ctx.alloc, a, (in Destructure x) =>
		documentParam(ctx, typeParams, x));

Json documentParam(ref Ctx ctx, in TypeParams typeParams, in Destructure a) {
	Opt!Symbol name = a.name;
	return jsonObject(ctx.alloc, [
		field!"name"(has(name) ? force(name) : symbol!"anonymous"),
		field!"type"(documentTypeRef(ctx, typeParams, a.type))]);
}

Json documentTypeRef(ref Ctx ctx, in TypeParams typeParams, in Type a) =>
	a.matchIn!Json(
		(in Type.Bogus) =>
			assert(false),
		(in TypeParamIndex x) =>
			jsonObject(ctx.alloc, [kindField!"type-param", field!"name"(typeParams[x.index].name)]),
		(in StructInst x) =>
			documentStructInst(ctx, typeParams, x));

Json documentSpecInst(ref Ctx ctx, in TypeParams typeParams, in SpecInst a) =>
	documentNameAndTypeArgs(ctx, typeParams, "spec", a.name, a.typeArgs);

Json documentStructInst(ref Ctx ctx, in TypeParams typeParams, in StructInst a) =>
	documentNameAndTypeArgs(ctx, typeParams, "struct", a.decl.name, a.typeArgs);

Json documentNameAndTypeArgs(
	ref Ctx ctx,
	in TypeParams typeParams,
	string nodeType,
	Symbol name,
	in Type[] typeArgs,
) =>
	isEmpty(typeArgs)
		? jsonObject(ctx.alloc, [kindField(nodeType), field!"name"(name)])
		: jsonObject(ctx.alloc, [
			kindField(nodeType),
			field!"name"(name),
			field!"type-args"(jsonList!Type(ctx.alloc, typeArgs, (in Type typeArg) =>
				documentTypeRef(ctx, typeParams, typeArg)))]);

void eachLine(string a, in void delegate(string) @safe @nogc pure nothrow cb) {
	Opt!size_t index = indexOf(a, '\n');
	if (has(index)) {
		cb(a[0..force(index)]);
		eachLine(a[force(index)+1 .. $], cb);
	} else
		cb(a);
}
