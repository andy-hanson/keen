module concretize.gatherInfo;

@safe @nogc pure nothrow:

import model.concreteModel :
	ConcreteCommonFuns, ConcreteExpr, ConcreteExprKind, ConcreteFun, ConcreteFunBody, existsDirectChildExpr;
import model.constant : Constant;
import model.model : BuiltinBinary, BuiltinFun;
import util.alloc.alloc : Alloc, withTempAlloc;
import util.col.array : mustFind;
import util.col.mutArr : mustPop, MutArr, mutArrIsEmpty, push;
import util.col.mutMultiMap : eachValueForKey, MutMultiMap, add;
import util.col.mutSet : mayAddToMutSet, MutSet;
import util.col.set : moveToSet, Set;

Set!(immutable ConcreteFun*) getYieldingFuns(
	ref Alloc alloc,
	in ConcreteCommonFuns commonFuns,
	immutable ConcreteFun*[] allConcreteFuns,
) =>
	withTempAlloc(alloc.meta, (ref Alloc tempAlloc) {
		const CalledBy calledBy = buildCalledBy(tempAlloc, allConcreteFuns);

		// There is just 1 intrinsically yielding function: 'switch-fiber'
		ConcreteFun* switchFiberSuspension =
			mustFind!(immutable ConcreteFun*)(allConcreteFuns, (ref immutable ConcreteFun* x) => isSwitchFiber(*x));

		// These are functions known to yield that have been added to 'res' but not yet processed callers.
		MutArr!(immutable ConcreteFun*) toPropagate;
		MutSet!(immutable ConcreteFun*) res;

		void add(ConcreteFun* x) {
			if (mayAddToMutSet(alloc, res, x))
				push(alloc, toPropagate, x); // TODO: use temp alloc
		}

		add(switchFiberSuspension);
		while (!mutArrIsEmpty(toPropagate)) {
			ConcreteFun* fun = mustPop(toPropagate);
			eachValueForKey(calledBy, fun, (immutable ConcreteFun* caller) {
				if (caller != commonFuns.runFiber)
					add(caller);
			});
		}

		return moveToSet!(immutable ConcreteFun*)(res);
	});

private:

bool isSwitchFiber(in ConcreteFun a) {
	if (a.body_.isA!(ConcreteFunBody.Builtin)) {
		ConcreteFunBody.Builtin builtin = a.body_.as!(ConcreteFunBody.Builtin);
		return builtin.kind.isA!(BuiltinBinary) && builtin.kind.as!(BuiltinBinary) == BuiltinBinary.switchFiber;
	} else
		return false;
}

// Maps a function to all functions that call it.
alias CalledBy = MutMultiMap!(immutable ConcreteFun*, immutable ConcreteFun*);

CalledBy buildCalledBy(ref Alloc alloc, in immutable ConcreteFun*[] allConcreteFuns) {
	CalledBy res;
	foreach (ConcreteFun* fun; allConcreteFuns)
		fun.body_.match!void(
			(ConcreteFunBody.Builtin x) {
				assert(!x.kind.isA!(BuiltinFun.CallLambda));
			},
			(ConcreteFunBody.Extern) {},
			(ConcreteExpr x) {
				if (!x.kind.isA!Constant)
					buildCalledByRecur(alloc, res, fun, x);
			},
			(ConcreteFunBody.VarGet) {},
			(ConcreteFunBody.VarSet) {},
			(ConcreteFunBody.Deferred) => assert(false));
	return res;
}

void buildCalledByRecur(ref Alloc alloc, ref CalledBy res, ConcreteFun* f, ref ConcreteExpr expr) {
	if (expr.kind.isA!(ConcreteExprKind.Call))
		add(alloc, res, expr.kind.as!(ConcreteExprKind.Call).called, f);
	existsDirectChildExpr(expr, (ref ConcreteExpr child) {
		buildCalledByRecur(alloc, res, f, child);
		return false;
	});
}
