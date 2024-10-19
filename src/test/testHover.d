module test.testHover;

@safe @nogc pure nothrow:

import frontend.ide.getDefinition : getDefinitionForPosition, getTypeDefinitionForPosition;
import frontend.ide.getHover : getHover;
import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspTypes : Hover, TextDocumentIdentifier, TextDocumentPositionParams;
import model.model : Program;
import test.testUtil : ideTestWithCrowAndJsonFiles, Test;
import util.alloc.alloc : Alloc;
import util.col.array : arraysEqual, isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.json : field, Json, jsonList, jsonObject, optionalArrayField;
import util.opt : force, has, Opt, optIf;
import util.sourceRange :
	endOfFile,
	jsonOfLineAndCharacterRange,
	jsonOfUriAndLineAndCharacterRange,
	LineAndCharacterGetter,
	Pos,
	PosKind,
	Range,
	UriAndRange;
import util.uri : Uri;

void testHover(ref Test test) {
	ideTestWithCrowAndJsonFiles!("hover", ["basic", "function"])(test, (in ShowModelCtx ctx, in Program program, Uri uri) =>
		hoverResult(test.alloc, ctx, program, uri));
}

private:

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

Json hoverResult(ref Alloc alloc, in ShowModelCtx ctx, in Program program, Uri uri) =>
	jsonList(buildArray!Json(alloc, (scope ref Builder!Json res) {
		// Combine ranges that have the same info
		Pos curRangeStart = 0;
		InfoAtPos curInfo = InfoAtPos("", [], []);
		LineAndCharacterGetter lcg = ctx.lineAndCharacterGetters[uri];

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

		foreach (Pos pos; 0 .. endOfFile(lcg) + 1) {
			Opt!Position position = getPosition(program, ctx, TextDocumentPositionParams(TextDocumentIdentifier(uri), lcg[pos, PosKind.startOfRange]), GetPositionKind.exact);
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
		endRange(endOfFile(lcg));
	}));
