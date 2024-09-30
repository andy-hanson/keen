module frontend.ide.getCompletion;

@safe @nogc pure nothrow:

import frontend.ide.position : Position;
import lib.lsp.lspTypes : CompletionList;
import model.model : Type;
import util.alloc.alloc : Alloc;
import util.opt : none, Opt, some;

Opt!CompletionList getCompletionForPosition(ref Alloc alloc, in Position pos) {
	return none!CompletionList;
}

