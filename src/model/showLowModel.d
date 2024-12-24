module model.showLowModel;

@safe @nogc pure nothrow:

import model.concreteModel :
	ConcreteFun,
	ConcreteFunKey,
	ConcreteFunSourceLambda,
	ConcreteFunSourceTest,
	ConcreteFunSourceWrapMain,
	ConcreteGeneratedLocalKind,
	ConcreteLocal,
	ConcreteLocalSourceClosure,
	ConcreteStruct,
	ConcreteStructSourceBogus,
	ConcreteStructSourceInst,
	ConcreteStructSourceLambda,
	ConcreteType,
	ReferenceKind;
import frontend.showModel : ShowCtx, writeTypeArgsGeneric;
import model.lowModel :
	AllLowTypes,
	LowExternType,
	LowFun,
	LowFunIndex,
	LowFunPointerType,
	LowFunSourceGenerated,
	LowPointerConst,
	LowPointerGc,
	LowPointerMut,
	LowProgram,
	LowRecord,
	LowType,
	LowUnion,
	PrimitiveType;
import model.model : Local;
import model.sourceRange : UriLineAndColumnRange;
import util.col.array : only;
import util.util : stringOfEnum;
import util.writer : Writer, writeWithCommas;

void writeFunName(scope ref Writer writer, in ShowCtx ctx, in LowProgram lowProgram, LowFunIndex fun) {
	writeFunName(writer, ctx, lowProgram, lowProgram.allFuns[fun]);
}

void writeFunName(scope ref Writer writer, in ShowCtx ctx, in LowProgram lowProgram, in LowFun a) {
	a.source.matchIn!void(
		(in ConcreteFun x) {
			writeConcreteFunName(writer, ctx, x);
		},
		(in LowFunSourceGenerated x) {
			writer ~= x.name;
			writeLowTypeArgs(writer, ctx, lowProgram, x.typeArgs);
			writer ~= " (generated)";
		});
}

private void writeLowTypeArgs(
	scope ref Writer writer,
	in ShowCtx ctx,
	in LowProgram lowProgram,
	in LowType[] typeArgs,
) {
	writeTypeArgsGeneric!LowType(writer, typeArgs,
		(in LowType x) => false,
		(in LowType typeArg) {
			writeLowType(writer, ctx, lowProgram.allTypes, typeArg);
		});
}

void writeFunSig(scope ref Writer writer, in ShowCtx ctx, in LowProgram lowProgram, in LowFun a) {
	a.source.matchIn!void(
		(in ConcreteFun x) {
			writeConcreteFunSig(writer, ctx, x, a.mayYield);
		},
		(in LowFunSourceGenerated _) {
			writeFunName(writer, ctx, lowProgram, a);
		});
}

private void writeConcreteFunSig(scope ref Writer writer, in ShowCtx ctx, in ConcreteFun a, bool mayYield) {
	writeConcreteFunName(writer, ctx, a);
	writer ~= ' ';
	writeConcreteType(writer, ctx, a.returnType);
	writer ~= '(';
	writeWithCommas!ConcreteLocal(
		writer,
		a.params,
		(in ConcreteLocal param) {
			param.source.matchIn!void(
				(in Local p) {
					writer ~= p.name;
				},
				(in ConcreteLocalSourceClosure _) {
					writer ~= "<closure>";
				},
				(in ConcreteGeneratedLocalKind x) {
					writer ~= stringOfEnum(x);
				});
			writer ~= ' ';
			writeConcreteType(writer, ctx, param.type);
		});
	writer ~= ')';
	if (mayYield)
		writer ~= " may-yield";
	writer ~= ' ';

	UriLineAndColumnRange range = ctx.lineAndColumnGetters[a.range];
	writer ~= range.uri;
	writer ~= ' ';
	writer ~= range.range.start;
}

void writeConcreteType(scope ref Writer writer, in ShowCtx ctx, in ConcreteType a) {
	writeConcreteStruct(writer, ctx, *a.struct_);
	if (a.reference != ReferenceKind.byVal) {
		writer ~= ' ';
		writer ~= stringOfEnum(a.reference);
	}
}

private:

void writeLowType(scope ref Writer writer, in ShowCtx ctx, in AllLowTypes lowTypes, in LowType a) {
	a.matchIn!void(
		(in LowExternType _) {
			writer ~= "some extern type"; // TODO: more detail
		},
		(in LowFunPointerType _) {
			writer ~= "some fun ptr type"; // TODO: more detail
		},
		(in PrimitiveType x) {
			writer ~= stringOfEnum(x);
		},
		(in LowPointerGc x) {
			writer ~= "pointer-gc(";
			writeLowType(writer, ctx, lowTypes, *x.pointee);
			writer ~= ')';
		},
		(in LowPointerConst x) {
			writer ~= "pointer-const(";
			writeLowType(writer, ctx, lowTypes, *x.pointee);
			writer ~= ')';
		},
		(in LowPointerMut x) {
			writer ~= "pointer-mut(";
			writeLowType(writer, ctx, lowTypes, *x.pointee);
			writer ~= ')';
		},
		(in LowRecord x) {
			writeConcreteStruct(writer, ctx, *x.source);
		},
		(in LowUnion x) {
			writeConcreteStruct(writer, ctx, *x.source);
		});
}

void writeConcreteFunName(scope ref Writer writer, in ShowCtx ctx, in ConcreteFun a) {
	a.source.matchIn!void(
		(in ConcreteFunKey x) {
			writer ~= x.decl.name;
			writeConcreteTypeArgs(writer, ctx, x.typeArgs);
			// TODO: write spec impls?
		},
		(in ConcreteFunSourceLambda x) {
			writeConcreteFunName(writer, ctx, *x.containingFun);
			writer ~= ".lambda";
			writer ~= x.index;
		},
		(in ConcreteFunSourceTest _) {
			//TODO: more unique name for each test
			writer ~= "test";
		},
		(in ConcreteFunSourceWrapMain _) {
			writer ~= "wrap-main";
		});
}

void writeConcreteTypeArgs(scope ref Writer writer, in ShowCtx ctx, in ConcreteType[] a) {
	writeTypeArgsGeneric!ConcreteType(writer, a,
		(in ConcreteType x) => false,
		(in ConcreteType x) {
			writeConcreteType(writer, ctx, x);
		});
}

void writeConcreteStruct(scope ref Writer writer, in ShowCtx ctx, in ConcreteStruct a) {
	a.source.matchIn!void(
		(in ConcreteStructSourceBogus _) {
			writer ~= "BOGUS";
		},
		(in ConcreteStructSourceInst x) {
			switch (x.typeArgs.length) {
				case 0:
					break;
				case 1:
					writeConcreteType(writer, ctx, only(x.typeArgs));
					writer ~= ' ';
					break;
				default:
					writer ~= '(';
					writeWithCommas!ConcreteType(writer, x.typeArgs, (in ConcreteType arg) {
						writeConcreteType(writer, ctx, arg);
					});
					writer ~= ") ";
			}
			writer ~= x.decl.name;
		},
		(in ConcreteStructSourceLambda x) {
			writeConcreteFunName(writer, ctx, *x.containingFun);
			writer ~= ".lambda";
			writer ~= x.index;
		});
}
