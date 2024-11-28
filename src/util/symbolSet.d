module util.symbolSet;

@safe @nogc pure nothrow:

import model.integralValues :
	emptyIntegralValues, IntegralValue, IntegralValues, mapToIntegralValues, only, singleIntegralValue;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.col.array : fold, isEmpty, only;
import util.col.arrayBuilder : buildArray, Builder;
import util.conv : safeToUint;
import util.opt : Opt, optIf;
import util.symbol : Symbol;

immutable struct SymbolSet {
	@safe @nogc pure nothrow:

	// Since a Symbol is represented with an integer, just use IntegralValues
	private IntegralValues inner;

	Opt!Symbol asSingle() scope const =>
		optIf(inner.length == 1, () => toSymbol(only(inner)));
	bool isEmpty() scope const =>
		inner.isEmpty;

	bool opBinaryRight(string op)(Symbol x) scope const if (op == "in") =>
		toIntegral(x) in inner;
	bool containsAll(SymbolSet b) scope const =>
		inner.containsAll(b.inner);
	SymbolSet opBinary(string op)(Symbol x) const if (op == "|") =>
		SymbolSet(inner | toIntegral(x));
	SymbolSet opBinary(string op)(SymbolSet x) const if (op == "|") =>
		SymbolSet(inner | x.inner);
	SymbolSet opBinary(string op)(in Symbol[] xs) const if (op == "|") =>
		fold!(SymbolSet, Symbol)(this, xs, (SymbolSet acc, in Symbol x) =>
			acc | x);

	int opApply(in int delegate(Symbol) @safe @nogc pure nothrow cb) scope {
		foreach (IntegralValue x; inner) {
			int res = cb(toSymbol(x));
			if (res != 0)
				return res;
		}
		return 0;
	}
}

SymbolSet emptySymbolSet() =>
	SymbolSet(emptyIntegralValues);

SymbolSet symbolSet(Symbol a) =>
	SymbolSet(singleIntegralValue(toIntegral(a)));

alias SymbolSetBuilder = StackArrayBuilder!Symbol;
SymbolSet buildSymbolSet(in void delegate(scope ref SymbolSetBuilder) @safe @nogc pure nothrow cb) =>
	withBuildStackArray!(SymbolSet, Symbol)(cb, (scope Symbol[] symbols) =>
		SymbolSet(mapToIntegralValues!Symbol(symbols, (ref const Symbol x) => toIntegral(x))));

Symbol[] symbolSetDifference(ref Alloc alloc, SymbolSet a, SymbolSet b) =>
	buildArray!Symbol(alloc, (scope ref Builder!Symbol out_) {
		foreach (Symbol x; a)
			if (x !in b)
				out_ ~= x;
	});

private:

Symbol toSymbol(IntegralValue a) =>
	Symbol.fromValue(safeToUint(a.asUnsigned));

IntegralValue toIntegral(Symbol a) =>
	IntegralValue(a.value);
