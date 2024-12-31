module model.model;

@safe @nogc pure nothrow:

import model.ast :
	ArrowAccessAst,
	AssertOrForbidAst,
	AssignmentAst,
	AssignmentCallAst,
	CallAst,
	CallNamedAst,
	CaseMemberAst,
	DestructureAst,
	DocCommentAst,
	EnumOrFlagsMemberAst,
	EmptyAst,
	ExprAst,
	ExternAst,
	FileAst,
	FinallyAst,
	ForAst,
	FunDeclAst,
	IfAst,
	ImportOrExportAst,
	InterpolatedAst,
	LambdaAst,
	LetAst,
	LoopAst,
	LoopBreakAst,
	LoopContinueAst,
	LoopWhileOrUntilAst,
	MatchAst,
	ModifierKeyword,
	ModifierKeywordAst,
	NameAndRange,
	PtrAst,
	RecordFieldAst,
	SingleDestructureAst,
	SpecDeclAst,
	SignatureAst,
	StructAliasAst,
	StructDeclAst,
	TestAst,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypedAst,
	UnpackOptionAst,
	VarDeclAst,
	VoidDestructureAst,
	WithAst;
import model.integralValues : IntegralValue;
import model.parseDiag : ParseDiag, ParseDiagnostic, ReadFileDiag;
import model.sourceRange :
	combineRanges, FileContentGetters, LineAndCharacterGetters, LineAndColumnGetters, Pos, Range, UriAndRange;
import util.alloc.alloc : Alloc;
import util.col.array :
	arrayOfSingle,
	concatenate,
	emptySmallArray,
	every,
	exists,
	first,
	firstPointer,
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
import util.late : Late, lateGet, lateIsSet, lateSet, lateSetOverwrite;
import util.opt : force, has, none, Opt, optEqual, optIf, optOr, optOrDefault, some;
import util.string : SmallString;
import util.symbol : enumOfSymbol, Symbol, symbol, symbolOfEnum;
import util.symbolSet : buildSymbolSet, emptySymbolSet, SymbolSet, symbolSet, SymbolSetBuilder;
import util.union_ : IndexType, TaggedUnion, Union;
import util.uri : RelPath, Uri;
import util.util : enumConvertOrAssert, max, min, optEnumConvert, stringOfEnum;
import versionInfo : OS, VersionFun;

public import model.ast : FunKind, stringOfVarKindLowerCase, stringOfVarKindUpperCase, SumTypeKind, VarKind, Visibility;

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
	mixin TaggedUnion!(BogusType, TypeParamIndex, StructInst*);

	static Type bogus() =>
		Type(BogusType());

	bool isBogus() scope =>
		isA!BogusType;

	bool opEquals(scope Type b) scope =>
		taggedPointerEquals(b);
}
immutable struct BogusType {}

bool isEmptyType(in Type a) =>
	a.isA!(StructInst*) && isEmptyType(*a.as!(StructInst*));
bool isEmptyType(in StructInst a) =>
	isVoid(*a.decl) || isEmptyRecord(*a.decl);
private bool isEmptyRecord(in StructDecl a) =>
	a.body_.isA!Record && isEmpty(a.body_.as!Record.fields);

bool isEnum(in Type a) =>
	a.isA!(StructInst*) && a.as!(StructInst*).decl.body_.isA!(Enum*);
bool isFlags(in Type a) =>
	a.isA!(StructInst*) && a.as!(StructInst*).decl.body_.isA!Flags;

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

Opt!Type tryUnwrapOptionType(Type optionType) =>
	isOptionType(optionType) || optionType.isBogus
		? some(mustUnwrapOptionTypeOrBogus(optionType))
		: none!Type;

Type mustUnwrapOptionTypeOrBogus(Type a) =>
	a.isBogus
		? Type.bogus
		: mustUnwrapOptionType(a);

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
Type pointeeType(in Type a) =>
	pointeeType(*a.as!(StructInst*));
Type pointeeType(in StructInst a) {
	assert(isPointerConstOrMut(*a.decl));
	return only(a.typeArgs);
}

PurityRange purityRange(Type a) =>
	a.matchIn!PurityRange(
		(in BogusType _) =>
			PurityRange(Purity.data, Purity.data),
		(in TypeParamIndex _) =>
			PurityRange(Purity.data, Purity.mut),
		(in StructInst x) =>
			x.purityRange);

Purity bestCasePurity(Type a) =>
	purityRange(a).bestCase;

LinkageRange linkageRange(Type a) =>
	a.matchIn!LinkageRange(
		(in BogusType _) =>
			LinkageRange(Linkage.extern_, Linkage.extern_),
		(in TypeParamIndex _) =>
			LinkageRange(Linkage.internal, Linkage.extern_),
		(in StructInst x) =>
			x.linkageRange);

immutable struct Params {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(SmallArray!Destructure, Varargs*);

	static Params empty() =>
		Params(emptySmallArray!Destructure);

	Arity arity() scope =>
		matchIn!Arity(
			(in Destructure[] params) =>
				Arity(safeToUint(params.length)),
			(in Varargs _) =>
				Arity(ArityVarargs()));
}
immutable struct Varargs {
	Destructure param;
	Type elementType;
}
bool isEmpty(in Params a) =>
	isEmpty(a.arity);

SmallArray!Destructure paramsArray(return scope Params a) =>
	a.matchWithPointers!(SmallArray!Destructure)(
		(Destructure[] x) =>
			small!Destructure(x),
		(Varargs* x) =>
			small!Destructure(arrayOfSingle(&x.param)));

Destructure[] assertNonVariadic(Params a) =>
	a.as!(Destructure[]);

private immutable struct Arity {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(immutable uint, ArityVarargs);

	uint countParamDecls() scope =>
		matchIn!uint(
			(in uint x) => x,
			(in ArityVarargs _) => 1);

	bool isVariadic() scope =>
		isA!ArityVarargs;
}
immutable struct ArityVarargs {}
bool isEmpty(in Arity a) =>
	a.match!bool(
		(uint nParams) =>
			nParams == 0,
		(ArityVarargs _) =>
			false);

bool arityMatches(in Arity sigArity, size_t nArgs) =>
	sigArity.match!bool(
		(uint nParams) =>
			nParams == nArgs,
		(ArityVarargs _) =>
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
			mustHaveIndexOfPointer(variant.body_.as!SumType.methods, a));

immutable struct TypeParamsAndSig {
	TypeParams typeParams;
	Type returnType;
	ParamsShort params;
	uint countSpecs;
}
immutable struct ParamsShort {
	mixin TaggedUnion!(SmallArray!ParamShort, ParamsShortVariadic*);
}
immutable struct ParamsShortVariadic { ParamShort param; Type elementType; }
immutable struct ParamShort {
	Symbol name;
	Type type;
}

immutable struct RecordFieldSource {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(SingleDestructureAst*, RecordFieldAst*);

	DocCommentAst docComment() scope =>
		match!DocCommentAst(
			(ref SingleDestructureAst _) =>
				DocCommentAst.empty,
			(ref RecordFieldAst x) =>
				x.docComment);

	Symbol name() scope =>
		matchIn!Symbol(
			(in SingleDestructureAst x) =>
				x.name.name,
			(in RecordFieldAst x) =>
				x.name.name);

	Range range() scope =>
		matchIn!Range(
			(in SingleDestructureAst x) =>
				x.range,
			(in RecordFieldAst x) =>
				x.range);

	Range nameRange() scope =>
		matchIn!Range(
			(in SingleDestructureAst x) =>
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
	mixin TaggedUnion!(EnumOrFlagsMemberAst*, SingleDestructureAst*);

	DocCommentAst docComment() return scope =>
		match!DocCommentAst(
			(ref EnumOrFlagsMemberAst x) =>
				x.docComment,
			(ref SingleDestructureAst x) =>
				DocCommentAst.empty);
	Symbol name() scope =>
		matchIn!Symbol(
			(in EnumOrFlagsMemberAst x) => x.name,
			(in SingleDestructureAst x) => x.name.name);
	Range range() scope =>
		matchIn!Range(
			(in EnumOrFlagsMemberAst x) => x.range,
			(in SingleDestructureAst x) => x.range);
	Range nameRange() scope =>
		matchIn!Range(
			(in EnumOrFlagsMemberAst x) => x.nameRange,
			(in SingleDestructureAst x) => x.nameRange);
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

	IntegralType storage() scope =>
		containingEnum.body_.isA!(Enum*)
			? containingEnum.body_.as!(Enum*).storage
			: containingEnum.body_.as!Flags.storage;
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
	mixin Union!(StructBodyBogus, BuiltinType, Enum*, ExternType, Flags, Record, SumType);
}
immutable struct StructBodyBogus {}
immutable struct Enum {
	IntegralType storage;
	SmallArray!EnumOrFlagsMember members;
	HashTable!(EnumOrFlagsMember*, Symbol, nameOfEnumOrFlagsMember) membersByName;
}
immutable struct ExternType {
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
static assert(StructBody.sizeof == Record.sizeof + size_t.sizeof);

SumTypeMemberAndMethodImpls[] asUnion(ref StructBody a) =>
	asUnion(a.as!SumType);
SumTypeMemberAndMethodImpls[] asUnion(ref SumType a) {
	assert(a.kind == SumTypeKind.union_);
	return a.listedMembers;
}

Symbol nameOfEnumOrFlagsMember(in EnumOrFlagsMember* a) =>
	a.name;

IntegralValue getAllFlagsValue(in Flags body_) =>
	fold!(IntegralValue, EnumOrFlagsMember)(
		IntegralValue(0),
		body_.members,
		(IntegralValue a, in EnumOrFlagsMember b) =>
			a | b.value);

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
			(ref StructDeclSourceBogus _) =>
				DocCommentAst.empty);
	DocComment docComment() return scope =>
		DocComment(docCommentAst, docCommentReferences);
	TypeParams typeParams() return scope =>
		source.match!TypeParams(
			(ref StructDeclAst x) =>
				x.typeParams,
			(ref StructDeclSourceBogus x) =>
				x.typeParams);
	Symbol name() scope =>
		source.matchIn!Symbol(
			(in StructDeclAst x) =>
				x.name.name,
			(in StructDeclSourceBogus x) =>
				x.name);

	UriAndRange range() scope =>
		UriAndRange(moduleUri, source.matchIn!Range(
			(in StructDeclAst x) =>
				x.range,
			(in StructDeclSourceBogus _) =>
				Range.empty));

	UriAndRange keywordRange() scope =>
		UriAndRange(moduleUri, source.keywordRange);

	UriAndRange nameRange() scope =>
		UriAndRange(moduleUri, source.nameRange);

	bool isTemplate() scope =>
		!isEmpty(typeParams);
}

EnumOrFlagsMember[] mustBeEnumOrFlags(in StructDecl a) =>
	a.body_.isA!(Enum*) ? a.body_.as!(Enum*).members : a.body_.as!Flags.members;

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

	ModifierKeywordAst* ast;
	StructInst* sumType;
	private Late!(SmallArray!(Opt!Called)) methodImpls_;

	SmallArray!(Opt!Called) methodImpls() return scope =>
		lateGet(methodImpls_);
	void methodImpls(SmallArray!(Opt!Called) value) =>
		lateSet(methodImpls_, value);

	ref SumType sumTypeBody() return scope =>
		sumType.decl.body_.as!SumType;

	SumTypeKind sumTypeKind() scope =>
		sumTypeBody.kind;
	SmallArray!Signature sumTypeDeclMethods() =>
		sumTypeBody.methods;
}

immutable struct StructDeclSource {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(StructDeclAst*, StructDeclSourceBogus*);

	Range keywordRange() scope =>
		matchIn!Range(
			(in StructDeclAst x) =>
				x.keywordRange,
			(in StructDeclSourceBogus _) =>
				Range.empty);

	Range nameRange() scope =>
		matchIn!Range(
			(in StructDeclAst x) =>
				x.nameRange,
			(in StructDeclSourceBogus _) =>
				Range.empty);
}
immutable struct StructDeclSourceBogus {
	Symbol name;
	TypeParams typeParams;
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
	return body_.isA!Record &&
		optEqual!ByValOrRef(body_.as!Record.flags.forcedByValOrRef, some(ByValOrRef.byRef));
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

immutable struct AutoFun {
	AutoFunKind kind;
	Called[] members; // e.g., '<=>' implementations for each record/union member
}
enum AutoFunKind {
	compare,
	enumOrFlagsMembers,
	enumOrFlagsToIntegral,
	enumToSymbol,
	equals,
	flagsToSymbolArray,
	integralToOptEnumOrFlags,
	symbolToOptEnumOrFlags,
	toJson
}

immutable struct FunBody {
	@safe @nogc pure nothrow:
	mixin Union!(
		FunBodyBogus,
		AutoFun,
		BuiltinFun,
		CreateEnumOrFlags,
		CreateExtern,
		CreateRecord,
		CreateRecordAndConvertToSumType,
		CreateSumType,
		Expr,
		FunBodyExtern,
		FunBodyFileImport,
		FlagsFunction,
		FunBodyMethod,
		RecordFieldCall,
		RecordFieldGet,
		RecordFieldPointer,
		RecordFieldSet,
		SumTypeMemberGet,
		VarGet,
		VarSet);

	static FunBody bogus() =>
		FunBody(FunBodyBogus());
}
static assert(FunBody.sizeof == ulong.sizeof + Expr.sizeof);

private bool isGenerated(in FunBody a) scope =>
	!a.isA!FunBodyBogus &&
	!a.isA!AutoFun &&
	!a.isA!BuiltinFun &&
	!a.isA!Expr &&
	!a.isA!FunBodyExtern &&
	!a.isA!FunBodyFileImport;

immutable struct FunBodyBogus {}
immutable struct CreateEnumOrFlags {
	EnumOrFlagsMember* member;
}
immutable struct CreateExtern {}
immutable struct CreateRecord {}
immutable struct CreateRecordAndConvertToSumType {
	StructInst* member; // This is the sumType member type, and the record type
}
immutable struct CreateSumType {}
immutable struct FunBodyExtern {
	Symbol libraryName;
}
immutable struct FunBodyFileImport {
	ImportFileContent content;
}
immutable struct FunBodyMethod {
	@safe @nogc pure nothrow:
	Signature* method;
}
ref SumType sumType(in FunBodyMethod a, in FunDecl fun) scope {
	assert(fun.body_.as!FunBodyMethod() == a);
	return fun.params.as!(Destructure[])[0].type.as!(StructInst*).decl.body_.as!SumType;
}
size_t methodIndex(in FunBodyMethod a, in FunDecl fun) scope =>
	mustHaveIndexOfPointer(sumType(a, fun).methods, a.method);

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
	require,
	set,
	typeof_,
}

immutable struct BuiltinFun {
	mixin Union!(
		BuiltinFunAllTests,
		BuiltinUnary,
		BuiltinUnaryMath,
		BuiltinBinary,
		BuiltinBinaryLazy,
		BuiltinBinaryMath,
		BuiltinTernary,
		Builtin4ary,
		BuiltinFunCallLambda,
		BuiltinFunCallFunPointer,
		BuiltinFunConstant,
		BuiltinFunGcSafeValue,
		BuiltinFunInit,
		JsFun,
		BuiltinFunMarkRoot,
		BuiltinFunMarkVisit,
		BuiltinFunNewEmptyOption,
		BuiltinFunNewNonEmptyOption,
		BuiltinFunPointerCast,
		BuiltinFunSizeOf,
		BuiltinFunStaticSymbols,
		VersionFun);
}
immutable struct BuiltinFunAllTests {}
immutable struct BuiltinFunCallLambda {}
immutable struct BuiltinFunCallFunPointer {}
immutable struct BuiltinFunConstant {
	// double includes constant float32s too
	mixin Union!(bool, double, BuiltinFunConstantNull, BuiltinFunConstantVoid);
}
immutable struct BuiltinFunConstantNull {}
immutable struct BuiltinFunConstantVoid {}
immutable struct BuiltinFunGcSafeValue {}
enum BuiltinFunInit { global, perThread }
immutable struct BuiltinFunMarkRoot {}
immutable struct BuiltinFunMarkVisit {}
immutable struct BuiltinFunNewEmptyOption {}
immutable struct BuiltinFunNewNonEmptyOption {}
immutable struct BuiltinFunPointerCast {}
immutable struct BuiltinFunSizeOf {}
immutable struct BuiltinFunStaticSymbols {}

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
	FunSafety safety;
	bool okIfUnused;
	bool forceCtx;

	FunFlags withOkIfUnused() =>
		FunFlags(bare, summon, safety, true, forceCtx);
	FunFlags withSummon() =>
		withSummon(true);
	FunFlags withSummon(bool value) =>
		FunFlags(bare, value, safety, okIfUnused, forceCtx);

	static FunFlags regular(bool bare, bool summon, FunSafety safety, bool forceCtx) =>
		FunFlags(bare, summon, safety, false, forceCtx);

	static FunFlags none() =>
		FunFlags(safety: FunSafety.safe);
	static FunFlags generatedBare() =>
		FunFlags(bare: true, safety: FunSafety.safe, okIfUnused: true);
	static FunFlags generatedBareUnsafe() =>
		FunFlags(bare: true, safety: FunSafety.unsafe, okIfUnused: true);
	static FunFlags generated() =>
		FunFlags(safety: FunSafety.safe, okIfUnused: true);
}
static assert(FunFlags.sizeof == 5);

enum FunSafety : ubyte { safe, trusted, unsafe }

immutable struct FunDeclSource {
	@safe @nogc pure nothrow:

	mixin Union!(
		FunSourceBogus,
		FunSourceAst,
		EnumOrFlagsMember*,
		FunSourceFileImport,
		RecordField*,
		// This is for a variant method
		Signature*,
		StructDecl*,
		VarDecl*);

	Uri moduleUri() scope =>
		matchIn!Uri(
			(in FunSourceBogus x) =>
				x.uri,
			(in FunSourceAst x) =>
				x.moduleUri,
			(in EnumOrFlagsMember x) =>
				x.moduleUri,
			(in FunSourceFileImport x) =>
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
			(in FunSourceBogus x) =>
				UriAndRange(x.uri, Range.empty),
			(in FunSourceAst x) =>
				UriAndRange(x.moduleUri, x.ast.range),
			(in EnumOrFlagsMember x) =>
				UriAndRange(x.moduleUri, x.range),
			(in FunSourceFileImport x) =>
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
			(in FunSourceBogus x) =>
				UriAndRange(x.uri, Range.empty),
			(in FunSourceAst x) =>
				UriAndRange(x.moduleUri, x.ast.nameRange),
			(in EnumOrFlagsMember x) =>
				x.nameRange,
			(in FunSourceFileImport x) =>
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
		isA!FunSourceAst
			? as!FunSourceAst.ast.docComment
			: DocCommentAst.empty;
}
immutable struct FunSourceBogus {
	Uri uri;
	TypeParams typeParams;
}
immutable struct FunSourceAst {
	Uri moduleUri;
	FunDeclAst* ast;
}
immutable struct FunSourceFileImport {
	Uri moduleUri; // This is the importing module, not imported
	ImportOrExportAst* ast;
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
			(FunSourceBogus x) =>
				x.typeParams,
			(FunSourceAst x) =>
				x.ast.typeParams,
			(ref EnumOrFlagsMember x) =>
				x.containingEnum.typeParams,
			(FunSourceFileImport _) =>
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
		body_.isA!FunBodyExtern ? Linkage.extern_ : Linkage.internal;

	bool isBare() scope =>
		flags.bare;
	bool isBareOrForceCtx() scope =>
		flags.bare || flags.forceCtx;
	bool isGenerated() scope =>
		.isGenerated(body_);
	bool isSummon() scope =>
		flags.summon;
	bool isUnsafe() scope =>
		flags.safety == FunSafety.unsafe;
	bool okIfUnused() scope =>
		flags.okIfUnused;

	bool isVariadic() scope =>
		params.isA!(Varargs*);

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

	mixin TaggedUnion!(CalledBogus*, FunInst*, CalledSpecSig);

	CalledDecl calledDecl() return scope =>
		match!CalledDecl(
			(ref CalledBogus x) =>
				x.decl,
			(ref FunInst x) =>
				CalledDecl(x.decl),
			(CalledSpecSig x) =>
				CalledDecl(x));

	Symbol name() scope =>
		calledDecl.name;

	Type returnType() scope =>
		match!Type(
			(ref CalledBogus x) =>
				x.returnType,
			(ref FunInst f) =>
				f.returnType,
			(CalledSpecSig s) =>
				s.instantiatedSig.returnType);

	Type[] paramTypes() scope =>
		match!(Type[])(
			(ref CalledBogus x) =>
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
immutable struct CalledBogus {
	CalledDecl decl;
	Type returnType;
	Type[] paramTypes;
}

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
		if (x.source.isA!FunSourceAst)
			cb(AnyDecl(&x));
	foreach (ref Test x; a.tests)
		cb(AnyDecl(&x));
}

immutable struct AnyDecl {
	@safe @nogc pure nothrow:

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
	mixin Union!(immutable ubyte[], string, ImportFileContentBogus);
}
immutable struct ImportFileContentBogus {}

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

	StructInst* opIndex(CharType type) {
		final switch (type) {
			case CharType.char8:
				return char8;
			case CharType.char32:
				return char32;
		}
	}
	StructInst* opIndex(IntegralType type) =>
		integrals[type];
	StructInst* opIndex(CharOrIntegralType type) =>
		type.match!(StructInst*)(
			(CharType x) =>
				this[x],
			(IntegralType x) =>
				this[x]);
	StructInst* opIndex(FloatType type) {
		final switch (type) {
			case FloatType.float32:
				return float32;
			case FloatType.float64:
				return float64;
		}
	}
	StructInst* opIndex(StringLikeType type) {
		final switch (type) {
			case StringLikeType.char8Array:
				return char8Array;
			case StringLikeType.char32Array:
				return char32Array;
			case StringLikeType.cString:
				return cString;
			case StringLikeType.jsAny:
				return jsAny;
			case StringLikeType.string_:
				return string_;
			case StringLikeType.symbol:
				return symbol;
		}
	}
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

immutable struct CharOrIntegralType {
	@safe @nogc pure nothrow:

	mixin Union!(CharType, IntegralType);
	bool isSigned() =>
		match!bool(
			(CharType _) =>
				false,
			(IntegralType x) =>
				.isSigned(x));
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
	mixin Union!(BuildTargetJs, BuildTargetNative);

	static BuildTarget js() =>
		BuildTarget(BuildTargetJs());
	static BuildTarget native(OS os) =>
		BuildTarget(BuildTargetNative(os));
}
private immutable struct BuildTargetJs {}
private immutable struct BuildTargetNative { OS os; }

// All 'extern's to compile with for the given target
SymbolSet allExterns(in ProgramWithMain program, BuildTarget target) =>
	allExternsForMainConfig(program.mainConfig, some(target));
SymbolSet allExternsForMainConfig(in Config mainConfig, Opt!BuildTarget target) =>
	buildSymbolSet((scope ref SymbolSetBuilder out_) {
		if (has(target)) {
			force(target).match!void(
				(BuildTargetJs _) {
					out_ ~= symbol!"js";
				},
				(BuildTargetNative x) {
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

	mixin Union!(MainFunNat64OfArgs, MainFunVoid, TestSelector);

	UriAndRange rangeForDiag() scope =>
		matchIn!UriAndRange(
			(in MainFunNat64OfArgs x) =>
				x.fun.decl.range,
			(in MainFunVoid x) =>
				x.fun.decl.range,
			(in TestSelector test) =>
				test.matchIn!UriAndRange(
					(in TestSelectorAll x) =>
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
			(in MainFunNat64OfArgs x) =>
				some(x.fun.decl.moduleUri),
			(in MainFunVoid x) =>
				some(x.fun.decl.moduleUri),
			(in TestSelector test) =>
				test.matchIn!(Opt!Uri)(
					(in TestSelectorAll _) =>
						none!Uri,
					(in Config x) =>
						some(force(x.configUri)),
					(in Uri x) =>
						some(x),
					(in Test x) =>
						some(x.moduleUri)));

	SymbolSet requiredExterns() scope =>
		matchIn!SymbolSet(
			(in MainFunNat64OfArgs x) =>
				x.fun.decl.externs,
			(in MainFunVoid x) =>
				x.fun.decl.externs,
			(in TestSelector x) =>
				x.matchIn!SymbolSet(
					(in TestSelectorAll _) =>
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
			(MainFunNat64OfArgs x) =>
				configFor(x.fun.decl.moduleUri),
			(MainFunVoid x) =>
				configFor(x.fun.decl.moduleUri),
			(TestSelector test) =>
				test.matchWithPointers!(Config*)(
					(TestSelectorAll x) =>
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
			(in MainFunNat64OfArgs _) =>
				TestSelector.all(mainConfig(program)),
			(in MainFunVoid _) =>
				TestSelector.all(mainConfig(program)),
			(in TestSelector x) =>
				x);
}
immutable struct MainFunNat64OfArgs {
	FunInst* fun;
}
immutable struct MainFunVoid {
	FunInst* fun;
}

immutable struct TestSelector {
	@safe @nogc pure nothrow:
	// All tests, tests in a particular config, tests in a single file, or a single test
	mixin Union!(TestSelectorAll, Config*, Uri, Test*);

	static TestSelector all(Config* mainConfig) =>
		TestSelector(TestSelectorAll(mainConfig));
}
private immutable struct TestSelectorAll {
	Config* mainConfig;
}

bool hasAnyDiagnostics(in ProgramWithMain a) =>
	hasAnyDiagnostics(a.program) || !isEmpty(a.mainFunDiagnostics);

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

bool existsDiagnostic(in Program a, in bool delegate(in UriAndDiagnostic) @safe @nogc pure nothrow cb) =>
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
		(TestSelectorAll _) {
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
	mixin TaggedUnion!(SingleDestructureAst*, LocalSourceGenerated*);
}
immutable struct LocalSourceGenerated { Symbol name; }

immutable struct Local {
	@safe @nogc pure nothrow:

	LocalSource source;
	LocalMutability mutability;
	Type type;

	Symbol name() scope =>
		source.matchIn!Symbol(
			(in SingleDestructureAst x) =>
				x.name.name,
			(in LocalSourceGenerated x) =>
				x.name);

	bool isMutable() scope =>
		mutability.matchIn!bool(
			(in LocalImmutable _) =>
				false,
			(in LocalMutableOnStack _) =>
				true,
			(in LocalMutableAllocated _) =>
				true);

	bool isAllocated() scope =>
		mutability.matchIn!bool(
			(in LocalImmutable _) =>
				false,
			(in LocalMutableOnStack _) =>
				false,
			(in LocalMutableAllocated _) =>
				true);
}

Range localMustHaveNameRange(in Local a) =>
	a.source.as!(SingleDestructureAst*).nameRange;

private Range localMustHaveRange(in Local a) =>
	a.source.as!(SingleDestructureAst*).range;

immutable struct LocalMutability {
	@safe @nogc pure nothrow:
	mixin Union!(LocalImmutable, LocalMutableOnStack, LocalMutableAllocated);

	static LocalMutability immutable_() =>
		LocalMutability(LocalImmutable());
	static LocalMutability mutableOnStack() =>
		LocalMutability(LocalMutableOnStack());

	bool isImmutable() scope =>
		isA!LocalImmutable;
}
immutable struct LocalImmutable {}
immutable struct LocalMutableOnStack {}
immutable struct LocalMutableAllocated { StructInst* referenceType; }

enum Mutability { immut, mut }
Mutability toMutability(LocalMutability a) =>
	a.matchIn!Mutability(
		(in LocalImmutable _) =>
			Mutability.immut,
		(in LocalMutableOnStack _) =>
			Mutability.mut,
		(in LocalMutableAllocated _) =>
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
			(in LocalImmutable _) =>
				ClosureReferenceKind.direct,
			(in LocalMutableOnStack _) =>
				assert(false),
			(in LocalMutableAllocated _) =>
				ClosureReferenceKind.allocated);
}

immutable struct DestructureIgnoreSource {
	mixin Union!(CaseMemberAst*, StructDecl*, SingleDestructureAst*, VoidDestructureAst*);
}

immutable struct Destructure {
	@safe @nogc pure nothrow:

	mixin TaggedUnion!(DestructureIgnore*, Local*, DestructureSplit*);

	Opt!Symbol name() scope =>
		matchIn!(Opt!Symbol)(
			(in DestructureIgnore _) =>
				none!Symbol,
			(in Local x) =>
				some(x.name),
			(in DestructureSplit _) =>
				none!Symbol);

	Range range() scope =>
		matchIn!Range(
			(in DestructureIgnore x) =>
				Range(x.pos, x.pos + 1),
			(in Local x) =>
				localMustHaveRange(x),
			(in DestructureSplit x) =>
				combineRanges(x.parts[0].range, x.parts[$ - 1].range));
	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;

	Type type() scope =>
		matchIn!Type(
			(in DestructureIgnore x) =>
				x.type,
			(in Local x) =>
				x.type,
			(in DestructureSplit x) =>
				x.destructuredType);
}
// This can come from '_' or '()' (which is the same as '_ void')
immutable struct DestructureIgnore {
	DestructureIgnoreSource source;
	Pos pos;
	Type type;
}
immutable struct DestructureSplit {
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
void eachLocal(Destructure a, in void delegate(Local*) @safe @nogc pure nothrow cb) {
	Opt!bool res = firstLocal!bool(a, (Local* x) {
		cb(x);
		return none!bool;
	});
	assert(!has(res));
}
Opt!Out firstLocal(Out)(Destructure a, in Opt!Out delegate(Local*) @safe @nogc pure nothrow cb) =>
	a.matchWithPointers!(Opt!Out)(
		(DestructureIgnore*) =>
			none!Out,
		(Local* x) =>
			cb(x),
		(DestructureSplit* x) =>
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
	mixin Union!(
		DocCommentReferenceBogus,
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
immutable struct DocCommentReferenceBogus {}
alias DocCommentReferences = SmallArray!DocCommentReference;
DocCommentReferences emptyDocCommentReferences() =>
	emptySmallArray!DocCommentReference;

immutable struct Expr {
	@safe @nogc pure nothrow:
	mixin Union!(
		AssertOrForbidExpr*,
		BogusCallExpr*,
		BogusExpr,
		BogusWrongTypeExpr,
		CallExpr,
		CallOptionExpr,
		ClosureGetExpr,
		ClosureSetExpr,
		ExternExpr,
		FinallyExpr*,
		FunPointerExpr,
		IfExpr*,
		LambdaExpr*,
		LetExpr*,
		LiteralFloatExpr,
		LiteralIntegralExpr,
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

	Pos start() scope =>
		range.start;
	Pos end() scope =>
		range.end;
	Range range() scope =>
		matchIn!Range(
			(in AssertOrForbidExpr x) =>
				x.range,
			(in BogusCallExpr x) =>
				x.range,
			(in BogusExpr x) =>
				x.range,
			(in BogusWrongTypeExpr x) =>
				x.range,
			(in CallExpr x) =>
				x.range,
			(in CallOptionExpr x) =>
				x.range,
			(in ClosureGetExpr x) =>
				x.range,
			(in ClosureSetExpr x) =>
				x.range,
			(in ExternExpr x) =>
				x.range,
			(in FinallyExpr x) =>
				x.range,
			(in FunPointerExpr x) =>
				x.range,
			(in IfExpr x) =>
				x.range,
			(in LambdaExpr x) =>
				x.range,
			(in LetExpr x) =>
				x.range,
			(in LiteralFloatExpr x) =>
				x.range,
			(in LiteralIntegralExpr x) =>
				x.range,
			(in LiteralStringLikeExpr x) =>
				x.range,
			(in LocalGetExpr x) =>
				x.range,
			(in LocalPointerExpr x) =>
				x.range,
			(in LocalSetExpr x) =>
				x.range,
			(in LoopExpr x) =>
				x.range,
			(in LoopBreakExpr x) =>
				x.range,
			(in LoopContinueExpr x) =>
				x.range,
			(in LoopWhileOrUntilExpr x) =>
				x.range,
			(in MatchEnumExpr x) =>
				x.range,
			(in MatchIntegralExpr x) =>
				x.range,
			(in MatchStringLikeExpr x) =>
				x.range,
			(in MatchSumTypeExpr x) =>
				x.range,
			(in RecordFieldPointerExpr x) =>
				x.range,
			(in SeqExpr x) =>
				x.range,
			(in ThrowExpr x) =>
				x.range,
			(in TrustedExpr x) =>
				x.range,
			(in TryExpr x) =>
				x.range,
			(in TryLetExpr x) =>
				x.range,
			(in TypedExpr x) =>
				x.range);

	bool typeIsBogus() scope =>
		typeNotCommon.isBogus;
	Type typeNotCommon() return scope {
		CommonTypes commonTypes = CommonTypes(); // It won't actually use this
		Type res = type(commonTypes);
		if (res.isA!(StructInst*))
			assert(res.as!(StructInst*) != null);
		return res;
	}
	Type type(ref CommonTypes commonTypes) return scope =>
		match!Type(
			(ref AssertOrForbidExpr x) =>
				Type(commonTypes.void_),
			(ref BogusCallExpr x) =>
				x.expectedType,
			(BogusExpr x) =>
				x.expectedType,
			(BogusWrongTypeExpr x) =>
				x.expectedType,
			(CallExpr x) =>
				x.type,
			(CallOptionExpr x) =>
				Type(x.type),
			(ClosureGetExpr x) =>
				x.type,
			(ClosureSetExpr x) =>
				Type(commonTypes.void_),
			(ExternExpr x) =>
				x.type(commonTypes),
			(ref FinallyExpr x) =>
				x.type(commonTypes),
			(FunPointerExpr x) =>
				Type(x.type),
			(ref IfExpr x) =>
				x.type(commonTypes),
			(ref LambdaExpr x) =>
				Type(x.type),
			(ref LetExpr x) =>
				x.type(commonTypes),
			(LiteralFloatExpr x) =>
				Type(x.type(commonTypes)),
			(LiteralIntegralExpr x) =>
				Type(x.type(commonTypes)),
			(LiteralStringLikeExpr x) =>
				Type(x.type(commonTypes)),
			(LocalGetExpr x) =>
				x.type,
			(LocalPointerExpr x) =>
				Type(x.type),
			(LocalSetExpr x) =>
				Type(commonTypes.void_),
			(ref LoopExpr x) =>
				x.type,
			(ref LoopBreakExpr x) =>
				x.loop.type,
			(LoopContinueExpr x) =>
				x.loop.type,
			(ref LoopWhileOrUntilExpr x) =>
				Type(commonTypes.void_),
			(ref MatchEnumExpr x) =>
				x.type(commonTypes),
			(ref MatchIntegralExpr x) =>
				x.type(commonTypes),
			(ref MatchStringLikeExpr x) =>
				x.type(commonTypes),
			(ref MatchSumTypeExpr x) =>
				x.type(commonTypes),
			(ref RecordFieldPointerExpr x) =>
				Type(x.type),
			(ref SeqExpr x) =>
				x.type(commonTypes),
			(ref ThrowExpr x) =>
				x.type,
			(ref TrustedExpr x) =>
				x.type(commonTypes),
			(ref TryExpr x) =>
				x.type(commonTypes),
			(ref TryLetExpr x) =>
				x.type(commonTypes),
			(ref TypedExpr x) =>
				x.type(commonTypes));
}
version (WebAssembly) {} else {
	static assert(Expr.sizeof == CallExpr.sizeof + ulong.sizeof);
}

immutable struct Condition {
	mixin TaggedUnion!(Expr*, UnpackOption*);
}
immutable struct UnpackOption {
	Destructure destructure;
	Expr option;
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
	if (e.isA!CallExpr) {
		CallExpr call = e.as!CallExpr;
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
	optIf(a.isA!ExternExpr, () => a.as!ExternExpr.names);
private ref Expr skipTrusted(return ref Expr a) =>
	a.isA!(TrustedExpr*) ? a.as!(TrustedExpr*).inner : a;

immutable struct AssertOrForbidExpr {
	@safe @nogc pure nothrow:
	AssertOrForbidAst* ast;
	bool isForbid;
	Condition condition;
	Opt!(Expr*) thrown;
	Expr after;

	Range range() scope =>
		ast.range;
}
private immutable struct PrefixAndRange {
	string prefix;
	Range range;
}
string defaultAssertOrForbidMessage(
	ref Alloc alloc,
	Uri curUri,
	in AssertOrForbidExpr a,
	in FileContentGetters content,
) {
	PrefixAndRange x = a.ast.condition.match!PrefixAndRange(
		(ref ExprAst condition) =>
			PrefixAndRange(
				a.isForbid ? "Forbidden expression is true: " : "Asserted expression is false: ",
				a.ast.condition.range),
		(ref UnpackOptionAst unpack) =>
			PrefixAndRange(
				a.isForbid ? "Forbidden option is non-empty: " : "Asserted option is empty: ",
				unpack.option.range));
	return concatenate(alloc, x.prefix, content[UriAndRange(curUri, x.range)]);
}

immutable struct BogusExpr {
	Range range;
	Type expectedType;
}

// Wraps an expression that has an invalid type.
immutable struct BogusWrongTypeExpr {
	@safe @nogc pure nothrow:
	Expr* inner;
	Type expectedType;

	Range range() scope =>
		inner.range;
}

immutable struct CallExprSource {
	@safe @nogc pure nothrow:
	// IfAst is for an implicit 'else ()'
	mixin Union!(
		ArrowAccessAst*,
		AssignmentAst*,
		AssignmentCallAst*,
		CallAst*,
		CallNamedAst*,
		EmptyAst*,
		ForAst*,
		IfAst*,
		InterpolatedAst*,
		LoopBreakAst*,
		LoopContinueAst*,
		NameAndRange*,
		WithAst*);

	Range range() scope =>
		matchIn!Range(
			(in ArrowAccessAst x) =>
				x.range,
			(in AssignmentAst x) =>
				x.range,
			(in AssignmentCallAst x) =>
				x.range,
			(in CallAst x) =>
				x.range,
			(in CallNamedAst x) =>
				x.range,
			(in EmptyAst x) =>
				x.range,
			(in ForAst x) =>
				x.range,
			(in IfAst x) =>
				x.range,
			(in InterpolatedAst x) =>
				x.range,
			(in LoopBreakAst x) =>
				x.range,
			(in LoopContinueAst x) =>
				x.range,
			(in NameAndRange x) =>
				x.range,
			(in WithAst x) =>
				x.range);
	Range nameRange() scope =>
		matchIn!Range(
			(in ArrowAccessAst x) =>
				x.name.range,
			(in AssignmentAst x) =>
				x.left.range,
			(in AssignmentCallAst x) =>
				x.funName.range,
			(in CallAst x) =>
				x.nameRange,
			(in CallNamedAst x) =>
				x.range,
			(in EmptyAst x) =>
				x.range,
			(in ForAst x) =>
				x.forKeywordRange,
			(in IfAst x) =>
				x.firstKeywordRange,
			(in InterpolatedAst x) =>
				x.range,
			(in LoopBreakAst x) =>
				x.range,
			(in LoopContinueAst x) =>
				x.range,
			(in NameAndRange x) =>
				x.range,
			(in WithAst x) =>
				x.withKeywordRange);
}

immutable struct BogusCallExpr {
	@safe @nogc pure nothrow:
	CallExprSource ast;
	SmallArray!CalledDecl candidates;
	// Note: It may have given up on checking arguments.
	SmallArray!Expr checkedArgs;
	Type expectedType;

	@safe @nogc pure nothrow this(CallExprSource a, SmallArray!CalledDecl cs, SmallArray!Expr cas, Type et) {
		ast = a;
		candidates = cs;
		checkedArgs = cas;
		expectedType = et;
		assert(!isEmpty(candidates));
	}

	Range range() scope =>
		ast.range;
}

immutable struct CallExpr {
	@safe @nogc pure nothrow:
	CallExprSource ast;
	Called called;
	SmallArray!Expr args;

	Range range() scope =>
		ast.range;
	Type type() =>
		called.returnType;
}

// Expression for 'x?.y' or 'x?[y]'
immutable struct CallOptionExpr {
	@safe @nogc pure nothrow:
	CallAst* ast;
	// May or may not return an option. If not it will be wrapped after calling.
	Called called;
	// The first arg is an option which is unwrapped before calling. The rest are non-optional.
	SmallArray!Expr allArgs;
	// If 'called.returnType' is not an option, this wraps it in an option.
	StructInst* type;

	Range range() scope =>
		ast.range;
	bool wrapsReturnAsOption() scope =>
		called.returnType != Type(type);
	ref Expr firstArg() =>
		allArgs[0];
	Expr[] restArgs() =>
		allArgs[1 .. $];
}

immutable struct ClosureGetExpr {
	@safe @nogc pure nothrow:
	Range range;
	ClosureRef closureRef;

	Type type() =>
		local.type;
	Local* local() return scope =>
		closureRef.local;
}

immutable struct ClosureSetExpr {
	@safe @nogc pure nothrow:
	Range assigneeRange;
	ClosureRef closureRef;
	Expr* value;

	Range range() scope =>
		combineRanges(assigneeRange, value.range);
	Local* local() return scope =>
		closureRef.local;
}

immutable struct ExternExpr {
	@safe @nogc pure nothrow:
	ExternAst* ast;
	SymbolSet names;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		Type(commonTypes.bool_);
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
	@safe @nogc pure nothrow:
	FinallyAst* ast;
	Expr right;
	Expr below;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		below.type(commonTypes);
}

immutable struct FunPointerExpr {
	@safe @nogc pure nothrow:
	PtrAst* ast;
	Called called;
	StructInst* type;

	Range range() scope =>
		ast.range;
}

// Expression for an IfAst -- see that for all kinds of syntax this corresponds to
immutable struct IfExpr {
	@safe @nogc pure nothrow:
	IfAst* ast;
	Condition condition;
	Expr trueBranch;
	Expr falseBranch;

	Range range() scope =>
		ast.range;
	ref Expr firstBranch() return =>
		ast.isConditionNegated ? falseBranch : trueBranch;
	ref Expr secondBranch() return =>
		ast.isConditionNegated ? trueBranch : falseBranch;
	Type type(ref CommonTypes commonTypes) {
		assert(trueBranch.type(commonTypes) == falseBranch.type(commonTypes));
		return trueBranch.type(commonTypes);
	}
}

immutable struct LambdaSource {
	@safe @nogc pure nothrow:
	mixin TaggedUnion!(ForAst*, LambdaAst*, WithAst*);

	DestructureAst param() return scope =>
		match!DestructureAst(
			(ref ForAst x) =>
				x.param,
			(ref LambdaAst x) =>
				x.param,
			(ref WithAst x) =>
				x.param);

	Range range() scope =>
		matchIn!Range(
			(in ForAst x) =>
				x.range,
			(in LambdaAst x) =>
				x.range,
			(in WithAst x) =>
				x.range);
}

immutable struct LambdaExpr {
	@safe @nogc pure nothrow:

	LambdaSource ast;
	LambdaKind kind;
	Destructure param;
	Opt!(StructInst*) mutTypeForExplicitShared;
	private Late!Expr lateBody;
	private Late!(SmallArray!VariableRef) closure_;
	private Late!(StructInst*) lambdaType_;

	void fillLate(Expr body_, SmallArray!VariableRef closure, StructInst* lambdaType) {
		lateSet(lateBody, body_);
		lateSet(closure_, closure);
		lateSet(lambdaType_, lambdaType);
	}

	Range range() scope =>
		ast.range;
	ref Expr body_() return scope =>
		lateGet(lateBody);
	SmallArray!VariableRef closure() return scope =>
		lateGet(closure_);
	StructInst* type() return scope =>
		lateGet(lambdaType_);
	Type returnType() return scope =>
		type.typeArgs[0];

	// We don't know whether this lambda is for the main body or for the optional 'else'.
	// But if it is from the `else`, this function will return true.
	bool isIgnore() scope =>
		param.isA!(DestructureIgnore*) &&
		param.as!(DestructureIgnore*).source.isA!(VoidDestructureAst*);
}
enum LambdaKind {
	data,
	shared_,
	mut,
	explicitShared,
}

immutable struct LetExpr {
	@safe @nogc pure nothrow:
	LetAst* ast;
	Destructure destructure;
	Expr value;
	Expr then;

	Range range() scope =>
		Range(destructure.start, then.end);
	Type type(ref CommonTypes commonTypes) =>
		then.type(commonTypes);
}

immutable struct LiteralFloatExpr {
	@safe @nogc pure nothrow:
	Range range;
	FloatType floatType;
	double value;

	StructInst* type(ref CommonTypes commonTypes) =>
		commonTypes[floatType];
}

immutable struct LiteralIntegralExpr {
	@safe @nogc pure nothrow:
	Range range;
	CharOrIntegralType integralType;
	IntegralValue value;

	bool isSigned() scope =>
		integralType.isSigned;
	StructInst* type(ref CommonTypes commonTypes) =>
		commonTypes[integralType];
}

immutable struct LiteralStringLikeExpr {
	@safe @nogc pure nothrow:
	Range range;
	StringLikeType stringType;
	SmallString value; // For char32Array, this will be decoded in concretize.

	StructInst* type(ref CommonTypes commonTypes) =>
		commonTypes[stringType];
}
enum StringLikeType { char8Array, char32Array, cString, jsAny, string_, symbol }

immutable struct LocalGetExpr {
	@safe @nogc pure nothrow:
	Range range;
	Local* local;

	Type type() =>
		local.type;
}

immutable struct LocalPointerExpr {
	@safe @nogc pure nothrow:
	PtrAst* ast;
	Local* local;
	StructInst* type;

	Range range() scope =>
		ast.range;
}

immutable struct LocalSetExpr {
	@safe @nogc pure nothrow:
	Range assigneeRange;
	Local* local;
	Expr* value;

	Range range() scope =>
		combineRanges(assigneeRange, value.range);
}

immutable struct LoopExpr {
	@safe @nogc pure nothrow:
	LoopAst* ast;
	Type type;
	Expr body_;

	Range range() scope =>
		ast.range;
}

immutable struct LoopBreakExpr {
	@safe @nogc pure nothrow:
	LoopBreakAst* ast;
	LoopExpr* loop;
	Expr value;

	Range range() scope =>
		ast.range;
}

immutable struct LoopContinueExpr {
	@safe @nogc pure nothrow:
	LoopContinueAst* ast;
	LoopExpr* loop;

	Range range() scope =>
		ast.range;
}

immutable struct LoopWhileOrUntilExpr {
	@safe @nogc pure nothrow:
	LoopWhileOrUntilAst* ast;
	Condition condition;
	Expr body_; // Always of type 'void'
	Expr after;

	bool isUntil() scope =>
		ast.isUntil;
	Range range() scope =>
		ast.range;
}

immutable struct MatchEnumExpr {
	@safe @nogc pure nothrow:

	MatchAst* ast;
	Expr matched;
	SmallArray!MatchEnumCase cases;
	Opt!Expr else_;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		has(else_) ? force(else_).type(commonTypes) : cases[0].then.type(commonTypes);

	StructInst* enumType() return scope =>
		matched.typeNotCommon.as!(StructInst*);
	StructDecl* enum_() {
		StructInst* inst = enumType;
		assert(isEmpty(inst.typeArgs));
		StructDecl* res = inst.decl;
		assert(every!MatchEnumCase(cases, (in MatchEnumCase x) => x.member.containingEnum == res));
		return res;
	}

	Enum* enumBody() =>
		enum_.body_.as!(Enum*);
}
immutable struct MatchEnumCase {
	EnumOrFlagsMember* member;
	Expr then;
}

// Match on charX, intX, natX type
immutable struct MatchIntegralExpr {
	@safe @nogc pure nothrow:
	MatchAst* ast;
	CharOrIntegralType integralType;
	Expr matched;
	SmallArray!MatchIntegralCase cases;
	Expr else_;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		else_.type(commonTypes);
	StructInst* matchedType() return scope =>
		matched.typeNotCommon.as!(StructInst*);
}
immutable struct MatchIntegralCase {
	IntegralValue value;
	Expr then;
}

// Match on symbol, string, char8 array, char8[], char32 array, char32[]
immutable struct MatchStringLikeExpr {
	@safe @nogc pure nothrow:
	MatchAst* ast;
	StringLikeType stringType;
	Expr matched;
	Called equals; // == function for the type
	SmallArray!MatchStringLikeCase cases;
	Expr else_;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		else_.type(commonTypes);
	StructInst* matchedType() return scope =>
		matched.typeNotCommon.as!(StructInst*);
}
immutable struct MatchStringLikeCase {
	string value;
	Expr then;
}

immutable struct MatchSumTypeExpr {
	@safe @nogc pure nothrow:

	MatchAst* ast;
	Expr matched;
	SmallArray!MatchSumTypeCase cases;
	Opt!(Expr*) else_;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		has(else_) ? force(else_).type(commonTypes) : cases[0].then.type(commonTypes);
	StructInst* sumType() return scope =>
		matched.typeNotCommon.as!(StructInst*);
	SumType sumTypeBody() return scope =>
		sumType.decl.body_.as!SumType;
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

	StructInst* caseType() return scope =>
		destructure.type.as!(StructInst*);
}

immutable struct RecordFieldPointerExpr {
	@safe @nogc pure nothrow:

	PtrAst* ast;
	Expr target; // This will be a pointer or by-ref type
	RecordField* field;
	StructInst* type;

	Range range() scope =>
		ast.range;
	StructDecl* recordDecl() scope {
		StructInst* targetType = target.typeNotCommon.as!(StructInst*);
		return isPointerConstOrMut(*targetType.decl)
			? pointeeType(*targetType).as!(StructInst*).decl
			: targetType.decl;
	}
	size_t fieldIndex() =>
		mustHaveIndexOfPointer(recordDecl.body_.as!Record.fields, field);
}

immutable struct SeqExpr {
	@safe @nogc pure nothrow:
	Expr first;
	Expr then;

	Range range() scope =>
		Range(first.start, then.end);
	Type type(ref CommonTypes commonTypes) =>
		then.type(commonTypes);
}

immutable struct ThrowExpr {
	@safe @nogc pure nothrow:
	ThrowAst* ast;
	Expr thrown;
	Type type;

	Range range() scope =>
		ast.range;
}

immutable struct TrustedExpr {
	@safe @nogc pure nothrow:
	TrustedAst* ast;
	Expr inner;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		inner.type(commonTypes);
}

immutable struct TryExpr {
	@safe @nogc pure nothrow:
	TryAst* ast;
	Expr tried;
	SmallArray!MatchSumTypeCase catches;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		tried.type(commonTypes);
}

immutable struct TryLetExpr {
	@safe @nogc pure nothrow:
	TryLetAst* ast;
	Destructure destructure;
	Expr value;
	MatchSumTypeCase catch_;
	Expr then;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) =>
		then.type(commonTypes);
}

immutable struct TypedExpr {
	@safe @nogc pure nothrow:
	TypedAst* ast;
	Expr inner;

	Range range() scope =>
		ast.range;
	Type type(ref CommonTypes commonTypes) return scope =>
		inner.type(commonTypes);
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

immutable struct CalledAndNameRange {
	Called called;
	Range nameRange;
}
Opt!CalledAndNameRange getCalledAtExpr(in Expr a) =>
	a.isA!CallExpr
		? some(CalledAndNameRange(a.as!CallExpr.called, a.as!CallExpr.ast.nameRange))
		: a.isA!CallOptionExpr
		? some(CalledAndNameRange(a.as!CallOptionExpr.called, a.as!CallOptionExpr.ast.nameRange))
		: a.isA!FunPointerExpr
		? some(CalledAndNameRange(a.as!FunPointerExpr.called, a.as!FunPointerExpr.ast.range))
		: none!CalledAndNameRange;

void eachDescendentExprIncluding(Expr* a, in void delegate(Expr*) @safe @nogc pure nothrow cb) {
	cb(a);
	eachDescendentExprExcluding(*a, cb);
}

void eachDescendentExprExcluding(ref Expr a, in void delegate(Expr*) @safe @nogc pure nothrow cb) {
	eachDirectChildExpr(a, (Expr* x) {
		eachDescendentExprIncluding(x, cb);
	});
}

void eachDirectChildExpr(ref Expr a, in void delegate(Expr*) @safe @nogc pure nothrow cb) {
	Opt!bool res = findDirectChildExpr!bool(a, (Expr* x) {
		cb(x);
		return none!bool;
	});
	assert(!has(res));
}

Opt!T findDirectChildExpr(T)(ref Expr a, in Opt!T delegate(Expr*) @safe @nogc pure nothrow cb) {
	Expr* directChildInCondition(Condition cond) =>
		cond.matchWithPointers!(Expr*)(
			(Expr* x) =>
				x,
			(UnpackOption* x) =>
				&x.option);
	Opt!T directChildInMatchSumTypeCases(MatchSumTypeCase[] cases) =>
		firstPointer!(T, MatchSumTypeCase)(cases, (MatchSumTypeCase* x) =>
			cb(&x.then));

	return a.matchWithPointers!(Opt!T)(
		(AssertOrForbidExpr* x) =>
			optOr!T(
				cb(directChildInCondition(x.condition)),
				() => has(x.thrown) ? cb(force(x.thrown)) : none!T,
				() => cb(&x.after)),
		(BogusCallExpr* _) =>
			none!T,
		(BogusExpr _) =>
			none!T,
		(BogusWrongTypeExpr x) =>
			cb(x.inner),
		(CallExpr x) =>
			firstPointer!(T, Expr)(x.args, cb),
		(CallOptionExpr x) =>
			firstPointer!(T, Expr)(x.allArgs, cb),
		(ClosureGetExpr x) =>
			none!T,
		(ClosureSetExpr x) =>
			cb(x.value),
		(ExternExpr x) =>
			none!T,
		(FinallyExpr* x) =>
			optOr!T(cb(&x.right), () => cb(&x.below)),
		(FunPointerExpr _) =>
			none!T,
		(IfExpr* x) =>
			optOr!T(
				cb(directChildInCondition(x.condition)),
				() => cb(&x.firstBranch()),
				() => cb(&x.secondBranch())),
		(LambdaExpr* x) =>
			cb(&x.body_()),
		(LetExpr* x) =>
			optOr!T(cb(&x.value), () => cb(&x.then)),
		(LiteralFloatExpr _) =>
			none!T,
		(LiteralIntegralExpr _) =>
			none!T,
		(LiteralStringLikeExpr _) =>
			none!T,
		(LocalGetExpr x) =>
			none!T,
		(LocalPointerExpr _) =>
			none!T,
		(LocalSetExpr x) =>
			cb(x.value),
		(LoopExpr* x) =>
			cb(&x.body_),
		(LoopBreakExpr* x) =>
			cb(&x.value),
		(LoopContinueExpr _) =>
			none!T,
		(LoopWhileOrUntilExpr* x) =>
			optOr!T(
				cb(directChildInCondition(x.condition)),
				() => cb(&x.body_),
				() => cb(&x.after)),
		(MatchEnumExpr* x) =>
			optOr!T(
				cb(&x.matched),
				() => firstPointer!(T, MatchEnumCase)(x.cases, (MatchEnumCase* y) => cb(&y.then)),
				() => has(x.else_) ? cb(&force(x.else_)) : none!T),
		(MatchIntegralExpr* x) =>
			optOr!T(
				cb(&x.matched),
				() => firstPointer!(T, MatchIntegralCase)(x.cases, (MatchIntegralCase* y) =>
					cb(&y.then)),
				() => cb(&x.else_)),
		(MatchStringLikeExpr* x) =>
			optOr!T(
				cb(&x.matched),
				() => firstPointer!(T, MatchStringLikeCase)(x.cases, (MatchStringLikeCase* y) =>
					cb(&y.then)),
				() => cb(&x.else_)),
		(MatchSumTypeExpr* x) =>
			optOr!T(
				cb(&x.matched),
				() => directChildInMatchSumTypeCases(x.cases),
				() => has(x.else_) ? cb(force(x.else_)) : none!T),
		(RecordFieldPointerExpr* x) =>
			cb(&x.target),
		(SeqExpr* x) =>
			optOr!T(cb(&x.first), () => cb(&x.then)),
		(ThrowExpr* x) =>
			cb(&x.thrown),
		(TrustedExpr* x) =>
			cb(&x.inner),
		(TryExpr* x) =>
			optOr!T(cb(&x.tried), () => directChildInMatchSumTypeCases(x.catches)),
		(TryLetExpr* x) =>
			optOr!T(
				cb(&x.value),
				() => cb(&x.catch_.then),
				() => cb(&x.then)),
		(TypedExpr* x) =>
			cb(&x.inner));
}

FunDecl* sumTypeMemberGetter(FunDecl[] funs, in StructDecl* struct_, in SumTypeMembership x) =>
	mustFindFunNamed(funs, struct_.name, (in FunDecl fun) =>
		fun.body_.isA!SumTypeMemberGet &&
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

// In the CLI, we omit diagnostics if there are other more severe ones.
// So e.g., you wouldn't see unused code errors if there are parse errors.
enum DiagnosticSeverity {
	unusedCode,
	warning,
	checkError,
	nameNotFound,
	// Severe error where a common fun (e.g. 'alloc', 'main') or type (e.g. 'void') is missing
	commonMissing,
	parseError,
	importError,
}
bool isFatal(DiagnosticSeverity a) =>
	a >= DiagnosticSeverity.commonMissing;

immutable struct UriAndDiagnostic {
	@safe @nogc pure nothrow:

	Uri uri;
	Diagnostic diagnostic;

	this(Uri u, Diagnostic d) {
		uri = u;
		diagnostic = d;
	}
	this(UriAndRange range, Diag kind) {
		uri = range.uri;
		diagnostic = Diagnostic(range.range, kind);
	}

	UriAndRange where() scope =>
		UriAndRange(uri, diagnostic.range);

	Diag kind() return scope =>
		diagnostic.kind;
}

immutable struct Diagnostic {
	Range range;
	Diag kind;
}

enum DeclKind {
	alias_,
	builtin,
	enum_,
	extern_,
	externFunction,
	flags,
	function_,
	global,
	interface_,
	record,
	spec,
	test,
	threadLocal,
	union_,
	variant,
}

immutable struct Diag {
	mixin Union!(
		DiagAliasNotAllowed,
		DiagAssertOrForbidMessageIsThrow,
		DiagAssignmentNotAllowed,
		DiagAutoFunBare,
		DiagAutoFunEnumOrFlagsToWrongStorage,
		DiagAutoFunParamNotSimple,
		DiagAutoFunSpecCorrupt,
		DiagAutoFunSpecFromWrongModule,
		DiagAutoFunTypeNotFullyVisible,
		DiagAutoFunWrongName,
		DiagAutoFunWrongParams,
		DiagAutoFunWrongParamType,
		DiagAutoFunWrongReturnType,
		DiagBuiltinFunCantHaveBody,
		DiagBuiltinUnsupported,
		DiagCallMissingExtern,
		DiagCallMultipleMatches,
		DiagCallNoMatch,
		DiagCallShouldUseSyntax,
		DiagCantCall,
		DiagCaseDuplicate,
		DiagCaseInvalidSumType,
		DiagCaseMissingType,
		DiagCaseTypeIsTemplate,
		DiagCharLiteralMustBeOneChar,
		DiagCommonFunDuplicate,
		DiagCommonFunMissing,
		DiagCommonTypeMissing,
		DiagCommonVarMissing,
		DiagDestructureTypeMismatch,
		DiagDuplicateDeclaration,
		DiagDuplicateExports,
		DiagDuplicateImportName,
		DiagDuplicateImports,
		DiagEmptyEnumOrUnion,
		DiagEnumBackingTypeInvalid,
		DiagEnumDuplicateValue,
		DiagExpectedTypeIsNotALambda,
		DiagExternBodyMultiple,
		DiagExternInvalidName,
		DiagExternIsUnsafe,
		DiagExternRedundant,
		DiagExternFunVariadic,
		DiagExternHasUnnecessaryLibraryName,
		DiagExternMissingLibraryName,
		DiagExternRecordImplicitlyByVal,
		DiagExternSumType,
		DiagExternTypeError,
		DiagFlagsSigned,
		DiagFunctionWithSignatureNotFound,
		DiagFunPointerExprMustBeName,
		DiagFunPointerNotBare,
		DiagIfThrow,
		DiagImportFile*,
		DiagImportRefersToNothing,
		DiagLambdaCantBeFunctionPointer,
		DiagLambdaCantInferParamType,
		DiagLambdaClosurePurity,
		DiagLambdaMultipleMatch,
		DiagLambdaNotExpected,
		DiagLambdaTypeMissingParamType,
		DiagLambdaTypeVariadic,
		DiagLinkageWorseThanContainingFun,
		DiagLinkageWorseThanContainingType,
		DiagLiteralFloatAccuracy,
		DiagLiteralMultipleMatch,
		DiagLiteralNotExpected,
		DiagLiteralOverflow,
		DiagLocalIgnoredButMutable,
		DiagLocalNotMutable,
		DiagLoopDisallowedBody,
		DiagLoopWithoutBreak,
		DiagMainMissingExterns,
		DiagMainTestMissing,
		DiagMatchCaseDuplicate,
		DiagMatchCaseForType,
		DiagMatchCaseNameNotInEnum,
		DiagMatchCaseNoValueForEnumOrSymbol,
		DiagMatchCaseShouldUseIgnore,
		DiagMatchNeedsElse,
		DiagMatchOnNonMatchable,
		DiagMatchSumTypeCantInferTypeArgs,
		DiagMatchSumTypeNoMember,
		DiagMatchUnhandledEnumMembers,
		DiagMatchUnhandledUnionCaseTypes,
		DiagMatchUnnecessaryElse,
		DiagMethodImplVisibility,
		DiagModifierConflict,
		DiagModifierDuplicate,
		DiagModifierInvalid,
		DiagModifierRedundantDueToDeclKind,
		DiagModifierRedundantDueToModifier,
		DiagModifierTypeArgInvalid,
		DiagMutFieldNotAllowed,
		DiagNameNotFound,
		DiagNeedsExpectedType,
		DiagParamMissingType,
		DiagParamMutable,
		ParseDiag,
		DiagPointerIsNative,
		DiagPointerIsUnsafe,
		DiagPointerMutToConst,
		DiagPointerUnsupported,
		DiagPurityWorseThanParent,
		DiagPurityWorseThanSumType,
		DiagRecordFieldNeedsType,
		DiagSharedArgIsNotLambda,
		DiagSharedLambdaTypeIsNotShared,
		DiagSharedLambdaUnused,
		DiagSharedNotExpected,
		DiagSpecMatchMultiple,
		DiagSpecNoMatch,
		DiagSpecRecursion,
		DiagSpecSigCantBeVariadic,
		DiagSpecUseInvalid,
		DiagStringLiteralInvalid,
		DiagStorageMissingType,
		DiagStructParamsSyntaxError,
		DiagSumTypeListedMembersNonUnion,
		DiagTestMissingBody,
		DiagTrustedUnnecessary,
		DiagTupleTooBig,
		DiagTypeAnnotationUnnecessary,
		DiagTypeConflict,
		DiagTypeParamCantHaveTypeArgs,
		DiagTypeParamsUnsupported,
		DiagTypeShouldUseSyntax,
		DiagUnionMemberTypeParameter,
		DiagUnsupportedSyntax,
		DiagUnusedImport,
		DiagUnusedLocal,
		DiagUnusedPrivateDecl,
		DiagVarargsParamMustBeArray,
		DiagVisibilityWarning,
		DiagWithHasElse,
		DiagWrongNumberTypeArgs);
}


immutable struct DiagAliasNotAllowed {}
immutable struct DiagAssertOrForbidMessageIsThrow {}
immutable struct DiagAssignmentNotAllowed {}

immutable struct DiagAutoFunBare {}
immutable struct DiagAutoFunEnumOrFlagsToWrongStorage {
	StructDecl* enumOrFlagsType;
	IntegralType actualStorageType;
	IntegralType expectedStorageType;
}
immutable struct DiagAutoFunParamNotSimple {}
immutable struct DiagAutoFunSpecCorrupt { Symbol specName; }
immutable struct DiagAutoFunSpecFromWrongModule {}
immutable struct DiagAutoFunTypeNotFullyVisible {}
immutable struct DiagAutoFunWrongName {}
immutable struct DiagAutoFunWrongParams {
	AutoFunName kind;
}
immutable struct DiagAutoFunWrongParamType {}
immutable struct DiagAutoFunWrongReturnType {
	AutoFunName kind;
}

immutable struct DiagBuiltinFunCantHaveBody {}
immutable struct DiagBuiltinUnsupported {
	DiagBuiltinUnsupportedKind kind;
	Symbol name;
}
enum DiagBuiltinUnsupportedKind { function_, spec, type }

immutable struct DiagCallMissingExtern {
	FunDecl* callee;
	Symbol missingExtern;
}

// Note: this error is issued *before* resolving specs.
// We don't exclude a candidate based on not having specs.
immutable struct DiagCallMultipleMatches {
	Symbol funName;
	TypeContainer typeContainer;
	// Unlike CallNoMatch, these are only the ones that match
	CalledDecl[] matches;
}

immutable struct DiagCallNoMatch {
	TypeContainer typeContainer;
	Symbol funName;
	ExpectedForDiag expectedReturnType;
	// 0 for inferred type args.
	// This is the unpacked tuple, actualNTypeArgs > 1 may match candidates with 1 type arg.
	size_t actualNTypeArgs;
	size_t actualArity;
	// NOTE: we may have given up early and this may not be as much as actualArity
	Type[] actualArgTypes;
	// All candidates, including those with wrong arity
	CalledDecl[] allCandidates;
}

immutable struct DiagCallShouldUseSyntax {
	size_t arity;
	DiagCallShouldUseSyntaxKind kind;
}
enum DiagCallShouldUseSyntaxKind {
	for_break,
	force,
	for_loop,
	new_,
	not,
	set_subscript,
	subscript,
	with_block,
}

immutable struct DiagCantCall {
	DiagCantCallReason reason;
	FunDecl* callee;
}
enum DiagCantCallReason { nonBare, summon, summonInDataLambda, unsafe, variadicFromBare }

immutable struct DiagCaseDuplicate {
	StructDecl* member;
	StructDecl* sumType;
}
immutable struct DiagCaseInvalidSumType {
	StructDecl* member;
	Type actual;
}
immutable struct DiagCaseMissingType {}
immutable struct DiagCaseTypeIsTemplate {
	StructDecl* caseType;
}

immutable struct DiagCharLiteralMustBeOneChar {}
immutable struct DiagCommonFunDuplicate {
	Symbol name;
}
immutable struct DiagCommonFunMissing {
	FunDecl* dummyForContext;
	TypeParamsAndSig[] sigChoices;
}
immutable struct DiagCommonTypeMissing {
	Symbol name;
}
immutable struct DiagCommonVarMissing {
	VarKind varKind;
	Symbol name;
}
immutable struct DiagDestructureTypeMismatch {
	DestructureExpectedType expected;
	TypeWithContainer actual;
}
immutable struct DestructureExpectedType {
	mixin Union!(DestructureExpectedTuple, TypeWithContainer);
}
immutable struct DestructureExpectedTuple { size_t size; }
immutable struct DiagDuplicateDeclaration {
	DiagDuplicateDeclarationKind kind;
	Symbol name;
}
enum DiagDuplicateDeclarationKind {
	enumMember,
	flagsMember,
	paramOrLocal,
	recordField,
	spec,
	structOrAlias,
	typeParam,
	unionMember,
}
immutable struct DiagDuplicateExports {
	DiagDuplicateExportsKind kind;
	Symbol name;
}
enum DiagDuplicateExportsKind { spec, type }
// This is for the same name imported multiple times (`import ./m: foo, foo`)
immutable struct DiagDuplicateImportName {
	Symbol name;
}
// This is for different types of the same name imported from multiple modules
immutable struct DiagDuplicateImports {
	DiagDuplicateExportsKind kind;
	Symbol name;
}
immutable struct DiagEmptyEnumOrUnion {}
immutable struct DiagEnumBackingTypeInvalid {
	StructDecl* enum_;
	Type actual;
}
immutable struct DiagEnumDuplicateValue {
	bool signed;
	IntegralValue value;
}
immutable struct DiagExpectedTypeIsNotALambda {
	Opt!TypeWithContainer expectedType;
}
immutable struct DiagExternBodyMultiple {}
immutable struct DiagExternInvalidName {
	Symbol name;
}
immutable struct DiagExternIsUnsafe {}
immutable struct DiagExternRedundant {
	Symbol name;
}
immutable struct DiagExternFunVariadic {}
immutable struct DiagExternHasUnnecessaryLibraryName {}
immutable struct DiagExternMissingLibraryName {}
immutable struct DiagExternRecordImplicitlyByVal {
	StructDecl* struct_;
}
enum DiagExternTypeError { alignmentIsDefault, badAlignment, tooBig }
immutable struct DiagExternSumType {}
immutable struct DiagFlagsSigned {}
immutable struct DiagFunctionWithSignatureNotFound {
	Symbol name;
	TypeContainer typeContainer;
	ReturnAndParamTypes returnAndParamTypes;
}
immutable struct DiagFunPointerExprMustBeName {}
immutable struct DiagFunPointerNotBare {}
immutable struct DiagIfThrow {}
immutable struct DiagImportFile {
	mixin Union!(CantImportCrowAsText, CircularImport, LibraryNotConfigured, ReadError, RelativeImportReachesPastRoot);
}
immutable struct CantImportCrowAsText {}
immutable struct CircularImport {
	SmallArray!Uri cycle;
}
immutable struct LibraryNotConfigured {
	Symbol libraryName;
}
immutable struct ReadError {
	// The imported file will also have a ParseDiag for the issue, but we also show the error in the importer.
	// (This is important in an IDE.)
	Uri uri;
	ReadFileDiag diag;
}
immutable struct RelativeImportReachesPastRoot {
	RelPath imported;
}
immutable struct DiagImportRefersToNothing {
	Symbol name;
}
immutable struct DiagLambdaCantBeFunctionPointer {}
immutable struct DiagLambdaCantInferParamType {}
immutable struct DiagLambdaClosurePurity {
	LambdaKind lambdaKind;
	Symbol localName;
	Purity localPurity;
	// If missing, the error is that the local itself is 'mut'.
	// If present, the error is that the type is 'mut'.
	Opt!TypeWithContainer type;
}
immutable struct DiagLambdaMultipleMatch {
	// This is only the expected types that are lambdas
	ExpectedForDiagChoices choices;
}
immutable struct DiagLambdaNotExpected {
	ExpectedForDiag expected;
}
immutable struct DiagLambdaTypeMissingParamType {}
immutable struct DiagLambdaTypeVariadic {}
immutable struct DiagLinkageWorseThanContainingFun {
	FunDecl* containingFun;
	Type referencedType;
	// empty for return type
	Opt!(Destructure*) param;
}
immutable struct DiagLinkageWorseThanContainingType {
	StructDecl* containingType;
	Type referencedType;
}
immutable struct DiagLiteralFloatAccuracy {
	FloatType type;
}
immutable struct DiagLiteralMultipleMatch {
	TypeContainer typeContainer;
	StructInst*[] types;
}
immutable struct DiagLiteralNotExpected {
	ExpectedForDiag expected;
}
immutable struct DiagLiteralOverflow {
	IntegralType type;
}
immutable struct DiagLocalIgnoredButMutable {}
immutable struct DiagLocalNotMutable {
	VariableRef local;
}
enum DiagLoopDisallowedBody { finally_, try_ }
immutable struct DiagLoopWithoutBreak {}
immutable struct DiagMainMissingExterns {
	Symbol[] missing;
}
immutable struct DiagMainTestMissing {
	uint expectedLine;
}
immutable struct DiagMatchCaseDuplicate {
	mixin Union!(Symbol, string, ulong, long);
}
enum DiagMatchCaseForType { enumOrUnion, numeric, stringLike }
immutable struct DiagMatchCaseNameNotInEnum {
	Symbol actual;
	StructDecl* enum_;
}
immutable struct DiagMatchCaseNoValueForEnumOrSymbol {
	Opt!(StructDecl*) enum_;
}
immutable struct DiagMatchCaseShouldUseIgnore {
	StructInst* member;
}
enum DiagMatchNeedsElse { integral, stringLike, variant }
immutable struct DiagMatchOnNonMatchable {
	TypeWithContainer type;
}
immutable struct DiagMatchSumTypeCantInferTypeArgs {
	StructDecl* member;
}
immutable struct DiagMatchSumTypeNoMember {
	TypeWithContainer variant;
	StructDecl* nonMember;
}
immutable struct DiagMatchUnhandledEnumMembers {
	immutable EnumOrFlagsMember*[] members;
}
immutable struct DiagMatchUnhandledUnionCaseTypes {
	immutable StructInst*[] caseTypes;
}
immutable struct DiagMatchUnnecessaryElse {}

immutable struct DiagModifierConflict {
	ModifierKeyword prevModifier;
	ModifierKeyword curModifier;
}
immutable struct DiagModifierDuplicate {
	ModifierKeyword modifier;
}
immutable struct DiagModifierInvalid {
	ModifierKeyword modifier;
	DeclKind declKind;
}
// This is like 'ModifierDuplicate' but the modifiers are not identical.
// E.g., 'extern unsafe', since 'extern' implies 'unsafe'.
immutable struct DiagModifierRedundantDueToModifier {
	ModifierKeyword modifier;
	// This is implied by the first modifier
	ModifierKeyword redundantModifier;
}
immutable struct DiagModifierRedundantDueToDeclKind {
	ModifierKeyword modifier;
	DeclKind declKind;
}
immutable struct DiagModifierTypeArgInvalid {
	ModifierKeyword modifier;
}
immutable struct DiagMutFieldNotAllowed {}
immutable struct DiagNameNotFound {
	DiagNameNotFoundKind kind;
	Symbol name;
}
enum DiagNameNotFoundKind { docCommentReference, function_, spec, type }
enum DiagNeedsExpectedType { loop, pointer, throw_ }
immutable struct DiagParamMissingType {}
immutable struct DiagParamMutable {}
immutable struct DiagPointerIsNative {}
immutable struct DiagPointerIsUnsafe {}
enum DiagPointerMutToConst { fieldOfByRef, fieldOfByVal, local }
enum DiagPointerUnsupported { other, recordNotByRef }
immutable struct DiagPurityWorseThanParent {
	StructDecl* parent;
	StructInst* child;
}
immutable struct DiagPurityWorseThanSumType {
	StructDecl* case_;
	StructInst* sumType;
}
immutable struct DiagRecordFieldNeedsType {
	Symbol fieldName;
}
immutable struct DiagStructParamsSyntaxError {
	StructDecl* struct_;
	DiagStructParamsSyntaxErrorReason reason;
}
enum DiagStructParamsSyntaxErrorReason { hasParamsAndFields, destructure, variadic }
immutable struct DiagSharedArgIsNotLambda {}
immutable struct DiagSharedLambdaTypeIsNotShared {
	DiagSharedLambdaTypeIsNotSharedKind kind;
	TypeWithContainer actual;
}
enum DiagSharedLambdaTypeIsNotSharedKind { paramType, returnType }
immutable struct DiagSharedLambdaUnused {}
immutable struct DiagSharedNotExpected {
	ExpectedForDiag expected;
}
immutable struct DiagSpecMatchMultiple {
	TypeContainer outermostTypeContainer;
	Symbol sigName;
	Called[] matches;
	FunDeclAndTypeArgs[] trace;
}
immutable struct DiagSpecNoMatch {
	TypeContainer outermostTypeContainer;
	SpecNoMatchReason reason;
	FunDeclAndTypeArgs[] trace;
}
immutable struct SpecNoMatchReason {
	mixin Union!(SpecBuiltinNotSatisfied, SpecCantInferTypeArgs, SpecImplNotFound, SpecTooDeep);
}
immutable struct SpecBuiltinNotSatisfied {
	BuiltinSpec kind;
	Type type;
}
immutable struct SpecCantInferTypeArgs {
	// Since we didn't infer type args, it can't go onto the trace.
	FunDecl* fun;
}
immutable struct SpecImplNotFound {
	Signature* sigDecl;
	ReturnAndParamTypes sigType;
}
immutable struct SpecTooDeep {}

immutable struct DiagSpecRecursion {
	SpecDecl*[] trace;
}
immutable struct DiagSpecSigCantBeVariadic {}
immutable struct DiagSpecUseInvalid {
	DeclKind declKind;
}
enum DiagStringLiteralInvalid { cStringContainsNul, notExternJs, stringContainsNul, symbolContainsNul }
immutable struct DiagStorageMissingType {}
immutable struct DiagSumTypeListedMembersNonUnion {}
immutable struct DiagTestMissingBody {}
enum DiagTrustedUnnecessary { inTrusted, inUnsafeFunction, unused }
immutable struct DiagTupleTooBig {
	size_t actual;
	size_t maxAllowed;
}
immutable struct DiagTypeAnnotationUnnecessary {
	TypeWithContainer type;
}
immutable struct DiagTypeConflict {
	ExpectedForDiag expected;
	TypeWithContainer actual;
}
immutable struct DiagTypeParamCantHaveTypeArgs {}
immutable struct DiagTypeParamsUnsupported {
	DeclKind declKind;
}
enum DiagTypeShouldUseSyntax {
	array,
	funData,
	funMut,
	funPointer,
	funShared,
	map,
	mutArray,
	mutMap,
	mutPointer,
	opt,
	pointer,
	sharedArray,
	sharedMap,
	tuple,
}
immutable struct DiagUnionMemberTypeParameter {}
enum DiagUnsupportedSyntax { enumMemberMutability, enumMemberType }
immutable struct DiagUnusedImport {
	Module* importedModule;
	Opt!Symbol importedName;
}
immutable struct DiagUnusedLocal {
	Local* local;
	bool usedGet;
	bool usedSet;
}
immutable struct DiagUnusedPrivateDecl {
	Symbol name;
}
immutable struct DiagVarargsParamMustBeArray {}
immutable struct DiagMethodImplVisibility {
	StructDecl* member;
	StructInst* sumType;
	FunInst* methodImpl;
}
// We don't have any warning at the top-level even though '~' is redundant. This is only within a record.
immutable struct DiagVisibilityWarning {
	VisibilityWarningKind kind;
	Visibility defaultVisibility;
	Visibility actualVisibility;
}
immutable struct VisibilityWarningKind {
	mixin Union!(VisibilityWarningField, VisibilityWarningFieldMutability, VisibilityWarningNew);
}
immutable struct VisibilityWarningField { StructDecl* record; Symbol fieldName; }
immutable struct VisibilityWarningFieldMutability { Symbol fieldName; }
immutable struct VisibilityWarningNew { StructDecl* record; }

immutable struct DiagWithHasElse {}
immutable struct DiagWrongNumberTypeArgs {
	Symbol name;
	size_t nExpectedTypeArgs;
	size_t nActualTypeArgs;
}

enum AutoFunName { compare, equals, members, to }

immutable struct ExpectedForDiag {
	mixin Union!(ExpectedForDiagChoices, ExpectedForDiagInfer, ExpectedForDiagLoop);
}
immutable struct ExpectedForDiagChoices {
	Type[] types;
	TypeContainer typeContainer;
}
immutable struct ExpectedForDiagInfer {}
immutable struct ExpectedForDiagLoop {}
