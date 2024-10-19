module frontend.ide.getRename;

@safe @nogc pure nothrow:

import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.position : Position;
import frontend.ide.getReferences : eachReferenceForTarget, IncludeImports;
import lib.lsp.lspTypes : TextEdit, WorkspaceEdit;
import model.model : Program;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : add, ArrayBuilder, arrayBuilderSort, Builder, buildSortedArray, finish;
import util.col.map : KeyValuePair;
import util.col.mutMap : getOrAdd, MutMap;
import util.comparison : Comparison;
import util.opt : force, has, none, Opt, some;
import util.sourceRange : compareRange, UriAndRange;
import util.string : copyString;
import util.uri : compareUriNaturally, Uri;

Opt!WorkspaceEdit getRenameForPosition(ref Alloc alloc, in Program program, in Position pos, in string newName) {
	Opt!Target target = targetForPosition(program.commonTypes, pos);
	return has(target)
		? some(WorkspaceEdit(buildGroupedAndSorted!(Uri, TextEdit, compareUriNaturally, compareTextEdit)(
			alloc,
			(scope ref GroupedSortedBuilder!(Uri, TextEdit) out_) {
				string newNameOut = copyString(alloc, newName);
				eachReferenceForTarget(program, pos.module_.uri, force(target), IncludeImports.include, (in UriAndRange x) {
					out_.add(x.uri, TextEdit(x.range, newNameOut));
				});
			})))
		: none!WorkspaceEdit;
}

private:

Comparison compareTextEdit(in TextEdit a, in TextEdit b) =>
	compareRange(a.range, b.range);

// TOOD: MOVE -------------------------------------------------------------------------------------------------------------------------
immutable(KeyValuePair!(Key, Value[]))[] buildGroupedAndSorted(Key, Value, alias compareKey, alias compareValue)(
	ref Alloc alloc,
	in void delegate(scope ref GroupedSortedBuilder!(Key, Value)) @safe @nogc pure nothrow cb,
) {
	GroupedSortedBuilder!(Key, Value) builder = GroupedSortedBuilder!(Key, Value)(&alloc);
	cb(builder);
	return buildSortedArray!(immutable(KeyValuePair!(Key, Value[])), compareByKey!(compareKey, Key, Value[]))(
		alloc,
		(scope ref Builder!(immutable(KeyValuePair!(Key, Value[]))) out_) {
			foreach (Key key, ref ArrayBuilder!Value values; builder.map) {
				arrayBuilderSort!(Value, compareValue)(values);
				out_ ~= immutable KeyValuePair!(Key, Value[])(key, finish(alloc, values));
			}
		});
}

Comparison compareByKey(alias compareKey, Key, Value)(in KeyValuePair!(Key, Value) a, in KeyValuePair!(Key, Value) b) =>
	compareKey(a.key, b.key);

struct GroupedSortedBuilder(Key, Value) {
	Alloc* allocPtr;
	MutMap!(Key, ArrayBuilder!Value) map;

	void add(Key key, Value value) {
		.add(*allocPtr, getOrAdd(*allocPtr, map, key, () => ArrayBuilder!Value()), value);
	}
}
