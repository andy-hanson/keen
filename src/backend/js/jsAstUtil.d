module backend.js.jsAstUtil;

@safe @nogc pure nothrow:

import backend.js.jsAst :
	genArray,
	genArrowFunction,
	genBlockStatement,
	genCall,
	genCallPropertySync,
	genGlobal,
	genIf,
	genIn,
	genInteger,
	genNew,
	genNotNot,
	genNumber,
	genPropertyAccess,
	genPropertyAccessComputed,
	genString,
	genThrow,
	JsBlockStatement,
	JsExpr,
	JsExprOrBlockStatement,
	JsMemberName,
	JsParams,
	JsStatement,
	SyncOrAsync;
import backend.js.sourceMap : Source;
import model.model : EnumOrFlagsMember, isSigned, StructInst, SumTypeMemberAndMethodImpls;
import util.alloc.alloc : Alloc;
import util.col.array : foldReverseWithIndex;
import util.memory : allocate;
import util.symbol : Symbol, symbol;

JsExpr genIife(ref Alloc alloc, in Source source, SyncOrAsync async, JsBlockStatement body_) =>
	genCall(
		alloc, source, async,
		allocate(alloc, genArrowFunction(source, async, JsParams(), JsExprOrBlockStatement(body_))),
		[]);

JsStatement genThrowJsError(ref Alloc alloc, in Source source, string message) =>
	genThrow(alloc, source, genNew(alloc, source, genGlobal(source, symbol!"Error"), [genString(source, message)]));
JsStatement genThrowBogus(ref Alloc alloc, in Source source) =>
	genThrowJsError(alloc, source, "Reached compile error");
JsExpr genThrowBogusExpr(ref Alloc alloc, in Source source) =>
	genIife(alloc, source, SyncOrAsync.sync, genBlockStatement(alloc, [genThrowBogus(alloc, source)]));

JsBlockStatement matchUnionMembers(
	ref Alloc alloc,
	in Source source,
	in SumTypeMemberAndMethodImpls[] members,
	JsExpr p0,
	in JsStatement delegate(size_t, ref SumTypeMemberAndMethodImpls) @safe @nogc pure nothrow cbCase,
) =>
	genBlockStatement(alloc, [
		foldReverseWithIndex!(JsStatement, SumTypeMemberAndMethodImpls)(
			genThrowJsError(alloc, source, "Invalid union value"),
			members,
			(JsStatement else_, size_t index, ref SumTypeMemberAndMethodImpls member) =>
				genIf(
					alloc,
					source,
					genIsUnionMember(alloc, source, p0, member.member),
					cbCase(index, member), else_))]);

JsExpr genIsUnionMember(ref Alloc alloc, in Source source, JsExpr a, StructInst* member) =>
	genIn(alloc, source, JsMemberName.unionMember(member.decl.name), a);

JsExpr genForceUnionMember(ref Alloc alloc, in Source source, JsExpr a, StructInst* member) =>
	genPropertyAccess(alloc, source, a, JsMemberName.unionMember(member.decl.name));

JsExpr genOptionHas(ref Alloc alloc, in Source source, JsExpr option) =>
	// !!option.length
	genNotNot(alloc, source, genPropertyAccess(alloc, source, option, JsMemberName.noPrefix(symbol!"length")));
JsExpr genOptionForce(ref Alloc alloc, in Source source, JsExpr option) =>
	// option[0]
	genPropertyAccessComputed(alloc, source, option, genNumber(source, 0));
JsExpr genOptionSome(ref Alloc alloc, in Source source, JsExpr arg) =>
	// [option]
	genArray(alloc, source, [arg]);
JsExpr genOptionNone(in Source source) =>
	genArray(source, []);

JsExpr genEnumIntegralValue(in Source source, ref EnumOrFlagsMember member) =>
	genInteger(source, isSigned(member.storage), member.value);

JsExpr genCallMath(ref Alloc alloc, in Source source, Symbol name, in JsExpr[] args) =>
	genCallPropertySync(alloc, source, genGlobal(source, symbol!"Math"), JsMemberName.noPrefix(name), args);

JsExpr genToFloat32(ref Alloc alloc, in Source source, JsExpr arg) =>
	genCallMath(alloc, source, symbol!"fround", [arg]);
