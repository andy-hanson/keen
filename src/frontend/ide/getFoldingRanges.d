module frontend.ide.getFoldingRanges;

@safe @nogc pure nothrow:

import frontend.ide.ideUtil : walkAstInOrder;
import frontend.storage : CrowFileInfo;
import lib.lsp.lspTypes : FoldingRange, FoldingRangeKind;
import model.ast : FunDeclAst, ImportsOrExportsAst, SpecDeclAst, StructAliasAst, StructDeclAst, TestAst, VarDeclAst;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.sourceRange : LineAndCharacterGetter, LineAndCharacterRange, Range;

FoldingRange[] foldingRangesOfAst(ref Alloc alloc, in CrowFileInfo file) {
	scope Ctx ctx = Ctx(&alloc, file.content.lineAndCharacterGetter);
	walkAstInOrder!(
		Ctx,
		addRangesForImports,
		addRangesForSpec,
		addRangesForStructAlias,
		addRangesForStructDecl,
		addRangesForFunDecl,
		addRangesForTest,
		addRangesForVarDecl,
	)(file.ast, ctx);
	return finish(alloc, ctx.out_);
}

private:

struct Ctx {
	Alloc* alloc;
	LineAndCharacterGetter lineAndCharacterGetter;
	ArrayBuilder!FoldingRange out_;
}

void addRange(scope ref Ctx ctx, in Range range, FoldingRangeKind kind) {
	LineAndCharacterRange lines = ctx.lineAndCharacterGetter[range];
	if (lines.start.line != lines.end.line) {
		add(*ctx.alloc, ctx.out_, FoldingRange(lines.start.line, lines.end.line, kind));
	}
}

void addRangesForImports(scope ref Ctx ctx, in ImportsOrExportsAst a) {
	addRange(ctx, a.range, FoldingRangeKind.imports);
}

void addRangesForSpec(scope ref Ctx ctx, in SpecDeclAst a) {
	// TODO: docComment -----------------------------------------------------------------------------------------------------------------------
}

void addRangesForStructAlias(scope ref Ctx ctx, in StructAliasAst a) {
	// TODO: docComment -----------------------------------------------------------------------------------------------------------------------
}

void addRangesForStructDecl(scope ref Ctx ctx, in StructDeclAst a) {
	// TODO: docComment -----------------------------------------------------------------------------------------------------------------------
}

void addRangesForFunDecl(scope ref Ctx ctx, in FunDeclAst a) {
	// TODO: docComment -----------------------------------------------------------------------------------------------------------------------
}

void addRangesForTest(scope ref Ctx ctx, in TestAst a) {
	// TODO: docComment -----------------------------------------------------------------------------------------------------------------------
}

void addRangesForVarDecl(scope ref Ctx ctx, in VarDeclAst a) {
	// TODO: docComment -----------------------------------------------------------------------------------------------------------------------
}


