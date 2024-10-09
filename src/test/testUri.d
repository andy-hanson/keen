module test.testUri;

@safe @nogc pure nothrow:

import test.testUtil : assertEqual, Test;
import util.col.array : zip;
import util.comparison : Comparison;
import util.opt : force, has, none, Opt, optEqual;
import util.symbol : Extension, Symbol, symbol, symbolOfString;
import util.uri :
	alterExtension,
	alterExtensionWithHex,
	asFilePath,
	baseName,
	compareUriAlphabetically,
	FilePath,
	getExtension,
	isAncestor,
	isWindowsPath,
	mustParseUri,
	parent,
	parseFilePath,
	parsePath,
	parseUriWithCwd,
	Path,
	relativePath,
	relativePathForUri,
	RelPath,
	stringOfFilePath,
	stringOfUri,
	toUri,
	Uri,
	uriIsFile,
	withComponents;
import util.util : stringOfEnum;
import util.writer : Writer;

void testUri(ref Test test) {
	testBasic(test);
	testFile(test);
	testRelativePath(test);
}

private:

void testBasic(ref Test test) {
	Uri a = mustParseUri("file:///a");
	verifyUri(test, a, ["file://", "a"]);
	Uri b = mustParseUri("file:///b");
	verifyUri(test, b, ["file://", "b"]);
	assert(compareUriAlphabetically(a, a) == Comparison.equal);
	assert(compareUriAlphabetically(a, b) == Comparison.less);

	assertEqual(stringOfUri(test.alloc, a), "file:///a");

	Uri aX = a / symbol!"x";
	verifyUri(test, aX, ["file://", "a", "x"]);
	assert(a / symbol!"x" == aX);
	Uri aY = a / symbol!"y";
	verifyUri(test, aY, ["file://", "a", "y"]);
	assert(aX != aY);
	assertEqual(stringOfUri(test.alloc, aX), "file:///a/x");
	assertEqual(stringOfUri(test.alloc, aY), "file:///a/y");

	Uri zW = parseUriWithCwd(aX, "/z/w.crow");
	verifyUri(test, zW, ["file://", "z", "w.crow"]);
	assertEqual(baseName(zW), symbolOfString("w.crow"));
	assertEqual(stringOfUri(test.alloc, zW), "file:///z/w.crow");
	assertEqual(getExtension(zW), Extension.crow);
	Uri aXZW = parseUriWithCwd(aX, "./z/w");
	assertEqual(stringOfUri(test.alloc, aXZW), "file:///a/x/z/w");
	assertEqual(aXZW, parseUriWithCwd(aX, "z/w"));
	assertEqual(aY, parseUriWithCwd(aX, "../y"));

	Uri crowLang = mustParseUri("http://crow-lang.org");
	assertEqual(parseUriWithCwd(aX, "http://crow-lang.org"), crowLang);

	assertEqual(test, parent(crowLang), none!Uri);
	assertEqual(getExtension(crowLang), Extension.none);
}

void assertEqual(ref Test test, Opt!Uri a, Opt!Uri b) {
	if (!optEqual!Uri(a, b)) {
		assertEqual(stringOfOptUri(test, a), stringOfOptUri(test, b));
		assert(false);
	}
}
string stringOfOptUri(ref Test test, Opt!Uri a) =>
	has(a) ? stringOfUri(test.alloc, force(a)) : "<<none>>";

void assertEqual(Extension a, Extension b) {
	assertEqual(a, b, (scope ref Writer writer, in Extension x) {
		writer ~= stringOfEnum(x);
	});
}

void testFile(ref Test test) {
	verifyFile(test, "file:///home/crow/a.txt", "/home/crow/a.txt", ["home", "crow", "a.txt"]);
	verifyFile(
		test,
		"file:///C%3A/Users/User/a.txt", "file:///c%3a/users/user/a.txt",
		"C:\\Users\\User\\a.txt", "c:/users/user/a.txt",
		["c:", "users", "user", "a.txt"]);

	Uri aUri = mustParseUri("file:///C%3A/Users/User/a");
	assert(isWindowsPath(aUri));
	Uri booUri = aUri / symbol!"BOO";
	assert(stringOfUri(test.alloc, booUri) == "file:///c%3a/users/user/a/boo");
	assert(isWindowsPath(booUri));

	FilePath a = parseFilePath("C:\\Users\\User\\a");
	assert(a == parseFilePath("c:/users/user/a"));
	assert(isWindowsPath(a));
	FilePath boo = a / symbol!"BOO";
	assert(stringOfFilePath(test.alloc, boo) == "c:/users/user/a/boo");
	assert(isWindowsPath(boo));

	FilePath aTxt = parseFilePath("/foo/a.txt");

	FilePath aF00dJson = alterExtensionWithHex(aTxt, [0xf0, 0x0d], Extension.json);
	assert(stringOfFilePath(test.alloc, aF00dJson) == "/foo/a.f00d.json");

	FilePath aF00dCrow = alterExtension(aF00dJson, Extension.crow);
	assert(stringOfFilePath(test.alloc, aF00dCrow) == "/foo/a.f00d.crow");
}

void verifyFile(scope ref Test test, in string asUriString, in string asFilePathString, in string[] components) {
	verifyFile(test, asUriString, asUriString, asFilePathString, asFilePathString, components);
}

@trusted void verifyFile(
	scope ref Test test,
	in string uriIn,
	in string uriOut,
	in string filePathIn,
	in string filePathOut,
	in string[] components,
) {
	Uri uri = mustParseUri(uriIn);
	FilePath filePath = parseFilePath(filePathIn);

	assert(uriIsFile(uri));
	assertEqual(asFilePath(uri), filePath);
	assertEqual(toUri(filePath), uri);

	verifyPath(test, filePath.path, components);

	assertEqual(stringOfUri(test.alloc, uri), uriOut);
	assertEqual(stringOfFilePath(test.alloc, filePath), filePathOut);
}

void verifyUri(ref Test test, Uri a, in string[] expectedParts) {
	verifyPath(test, a.pathIncludingScheme, expectedParts);
}

void verifyPath(ref Test test, Path a, in string[] expectedComponents) {
	withComponents(a, (in Symbol[] actual) {
		assert(actual.length == expectedComponents.length);
		zip(actual, expectedComponents, (ref Symbol actualComponent, ref const string expectedComponent) {
			assertEqual(actualComponent, symbolOfString(expectedComponent));
		});
	});
}

void testRelativePath(ref Test test) {
	assert(isAncestor(parsePath("a"), parsePath("a/c")));
	assertEqual(relativePath(parsePath("a/b"), parsePath("a/c")), RelPath(0, parsePath("c")));
	assertEqual(relativePath(parsePath("a/b"), parsePath("c/d")), RelPath(1, parsePath("c/d")));

	Uri a = mustParseUri("http://foo.com/x/y");
	Uri b = mustParseUri("http://foo.com/x/z");
	assertEqual(force(relativePathForUri(a, b)), RelPath(0, parsePath("z")));
	assert(!has(relativePathForUri(a, mustParseUri("https://foo.com/x/z"))));
}
