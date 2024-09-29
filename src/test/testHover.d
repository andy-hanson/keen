module test.testHover;

@safe @nogc pure nothrow:

import frontend.ide.getDefinition : getDefinitionForPosition;
import frontend.ide.getHover : getHover;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspTypes : Hover;
import lib.server : getProgramForAll, getShowDiagCtx, Server;
import model.model : Module, Program;
import test.testUtil : setupTestServer, Test, withTestServer;
import util.alloc.alloc : Alloc;
import util.col.array : arraysEqual, filter, isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.col.hashTable : mustGet;
import util.conv : safeToUint;
import util.json : field, Json, jsonList, jsonObject, jsonToStringPretty, optionalArrayField;
import util.opt : force, has, Opt, optIf;
import util.uri : mustParseUri, Uri;
import util.sourceRange :
	jsonOfLineAndCharacterRange,
	jsonOfUriAndLineAndCharacterRange,
	LineAndCharacterGetter,
	LineAndColumnGetter,
	Pos,
	Range,
	UriAndRange;
import util.writer : debugLogWithWriter, Writer;

@trusted void testHover(ref Test test) {
	hoverTest!("basic.crow", "hover/basic.json")(test);
	hoverTest!("function.crow", "hover/function.json")(test);
}

private:

void hoverTest(string crowFileName, string outputFileName)(ref Test test) {
	string content = import("hover/" ~ crowFileName);
	immutable string expected = removeCarriageReturn(test.alloc, import(outputFileName));
	withHoverTest!crowFileName(test, content, (in ShowModelCtx ctx, in Program program, in Module* module_) {
		string actual = jsonToStringPretty(test.alloc, hoverResult(test.alloc, content, ctx, program, module_));
		if (actual != expected) {
			debugLogWithWriter((scope ref Writer writer) {
				writer ~= "Test output for ";
				writer ~= outputFileName;
				writer ~= " is different than expected. Actual is:\n";
				writer ~= actual;
			});
			assert(false);
		}
	});
}

string removeCarriageReturn(ref Alloc alloc, string a) {
	version (Windows)
		return filter!(immutable char)(alloc, a, (in immutable char x) => x != '\r');
	else
		return a;
}

void withHoverTest(string fileName)(
	ref Test test,
	in string content,
	in void delegate(in ShowModelCtx, in Program, in Module*) @safe @nogc pure nothrow cb,
) {
	withTestServer(test, (ref Alloc alloc, ref Server server) {
		Uri uri = mustParseUri("magic:/" ~ fileName);
		setupTestServer(test, alloc, server, uri, content);
		Program program = getProgramForAll(test.perf, alloc, server);
		cb(getShowDiagCtx(server, program), program, mustGet(program.allModules, uri));
	});
}

struct InfoAtPos {
	@safe @nogc pure nothrow:

	string hover;
	UriAndRange[] definition;

	bool isEmpty() scope =>
		.isEmpty(hover) && .isEmpty(definition);

	bool opEquals(in InfoAtPos b) scope =>
		hover == b.hover && arraysEqual(definition, b.definition);
}

Json hoverResult(ref Alloc alloc, in string content, in ShowModelCtx ctx, in Program program, in Module* mainModule) =>
	jsonList(buildArray!Json(alloc, (scope ref Builder!Json res) {
		// We combine ranges that have the same info.
		Pos curRangeStart = 0;
		InfoAtPos curInfo = InfoAtPos("", []);

		LineAndCharacterGetter lcg = ctx.lineAndCharacterGetters[mainModule.uri];

		void endRange(Pos end) {
			if (!curInfo.isEmpty)
				res ~= jsonObject(alloc, [
					field!"range"(jsonOfLineAndCharacterRange(alloc, lcg[Range(curRangeStart, end)])),
					field!"hover"(curInfo.hover),
					optionalArrayField!("definition", UriAndRange)(alloc, curInfo.definition, (in UriAndRange x) =>
						jsonOfUriAndLineAndCharacterRange(alloc, ctx.lineAndCharacterGetters[x])),
				]);
		}

		Pos endOfFile = safeToUint(content.length);
		foreach (Pos pos; 0 .. endOfFile + 1) {
			Opt!Position position = getPosition(program, mainModule, pos, GetPositionKind.target);
			Opt!Hover hover = optIf(has(position), () => getHover(alloc, ctx, force(position)));
			InfoAtPos here = InfoAtPos(
				has(hover) ? force(hover).contents.value : "",
				has(position) ? getDefinitionForPosition(alloc, program.commonTypes, force(position)) : []);
			if (here != curInfo) {
				endRange(pos);
				curRangeStart = pos;
				curInfo = here;
			}
		}
		endRange(endOfFile);
	}));
