module frontend.ide.getFoldingRanges;

@safe @nogc pure nothrow:

import frontend.ide.ideUtil : walkAstInOrder;
import frontend.storage : CrowFileInfo;
import lib.lsp.lspTypes : FoldingRange, FoldingRangeKind;
import model.ast :
	DocCommentAst, FunDeclAst, ImportsOrExportsAst, SpecDeclAst, StructAliasAst, StructDeclAst, TestAst, VarDeclAst;
import model.sourceRange : LineAndCharacterGetter, LineAndCharacterRange, Range;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : add, ArrayBuilder, finish;
import util.conv : safeToUint;
import util.opt : force, has, MutOpt, none, noneMut, Opt, some, someMut;

FoldingRange[] foldingRangesOfAst(ref Alloc alloc, in CrowFileInfo file) {
	scope Ctx ctx = Ctx(&alloc, file.content.lineAndCharacterGetter);
	addRangesForRegions(ctx, file.ast.regions);
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

void addRange(scope ref Ctx ctx, in Range range, Opt!FoldingRangeKind kind) {
	LineAndCharacterRange lines = ctx.lineAndCharacterGetter[range];
	if (lines.start.line != lines.end.line)
		add(*ctx.alloc, ctx.out_, FoldingRange(lines.start.line, lines.end.line, kind));
}
void addRangeForRegion(scope ref Ctx ctx, uint startLine, uint endLine) {
	assert(startLine <= endLine);
	if (startLine != endLine)
		add(*ctx.alloc, ctx.out_, FoldingRange(startLine, endLine, some(FoldingRangeKind.region)));
}
void addRangeForDecl(scope ref Ctx ctx, in Range range) {
	addRange(ctx, range, none!FoldingRangeKind);
}
void addRangeForDocComment(scope ref Ctx ctx, in DocCommentAst ast) {
	if (!ast.isEmpty)
		addRange(ctx, force(ast.range), some(FoldingRangeKind.comment));
}

void addRangesForRegions(scope ref Ctx ctx, in Range[] regions) {
	MutOpt!uint prevLine = noneMut!uint;
	foreach (Range region; regions) {
		uint line = ctx.lineAndCharacterGetter[region].start.line;
		if (has(prevLine))
			addRangeForRegion(ctx, force(prevLine), line - 1);
		prevLine = someMut(line);
	}
	if (has(prevLine))
		addRangeForRegion(ctx, force(prevLine), safeToUint(ctx.lineAndCharacterGetter.lastLine));
}

void addRangesForImports(scope ref Ctx ctx, in ImportsOrExportsAst a) {
	addRange(ctx, a.range, some(FoldingRangeKind.imports));
}

void addRangesForSpec(scope ref Ctx ctx, in SpecDeclAst a) {
	addRangeForDocComment(ctx, a.docComment);
	addRangeForDecl(ctx, a.range);
}

void addRangesForStructAlias(scope ref Ctx ctx, in StructAliasAst a) {
	addRangeForDocComment(ctx, a.docComment);
	addRangeForDecl(ctx, a.range);
}

void addRangesForStructDecl(scope ref Ctx ctx, in StructDeclAst a) {
	addRangeForDocComment(ctx, a.docComment);
	addRangeForDecl(ctx, a.range);
}

void addRangesForFunDecl(scope ref Ctx ctx, in FunDeclAst a) {
	addRangeForDocComment(ctx, a.docComment);
	addRangeForDecl(ctx, a.range);
}

void addRangesForTest(scope ref Ctx ctx, in TestAst a) {
	addRangeForDocComment(ctx, a.docComment);
	addRangeForDecl(ctx, a.range);
}

void addRangesForVarDecl(scope ref Ctx ctx, in VarDeclAst a) {
	addRangeForDocComment(ctx, a.docComment);
	addRangeForDecl(ctx, a.range);
}


