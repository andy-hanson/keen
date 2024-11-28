module concretize.checkConcreteModel;

@safe @nogc pure nothrow:

import frontend.showModel : ShowCtx;
import model.concreteModel :
	BuiltinConcreteExpr,
	CallConcreteExpr,
	CastConcreteExpr,
	ConcreteExpr,
	ConcreteFun,
	ConcreteLocal,
	ConcreteMatchStringLikeCase,
	ConcreteMatchUnionCase,
	ConcreteProgram,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteType,
	CreateArrayConcreteExpr,
	CreateRecordConcreteExpr,
	CreateUnionConcreteExpr,
	DropConcreteExpr,
	FinallyConcreteExpr,
	IfConcreteExpr,
	isBogus,
	isPointer,
	isVoid,
	LetConcreteExpr,
	LocalGetConcreteExpr,
	LocalPointerConcreteExpr,
	LocalSetConcreteExpr,
	LoopBreakConcreteExpr,
	LoopConcreteExpr,
	LoopContinueConcreteExpr,
	MatchEnumOrIntegralConcreteExpr,
	MatchStringLikeConcreteExpr,
	MatchUnionConcreteExpr,
	mustBeByVal,
	pointeeType,
	RecordFieldGetConcreteExpr,
	RecordFieldPointerConcreteExpr,
	RecordFieldSetConcreteExpr,
	ReferenceKind,
	SeqConcreteExpr,
	sizeOrPointerSizeBytes,
	ThrowConcreteExpr,
	TryConcreteExpr,
	TryLetConcreteExpr,
	UnionAsConcreteExpr,
	UnionKindConcreteExpr;
import model.constant : Constant, ConstantRecord;
import model.model :
	Builtin4ary,
	BuiltinBinary,
	BuiltinBinaryLazy,
	BuiltinBinaryMath,
	BuiltinFunAllTests,
	BuiltinFunCallFunPointer,
	BuiltinFunCallLambda,
	BuiltinFunConstant,
	BuiltinFunGcSafeValue,
	BuiltinFunInit,
	BuiltinFunMarkRoot,
	BuiltinFunMarkVisit,
	BuiltinFunNewEmptyOption,
	BuiltinFunNewNonEmptyOption,
	BuiltinFunPointerCast,
	BuiltinFunSizeOf,
	BuiltinFunStaticSymbols,
	BuiltinTernary,
	BuiltinType,
	BuiltinUnary,
	BuiltinUnaryMath,
	IntegralType,
	isCharOrIntegral,
	JsFun;
import model.showLowModel : writeConcreteType;
import util.col.array : every, only, zip;
import util.col.enumMap : EnumMap;
import util.conv : safeToSizeT;
import util.integralValues : IntegralValues, singleIntegralValue;
import util.opt : force, has;
import util.util : castNonScope_ref, ptrTrustMe, stringOfEnum;
import util.writer : debugLogWithWriter, Writer;
import versionInfo : VersionFun;

void checkConcreteProgram(in ShowCtx printCtx, in ConcreteCommonTypes types, in ConcreteProgram a) {
	Ctx ctx = Ctx(ptrTrustMe(printCtx), ptrTrustMe(types));
	foreach (ConcreteFun* fun; a.allFuns)
		if (fun.body_.isA!ConcreteExpr)
			checkExpr(ctx, fun.returnType, fun.body_.as!ConcreteExpr);
}

immutable struct ConcreteCommonTypes {
	@safe @nogc pure nothrow:
	ConcreteType bool_;
	ConcreteType exception;
	EnumMap!(IntegralType, ConcreteType) integralTypes;
	ConcreteType symbol;
	ConcreteType void_;

	ConcreteType int8() => integralTypes[IntegralType.int8];
	ConcreteType int16() => integralTypes[IntegralType.int16];
	ConcreteType int32() => integralTypes[IntegralType.int32];
	ConcreteType int64() => integralTypes[IntegralType.int64];
	ConcreteType nat8() => integralTypes[IntegralType.nat8];
	ConcreteType nat16() => integralTypes[IntegralType.nat16];
	ConcreteType nat32() => integralTypes[IntegralType.nat32];
	ConcreteType nat64() => integralTypes[IntegralType.nat64];
}

private:

struct Ctx {
	ShowCtx* printCtx;
	ConcreteCommonTypes* types;
}

void checkExpr(ref Ctx ctx, in ConcreteType type, in ConcreteExpr expr) {
	assert(!isBogus(type) || expr.kind.isA!(ThrowConcreteExpr*));
	checkType(ctx, type, expr.type);
	expr.kind.matchIn!void(
		(in BuiltinConcreteExpr x) {
			checkBuiltin(ctx, type, x);
		},
		(in CallConcreteExpr x) {
			checkType(ctx, type, x.called.returnType);
			zip(x.called.params, x.args, (ref ConcreteLocal param, ref ConcreteExpr arg) {
				checkExpr(ctx, param.type, arg);
			});
		},
		(in CastConcreteExpr x) {
			assert(sizeOrPointerSizeBytes(type) == sizeOrPointerSizeBytes(x.inner.type));
			checkExpr(ctx, x.inner.type, *x.inner);
		},
		(in Constant x) {
			if (x.isA!ConstantRecord) {
				assert(mustBeByVal(type).body_.isA!(ConcreteStructBody.Record));
			}
			// TODO: More checks
		},
		(in CreateArrayConcreteExpr x) {
			// TODO: validate 'type' is an array type and 'args' are elements
			foreach (ConcreteExpr arg; x.args)
				checkExprAnyType(ctx, arg);
		},
		(in CreateRecordConcreteExpr x) {
			// TODO: validate 'type' is a record and this creates it
			foreach (ConcreteExpr arg; x.args)
				checkExprAnyType(ctx, arg);
		},
		(in CreateUnionConcreteExpr x) {
			checkExpr(ctx, mustBeByVal(type).body_.as!(ConcreteStructBody.Union).members[x.memberIndex], x.arg);
		},
		(in DropConcreteExpr x) {
			assert(isVoid(type));
			checkExprAnyType(ctx, x.arg);
		},
		(in FinallyConcreteExpr x) {
			checkExpr(ctx, ctx.types.void_, x.right);
			checkExpr(ctx, type, x.below);
		},
		(in IfConcreteExpr x) {
			checkExpr(ctx, ctx.types.bool_, x.cond);
			checkExpr(ctx, type, x.then);
			checkExpr(ctx, type, x.else_);
		},
		(in LetConcreteExpr x) {
			checkExpr(ctx, x.local.type, x.value);
			checkExpr(ctx, type, x.then);
		},
		(in LocalGetConcreteExpr x) {
			checkType(ctx, type, x.local.type);
		},
		(in LocalPointerConcreteExpr x) {
			checkType(ctx, pointeeType(type), x.local.type);
		},
		(in LocalSetConcreteExpr x) {
			assert(isVoid(type));
			checkExpr(ctx, x.local.type, x.value);
		},
		(in LoopConcreteExpr x) {
			checkExpr(ctx, type, x.body_);
		},
		(in LoopBreakConcreteExpr x) {
			checkExpr(ctx, type, x.value);
		},
		(in LoopContinueConcreteExpr x) {},
		(in MatchEnumOrIntegralConcreteExpr x) {
			ConcreteStructBody body_ = mustBeByVal(x.matched.type).body_;
			assert(
				body_.isA!(ConcreteStructBody.Enum) ||
				isCharOrIntegral(body_.as!(ConcreteStructBody.Builtin*).kind));
			checkExprAnyType(ctx, x.matched);
			foreach (ConcreteExpr case_; x.caseExprs)
				checkExpr(ctx, type, case_);
			if (has(x.else_))
				checkExpr(ctx, type, *force(x.else_));
		},
		(in MatchStringLikeConcreteExpr x) {
			checkExprAnyType(ctx, x.matched);
			assert(x.equals.returnType == ctx.types.bool_);
			assert(x.equals.params.length == 2);
			assert(every!ConcreteLocal(x.equals.params, (in ConcreteLocal param) =>
				param.type == x.matched.type));
			foreach (ConcreteMatchStringLikeCase case_; x.cases)
				checkExpr(ctx, type, case_.then);
			checkExpr(ctx, type, x.else_);
		},
		(in MatchUnionConcreteExpr x) {
			checkExprAnyType(ctx, x.matched);
			ConcreteType[] members = unionMembers(ctx, x.matched.type);
			assert(x.memberIndices.length <= members.length);
			checkMatchUnionCases(ctx, type, x.matched.type, x.memberIndices, x.cases);
			if (has(x.else_))
				checkExpr(ctx, type, *force(x.else_));
		},
		(in RecordFieldGetConcreteExpr x) {
			checkExprAnyType(ctx, *x.record);
			assert(x.record.type.struct_.body_.as!(ConcreteStructBody.Record).fields[x.fieldIndex].type == type);
		},
		(in RecordFieldPointerConcreteExpr x) {
			checkExprAnyType(ctx, *x.record);
			ConcreteStruct* record = () {
				final switch (x.record.type.reference) {
					case ReferenceKind.byVal:
						return mustBeByVal(pointeeType(x.record.type));
					case ReferenceKind.byRef:
						return x.record.type.struct_;
				}
			}();
			assert(record.body_.as!(ConcreteStructBody.Record).fields[x.fieldIndex].type == pointeeType(type));
		},
		(in RecordFieldSetConcreteExpr x) {
			assert(isVoid(type));
			checkExprAnyType(ctx, x.record);
			ConcreteStruct* struct_ = x.record.type.struct_;
			ConcreteType recordType = () {
				if (struct_.body_.isA!(ConcreteStructBody.Builtin*)) {
					ConcreteStructBody.Builtin* builtin = struct_.body_.as!(ConcreteStructBody.Builtin*);
					assert(builtin.kind == BuiltinType.pointerMut);
					return only(builtin.typeArgs);
				} else
					return x.record.type;
			}();
			checkExpr(ctx, recordType.struct_.body_.as!(ConcreteStructBody.Record).fields[x.fieldIndex].type, x.value);
		},
		(in SeqConcreteExpr x) {
			checkExpr(ctx, ctx.types.void_, x.first);
			checkExpr(ctx, type, x.then);
		},
		(in ThrowConcreteExpr x) {
			checkExpr(ctx, ctx.types.exception, x.thrown);
		},
		(in TryConcreteExpr x) {
			checkExpr(ctx, type, x.tried);
			checkMatchUnionCases(ctx, type, ctx.types.exception, x.exceptionMemberIndices, x.catchCases);
		},
		(in TryLetConcreteExpr x) {
			checkExpr(ctx, has(x.local) ? force(x.local).type : x.value.type, x.value);
			checkMatchUnionCases(
				ctx, type, ctx.types.exception,
				singleIntegralValue(x.exceptionMemberIndex),
				[castNonScope_ref(x.catch_)]);
			checkExpr(ctx, type, x.then);
		},
		(in UnionAsConcreteExpr x) {
			ConcreteType actualType = unionMembers(ctx, x.union_.type)[x.memberIndex];
			checkType(ctx, type, actualType);
			checkExprAnyType(ctx, *x.union_);
		},
		(in UnionKindConcreteExpr x) {
			checkType(ctx, type, ctx.types.nat64);
			ConcreteStructBody body_ = mustBeByVal(x.union_.type).body_;
			assert(body_.isA!(ConcreteStructBody.Union));
		});
}

void checkBuiltin(ref Ctx ctx, in ConcreteType type, in BuiltinConcreteExpr a) {
	a.fun.match!void(
		(BuiltinFunAllTests _) {
			assert(false);
		},
		(BuiltinUnary x) {
			checkBuiltinUnary(ctx, type, x, only(a.args));
		},
		(BuiltinUnaryMath _) {
			assert(false);
		},
		(BuiltinBinary x) {
			assert(a.args.length == 2);
			checkBuiltinBinary(ctx, type, x, a.args[0], a.args[1]);
		},
		(BuiltinBinaryLazy _) {
			assert(false);
		},
		(BuiltinBinaryMath _) {
			assert(false);
		},
		(BuiltinTernary _) {
			assert(false);
		},
		(Builtin4ary _) {
			assert(false);
		},
		(BuiltinFunCallLambda _) {
			assert(false);
		},
		(BuiltinFunCallFunPointer _) {
			assert(false);
		},
		(BuiltinFunConstant _) {
			assert(false);
		},
		(BuiltinFunGcSafeValue _) {
			assert(false);
		},
		(BuiltinFunInit _) {
			assert(false);
		},
		(JsFun _) {
			assert(false);
		},
		(BuiltinFunMarkRoot _) {
			assert(false);
		},
		(BuiltinFunMarkVisit _) {
			assert(false);
		},
		(BuiltinFunNewEmptyOption _) {
			assert(false);
		},
		(BuiltinFunNewNonEmptyOption _) {
			assert(false);
		},
		(BuiltinFunPointerCast _) {
			assert(false);
		},
		(BuiltinFunSizeOf _) {
			assert(false);
		},
		(BuiltinFunStaticSymbols _) {
			assert(false);
		},
		(VersionFun _) {
			assert(false);
		});
}

void checkBuiltinUnary(ref Ctx ctx, in ConcreteType type, BuiltinUnary kind, ConcreteExpr a) {
	void check(ConcreteType returnType, ConcreteType argType) {
		checkType(ctx, type, returnType);
		checkExpr(ctx, argType, a);
	}
	void check2(ConcreteType type) {
		check(type, type);
	}
	ref ConcreteCommonTypes types() =>
		*ctx.types;

	switch (kind) {
		case BuiltinUnary.bitwiseNotNat8:
			return check2(types.nat8);
		case BuiltinUnary.bitwiseNotNat16:
			return check2(types.nat16);
		case BuiltinUnary.bitwiseNotNat32:
			return check2(types.nat32);
		case BuiltinUnary.bitwiseNotNat64:
			return check2(types.nat64);
		default:
			debugLogWithWriter((scope ref Writer writer) {
				writer ~= stringOfEnum(kind);
			});
			assert(false);
	}
}

void checkBuiltinBinary(
	ref Ctx ctx,
	in ConcreteType type,
	BuiltinBinary kind,
	ConcreteExpr a,
	ConcreteExpr b,
) {
	void check(ConcreteType returnType, ConcreteType aType, ConcreteType bType) {
		checkType(ctx, type, returnType);
		checkExpr(ctx, aType, a);
		checkExpr(ctx, bType, b);
	}
	void check3(ConcreteType type) {
		check(type, type, type);
	}
	ConcreteType bool_ = ctx.types.bool_;
	ref ConcreteCommonTypes types() =>
		*ctx.types;

	switch (kind) {
		case BuiltinBinary.bitwiseAndInt8:
		case BuiltinBinary.bitwiseOrInt8:
			return check3(types.int8);
		case BuiltinBinary.bitwiseAndInt16:
		case BuiltinBinary.bitwiseOrInt16:
			return check3(types.int16);
		case BuiltinBinary.bitwiseAndInt32:
		case BuiltinBinary.bitwiseOrInt32:
			return check3(types.int32);
		case BuiltinBinary.bitwiseAndInt64:
		case BuiltinBinary.bitwiseOrInt64:
			return check3(types.int64);
		case BuiltinBinary.bitwiseAndNat8:
		case BuiltinBinary.bitwiseOrNat8:
			return check3(types.nat8);
		case BuiltinBinary.bitwiseAndNat16:
		case BuiltinBinary.bitwiseOrNat16:
			return check3(types.nat16);
		case BuiltinBinary.bitwiseAndNat32:
		case BuiltinBinary.bitwiseOrNat32:
			return check3(types.nat32);
		case BuiltinBinary.bitwiseAndNat64:
		case BuiltinBinary.bitwiseOrNat64:
			return check3(types.nat64);
		case BuiltinBinary.equalInt8:
		case BuiltinBinary.lessInt8:
			return check(bool_, types.int8, types.int8);
		case BuiltinBinary.equalInt16:
		case BuiltinBinary.lessInt16:
			return check(bool_, types.int16, types.int16);
		case BuiltinBinary.equalInt32:
		case BuiltinBinary.lessInt32:
			return check(bool_, types.int32, types.int32);
		case BuiltinBinary.equalInt64:
		case BuiltinBinary.lessInt64:
			return check(bool_, types.int64, types.int64);
		case BuiltinBinary.equalNat8:
		case BuiltinBinary.lessNat8:
			return check(bool_, types.nat8, types.nat8);
		case BuiltinBinary.equalNat16:
		case BuiltinBinary.lessNat16:
			return check(bool_, types.nat16, types.nat16);
		case BuiltinBinary.equalNat32:
		case BuiltinBinary.lessNat32:
			return check(bool_, types.nat32, types.nat32);
		case BuiltinBinary.equalNat64:
		case BuiltinBinary.lessNat64:
			return check(bool_, types.nat64, types.nat64);
		case BuiltinBinary.equalPointer:
			checkType(ctx, type, bool_);
			assert(isPointer(a.type));
			checkType(ctx, a.type, b.type);
			checkExpr(ctx, a.type, a);
			checkExpr(ctx, b.type, b);
			break;
		default:
			debugLogWithWriter((scope ref Writer writer) {
				writer ~= stringOfEnum(kind);
			});
			assert(false);
	}
}

void checkMatchUnionCases(
	ref Ctx ctx,
	in ConcreteType type,
	in ConcreteType unionOrVariant,
	in IntegralValues memberIndices,
	in ConcreteMatchUnionCase[] cases,
) {
	assert(cases.length == memberIndices.length);
	ConcreteType[] members = unionMembers(ctx, unionOrVariant);
	foreach (size_t caseIndex, ConcreteMatchUnionCase case_; cases) {
		assert(
			!has(case_.local) ||
			force(case_.local).type == members[safeToSizeT(memberIndices[caseIndex].value)]);
		checkExpr(ctx, type, case_.then);
	}
}

ConcreteType[] unionMembers(ref Ctx ctx, in ConcreteType type) =>
	mustBeByVal(type).body_.as!(ConcreteStructBody.Union).members;

void checkExprAnyType(ref Ctx ctx, in ConcreteExpr expr) {
	checkExpr(ctx, expr.type, expr);
}

void checkType(ref Ctx ctx, in ConcreteType expected, in ConcreteType actual) {
	if (expected != actual) {
		debugLogWithWriter((scope ref Writer writer) {
			writer ~= "expected ";
			writeConcreteType(writer, *ctx.printCtx, expected);
			writer ~= " but was ";
			writeConcreteType(writer, *ctx.printCtx, actual);
		});
		assert(false);
	}
}
