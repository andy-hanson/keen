module util.exitCode;
import util.union_ : TaggedUnion;

@safe @nogc nothrow: // not pure

immutable struct ExitCode {
	@safe @nogc pure nothrow:
	int value;

	uint asUintForTaggedUnion() =>
		cast(uint) value;
	static ExitCode fromUintForTaggedUnion(uint a) =>
		ExitCode(cast(int) a);

	static ExitCode ok() =>
		ExitCode(0);
	static ExitCode error() =>
		ExitCode(1);
}

pure ExitCode exitCodeCombine(ExitCode a, ExitCode b) =>
	a == ExitCode.ok ? b : a;
pure ExitCodeOrSignal exitCodeCombine(ExitCodeOrSignal a, ExitCode b) =>
	a.match!ExitCodeOrSignal(
		(ExitCode x) =>
			ExitCodeOrSignal(exitCodeCombine(x, b)),
		(Signal x) =>
			ExitCodeOrSignal(x));

ExitCode okAnd(ExitCode a, in ExitCode delegate() @safe @nogc nothrow cb) =>
	a == ExitCode.ok ? cb() : a;
ExitCode okAnd(ExitCode a, in ExitCode delegate() @safe @nogc nothrow cb, in ExitCode delegate() @safe @nogc nothrow cb2) => //rename
	okAnd(a, () =>
		okAnd(cb(), cb2));

ExitCodeOrSignal okAnd(ExitCodeOrSignal a, in ExitCodeOrSignal delegate() @safe @nogc nothrow cb) =>
	a.isA!ExitCode && a.as!ExitCode == ExitCode.ok ? cb() : a;

ExitCodeOrSignal okAnd(
	ExitCodeOrSignal a,
	in ExitCodeOrSignal delegate() @safe @nogc nothrow cb,
	in ExitCodeOrSignal delegate() @safe @nogc nothrow cb2,
) =>
	okAnd(a, () =>
		okAnd(cb(), cb2));

ExitCode onError(ExitCode a, in ExitCode delegate() @safe @nogc nothrow cb) =>
	a == ExitCode.ok ? a : cb();

ExitCode eachUntilError(T)(in T[] xs, in ExitCode delegate(ref T) @safe @nogc nothrow cb) {
	foreach (ref T x; xs) {
		ExitCode res = cb(x);
		if (res != ExitCode.ok)
			return res;
	}
	return ExitCode.ok;
}
ExitCodeOrSignal eachUntilError(T)(in T[] xs, in ExitCodeOrSignal delegate(ref T) @safe @nogc nothrow cb) {
	foreach (ref T x; xs) {
		ExitCodeOrSignal res = cb(x);
		if (res != ExitCodeOrSignal.ok)
			return res;
	}
	return ExitCodeOrSignal.ok;
}

immutable struct ExitCodeOrSignal {
	@safe @nogc nothrow:

	mixin TaggedUnion!(ExitCode, Signal);

	pure static ExitCodeOrSignal ok() =>
		ExitCodeOrSignal(ExitCode.ok);
	pure static ExitCodeOrSignal error() =>
		ExitCodeOrSignal(ExitCode.error);
}

immutable struct Signal {
	@safe @nogc pure nothrow:

	int signal;

	uint asUintForTaggedUnion() =>
		cast(uint) signal;
	static Signal fromUintForTaggedUnion(uint a) =>
		Signal(cast(int) a);
}

pure bool isOk(in ExitCodeOrSignal a) =>
	a.asExitCode == ExitCode.ok;

pure ExitCode asExitCode(in ExitCodeOrSignal a) =>
	a.match!ExitCode(
		(ExitCode x) =>
			x,
		(Signal _) =>
			ExitCode.error);
