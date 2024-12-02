module frontend.ide.getHover;

@safe @nogc pure nothrow:

import frontend.ide.position :
	ExpressionPosition,
	ExpressionPositionLiteral,
	ExprKeyword,
	LocalRef,
	LocalRefKind,
	Position,
	PositionDocRef,
	PositionImportedModule,
	PositionImportedName,
	PositionKeyword,
	PositionLocal,
	PositionMatchEnumCase,
	PositionMatchIntegralCase,
	PositionMatchStringLikeCase,
	PositionMatchSumTypeCase,
	PositionModifier,
	PositionModifierExtern,
	PositionModule,
	PositionRecordFieldMutability,
	PositionSpecUse,
	PositionVisibilityMark,
	typeContainerFor,
	TypeParamWithContainer;
import frontend.showModel :
	ShowModelCtx,
	showSumTypeKindUpperCase,
	writeCalled,
	writeCalledDecl,
	writeCalledSpecSig,
	writeFile,
	writeFunDecl,
	WriteKind,
	writeName,
	writeSpecInst,
	writeTypeQuoted,
	writeTypeUnquoted,
	writeVisibility;
import lib.lsp.lspTypes : Hover, MarkupContent, MarkupKind;
import model.ast : IfAstKind, ModifierKeyword;
import model.model :
	AnyDecl,
	asBuiltinExtern,
	AssertOrForbidExpr,
	BogusCallExpr,
	BogusType,
	BuiltinExtern,
	BuiltinType,
	CalledSpecSig,
	CallExpr,
	CallOptionExpr,
	CharType,
	DocCommentReferenceBogus,
	Enum,
	EnumOrFlagsMember,
	Expr,
	ExternExpr,
	ExternType,
	Flags,
	forbidModule,
	FunDecl,
	FunPointerExpr,
	IfExpr,
	IntegralType,
	isSigned,
	LambdaExpr,
	LambdaKind,
	Local,
	LoopExpr,
	LoopBreakExpr,
	LoopContinueExpr,
	LoopWhileOrUntilExpr,
	NameReferents,
	MatchEnumExpr,
	MatchIntegralExpr,
	MatchStringLikeExpr,
	MatchSumTypeExpr,
	Record,
	RecordField,
	Signature,
	SpecDecl,
	stringOfVarKindLowerCase,
	stringOfVarKindUpperCase,
	StructAlias,
	StructBodyBogus,
	StructDecl,
	StructInst,
	SumType,
	SumTypeKind,
	Test,
	TryExpr,
	TryLetExpr,
	Type,
	TypeContainer,
	TypeParamIndex,
	TypeWithContainer,
	UnpackOption,
	VarDecl;
import model.sourceRange : PosKind;
import util.alloc.alloc : Alloc;
import util.col.array : only;
import util.conv : safeToUint;
import util.opt : force, has, Opt;
import util.symbol : Symbol;
import util.uri : Uri;
import util.util : stringOfEnum;
import util.writer : makeStringWithWriter, writeNewline, writeQuotedChar, writeQuotedString, Writer;

Hover getHover(ref Alloc alloc, in ShowModelCtx ctx, in Position pos) =>
	Hover(MarkupContent(MarkupKind.plaintext, makeStringWithWriter(alloc, (scope ref Writer writer) {
		getHover(writer, ctx, pos);
	})));

void getHover(scope ref Writer writer, in ShowModelCtx ctx, in Position pos) =>
	pos.kind.matchWithPointers!void(
		(PositionDocRef x) {
			hoverForDocRef(writer, ctx, x);
		},
		(EnumOrFlagsMember* x) {
			writer ~= x.containingEnum.body_.isA!(Enum*) ? "Enum " : "Flags ";
			writer ~= " member ";
			writer ~= x.containingEnum.name;
			writer ~= '.';
			writer ~= x.name;
		},
		(ExpressionPosition x) {
			getExprHover(writer, ctx, pos.module_.uri, x);
		},
		(FunDecl* x) {
			writeFunDecl(writer, ctx, WriteKind.unquoted, x);
		},
		(PositionImportedModule x) {
			writer ~= "Import module ";
			writeFile(writer, ctx, x.module_.uri);
		},
		(PositionImportedName x) {
			getImportedNameHover(writer, ctx, x);
		},
		(PositionKeyword x) {
			writer ~= () {
				final switch (x) {
					case PositionKeyword.alias_:
						return "Declares a type alias.";
					case PositionKeyword.builtin:
						return "Declares a type implemented natively by Crow.";
					case PositionKeyword.enum_:
						return "Declares an enumerated type. The type can only have the values listed.";
					case PositionKeyword.extern_:
						return "Declares a type implemented by an external library.";
					case PositionKeyword.flags:
						return "Declares a type that can have any combination of flags (this would be an 'enum' in C)";
					case PositionKeyword.global:
						return "Declares a mutable global variable (shared between all threads).";
					case PositionKeyword.interface_:
						return "An 'interface' is just like a 'variant', " ~
							"but does not support 'match' or conversion to case types.";
					case PositionKeyword.localMut:
						return "Makes this a mutable variable.";
					case PositionKeyword.record:
						return "Declares a type combining several named members.";
					case PositionKeyword.spec:
						return "Specifies function signatures which to be provided by a function's caller.";
					case PositionKeyword.threadLocal:
						return "Declares a mutable thread-local variable.";
					case PositionKeyword.underscore:
						return "Ignores the value.";
					case PositionKeyword.union_:
						return "A union can be one of several listed case types.";
					case PositionKeyword.variant:
						return "Declares a union-like type with an extensible set of case types, " ~
							"created by 'case' declarations on the types.";
				}
			}();
		},
		(PositionLocal x) {
			writer ~= "Local ";
			writeName(writer, ctx, x.local.name);
			writer ~= " of type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(x.local.type, x.container.toTypeContainer));
		},
		(PositionMatchEnumCase x) {
			writer ~= "Handler for enum ";
			writeName(writer, ctx, x.member.containingEnum.name);
			writer ~= " member ";
			writeName(writer, ctx, x.member.name);
		},
		(PositionMatchIntegralCase x) {
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
		(PositionMatchStringLikeCase x) {
			writer ~= "Handler for value ";
			writeQuotedString(writer, x.value);
			writer ~= " :: ";
			writeTypeUnquoted(writer, ctx, x.type);
		},
		(PositionMatchSumTypeCase x) {
			writer ~= "Handler for type ";
			writeTypeQuoted(writer, ctx, TypeWithContainer(Type(x.member), x.container.toTypeContainer));
		},
		(PositionModifier x) {
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
					case ModifierKeyword.case_:
						return "Adds a case type to an interface or variant type. " ~
							"The case type must implement the interface/variant type's methods, if any.";
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
				}
			}();
		},
		(PositionModifierExtern x) {
			writer ~= "Function comes from external library ";
			writeName(writer, ctx, x.libraryName);
			writer ~= '.';
		},
		(PositionModule _) {
			writer ~= "Module ";
			writer ~= pos.module_.uri;
		},
		(RecordField* x) {
			writer ~= "Record field ";
			writer ~= x.containingRecord.name;
			writer ~= '.';
			writer ~= x.name;
			writer ~= " :: ";
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.type, TypeContainer(x.containingRecord)));
		},
		(PositionRecordFieldMutability x) {
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
		(Signature* sig) {
			sig.container.matchIn!void(
				(in SpecDecl x) {
					writer ~= "Spec ";
					writeName(writer, ctx, x.name);
					writer ~= " signature ";
				},
				(in StructDecl x) {
					writer ~= showSumTypeKindUpperCase(x.body_.as!SumType.kind);
					writeName(writer, ctx, x.name);
					writer ~= " method ";
				});
			writeName(writer, ctx, sig.name);
		},
		(PositionSpecUse x) {
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
				(in BogusType _) {},
				(in TypeParamIndex p) {
					hoverTypeParam(writer, ctx, forbidModule(x.container), p);
				},
				(in StructInst i) {
					writeStructDeclHover(writer, ctx, *i.decl);
				});
		},
		(TypeParamWithContainer x) {
			hoverTypeParam(writer, ctx, x.container, x.typeParam);
		},
		(VarDecl* x) {
			writer ~= stringOfVarKindUpperCase(x.kind);
			writer ~= " variable ";
			writeName(writer, ctx, x.name);
			writer ~= " :: ";
			writeTypeUnquoted(writer, ctx, TypeWithContainer(x.type, TypeContainer(x)));
		},
		(PositionVisibilityMark x) {
			writer ~= "Marks ";
			writeName(writer, ctx, x.container.name);
			writer ~= " as ";
			writeVisibility(writer, ctx, x.container.visibility);
			writer ~= '.';
		});

private:

void hoverForDocRef(scope ref Writer writer, in ShowModelCtx ctx, PositionDocRef a) {
	a.ref_.matchWithPointers!void(
		(DocCommentReferenceBogus _) {},
		(CalledSpecSig x) {
			writer ~= "References ";
			writeCalledSpecSig(writer, ctx, WriteKind.quoted, typeContainerFor(a.container), x);
		},
		(EnumOrFlagsMember* x) {
			writer ~= "References ";
			writer ~= x.containingEnum.body_.isA!(Enum*)
				? "enum"
				: x.containingEnum.body_.isA!Flags
				? "flags"
				: assert(false);
			writeName(writer, ctx, x.containingEnum.name);
			writer ~= " member ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(FunDecl* x) {
			writer ~= "References function ";
			writeFunDecl(writer, ctx, WriteKind.unquoted, x);
		},
		(Local* x) {
			writer ~= "References parameter ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(RecordField* x) {
			writer ~= "References record ";
			writeName(writer, ctx, x.containingRecord.name);
			writer ~= " field ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(Signature* x) {
			writer ~= "References ";
			writer ~= x.container.matchIn!string(
				(in SpecDecl _) => "spec signature",
				(in StructDecl _) => "variant method");
			writer ~= ' ';
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(StructAlias* x) {
			writer ~= "References alias ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(StructDecl* x) {
			writer ~= "References type ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(SpecDecl* x) {
			writer ~= "References spec ";
			writeName(writer, ctx, x.name);
			writer ~= '.';
		},
		(TypeParamIndex x) {
			writer ~= "References type parameter ";
			writeName(writer, ctx, typeContainerFor(a.container).typeParams[x.index].name);
			writer ~= '.';
		},
		(VarDecl* x) {
			writer ~= "References ";
			writer ~= stringOfVarKindLowerCase(x.kind);
			writer ~= ' ';
			writeName(writer, ctx, x.name);
			writer ~= '.';
		});
}

void writeStructAliasHover(scope ref Writer writer, in ShowModelCtx ctx, in StructAlias* a) {
	writer ~= "Alias for ";
	writeTypeQuoted(writer, ctx, TypeWithContainer(Type(a.target), TypeContainer(a)));
}

void writeStructDeclHover(scope ref Writer writer, in ShowModelCtx ctx, in StructDecl a) {
	writer ~= a.body_.matchIn!string(
		(in StructBodyBogus _) =>
			"Type ",
		(in BuiltinType _) =>
			"Builtin type ",
		(in Enum _) =>
			"Enum type ",
		(in ExternType _) =>
			"Extern type ",
		(in Flags _) =>
			"Flags type ",
		(in Record _) =>
			"Record type ",
		(in SumType x) {
			writer ~= showSumTypeKindUpperCase(x.kind);
			return " type ";
		});
	writeName(writer, ctx, a.name);
}

void writeSpecDeclHover(scope ref Writer writer, in ShowModelCtx ctx, in SpecDecl a) {
	writer ~= "Spec ";
	writeName(writer, ctx, a.name);
}

void getImportedNameHover(scope ref Writer writer, in ShowModelCtx ctx, in PositionImportedName a) {
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
			writeFunDecl(writer, ctx, WriteKind.unquoted, x);
		}
	}
}

void hoverTypeParam(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in AnyDecl typeContainer,
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
	ExprKeyword keyword,
) {
	final switch (keyword) {
		case ExprKeyword.ampersand:
			writer ~= "Gets a pointer to an expression. " ~
				"This does not allocate and so is unsafe. This only works for certain expressions.";
			break;
		case ExprKeyword.colonColon:
			writer ~= "Provides an expected type for the expression to its left.";
			break;
		case ExprKeyword.colonAfterAssert:
			writer ~= "If the condition is false, throws an exception with the message to the right of the ':'.";
			break;
		case ExprKeyword.colonAfterForbid:
			writer ~= "If the condition is false, throws an exception with the message to the right of the ':'.";
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
		case ExprKeyword.elseAfterIf:
			writer ~= "If the condition is 'false', the 'else' branch is evaluated.";
			break;
		case ExprKeyword.elseAfterMatch:
			writer ~= "If no branch was satisfied, the 'match' evaluates to the 'else' branch.";
			break;
		case ExprKeyword.finally_:
			writer ~= "The expression below 'finally' runs first.\n" ~
				"The expression to the right of 'finally' runs second, even if there was an exception.\n" ~
				"The result is from the below expression; the right expression must be 'void'.";
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
	}
}

void getExprHover(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in Uri curUri,
	in ExpressionPosition a,
) {
	TypeContainer typeContainer = a.container.toTypeContainer;
	a.kind.matchIn!void(
		(in AssertOrForbidExpr x) {
			writer ~= x.condition.matchIn!string(
				(in Expr _) =>
					x.isForbid ? "Throws if the condition is 'true'." : "Throws if the condition is 'false'.",
				(in UnpackOption _) =>
					x.isForbid ? "Throws if the option is non-empty." : "Throws if the option is empty.");
		},
		(in BogusCallExpr x) {
			if (x.candidates.length == 1) {
				writer ~= "Calls ";
				writeCalledDecl(writer, ctx, WriteKind.quoted, typeContainer, only(x.candidates));
			} else {
				writer ~= "Calls a function named ";
				writeName(writer, ctx, x.candidates[0].name);
			}
			writer ~= '.';
		},
		(in CallExpr x) {
			writer ~= "Calls ";
			writeCalled(writer, ctx, WriteKind.quoted, typeContainer, x.called);
			writer ~= '.';
		},
		(in CallOptionExpr x) {
			writer ~= "Calls ";
			writeCalled(writer, ctx, WriteKind.quoted, typeContainer, x.called);
			writer ~= " if the first argument is non-empty.";
		},
		(in ExprKeyword x) {
			getExprKeywordHover(writer, ctx, curUri, typeContainer, x);
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
							case BuiltinExtern.fake:
								return "run with '--fake-extern', or when running tests in an IDE";
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
			writeCalled(writer, ctx, WriteKind.quoted, typeContainer, x.called);
			writer ~= '.';
		},
		(in IfExpr x) {
			bool isUnpackOption = x.condition.matchIn!bool(
				(in Expr _) => false,
				(in UnpackOption _) => true);
			final switch (x.ast.kind) {
				case IfAstKind.guardWithColon:
				case IfAstKind.guardWithoutColon:
					writer ~= isUnpackOption
						? "If the option is non-empty, destructures it and continues."
						: "If the expression is 'true', continues.";
					writer ~= '\n';
					writer ~= x.ast.kind == IfAstKind.guardWithColon
						? "Otherwise, returns the expression after the ':'."
						: "Otherwise, returns '()'.";
					break;
				case IfAstKind.ifWithoutElse:
				case IfAstKind.ifElif:
				case IfAstKind.ifElse:
				case IfAstKind.ternaryWithElse:
				case IfAstKind.ternaryWithoutElse:
					writer ~= isUnpackOption
						? "If the value is a non-empty option, destructures it and returns the first branch."
						: "If the condition is 'true', returns the first branch.";
					writer ~= '\n';
					writer ~= () {
						final switch (x.ast.kind) {
							case IfAstKind.ifWithoutElse:
							case IfAstKind.ternaryWithoutElse:
								return "Otherwise, returns '()'.";
							case IfAstKind.ifElif:
							case IfAstKind.ifElse:
							case IfAstKind.ternaryWithElse:
								return "Otherwise, returns the second branch.";
							case IfAstKind.guardWithColon:
							case IfAstKind.guardWithoutColon:
							case IfAstKind.unless:
								assert(0);
						}
					}();
					break;
				case IfAstKind.unless:
					writer ~= "Returns the body if the condition is false. If the condition is true, returns '()'.";
					break;
			}
		},
		(in ExpressionPositionLiteral _) {
			writer ~= "Literal expression.";
		},
		(in LambdaExpr x) {
			writer ~= () {
				final switch (x.kind) {
					case LambdaKind.data:
						return "Lambda with 'data' closure and no 'summon'.";
					case LambdaKind.shared_:
						return "Lambda with 'shared' closure.";
					case LambdaKind.mut:
						return "Lambda with 'mut' closure.";
					case LambdaKind.explicitShared:
						return "Lambda with 'mut' closure, converted to 'shared' by waiting for exclusion.";
				}
			}();
		},
		(in LocalRef x) {
			writer ~= () {
				final switch (x.kind) {
					case LocalRefKind.get:
						return "Gets local variable ";
					case LocalRefKind.set:
						return "Sets local variable ";
					case LocalRefKind.closureGet:
						return "Gets local variable ";
					case LocalRefKind.closureSet:
						return "Sets local variable ";
					case LocalRefKind.pointer:
						return "Gets pointer to local variable ";
				}
			}();
			writeName(writer, ctx, x.local.name);
			writer ~= () {
				final switch (x.kind) {
					case LocalRefKind.get:
					case LocalRefKind.set:
					case LocalRefKind.pointer:
						return "";
					case LocalRefKind.closureGet:
					case LocalRefKind.closureSet:
						return " (through closure)";
				}
			}();
			writer ~= '.';
		},
		(in LoopExpr x) {
			writer ~= "Loop that terminates at a 'break'.";
		},
		(in LoopBreakExpr x) {
			writer ~= "Breaks out of ";
			writeLoop(writer, ctx, curUri, *x.loop);
			writer ~= '.';
		},
		(in LoopContinueExpr x) {
			writer ~= "Goes back to the start of ";
			writeLoop(writer, ctx, curUri, *x.loop);
			writer ~= '.';
		},
		(in LoopWhileOrUntilExpr x) {
			writer ~= x.condition.matchIn!string(
				(in Expr _) =>
					x.isUntil
						? "Loop will run as long as the condition is 'false'."
						: "Loop will run as long as the condition is 'true'.",
				(in UnpackOption _) =>
					x.isUntil
						? "Loop will run as long as the option is empty.\n" ~
							"Then it is destructured and available after the loop."
						: "Loop will run as long as the option is non-empty.");
		},
		(in MatchEnumExpr x) {
			writeMatchHover(writer, ctx, typeContainer, "enum ", x.enumType);
		},
		(in MatchIntegralExpr x) {
			writeMatchHover(writer, ctx, typeContainer, "", x.matchedType);
		},
		(in MatchStringLikeExpr x) {
			writeMatchHover(writer, ctx, typeContainer, "", x.matchedType);
		},
		(in MatchSumTypeExpr x) {
			string typeDesc = () {
				final switch (x.sumTypeBody.kind) {
					case SumTypeKind.interface_:
						return "interface ";
					case SumTypeKind.union_:
						return "union ";
					case SumTypeKind.variant:
						return "variant ";
				}
			}();
			writeMatchHover(writer, ctx, typeContainer, typeDesc, x.sumType);
		},
		(in TryExpr x) {
			writer ~= "Evaluates the 'try' block, but if it throws ";
			if (x.catches.length == 1) {
				writer ~= "a ";
				writeTypeQuoted(writer, ctx, TypeWithContainer(Type(only(x.catches).caseType), typeContainer));
			} else {
				writer ~= "an exception matching a 'catch' block";
			}
			writer ~= ", evaluates the 'catch' block instead.";
		},
		(in TryLetExpr x) {
			writer ~= "Runs the initializer (between '=' and 'catch'). " ~
				"If it succeeds, destructures it and continues.\n" ~
				"If it throws the handled exception, returns the expression after the ':'.";
		});

	if (has(a.type)) {
		writer ~= "\nExpression type is: ";
		writeTypeQuoted(writer, ctx, TypeWithContainer(force(a.type), typeContainer));
	}
}

void writeLoop(scope ref Writer writer, in ShowModelCtx ctx, Uri curUri, in LoopExpr loop) {
	writer ~= "the loop at ";
	writer ~= ctx.lineAndColumnGetters[curUri][loop.ast.start, PosKind.startOfRange];
}

void writeMatchHover(
	scope ref Writer writer,
	in ShowModelCtx ctx,
	in TypeContainer typeContainer,
	string typeDesc,
	in StructInst* matchedType,
) {
	writer ~= "Match on ";
	writer ~= typeDesc;
	writeTypeQuoted(writer, ctx, TypeWithContainer(Type(matchedType), typeContainer));
	writer ~= '.';
}