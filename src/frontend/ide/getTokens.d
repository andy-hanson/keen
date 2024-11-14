module frontend.ide.getTokens;

@safe @nogc pure nothrow:

import std.range : iota;
import std.traits : EnumMembers;

import frontend.ide.ideUtil : walkAstInOrder;
import frontend.parse.lexWhitespace : lexTokensBetweenAsts;
import frontend.storage : CrowFileInfo;
import lib.lsp.lspTypes : SemanticTokens;
import model.ast :
	ArrowAccessAst,
	AssertOrForbidAst,
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
	ExternAst,
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
	NameAndRange,
	ParamsAst,
	ParenthesizedAst,
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
	TestAst,
	ThrowAst,
	TrustedAst,
	TryAst,
	TryLetAst,
	TypeAst,
	TypedAst,
	VarDeclAst,
	WithAst;
import util.alloc.alloc : Alloc;
import util.col.array : newArray, only, zip;
import util.col.arrayBuilder : add, addAll, ArrayBuilder, buildArray, Builder, finish;
import util.conv : safeToUint;
import util.json : field, Json, jsonList, jsonObject, jsonString;
import util.opt : force, has, Opt;
import util.sourceRange :
	LineAndCharacterGetter,
	LineAndCharacter,
	LineAndCharacterRange,
	lineLengthInCharacters,
	Pos,
	rangeContains,
	rangeOfStartAndLength,
	Range;
import util.string : CString, cStringSize;
import util.symbol : symbol;
import util.util : stringOfEnum;

SemanticTokens tokensOfAst(ref Alloc alloc, in CrowFileInfo file) {
	scope Ctx ctx = Ctx(TokensBuilder(file.content.content, &alloc, file.content.lineAndCharacterGetter));
	addDocCommentTokens(ctx, file.ast.docComment);
	walkAstInOrder!(
		Ctx,
		addImportTokens,
		addSpecTokens,
		addStructAliasTokens,
		addStructTokens,
		addFunTokens,
		addTestTokens,
		addVarDeclTokens,
	)(file.ast, ctx);
	addLastTokens(ctx.tokens);
	return SemanticTokens(finish(alloc, ctx.tokens.encoded));
}

Json jsonOfDecodedTokens(ref Alloc alloc, in SemanticTokens a) =>
	jsonList(buildArray!Json(alloc, (scope ref Builder!Json res) {
		decodeTokens(a, (in LineAndCharacter lc, size_t length, TokenType type, TokenModifiers modifiers) {
			res ~= jsonObject(alloc, [
				field!"line"(lc.line),
				field!"character"(lc.character),
				field!"length"(length),
				field!"type"(stringOfEnum(type)),
				field!"modifiers"(jsonList(modifiers == noTokenModifiers
					? []
					: newArray(alloc, [Json(stringOfTokenModifier(modifiers))])))]);
		});
	}));

Json getTokensLegend(ref Alloc alloc) {
	static immutable TokenType[] allTokenTypes = [EnumMembers!TokenType];
	static immutable TokenModifiers[] allTokenModifiers = [EnumMembers!TokenModifiers];
	return jsonObject(alloc, [
		field!"tokenTypes"(jsonList!TokenType(alloc, allTokenTypes, (in TokenType x) =>
			jsonString(stringOfEnum(x)))),
		field!"tokenModifiers"(jsonList!TokenModifiers(alloc, allTokenModifiers, (in TokenModifiers x) =>
			jsonString(stringOfTokenModifier(x))))]);
}

private:

struct Ctx {
	TokensBuilder tokens;
}

void decodeTokens(
	in SemanticTokens a,
	in void delegate(in LineAndCharacter, size_t, TokenType, TokenModifiers) @safe @nogc pure nothrow cb,
) {
	uint line = 0;
	uint character = 0;
	foreach (size_t i; iota(0, a.data.length, 5)) {
		uint deltaLine = a.data[i];
		uint deltaCharacter = a.data[i + 1];
		uint length = a.data[i + 2];
		TokenType type = cast(TokenType) a.data[i + 3];
		TokenModifiers modifiers = cast(TokenModifiers) a.data[i + 4];
		if (deltaLine == 0)
			character += deltaCharacter;
		else {
			line += deltaLine;
			character = deltaCharacter;
		}
		cb(LineAndCharacter(line, character), length, type, modifiers);
	}
}

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokenTypes
enum TokenType {
	comment,
	enum_,
	enumMember,
	function_,
	interface_,
	keyword,
	namespace,
	number,
	parameter,
	property,
	string,
	type,
	typeParameter,
	variable,
}
// This will be a flags enum
enum TokenModifiers {
	declaration = 1,
}

TokenModifiers noTokenModifiers() =>
	cast(TokenModifiers) 0;

string stringOfTokenModifier(TokenModifiers a) {
	final switch (a) {
		case TokenModifiers.declaration:
			return "declaration";
	}
}

struct TokensBuilder {
	CString source;
	Alloc* alloc;
	LineAndCharacterGetter lineAndCharacterGetter;
	ArrayBuilder!(immutable uint) encoded;
	Pos prevPos;
	uint prevLine;
	uint prevCharacter;
}
void add(scope ref TokensBuilder a, Range range, TokenType type, TokenModifiers modifiers) {
	if (range.length != 0) { // This can happen for missing names
		advanceTo(a, range.start);
		a.prevPos = range.end;
		addInner(a, range, type, modifiers);
	}
}

void advanceTo(scope ref TokensBuilder a, Pos pos) {
	addTokensBetween(a, Range(a.prevPos, pos));
	a.prevPos = pos;
}

void addLastTokens(scope ref TokensBuilder a) {
	advanceTo(a, a.prevPos + safeToUint(cStringSize((() @trusted => a.source.jumpTo(a.prevPos))())));
}

void addInner(scope ref TokensBuilder a, Range range, TokenType type, TokenModifiers modifiers) {
	LineAndCharacterRange lcRange = a.lineAndCharacterGetter[range];
	LineAndCharacter start = lcRange.start;
	LineAndCharacter end = lcRange.end;
	if (start.line == end.line)
		addSingleLineToken(a, start, end.character - start.character, type, modifiers);
	else {
		uint firstLength = lineLengthInCharacters(a.lineAndCharacterGetter, start.line) - start.character;
		addSingleLineToken(a, start, firstLength, type, modifiers);
		foreach (uint line; start.line + 1 .. end.line)
			addSingleLineToken(
				a, LineAndCharacter(line, 0), lineLengthInCharacters(a.lineAndCharacterGetter, line), type, modifiers);
		addSingleLineToken(a, LineAndCharacter(end.line, 0), end.character, type, modifiers);
	}
}

void addSingleLineToken(
	scope ref TokensBuilder a,
	in LineAndCharacter pos,
	uint length,
	TokenType type,
	TokenModifiers modifiers,
) {
	assert(a.prevLine < pos.line ||
		(a.prevLine == pos.line && a.prevCharacter < pos.character) ||
		(a.prevLine == 0 && a.prevCharacter == 0));
	immutable uint[5] toAdd = pos.line == a.prevLine
		? [0, pos.character - a.prevCharacter, length, type, modifiers]
		: [pos.line - a.prevLine, pos.character, length, type, modifiers];
	addAll!(immutable uint)(*a.alloc, a.encoded, toAdd);
	a.prevLine = pos.line;
	a.prevCharacter = pos.character;
}

@trusted void addTokensBetween(scope ref TokensBuilder a, Range range) {
	lexTokensBetweenAsts(
		a.source, range,
		(Range commentRange) {
			assert(rangeContains(range, commentRange));
			addInner(a, commentRange, TokenType.comment, noTokenModifiers);
		},
		(Range keywordRange) {
			assert(rangeContains(range, keywordRange));
			addInner(a, keywordRange, TokenType.keyword, noTokenModifiers);
		});
}

void declare(scope ref TokensBuilder a, TokenType type, in Range range) {
	add(a, range, type, TokenModifiers.declaration);
}
void reference(scope ref TokensBuilder a, TokenType type, in Range range) {
	add(a, range, type, noTokenModifiers);
}
void keyword(scope ref TokensBuilder a, in Range range) {
	reference(a, TokenType.keyword, range);
}
void keyword(scope ref TokensBuilder a, Pos start, in string name) {
	keyword(a, rangeOfStartAndLength(start, name.length));
}
void numberLiteral(scope ref TokensBuilder a, in Range range) {
	reference(a, TokenType.number, range);
}
void stringLiteral(scope ref TokensBuilder a, in Range range) {
	reference(a, TokenType.string, range);
}

void addDocCommentTokens(scope ref Ctx ctx, in DocCommentAst a) {
	if (!a.isEmpty) {
		Range range = force(a.range);
		Pos pos = range.start;
		foreach (TypeAst x; a.references) {
			reference(ctx.tokens, TokenType.comment, Range(pos, x.range.start));
			reference(ctx.tokens, TokenType.variable, x.range);
			pos = x.range.end;
		}
		reference(ctx.tokens, TokenType.comment, Range(pos, range.end));
	}
}

void addImportTokens(scope ref Ctx ctx, in ImportsOrExportsAst a) {
	foreach (ref ImportOrExportAst x; a.paths) {
		reference(ctx.tokens, TokenType.namespace, x.pathRange);
		x.kind.matchIn!void(
			(in ImportOrExportAstKind.ModuleWhole) {},
			(in NameAndRange[] names) {
				foreach (NameAndRange name; names)
					reference(ctx.tokens, TokenType.variable, name.range);
			},
			(in ImportOrExportAstKind.File x) {
				declare(ctx.tokens, TokenType.variable, x.name.range);
				addTypeTokens(ctx, x.typeAst);
			});
	}
}

void addSpecTokens(scope ref Ctx ctx, in SpecDeclAst a) {
	addDocCommentTokens(ctx, a.docComment);
	declare(ctx.tokens, TokenType.interface_, a.name.range);
	addTypeParamsTokens(ctx, a.typeParams);
	addModifierTokens(ctx, a.modifiers);
	foreach (ref SignatureAst x; a.sigs)
		addSignatureTokens(ctx, x);
}

void addSignatureTokens(scope ref Ctx ctx, in SignatureAst a) {
	addDocCommentTokens(ctx, a.docComment);
	declare(ctx.tokens, TokenType.function_, a.nameRange);
	addSigReturnTypeAndParamsTokens(ctx, a.returnType, a.params);
}

void addSigReturnTypeAndParamsTokens(scope ref Ctx ctx, in TypeAst returnType, in ParamsAst params) {
	addTypeTokens(ctx, returnType);
	addParamsTokens(ctx, params);
}

void addParamsTokens(scope ref Ctx ctx, in ParamsAst params) {
	params.matchIn!void(
		(in DestructureAst[] regular) {
			foreach (ref DestructureAst param; regular)
				addDestructureTokens(ctx, param);
		},
		(in ParamsAst.Varargs) {
			addDestructureTokens(ctx, params.as!(ParamsAst.Varargs*).param);
		});
}

void addTypeTokens(scope ref Ctx ctx, in TypeAst a) {
	a.matchIn!void(
		(in TypeAst.Bogus) {},
		(in TypeAst.Fun x) {
			addTypeTokens(ctx, x.returnType);
			addParamsTokens(ctx, x.params);
		},
		(in TypeAst.Map x) {
			addTypeTokens(ctx, x.v);
			addTypeTokens(ctx, x.k);
		},
		(in NameAndRange x) {
			reference(ctx.tokens, TokenType.type, x.range);
		},
		(in TypeAst.SuffixName x) {
			addTypeTokens(ctx, x.left);
			reference(ctx.tokens, TokenType.type, x.name.range);
		},
		(in TypeAst.SuffixSpecial x) {
			addTypeTokens(ctx, x.left);
			declare(ctx.tokens, TokenType.type, x.suffixRange);
		},
		(in TypeAst.Tuple x) {
			foreach (TypeAst t; x.members)
				addTypeTokens(ctx, t);
		});
}

void addTypeParamsTokens(scope ref Ctx ctx, in NameAndRange[] a) {
	foreach (NameAndRange typeParam; a)
		declare(ctx.tokens, TokenType.typeParameter, typeParam.range);
}

void addStructAliasTokens(scope ref Ctx ctx, in StructAliasAst a) {
	addDocCommentTokens(ctx, a.docComment);
	declare(ctx.tokens, TokenType.type, a.name.range);
	addTypeParamsTokens(ctx, a.typeParams);
	addTypeTokens(ctx, a.target);
}

void addStructTokens(scope ref Ctx ctx, in StructDeclAst a) {
	addDocCommentTokens(ctx, a.docComment);
	declare(ctx.tokens, TokenType.type, a.name.range);
	addTypeParamsTokens(ctx, a.typeParams);
	a.body_.matchIn!void(
		(in StructBodyAst.Builtin) {
			addModifierTokens(ctx, a.modifiers);
		},
		(in StructBodyAst.Enum x) {
			addEnumOrFlagsTokens(ctx, a, x.params, x.members);
		},
		(in StructBodyAst.Extern) {
			addModifierTokens(ctx, a.modifiers);
		},
		(in StructBodyAst.Flags x) {
			addEnumOrFlagsTokens(ctx, a, x.params, x.members);
		},
		(in StructBodyAst.Record x) {
			addRecordOrUnionTokens(ctx, a, x.params, x.fields, TokenType.property);
		},
		(in StructBodyAst.Union x) {
			addRecordOrUnionTokens(ctx, a, x.params, x.members, TokenType.enumMember);
		},
		(in StructBodyAst.Variant x) {
			addModifierTokens(ctx, a.modifiers);
			foreach (ref TypeAst type; x.types)
				addTypeTokens(ctx, type);
			foreach (ref SignatureAst sig; x.methods)
				addSignatureTokens(ctx, sig);
		});
}

void addRecordOrUnionTokens(
	scope ref Ctx ctx,
	in StructDeclAst a,
	in Opt!ParamsAst params,
	in RecordOrUnionMemberAst[] members,
	TokenType memberTokenType,
) {
	if (has(params))
		addParamsTokens(ctx, force(params));
	addModifierTokens(ctx, a.modifiers);
	foreach (ref RecordOrUnionMemberAst x; members) {
		addDocCommentTokens(ctx, x.docComment);
		declare(ctx.tokens, memberTokenType, x.name.range);
		if (has(x.type))
			addTypeTokens(ctx, force(x.type));
	}
}

void addModifierTokens(scope ref Ctx ctx, in ModifierAst[] a) {
	foreach (ref ModifierAst mod; a) {
		mod.matchIn!void(
			(in ModifierAst.Keyword x) {
				if (has(x.typeArg))
					addTypeTokens(ctx, force(x.typeArg));
			},
			(in SpecUseAst x) {
				if (has(x.typeArg))
					addTypeTokens(ctx, force(x.typeArg));
				reference(ctx.tokens, TokenType.interface_, x.name.range);
			});
	}
}

void addEnumOrFlagsTokens(
	scope ref Ctx ctx,
	in StructDeclAst a,
	in Opt!ParamsAst params,
	in EnumOrFlagsMemberAst[] members,
) {
	if (has(params))
		addParamsTokens(ctx, force(params));
	addModifierTokens(ctx, a.modifiers);
	foreach (ref EnumOrFlagsMemberAst member; members) {
		addDocCommentTokens(ctx, member.docComment);
		declare(ctx.tokens, TokenType.enumMember, member.nameRange);
		if (has(member.value))
			numberLiteral(ctx.tokens, force(member.value).range);
	}
}

void addVarDeclTokens(scope ref Ctx ctx, in VarDeclAst a) {
	addDocCommentTokens(ctx, a.docComment);
	declare(ctx.tokens, TokenType.variable, a.name.range);
	addTypeParamsTokens(ctx, a.typeParams);
	addTypeTokens(ctx, a.type);
	addModifierTokens(ctx, a.modifiers);
}

void addFunTokens(scope ref Ctx ctx, in FunDeclAst a) {
	addDocCommentTokens(ctx, a.docComment);
	declare(ctx.tokens, TokenType.function_, a.name.range);
	addTypeParamsTokens(ctx, a.typeParams);
	addSigReturnTypeAndParamsTokens(ctx, a.returnType, a.params);
	addModifierTokens(ctx, a.modifiers);
	addExprTokens(ctx, a.body_);
}

void addTestTokens(scope ref Ctx ctx, in TestAst a) {
	addDocCommentTokens(ctx, a.docComment);
	addExprTokens(ctx, a.body_);
}

void addExprTokens(scope ref Ctx ctx, in ExprAst a) {
	a.kind.matchIn!void(
		(in ArrowAccessAst x) {
			addExprTokens(ctx, *x.left);
			reference(ctx.tokens, TokenType.function_, x.name.range);
		},
		(in AssertOrForbidAst x) {
			// Only the length matters, and "assert" is same length as "forbid"
			keyword(ctx.tokens, a.range.start, "assert");
			addConditionTokens(ctx, x.condition);
			if (has(x.thrown))
				addExprTokens(ctx, force(x.thrown).expr);
			addExprTokens(ctx, *x.after);
		},
		(in AssignmentAst x) {
			addExprTokens(ctx, x.left);
			keyword(ctx.tokens, x.assignmentPos, ":=");
			addExprTokens(ctx, x.right);
		},
		(in AssignmentCallAst x) {
			addExprTokens(ctx, x.left);
			reference(ctx.tokens, TokenType.function_, x.funName.range);
			addExprTokens(ctx, x.right);
		},
		(in BogusAst _) {},
		(in CallAst x) {
			void addName() {
				reference(ctx.tokens, TokenType.function_, x.funName.range);
				if (has(x.typeArg))
					addTypeTokens(ctx, *force(x.typeArg));
			}
			final switch (x.style) {
				case CallAst.Style.dot:
				case CallAst.Style.infix:
				case CallAst.Style.questionDot:
					addExprTokens(ctx, x.args[0]);
					addName();
					addExprsTokens(ctx, x.args[1 .. $]);
					break;
				case CallAst.Style.prefixBang:
					reference(ctx.tokens, TokenType.function_, rangeOfStartAndLength(x.funName.start, "!".length));
					addExprTokens(ctx, only(x.args));
					break;
				case CallAst.Style.suffixBang:
					addExprTokens(ctx, only(x.args));
					reference(ctx.tokens, TokenType.function_, rangeOfStartAndLength(x.funName.start, "!".length));
					break;
				case CallAst.style.emptyParens:
					break;
				case CallAst.style.prefixOperator:
				case CallAst.Style.single:
					addName();
					addExprsTokens(ctx, x.args);
					break;
				case CallAst.Style.augment:
				case CallAst.Style.comma:
				case CallAst.Style.subscript:
				case CallAst.Style.questionSubscript:
					addExprsTokens(ctx, x.args);
					break;
			}
		},
		(in CallNamedAst x) {
			zip(x.names, x.args, (ref NameAndRange name, ref ExprAst arg) {
				reference(ctx.tokens, TokenType.parameter, name.range);
				addExprTokens(ctx, arg);
			});
		},
		(in DoAst x) {
			addExprTokens(ctx, *x.body_);
		},
		(in EmptyAst x) {},
		(in ExternAst x) {
			foreach (NameAndRange name; x.names)
				reference(ctx.tokens, TokenType.namespace, name.range);
		},
		(in FinallyAst x) {
			addExprTokens(ctx, x.right);
			addExprTokens(ctx, x.below);
		},
		(in ForAst x) {
			addDestructureTokens(ctx, x.param);
			addExprTokens(ctx, x.collection);
			addExprTokens(ctx, x.body_);
			addExprTokens(ctx, x.else_);
		},
		(in IdentifierAst _) {
			reference(ctx.tokens, TokenType.variable, a.range);
		},
		(in IfAst x) {
			addConditionTokens(ctx, x.condition);
			foreach (ExprAst branch; x.allBranches)
				addExprTokens(ctx, branch);
		},
		(in InterpolatedAst x) {
			foreach (size_t i, ref ExprAst part; x.parts) {
				if (part.kind.isA!LiteralStringAst)
					// Extend the range to include the opening or closing '"'
					stringLiteral(ctx.tokens, Range(
						i == 0 ? a.range.start : part.range.start,
						i == x.parts.length - 1 ? a.range.end : part.range.end));
				else
					addExprTokens(ctx, part);
			}
		},
		(in LambdaAst x) {
			addDestructureTokens(ctx, x.param);
			addExprTokens(ctx, x.body_);
		},
		(in LetAst x) {
			addDestructureTokens(ctx, x.destructure);
			addExprTokens(ctx, x.value);
			addExprTokens(ctx, x.then);
		},
		(in LiteralFloatAst _) {
			numberLiteral(ctx.tokens, a.range);
		},
		(in LiteralIntegral _) {
			numberLiteral(ctx.tokens, a.range);
		},
		(in LiteralStringAst _) {
			stringLiteral(ctx.tokens, a.range);
		},
		(in LoopAst x) {
			addExprTokens(ctx, x.body_);
		},
		(in LoopBreakAst x) {
			addExprTokens(ctx, x.value);
		},
		(in LoopContinueAst _) {},
		(in LoopWhileOrUntilAst x) {
			addConditionTokens(ctx, x.condition);
			addExprTokens(ctx, x.body_);
			addExprTokens(ctx, x.after);
		},
		(in MatchAst x) {
			addExprTokens(ctx, *x.matched);
			foreach (ref CaseAst case_; x.cases)
				addCaseTokens(ctx, case_);
			if (has(x.else_))
				addExprTokens(ctx, force(x.else_).expr);
		},
		(in ParenthesizedAst x) {
			addExprTokens(ctx, x.inner);
		},
		(in PtrAst x) {
			addExprTokens(ctx, x.inner);
		},
		(in SeqAst x) {
			addExprTokens(ctx, x.first);
			addExprTokens( ctx, x.then);
		},
		(in SharedAst x) {
			addExprTokens(ctx, x.inner);
		},
		(in ThrowAst x) {
			addExprTokens(ctx, x.thrown);
		},
		(in TrustedAst x) {
			addExprTokens(ctx, x.inner);
		},
		(in TryAst x) {
			addExprTokens(ctx, *x.tried);
			foreach (ref CaseAst case_; x.catches)
				addCaseTokens(ctx, case_);
		},
		(in TryLetAst x) {
			addDestructureTokens(ctx, x.destructure);
			addExprTokens(ctx, x.value);
			addCaseMemberTokens(ctx, x.catchMember);
			addExprTokens(ctx, x.catch_);
			addExprTokens(ctx, x.then);
		},
		(in TypedAst x) {
			addExprTokens(ctx, x.expr);
			addTypeTokens(ctx, x.type);
		},
		(in WithAst x) {
			addDestructureTokens(ctx, x.param);
			addExprTokens(ctx, x.arg);
			addExprTokens(ctx, x.body_);
		});
}

void addCaseTokens(scope ref Ctx ctx, in CaseAst a) {
	addCaseMemberTokens(ctx, a.member);
	addExprTokens(ctx, a.then);
}

void addCaseMemberTokens(scope ref Ctx ctx, in CaseMemberAst a) {
	a.matchIn!void(
		(in CaseMemberAst.Name x) {
			reference(ctx.tokens, TokenType.enumMember, x.name.range);
			if (has(x.destructure))
				addDestructureTokens(ctx, force(x.destructure));
		},
		(in LiteralIntegralAndRange x) {
			numberLiteral(ctx.tokens, x.range);
		},
		(in CaseMemberAst.String x) {
			stringLiteral(ctx.tokens, x.range);
		},
		(in CaseMemberAst.Bogus) {});
}

void addConditionTokens(scope ref Ctx ctx, in ConditionAst a) {
	a.matchIn!void(
		(in ExprAst x) {
			addExprTokens(ctx, x);
		},
		(in ConditionAst.UnpackOption x) {
			addDestructureTokens(ctx, x.destructure);
			addExprTokens(ctx, *x.option);
		});
}

void addDestructureTokens(scope ref Ctx ctx, in DestructureAst a) {
	a.matchIn!void(
		(in DestructureAst.Single x) {
			declare(
				ctx.tokens,
				x.name.name == symbol!"_" ? TokenType.comment : TokenType.parameter,
				x.name.range);
			//TODO: add 'mut' keyword
			if (has(x.type))
				addTypeTokens(ctx, *force(x.type));
		},
		(in DestructureAst.Void x) {
			keyword(ctx.tokens, a.range);
		},
		(in DestructureAst[] xs) {
			foreach (ref DestructureAst x; xs)
				addDestructureTokens(ctx, x);
		});
}

void addExprsTokens(scope ref Ctx ctx, in ExprAst[] exprs) {
	foreach (ref ExprAst expr; exprs)
		addExprTokens(ctx, expr);
}
