module model.model;

// See also frontendUtil.d

@safe @nogc pure nothrow:

import frontend.getDiagnosticSeverity : getDiagnosticSeverity;
import frontend.storage : FileContentGetters, LineAndCharacterGetters, LineAndColumnGetters;
import model.ast :
	AssertOrForbidAst,
	CaseAst,
	CaseMemberAst,
	ConditionAst,
	DestructureAst,
	DocCommentAst,
	EnumOrFlagsMemberAst,
	ExprAst,
	FileAst,
	FunDeclAst,
	IfAst,
	ImportOrExportAst,
	MatchAst,
	ModifierAst,
	NameAndRange,
	RecordFieldAst,
	SpecDeclAst,
	SignatureAst,
	StructAliasAst,
	StructDeclAst,
	TestAst,
	TryAst,
	VarDeclAst;
import model.constant : Constant;
import model.diag : Diag, Diagnostic, isFatal, UriAndDiagnostic;
import model.parseDiag : ParseDiagnostic;
import util.alloc.alloc : Alloc;
import util.col.array :
	arrayOfSingle,
	arraysCorrespond,
	concatenate,
	emptySmallArray,
	every,
	exists,
	first,
	firstPointer,
	firstZipPointerFirst,
	fold,
	isEmpty,
	mustFindPointer,
	mustHaveIndexOfPointer,
	newArray,
	only,
	PtrAndSmallNumber,
	small,
	SmallArray,
	sum;
import util.col.hashTable : existsInHashTable, HashTable, mustGet;
import util.col.map : Map, mustGet;
import util.col.enumMap : EnumMap;
import util.conv : safeToUint, safeToUshort;
import util.integralValues : IntegralValue;
import util.late : Late, lateGet, lateIsSet, lateSet, lateSetOverwrite;
import util.opt : force, has, none, Opt, optEqual, optIf, optOr, optOrDefault, some;
import util.sourceRange : combineRanges, UriAndRange, Pos, Range;
import util.string : SmallString;
import util.symbol : enumOfSymbol, Symbol, symbol, symbolOfEnum;
import util.symbolSet : buildSymbolSet, emptySymbolSet, SymbolSet, symbolSet, SymbolSetBuilder;
import util.union_ : IndexType, TaggedUnion, Union;
import util.uri : RelPath, Uri;
import util.util : enumConvertOrAssert, max, min, optEnumConvert, stringOfEnum;
import versionInfo : OS, VersionFun;

alias Purity = immutable Purity_;
private enum Purity_ : ubyte {
	// sorted best case to worst case
	data,
	shared_,
	mut,
}

bool isPurityCompatible(Purity expected, Purity actual) =>
	actual <= expected;

immutable struct PurityRange {
	Purity bestCase;
	Purity worstCase;
}

private PurityRange combinePurityRange(PurityRange a, PurityRange b) =>
	immutable PurityRange(worsePurity(a.bestCase, b.bestCase), worsePurity(a.worstCase, b.worstCase));

bool isPurityAlwaysCompatible(Purity referencer, PurityRange referenced) =>
	referenced.worstCase <= referencer;
bool isPurityAlwaysCompatible(PurityRange referencer, Purity referenced) =>
	referenced <= referencer.bestCase;

bool isPurityPossiblyCompatible(Purity referencer, PurityRange referenced) =>
	referenced.bestCase <= referencer;

Purity worsePurity(Purity a, Purity b) =>
	max(a, b);

alias TypeParams = SmallArray!NameAndRange;
TypeParams emptyTypeParams() =>
	emptySmallArray!NameAndRange;
alias TypeArgs = SmallArray!Type;
TypeArgs emptyTypeArgs() =>
	emptySmallArray!Type;
alias SpecImpls = SmallArray!Called;
SpecImpls emptySpecImpls() =>
	emptySmallArray!Called;
alias Specs = SmallArray!(immutable SpecInst*);
Specs emptySpecs() =>
	emptySmallArray!(immutable SpecInst*);

// Represent type parameter as the index, so we don't generate different types for every `t list`.
// (These are disambiguated in the type checker using `TypeAndContext`)
immutable struct TypeParamIndex {
	mixin IndexType;
}

immutable struct Type {
	@safe @nogc pure nothrow:
	immutable struct Bogus {}
	mixin TaggedUnion!(Bogus, TypeParamIndex, StructInst*);

	static Type bogus() =>
		Type(Type.Bogus());

	bool isBogus() scope =>
		isA!Bogus;

	bool opEquals(scope Type b) scope =>
		taggedPointerEquals(b);
}

bool isEmptyType(in Type a) =>
	a.isA!(StructInst*) && isEmptyType(*a.as!(StructInst*));
bool isEmptyType(in StructInst a) =>
	isVoid(*a.decl) || isEmptyRecord(*a.decl);
private bool isEmptyRecord(in StructDecl a) =>
	a.body_.isA!(StructBody.Record) && isEmpty(a.body_.as!(StructBody.Record).fields);

bool isArray(in Type a) =>
	isBuiltinType(a, BuiltinType.array);
bool isMutArray(in Type a) =>
	isBuiltinType(a, BuiltinType.mutArray);
bool isMutArray(in StructInst a) =>
	isBuiltinType(a, BuiltinType.mutArray);
bool isMutSlice(in Type a) =>
	isBuiltinType(a, BuiltinType.mutSlice);
bool isArrayOrMutSlice(in StructDecl a) =>
	isBuiltinType(a, BuiltinType.array) || isBuiltinType(a, BuiltinType.mutSlice);

bool isTuple(in CommonTypes commonTypes, in Type a) =>
	a.isA!(StructInst*) && isTuple(commonTypes, a.as!(StructInst*).decl);
bool isTuple(in CommonTypes commonTypes, in StructDecl* a) {
	Opt!(StructDecl*) actual = commonTypes.tuple(a.typeParams.length);
	return has(actual) && force(actual) == a;
}
Opt!(Type[]) asTuple(in CommonTypes commonTypes, Type type) =>
	isTuple(commonTypes, type) ? some!(Type[])(type.as!(StructInst*).typeArgs) : none!(Type[]);

bool isBool(in Type a) =>
	isBuiltinType(a, BuiltinType.bool_);
bool isChar8(in Type a) =>
	isBuiltinType(a, BuiltinType.char8);
bool isChar32(in Type a) =>
	isBuiltinType(a, BuiltinType.char32);
bool isFloat32(in Type a) =>
	isBuiltinType(a, BuiltinType.float32);
bool isFloat64(in Type a) =>
	isBuiltinType(a, BuiltinType.float64);
bool isFuture(in Type a) =>
	isBuiltinType(a, BuiltinType.future);
bool isFuture(in StructInst a) =>
	isBuiltinType(a, BuiltinType.future);
bool isInt8(in Type a) =>
	isBuiltinType(a, BuiltinType.int8);
bool isInt16(in Type a) =>
	isBuiltinType(a, BuiltinType.int16);
bool isInt32(in Type a) =>
	isBuiltinType(a, BuiltinType.int32);
bool isInt64(in Type a) =>
	isBuiltinType(a, BuiltinType.int64);
bool isJsAny(in Type a) =>
	isBuiltinType(a, BuiltinType.jsAny);
bool isNat8(in Type a) =>
	isBuiltinType(a, BuiltinType.nat8);
bool isNat16(in Type a) =>
	isBuiltinType(a, BuiltinType.nat16);
bool isNat32(in Type a) =>
	isBuiltinType(a, BuiltinType.nat32);
bool isNat64(in Type a) =>
	isBuiltinType(a, BuiltinType.nat64);
bool isString(in Type a) =>
	isBuiltinType(a, BuiltinType.string_);
bool isString(in StructDecl a) =>
	isBuiltinType(a, BuiltinType.string_);
bool isSymbol(in Type a) =>
	isBuiltinType(a, BuiltinType.symbol);
bool isVoid(in Type a) =>
	isBuiltinType(a, BuiltinType.void_);
bool isVoid(in StructDecl a) =>
	isBuiltinType(a, BuiltinType.void_);

Opt!IntegralType asIntegralType(in Type a) {
	Opt!BuiltinType builtin = asBuiltinType(a);
	return has(builtin) ? optEnumConvert!IntegralType(force(builtin)) : none!IntegralType;
}

private bool isBuiltinType(in Type a, BuiltinType builtin) =>
	a.isA!(StructInst*) && isBuiltinType(*a.as!(StructInst*), builtin);
private bool isBuiltinType(in StructInst a, BuiltinType builtin) =>
	isBuiltinType(*a.decl, builtin);
bool isBuiltinType(in StructDecl a) =>
	a.body_.isA!BuiltinType;
private bool isBuiltinType(in StructDecl a, BuiltinType builtin) =>
	a.body_.isA!BuiltinType && a.body_.as!BuiltinType == builtin;
private Opt!BuiltinType asBuiltinType(in Type a) =>
	optIf(a.isA!(StructInst*) && a.as!(StructInst*).decl.body_.isA!BuiltinType, () =>
		a.as!(StructInst*).decl.body_.as!BuiltinType);

Type arrayElementType(Type type) {
	assert(isArray(type));
	return only(type.as!(StructInst*).typeArgs);
}

Type mustUnwrapOptionType(Type a) {
	assert(isOptionType(a));
	return only(a.as!(StructInst*).typeArgs);
}

bool isOptionType(in Type a) =>
	isBuiltinType(a, BuiltinType.option);
bool isOptionType(in StructDecl* a) =>
	isBuiltinType(*a, BuiltinType.option);

bool isFunPointer(in Type a) =>
	isBuiltinType(a, BuiltinType.funPointer);
bool isLambdaType(in Type a) =>
	a.isA!(StructInst*) && isLambdaType(*a.as!(StructInst*).decl);
bool isLambdaType(in StructDecl a) =>
	a.body_.isA!BuiltinType && isLambda(a.body_.as!BuiltinType);

bool isPointerConstOrMut(in Type a) =>
	isPointerConst(a) || isPointerMut(a);
bool isPointerConstOrMut(in StructDecl a) =>
	isBuiltinType(a, BuiltinType.pointerConst) || isBuiltinType(a, BuiltinType.pointerMut);
bool isPointerConst(in Type a) =>
	isBuiltinType(a, BuiltinType.pointerConst);
bool isPointerMut(in Type a) =>
	isBuiltinType(a, BuiltinType.pointerMut);
Type pointeeType(in Type a) {
	assert(isPointerConstOrMut(a));
	return only(a.as!(StructInst*).typeArgs);
}

PurityRange purityRange(Type a) =>
	a.matchIn!PurityRange(
		(in Type.Bogus) =>
			PurityRange(Purity.data, Purity.data),
		(in TypeParamIndex _) =>
			PurityRange(Purity.data, Purity.mut),
		(in StructInst x) =>
			x.purityRange);

Purity bestCasePurity(Type a) =>
	purityRange(a).bestCase;

LinkageRange linkageRange(Type a) =>
	a.matchIn!LinkageRange(
		(in Type.Bogus) =>
			LinkageRange(Linkage.extern_, Linkage.extern_),
		(in TypeParamIndex _) =>
			LinkageRange(Linkage.internal, Linkage.extern_),
		(in StructInst x) =>
			x.linkageRange);

immutable struct Params {
	@safe @nogc pure nothrow:

	immutable struct Varargs {
		Destructure param;
		Type elementType;
	}

	mixin TaggedUnion!(SmallArray!Destructure, Varargs*);

	static Params empty() =>
		Params(emptySmallArray!Destructure);

	Arity arity() scope =>
		matchIn!Arity(
			(in Destructure[] params) =>
				Arity(safeToUint(params.length)),
			(in Params.Varargs) =>
				Arity(Arity.Varargs()));
}
bool isEmpty(in Params a) =>
	isEmpty(a.arity);

SmallArray!Destructure paramsArray(return scope Params a) =>
	a.matchWithPointers!(SmallArray!Destructure)(
		(Destructure[] x) =>
			small!Destructure(x),
		(Params.Varargs* x) =>
			small!Destructure(arrayOfSingle(&x.param)));

Destructure[] assertNonVariadic(Params a) =>
	a.as!(Destructure[]);

immutable struct Arity {
	@safe @nogc pure nothrow:
	immutable struct Varargs {}
	mixin TaggedUnion!(immutable uint, Varargs);

	uint countParamDecls() scope =>
		matchIn!uint(
			(in uint x) => x,
			(in Varargs) => 1);

	bool isVariadic() scope =>
		isA!Varargs;
}
bool isEmpty(in Arity a) =>
	a.match!bool(
		(uint nParams) =>
			nParams == 0,
		(Arity.Varargs) =>
			false);

bool arityMatches(in Arity sigArity, size_t nArgs) =>
	sigArity.match!bool(
		(uint nParams) =>
			nParams == nArgs,
		(Arity.Varargs) =>
			true);

immutable struct SignatureContainer {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(SpecDecl*, StructDecl*);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in SpecDecl x) =>
				x.moduleUri,
			(in StructDecl x) =>
				x.moduleUri);

	Symbol name() scope =>
		matchIn!Symbol(
			(in SpecDecl x) =>
				x.name,
			(in StructDecl x) =>
				x.name);

	TypeParams typeParams() =>
		match!TypeParams(
			(ref SpecDecl x) =>
				x.typeParams,
			(ref StructDecl x) =>
				x.typeParams);
}
TypeContainer asTypeContainer(SignatureContainer a) =>
	a.matchWithPointers!TypeContainer(
		(SpecDecl* x) =>
			TypeContainer(x),
		(StructDecl* x) =>
			TypeContainer(x));

// Function signature without a body. Used in a spec or variant.
immutable struct Signature {
	@safe @nogc pure nothrow:

	SignatureContainer container;
	SignatureAst* ast;
	Type returnType;
	SmallArray!Destructure params;
	Late!DocCommentReferences lateDocCommentReferences;

	Symbol name() scope =>
		ast.name;
	Uri moduleUri() scope =>
		container.moduleUri;
	UriAndRange range() scope =>
		UriAndRange(moduleUri, ast.range);
	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, ast.nameAndRange.range);
	DocCommentAst docCommentAst() scope =>
		ast.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}
}
size_t signatureIndex(in Signature* a) scope =>
	a.container.matchIn!size_t(
		(in SpecDecl spec) =>
			mustHaveIndexOfPointer(spec.sigs, a),
		(in StructDecl variant) =>
			mustHaveIndexOfPointer(variant.body_.as!(StructBody.SumType).methods, a));

immutable struct TypeParamsAndSig {
	TypeParams typeParams;
	Type returnType;
	ParamsShort params;
	uint countSpecs;
}
immutable struct ParamsShort {
	immutable struct Variadic { ParamShort param; Type elementType; }
	mixin TaggedUnion!(SmallArray!ParamShort, Variadic*);
}
immutable struct ParamShort {
	Symbol name;
	Type type;
}

immutable struct RecordFieldSource {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(DestructureAst.Single*, RecordFieldAst*);

	DocCommentAst docComment() scope =>
		match!DocCommentAst(
			(ref DestructureAst.Single) =>
				DocCommentAst.empty,
			(ref RecordFieldAst x) =>
				x.docComment);

	Symbol name() scope =>
		matchIn!Symbol(
			(in DestructureAst.Single x) =>
				x.name.name,
			(in RecordFieldAst x) =>
				x.name.name);

	Range range() scope =>
		matchIn!Range(
			(in DestructureAst.Single x) =>
				x.range,
			(in RecordFieldAst x) =>
				x.range);

	Range nameRange() scope =>
		matchIn!Range(
			(in DestructureAst.Single x) =>
				x.nameRange,
			(in RecordFieldAst x) =>
				x.nameRange);
}

immutable struct RecordField {
	@safe @nogc pure nothrow:

	RecordFieldSource source;
	StructDecl* containingRecord;
	Visibility visibility;
	Opt!Visibility mutability;
	Type type;
	private Late!DocCommentReferences lateDocCommentReferences;

	Uri moduleUri() scope =>
		containingRecord.moduleUri;
	Symbol name() scope =>
		source.name;
	Range range() scope =>
		source.range;
	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, source.nameRange);

	DocCommentAst docCommentAst() return scope =>
		source.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}
}

alias ByValOrRef = immutable ByValOrRef_;
private enum ByValOrRef_ : ubyte {
	byVal,
	byRef,
}

immutable struct RecordFlags {
	Visibility newVisibility;
	bool nominal;
	bool packed;
	Opt!ByValOrRef forcedByValOrRef;
}
static assert(RecordFlags.sizeof == uint.sizeof);

immutable struct EnumMemberSource {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(EnumOrFlagsMemberAst*, DestructureAst.Single*);

	DocCommentAst docComment() return scope =>
		match!DocCommentAst(
			(ref EnumOrFlagsMemberAst x) =>
				x.docComment,
			(ref DestructureAst.Single x) =>
				DocCommentAst.empty);
	Symbol name() scope =>
		matchIn!Symbol(
			(in EnumOrFlagsMemberAst x) => x.name,
			(in DestructureAst.Single x) => x.name.name);
	Range range() scope =>
		matchIn!Range(
			(in EnumOrFlagsMemberAst x) => x.range,
			(in DestructureAst.Single x) => x.range);
	Range nameRange() scope =>
		matchIn!Range(
			(in EnumOrFlagsMemberAst x) => x.nameRange,
			(in DestructureAst.Single x) => x.nameRange);
}

alias EnumMember = EnumOrFlagsMember;
immutable struct EnumOrFlagsMember {
	@safe @nogc pure nothrow:

	EnumMemberSource source;
	StructDecl* containingEnum;
	IntegralValue value;
	private Late!DocCommentReferences lateDocCommentReferences;

	DocCommentAst docCommentAst() return scope =>
		source.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	size_t memberIndex() =>
		mustHaveIndexOfPointer(containingEnum.body_.as!(StructBody.Enum*).members, &this);
	Uri moduleUri() scope =>
		containingEnum.moduleUri;
	Visibility visibility() scope =>
		containingEnum.visibility;
	Symbol name() scope =>
		source.name;
	Range range() scope =>
		source.range;
	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, source.nameRange);
}

immutable struct StructBody {
	immutable struct Bogus {}
	immutable struct Enum {
		IntegralType storage;
		SmallArray!EnumOrFlagsMember members;
		HashTable!(EnumOrFlagsMember*, Symbol, nameOfEnumOrFlagsMember) membersByName;
	}
	immutable struct Extern {
		Opt!TypeSize size;
	}
	immutable struct Flags {
		IntegralType storage;
		SmallArray!EnumOrFlagsMember members;
	}
	immutable struct Record {
		RecordFlags flags;
		SmallArray!RecordField fields;
	}
	// 'interface', 'union', or 'variant'
	immutable struct SumType {
		@safe @nogc pure nothrow:

		SumTypeKind kind;
		immutable struct MembersAndMethods {
			SmallArray!SumTypeMemberAndMethodImpls listedMembers; // There may be other members not in this list
			SmallArray!Signature methods;
		}
		private MembersAndMethods* membersAndMethods;

		SmallArray!SumTypeMemberAndMethodImpls listedMembers() return scope =>
			membersAndMethods.listedMembers;
		SmallArray!Signature methods() return scope =>
			membersAndMethods.methods;
	}

	mixin .Union!(Bogus, BuiltinType, Enum*, Extern, Flags, Record, SumType);
}
static assert(StructBody.sizeof == StructBody.Record.sizeof + size_t.sizeof);

SumTypeMemberAndMethodImpls[] asUnion(ref StructBody a) =>
	asUnion(a.as!(StructBody.SumType));
SumTypeMemberAndMethodImpls[] asUnion(ref StructBody.SumType a) {
	assert(a.kind == SumTypeKind.union_);
	return a.listedMembers;
}

Symbol nameOfEnumOrFlagsMember(in EnumOrFlagsMember* a) =>
	a.name;

IntegralValue getAllFlagsValue(in StructBody.Flags body_) =>
	fold!(IntegralValue, EnumOrFlagsMember)(
		IntegralValue(0),
		body_.members,
		(IntegralValue a, in EnumOrFlagsMember b) =>
			a | b.value);

enum SumTypeKind { interface_, union_, variant }

enum BuiltinType {
	array,
	bool_,
	catchPoint,
	char8,
	char32,
	float32,
	float64,
	funPointer,
	future,
	int8,
	int16,
	int32,
	int64,
	jsAny,
	lambdaData,
	lambdaMut,
	lambdaShared,
	mutArray,
	mutSlice,
	nat8,
	nat16,
	nat32,
	nat64,
	option,
	pointerConst,
	pointerMut,
	string_,
	symbol,
	void_,
}
bool isCharOrIntegral(BuiltinType a) {
	final switch (a) {
		case BuiltinType.char8:
		case BuiltinType.char32:
		case BuiltinType.int8:
		case BuiltinType.int16:
		case BuiltinType.int32:
		case BuiltinType.int64:
		case BuiltinType.nat8:
		case BuiltinType.nat16:
		case BuiltinType.nat32:
		case BuiltinType.nat64:
			return true;
		case BuiltinType.array:
		case BuiltinType.bool_:
		case BuiltinType.catchPoint:
		case BuiltinType.float32:
		case BuiltinType.float64:
		case BuiltinType.future:
		case BuiltinType.funPointer:
		case BuiltinType.jsAny:
		case BuiltinType.lambdaData:
		case BuiltinType.lambdaShared:
		case BuiltinType.lambdaMut:
		case BuiltinType.mutArray:
		case BuiltinType.mutSlice:
		case BuiltinType.option:
		case BuiltinType.pointerConst:
		case BuiltinType.pointerMut:
		case BuiltinType.string_:
		case BuiltinType.symbol:
		case BuiltinType.void_:
			return false;
	}
}
bool isLambda(BuiltinType a) {
	switch (a) {
		case BuiltinType.lambdaData:
		case BuiltinType.lambdaMut:
		case BuiltinType.lambdaShared:
			return true;
		default:
			return false;
	}
}

immutable struct TypeSize {
	uint sizeBytes;
	uint alignmentBytes;
}

immutable struct StructAlias {
	@safe @nogc pure nothrow:

	StructAliasAst* ast;
	Uri moduleUri;
	Visibility visibility;
	private Late!DocCommentReferences lateDocCommentReferences;
	private Late!(StructInst*) target_;

	DocCommentAst docCommentAst() return scope =>
		ast.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);

	Symbol name() scope =>
		ast.name.name;
	TypeParams typeParams() return scope =>
		emptyTypeParams;

	UriAndRange range() scope =>
		UriAndRange(moduleUri, ast.range);
	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, ast.nameRange);

	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	StructInst* target() return scope =>
		lateGet(target_);
	void target(StructInst* value) {
		lateSet(target_, value);
	}
}

// sorted least strict to most strict
enum Linkage : ubyte { internal, extern_ }

// Range of possible linkage
private immutable struct LinkageRange {
	Linkage leastStrict;
	Linkage mostStrict;
}

private LinkageRange combineLinkageRange(LinkageRange referencer, LinkageRange referenced) =>
	LinkageRange(
		lessStrictLinkage(referencer.leastStrict, referenced.leastStrict),
		lessStrictLinkage(referencer.mostStrict, referenced.mostStrict));

private Linkage lessStrictLinkage(Linkage a, Linkage b) =>
	min(a, b);

bool isLinkagePossiblyCompatible(Linkage referencer, LinkageRange referenced) =>
	referenced.mostStrict >= referencer;

bool isLinkageAlwaysCompatible(Linkage referencer, LinkageRange referenced) =>
	referenced.leastStrict >= referencer;

immutable struct StructDecl {
	@safe @nogc pure nothrow:

	StructDeclSource source;
	Uri moduleUri;
	Visibility visibility;
	Opt!SymbolSet extern_;
	bool isSummon;
	// Note: purity on the decl does not take type args into account
	Purity purity;
	bool purityIsForced;
	private Late!DocCommentReferences lateDocCommentReferences;
	private Late!(SmallArray!SumTypeMembership) lateSumTypeMemberships;
	private Late!StructBody lateBody;

	bool bodyIsSet() =>
		lateIsSet(lateBody);

	SymbolSet externSet() =>
		optOrDefault!SymbolSet(extern_, () => emptySymbolSet);
	Linkage linkage() scope =>
		has(extern_) && force(extern_) != symbolSet(symbol!"js") ? Linkage.extern_ : Linkage.internal;

	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	SmallArray!SumTypeMembership sumTypeMemberships() return scope =>
		lateGet(lateSumTypeMemberships);
	void sumTypeMemberships(SmallArray!SumTypeMembership value) =>
		lateSet(lateSumTypeMemberships, value);

	ref StructBody body_() return scope =>
		lateGet(lateBody);

	void body_(StructBody value) {
		lateSet(lateBody, value);
	}

	DocCommentAst docCommentAst() return scope =>
		source.match!DocCommentAst(
			(ref StructDeclAst x) =>
				x.docComment,
			(ref StructDeclSource.Bogus) =>
				DocCommentAst.empty);
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
	TypeParams typeParams() return scope =>
		source.match!TypeParams(
			(ref StructDeclAst x) =>
				x.typeParams,
			(ref StructDeclSource.Bogus x) =>
				x.typeParams);
	Symbol name() scope =>
		source.matchIn!Symbol(
			(in StructDeclAst x) =>
				x.name.name,
			(in StructDeclSource.Bogus x) =>
				x.name);

	UriAndRange range() scope =>
		UriAndRange(moduleUri, source.matchIn!Range(
			(in StructDeclAst x) =>
				x.range,
			(in StructDeclSource.Bogus) =>
				Range.empty));

	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, source.matchIn!Range(
			(in StructDeclAst x) =>
				x.nameRange,
			(in StructDeclSource.Bogus) =>
				Range.empty));

	bool isTemplate() scope =>
		!isEmpty(typeParams);
}

EnumOrFlagsMember[] mustBeEnumOrFlags(in StructDecl a) =>
	a.body_.isA!(StructBody.Enum*) ? a.body_.as!(StructBody.Enum*).members : a.body_.as!(StructBody.Flags).members;

// This is stored on the SumType for the types listed in it.
immutable struct SumTypeMemberAndMethodImpls {
	@safe @nogc pure nothrow:

	StructInst* member;
	private Late!(SmallArray!(Opt!Called)) methodImpls_;

	Symbol name() scope =>
		member.decl.name;
	SmallArray!(Opt!Called) methodImpls() return scope =>
		lateGet(methodImpls_);
	void methodImpls(SmallArray!(Opt!Called) value) =>
		lateSet(methodImpls_, value);
}

// This is stored on a type with a 'case' modifier.
immutable struct SumTypeMembership {
	@safe @nogc pure nothrow:

	ModifierAst.Keyword* ast;
	StructInst* sumType;
	private Late!(SmallArray!(Opt!Called)) methodImpls_;

	SmallArray!(Opt!Called) methodImpls() return scope =>
		lateGet(methodImpls_);
	void methodImpls(SmallArray!(Opt!Called) value) =>
		lateSet(methodImpls_, value);

	ref StructBody.SumType sumTypeBody() return scope =>
		sumType.decl.body_.as!(StructBody.SumType);

	SumTypeKind sumTypeKind() scope =>
		sumTypeBody.kind;
	SmallArray!Signature sumTypeDeclMethods() =>
		sumTypeBody.methods;
}

immutable struct StructDeclSource {
	immutable struct Bogus {
		Symbol name;
		TypeParams typeParams;
	}
	mixin TaggedUnion!(StructDeclAst*, Bogus*);
}

// The StructInst and its contents are allocated using the AllInsts alloc.
immutable struct StructInst {
	@safe @nogc pure nothrow:

	StructDecl* decl;
	TypeArgs typeArgs;

	LinkageRange linkageRange() scope =>
		fold!(LinkageRange, Type)(
			LinkageRange(decl.linkage, decl.linkage),
			typeArgs,
			(LinkageRange cur, in Type typeArg) => combineLinkageRange(cur, .linkageRange(typeArg)));

	PurityRange purityRange() scope =>
		fold!(PurityRange, Type)(
			PurityRange(decl.purity, decl.purity),
			typeArgs,
			(PurityRange cur, in Type typeArg) =>
				combinePurityRange(cur, .purityRange(typeArg)));
}

bool isDefinitelyByRef(in StructInst a) {
	StructBody body_ = a.decl.body_;
	return body_.isA!(StructBody.Record) &&
		optEqual!ByValOrRef(body_.as!(StructBody.Record).flags.forcedByValOrRef, some(ByValOrRef.byRef));
}

immutable struct SpecDeclBody {
	Opt!BuiltinSpec builtin;
	Specs parents;
	SmallArray!Signature sigs;
}

enum BuiltinSpec { data, shared_ }

immutable struct SpecDecl {
	@safe @nogc pure nothrow:

	Uri moduleUri;
	SpecDeclAst* ast;
	Visibility visibility;
	private Late!DocCommentReferences lateDocCommentReferences;
	private Late!SpecDeclBody lateBody;

	DocCommentAst docCommentAst() return scope =>
		ast.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
	Symbol name() scope =>
		ast.name.name;
	TypeParams typeParams() return scope =>
		ast.typeParams;

	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	bool bodyIsSet() scope =>
		lateIsSet(lateBody);
	private ref SpecDeclBody body_() return scope =>
		lateGet(lateBody);
	void body_(SpecDeclBody value) scope {
		lateSet(lateBody, value);
	}

	ref Opt!BuiltinSpec builtin() return scope =>
		body_.builtin;

	Specs parents() return scope =>
		body_.parents;

	void overwriteParentsToEmpty() scope =>
		lateSetOverwrite(lateBody, SpecDeclBody(builtin, emptySpecs, sigs));

	SmallArray!Signature sigs() return scope =>
		body_.sigs;

	UriAndRange range() scope =>
		UriAndRange(moduleUri, ast.range);
	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, ast.nameRange);
}

// The SpecInst and contents are allocated using the AllInsts alloc.
immutable struct SpecInst {
	@safe @nogc pure nothrow:

	SpecDecl* decl;
	TypeArgs typeArgs;
	private Late!SpecInstBody lateBody;

	immutable(SpecInst*[]) parents() return scope =>
		lateGet(lateBody).parents;
	immutable(ReturnAndParamTypes[]) sigTypes() return scope =>
		lateGet(lateBody).sigTypes;
	void body_(SpecInstBody value) {
		lateSet(lateBody, value);
	}

	Symbol name() scope =>
		decl.name;
}
private void eachSpecSig(in SpecInst a, in void delegate(Signature*) @safe @nogc pure nothrow cb) {
	foreach (SpecInst* parent; a.parents)
		eachSpecSig(*parent, cb);
	foreach (ref Signature sig; a.decl.sigs)
		cb(&sig);
}
size_t countSigs(in SpecInst*[] a) =>
	sum(a, (in SpecInst* x) => countSigs(*x));
size_t countSigs(in SpecInst a) =>
	countSigs(a.parents) + a.sigTypes.length;
void eachCalledSpecSig(SpecInst* specInst, in void delegate(CalledSpecSig) @safe @nogc pure nothrow cb) {
	foreach (SpecInst* parent; specInst.parents)
		eachCalledSpecSig(parent, cb);
	foreach (size_t sigIndex, ref Signature sig; specInst.decl.sigs)
		cb(CalledSpecSig(specInst, safeToUshort(sigIndex)));
}

immutable struct SpecInstBody {
	Specs parents;
	// Corresponds to the signatures in decl.body_
	SmallArray!ReturnAndParamTypes sigTypes;
}

enum FlagsFunction {
	in_,
	intersect, // &
	negate, // ~
	none,
	union_, // |
}

enum VarKind { global, threadLocal }

string stringOfVarKindUpperCase(VarKind a) {
	final switch (a) {
		case VarKind.global:
			return "Global";
		case VarKind.threadLocal:
			return "Thread-local";
	}
}

string stringOfVarKindLowerCase(VarKind a) {
	final switch (a) {
		case VarKind.global:
			return "global";
		case VarKind.threadLocal:
			return "thread-local";
	}
}

immutable struct AutoFun {
	enum Kind {
		compare,
		enumOrFlagsMembers,
		enumOrFlagsToIntegral,
		enumToSymbol,
		equals,
		flagsToSymbolArray,
		symbolToOptEnumOrFlags,
		toJson
	}
	Kind kind;
	Called[] members; // e.g., '<=>' implementations for each record/union member
}

immutable struct FunBody {
	@safe @nogc pure nothrow:
	immutable struct Bogus {}
	immutable struct CreateEnumOrFlags {
		EnumOrFlagsMember* member;
	}
	immutable struct CreateExtern {}
	immutable struct CreateRecord {}
	immutable struct CreateRecordAndConvertToSumType {
		StructInst* member; // This is the sumType member type, and the record type
	}
	immutable struct CreateSumType {}
	immutable struct Extern {
		Symbol libraryName;
	}
	immutable struct FileImport {
		ImportFileContent content;
	}
	immutable struct Method {
		@safe @nogc pure nothrow:
		Signature* method;

		ref StructBody.SumType sumType(in FunDecl fun) scope {
			assert(fun.body_.as!(FunBody.Method) == this);
			return fun.params.as!(Destructure[])[0].type.as!(StructInst*).decl.body_.as!(StructBody.SumType);
		}
		size_t methodIndex(in FunDecl fun) scope =>
			mustHaveIndexOfPointer(sumType(fun).methods, method);
	}
	immutable struct RecordFieldCall {
		RecordField* field;
		FunKind funKind;
	}
	immutable struct RecordFieldGet {
		RecordField* field;
	}
	immutable struct RecordFieldPointer {
		RecordField* field;
	}
	immutable struct RecordFieldSet {
		RecordField* field;
	}
	immutable struct SumTypeMemberGet {}
	immutable struct VarGet { VarDecl* var; }
	immutable struct VarSet { VarDecl* var; }

	mixin Union!(
		Bogus,
		AutoFun,
		BuiltinFun,
		CreateEnumOrFlags,
		CreateExtern,
		CreateRecord,
		CreateRecordAndConvertToSumType,
		CreateSumType,
		Expr,
		Extern,
		FileImport,
		FlagsFunction,
		Method,
		RecordFieldCall,
		RecordFieldGet,
		RecordFieldPointer,
		RecordFieldSet,
		SumTypeMemberGet,
		VarGet,
		VarSet);

	static FunBody bogus() =>
		FunBody(Bogus());

	bool isGenerated() scope =>
		!isA!Bogus && !isA!AutoFun && !isA!BuiltinFun && !isA!Expr && !isA!Extern && !isA!FileImport;
}
static assert(FunBody.sizeof == ulong.sizeof + Expr.sizeof);

enum JsFun {
	asJsAny,
	await,
	call,
	callNew,
	callProperty,
	callPropertySpread,
	cast_,
	eqEqEq,
	get,
	instanceof,
	jsGlobal,
	less,
	plus,
	set,
	typeof_,
}

immutable struct BuiltinFun {
	immutable struct AllTests {}
	immutable struct CallLambda {}
	immutable struct CallFunPointer {}
	immutable struct GcSafeValue {}
	immutable struct Init {
		enum Kind { global, perThread }
		Kind kind;
	}
	immutable struct MarkRoot {}
	immutable struct MarkVisit {}
	immutable struct NewEmptyOption {}
	immutable struct NewNonEmptyOption {}
	immutable struct PointerCast {}
	immutable struct SizeOf {}
	immutable struct StaticSymbols {}

	mixin Union!(
		AllTests,
		BuiltinUnary,
		BuiltinUnaryMath,
		BuiltinBinary,
		BuiltinBinaryLazy,
		BuiltinBinaryMath,
		BuiltinTernary,
		Builtin4ary,
		CallLambda,
		CallFunPointer,
		Constant,
		GcSafeValue,
		Init,
		JsFun,
		MarkRoot,
		MarkVisit,
		NewEmptyOption,
		NewNonEmptyOption,
		PointerCast,
		SizeOf,
		StaticSymbols,
		VersionFun);
}

enum BuiltinUnary {
	arrayPointer, // works on mut-slice too
	arraySize, // works on mut-slice too
	asAnyPointer,
	asFuture,
	asFutureImpl,
	asMutArray,
	asMutArrayImpl,
	bitsOfFloat32,
	bitsOfFloat64,
	bitwiseNotNat8,
	bitwiseNotNat16,
	bitwiseNotNat32,
	bitwiseNotNat64,
	countOnesNat64,
	cStringOfSymbol,
	deref,
	drop,
	float32FromBits,
	float64FromBits,
	isNanFloat32,
	isNanFloat64,
	not,
	jumpToCatch,
	referenceFromPointer,
	setupCatch,
	symbolOfCString,
	toChar8FromNat8,
	toChar8ArrayFromString,
	toFloat32FromFloat64,
	toFloat64FromFloat32,
	toFloat64FromInt64,
	toFloat64FromNat64,
	toInt64FromInt8,
	toInt64FromInt16,
	toInt64FromInt32,
	toNat8FromChar8,
	toNat32FromChar32,
	toNat64FromNat8,
	toNat64FromNat16,
	toNat64FromNat32,
	toNat64FromPtr,
	toPtrFromNat64,
	truncateToInt64FromFloat64,
	trustAsString,
	unsafeToChar32FromChar8,
	unsafeToChar32FromNat32,
	unsafeToNat32FromInt32,
	unsafeToInt8FromInt64,
	unsafeToInt16FromInt64,
	unsafeToInt32FromInt64,
	unsafeToNat64FromInt64,
	unsafeToInt64FromNat64,
	unsafeToNat8FromNat64,
	unsafeToNat16FromNat64,
	unsafeToNat32FromNat64,
}

enum BuiltinUnaryMath {
	acosFloat32,
	acosFloat64,
	acoshFloat32,
	acoshFloat64,
	asinFloat32,
	asinFloat64,
	asinhFloat32,
	asinhFloat64,
	atanFloat32,
	atanFloat64,
	atanhFloat32,
	atanhFloat64,
	cosFloat32,
	cosFloat64,
	coshFloat32,
	coshFloat64,
	roundDownFloat32,
	roundDownFloat64,
	roundFloat32,
	roundFloat64,
	roundUpFloat32,
	roundUpFloat64,
	sinFloat32,
	sinFloat64,
	sinhFloat32,
	sinhFloat64,
	sqrtFloat32,
	sqrtFloat64,
	tanFloat32,
	tanFloat64,
	tanhFloat32,
	tanhFloat64,
	unsafeLogFloat32,
	unsafeLogFloat64,
}

enum BuiltinBinary {
	addFloat32,
	addFloat64,
	addPointerAndNat64, // RHS is multiplied by size of pointee first
	bitwiseAndInt8,
	bitwiseAndInt16,
	bitwiseAndInt32,
	bitwiseAndInt64,
	bitwiseAndNat8,
	bitwiseAndNat16,
	bitwiseAndNat32,
	bitwiseAndNat64,
	bitwiseOrInt8,
	bitwiseOrInt16,
	bitwiseOrInt32,
	bitwiseOrInt64,
	bitwiseOrNat8,
	bitwiseOrNat16,
	bitwiseOrNat32,
	bitwiseOrNat64,
	bitwiseXorInt8,
	bitwiseXorInt16,
	bitwiseXorInt32,
	bitwiseXorInt64,
	bitwiseXorNat8,
	bitwiseXorNat16,
	bitwiseXorNat32,
	bitwiseXorNat64,
	equalChar8,
	equalChar32,
	equalFloat32,
	equalFloat64,
	equalInt8,
	equalInt16,
	equalInt32,
	equalInt64,
	equalNat8,
	equalNat16,
	equalNat32,
	equalNat64,
	equalPointer,
	lessChar8,
	lessFloat32,
	lessFloat64,
	lessInt8,
	lessInt16,
	lessInt32,
	lessInt64,
	lessNat8,
	lessNat16,
	lessNat32,
	lessNat64,
	lessPointer,
	mulFloat32,
	mulFloat64,
	newArray, // Also works for mut-slice
	referenceEqual,
	seq,
	subFloat32,
	subFloat64,
	subPointerAndNat64, // RHS is multiplied by size of pointee first
	switchFiber,
	unsafeAddInt8,
	unsafeAddInt16,
	unsafeAddInt32,
	unsafeAddInt64,
	unsafeAddNat8,
	unsafeAddNat16,
	unsafeAddNat32,
	unsafeAddNat64,
	unsafeBitShiftLeftNat64,
	unsafeBitShiftRightNat64,
	unsafeDivFloat32,
	unsafeDivFloat64,
	unsafeDivInt8,
	unsafeDivInt16,
	unsafeDivInt32,
	unsafeDivInt64,
	unsafeDivNat8,
	unsafeDivNat16,
	unsafeDivNat32,
	unsafeDivNat64,
	unsafeModNat64,
	unsafeMulInt8,
	unsafeMulInt16,
	unsafeMulInt32,
	unsafeMulInt64,
	unsafeMulNat8,
	unsafeMulNat16,
	unsafeMulNat32,
	unsafeMulNat64,
	unsafeSubInt8,
	unsafeSubInt16,
	unsafeSubInt32,
	unsafeSubInt64,
	unsafeSubNat8,
	unsafeSubNat16,
	unsafeSubNat32,
	unsafeSubNat64,
	wrapAddNat8,
	wrapAddNat16,
	wrapAddNat32,
	wrapAddNat64,
	wrapMulNat8,
	wrapMulNat16,
	wrapMulNat32,
	wrapMulNat64,
	wrapSubNat8,
	wrapSubNat16,
	wrapSubNat32,
	wrapSubNat64,
	writeToPointer,
}

// These all have a lazy second argument
enum BuiltinBinaryLazy {
	boolAnd,
	boolOr,
	optionOr,
	optionQuestion2,
}

enum BuiltinBinaryMath {
	atan2Float32,
	atan2Float64,
	// Note: Like the C 'fmod' function, this is not a true modulo; it keeps negative numbers negative
	fmodFloat32,
	fmodFloat64,
	unsafePowFloat32,
	unsafePowFloat64,
}

enum BuiltinTernary { interpreterBacktrace }
enum Builtin4ary { switchFiberInitial }

immutable struct FunFlags {
	@safe @nogc pure nothrow:

	bool bare;
	bool summon;
	enum Safety : ubyte { safe, trusted, unsafe }
	Safety safety;
	bool okIfUnused;
	bool forceCtx;

	FunFlags withOkIfUnused() =>
		FunFlags(bare, summon, safety, true, forceCtx);
	FunFlags withSummon() =>
		withSummon(true);
	FunFlags withSummon(bool value) =>
		FunFlags(bare, value, safety, okIfUnused, forceCtx);

	static FunFlags regular(bool bare, bool summon, Safety safety, bool forceCtx) =>
		FunFlags(bare, summon, safety, false, forceCtx);

	static FunFlags none() =>
		FunFlags(safety: Safety.safe);
	static FunFlags generatedBare() =>
		FunFlags(bare: true, safety: Safety.safe, okIfUnused: true);
	static FunFlags generatedBareUnsafe() =>
		FunFlags(bare: true, safety: Safety.unsafe, okIfUnused: true);
	static FunFlags generated() =>
		FunFlags(safety: Safety.safe, okIfUnused: true);
}
static assert(FunFlags.sizeof == 5);

immutable struct FunDeclSource {
	@safe @nogc pure nothrow:

	immutable struct Bogus {
		Uri uri;
		TypeParams typeParams;
	}
	immutable struct Ast {
		Uri moduleUri;
		FunDeclAst* ast;
	}
	immutable struct FileImport {
		Uri moduleUri; // This is the importing module, not imported
		ImportOrExportAst* ast;
	}

	mixin Union!(
		Bogus,
		Ast,
		EnumOrFlagsMember*,
		FileImport,
		RecordField*,
		// This is for a variant method
		Signature*,
		StructDecl*,
		VarDecl*);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in FunDeclSource.Bogus x) =>
				x.uri,
			(in FunDeclSource.Ast x) =>
				x.moduleUri,
			(in EnumOrFlagsMember x) =>
				x.moduleUri,
			(in FunDeclSource.FileImport x) =>
				x.moduleUri,
			(in RecordField x) =>
				x.moduleUri,
			(in Signature x) =>
				x.moduleUri,
			(in StructDecl x) =>
				x.moduleUri,
			(in VarDecl x) =>
				x.moduleUri);

	UriAndRange range() scope =>
		matchIn!UriAndRange(
			(in FunDeclSource.Bogus x) =>
				UriAndRange(x.uri, Range.empty),
			(in FunDeclSource.Ast x) =>
				UriAndRange(x.moduleUri, x.ast.range),
			(in EnumOrFlagsMember x) =>
				UriAndRange(x.moduleUri, x.range),
			(in FunDeclSource.FileImport x) =>
				UriAndRange(x.moduleUri, x.ast.range),
			(in RecordField x) =>
				UriAndRange(x.moduleUri, x.range),
			(in Signature x) =>
				x.range,
			(in StructDecl x) =>
				x.range,
			(in VarDecl x) =>
				x.range);
	UriAndRange nameRange() scope =>
		matchIn!UriAndRange(
			(in FunDeclSource.Bogus x) =>
				UriAndRange(x.uri, Range.empty),
			(in FunDeclSource.Ast x) =>
				UriAndRange(x.moduleUri, x.ast.nameRange),
			(in EnumOrFlagsMember x) =>
				x.nameRange,
			(in FunDeclSource.FileImport x) =>
				UriAndRange(x.moduleUri, x.ast.range),
			(in RecordField x) =>
				x.nameRange,
			(in Signature x) =>
				x.nameRange,
			(in StructDecl x) =>
				x.nameRange,
			(in VarDecl x) =>
				x.nameRange);

	DocCommentAst docCommentAst() scope =>
		isA!Ast
			? as!Ast.ast.docComment
			: DocCommentAst.empty;
}

immutable struct FunDecl {
	@safe @nogc pure nothrow:

	FunDeclSource source;
	Visibility visibility;
	Symbol name;
	Type returnType;
	Params params;
	FunFlags flags;
	SymbolSet externs;
	Specs specs;
	private Late!DocCommentReferences lateDocCommentReferences;
	private Late!FunBody lateBody;

	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	ref FunBody body_() return scope =>
		lateGet(lateBody);
	bool bodyIsSet() return scope =>
		lateIsSet(lateBody);
	void body_(FunBody b) {
		lateSet(lateBody, b);
	}

	TypeParams typeParams() return scope =>
		source.match!TypeParams(
			(FunDeclSource.Bogus x) =>
				x.typeParams,
			(FunDeclSource.Ast x) =>
				x.ast.typeParams,
			(ref EnumOrFlagsMember x) =>
				x.containingEnum.typeParams,
			(FunDeclSource.FileImport _) =>
				emptySmallArray!NameAndRange,
			(ref RecordField x) =>
				x.containingRecord.typeParams,
			(ref Signature x) =>
				x.container.typeParams,
			(ref StructDecl x) =>
				x.typeParams,
			(ref VarDecl x) =>
				x.typeParams);

	Uri moduleUri() scope =>
		source.moduleUri;

	UriAndRange range() scope =>
		source.range;
	UriAndRange nameRange() scope =>
		source.nameRange;
	DocCommentAst docCommentAst() scope =>
		source.docCommentAst;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);

	Linkage linkage() scope =>
		body_.isA!(FunBody.Extern) ? Linkage.extern_ : Linkage.internal;

	bool isBare() scope =>
		flags.bare;
	bool isBareOrForceCtx() scope =>
		flags.bare || flags.forceCtx;
	bool isGenerated() scope =>
		body_.isGenerated;
	bool isSummon() scope =>
		flags.summon;
	bool isUnsafe() scope =>
		flags.safety == FunFlags.Safety.unsafe;
	bool okIfUnused() scope =>
		flags.okIfUnused;

	bool isVariadic() scope =>
		params.isA!(Params.Varargs*);

	bool isTemplate() scope =>
		!isEmpty(typeParams) || !isEmpty(specs);

	Arity arity() scope =>
		params.arity;
}
bool eachSpecInFunIncludingParents(in FunDecl a, in bool delegate(SpecInst*) @safe @nogc pure nothrow cb) =>
	exists!(SpecInst*)(a.specs, (ref const SpecInst* spec) =>
		eachSpecIncludingParents(spec, cb));
private bool eachSpecIncludingParents(SpecInst* a, in bool delegate(SpecInst*) @safe @nogc pure nothrow cb) =>
	exists!(SpecInst*)(a.parents, (ref const SpecInst* parent) => eachSpecIncludingParents(parent, cb)) || cb(a);
void eachSpecSigAndImpl(
	in FunDecl a,
	in SpecImpls impls,
	in void delegate(SpecInst*, Signature*, Called) @safe @nogc pure nothrow cb,
) {
	assert(impls.length == countSigs(a.specs));
	size_t implIndex = 0;
	foreach (SpecInst* spec; a.specs)
		eachSpecSig(*spec, (Signature* sig) {
			cb(spec, sig, impls[implIndex++]);
		});
	assert(implIndex == impls.length);
}

immutable struct Test {
	@safe @nogc pure nothrow:

	TestAst* ast;
	Uri moduleUri;
	FunFlags flags;
	SymbolSet externs;
	Expr body_;
	private Late!DocCommentReferences lateDocCommentReferences;

	DocCommentAst docCommentAst() return scope =>
		ast.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);

	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	UriAndRange range() scope =>
		UriAndRange(moduleUri, ast.range);

	Symbol name() scope =>
		symbol!"test";
}

immutable struct FunDeclAndTypeArgs {
	FunDecl* decl;
	TypeArgs typeArgs;
}

// The FunInst and its contents are allocated using the AllInsts alloc.
immutable struct FunInst {
	@safe @nogc pure nothrow:

	FunDecl* decl;
	TypeArgs typeArgs;
	SpecImpls specImpls;
	ReturnAndParamTypes instantiatedSig;

	Symbol name() scope =>
		decl.name;

	Type returnType() scope =>
		instantiatedSig.returnType;

	Type[] paramTypes() return scope =>
		instantiatedSig.paramTypes;

	Arity arity() scope =>
		decl.arity;
}

immutable struct ReturnAndParamTypes {
	@safe @nogc pure nothrow:

	SmallArray!Type returnAndParamTypes;

	Type returnType() scope =>
		returnAndParamTypes[0];

	Type[] paramTypes() return scope =>
		returnAndParamTypes[1 .. $];
}

immutable struct CalledSpecSig {
	@safe @nogc pure nothrow:

	private PtrAndSmallNumber!SpecInst inner;

	private this(PtrAndSmallNumber!SpecInst i) {
		inner = i;
		assert(sigIndex < specInst.sigTypes.length);
	}
	this(SpecInst* s, ushort i) {
		this(PtrAndSmallNumber!SpecInst(s, i));
	}

	@system ulong asTaggable() =>
		inner.asTaggable;
	@system static CalledSpecSig fromTagged(ulong x) =>
		CalledSpecSig(PtrAndSmallNumber!SpecInst.fromTagged(x));

	SpecInst* specInst() return scope =>
		inner.ptr;
	size_t sigIndex() scope =>
		inner.number;

	ReturnAndParamTypes instantiatedSig() return scope =>
		specInst.sigTypes[sigIndex];
	Type returnType() scope =>
		instantiatedSig.returnType;
	Type[] paramTypes() return scope =>
		instantiatedSig.paramTypes;

	Signature* nonInstantiatedSig() return scope =>
		&specInst.decl.sigs[sigIndex];

	Symbol name() scope =>
		nonInstantiatedSig.name;

	Arity arity() scope =>
		Arity(safeToUint(nonInstantiatedSig.params.length));
}

// Like 'Called', but we haven't fully instantiated yet. (This is used for Candidate when checking a call expr.)
immutable struct CalledDecl {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(FunDecl*, CalledSpecSig);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in FunDecl x) => x.moduleUri,
			(in CalledSpecSig x) => x.specInst.decl.moduleUri);

	UriAndRange range() =>
		matchIn!UriAndRange(
			(in FunDecl x) =>
				x.range,
			(in CalledSpecSig x) =>
				x.nonInstantiatedSig.range);

	Symbol name() scope =>
		matchIn!Symbol(
			(in FunDecl f) => f.name,
			(in CalledSpecSig s) => s.name);

	TypeParams typeParams() return scope =>
		match!TypeParams(
			(ref FunDecl f) => f.typeParams,
			(CalledSpecSig _) => emptyTypeParams);

	Type returnType() =>
		match!Type(
			(ref FunDecl f) => f.returnType,
			(CalledSpecSig s) => s.returnType);

	Arity arity() scope =>
		matchIn!Arity(
			(in FunDecl x) =>
				x.arity,
			(in CalledSpecSig x) =>
				x.arity);

	DocComment docComment() scope =>
		match!DocComment(
			(ref FunDecl x) =>
				x.docComment,
			(CalledSpecSig x) =>
				x.nonInstantiatedSig.docComment);

	Params nonInstantiatedParams() =>
		match!Params(
			(ref FunDecl x) =>
				x.params,
			(CalledSpecSig x) =>
				Params(x.nonInstantiatedSig.params));

	bool isVariadic() scope =>
		arity.isVariadic;
}

size_t nTypeParams(in CalledDecl a) =>
	a.typeParams.length;

immutable struct Called {
	@safe @nogc pure nothrow:

	immutable struct Bogus {
		CalledDecl decl;
		Type returnType;
		Type[] paramTypes;
	}
	mixin TaggedUnion!(Bogus*, FunInst*, CalledSpecSig);

	CalledDecl calledDecl() return scope =>
		match!CalledDecl(
			(ref Bogus x) =>
				x.decl,
			(ref FunInst x) =>
				CalledDecl(x.decl),
			(CalledSpecSig x) =>
				CalledDecl(x));

	Symbol name() scope =>
		calledDecl.name;

	Type returnType() scope =>
		match!Type(
			(ref Bogus x) =>
				x.returnType,
			(ref FunInst f) =>
				f.returnType,
			(CalledSpecSig s) =>
				s.instantiatedSig.returnType);

	Type[] paramTypes() scope =>
		match!(Type[])(
			(ref Bogus x) =>
				x.paramTypes,
			(ref FunInst x) =>
				x.paramTypes,
			(CalledSpecSig s) =>
				s.instantiatedSig.paramTypes);

	Arity arity() scope =>
		calledDecl.arity;

	bool isVariadic() scope =>
		arity.isVariadic;
}

Type paramTypeAt(in Called a, size_t argIndex) scope =>
	a.matchIn!Type(
		(in Called.Bogus x) =>
			a.isVariadic ? only(x.paramTypes) : x.paramTypes[argIndex],
		(in FunInst x) =>
			a.isVariadic ? arrayElementType(only(x.paramTypes)) : x.paramTypes[argIndex],
		(in CalledSpecSig x) {
			assert(!a.isVariadic);
			return x.paramTypes[argIndex];
		});

immutable struct StructOrAlias {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(StructAlias*, StructDecl*);

	UriAndRange range() scope =>
		matchIn!UriAndRange(
			(in StructAlias x) => x.range,
			(in StructDecl x) => x.range);
	UriAndRange nameRange() scope =>
		matchIn!UriAndRange(
			(in StructAlias x) =>
				x.nameRange,
			(in StructDecl x) =>
				x.nameRange);

	Visibility visibility() scope =>
		matchIn!Visibility(
			(in StructAlias x) => x.visibility,
			(in StructDecl x) => x.visibility);

	Symbol name() scope =>
		matchIn!Symbol(
			(in StructAlias x) => x.name,
			(in StructDecl x) => x.name);

	TypeParams typeParams() =>
		match!TypeParams(
			(ref StructAlias x) => x.typeParams,
			(ref StructDecl x) => x.typeParams);
}

// No VarInst since these can't be templates
immutable struct VarDecl {
	@safe @nogc pure nothrow:

	VarDeclAst* ast;
	Uri moduleUri;
	Visibility visibility;
	Type type;
	Opt!Symbol externLibraryName;
	private Late!DocCommentReferences lateDocCommentReferences;

	DocCommentAst docCommentAst() return scope =>
		ast.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);

	DocCommentReferences docCommentReferences() return scope =>
		lateGet(lateDocCommentReferences);
	void docCommentReferences(DocCommentReferences value) {
		lateSet(lateDocCommentReferences, value);
	}

	Symbol name() scope =>
		ast.name.name;
	TypeParams typeParams() return scope =>
		emptyTypeParams;
	VarKind kind() scope =>
		ast.kind;

	UriAndRange range() scope =>
		UriAndRange(moduleUri, ast.range);
	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, ast.nameRange);
}

immutable struct Module {
	@safe @nogc pure nothrow:

	Uri uri;
	Config* config; // The config closest to this module. (Not necessarily the main config.)
	FileAst* ast;
	SmallArray!Diagnostic diagnostics; // See also 'ast.diagnostics'
	SmallArray!ImportOrExport imports; // includes import of std (if applicable)
	SmallArray!ImportOrExport reExports;
	SmallArray!StructAlias aliases;
	SmallArray!StructDecl structs;
	SmallArray!VarDecl vars;
	SmallArray!SpecDecl specs;
	SmallArray!FunDecl funs;
	SmallArray!Test tests;
	// Includes both internal and public exports.
	HashTable!(NameReferents, Symbol, nameFromNameReferents) exports;
	DocCommentReferences docCommentReferences;

	UriAndRange range() scope =>
		UriAndRange.topOfFile(uri);
	DocCommentAst docCommentAst() scope =>
		ast.docComment;
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
}
Uri getModuleUri(in Module* a) =>
	a.uri;

// Excludes derived decls, e.g. FunDecl that is a record field getter
void eachDecl(in Module a, in void delegate(AnyDecl) @safe @nogc pure nothrow cb) {
	foreach (ref StructAlias x; a.aliases)
		cb(AnyDecl(&x));
	foreach (ref StructDecl x; a.structs)
		cb(AnyDecl(&x));
	foreach (ref VarDecl x; a.vars)
		cb(AnyDecl(&x));
	foreach (ref SpecDecl x; a.specs)
		cb(AnyDecl(&x));
	foreach (ref FunDecl x; a.funs)
		if (x.source.isA!(FunDeclSource.Ast))
			cb(AnyDecl(&x));
	foreach (ref Test x; a.tests)
		cb(AnyDecl(&x));
}

immutable struct AnyDecl {
	@safe @nogc pure nothrow:

	// WARN: We'll never consider a StructAlias as 'used', only the underlying StructDecl.
	// An inlined function is not considered used, just its return type
	mixin TaggedUnion!(FunDecl*, SpecDecl*, StructAlias*, StructDecl*, Test*, VarDecl*);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in FunDecl x) => x.moduleUri,
			(in SpecDecl x) => x.moduleUri,
			(in StructAlias x) => x.moduleUri,
			(in StructDecl x) => x.moduleUri,
			(in Test x) => x.moduleUri,
			(in VarDecl x) => x.moduleUri);

	Symbol name() scope =>
		matchIn!Symbol(
			(in FunDecl x) => x.name,
			(in SpecDecl x) => x.name,
			(in StructAlias x) => x.name,
			(in StructDecl x) => x.name,
			(in Test x) => x.name,
			(in VarDecl x) => x.name);

	UriAndRange range() scope =>
		matchIn!UriAndRange(
			(in FunDecl x) => x.range,
			(in SpecDecl x) => x.range,
			(in StructAlias x) => x.range,
			(in StructDecl x) => x.range,
			(in Test x) => x.range,
			(in VarDecl x) => x.range);

	DocCommentAst docCommentAst() =>
		match!DocCommentAst(
			(ref FunDecl x) =>
				x.docCommentAst,
			(ref SpecDecl x) =>
				x.docCommentAst,
			(ref StructAlias x) =>
				x.docCommentAst,
			(ref StructDecl x) =>
				x.docCommentAst,
			(ref Test x) =>
				x.docCommentAst,
			(ref VarDecl x) =>
				x.docCommentAst);

	DocComment docComment() return scope =>
		match!DocComment(
			(ref FunDecl x) =>
				x.docComment,
			(ref SpecDecl x) =>
				x.docComment,
			(ref StructAlias x) =>
				x.docComment,
			(ref StructDecl x) =>
				x.docComment,
			(ref Test x) =>
				x.docComment,
			(ref VarDecl x) =>
				x.docComment);

	Specs specs() scope =>
		match!Specs(
			(ref FunDecl x) =>
				x.specs,
			(ref SpecDecl x) =>
				x.parents,
			(ref StructAlias _) =>
				emptySpecs,
			(ref StructDecl _) =>
				emptySpecs,
			(ref Test _) =>
				emptySpecs,
			(ref VarDecl _) =>
				emptySpecs);

	TypeParams typeParams() scope =>
		matchIn!TypeParams(
			(in FunDecl x) =>
				x.typeParams,
			(in SpecDecl x) =>
				x.typeParams,
			(in StructAlias x) =>
				emptyTypeParams,
			(in StructDecl x) =>
				x.typeParams,
			(in Test x) =>
				emptyTypeParams,
			(in VarDecl x) =>
				x.typeParams);

	Visibility visibility() scope =>
		matchIn!Visibility(
			(in FunDecl x) => x.visibility,
			(in SpecDecl x) => x.visibility,
			(in StructAlias x) => x.visibility,
			(in StructDecl x) => x.visibility,
			// Treat as public since 'run-all-tests' runs tests from other modules
			(in Test x) => Visibility.public_,
			(in VarDecl x) => x.visibility);
}

immutable struct TypeWithContainer {
	Type type;
	TypeContainer container;
}

// Since a type parameter is represented as its index, we need a context to know where to find it.
// This is like AnyDecl, but also includes 'Module' which can have types in its doc comment.
immutable struct TypeContainer {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(FunDecl*, Module*, SpecDecl*, StructAlias*, StructDecl*, Test*, VarDecl*);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in FunDecl x) =>
				x.moduleUri,
			(in Module x) =>
				x.uri,
			(in SpecDecl x) =>
				x.moduleUri,
			(in StructAlias x) =>
				x.moduleUri,
			(in StructDecl x) =>
				x.moduleUri,
			(in Test x) =>
				x.moduleUri,
			(in VarDecl x) =>
				x.moduleUri);

	TypeParams typeParams() scope =>
		matchIn!TypeParams(
			(in FunDecl x) =>
				x.typeParams,
			(in Module x) =>
				emptyTypeParams,
			(in SpecDecl x) =>
				x.typeParams,
			(in StructAlias x) =>
				emptyTypeParams,
			(in StructDecl x) =>
				x.typeParams,
			(in Test x) =>
				emptyTypeParams,
			(in VarDecl x) =>
				x.typeParams);

	DocComment docComment() return scope =>
		matchIn!DocComment(
			(in FunDecl x) =>
				x.docComment,
			(in Module x) =>
				x.docComment,
			(in SpecDecl x) =>
				x.docComment,
			(in StructAlias x) =>
				x.docComment,
			(in StructDecl x) =>
				x.docComment,
			(in Test x) =>
				x.docComment,
			(in VarDecl x) =>
				x.docComment);
}
AnyDecl forbidModule(TypeContainer a) =>
	a.matchWithPointers!AnyDecl(
		(FunDecl* x) => AnyDecl(x),
		(Module*) => assert(false),
		(SpecDecl* x) => AnyDecl(x),
		(StructAlias* x) => AnyDecl(x),
		(StructDecl* x) => AnyDecl(x),
		(Test* x) => AnyDecl(x),
		(VarDecl* x) => AnyDecl(x));
TypeContainer toTypeContainer(AnyDecl a) =>
	a.matchWithPointers!TypeContainer(
		(FunDecl* x) => TypeContainer(x),
		(SpecDecl* x) => TypeContainer(x),
		(StructAlias* x) => TypeContainer(x),
		(StructDecl* x) => TypeContainer(x),
		(Test* x) => TypeContainer(x),
		(VarDecl* x) => TypeContainer(x));

enum IsImportOrExport { import_, export_ }
void eachImportOrReExport(in Module a, in void delegate(ref ImportOrExport) @safe @nogc pure nothrow cb) {
	eachImportOrReExport(a, (IsImportOrExport _, ref ImportOrExport x) {
		cb(x);
	});
}
void eachImportOrReExport(
	in Module a,
	in void delegate(IsImportOrExport, ref ImportOrExport) @safe @nogc pure nothrow cb,
) {
	foreach (ref ImportOrExport x; a.imports)
		cb(IsImportOrExport.import_, x);
	foreach (ref ImportOrExport x; a.reExports)
		cb(IsImportOrExport.export_, x);
}

immutable struct ImportOrExport {
	@safe @nogc pure nothrow:

	// none for an automatic import of std
	Opt!(ImportOrExportAst*) source;
	Module* modulePtr;
	// If this is internal, imports internal and public exports; if this is public, import only public exports
	ExportVisibility importVisibility;
	// If the ast was NameAndRange[], this will have an entry for each name (except when there was nothing to import).
	// For an import of a ModuleWhole, this tracks what was actually used in this module.
	// For a re-export of a ModuleWhole, this is not used.
	Late!ImportedReferents imported_;

	ref Module module_() return scope =>
		*modulePtr;
	// WARN: This is not set for a re-export of a ModuleWhole. Test 'hasImported' first.
	ref ImportedReferents imported() return scope =>
		lateGet(imported_);
	void imported(ImportedReferents value) {
		lateSet(imported_, value);
	}
	bool hasImported() scope =>
		lateIsSet(imported_);
	bool isStd() scope =>
		!has(source);
	bool isRelativeImport() scope =>
		has(source) && force(source).path.isA!RelPath;
}
alias ImportedReferents = HashTable!(NameReferents*, Symbol, nameFromNameReferentsPointer);

immutable struct ImportFileContent {
	immutable struct Bogus {}
	mixin Union!(immutable ubyte[], string, Bogus);
}

immutable struct NameReferents {
	@safe @nogc pure nothrow:

	Opt!StructOrAlias structOrAlias;
	Opt!(SpecDecl*) spec;
	SmallArray!(FunDecl*) funs;

	this(Opt!StructOrAlias sa, Opt!(SpecDecl*) sp, immutable FunDecl*[] fs) {
		structOrAlias = sa;
		spec = sp;
		funs = fs;
		assert(has(structOrAlias) || has(spec) || !isEmpty(funs));
	}

	Symbol name() scope =>
		has(structOrAlias)
			? force(structOrAlias).name
			: has(spec)
			? force(spec).name
			: funs[0].name;
}
Symbol nameFromNameReferents(in NameReferents a) =>
	a.name;
Symbol nameFromNameReferentsPointer(in NameReferents* a) =>
	a.name;

enum FunKind {
	data,
	shared_,
	mut,
	function_,
}
Opt!FunKind funKindFromBuiltinType(BuiltinType a) {
	switch (a) {
		case BuiltinType.lambdaData:
			return some(FunKind.data);
		case BuiltinType.lambdaShared:
			return some(FunKind.shared_);
		case BuiltinType.lambdaMut:
			return some(FunKind.mut);
		case BuiltinType.funPointer:
			return some(FunKind.function_);
		default:
			return none!FunKind;
	}
}

immutable struct CommonFunsAndDiagnostics {
	CommonFuns commonFuns;
	SmallArray!UriAndDiagnostic diagnostics;
}
immutable struct CommonFuns {
	@safe @nogc pure nothrow:
	FunInst* jsAwait;
	FunInst* curCatchPoint;
	FunInst* setCurCatchPoint;
	VarDecl* curThrown;
	FunInst* allocate;
	FunInst* and;
	FunInst* createError;
	EnumMap!(FunKind, FunDecl*) lambdaSubscript;
	FunDecl* sharedOfMutLambda;
	FunInst* mark;
	FunInst* toJsonFromJson;
	FunDecl* toJsonFromTArray;
	FunInst* newJsonFromPairs;
	FunInst* runFiber;
	FunInst* runAllTests;
	FunInst* rtMain;
	FunInst* throwImpl;
	FunDecl* equalConstPointers;
	FunInst* rethrowCurrentException;
	FunDecl* concatArrays;

	FunInst* gcRoot;
	FunInst* setGcRoot;
	FunInst* popGcRoot;

	StructInst* catchPointPointerType() =>
		curCatchPoint.returnType.as!(StructInst*);
	StructInst* catchPointType() =>
		only(catchPointPointerType.typeArgs).as!(StructInst*);
}

immutable struct CommonTypes {
	@safe @nogc pure nothrow:

	StructInst* bool_;
	StructInst* char8;
	StructInst* char32;
	StructInst* cString;
	StructInst* exception;
	StructInst* fiber;
	StructInst* float32;
	StructInst* float64;
	StructDecl* future;
	IntegralTypes integrals;
	StructInst* jsAny;
	StructInst* string_;
	StructInst* symbol;
	StructInst* symbolArray;
	StructInst* void_;

	StructDecl* array;
	StructInst* char8Array;
	StructInst* char8ConstPointer;
	StructInst* char32Array;
	StructInst* nat8Array;
	StructInst* stringArray;
	StructDecl* option;
	StructDecl* pointerConst;
	StructDecl* pointerMut;
	StructDecl* reference;
	// No tuple0 and tuple1, so this is 2-9 inclusive
	StructDecl*[8] tuples2Through9;
	// Indexed by FunKind, then by arity. (arity = typeArgs.length - 1)
	EnumMap!(FunKind, StructDecl*) funStructs;

	StructDecl* funPointerStruct() =>
		funStructs[FunKind.function_];

	StructDecl* pair() return scope =>
		force(tuple(2));
	Opt!(StructDecl*) tuple(size_t arity) return scope =>
		2 <= arity && arity <= 9 ? some(tuples2Through9[arity - 2]) : none!(StructDecl*);

	size_t maxTupleSize() scope =>
		9;
}
immutable struct OtherTypes {
	Map!(StructInst*, StructInst*) futureOrMutArrayToImpl;
}

immutable struct IntegralTypes {
	@safe @nogc pure nothrow:
	EnumMap!(IntegralType, StructInst*) map;
	StructInst* opIndex(IntegralType name) return scope => map[name];
	StructInst* int8() return scope => this[IntegralType.int8];
	StructInst* int16() return scope => this[IntegralType.int16];
	StructInst* int32() return scope => this[IntegralType.int32];
	StructInst* int64() return scope => this[IntegralType.int64];
	StructInst* nat8() return scope => this[IntegralType.nat8];
	StructInst* nat16() return scope => this[IntegralType.nat16];
	StructInst* nat32() return scope => this[IntegralType.nat32];
	StructInst* nat64() return scope => this[IntegralType.nat64];
}

enum CharType { char8, char32 }
enum FloatType { float32, float64 }
enum IntegralType {
	int8,
	int16,
	int32,
	int64,
	nat8,
	nat16,
	nat32,
	nat64,
}
bool isSigned(IntegralType a) {
	final switch (a) {
		case IntegralType.int8:
		case IntegralType.int16:
		case IntegralType.int32:
		case IntegralType.int64:
			return true;
		case IntegralType.nat8:
		case IntegralType.nat16:
		case IntegralType.nat32:
		case IntegralType.nat64:
			return false;
	}
}

long minValue(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
			return byte.min;
		case IntegralType.int16:
			return short.min;
		case IntegralType.int32:
			return int.min;
		case IntegralType.int64:
			return long.min;
		case IntegralType.nat8:
		case IntegralType.nat16:
		case IntegralType.nat32:
		case IntegralType.nat64:
			return 0;
	}
}

ulong maxValue(IntegralType type) {
	final switch (type) {
		case IntegralType.int8:
			return byte.max;
		case IntegralType.int16:
			return short.max;
		case IntegralType.int32:
			return int.max;
		case IntegralType.int64:
			return long.max;
		case IntegralType.nat8:
			return ubyte.max;
		case IntegralType.nat16:
			return ushort.max;
		case IntegralType.nat32:
			return uint.max;
		case IntegralType.nat64:
			return ulong.max;
	}
}

immutable struct ProgramWithMain {
	@safe @nogc pure nothrow:
	Program program;
	MainFunAndDiagnostics mainFunAndDiagnostics;

	MainFun mainFun() return scope =>
		mainFunAndDiagnostics.mainFun;
	UriAndDiagnostic[] mainFunDiagnostics() return scope =>
		mainFunAndDiagnostics.diagnostics;
	ref Config mainConfig() return scope =>
		*mainFun.mainConfig(program);
	TestSelector testSelector() =>
		mainFun.testSelector(program);
}

// TODO: isn't this basically just OS?
immutable struct BuildTarget {
	@safe @nogc pure nothrow:
	immutable struct Js {}
	immutable struct Native { OS os; }
	mixin Union!(Js, Native);

	static BuildTarget js() =>
		BuildTarget(Js());
	static BuildTarget native(OS os) =>
		BuildTarget(Native(os));
}

// All 'extern's to compile with for the given target
SymbolSet allExterns(in ProgramWithMain program, BuildTarget target) =>
	allExternsForMainConfig(program.mainConfig, some(target));
SymbolSet allExternsForMainConfig(in Config mainConfig, Opt!BuildTarget target) =>
	buildSymbolSet((scope ref SymbolSetBuilder out_) {
		if (has(target)) {
			force(target).match!void(
				(BuildTarget.Js) {
					out_ ~= symbol!"js";
				},
				(BuildTarget.Native x) {
					final switch (x.os) {
						case OS.nodeJs:
						case OS.web:
							assert(false);
						case OS.none:
							out_ ~= symbol!"fake";
							break;
						case OS.linux:
							out_ ~= [
								symbolOfEnum(BuiltinExtern.linux),
								symbolOfEnum(BuiltinExtern.posix),
								symbolOfEnum(BuiltinExtern.pthread),
								symbolOfEnum(BuiltinExtern.sodium),
								symbolOfEnum(BuiltinExtern.unwind),
							];
							break;
						case OS.windows:
							out_ ~= [
								symbolOfEnum(BuiltinExtern.DbgHelp),
								symbolOfEnum(BuiltinExtern.ucrtbase),
								symbolOfEnum(BuiltinExtern.windows),
							];
							break;
					}
					out_ ~= [symbolOfEnum(BuiltinExtern.libc), symbolOfEnum(BuiltinExtern.native)];
				});
		}
		foreach (Symbol name, Opt!Uri uri; mainConfig.extern_)
			if (has(uri))
				out_ ~= name;
	});

immutable struct ProgramWithOptMain {
	@safe @nogc pure nothrow:
	Program program;
	private Opt!MainFunAndDiagnostics mainFunAndDiagnostics;

	bool hasMain() scope =>
		has(mainFunAndDiagnostics);
	ProgramWithMain asProgramWithMain() return scope =>
		ProgramWithMain(program, force(mainFunAndDiagnostics));
	Program asProgram() return scope =>
		program;
}
ProgramWithOptMain asProgramWithOptMain(ProgramWithMain a) =>
	ProgramWithOptMain(a.program, some(a.mainFunAndDiagnostics));
ProgramWithOptMain asProgramWithOptMain(Program a) =>
	ProgramWithOptMain(a, none!MainFunAndDiagnostics);

immutable struct MainFunAndDiagnostics {
	MainFun mainFun;
	SmallArray!UriAndDiagnostic diagnostics;
}
immutable struct MainFun {
	@safe @nogc pure nothrow:

	immutable struct Nat64OfArgs {
		FunInst* fun;
	}
	immutable struct Void {
		FunInst* fun;
	}

	mixin Union!(Nat64OfArgs, Void, TestSelector);

	UriAndRange rangeForDiag() scope =>
		matchIn!UriAndRange(
			(in Nat64OfArgs x) =>
				x.fun.decl.range,
			(in Void x) =>
				x.fun.decl.range,
			(in TestSelector test) =>
				test.matchIn!UriAndRange(
					(in TestSelector.All x) =>
						// We don't get diagnostics for this
						assert(false),
					(in Config x) =>
						UriAndRange.topOfFile(force(x.configUri)),
					(in Uri x) =>
						UriAndRange.topOfFile(x),
					(in Test x) =>
						x.range));

	Opt!Uri uriForTempPath() scope =>
		matchIn!(Opt!Uri)(
			(in Nat64OfArgs x) =>
				some(x.fun.decl.moduleUri),
			(in Void x) =>
				some(x.fun.decl.moduleUri),
			(in TestSelector test) =>
				test.matchIn!(Opt!Uri)(
					(in TestSelector.All) =>
						none!Uri,
					(in Config x) =>
						some(force(x.configUri)),
					(in Uri x) =>
						some(x),
					(in Test x) =>
						some(x.moduleUri)));

	SymbolSet requiredExterns() scope =>
		matchIn!SymbolSet(
			(in Nat64OfArgs x) =>
				x.fun.decl.externs,
			(in Void x) =>
				x.fun.decl.externs,
			(in TestSelector x) =>
				x.matchIn!SymbolSet(
					(in TestSelector.All) =>
						emptySymbolSet,
					(in Config _) =>
						emptySymbolSet,
					(in Uri _) =>
						emptySymbolSet,
					(in Test x) =>
						x.externs));

	Config* mainConfig(return scope ref Program program) return scope {
		Config* configFor(Uri uri) =>
			moduleAtUri(program, uri).config;
		return match!(Config*)(
			(Nat64OfArgs x) =>
				configFor(x.fun.decl.moduleUri),
			(Void x) =>
				configFor(x.fun.decl.moduleUri),
			(TestSelector test) =>
				test.matchWithPointers!(Config*)(
					(TestSelector.All x) =>
						x.mainConfig,
					(Config* x) =>
						x,
					(Uri x) =>
						configFor(x),
					(Test* x) =>
						configFor(x.moduleUri)));
	}

	TestSelector testSelector(ref Program program) =>
		matchIn!TestSelector(
			(in Nat64OfArgs _) =>
				TestSelector.all(mainConfig(program)),
			(in Void _) =>
				TestSelector.all(mainConfig(program)),
			(in TestSelector x) =>
				x);
}

immutable struct TestSelector {
	@safe @nogc pure nothrow:
	immutable struct All {
		Config* mainConfig;
	}
	// All tests, tests in a particular config, tests in a single file, or a single test
	mixin Union!(All, Config*, Uri, Test*);

	static TestSelector all(Config* mainConfig) =>
		TestSelector(All(mainConfig));
}

bool hasAnyDiagnostics(in ProgramWithMain a) =>
	hasAnyDiagnostics(a.program) || !isEmpty(a.mainFunDiagnostics);
bool hasFatalDiagnostics(in ProgramWithMain a) =>
	hasFatalDiagnostics(a.program) || !isEmpty(a.mainFunDiagnostics);

immutable struct Program {
	@safe @nogc pure nothrow:
	HashTable!(immutable Config*, Uri, getConfigUri) allConfigs;
	HashTable!(immutable Module*, Uri, getModuleUri) allModules;
	FileContentGetters fileContentGetters;
	LineAndColumnGetters lineAndColumnGetters;
	CommonFunsAndDiagnostics commonFunsAndDiagnostics;
	CommonTypes* commonTypesPtr;
	OtherTypes otherTypes;

	LineAndCharacterGetters lineAndCharacterGetters() return scope =>
		lineAndColumnGetters.lineAndCharacterGetters;
	ref CommonFuns commonFuns() scope return =>
		commonFunsAndDiagnostics.commonFuns;
	ref CommonTypes commonTypes() return scope =>
		*commonTypesPtr;
}
Config* configAtUri(in Program program, Uri uri) =>
	mustGet(program.allConfigs, uri);
Module* moduleAtUri(in Program program, Uri uri) =>
	mustGet(program.allModules, uri);

bool hasAnyDiagnostics(in Program a) =>
	existsDiagnostic(a, (in UriAndDiagnostic _) => true);
bool hasFatalDiagnostics(in Program a) =>
	existsDiagnostic(a, (in UriAndDiagnostic x) =>
		isFatal(getDiagnosticSeverity(x.kind)));

// Iterates in no particular order
void eachDiagnostic(in ProgramWithOptMain a, in void delegate(in UriAndDiagnostic) @safe @nogc pure nothrow cb) {
	bool res = existsDiagnostic(a, (in UriAndDiagnostic x) {
		cb(x);
		return false;
	});
	assert(!res);
}

private bool existsDiagnostic(
	in ProgramWithOptMain a,
	in bool delegate(in UriAndDiagnostic) @safe @nogc pure nothrow cb,
) =>
	(a.hasMain && exists!UriAndDiagnostic(a.asProgramWithMain.mainFunDiagnostics, cb)) ||
	existsDiagnostic(a.program, cb);

private bool existsDiagnostic(in Program a, in bool delegate(in UriAndDiagnostic) @safe @nogc pure nothrow cb) =>
	exists!UriAndDiagnostic(a.commonFunsAndDiagnostics.diagnostics, cb) ||
	existsInHashTable!(immutable Config*, Uri, getConfigUri)(a.allConfigs, (in Config* config) =>
		exists!Diagnostic(config.diagnostics, (in Diagnostic x) =>
			cb(UriAndDiagnostic(force(config.configUri), x)))) ||
	existsInHashTable!(immutable Module*, Uri, getModuleUri)(a.allModules, (in Module* module_) =>
		exists!ParseDiagnostic(module_.ast.parseDiagnostics, (in ParseDiagnostic x) =>
			cb(UriAndDiagnostic(UriAndRange(module_.uri, x.range), Diag(x.kind)))) ||
		exists!Diagnostic(module_.diagnostics, (in Diagnostic x) =>
			cb(UriAndDiagnostic(module_.uri, x))));

void eachTest(
	ref Program program,
	SymbolSet allExterns,
	TestSelector testSelector,
	in void delegate(Test*) @safe @nogc pure nothrow cb,
) {
	testSelector.matchWithPointers!void(
		(TestSelector.All) {
			foreach (immutable Module* m; program.allModules) {
				foreach (ref Test x; m.tests)
					if (allExterns.containsAll(x.externs))
						cb(&x);
			}
		},
		(Config* config) {
			foreach (immutable Module* m; program.allModules)
				if (m.config == config)
					foreach (ref Test x; m.tests)
						if (allExterns.containsAll(x.externs))
							cb(&x);

		},
		(Uri uri) {
			foreach (ref Test x; moduleAtUri(program, uri).tests)
				if (allExterns.containsAll(x.externs))
					cb(&x);
		},
		(Test* x) {
			assert(allExterns.containsAll(x.externs));
			cb(x);
		});
}

immutable struct Config {
	Opt!Uri configUri; // none for default config
	Diagnostic[] diagnostics;
	ConfigImportUris include;
	ConfigExternUris extern_;
}
Uri getConfigUri(in Config* a) =>
	force(a.configUri);
Config emptyConfig = Config(none!Uri, [], ConfigImportUris(), ConfigExternUris());
Config configForDiag(ref Alloc alloc, Uri uri, Diag diag) =>
	Config(some(uri), newArray(alloc, [Diagnostic(Range.empty, diag)]));

alias ConfigImportUris = Map!(Symbol, Uri);
alias ConfigExternUris = Map!(Symbol, Opt!Uri);

immutable struct LocalSource {
	immutable struct Generated { Symbol name; }
	mixin TaggedUnion!(DestructureAst.Single*, Generated*);
}

immutable struct Local {
	@safe @nogc pure nothrow:

	LocalSource source;
	LocalMutability mutability;
	Type type;

	Symbol name() scope =>
		source.matchIn!Symbol(
			(in DestructureAst.Single x) =>
				x.name.name,
			(in LocalSource.Generated x) =>
				x.name);

	bool isMutable() scope =>
		mutability.matchIn!bool(
			(in LocalMutability.Immutable) =>
				false,
			(in LocalMutability.MutableOnStack) =>
				true,
			(in LocalMutability.MutableAllocated) =>
				true);

	bool isAllocated() scope =>
		mutability.matchIn!bool(
			(in LocalMutability.Immutable) =>
				false,
			(in LocalMutability.MutableOnStack) =>
				false,
			(in LocalMutability.MutableAllocated) =>
				true);
}

Range localMustHaveNameRange(in Local a) =>
	a.source.as!(DestructureAst.Single*).nameRange;

private Range localMustHaveRange(in Local a) =>
	a.source.as!(DestructureAst.Single*).range;

immutable struct LocalMutability {
	@safe @nogc pure nothrow:
	immutable struct Immutable {}
	immutable struct MutableOnStack {}
	immutable struct MutableAllocated { StructInst* referenceType; }
	mixin Union!(Immutable, MutableOnStack, MutableAllocated);

	static LocalMutability immutable_() =>
		LocalMutability(LocalMutability.Immutable());
	static LocalMutability mutableOnStack() =>
		LocalMutability(LocalMutability.MutableOnStack());

	bool isImmutable() scope =>
		isA!Immutable;
}

enum Mutability { immut, mut }
Mutability toMutability(LocalMutability a) =>
	a.matchIn!Mutability(
		(in LocalMutability.Immutable) =>
			Mutability.immut,
		(in LocalMutability.MutableOnStack) =>
			Mutability.mut,
		(in LocalMutability.MutableAllocated) =>
			Mutability.mut);

immutable struct ClosureRef {
	@safe @nogc pure nothrow:

	PtrAndSmallNumber!LambdaExpr lambdaAndIndex;

	@system ulong asTaggable() =>
		lambdaAndIndex.asTaggable;
	@system static ClosureRef fromTagged(ulong x) =>
		ClosureRef(PtrAndSmallNumber!LambdaExpr.fromTagged(x));

	LambdaExpr* lambda() return scope =>
		lambdaAndIndex.ptr;

	ushort index() scope =>
		lambdaAndIndex.number;

	VariableRef variableRef() return scope =>
		lambda.closure[index];

	Local* local() return scope =>
		variableRef.local;

	ClosureReferenceKind closureReferenceKind() scope =>
		variableRef.closureReferenceKind;

	Symbol name() scope =>
		local.name;

	Type type() return scope =>
		local.type;
}

enum ClosureReferenceKind { direct, allocated }

immutable struct VariableRef {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(Local*, ClosureRef);

	Symbol name() scope =>
		local.name;
	LocalMutability mutability() scope =>
		local.mutability;
	Type type() return scope =>
		local.type;

	Local* local() return scope =>
		matchWithPointers!(Local*)(
			(Local* x) => x,
			(ClosureRef x) => x.local);
	ClosureReferenceKind closureReferenceKind() scope =>
		local.mutability.matchIn!ClosureReferenceKind(
			(in LocalMutability.Immutable) =>
				ClosureReferenceKind.direct,
			(in LocalMutability.MutableOnStack) =>
				assert(false),
			(in LocalMutability.MutableAllocated) =>
				ClosureReferenceKind.allocated);
}

immutable struct DestructureIgnoreSource {
	mixin Union!(CaseMemberAst*, StructDecl*, DestructureAst.Single*, DestructureAst.Void*);
}

immutable struct Destructure {
	@safe @nogc pure nothrow:

	// This can come from '_' or '()' (which is the same as '_ void')
	immutable struct Ignore {
		DestructureIgnoreSource source;
		Pos pos;
		Type type;
	}
	immutable struct Split {
		@safe @nogc pure nothrow:
		// This will be the type attempted to destructure.
		// If it can't be destructured, each of 'parts' will have a bogus type.
		Type destructuredType;
		SmallArray!Destructure parts;

		bool isValidDestructure(in CommonTypes commonTypes) scope {
			Opt!(Type[]) types = asTuple(commonTypes, destructuredType);
			return has(types) && force(types).length == parts.length;
		}
	}
	mixin TaggedUnion!(Ignore*, Local*, Split*);

	Opt!Symbol name() scope =>
		matchIn!(Opt!Symbol)(
			(in Destructure.Ignore _) =>
				none!Symbol,
			(in Local x) =>
				some(x.name),
			(in Destructure.Split _) =>
				none!Symbol);

	Range range() scope =>
		matchIn!Range(
			(in Ignore x) =>
				Range(x.pos, x.pos + 1),
			(in Local x) =>
				localMustHaveRange(x),
			(in Split x) =>
				combineRanges(x.parts[0].range, x.parts[$ - 1].range));

	Type type() scope =>
		matchIn!Type(
			(in Ignore x) =>
				x.type,
			(in Local x) =>
				x.type,
			(in Split x) =>
				x.destructuredType);
}
void eachLocal(Destructure a, in void delegate(Local*) @safe @nogc pure nothrow cb) {
	Opt!bool res = firstLocal!bool(a, (Local* x) {
		cb(x);
		return none!bool;
	});
	assert(!has(res));
}
Opt!Out firstLocal(Out)(Destructure a, in Opt!Out delegate(Local*) @safe @nogc pure nothrow cb) =>
	a.matchWithPointers!(Opt!Out)(
		(Destructure.Ignore*) =>
			none!Out,
		(Local* x) =>
			cb(x),
		(Destructure.Split* x) =>
			first!(Out, Destructure)(x.parts, (Destructure part) =>
				firstLocal!Out(part, cb)));

immutable struct DocComment {
	@safe @nogc pure nothrow:
	DocCommentAst ast;
	DocCommentReferences references;

	bool isEmpty() scope =>
		ast.isEmpty;
}

immutable struct DocCommentReference {
	immutable struct Bogus {}
	mixin Union!(
		Bogus,
		CalledSpecSig,
		EnumOrFlagsMember*,
		FunDecl*,
		Local*,
		RecordField*,
		Signature*,
		StructAlias*,
		StructDecl*,
		SpecDecl*,
		TypeParamIndex,
		VarDecl*);
}
alias DocCommentReferences = SmallArray!DocCommentReference;
DocCommentReferences emptyDocCommentReferences() =>
	emptySmallArray!DocCommentReference;

immutable struct Expr {
	@safe @nogc pure nothrow:
	ExprAst* ast;
	ExprKind kind;

	Range range() scope =>
		ast.range;
}

immutable struct ExprKind {
	mixin Union!(
		AssertOrForbidExpr*,
		BogusCallExpr,
		BogusExpr,
		BogusWrongTypeExpr,
		CallExpr,
		CallOptionExpr*,
		ClosureGetExpr,
		ClosureSetExpr,
		ExternExpr,
		FinallyExpr*,
		FunPointerExpr,
		IfExpr*,
		LambdaExpr*,
		LetExpr*,
		LiteralExpr,
		LiteralStringLikeExpr,
		LocalGetExpr,
		LocalPointerExpr,
		LocalSetExpr,
		LoopExpr*,
		LoopBreakExpr*,
		LoopContinueExpr,
		LoopWhileOrUntilExpr*,
		MatchEnumExpr*,
		MatchIntegralExpr*,
		MatchStringLikeExpr*,
		MatchSumTypeExpr*,
		RecordFieldPointerExpr*,
		SeqExpr*,
		ThrowExpr*,
		TrustedExpr*,
		TryExpr*,
		TryLetExpr*,
		TypedExpr*);
}
static assert(ExprKind.sizeof == CallExpr.sizeof + ulong.sizeof);

immutable struct ExprAndType {
	Expr expr;
	Type type;
}

immutable struct Condition {
	immutable struct UnpackOption {
		Destructure destructure;
		ExprAndType option;
	}
	mixin TaggedUnion!(Expr*, UnpackOption*);
}

immutable struct ExternCondition {
	bool isNegated;
	// If isNegated is set, this means !(x && y && ...)
	SymbolSet requiredExterns;
}
bool evalExternCondition(in ExternCondition a, in SymbolSet allExterns) =>
	a.isNegated ^ allExterns.containsAll(a.requiredExterns);
Opt!ExternCondition asExtern(in Condition a) =>
	a.isA!(Expr*)
		? asExtern(*a.as!(Expr*))
		: none!ExternCondition;
private Opt!ExternCondition asExtern(ref Expr a) {
	Expr e = skipTrusted(a);
	if (e.kind.isA!CallExpr) {
		CallExpr call = e.kind.as!CallExpr;
		if (isAnd(call.called)) {
			assert(call.args.length == 2);
			Opt!ExternCondition arg0 = asExtern(call.args[0]);
			Opt!ExternCondition arg1 = asExtern(call.args[1]);
			return optIf(has(arg0) && !force(arg0).isNegated && has(arg1) && !force(arg1).isNegated, () =>
				ExternCondition(false, force(arg0).requiredExterns | force(arg1).requiredExterns));
		} else if (isNot(call.called)) {
			Opt!SymbolSet names = asExternExpr(skipTrusted(only(call.args)));
			return optIf(has(names), () => ExternCondition(true, force(names)));
		} else
			return none!ExternCondition;
	} else {
		Opt!SymbolSet names = asExternExpr(e);
		return optIf(has(names), () => ExternCondition(false, force(names)));
	}
}
private bool isAnd(in Called a) =>
	isBuiltinFun(a, (in BuiltinFun x) =>
		x.isA!BuiltinBinaryLazy && x.as!BuiltinBinaryLazy == BuiltinBinaryLazy.boolAnd);
private bool isNot(in Called a) =>
	isBuiltinFun(a, (in BuiltinFun x) =>
		x.isA!BuiltinUnary && x.as!BuiltinUnary == BuiltinUnary.not);
private bool isBuiltinFun(in Called a, in bool delegate(in BuiltinFun) @safe @nogc pure nothrow cb) =>
	// A BuiltinFun body is never set late
	a.isA!(FunInst*) && a.as!(FunInst*).decl.bodyIsSet && isBuiltinFun(a.as!(FunInst*).decl.body_, cb);
private bool isBuiltinFun(in FunBody a, in bool delegate(in BuiltinFun) @safe @nogc pure nothrow cb) =>
	a.isA!BuiltinFun && cb(a.as!BuiltinFun);
private Opt!SymbolSet asExternExpr(in Expr a) =>
	optIf(a.kind.isA!ExternExpr, () => a.kind.as!ExternExpr.names);
private ref Expr skipTrusted(return ref Expr a) =>
	a.kind.isA!(TrustedExpr*) ? a.kind.as!(TrustedExpr*).inner : a;

immutable struct AssertOrForbidExpr {
	bool isForbid;
	Condition condition;
	Opt!(Expr*) thrown;
	Expr after;
}
private immutable struct PrefixAndRange {
	string prefix;
	Range range;
}
string defaultAssertOrForbidMessage(
	ref Alloc alloc,
	Uri curUri,
	in Expr expr,
	in AssertOrForbidExpr a,
	in FileContentGetters content,
) {
	PrefixAndRange x = expr.ast.kind.as!AssertOrForbidAst.condition.match!PrefixAndRange(
		(ref ExprAst condition) =>
			PrefixAndRange(
				a.isForbid ? "Forbidden expression is true: " : "Asserted expression is false: ",
				expr.ast.kind.as!AssertOrForbidAst.condition.range),
		(ref ConditionAst.UnpackOption unpack) =>
			PrefixAndRange(
				a.isForbid ? "Forbidden option is non-empty: " : "Asserted option is empty: ",
				unpack.option.range));
	return concatenate(alloc, x.prefix, content[UriAndRange(curUri, x.range)]);
}

immutable struct BogusExpr {}

// Wraps an expression that has an invalid type.
immutable struct BogusWrongTypeExpr {
	ExprRef inner;
}

immutable struct BogusCallExpr {
	SmallArray!CalledDecl candidates;
	// Note: It may have given up on checking arguments.
	SmallArray!ExprAndType checkedArgs;

	@safe @nogc pure nothrow this(SmallArray!CalledDecl cs, SmallArray!ExprAndType cas) {
		candidates = cs;
		checkedArgs = cas;
		assert(!isEmpty(candidates));
	}
}

immutable struct CallExpr {
	Called called;
	SmallArray!Expr args;
}

// Expression for 'x?.y' or 'x?[y]'
immutable struct CallOptionExpr {
	// May or may not return an option. If not it will be wrapped after calling.
	Called called;
	// Type is an option type. The option is unwrapped before calling.
	ExprAndType firstArg;
	// These are non-optional.
	SmallArray!Expr restArgs;
}

immutable struct ClosureGetExpr {
	@safe @nogc pure nothrow:
	ClosureRef closureRef;

	Local* local() return scope =>
		closureRef.local;
}

immutable struct ClosureSetExpr {
	@safe @nogc pure nothrow:
	ClosureRef closureRef;
	Expr* value;

	Local* local() return scope =>
		closureRef.local;
}

immutable struct ExternExpr {
	SymbolSet names;
}

bool isBuiltinExtern(Symbol a) =>
	has(asBuiltinExtern(a));
Opt!BuiltinExtern asBuiltinExtern(Symbol a) =>
	enumOfSymbol!BuiltinExtern(a);
immutable enum BuiltinExtern {
	DbgHelp,
	fake,
	js,
	libc,
	linux,
	native,
	posix,
	pthread,
	sodium,
	ucrtbase,
	unwind,
	windows,
}

immutable struct FinallyExpr {
	Expr right;
	Expr below;
}

immutable struct FunPointerExpr {
	Called called;
}

// Expression for an IfAst -- see that for all kinds of syntax this corresponds to
immutable struct IfExpr {
	@safe @nogc pure nothrow:
	Condition condition;
	Expr trueBranch;
	Expr falseBranch;

	ref Expr firstBranch(ExprAst* ast) return =>
		ast.kind.as!IfAst.isConditionNegated ? falseBranch : trueBranch;
	ref Expr secondBranch(ExprAst* ast) return =>
		ast.kind.as!IfAst.isConditionNegated ? trueBranch : falseBranch;
}

immutable struct LambdaExpr {
	@safe @nogc pure nothrow:

	enum Kind {
		data,
		shared_,
		mut,
		explicitShared,
	}

	Kind kind;
	Destructure param;
	Opt!(StructInst*) mutTypeForExplicitShared;
	private Late!Expr lateBody;
	private Late!(SmallArray!VariableRef) closure_;
	private Late!Type returnType_;

	void fillLate(Expr body_, SmallArray!VariableRef closure, Type returnType) {
		lateSet(lateBody, body_);
		lateSet(closure_, closure);
		lateSet(returnType_, returnType);
	}

	ref Expr body_() return scope =>
		lateGet(lateBody);
	SmallArray!VariableRef closure() return scope =>
		lateGet(closure_);
	Type returnType() return scope =>
		lateGet(returnType_);

	// We don't know whether this lambda is for the main body or for the optional 'else'.
	// But if it is from the `else`, this function will return true.
	bool isIgnore() scope =>
		param.isA!(Destructure.Ignore*) &&
		param.as!(Destructure.Ignore*).source.isA!(DestructureAst.Void*);
}

immutable struct LetExpr {
	Destructure destructure;
	Expr value;
	Expr then;
}

immutable struct LiteralExpr {
	Constant value;
}

immutable struct LiteralStringLikeExpr {
	@safe @nogc pure nothrow:

	enum Kind { char8Array, char32Array, cString, jsAny, string_, symbol }
	Kind kind;
	SmallString value; // For char32Array, this will be decoded in concretize.
}

immutable struct LocalGetExpr {
	Local* local;
}

immutable struct LocalPointerExpr {
	Local* local;
}

immutable struct LocalSetExpr {
	Local* local;
	Expr* value;
}

immutable struct LoopExpr {
	Expr body_;
}

immutable struct LoopBreakExpr {
	LoopExpr* loop;
	Expr value;
}

immutable struct LoopContinueExpr {
	LoopExpr* loop;
}

immutable struct LoopWhileOrUntilExpr {
	bool isUntil;
	Condition condition;
	Expr body_; // Always of type 'void'
	Expr after;
}

immutable struct MatchEnumExpr {
	@safe @nogc pure nothrow:

	ExprAndType matched;
	immutable struct Case {
		immutable EnumOrFlagsMember* member;
		Expr then;
	}
	SmallArray!Case cases;
	Opt!Expr else_;

	StructDecl* enum_() {
		StructInst* inst = matched.type.as!(StructInst*);
		assert(isEmpty(inst.typeArgs));
		StructDecl* res = inst.decl;
		assert(every!Case(cases, (in Case x) => x.member.containingEnum == res));
		return res;
	}

	StructBody.Enum* enumBody() =>
		enum_.body_.as!(StructBody.Enum*);
}

Range caseNameRange(in Expr matchExpr, size_t caseIndex) {
	assert(
		matchExpr.kind.isA!(MatchEnumExpr*) ||
		matchExpr.kind.isA!(MatchSumTypeExpr*) ||
		matchExpr.kind.isA!(TryExpr*));
	SmallArray!CaseAst cases = matchExpr.ast.kind.isA!TryAst
		? matchExpr.ast.kind.as!TryAst.catches
		: matchExpr.ast.kind.as!MatchAst.cases;
	return cases[caseIndex].member.nameRange;
}

// Match on charX, intX, natX type
immutable struct MatchIntegralExpr {
	immutable struct Kind {
		@safe @nogc pure nothrow:
		mixin TaggedUnion!(CharType, IntegralType);
		bool isSigned() =>
			match!bool(
				(CharType _) => false,
				(IntegralType x) => .isSigned(x));
	}
	immutable struct Case {
		IntegralValue value;
		Expr then;
	}
	Kind kind;
	ExprAndType matched;
	SmallArray!Case cases;
	Expr else_;
}

// Match on symbol, string, char8 array, char8[], char32 array, char32[]
immutable struct MatchStringLikeExpr {
	immutable struct Case {
		string value;
		Expr then;
	}

	LiteralStringLikeExpr.Kind kind;
	ExprAndType matched;
	Called equals; // == function for the type
	SmallArray!Case cases;
	Expr else_;
}

immutable struct MatchSumTypeExpr {
	@safe @nogc pure nothrow:

	ExprAndType matched;
	SmallArray!MatchSumTypeCase cases;
	Opt!(Expr*) else_;

	StructInst* sumType() return scope =>
		matched.type.as!(StructInst*);
	StructBody.SumType sumTypeBody() return scope =>
		sumType.decl.body_.as!(StructBody.SumType);
	bool isUnion() {
		final switch (sumTypeBody.kind) {
			case SumTypeKind.interface_:
				assert(false);
			case SumTypeKind.union_:
				return true;
			case SumTypeKind.variant:
				return false;
		}
	}
}
immutable struct MatchSumTypeCase {
	@safe @nogc pure nothrow:
	Destructure destructure;
	Expr then;

	StructInst* member() return scope =>
		destructure.type.as!(StructInst*);
}

immutable struct RecordFieldPointerExpr {
	@safe @nogc pure nothrow:

	ExprAndType target; // This will be a pointer or by-ref type
	RecordField* field;

	StructDecl* recordDecl() scope =>
		isPointerConstOrMut(target.type)
			? pointeeType(target.type).as!(StructInst*).decl
			: target.type.as!(StructInst*).decl;

	size_t fieldIndex() =>
		mustHaveIndexOfPointer(recordDecl.body_.as!(StructBody.Record).fields, field);
}

immutable struct SeqExpr {
	Expr first;
	Expr then;
}

immutable struct ThrowExpr {
	Expr thrown;
}

immutable struct TrustedExpr {
	Expr inner;
}

immutable struct TryExpr {
	Expr tried;
	SmallArray!MatchSumTypeCase catches;
}

immutable struct TryLetExpr {
	Destructure destructure;
	Expr value;
	MatchSumTypeCase catch_;
	Expr then;
}

immutable struct TypedExpr {
	Expr inner;
}

alias Visibility = immutable Visibility_;
private enum Visibility_ : ubyte {
	private_,
	internal,
	public_,
}
string stringOfVisibility(Visibility a) =>
	stringOfEnum(a);

enum ExportVisibility : ubyte {
	internal,
	public_
}

bool importCanSee(ExportVisibility importVisibility, Visibility exportVisibility) =>
	enumConvertOrAssert!ExportVisibility(exportVisibility) >= importVisibility;

Visibility leastVisibility(Visibility a, Visibility b) =>
	min(a, b);
Visibility greatestVisibility(Visibility a, Visibility b) =>
	max(a, b);

Opt!Called getCalledAtExpr(in ExprKind x) =>
	x.isA!CallExpr
		? some(x.as!CallExpr.called)
		: x.isA!(CallOptionExpr*)
		? some(x.as!(CallOptionExpr*).called)
		: x.isA!FunPointerExpr
		? some(x.as!FunPointerExpr.called)
		: none!Called;

immutable struct ExprRef {
	Expr* expr;
	Type type;
}
ExprAndType toExprAndType(return scope ExprRef a) =>
	ExprAndType(*a.expr, a.type);

ExprRef funBodyExprRef(FunDecl* a) =>
	ExprRef(&a.body_.as!Expr(), a.returnType);
ExprRef testBodyExprRef(ref CommonTypes commonTypes, Test* a) =>
	ExprRef(&a.body_, Type(commonTypes.void_));

void eachDescendentExprIncluding(
	ref CommonTypes commonTypes,
	ExprRef a,
	in void delegate(ExprRef) @safe @nogc pure nothrow cb,
) {
	cb(a);
	eachDescendentExprExcluding(commonTypes, a, cb);
}

void eachDescendentExprExcluding(
	ref CommonTypes commonTypes,
	ExprRef a,
	in void delegate(ExprRef) @safe @nogc pure nothrow cb,
) {
	eachDirectChildExpr(commonTypes, a, (ExprRef x) {
		eachDescendentExprIncluding(commonTypes, x, cb);
	});
}

void eachDirectChildExpr(
	ref CommonTypes commonTypes,
	ExprRef a,
	in void delegate(ExprRef) @safe @nogc pure nothrow cb,
) {
	Opt!bool res = findDirectChildExpr!bool(commonTypes, a, (ExprRef x) {
		cb(x);
		return none!bool;
	});
	assert(!has(res));
}

Opt!T findDirectChildExpr(T)(
	ref CommonTypes commonTypes,
	ExprRef a,
	in Opt!T delegate(ExprRef) @safe @nogc pure nothrow cb,
) {
	Type boolType = Type(commonTypes.bool_);
	Type exceptionType = Type(commonTypes.exception);
	Type voidType = Type(commonTypes.void_);
	ExprRef sameType(Expr* x) =>
		ExprRef(x, a.type);
	ExprRef toRef(ExprAndType* x) =>
		ExprRef(&x.expr, x.type);

	ExprRef directChildInCondition(Condition cond) =>
		cond.matchWithPointers!ExprRef(
			(Expr* x) =>
				ExprRef(x, boolType),
			(Condition.UnpackOption* x) =>
				toRef(&x.option));
	Opt!T directChildInMatchSumTypeCases(MatchSumTypeCase[] cases) =>
		firstPointer!(T, MatchSumTypeCase)(cases, (MatchSumTypeCase* x) =>
			cb(sameType(&x.then)));

	return a.expr.kind.matchWithPointers!(Opt!T)(
		(AssertOrForbidExpr* x) =>
			optOr!T(
				cb(directChildInCondition(x.condition)),
				() => has(x.thrown) ? cb(ExprRef(force(x.thrown), exceptionType)) : none!T,
				() => cb(sameType(&x.after))),
		(BogusCallExpr _) =>
			none!T,
		(BogusExpr _) =>
			none!T,
		(BogusWrongTypeExpr x) =>
			cb(x.inner),
		(CallExpr x) {
			assert(typesCompatible(a.type, x.called.returnType));
			if (x.called.isVariadic) {
				Type argType = arrayElementType(only(x.called.paramTypes));
				return firstPointer!(T, Expr)(x.args, (Expr* e) => cb(ExprRef(e, argType)));
			} else
				return firstZipPointerFirst!(T, Expr, Type)(x.args, x.called.paramTypes, (Expr* e, Type t) =>
					cb(ExprRef(e, t)));
		},
		(CallOptionExpr* x) =>
			optOr!T(
				cb(toRef(&x.firstArg)),
				() => firstZipPointerFirst!(T, Expr, Type)(x.restArgs, x.called.paramTypes[1 .. $], (Expr* e, Type t) =>
					cb(ExprRef(e, t)))),
		(ClosureGetExpr x) {
			assert(a.type == x.local.type);
			return none!T;
		},
		(ClosureSetExpr x) {
			assert(a.type == voidType || a.type.isBogus);
			return cb(ExprRef(x.value, x.local.type));
		},
		(ExternExpr x) =>
			none!T,
		(FinallyExpr* x) =>
			optOr!T(
				cb(ExprRef(&x.right, voidType)),
				() => cb(sameType(&x.below))),
		(FunPointerExpr _) =>
			none!T,
		(IfExpr* x) =>
			optOr!T(
				cb(directChildInCondition(x.condition)),
				() => cb(sameType(&x.firstBranch(a.expr.ast))),
				() => cb(sameType(&x.secondBranch(a.expr.ast)))),
		(LambdaExpr* x) =>
			cb(ExprRef(&x.body_(), x.returnType)),
		(LetExpr* x) =>
			optOr!T(cb(ExprRef(&x.value, x.destructure.type)), () => cb(sameType(&x.then))),
		(LiteralExpr _) =>
			none!T,
		(LiteralStringLikeExpr _) =>
			none!T,
		(LocalGetExpr x) {
			assert(typesCompatible(a.type, x.local.type));
			return none!T;
		},
		(LocalPointerExpr _) =>
			none!T,
		(LocalSetExpr x) {
			assert(a.type == voidType);
			return cb(ExprRef(x.value, x.local.type));
		},
		(LoopExpr* x) =>
			cb(sameType(&x.body_)),
		(LoopBreakExpr* x) =>
			cb(sameType(&x.value)),
		(LoopContinueExpr _) =>
			none!T,
		(LoopWhileOrUntilExpr* x) =>
			optOr!T(
				cb(directChildInCondition(x.condition)),
				() => cb(ExprRef(&x.body_, voidType)),
				() => cb(sameType(&x.after))),
		(MatchEnumExpr* x) =>
			optOr!T(
				cb(toRef(&x.matched)),
				() => firstPointer!(T, MatchEnumExpr.Case)(x.cases, (MatchEnumExpr.Case* y) => cb(sameType(&y.then))),
				() => has(x.else_) ? cb(sameType(&force(x.else_))) : none!T),
		(MatchIntegralExpr* x) =>
			optOr!T(
				cb(toRef(&x.matched)),
				() => firstPointer!(T, MatchIntegralExpr.Case)(x.cases, (MatchIntegralExpr.Case* y) =>
					cb(sameType(&y.then))),
				() => cb(sameType(&x.else_))),
		(MatchStringLikeExpr* x) =>
			optOr!T(
				cb(toRef(&x.matched)),
				() => firstPointer!(T, MatchStringLikeExpr.Case)(x.cases, (MatchStringLikeExpr.Case* y) =>
					cb(sameType(&y.then))),
				() => cb(sameType(&x.else_))),
		(MatchSumTypeExpr* x) =>
			optOr!T(
				cb(toRef(&x.matched)),
				() => directChildInMatchSumTypeCases(x.cases),
				() => has(x.else_) ? cb(sameType(force(x.else_))) : none!T),
		(RecordFieldPointerExpr* x) =>
			cb(toRef(&x.target)),
		(SeqExpr* x) =>
			optOr!T(cb(ExprRef(&x.first, voidType)), () => cb(sameType(&x.then))),
		(ThrowExpr* x) =>
			cb(ExprRef(&x.thrown, exceptionType)),
		(TrustedExpr* x) =>
			cb(sameType(&x.inner)),
		(TryExpr* x) =>
			optOr!T(cb(sameType(&x.tried)), () => directChildInMatchSumTypeCases(x.catches)),
		(TryLetExpr* x) =>
			optOr!T(
				cb(ExprRef(&x.value, x.destructure.type)),
				() => cb(sameType(&x.catch_.then)),
				() => cb(sameType(&x.then))),
		(TypedExpr* x) =>
			cb(sameType(&x.inner)));
}
private bool typesCompatible(in Type a, in Type b) =>
	a == b || a.isBogus || b.isBogus || (
		a.isA!(StructInst*) && b.isA!(StructInst*) && a.as!(StructInst*).decl == b.as!(StructInst*).decl &&
		arraysCorrespond!(Type, Type)(
			a.as!(StructInst*).typeArgs,
			b.as!(StructInst*).typeArgs,
			(ref Type x, ref Type y) => typesCompatible(x, y)));

FunDecl* sumTypeMemberGetter(FunDecl[] funs, in StructDecl* struct_, in SumTypeMembership x) =>
	mustFindFunNamed(funs, struct_.name, (in FunDecl fun) =>
		fun.body_.isA!(FunBody.SumTypeMemberGet) &&
		only(paramsArray(fun.params)).type == Type(x.sumType) &&
		fun.source.as!(StructDecl*) == struct_);
FunDecl* methodCaller(ref Program program, in Signature* a) =>
	mustFindFunNamed(moduleAtUri(program, a.moduleUri), a.name, (in FunDecl fun) =>
		fun.source.isA!(Signature*) &&
		fun.source.as!(Signature*) == a);

FunDecl* mustFindFunNamed(in Module* module_, Symbol name, in bool delegate(in FunDecl) @safe @nogc pure nothrow cb) =>
	mustFindFunNamed(module_.funs, name, cb);
private FunDecl* mustFindFunNamed(
	FunDecl[] funs,
	Symbol name,
	in bool delegate(in FunDecl) @safe @nogc pure nothrow cb,
) =>
	mustFindPointer!FunDecl(funs, (ref FunDecl fun) => fun.name == name && cb(fun));
