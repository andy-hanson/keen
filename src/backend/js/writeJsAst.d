module backend.js.writeJsAst;

@safe @nogc pure nothrow:

import backend.js.jsAst :
	JsArrayExpr,
	JsArrowFunction,
	JsAssignStatement,
	JsBinaryExpr,
	JsBinaryKind,
	JsBlockStatement,
	JsBreakStatement,
	JsCallExpr,
	JsCallWithSpreadExpr,
	JsClassDecl,
	JsClassMember,
	JsClassMemberStatic,
	JsClassMethod,
	JsContinueStatement,
	JsDecl,
	JsDeclExported,
	JsDefaultDestructure,
	JsDestructure,
	JsExpr,
	JsExprOrBlockStatement,
	JsIfStatement,
	JsImport,
	JsLiteralBool,
	JsLiteralInteger,
	JsLiteralNumber,
	JsLiteralString,
	JsLiteralStringFromMemberName,
	JsLiteralStringFromSymbol,
	JsMemberName,
	JsMemberNameKind,
	JsModuleAst,
	JsName,
	JsNameKind,
	JsNewExpr,
	JsNullExpr,
	JsObjectDestructure,
	JsObject1Expr,
	JsParams,
	JsPropertyAccessExpr,
	JsPropertyAccessComputedExpr,
	JsReturnStatement,
	JsScriptAst,
	JsStatement,
	JsSwitchStatement,
	JsTernaryExpr,
	JsThisExpr,
	JsThrowStatement,
	JsTryCatchStatement,
	JsTryFinallyStatement,
	JsUnaryExpr,
	JsUnaryKind,
	JsVarDecl,
	JsWhileStatement,
	LetDeclKind,
	Shebang,
	SyncOrAsync;
import backend.js.sourceMap : finish, JsAndMap, ModulePaths, SingleSourceMapping, Source, SourceMapBuilder;
import backend.mangle : mangleNameCommon;
import frontend.showModel : ShowTypeCtx;
import frontend.storage : FileContentGetters;
import util.alloc.alloc : Alloc;
import util.col.array : contains, isEmpty, only;
import util.col.map : KeyValuePair;
import util.opt : force, has, MutOpt, none, noneMut, Opt, optIf, someMut;
import util.sourceRange : LineAndCharacter;
import util.string : isAsciiIdentifierChar, isDecimalDigit;
import util.symbol : Symbol, symbol, writeQuotedSymbol;
import util.uri : RelPath, Uri;
import util.util : ptrTrustMe, stringOfEnum;
import util.writer : finish, writeAndVerify, writeFloatLiteralForJS, writeNewline, writeQuotedString, Writer;

JsAndMap writeJsScriptAst(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in ModulePaths modulePaths,
	in JsScriptAst a,
	Opt!Symbol sourceMapName,
) =>
	buildOutput(alloc, showCtx.fileContentGetters, modulePaths, has(sourceMapName), (scope ref Output writer) {
		writeShebang(writer, a.shebang);
		if (has(sourceMapName))
			writeSourceMapUrl(writer, force(sourceMapName));
		foreach (JsDecl x; a.decls)
			writeDecl(writer, showCtx, x, neverExport: true);
		writeStatements(writer, a.statements);
	});

string writeJsModuleAst(
	ref Alloc alloc,
	in ShowTypeCtx showCtx,
	in ModulePaths modulePaths,
	Uri sourceUri,
	in JsModuleAst a,
) =>
	buildOutput(alloc, showCtx.fileContentGetters, modulePaths, false, (scope ref Output writer) {
		writeShebang(writer, a.shebang);
		foreach (JsImport x; a.imports)
			writeImportOrReExport(writer, "import", x);
		foreach (JsImport x; a.reExports)
			writeImportOrReExport(writer, "export", x);
		foreach (JsDecl x; a.decls)
			writeDecl(writer, showCtx, x);
		writeStatements(writer, a.statements);
	}).js;

private:

JsAndMap buildOutput(
	ref Alloc alloc,
	in FileContentGetters files,
	in ModulePaths modulePaths,
	bool includeSourceMap,
	in void delegate(scope ref Output) @safe @nogc pure nothrow cb,
) {
	Output writer = Output(
		Writer(ptrTrustMe(alloc)),
		includeSourceMap ? someMut(SourceMapBuilder(Writer(ptrTrustMe(alloc)))) : noneMut!SourceMapBuilder);
	cb(writer);
	return JsAndMap(
		finish(writer.writer),
		optIf(has(writer.map), () => finish(force(writer.map), files, modulePaths)));
}

struct Output {
	@safe @nogc pure nothrow:

	Writer writer;
	MutOpt!SourceMapBuilder map;
	uint line;
	uint character;

	ref Alloc alloc() return scope =>
		writer.alloc;

	void opOpAssign(string op : "~")(in string s) scope {
		foreach (char x; s)
			this ~= x;
	}
	void opOpAssign(string op : "~")(in char x) scope {
		this ~= dchar(x);
	}
	void opOpAssign(string op : "~")(in dchar x) scope {
		writer ~= x;
		if (x == '\n') {
			line += 1;
			character = 0;
		} else
			character += 1;
	}

	void opOpAssign(string op : "~")(bool x) scope {
		writeOnSingleLine(this, x);
	}
	void opOpAssign(string op : "~")(ushort x) scope {
		writeOnSingleLine(this, x);
	}
	void opOpAssign(string op : "~")(uint x) scope {
		writeOnSingleLine(this, x);
	}
	void opOpAssign(string op : "~")(ulong x) scope {
		writeOnSingleLine(this, x);
	}
	void opOpAssign(string op : "~")(long x) scope {
		writeOnSingleLine(this, x);
	}
	void opOpAssign(string op : "~")(double x) scope {
		writeOnSingleLine(this, x);
	}

	void opOpAssign(string op : "~")(in RelPath x) scope {
		writeOnSingleLine!RelPath(this, x);
	}
	void opOpAssign(string op : "~")(Symbol x) scope {
		writeOnSingleLine!Symbol(this, x);
	}
}

void markMap(scope ref Output a, in Source source) {
	if (has(a.map))
		force(a.map) ~= SingleSourceMapping(source, LineAndCharacter(a.line, a.character));
}

void writeOnSingleLine(T)(scope ref Output writer, in T x) {
	writeOnSingleLine(writer, (scope ref Writer w) {
		w ~= x;
	});
}
void writeOnSingleLine(scope ref Output writer, in void delegate(scope ref Writer) @safe @nogc pure nothrow cb) {
	writeAndVerify(
		writer.writer,
		() {
			cb(writer.writer);
		},
		(in string x) {
			assert(!contains(x, '\n'));
			writer.character += x.length;
		});
}

void writeNewline(scope ref Output writer, uint indent) {
	writer ~= '\n';
	foreach (size_t _; 0 .. indent)
		writer ~= '\t';
}

void writeWithCommas(T)(scope ref Output writer, in T[] xs, in void delegate(in T) @safe @nogc pure nothrow cb) {
	bool first = true;
	foreach (ref const T x; xs) {
		if (first)
			first = false;
		else
			writer ~= ',';
		cb(x);
	}
}

void writeShebang(scope ref Output writer, Shebang a) {
	final switch (a) {
		case Shebang.none:
			break;
		case Shebang.node:
			writer ~= "#!/usr/bin/env node\n";
	}
}

void writeSourceMapUrl(scope ref Output writer, in Symbol sourceMapName) {
	writer ~= "//# sourceMappingURL=";
	writer ~= sourceMapName;
	writer ~= '\n';
}

void writeStatements(scope ref Output writer, in JsStatement[] statements) {
	foreach (JsStatement x; statements) {
		writeNewline(writer, 0);
		writeStatement(writer, 0, x, StatementPos.nonFirst);
	}
}

void writeJsName(scope ref Output writer, in JsName name) {
	if (isJsKeyword(name.crowName) && !has(name.mangleIndex)) {
		writer ~= '_';
		writer ~= name.crowName;
	} else {
		writer ~= () {
			final switch (name.kind) {
				case JsNameKind.none:
					return "";
				case JsNameKind.function_:
					return "f_";
				case JsNameKind.local:
					return "l_";
				case JsNameKind.specialLocal:
					return "sl_";
				case JsNameKind.specSig:
					return "s_";
				case JsNameKind.temp:
					return "x_";
				case JsNameKind.type:
					return "t_";
			}
		}();
		mangleNameCommon(writer, name.crowName);
		if (has(name.mangleIndex)) {
			writer ~= "___";
			writer ~= force(name.mangleIndex);
		}
	}
}
void writePropertyAccess(scope ref Output writer, JsMemberName a) {
	if (!needsMangle(a.crowName))
		writer ~= '.';
	writeMemberName(writer, a);
}
void writeMemberName(scope ref Output writer, JsMemberName a) {
	if (needsMangle(a.crowName)) {
		writer ~= '[';
		writeQuotedMemberName(writer, a);
		writer ~= ']';
	} else {
		writer ~= memberNamePrefix(a.kind);
		writer ~= a.crowName;
	}
}
void writeQuotedMemberName(scope ref Output writer, JsMemberName a) {
	writer ~= '"';
	writer ~= memberNamePrefix(a.kind);
	writer ~= a.crowName;
	writer ~= '"';
}
string memberNamePrefix(JsMemberNameKind a) {
	final switch (a) {
		case JsMemberNameKind.none:
			return "";
		case JsMemberNameKind.enumMember:
			return "e_";
		case JsMemberNameKind.recordField:
			return "f_";
		case JsMemberNameKind.special:
			return "s_";
		case JsMemberNameKind.sumTypeMethod:
			return "m_";
		case JsMemberNameKind.unionConstructor:
			return "uc_";
		case JsMemberNameKind.unionMember:
			return "um_";
	}
}

bool needsMangle(Symbol a) {
	bool first = true;
	foreach (char x; a) {
		if ((first && isDecimalDigit(x)) || !isAllowedJsIdentifierChar(x))
			return true;
		first = false;
	}
	return isJsKeyword(a);
}
bool isJsKeyword(Symbol a) {
	switch (a.value) {
		case symbol!"await".value:
		case symbol!"case".value:
		case symbol!"const".value:
		case symbol!"debugger".value:
		case symbol!"default".value:
		case symbol!"delete".value:
		case symbol!"enum".value:
		case symbol!"false".value:
		case symbol!"function".value:
		case symbol!"in".value:
		case symbol!"instanceof".value:
		case symbol!"let".value:
		case symbol!"new".value:
		case symbol!"null".value:
		case symbol!"static".value:
		case symbol!"switch".value:
		case symbol!"this".value:
		case symbol!"true".value:
		case symbol!"typeof".value:
		case symbol!"var".value:
		case symbol!"void".value:
			return true;
		default:
			return false;
	}
}
bool isAllowedJsIdentifierChar(dchar a) =>
	// TODO: JS allows more
	isAsciiIdentifierChar(a);

void writeImportOrReExport(scope ref Output writer, in string importOrExport, in JsImport import_) {
	writer ~= importOrExport;
	if (has(import_.importedNames)) {
		writer ~= " { ";
		writeWithCommas!JsName(writer, force(import_.importedNames), (in JsName name) {
			writeJsName(writer, name);
		});
		writer ~= " }";
	} else
		writer ~= " *";
	writer ~= " from ";
	writeQuotedRelPath(writer, import_.path);
	writer ~= "\n";
}

void writeQuotedRelPath(scope ref Output writer, RelPath path) {
	writer ~= '"';
	writer ~= path;
	writer ~= '"';
}

void writeDecl(scope ref Output writer, in ShowTypeCtx showCtx, in JsDecl decl, bool neverExport = false) {
	writer ~= '\n';
	markMap(writer, decl.source);
	if (!neverExport) {
		final switch (decl.exported) {
			case JsDeclExported.private_:
				break;
			case JsDeclExported.export_:
				writer ~= "export ";
				break;
		}
	}
	decl.kind.matchIn!void(
		(in JsClassDecl x) {
			writeClass(writer, decl.name, x);
		},
		(in JsExpr x) {
			writer ~= "const ";
			writeJsName(writer, decl.name);
			writer ~= " = ";
			writeExpr(writer, 0, x);
		},
		(in LetDeclKind) {
			writer ~= "let ";
			writeJsName(writer, decl.name);
		});
	writer ~= "\n";
}

void writeClass(scope ref Output writer, JsName name, in JsClassDecl x) {
	writer ~= "class ";
	writeJsName(writer, name);
	if (has(x.extends)) {
		writer ~= " extends ";
		writeExpr(writer, 2, *force(x.extends));
	}

	writer ~= " {";
	foreach (JsClassMember member; x.members) {
		markMap(writer, member.source);
		writeNewline(writer, 1);
		writeClassMember(writer, member);
	}
	writeNewline(writer, 0);
	writer ~= "}";
}
void writeClassMember(scope ref Output writer, in JsClassMember member) {
	final switch (member.isStatic) {
		case JsClassMemberStatic.instance:
			break;
		case JsClassMemberStatic.static_:
			writer ~= "static ";
			break;
	}
	if (member.kind.isA!JsClassMethod)
		maybeWriteAsync(writer, member.kind.as!JsClassMethod.async);
	writeMemberName(writer, member.name);
	member.kind.matchIn!void(
		(in JsClassMethod x) {
			writeParams(writer, x.params, alwaysParens: true);
			writeBlockStatement(writer, 1, x.body_);
		},
		(in JsExpr x) {
			writer ~= " = ";
			writeExpr(writer, 1, x);
		});
}

void writeParams(scope ref Output writer, in JsParams a, bool alwaysParens) {
	bool parens = alwaysParens || a.params.length != 1 || !only(a.params).isA!JsName || has(a.restParam);
	if (parens) writer ~= '(';
	writeWithCommas!JsDestructure(writer, a.params, (in JsDestructure x) {
		writeDestructure(writer, x);
	});
	if (has(a.restParam)) {
		if (!isEmpty(a.params))
			writer ~= ", ";
		writer ~= "...";
		writeDestructure(writer, force(a.restParam));
	}
	if (parens) writer ~= ')';
}
void writeDestructure(scope ref Output writer, in JsDestructure a) {
	a.matchIn!void(
		(in JsName x) {
			writeJsName(writer, x);
		},
		(in JsDefaultDestructure x) {
			writeDestructure(writer, x.left);
			writer ~= " = ";
			writeExpr(writer, 0, x.default_, ExprPos.expr);
		},
		(in JsObjectDestructure x) {
			writer ~= "{ ";
			writeWithCommas!(KeyValuePair!(JsMemberName, JsDestructure))(
				writer, x.fields,
				(in KeyValuePair!(JsMemberName, JsDestructure) pair) {
					writeMemberName(writer, pair.key);
					writer ~= ": ";
					writeDestructure(writer, pair.value);
				});
			writer ~= " }";
		});
}

void writeBlockStatement(scope ref Output writer, uint indent, in JsBlockStatement a) {
	writer ~= '{';
	foreach (size_t index, JsStatement x; a.statements) {
		writeNewline(writer, indent + 1);
		writeStatement(writer, indent + 1, x, index == 0 ? StatementPos.first : StatementPos.nonFirst);
	}
	writeNewline(writer, indent);
	writer ~= '}';
}

void writeExprOrBlockStatementIndented(scope ref Output writer, uint indent, in JsExprOrBlockStatement a) {
	a.matchIn!void(
		(in JsExpr x) {
			writeNewline(writer, indent + 1);
			writeExpr(writer, indent + 1, x);
		},
		(in JsBlockStatement x) {
			writer ~= ' ';
			writeBlockStatement(writer, indent, x);
		});
}

enum StatementPos { first, nonFirst }
void writeStatement(scope ref Output writer, uint indent, in JsStatement a, StatementPos pos) {
	markMap(writer, a.source);
	a.kind.matchIn!void(
		(in JsAssignStatement x) {
			writeAssign(writer, indent, x);
		},
		(in JsBlockStatement x) {
			writeBlockStatement(writer, indent, x);
		},
		(in JsBreakStatement x) {
			writer ~= "break";
			if (has(x.label)) {
				writer ~= ' ';
				writeJsName(writer, force(x.label));
			}
		},
		(in JsContinueStatement x) {
			writer ~= "continue";
		},
		(in JsExpr x) {
			writeExpr(writer, indent, x, () {
				final switch (pos) {
					case StatementPos.first:
						return ExprPos.statementFirst;
					case StatementPos.nonFirst:
						return ExprPos.statementNonFirst;
				}
			}());
		},
		(in JsIfStatement x) {
			writeIf(writer, indent, x);
		},
		(in JsReturnStatement x) {
			writer ~= "return ";
			writeExpr(writer, indent, *x.arg);
		},
		(in JsSwitchStatement x) {
			writeSwitch(writer, indent, x);
		},
		(in JsThrowStatement x) {
			writer ~= "throw ";
			writeExpr(writer, indent, *x.arg);
		},
		(in JsTryCatchStatement x) {
			writeTryCatch(writer, indent, x);
		},
		(in JsTryFinallyStatement x) {
			writeTryFinally(writer, indent, x);
		},
		(in JsVarDecl x) {
			writeVarDecl(writer, indent, x);
		},
		(in JsWhileStatement x) {
			writeWhile(writer, indent, x);
		});
}
// Optimized build has infinite compile time inlining 'writeStatement' into itself recursively.
// May be a similar issue to https://github.com/ldc-developers/ldc/issues/3879
pragma(inline, false)
void writeAssign(scope ref Output writer, uint indent, in JsAssignStatement a) {
	writeExpr(writer, indent, a.left);
	writer ~= " = ";
	writeExpr(writer, indent, a.right);
}
pragma(inline, false)
void writeIf(scope ref Output writer, uint indent, in JsIfStatement a) {
	writer ~= "if (";
	writeExpr(writer, indent + 2, a.cond);
	writer ~= ")";
	bool wasBlock = writeStatementIndented(writer, indent, a.then, StatementPos.first);
	if (has(a.else_)) {
		if (wasBlock)
			writer ~= ' ';
		else
			writeNewline(writer, indent);
		writer ~= "else";
		JsStatement else_ = force(a.else_);
		if (else_.kind.isA!(JsIfStatement*)) {
			writer ~= ' ';
			writeStatement(writer, indent, else_, StatementPos.first);
		} else
			cast(void) writeStatementIndented(writer, indent, else_, StatementPos.first);
	}
}
pragma(inline, false)
void writeSwitch(scope ref Output writer, uint indent, in JsSwitchStatement a) {
	writer ~= "switch (";
	writeExpr(writer, indent + 2, *a.arg);
	writer ~= ") {";
	foreach (JsSwitchStatement.Case case_; a.cases_) {
		writeNewline(writer, indent + 1);
		writer ~= "case ";
		writeExpr(writer, indent, case_.value);
		writer ~= ":";
		writeBlockStatement(writer, indent + 1, case_.then);
	}
	writeNewline(writer, indent + 1);
	writer ~= "default:";
	writeBlockStatement(writer, indent + 1, a.default_);
	writeNewline(writer, indent);
	writer ~= "}";
}
pragma(inline, false)
void writeTryCatch(scope ref Output writer, uint indent, in JsTryCatchStatement a) {
	writer ~= "try ";
	writeBlockStatement(writer, indent, a.tried);
	writer ~= " catch (";
	writeJsName(writer, a.exception);
	writer ~= ") ";
	writeBlockStatement(writer, indent, a.catch_);
}
pragma(inline, false)
void writeTryFinally(scope ref Output writer, uint indent, in JsTryFinallyStatement a) {
	writer ~= "try ";
	writeBlockStatement(writer, indent, a.tried);
	writer ~= " finally ";
	writeBlockStatement(writer, indent, a.finally_);
}
pragma(inline, false)
void writeVarDecl(scope ref Output writer, uint indent, in JsVarDecl a) {
	writer ~= stringOfEnum(a.const_);
	writer ~= ' ';
	writeDestructure(writer, a.destructure);
	if (has(a.initializer)) {
		writer ~= " = ";
		writeExpr(writer, indent, *force(a.initializer));
	}
}
pragma(inline, false)
void writeWhile(scope ref Output writer, uint indent, in JsWhileStatement a) {
	if (has(a.label)) {
		writeJsName(writer, force(a.label));
		writer ~= ": ";
	}
	writer ~= "while (";
	writeExpr(writer, indent + 2, *a.condition);
	writer ~= ')';
	writeBlockStatement(writer, indent, a.body_);
}

// Returns true if it was a block
bool writeStatementIndented(scope ref Output writer, uint indent, in JsStatement a, StatementPos pos) {
	if (a.kind.isA!JsBlockStatement) {
		writer ~= ' ';
		writeBlockStatement(writer, indent, a.kind.as!JsBlockStatement);
		return true;
	} else {
		writeNewline(writer, indent + 1);
		writeStatement(writer, indent + 1, a, pos);
		return false;
	}
}

struct ExprPos {
	@safe @nogc pure nothrow:

	bool isNonFirstStatement; // Expression is at the start of a statement and may need ';'
	bool isCalled; // Expression is called and may need to be wrapped in '()'

	ExprPos withCalled() =>
		ExprPos(isNonFirstStatement, isCalled: true);

	static ExprPos expr() =>
		ExprPos(false, false);
	static ExprPos statementFirst() =>
		ExprPos(isNonFirstStatement: false, isCalled: false);
	static ExprPos statementNonFirst() =>
		ExprPos(isNonFirstStatement: true, isCalled: false);
}
void writeExpr(scope ref Output writer, uint indent, in JsExpr a, ExprPos pos = ExprPos.expr) {
	markMap(writer, a.source);
	void writeArg(in JsExpr arg, ExprPos pos = ExprPos.expr) {
		writeExpr(writer, indent, arg, pos);
	}
	void writeArgs(in JsExpr[] args) {
		writeWithCommas!JsExpr(writer, args, (in JsExpr arg) {
			writeExpr(writer, indent + 1, arg);
		});
	}

	a.kind.matchIn!void(
		(in JsArrayExpr x) {
			writer ~= '[';
			writeArgs(x.elements);
			writer ~= ']';
		},
		(in JsArrowFunction x) {
			if (pos.isNonFirstStatement)
				writer ~= ';';
			if (pos.isCalled)
				writer ~= '(';
			maybeWriteAsync(writer, x.async);
			writeParams(writer, x.params, alwaysParens: false);
			writer ~= " =>";
			writeExprOrBlockStatementIndented(writer, indent, x.body_);
			if (pos.isCalled)
				writer ~= ')';
		},
		(in JsBinaryExpr x) {
			if (pos.isNonFirstStatement)
				writer ~= ';';
			writer ~= '(';
			writeArg(*x.left);
			writer ~= ' ';
			writer ~= () {
				final switch (x.kind) {
					case JsBinaryKind.and:
						return "&&";
					case JsBinaryKind.bitShiftLeft:
						return "<<";
					case JsBinaryKind.bitShiftRight:
						return ">>";
					case JsBinaryKind.bitwiseAnd:
						return "&";
					case JsBinaryKind.bitwiseOr:
						return "|";
					case JsBinaryKind.bitwiseXor:
						return "^";
					case JsBinaryKind.divide:
						return "/";
					case JsBinaryKind.eqEqEq:
						return "===";
					case JsBinaryKind.in_:
						return "in";
					case JsBinaryKind.instanceof:
						return "instanceof";
					case JsBinaryKind.less:
						return "<";
					case JsBinaryKind.minus:
						return "-";
					case JsBinaryKind.modulo:
						return "%";
					case JsBinaryKind.notEqEq:
						return "!==";
					case JsBinaryKind.or:
						return "||";
					case JsBinaryKind.plus:
						return "+";
					case JsBinaryKind.times:
						return "*";
				}
			}();
			writer ~= ' ';
			writeArg(*x.right);
			writer ~= ')';
		},
		(in JsCallExpr x) {
			writeArg(*x.called, pos.withCalled);
			writer ~= '(';
			writeArgs(x.args);
			writer ~= ')';
		},
		(in JsCallWithSpreadExpr x) {
			writeArg(*x.called, pos.withCalled);
			writer ~= '(';
			writeArgs(x.args);
			if (!isEmpty(x.args))
				writer ~= ", ";
			writer ~= "...";
			writeArg(*x.spreadArg);
			writer ~= ')';
		},
		(in JsLiteralBool x) {
			writer ~= x.value;
		},
		(in JsLiteralInteger x) {
			if (x.isSigned)
				writer ~= x.value.asSigned;
			else
				writer ~= x.value.asUnsigned;
			writer ~= 'n';
		},
		(in JsLiteralNumber x) {
			writeOnSingleLine(writer, (scope ref Writer w) {
				writeFloatLiteralForJS(w, x.value);
			});
		},
		(in JsLiteralString x) {
			writeOnSingleLine(writer, (scope ref Writer w) {
				writeQuotedString(w, x.value);
			});
		},
		(in JsLiteralStringFromMemberName x) {
			writeQuotedMemberName(writer, x.value);
		},
		(in JsLiteralStringFromSymbol x) {
			writeOnSingleLine(writer, (scope ref Writer w) {
				writeQuotedSymbol(w, x.value);
			});
		},
		(in JsName x) {
			writeJsName(writer, x);
		},
		(in JsNewExpr x) {
			writer ~= "new ";
			writer ~= '(';
			writeArg(*x.class_);
			writer ~= ')';
			writer ~= '(';
			writeArgs(x.arguments);
			writer ~= ')';
		},
		(in JsNullExpr x) {
			writer ~= "null";
		},
		(in JsObject1Expr x) {
			assert(!pos.isNonFirstStatement);
			writer ~= "{ ";
			writeObjectPair(writer, indent, x.key, *x.value);
			writer ~= " }";
		},
		(in JsPropertyAccessExpr x) {
			writeArg(*x.object, pos);
			writePropertyAccess(writer, x.propertyName);
		},
		(in JsPropertyAccessComputedExpr x) {
			writeArg(x.object, pos);
			writer ~= '[';
			writeArg(x.propertyName);
			writer ~= ']';
		},
		(in JsTernaryExpr x) {
			if (pos.isNonFirstStatement)
				writer ~= ';';
			if (pos.isCalled)
				writer ~= '(';
			writeArg(x.condition);
			writer ~= " ? ";
			writeArg(x.then);
			writer ~= " : ";
			writeArg(x.else_);
			if (pos.isCalled)
				writer ~= ')';
		},
		(in JsThisExpr x) {
			writer ~= "this";
		},
		(in JsUnaryExpr x) {
			if (pos.isNonFirstStatement)
				writer ~= ';';
			writer ~= '(';
			writer ~= () {
				final switch (x.kind) {
					case JsUnaryKind.await:
						return "await ";
					case JsUnaryKind.bitwiseNot:
						return "~";
					case JsUnaryKind.not:
						return "!";
					case JsUnaryKind.typeof_:
						return "typeof ";
					case JsUnaryKind.void_:
						return "void ";
				}
			}();
			writeArg(*x.arg);
			writer ~= ')';
		});
}

void maybeWriteAsync(scope ref Output writer, SyncOrAsync async) {
	final switch (async) {
		case SyncOrAsync.sync:
			break;
		case SyncOrAsync.async:
			writer ~= "async ";
			break;
	}
}

void writeObjectPair(scope ref Output writer, uint indent, JsMemberName key, in JsExpr value) {
	writeMemberName(writer, key);
	writer ~= ": ";
	writeExpr(writer, indent, value);
}
