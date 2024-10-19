module test.testRename;

@safe @nogc pure nothrow:

import frontend.ide.getPosition : getPosition, GetPositionKind;
import frontend.ide.getRename : getRenameForPosition;
import frontend.ide.position : Position;
import frontend.showModel : ShowModelCtx;
import lib.lsp.lspToJson : jsonOfWorkspaceEdit;
import lib.lsp.lspTypes : TextDocumentPositionParams, WorkspaceEdit;
import model.model : Program;
import test.testUtil : Test, withIdeTestsAtPositions;
import util.json : jsonNull;
import util.opt : force, has, none, Opt;

void testRename(ref Test test) {
	withIdeTestsAtPositions!("rename", ["a", "b"])(test, (in ShowModelCtx ctx, in Program program, in TextDocumentPositionParams where) {
		Opt!Position position = getPosition(program, ctx, where, GetPositionKind.exact);
		Opt!WorkspaceEdit rename = has(position)
			? getRenameForPosition(test.alloc, program, force(position), "new-name")
			: none!WorkspaceEdit;
		return has(rename) ? jsonOfWorkspaceEdit(test.alloc, ctx.lineAndCharacterGetters, force(rename)) : jsonNull;
	});
}
