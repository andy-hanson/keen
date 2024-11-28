module test.testSourceMap;

@safe @nogc pure nothrow:

import backend.js.sourceMap : finish, ModulePaths, SingleSourceMapping, Source, SourceMapBuilder, writeBase64VLQ;
import frontend.lang : FileType, fileType;
import frontend.storage : fileContentGetters, setFileAssumeUtf8, Storage;
import model.sourceRange : LineAndCharacter;
import test.testUtil : assertEqual, Test;
import util.col.map : KeyValuePair, newMap;
import util.symbol : symbol;
import util.uri : mustParseUri, parsePath, Path, Uri;
import util.writer : withStackWriter, Writer;

void testSourceMap(ref Test test) {
	testBase64VLQ();
	testBuilder(test);
}

private:

void testBase64VLQ() {
	void test(int value, string expected) {
		withStackWriter!0x10000(
			(scope ref Writer writer) {
				writeBase64VLQ(writer, value);
			},
			(in string actual) {
				assertEqual(actual, expected);
			});
	}

	test(0, "A");
	test(1, "C");
	test(-1, "D");
	test(2, "E");
	test(-2, "F");
	test(15, "e");
	test(-15, "f");
	test(16, "gB");
	test(-16, "hB");
	test(17, "iB");
	test(-17, "jB");
	test(511, "+f");
	test(-511, "/f");
	test(512, "ggB");
	test(513, "igB");
}

void testBuilder(ref Test test) {
	SourceMapBuilder map = SourceMapBuilder(Writer(test.allocPtr));
	Uri a_crow = mustParseUri("file://foo/a.crow");
	assert(fileType(a_crow) == FileType.crow);

	map ~= SingleSourceMapping(
		Source(a_crow, symbol!"foo", LineAndCharacter(1, 1)),
		LineAndCharacter(1, 1));
	map ~= SingleSourceMapping(
		Source(a_crow, symbol!"foo", LineAndCharacter(2, 1)),
		LineAndCharacter(2, 1));

	Storage storage = Storage(test.metaAlloc);
	setFileAssumeUtf8(test.perf, storage, a_crow, "hello");
	ModulePaths modulePaths = ModulePaths(newMap(test.alloc, [
		KeyValuePair!(Uri, Path)(a_crow, parsePath("mapped/a.crow"))]));
	assertEqual(
		finish(map, fileContentGetters(test.alloc, storage), modulePaths),
		q"({"version":3,"sources":["mapped/a.crow"],"sourcesContent":["hello"],"names":["foo"],)" ~
		q"("mappings":";CACCA;CACAA"})");
}
