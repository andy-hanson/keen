module concretize.constantsOrExprs;

@safe @nogc pure nothrow:

import model.concreteModel : ConcreteExpr, Constant;
import util.alloc.alloc : Alloc;
import util.col.array : every, map, SmallArray;
import util.union_ : TaggedUnion;

immutable struct ConstantsOrExprs {
	mixin TaggedUnion!(SmallArray!Constant, SmallArray!ConcreteExpr);
}

ConstantsOrExprs asConstantsOrExprs(ref Alloc alloc, ConcreteExpr[] exprs) =>
	every!ConcreteExpr(exprs, (in ConcreteExpr arg) => arg.kind.isA!Constant)
		? ConstantsOrExprs(map(alloc, exprs, (ref ConcreteExpr arg) => arg.kind.as!Constant))
		: ConstantsOrExprs(exprs);
