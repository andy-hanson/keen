module concretize.checkConcreteModel;

@safe @nogc pure nothrow:

import frontend.showModel : ShowCtx;
import model.concreteModel :
	ConcreteExpr,
	ConcreteExprKind,
	ConcreteFun,
	ConcreteLocal,
	ConcreteProgram,
	ConcreteStruct,
	ConcreteStructBody,
	ConcreteType,
	isBogus,
	isVoid,
	mustBeByVal,
	pointeeType,
	ReferenceKind,
	sizeOrPointerSizeBytes;
import model.constant : Constant;
import model.model : BuiltinType, isCharOrIntegral;
import model.showLowModel : writeConcreteType;
import util.col.array : every, only, zip;
import util.conv : safeToSizeT;
import util.integralValues : IntegralValues, singleIntegralValue;
import util.opt : force, has;
import util.util : castNonScope_ref, ptrTrustMe;
import util.writer : debugLogWithWriter, Writer;

void checkConcreteProgram(in ShowCtx printCtx, in ConcreteCommonTypes types, in ConcreteProgram a) {
	Ctx ctx = Ctx(ptrTrustMe(printCtx), ptrTrustMe(types));
	foreach (ConcreteFun* fun; a.allFuns)
		if (fun.body_.isA!ConcreteExpr)
			checkExpr(ctx, fun.returnType, fun.body_.as!ConcreteExpr);
}

immutable struct ConcreteCommonTypes {
	ConcreteType bool_;
	ConcreteType exception;
	ConcreteType nat64;
	ConcreteType symbol;
	ConcreteType void_;
}

private:

struct Ctx {
	ShowCtx* printCtx;
	ConcreteCommonTypes* types;
}

void checkExpr(ref Ctx ctx, in ConcreteType type, in ConcreteExpr expr) {
	assert(!isBogus(type) || expr.kind.isA!(ConcreteExprKind.Throw*));
	checkType(ctx, type, expr.type);
	expr.kind.matchIn!void(
		(in ConcreteExprKind.Builtin x) {
			// TODO: type depending on the BuiltinFun ............................................................................
			foreach (ConcreteExpr arg; x.args) {
				checkExpr(ctx, arg.type, arg);				
			}
		},
		(in ConcreteExprKind.Call x) {
			checkType(ctx, type, x.called.returnType);
			zip(x.called.params, x.args, (ref ConcreteLocal param, ref ConcreteExpr arg) {
				checkExpr(ctx, param.type, arg);
			});
		},
		(in ConcreteExprKind.Cast x) {
			assert(sizeOrPointerSizeBytes(type) == sizeOrPointerSizeBytes(x.inner.type));
			checkExpr(ctx, x.inner.type, *x.inner);
		},
		(in Constant) {},
		(in ConcreteExprKind.CreateArray x) {
			// TODO: validate 'type' is an array type and 'args' are elements
			foreach (ConcreteExpr arg; x.args)
				checkExprAnyType(ctx, arg);
		},
		(in ConcreteExprKind.CreateRecord x) {
			// TODO: validate 'type' is a record and this creates it
			foreach (ConcreteExpr arg; x.args)
				checkExprAnyType(ctx, arg);
		},
		(in ConcreteExprKind.CreateUnion x) {
			checkExpr(ctx, mustBeByVal(type).body_.as!(ConcreteStructBody.Union).members[x.memberIndex], x.arg);
		},
		(in ConcreteExprKind.Drop x) {
			assert(isVoid(type));
			checkExprAnyType(ctx, x.arg);
		},
		(in ConcreteExprKind.Finally x) {
			checkExpr(ctx, ctx.types.void_, x.right);
			checkExpr(ctx, type, x.below);
		},
		(in ConcreteExprKind.If x) {
			checkExpr(ctx, ctx.types.bool_, x.cond);
			checkExpr(ctx, type, x.then);
			checkExpr(ctx, type, x.else_);
		},
		(in ConcreteExprKind.Let x) {
			checkExpr(ctx, x.local.type, x.value);
			checkExpr(ctx, type, x.then);
		},
		(in ConcreteExprKind.LocalGet x) {
			checkType(ctx, type, x.local.type);
		},
		(in ConcreteExprKind.LocalPointer x) {
			checkType(ctx, pointeeType(type), x.local.type);
		},
		(in ConcreteExprKind.LocalSet x) {
			assert(isVoid(type));
			checkExpr(ctx, x.local.type, x.value);
		},
		(in ConcreteExprKind.Loop x) {
			checkExpr(ctx, type, x.body_);
		},
		(in ConcreteExprKind.LoopBreak x) {
			checkExpr(ctx, type, x.value);
		},
		(in ConcreteExprKind.LoopContinue x) {},
		(in ConcreteExprKind.MatchEnumOrIntegral x) {
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
		(in ConcreteExprKind.MatchStringLike x) {
			checkExprAnyType(ctx, x.matched);
			assert(x.equals.returnType == ctx.types.bool_);
			assert(x.equals.params.length == 2);
			assert(every!ConcreteLocal(x.equals.params, (in ConcreteLocal param) =>
				param.type == x.matched.type));
			foreach (ConcreteExprKind.MatchStringLike.Case case_; x.cases)
				checkExpr(ctx, type, case_.then);
			checkExpr(ctx, type, x.else_);
		},
		(in ConcreteExprKind.MatchUnion x) {
			checkExprAnyType(ctx, x.matched);
			ConcreteType[] members = unionMembers(ctx, x.matched.type);
			assert(x.memberIndices.length <= members.length);
			checkMatchUnionCases(ctx, type, x.matched.type, x.memberIndices, x.cases);
			if (has(x.else_))
				checkExpr(ctx, type, *force(x.else_));
		},
		(in ConcreteExprKind.RecordFieldGet x) {
			checkExprAnyType(ctx, *x.record);
			assert(x.record.type.struct_.body_.as!(ConcreteStructBody.Record).fields[x.fieldIndex].type == type);
		},
		(in ConcreteExprKind.RecordFieldPointer x) {
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
		(in ConcreteExprKind.RecordFieldSet x) {
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
		(in ConcreteExprKind.Seq x) {
			checkExpr(ctx, ctx.types.void_, x.first);
			checkExpr(ctx, type, x.then);
		},
		(in ConcreteExprKind.Throw x) {
			checkExpr(ctx, ctx.types.exception, x.thrown);
		},
		(in ConcreteExprKind.Try x) {
			checkExpr(ctx, type, x.tried);
			checkMatchUnionCases(ctx, type, ctx.types.exception, x.exceptionMemberIndices, x.catchCases);
		},
		(in ConcreteExprKind.TryLet x) {
			checkExpr(ctx, has(x.local) ? force(x.local).type : x.value.type, x.value);
			checkMatchUnionCases(
				ctx, type, ctx.types.exception,
				singleIntegralValue(x.exceptionMemberIndex),
				[castNonScope_ref(x.catch_)]);
			checkExpr(ctx, type, x.then);
		},
		(in ConcreteExprKind.UnionAs x) {
			ConcreteType actualType = unionMembers(ctx, x.union_.type)[x.memberIndex];
			checkType(ctx, type, actualType);
			checkExprAnyType(ctx, *x.union_);
		},
		(in ConcreteExprKind.UnionKind x) {
			checkType(ctx, type, ctx.types.nat64);
			ConcreteStructBody body_ = mustBeByVal(x.union_.type).body_;
			assert(body_.isA!(ConcreteStructBody.Union));
		});
}

void checkMatchUnionCases(
	ref Ctx ctx,
	in ConcreteType type,
	in ConcreteType unionOrVariant,
	in IntegralValues memberIndices,
	in ConcreteExprKind.MatchUnion.Case[] cases,
) {
	assert(cases.length == memberIndices.length);
	ConcreteType[] members = unionMembers(ctx, unionOrVariant);
	foreach (size_t caseIndex, ConcreteExprKind.MatchUnion.Case case_; cases) {
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
