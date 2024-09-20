module test.testAllInsts;

@safe @nogc pure nothrow:

import frontend.allInsts :
	AllInsts,
	AllInstsArrays,
	AnyDeclOrInst,
	AnyInst,
	freeInstantiationsForModule,
	getOrAddStructInst,
	TEST_getAllInstsArrays,
	TEST_getReferencedBy;
import model.ast : NameAndRange;
import model.model :
	emptyTypeArgs,
	FunInst,
	Linkage,
	LinkageRange,
	Module,
	Purity,
	PurityRange,
	SpecInst,
	StructDecl,
	StructDeclSource,
	StructInst,
	Type,
	Visibility;
import test.testUtil : Test;
import util.alloc.alloc : Alloc, withTempAlloc;
import util.col.array : contains, indexOf, newArray, newSmallArray, small;
import util.col.hashTable : ValueAndDidAdd;
import util.col.mutMultiMap : countKeys, eachValueForKey, MutMultiMap;
import util.memory : allocate;
import util.opt : force, none, Opt;
import util.symbol : Symbol, symbol;
import util.symbolSet : SymbolSet;
import util.uri : mustParseUri, Uri;
import util.util : ptrTrustMe;
import util.writer : debugLogWithWriter, writeNewline, Writer;

void testAllInsts(ref Test test) {
	withTempAlloc!void(test.metaAlloc, (ref Alloc alloc) {
		testFreeInstantiationsForModule(test, alloc);
	});
}

private:

void testFreeInstantiationsForModule(ref Test test, ref Alloc alloc) {
	AllInsts insts = AllInsts(ptrTrustMe(alloc));

	/*
	a.crow:
		a0 record
		a1[t] record
		and something using `a0 a1`
	*/
	Uri uriA = mustParseUri("test://a.crow");
	Module moduleA = makeModule(alloc, uriA, [
		dummyStruct(test.alloc, uriA, symbol!"a0", 0),
		dummyStruct(alloc, uriA, symbol!"a1", 1)]);
	StructDecl* a0 = &moduleA.structs[0];
	StructDecl* a1 = &moduleA.structs[1];
	StructInst* a0Inst = mustDidAdd(getStruct(insts, a0, []));
	assert(mustNotDidAdd(getStruct(insts, a0, emptyTypeArgs)) == a0Inst);
	assertReferencedBy(test, insts, [
		referenced(alloc, a0, [AnyInst(a0Inst)]),
	]);

	StructInst* a1OfA0 = mustDidAdd(getStruct(insts, a1, [Type(a0Inst)]));
	assert(a1OfA0 != a0Inst);
	assert(mustNotDidAdd(getStruct(insts, a1, [Type(a0Inst)])) == a1OfA0);
	assertReferencedBy(test, insts, [
		referenced(alloc, a0, [AnyInst(a0Inst)]),
		referenced(alloc, a1, [AnyInst(a1OfA0)]),
		referenced(alloc, a0Inst, [AnyInst(a1OfA0)]),
	]);

	/*
	b.crow:
		b0 record
		b1[t] record
		and something using `b0 b1`
	*/
	Uri uriB = mustParseUri("test://b.crow");
	Module moduleB = makeModule(alloc, uriB, [
		dummyStruct(alloc, uriB, symbol!"b0", 0),
		dummyStruct(alloc, uriB, symbol!"b1", 1)]);
	StructDecl* b0 = &moduleB.structs[0];
	StructDecl* b1 = &moduleB.structs[1];
	StructInst* b0Inst = mustDidAdd(getStruct(insts, b0, []));
	StructInst* b1OfB0 = mustDidAdd(getStruct(insts, b1, [Type(b0Inst)]));

	// A third module uses `a0 b1`
	StructInst* b1OfA0 = mustDidAdd(getStruct(insts, b1, [Type(a0Inst)]));

	assertReferencedBy(test, insts, [
		referenced(alloc, a0, [AnyInst(a0Inst)]),
		referenced(alloc, a1, [AnyInst(a1OfA0)]),
		referenced(alloc, a0Inst, [AnyInst(a1OfA0), AnyInst(b1OfA0)]),
		referenced(alloc, b0, [AnyInst(b0Inst)]),
		referenced(alloc, b1, [AnyInst(b1OfB0), AnyInst(b1OfA0)]),
		referenced(alloc, b0Inst, [AnyInst(b1OfB0)]),
	]);

	scope immutable StructInst*[] allStructs0 = [a0Inst, a1OfA0, b0Inst, b1OfA0, b1OfB0];
	assertAllInsts(alloc, insts, AllInstsArrays(allStructs0, [], []));

	freeInstantiationsForModule(insts, moduleA);

	scope immutable StructInst*[] allStructs1 = [b0Inst, b1OfB0];
	assertAllInsts(alloc, insts, AllInstsArrays(allStructs1, [], []));

	assertReferencedBy(test, insts, [
		referenced(alloc, b0, [AnyInst(b0Inst)]),
		referenced(alloc, b1, [AnyInst(b1OfB0)]),
		referenced(alloc, b0Inst, [AnyInst(b1OfB0)]),
	]);

	freeInstantiationsForModule(insts, moduleB);
	assertAllInsts(alloc, insts, AllInstsArrays([], [], []));
	assertReferencedBy(test, insts, []);
}

void assertAllInsts(ref Alloc alloc, in AllInsts insts, in AllInstsArrays expected) {
	AllInstsArrays actual = TEST_getAllInstsArrays(alloc, insts);
	assertEqualIgnoreOrder(actual.structs, expected.structs);
	assertEqualIgnoreOrder(actual.specs, expected.specs);
	assertEqualIgnoreOrder(actual.funs, expected.funs);
}

void assertEqualIgnoreOrder(T)(in T[] actual, in T[] expected) {
	assert(actual.length == expected.length);
	foreach (size_t i, T x; actual) {
		Opt!size_t index = indexOf(actual, x);
		assert(force(index) == i); // no duplicates
		assert(contains(expected, x));
	}
}

void assertReferencedBy(in Test test, in AllInsts insts, in ExpectedReferences[] expected) {
	scope const MutMultiMap!(AnyDeclOrInst, AnyInst) actual = TEST_getReferencedBy(insts);
	assert(actual.countKeys == expected.length);
	foreach (ExpectedReferences expectedRefs; expected) {
		if (false) {
			debugLogWithWriter((scope ref Writer writer) {
				writer ~= "actual values:";
				eachValueForKey!(AnyDeclOrInst, AnyInst)(actual, expectedRefs.referenced, (AnyInst x) {
					writeNewline(writer, 1);
					writeAnyInst(writer, x);
				});
				writeNewline(writer, 0);
				writer ~= "expected values:";
				foreach (AnyInst x; expectedRefs.referencers) {
					writeNewline(writer, 1);
					writeAnyInst(writer, x);
				}
			});
		}
		size_t i = 0;
		eachValueForKey!(AnyDeclOrInst, AnyInst)(actual, expectedRefs.referenced, (AnyInst x) {
			assert(x == expectedRefs.referencers[i]);
			i++;
		});
		assert(i == expectedRefs.referencers.length);
	}
}


void writeAnyInst(scope ref Writer writer, in AnyInst inst) {
	writer ~= inst.matchIn!Symbol(
		(in StructInst x) => x.decl.name,
		(in SpecInst x) => x.decl.name,
		(in FunInst x) => x.decl.name);
}

struct ExpectedReferences {
	AnyDeclOrInst referenced;
	AnyInst[] referencers;
}
ExpectedReferences referenced(ref Alloc alloc, return scope AnyDeclOrInst a, in AnyInst[] b) =>
	ExpectedReferences(a, newArray(alloc, b));

ValueAndDidAdd!(StructInst*) getStruct(ref AllInsts a, StructDecl* decl, in Type[] typeArgs) =>
	getOrAddStructInst(
		a, decl, small!Type(typeArgs),
		() => LinkageRange(Linkage.internal, Linkage.internal),
		() => PurityRange(Purity.data, Purity.data));

T mustDidAdd(T)(ValueAndDidAdd!T a) {
	assert(a.didAdd);
	return a.value;
}

T mustNotDidAdd(T)(ValueAndDidAdd!T a) {
	assert(!a.didAdd);
	return a.value;
}

Module makeModule(ref Alloc alloc, Uri uri, in StructDecl[] structs) =>
	Module(uri, structs: newSmallArray(alloc, structs));

StructDecl dummyStruct(ref Alloc alloc, Uri uri, Symbol name, size_t nTypeParams) =>
	StructDecl(
		StructDeclSource(allocate(alloc, StructDeclSource.Bogus(
			name,
			small!NameAndRange(typeParams[0 .. nTypeParams])))),
		uri,
		Visibility.public_,
		none!SymbolSet,
		Purity.data,
		false);

NameAndRange[2] typeParams = [NameAndRange(0, symbol!"a"), NameAndRange(0, symbol!"b")];
