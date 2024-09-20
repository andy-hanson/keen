module frontend.ide.getHover;

@safe @nogc pure nothrow:

import frontend.ide.position : ExpressionPosition, ExpressionPositionKind, ExprKeyword, Position, PositionKind;
import frontend.showModel :
	ShowModelCtx,
	writeCalled,
	writeFile,
	writeFunDecl,
	writeName,
	writeSpecInst,
	writeTypeQuoted,
	writeTypeUnquoted,
	writeVisibility;
import lib.lsp.lspTypes : Hover, MarkupContent, MarkupKind;
import model.ast :
	AssertOrForbidAst, ConditionAst, ExprAst, ExprAstKind, IfAst, ImportOrExportAstKind, MatchAst, ModifierKeyword;
import model.diag : TypeContainer, TypeWithContainer;
import model.model :
	asBuiltinExtern,
	AssertOrForbidExpr,
	BuiltinExtern,
	BuiltinType,
	CallExpr,
	CallOptionExpr,
	CharType,
	Condition,
	EnumOrFlagsMember,
	Expr,
	ExprKind,
	ExprRef,
	ExternExpr,
	FunDecl,
	FunPointerExpr,
	IntegralType,
	isSigned,
	LambdaExpr,
	Local,
	LoopWhileOrUntilExpr,
	nameFromNameReferentsPointer,
	NameReferents,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchUnionExpr,
	MatchVariantExpr,
	RecordField,
	StructAlias,
	StructBody,
	SpecDecl,
	stringOfVarKindUpperCase,
	StructDecl,
	StructInst,
	Test,
	TryExpr,
	Type,
	TypeParamIndex,
	UnionMember,
	VarDecl;
import util.alloc.alloc : Alloc;
import util.col.hashTable : withSortedKeys;
import util.conv : safeToUint;
import util.opt : force, has, Opt;
import util.sourceRange : PosKind;
import util.symbol : compareSymbolsAlphabetically, Symbol;
import util.uri : Uri;
import util.util : stringOfEnum;
import util.writer : makeStringWithWriter, writeNewline, writeQuotedChar, writeQuotedString, Writer, writeWithCommas;

Hover getHover(ref Alloc alloc, in ShowModelCtx ctx, in Position pos) =>
	Hover(MarkupContent(MarkupKind.plaintext, makeStringWithWriter(alloc, (scope ref Writer writer) {
		getHover(writer, ctx, pos);
	})));

void getHover(scope ref Writer writer, in ShowModelCtx ctx, in Position pos) =>
	pos.kind.matchWithPointers!void(
		(EnumOrFlagsMember* x) {
			writer ~= x.containingEnum.body_.isA!(StructBody.Enum*) ? "Enum " : "Flags ";
			writer ~= " member ";
			writer ~= x.containingEnum.name;
			writer ~= '.';
			writer ~= x.name;
		},
		(ExpressionPosition x) {
			getExprHover(writer, ctx, pos.module_.uri, x);
		},
		(FunDecl* x) {
			writeFunDecl(writer, ctx, x);
		},
		(PositionKind.ImportedModule x) {
			writer ~= "Import module ";
			writeFile(writer, ctx, x.module_.uri);
			if (x.import_.hasImported && force(x.import_.source).kind.isA!(ImportOrExportAstKind.ModuleWhole)) {
				writer ~= "(using: ";
				withSortedKeys!(void, NameReferents*, Symbol, nameFromNameReferentsPointer)(
					x.import_.imported,
					(in Symbol x, in Symbol y) => compareSymbolsAlphabetically(x, y),
					(in Symbol[] names) {
						writeWithCommas!Symbol(writer, names, (in Symbol name) { writer ~= name; });
					});
				writer ~= ')';
			}
		},
		(PositionKind.ImportedName x) {
			getImportedNameHover(writer, ctx, x);
		},
		(PositionKind.Keyword x) {
			writer ~= () {
				final switch (x.kind) {
					case PositionKind.Keyword.Kind.alias_:
						return "Declares a type alias.";
					case PositionKind.Keyword.Kind.builtin:
						return "Declares a type implemented natively by Crow.";
					case PositionKind.Keyword.Kind.enum_:
						return "Declares an enumerated type. The type can only have the values listed.";
					case PositionKind.Keyword.Kind.extern_:
						return "Declares a type implemented by an external library.";
					case PositionKind.Keyword.Kind.flags:
						return "Declares a type that can have any combination of flags (this would be an 'enum' in C)";
					case PositionKind.Keyword.Kind.global:
						return "Declares a mutable global variable (shared between all threads).";
					case PositionKind.Keyword.Kind.localMut:
						return "Makes this a mutable variable.";
					case PositionKind.Keyword.Kind.record:
						return "Declares a type combining several named members.";
					case PositionKind.Keyword.Kind.spec:
						return "Specifies function signatures which to be provided by a function's caller.";
					case PositionKind.Keyword.Kind.threadLocal:
						return "Declares a mutable thread-local variable.";
					case PositionKind.Keyword.Kind.underscore:
						return "Ignores the value.";
					case PositionKind.Keyword.Kind.union_:
						return "Declares a type where a value will be one of the listed choices.";
					case PositionKind.Keyword.Kind.variant:
						return "Declares a union-like type with an unlimited set of members, " ~
							"created by 'variant-member' declarations.";
					case PositionKind.Keyword.Kind.variantMember:
						return "Adds a member to a variant type.";
				}
			}();
		},
		(PositionKind.LocalPosition x) {
			writer ~= "Local ";
			writeName(writer, ctx, x.local.name);
			writer ~= " of type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.local.type, x.container.toTypeContainer));
		},
		(PositionKind.MatchEnumCase x) {
			writer ~= "Handler for enum ";
			writeName(writer, ctx, x.member.containingEnum.name);
			writer ~= " member ";
			writeName(writer, ctx, x.member.name);
		},
		(PositionKind.MatchIntegralCase x) {
			writer ~= "Handler for value ";
			x.kind.matchIn!void(
				(in CharType t) {
					writeQuotedChar(writer, dchar(safeToUint(x.value.asUnsigned())));
					writer ~= " :: ";
					writeName(writer, ctx, stringOfEnum(t));
				},
				(in IntegralType t) {
					if (isSigned(t))
						writer ~= x.value.asSigned();
					else
						writer ~= x.value.asUnsigned();
					writer ~= " :: ";
					writeName(writer, ctx, stringOfEnum(t));
				});
		},
		(PositionKind.MatchStringLikeCase x) {
			writer ~= "Handler for value ";
			writeQuotedString(writer, x.value);
			writer ~= " :: ";
			writeTypeUnquoted(writer, ctx, x.type);
		},
		(PositionKind.MatchUnionCase x) {
			writer ~= "Handler for union ";
			writeName(writer, ctx, x.member.containingUnion.name);
			writer ~= " member ";
			writeName(writer, ctx, x.member.name);
		},
		(PositionKind.MatchVariantCase x) {
			writer ~= "Handler for type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(Type(x.member), x.container.toTypeContainer));
		},
		(PositionKind.Modifier x) {
			writer ~= () {
				final switch (x.modifier) {
					case ModifierKeyword.bare:
						return "This function does not use the Crow runtime.";
					case ModifierKeyword.builtin:
						return "This function is implemented natively by Crow.";
					case ModifierKeyword.byRef:
						return "This type is behind a pointer.\n" ~
							"This is more efficient if there are many references to the same value.";
					case ModifierKeyword.byVal:
						return "This type is stored by-value.\n" ~
							"This avoids allocation but each place this value is used has its own copy of the content.";
					case ModifierKeyword.data:
						return "The type is completely immutable.";
					case ModifierKeyword.extern_:
						return "This type is compatible with external libraries.";
					case ModifierKeyword.forceCtx:
						return "This function uses the runtime, but 'bare' functions can call it. " ~
							"(Don't use outside of the Crow runtime.)";
					case ModifierKeyword.forceShared:
						return "This type is be considered 'shared' even though it has 'mut' content.";
					case ModifierKeyword.mut:
						return "This type is either directly mutable or references something mutable.";
					case ModifierKeyword.newInternal:
						return "The 'new' function is internal.";
					case ModifierKeyword.newPrivate:
						return "The 'new' function is private.";
					case ModifierKeyword.newPublic:
						return "The 'new' function is public.";
					case ModifierKeyword.nominal:
						return "The type's constructor uses the type's name instead of 'new'.";
					case ModifierKeyword.packed:
						return "The type will be laid out without gaps for alignment.";
					case ModifierKeyword.pure_:
						return "Marks an 'extern' function as not 'summon', meaning it following Crow's purity rules.";
					case ModifierKeyword.shared_:
						return "The type is mutable, but in a way that is safe to share between concurrent tasks.";
					case ModifierKeyword.storage:
						return "Determines the type of number used to store the enum.";
					case ModifierKeyword.summon:
						return "This function can directly access all I/O capabilities.";
					case ModifierKeyword.trusted:
						return "This function is not unsafe, but can do unsafe things internally.";
					case ModifierKeyword.unsafe:
						return "This function can only be called by 'trusted' or 'unsafe' functions.";
					case ModifierKeyword.variantMember:
						return "This type can be used as a member of the variant. " ~
							"It must implement the variant's methods, if any.";
				}
			}();
		},
		(PositionKind.ModifierExtern x) {
			writer ~= "Function comes from external library ";
			writeName(writer, ctx, x.libraryName);
			writer ~= '.';
		},
		(RecordField* x) {
			writer ~= "Record field ";
			writer ~= x.containingRecord.name;
			writer ~= '.';
			writer ~= x.name;
			writer ~= " :: ";
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.type, TypeContainer(x.containingRecord)));
		},
		(PositionKind.RecordFieldMutability x) {
			writer ~= "Defines a ";
			if (has(x.visibility)) {
				writeVisibility(writer, ctx.show, force(x.visibility));
				writer ~= ' ';
			}
			writer ~= "setter.";
		},
		(SpecDecl* x) {
			writeSpecDeclHover(writer, ctx, *x);
		},
		(PositionKind.SpecSig x) {
			writer ~= "Spec ";
			writeName(writer, ctx, x.spec.name);
			writer ~= " signature ";
			writeName(writer, ctx, x.sig.name);
		},
		(PositionKind.SpecUse x) {
			writer ~= "Spec ";
			writeSpecInst(writer, ctx, x.container, *x.spec);
		},
		(StructAlias* x) {
			writeStructAliasHover(writer, ctx, x);
		},
		(StructDecl* x) {
			writeStructDeclHover(writer, ctx, *x);
		},
		(Test* x) {
			writer ~= "Declares a unit test.";
		},
		(TypeWithContainer x) {
			x.type.matchIn!void(
				(in Type.Bogus) {},
				(in TypeParamIndex p) {
					hoverTypeParam(writer, ctx, x.container, p);
				},
				(in StructInst i) {
					writeStructDeclHover(writer, ctx, *i.decl);
				});
		},
		(PositionKind.TypeParamWithContainer x) {
			hoverTypeParam(writer, ctx, x.container, x.typeParam);
		},
		(UnionMember* x) {
			writer ~= "Union member ";
			writer ~= x.containingUnion.name;
			writer ~= '.';
			writer ~= x.name;
			if (x.type == Type(ctx.commonTypes.void_))
				writer ~= " (no associated value)";
			else {
				writer ~= " :: ";
				writeTypeUnquoted(writer, ctx, TypeWithContainer(x.type, TypeContainer(x.containingUnion)));
			}
		},
		(VarDecl* x) {
			writer ~= stringOfVarKindUpperCase(x.kind);
			writer ~= " variable ";
			writeName(writer, ctx, x.name);
			writer ~= " :: ";
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.type, TypeContainer(x)));
		},
		(PositionKind.VariantMethod x) {
			writer ~= "Variant ";
			writeName(writer, ctx, x.variant.name);
			writer ~= " method ";
			writeName(writer, ctx, x.method.name);
		},
		(PositionKind.VisibilityMark x) {
			writer ~= "Marks ";
			writeName(writer, ctx, x.container.name);
			writer ~= " as ";
			writeVisibility(writer, ctx, x.container.visibility);
			writer ~= '.';
		});

private:

void writeStructAliasHover(scope ref Writer writer, in ShowModelCtx ctx, in StructAlias* a) {
	writer ~= "Alias for ";
	writeTypeQuoted(writer, ctx, TypeWithContainer(Type(a.target), TypeContainer(a)));
}

void writeStructDeclHover(scope ref Writer writer, in ShowModelCtx ctx, in StructDecl a) {
	writer ~= a.body_.matchIn!string(
		(in StructBody.Bogus) =>
			"Type ",
		(in BuiltinType _) =>
			"Builtin type ",
		(in StructBody.Enum) =>
			"Enum type ",
		(in StructBody.Extern) =>
			"Extern type ",
		(in StructBody.Flags) =>
			"Flags type ",
		(in StructBody.Record) =>
			"Record type ",
		(in StructBody.Union) =>
			"Union type ",
		(in StructBody.Variant) =>
			"Variant type ");
	writeName(writer, ctx, a.name);
}

void writeSpecDeclHover(scope ref Writer writer, in ShowModelCtx ctx, in SpecDecl a) {
	writer ~= "Spec ";
	writeName(writer, ctx, a.name);
}

void getImportedNameHover(scope ref Writer writer, in ShowModelCtx ctx, in PositionKind.ImportedName a) {
	if (has(a.referents)) {
		bool first = true;
		void separate() {
			if (!first)
				writeNewline(writer, 0);
			first = false;
		}

		NameReferents* referents = force(a.referents);
		if (has(referents.structOrAlias)) {
			force(referents.structOrAlias).matchWithPointers!void(
				(StructAlias* x) {
					separate();
					writeStructAliasHover(writer, ctx, x);
				},
				(StructDecl* x) {
					separate();
					writeStructDeclHover(writer, ctx, *x);
				});
		}
		if (has(referents.spec)) {
			separate();
			writeSpecDeclHover(writer, ctx, *force(referents.spec));
		}
		foreach (FunDecl* x; referents.funs) {
			separate();
			writeFunDecl(writer, ctx, x);
		}
	}
}

void hoverTypeParam(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in TypeContainer typeContainer,
	in TypeParamIndex index,
) {
	writer ~= "Type parameter ";
	writeName(writer, ctx, typeContainer.typeParams[index.index].name);
}

void getExprKeywordHover(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in Uri curUri,
	in TypeContainer typeContainer,
	in ExprRef a,
	ExprKeyword keyword,
) {
	ExprKind exprKind() =>
		a.expr.kind;
	ExprAstKind astKind() =>
		a.expr.ast.kind;
	final switch (keyword) {
		case ExprKeyword.ampersand:
			writer ~= "Gets a pointer to an expression. " ~
				"This does not allocate and so is unsafe. This only works for certain expressions.";
			break;
		case ExprKeyword.assert_:
			writer ~= exprKind.as!(AssertOrForbidExpr*).condition.matchIn!string(
				(in Expr _) => "Throws if the condition is 'false'.",
				(in Condition.UnpackOption _) => "Throws if the option is empty.");
			break;
		case ExprKeyword.colonColon:
			writer ~= "Provides an expected type for the expression to its left.";
			break;
		case ExprKeyword.colonInAssertOrForbid:
			writer ~= "If the condition is '";
			writer ~= astKind.as!AssertOrForbidAst.isForbid ? "true" : "false";
			writer ~= "', throws an exception with the message to the right of the ':'.";
			break;
		case ExprKeyword.colonInFor:
			writer ~= "The expression to the right of the ':' is the first argument to 'for-loop' or 'for-break'.";
			break;
		case ExprKeyword.colonInIf:
			writer ~= "If the condition is 'false', returns the expression to the right of the colon.";
			break;
		case ExprKeyword.colonInWith:
			writer ~= "The expression to the right of the ':' is the first argument to 'with-block'.";
			break;
		case ExprKeyword.elif:
			writer ~= "If the first condition is false, evaluates another 'if'.";
			break;
		case ExprKeyword.else_:
			writer ~= astKind.isA!MatchAst
				? "If no branch was satisfied, the 'match' evaluates to the 'else' branch."
				: "If the condition is 'false', the 'else' branch is evaluated.";
			break;
		case ExprKeyword.finally_:
			writer ~= "The expression below 'finally' runs first.\n" ~
				"The expression to the right of 'finally' runs second, even if there was an exception.\n" ~
				"The result is from the below expression; the right expression must be 'void'.";
			break;
		case ExprKeyword.forbid:
			writer ~= exprKind.as!(AssertOrForbidExpr*).condition.matchIn!string(
				(in Expr _) => "Throws if the condition is 'true'.",
				(in Condition.UnpackOption _) => "Throws if the option is non-empty.");
			break;
		case ExprKeyword.guardIfOrUnless:
			IfAst ifAst = astKind.as!IfAst;
			bool isUnpackOption = ifAst.condition.matchIn!bool(
				(in ExprAst _) => false,
				(in ConditionAst.UnpackOption) => true);
			final switch (ifAst.kind) {
				case IfAst.Kind.guardWithColon:
				case IfAst.Kind.guardWithoutColon:
					writer ~= isUnpackOption
						? "If the option is non-empty, destructures it and continues."
						: "If the expression is 'true', continues.";
					writer ~= '\n';
					writer ~= ifAst.kind == IfAst.Kind.guardWithColon
						? "Otherwise, returns the expression after the ':'."
						: "Otherwise, returns '()'.";
					break;
				case IfAst.Kind.ifWithoutElse:
				case IfAst.Kind.ifElif:
				case IfAst.Kind.ifElse:
				case IfAst.Kind.ternaryWithElse:
				case IfAst.Kind.ternaryWithoutElse:
					writer ~= isUnpackOption
						? "If the value is a non-empty option, destructures it and returns the first branch."
						: "If the condition is 'true', returns the first branch.";
					writer ~= '\n';
					writer ~= () {
						final switch (ifAst.kind) {
							case IfAst.Kind.ifWithoutElse:
							case IfAst.Kind.ternaryWithoutElse:
								return "Otherwise, returns '()'.";
							case IfAst.Kind.ifElif:
							case IfAst.Kind.ifElse:
							case IfAst.Kind.ternaryWithElse:
								return "Otherwise, returns the second branch.";
							case IfAst.Kind.guardWithColon:
							case IfAst.Kind.guardWithoutColon:
							case IfAst.Kind.unless:
								assert(0);
						}
					}();
					break;
				case IfAst.Kind.unless:
					writer ~= "Returns the body if the condition is false. If the condition is true, returns '()'.";
					break;
			}
			break;
		case ExprKeyword.lambdaArrow:
			writer ~= () {
				final switch (exprKind.as!(LambdaExpr*).kind) {
					case LambdaExpr.Kind.data:
						return "Lambda with 'data' closure and no 'summon'.";
					case LambdaExpr.Kind.shared_:
						return "Lambda with 'shared' closure.";
					case LambdaExpr.Kind.mut:
						return "Lambda with 'mut' closure.";
					case LambdaExpr.Kind.explicitShared:
						return "Lambda with 'mut' closure, converted to 'shared' by waiting for exclusion.";
				}
			}();
			break;
		case ExprKeyword.match:
			getMatchHover(writer, ctx, typeContainer, a);
			break;
		case ExprKeyword.questionDotOrSubscript:
			writer ~= "The expression to the left of '?.' or '?[' is an option.\n" ~
				"The call is only done if it is non-empty.";
			break;
		case ExprKeyword.questionEquals:
			writer ~= "The expression to the right of '?=' should be an option.\n" ~
				"The expression to the left of '?=' is destructures the value inside the option if it is non-empty.";
			break;
		case ExprKeyword.throw_:
			writer ~= "Throws an exception.";
			break;
		case ExprKeyword.trusted:
			writer ~= "Allows 'unsafe' code to be used anywhere.";
			break;
		case ExprKeyword.try_:
			writer ~= exprKind.isA!(TryExpr*)
				? "Evaluates and returns the 'try' block, " ~
					"but if it throws is an exception matching a 'catch' block, returns that instead."
				: "Runs the initializer (between '=' and 'catch'). If it succeeds, destructures it and continues.\n" ~
					"If it throws the handled exception, returns the expression after the ':'.";
			break;
		case ExprKeyword.until:
			writer ~= exprKind.as!(LoopWhileOrUntilExpr*).condition.isA!(Expr*)
				? "Loop will run as long as the condition is 'false'."
				: "Loop will run as long as the option is empty.\n" ~
					"Then it is destructured and available after the loop.";
			break;
		case ExprKeyword.while_:
			writer ~= exprKind.as!(LoopWhileOrUntilExpr*).condition.isA!(Expr*)
				? "Loop will run as long as the condition is 'true'."
				: "Loop will run as long as the option is non-empty.";
			break;
	}
}

void getMatchHover(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in TypeContainer typeContainer,
	in ExprRef a,
) {
	MatchInfo info = getMatchInfo(a.expr.kind);
	writer ~= "Match on ";
	writeTypeQuoted(writer, ctx, TypeWithContainer(info.matchedType, typeContainer));
	writer ~= "\n";
	writer ~= () {
		final switch (info.kind) {
			case MatchInfo.Kind.enum_:
				return "Evaluates the branch with the selected member of the enum";
			case MatchInfo.Kind.union_:
				return "Evaluates the branch with the selected member of the union";
			case MatchInfo.Kind.variant:
				return "Evaluates the branch with the selected member of the variant";
			case MatchInfo.Kind.other:
				return "Evaluates the branch with a matching value";
		}
	}();
	writer ~= has(a.expr.ast.kind.as!MatchAst.else_)
		? ", or the 'else' branch if none matched."
		: info.kind == MatchInfo.Kind.other
		? ", or '()' if none matched."
		: ".";
}
immutable struct MatchInfo {
	enum Kind { enum_, union_, variant, other }
	Kind kind;
	Type matchedType;
}
MatchInfo getMatchInfo(ExprKind a) =>
	a.isA!(MatchEnumExpr*)
		? MatchInfo(MatchInfo.Kind.enum_, a.as!(MatchEnumExpr*).matched.type)
		: a.isA!(MatchIntegralExpr*)
		? MatchInfo(MatchInfo.Kind.other, a.as!(MatchIntegralExpr*).matched.type)
		: a.isA!(MatchStringLikeExpr*)
		? MatchInfo(MatchInfo.Kind.other, a.as!(MatchStringLikeExpr*).matched.type)
		: a.isA!(MatchUnionExpr*)
		? MatchInfo(MatchInfo.Kind.union_, a.as!(MatchUnionExpr*).matched.type)
		: a.isA!(MatchVariantExpr*)
		? MatchInfo(MatchInfo.Kind.variant, a.as!(MatchVariantExpr*).matched.type)
		: assert(false);

void getExprHover(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in Uri curUri,
	in ExpressionPosition a,
) {
	TypeContainer typeContainer = a.container.toTypeContainer;
	a.kind.matchIn!void(
		(in CallExpr x) {
			writer ~= "Calls ";
			writeCalled(writer, ctx, typeContainer, x.called);
			writer ~= '.';
		},
		(in CallOptionExpr x) {
			writer ~= "Calls ";
			writeCalled(writer, ctx, typeContainer, x.called);
			writer ~= " if the first argument is non-empty.";
		},
		(in ExprKeyword x) {
			getExprKeywordHover(writer, ctx, curUri, typeContainer, a.expr, x);
		},
		(in ExternExpr x) {
			bool first = true;
			writer ~= "The expression will be true if ";
			foreach (Symbol name; x.names) {
				if (first) writer ~= " and ";
				first = false;
				Opt!BuiltinExtern builtin = asBuiltinExtern(name);
				if (has(builtin)) {
					writer ~= () {
						final switch (force(builtin)) {
							case BuiltinExtern.DbgHelp:
							case BuiltinExtern.windows:
							case BuiltinExtern.ucrtbase:
								return "run on Windows";
							case BuiltinExtern.js:
								return "run in a JavaScript build";
							case BuiltinExtern.linux:
								return "run on Linux";
							case BuiltinExtern.native:
							case BuiltinExtern.libc:
								return "not run on a JavaScript build";
							case BuiltinExtern.posix:
							case BuiltinExtern.pthread:
							case BuiltinExtern.sodium:
							case BuiltinExtern.unwind:
								return "run on a Posix-compliant operating system";
						}
					}();
				} else {
					writer ~= "the '";
					writer ~= name;
					writer ~= "' library is present";
				}
			}
			writer ~= '.';
		},
		(in FunPointerExpr x) {
			writer ~= "Pointer to function ";
			writeCalled(writer, ctx, typeContainer, x.called);
		},
		(in ExpressionPositionKind.Literal x) {
			writer ~= "Literal expression.";
		},
		(in ExpressionPositionKind.LocalRef x) {
			writer ~= () {
				final switch (x.kind) {
					case ExpressionPositionKind.LocalRef.Kind.get:
						return "Gets local variable ";
					case ExpressionPositionKind.LocalRef.Kind.set:
						return "Sets local variable ";
					case ExpressionPositionKind.LocalRef.Kind.closureGet:
						return "Gets local variable ";
					case ExpressionPositionKind.LocalRef.Kind.closureSet:
						return "Sets local variable ";
					case ExpressionPositionKind.LocalRef.Kind.pointer:
						return "Gets pointer to local variable ";
				}
			}();
			writeName(writer, ctx, x.local.name);
			writer ~= () {
				final switch (x.kind) {
					case ExpressionPositionKind.LocalRef.Kind.get:
					case ExpressionPositionKind.LocalRef.Kind.set:
					case ExpressionPositionKind.LocalRef.Kind.pointer:
						return "";
					case ExpressionPositionKind.LocalRef.Kind.closureGet:
					case ExpressionPositionKind.LocalRef.Kind.closureSet:
						return " (through closure)";
				}
			}();
			writer ~= '.';
		},
		(in ExpressionPositionKind.LoopKeyword x) {
			final switch (x.kind) {
				case ExpressionPositionKind.LoopKeyword.Kind.break_:
					writer ~= "Breaks out of ";
					writeLoop(writer, ctx, curUri, x.loop);
					writer ~= '.';
					break;
				case ExpressionPositionKind.LoopKeyword.Kind.continue_:
					writer ~= "Goes back to the start of ";
					writeLoop(writer, ctx, curUri, x.loop);
					writer ~= '.';
					break;
				case ExpressionPositionKind.LoopKeyword.Kind.loop:
					writer ~= "Loop that terminates at a 'break'.";
					break;
			}
		});

	writer ~= "\nExpression type is: ";
	writeTypeQuoted(writer, ctx, TypeWithContainer(a.expr.type, typeContainer));
}

void writeLoop(scope ref Writer writer, in ShowModelCtx ctx, Uri curUri, in ExprRef a) {
	writer ~= "the loop at ";
	writer ~= ctx.lineAndColumnGetters[curUri][a.expr.range.start, PosKind.startOfRange];
}
