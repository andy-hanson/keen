module frontend.ide.getRename;

@safe @nogc pure nothrow:

import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.position : Position;
import frontend.ide.getReferences : eachReferenceForTarget, IncludeImports;
import lib.lsp.lspTypes : TextEdit, WorkspaceEdit;
import model.model : Program;
import util.alloc.alloc : Alloc;
import util.col.multiMap : makeMultiMap, MultiMapCb;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : UriAndRange;
import util.string : copyString;
import util.uri : Uri;

Opt!WorkspaceEdit getRenameForPosition(ref Alloc alloc, in Program program, in Position pos, in string newName) {
	Opt!Target target = targetForPosition(program.commonTypes, pos.kind);
	return has(target)
		? some(WorkspaceEdit(makeMultiMap!(Uri, TextEdit)(alloc, (in MultiMapCb!(Uri, TextEdit) cb) {
			string newNameOut = copyString(alloc, newName);
			eachReferenceForTarget(program, pos.module_.uri, force(target), IncludeImports.include, (in UriAndRange x) {
				cb(x.uri, TextEdit(x.range, newNameOut));
			});
		})))
		: none!WorkspaceEdit;
}
