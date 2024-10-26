module frontend.ide.getImplementation;

@safe @nogc pure nothrow:

import frontend.ide.getDefinition : definitionForTarget;
import frontend.ide.getTarget : Target, targetForPosition;
import frontend.ide.ideUtil : ReferenceCb;
import frontend.ide.position : Position;
import model.model : Called, FunInst, Module, Program, Signature, signatureIndex, StructDecl, VariantAndMethodImpls;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : buildArray, Builder;
import util.opt : force, has, Opt;
import util.sourceRange : UriAndLineAndCharacterRange, UriAndRange;
import util.uri : Uri;

UriAndLineAndCharacterRange[] getImplementationForPosition(ref Alloc alloc, in Program program, in Position pos) =>
	buildArray!UriAndLineAndCharacterRange(alloc, (scope ref Builder!UriAndLineAndCharacterRange res) {
		Opt!Target optTarget = targetForPosition(program.commonTypes, pos);
		if (has(optTarget))
			implementationForTarget(program, pos.module_.uri, force(optTarget), (in UriAndRange x) {
				res ~= program.lineAndCharacterGetters[x];
			});
	});

private:

void implementationForTarget(in Program program, Uri uri, in Target target, in ReferenceCb cb) {
	if (target.isA!(Signature*) && target.as!(Signature*).container.isA!(StructDecl*))
		implementationForVariantMethod(program, target.as!(Signature*).container.as!(StructDecl*), target.as!(Signature*), cb);
	else
		definitionForTarget(uri, target, cb);
}

void implementationForVariantMethod(in Program program, in StructDecl* variant, in Signature* method, in ReferenceCb cb) {
	size_t sigIndex = signatureIndex(method);
	foreach (ref immutable Module* module_; program.allModules) {
		foreach (ref StructDecl struct_; module_.structs) {
			foreach (VariantAndMethodImpls v; struct_.variants) {
				if (v.variant.decl == variant) {
					Opt!Called called = v.methodImpls[sigIndex];
					if (has(called) && force(called).isA!(FunInst*))
						cb(force(called).as!(FunInst*).decl.nameRange);
				}
			}
		}
	}
}
