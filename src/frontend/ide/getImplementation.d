module frontend.ide.getImplementation;

@safe @nogc pure nothrow:

import frontend.ide.getDefinition : definitionForTarget;
import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.position : Position, PositionKind;
import model.model : Called, FunInst, Module, Program, StructDecl, VariantAndMethodImpls;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, Opt;
import util.sourceRange : UriAndRange;

UriAndRange[] getImplementationForPosition(ref Alloc alloc, in Program program, in Position pos) {
	Opt!Target optTarget = targetForPosition(program.commonTypes, pos);
	if (has(optTarget)) {
		Target target = force(optTarget);
		return buildArray!UriAndRange(alloc, (scope ref Builder!UriAndRange res) {
			if (target.isA!(PositionKind.VariantMethod))
				getImplementationForVariantMethod(res, program, target.as!(PositionKind.VariantMethod));
			else
				definitionForTarget(pos.module_.uri, target, (in UriAndRange x) { res ~= x; });
		});
	} else
		return [];
}

private:

void getImplementationForVariantMethod(
	scope ref Builder!UriAndRange out_,
	in Program program,
	in PositionKind.VariantMethod method,
) {
	size_t signatureIndex = method.signatureIndex;
	foreach (ref immutable Module* module_; program.allModules) {
		foreach (ref StructDecl struct_; module_.structs) {
			foreach (VariantAndMethodImpls v; struct_.variants) {
				if (v.variant.decl == method.variant) {
					Opt!Called called = v.methodImpls[signatureIndex];
					if (has(called) && force(called).isA!(FunInst*))
						out_ ~= force(called).as!(FunInst*).decl.nameRange;
				}
			}
		}
	}
}
