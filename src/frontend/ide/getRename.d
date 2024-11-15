module frontend.ide.getRename;

@safe @nogc pure nothrow:

import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.position : Position;
import frontend.ide.getReferences : eachReferenceForTarget, IncludeImports;
import lib.lsp.lspTypes : TextEdit, WorkspaceEdit;
import model.model : Program;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : add, buildGroupedAndSorted, GroupedSortedBuilder;
import util.comparison : Comparison;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : compareLineAndCharacterRange, UriAndLineAndCharacterRange, UriAndRange;
import util.string : copyString;
import util.uri : compareUriNaturally, Uri;

Opt!WorkspaceEdit getRenameForPosition(ref Alloc alloc, in Program program, in Position pos, in string newName) {
	Opt!Target target = targetForPosition(pos);
	return has(target)
		? some(WorkspaceEdit(buildGroupedAndSorted!(Uri, TextEdit, compareUriNaturally, compareTextEdit)(
			alloc,
			(scope ref GroupedSortedBuilder!(Uri, TextEdit) out_) {
				string newNameOut = copyString(alloc, newName);
				eachReferenceForTarget(
					program, pos.module_.uri, force(target), IncludeImports.include,
					(in UriAndRange x) {
						UriAndLineAndCharacterRange range = program.lineAndCharacterGetters[x];
						out_.add(range.uri, TextEdit(range.range, newNameOut));
					});
			})))
		: none!WorkspaceEdit;
}

private:

Comparison compareTextEdit(in TextEdit a, in TextEdit b) =>
	compareLineAndCharacterRange(a.range, b.range);
