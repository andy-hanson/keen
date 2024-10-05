module test.testHover;

@safe @nogc pure nothrow:

import frontend.ide.getDefinition : getDefinitionForPosition, getTypeDefinitionForPosition;
import frontend.ide.getHover : getHover;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspTypes : Hover;
import model.model : Module, Program;
import test.testUtil : assertEqual, Test, testWithCrowAndJsonFiles, withIdeTest;
import util.alloc.alloc : Alloc;
import util.col.array : arraysEqual, isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.conv : safeToUint;
import util.json : field, Json, jsonList, jsonObject, optionalArrayField;
import util.opt : force, has, Opt, optIf;
import util.uri : Uri;
import util.sourceRange :
	jsonOfLineAndCharacterRange,
	jsonOfUriAndLineAndCharacterRange,
	LineAndCharacterGetter,
	Pos,
	Range,
	UriAndRange;

void testHover(ref Test test) {
	testWithCrowAndJsonFiles!("hover", ["basic", "function"])(test, (Uri uri, in string crow, in Json json) {
		hoverTest(test, uri, crow, json);
	});
}

private:

void hoverTest(ref Test test, Uri uri, in string crow, in Json expected) { // inline ----------------------------------------------------------
	withIdeTest(test, uri, crow, (in ShowModelCtx ctx, in Program program, in Module* module_) {
		assertEqual(hoverResult(test.alloc, crow, ctx, program, module_), expected);
	});
}

struct InfoAtPos {
	@safe @nogc pure nothrow:

	string hover;
	UriAndRange[] definition;
	UriAndRange[] typeDefinition;

	bool isEmpty() scope =>
		.isEmpty(hover) && .isEmpty(definition) && .isEmpty(typeDefinition);

	bool opEquals(in InfoAtPos b) scope =>
		hover == b.hover && arraysEqual(definition, b.definition) && arraysEqual(typeDefinition, b.typeDefinition);
}

Json hoverResult(ref Alloc alloc, in string content, in ShowModelCtx ctx, in Program program, in Module* mainModule) =>
	jsonList(buildArray!Json(alloc, (scope ref Builder!Json res) {
		// We combine ranges that have the same info.
		Pos curRangeStart = 0;
		InfoAtPos curInfo = InfoAtPos("", [], []);

		LineAndCharacterGetter lcg = ctx.lineAndCharacterGetters[mainModule.uri];

		void endRange(Pos end) {
			if (!curInfo.isEmpty)
				res ~= jsonObject(alloc, [
					field!"range"(jsonOfLineAndCharacterRange(alloc, lcg[Range(curRangeStart, end)])),
					field!"hover"(curInfo.hover),
					optionalArrayField!("definition", UriAndRange)(alloc, curInfo.definition, (in UriAndRange x) =>
						jsonOfUriAndLineAndCharacterRange(alloc, ctx.lineAndCharacterGetters[x])),
					optionalArrayField!("type-definition", UriAndRange)(
						alloc, curInfo.typeDefinition, (in UriAndRange x) =>
							jsonOfUriAndLineAndCharacterRange(alloc, ctx.lineAndCharacterGetters[x])),
				]);
		}

		Pos endOfFile = safeToUint(content.length);
		foreach (Pos pos; 0 .. endOfFile + 1) {
			Opt!Position position = getPosition(program, mainModule, content, pos, GetPositionKind.exact);
			Opt!Hover hover = optIf(has(position), () => getHover(alloc, ctx, force(position)));
			InfoAtPos here = InfoAtPos(
				has(hover) ? force(hover).contents.value : "",
				has(position) ? getDefinitionForPosition(alloc, program.commonTypes, force(position)) : [],
				has(position) ? getTypeDefinitionForPosition(alloc, program.commonTypes, force(position)) : []);
			if (here != curInfo) {
				endRange(pos);
				curRangeStart = pos;
				curInfo = here;
			}
		}
		endRange(endOfFile);
	}));
