module test.test;

@safe @nogc nothrow: // not pure

import app.fileSystem : printCb;
import test.testAllInsts : testAllInsts;
import test.testAlloc : testAlloc;
import test.testApplyFn : testApplyFn;
import test.testArrayBuilder : testArrayBuilder;
import test.testFakeExtern : testFakeExtern;
import test.testHashTable : testHashTable;
import test.testIde :
	testCodeLens,
	testCompletion,
	testFoldingRanges,
	testHover,
	testImplementation,
	testInlayHints,
	testReferences,
	testRename,
	testSignatureHelp,
	testTokens;
import test.testIntegralValues : testIntegralValues;
import test.testInterpreter : testInterpreter;
import test.testJson : testJson;
import test.testMap : testMap;
import test.testMemory : testMemory;
import test.testMutMultiMap : testMutMultiMap;
import test.testServer : testServer;
import test.testSortUtil : testSortUtil;
import test.testSourceMap : testSourceMap;
import test.testSourceRange : testSourceRange;
import test.testStack : testStack;
import test.testStackAlloc : testStackAlloc;
import test.testString : testString;
import test.testSymbol : testSymbol;
import test.testSymbolSet : testSymbolSet;
import test.testSyntaxTranslate : testSyntaxTranslate;
import test.testUnicode : testUnicode;
import test.testUri : testUri;
import test.testUtil : Test;
import test.testWriter : testWriter;
import util.alloc.alloc : MetaAlloc;
import util.col.array : find, isEmpty;
import util.exitCode : ExitCode;
import util.opt : force, Opt;
import util.perf : Perf, withNullPerf;
import util.string : CString, stringOfCString, stringsEqual;
import util.util : ptrTrustMe;
import util.writer : Writer;

ExitCode test(MetaAlloc* alloc, in CString[] names) =>
	withNullPerf!(ExitCode, (scope ref Perf perf) {
		Test test = Test(alloc, ptrTrustMe(perf));
		if (isEmpty(names)) {
			foreach (ref NameAndTest x; allTests)
				x.test(test);
		} else {
			foreach (CString name; names) {
				Opt!NameAndTest found = find!NameAndTest(allTests, (in NameAndTest x) =>
					stringsEqual(x.name, stringOfCString(name)));
				force(found).test(test);
			}
		}
		return printCb((scope ref Writer writer) {
			writer ~= "Ran ";
			writer ~= isEmpty(names) ? allTests.length : names.length;
			writer ~= " tests.";
		});
	});

private:

immutable NameAndTest[] allTests = [
	NameAndTest("alloc", &testAlloc),
	NameAndTest("all-insts", &testAllInsts),
	NameAndTest("apply-fn", &testApplyFn),
	NameAndTest("array-builder", &testArrayBuilder),
	NameAndTest("code-lens", &testCodeLens),
	NameAndTest("completion", &testCompletion),
	NameAndTest("fake-extern", &testFakeExtern),
	NameAndTest("folding-ranges", &testFoldingRanges),
	NameAndTest("hash-table", &testHashTable),
	NameAndTest("hover", &testHover),
	NameAndTest("implementation", &testImplementation),
	NameAndTest("inlay-hints", &testInlayHints),
	NameAndTest("integral-values", &testIntegralValues),
	NameAndTest("interpreter", &testInterpreter),
	NameAndTest("json", &testJson),
	NameAndTest("map", &testMap),
	NameAndTest("memory", &testMemory),
	NameAndTest("mut-multi-map", &testMutMultiMap),
	NameAndTest("rename", &testRename),
	NameAndTest("references", &testReferences),
	NameAndTest("server", &testServer),
	NameAndTest("signature-help", &testSignatureHelp),
	NameAndTest("sort-util", &testSortUtil),
	NameAndTest("source-map", &testSourceMap),
	NameAndTest("source-range", &testSourceRange),
	NameAndTest("stack", &testStack),
	NameAndTest("stack-alloc", &testStackAlloc),
	NameAndTest("string", &testString),
	NameAndTest("symbol", &testSymbol),
	NameAndTest("symbol-set", &testSymbolSet),
	NameAndTest("syntax-translate", &testSyntaxTranslate),
	NameAndTest("tokens", &testTokens),
	NameAndTest("unicode", &testUnicode),
	NameAndTest("uri", &testUri),
	NameAndTest("writer", &testWriter),
];

immutable struct NameAndTest {
	string name;
	void function(ref Test) @safe @nogc nothrow test; // not pure
}
