module backend.mangle;

@safe @nogc pure nothrow:

import model.concreteModel :
	ConcreteFun,
	ConcreteFunBody,
	ConcreteFunKey,
	ConcreteFunSource,
	ConcreteStruct,
	ConcreteStructSource;
import model.lowModel :
	LowExternType,
	LowFun,
	LowFunIndex,
	LowFunPointerType,
	LowFunSource,
	LowLocal,
	LowProgram,
	LowRecord,
	LowType,
	LowUnion,
	LowVar,
	LowVarIndex,
	LowVarKind;
import util.alloc.alloc : Alloc;
import util.col.map : Map;
import util.col.mapBuilder : finishMap, mustAddToMap, MapBuilder;
import util.col.fullIndexMap : FullIndexMap, mapFullIndexMap;
import util.col.mutMap : getOrAdd, insertOrUpdate, MutMap, setInMap;
import util.opt : force, has, Opt;
import util.string : isAsciiIdentifierChar;
import util.symbol : Symbol, symbol;
import util.union_ : TaggedUnion;
import util.util : stringOfEnum, todo;
import util.writer : Writer;

const struct MangledNames {
	FullIndexMap!(LowVarIndex, size_t) varToNameIndex;
	Map!(ConcreteFun*, size_t) funToNameIndex;
	//TODO:PERF we could use separate FullIndexMap for record, union, etc.
	Map!(ConcreteStruct*, size_t) structToNameIndex;
}

MangledNames buildMangledNames(ref Alloc alloc, return scope const LowProgram program) {
	// First time we see a fun with a name, we'll store the fun-pointer here in case it's not overloaded.
	// After that, we'll start putting them in funToNameIndex, and store the next index here.
	MutMap!(Symbol, PrevOrIndex!ConcreteFun) funNameToIndex;
	// This will not have an entry for non-overloaded funs.
	MapBuilder!(ConcreteFun*, size_t) funToNameIndex;
	// HAX: Ensure "main" has that name.
	setInMap(alloc, funNameToIndex, symbol!"main", PrevOrIndex!ConcreteFun(0));
	foreach (ref LowFun fun; program.allFuns)
		fun.source.matchWithPointers!void(
			(ConcreteFun* cf) {
				cf.source.matchIn!void(
					(in ConcreteFunKey x) {
						//TODO: use temp alloc
						addToPrevOrIndex!ConcreteFun(alloc, funNameToIndex, funToNameIndex, cf, x.decl.name);
					},
					(in ConcreteFunSource.Lambda) {},
					(in ConcreteFunSource.Test) {},
					(in ConcreteFunSource.WrapMain) {});
			},
			(LowFunSource.Generated*) {});

	MutMap!(Symbol, PrevOrIndex!ConcreteStruct) structNameToIndex;
	// This will not have an entry for non-overloaded structs.
	MapBuilder!(ConcreteStruct*, size_t) structToNameIndex;

	void build(ConcreteStruct* s) {
		s.source.match!void(
			(ConcreteStructSource.Bogus) {},
			(ConcreteStructSource.Inst x) {
				addToPrevOrIndex!ConcreteStruct(alloc, structNameToIndex, structToNameIndex, s, x.decl.name);
			},
			(ConcreteStructSource.Lambda) {});
	}
	foreach (ref LowExternType x; program.allExternTypes)
		build(x.source);
	foreach (ref LowFunPointerType x; program.allFunPointerTypes)
		build(x.source);
	foreach (ref LowRecord x; program.allRecords)
		build(x.source);
	foreach (LowUnion x; program.allUnions)
		build(x.source);

	return MangledNames(
		makeVarToNameIndex(alloc, program.vars),
		finishMap(alloc, funToNameIndex),
		finishMap(alloc, structToNameIndex));
}

private immutable(FullIndexMap!(LowVarIndex, size_t)) makeVarToNameIndex(
	ref Alloc alloc,
	in immutable FullIndexMap!(LowVarIndex, LowVar) vars,
) {
	MutMap!(Symbol, size_t) counts;
	return mapFullIndexMap!(LowVarIndex, size_t, LowVar)(alloc, vars, (LowVarIndex _, ref LowVar x) {
		//TODO:PERF use temp alloc
		size_t* index = &getOrAdd!(Symbol, size_t)(alloc, counts, x.name, () => 0);
		size_t res = *index;
		(*index)++;
		if (x.isExtern && res != 0)
			todo!void("'extern' vars can't have same name");
		return res;
	});
}

void writeStructMangledName(scope ref Writer writer, in MangledNames mangledNames, in ConcreteStruct* source) {
	source.source.matchIn!void(
		(in ConcreteStructSource.Bogus) {
			writer ~= "__BOGUS";
		},
		(in ConcreteStructSource.Inst x) {
			writeMangledName(writer, mangledNames, x.decl.name);
			maybeWriteIndexSuffix(writer, mangledNames.structToNameIndex[source]);
		},
		(in ConcreteStructSource.Lambda it) {
			writeConcreteFunMangledName(writer, mangledNames, it.containingFun);
			writer ~= "__lambda";
			writer ~= it.index;
		});
}

void writeLowVarMangledName(
	scope ref Writer writer,
	in MangledNames mangledNames,
	LowVarIndex varIndex,
	in LowVar var,
) {
	if (var.kind != LowVarKind.externGlobal) {
		writer ~= stringOfEnum(var.kind);
		writer ~= '_';
	}
	writeMangledName(writer, mangledNames, var.name);
	size_t index = mangledNames.varToNameIndex[varIndex];
	if (index != 0) {
		writer ~= '_';
		writer ~= index;
	}
}

void writeLowFunMangledName(
	scope ref Writer writer,
	in MangledNames mangledNames,
	LowFunIndex funIndex,
	in LowFun fun,
) {
	fun.source.matchWithPointers!void(
		(ConcreteFun* x) {
			writeConcreteFunMangledName(writer, mangledNames, x);
		},
		(LowFunSource.Generated* x) {
			writeMangledName(writer, mangledNames, x.name);
			if (x.name != symbol!"main") {
				writer ~= '_';
				writer ~= funIndex.index;
			}
		});
}

private void writeConcreteFunMangledName(
	scope ref Writer writer,
	in MangledNames mangledNames,
	in ConcreteFun* source,
) {
	source.source.matchIn!void(
		(in ConcreteFunKey x) {
			if (source.body_.isA!(ConcreteFunBody.Extern))
				writer ~= x.decl.name;
			else {
				writeMangledName(writer, mangledNames, x.decl.name);
				maybeWriteIndexSuffix(writer, mangledNames.funToNameIndex[source]);
			}
		},
		(in ConcreteFunSource.Lambda x) {
			writeConcreteFunMangledName(writer, mangledNames, x.containingFun);
			writer ~= "__lambda";
			writer ~= x.index;
		},
		(in ConcreteFunSource.Test x) {
			writer ~= "__test";
			writer ~= x.testIndex;
		},
		(in ConcreteFunSource.WrapMain x) {
			writer ~= "__wrap_main";
		});
}

private void maybeWriteIndexSuffix(scope ref Writer writer, Opt!size_t index) {
	if (has(index)) {
		writer ~= '_';
		writer ~= force(index);
	}
}

void writeLowLocalName(scope ref Writer writer, in MangledNames mangledNames, in LowLocal a) {
	writer ~= "__local";
	writeMangledName(writer, mangledNames, a.name);
	writer ~= a.index;
}

void writeConstantArrStorageName(
	scope ref Writer writer,
	in MangledNames mangledNames,
	in LowProgram program,
	in LowRecord* arrType,
	size_t index,
) {
	writer ~= "constant";
	writeStructMangledName(writer, mangledNames, arrType.source);
	writer ~= '_';
	writer ~= index;
}

void writeConstantPointerStorageName(
	scope ref Writer writer,
	in MangledNames mangledNames,
	in LowProgram program,
	in LowType pointeeType,
	size_t index,
) {
	writer ~= "constant";
	writeStructMangledName(writer, mangledNames, pointeeType.as!(LowRecord*).source);
	writer ~= '_';
	writer ~= index;
}

private:

immutable struct PrevOrIndex(T) {
	mixin TaggedUnion!(immutable T*, uint);
}

void addToPrevOrIndex(T)(
	ref Alloc alloc,
	ref MutMap!(Symbol, PrevOrIndex!T) nameToIndex,
	ref MapBuilder!(T*, size_t) toNameIndex,
	immutable T* cur,
	Symbol name,
) {
	insertOrUpdate!(Symbol, PrevOrIndex!T)(
		alloc,
		nameToIndex,
		name,
		() =>
			PrevOrIndex!T(cur),
		(in PrevOrIndex!T x) =>
			PrevOrIndex!T(x.matchWithPointers!uint(
				(T* prev) {
					mustAddToMap(alloc, toNameIndex, prev, 0);
					mustAddToMap(alloc, toNameIndex, cur, 1);
					return 2;
				},
				(uint index) {
					mustAddToMap(alloc, toNameIndex, cur, index);
					return index + 1;
				})));
}

public void writeMangledName(scope ref Writer writer, in MangledNames mangledNames, Symbol a) {
	//TODO: this applies to any C function. Maybe crow functions should have a common prefix.
	if (a == symbol!"errno") {
		writer ~= "_crow_errno";
		return;
	}

	if (conflictsWithCName(a))
		writer ~= '_';
	mangleNameCommon(writer, a);
}

// Used for both JS and C
public void mangleNameCommon(Writer)(scope ref Writer writer, in Symbol a) {
	foreach (dchar x; a) {
		if (!isAsciiIdentifierChar(x)) {
			writer ~= "__";
			writer ~= uint(x);
		} else
			writer ~= x;
	}
}

bool conflictsWithCName(Symbol a) {
	switch (a.value) {
		case symbol!"atomic-bool".value: // avoid conflicting with c's "atomic_bool" type
		case symbol!"abs".value: // conflicts with corecrt_math.h on Windows
		case symbol!"break".value:
		case symbol!"continue".value:
		case symbol!"default".value:
		case symbol!"do".value:
		case symbol!"double".value:
		case symbol!"float".value:
		case symbol!"for".value:
		case symbol!"int".value:
		case symbol!"log".value: // defined by tgmath.h
		case symbol!"nan".value: // defined by mathcalls.h
		case symbol!"signed".value:
		case symbol!"unsigned".value:
		case symbol!"void".value:
		case symbol!"while".value:

		// Not core keywords, but common libraries
		case symbol!"remove".value:
		case symbol!"stderr".value:
		case symbol!"stdout".value:
		case symbol!"write".value:
			return true;
		default:
			return false;
	}
}
