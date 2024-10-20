module frontend.ide.getCodeLenses;

@safe @nogc pure nothrow:

import frontend.ide.importReferences : ImportsAndReExports, isEmpty, withImportsAndReExportsOfModule;
import lib.lsp.lspTypes : CodeLens, CodeLensParams, Command;
import model.model : Module, moduleAtUri, Program;
import util.alloc.alloc : Alloc;
import util.col.array : isEmpty;
import util.col.arrayBuilder : buildArray, Builder;
import util.sourceRange : LineAndCharacterRange;
import util.uri : baseName, Uri;
import util.writer : makeStringWithWriter, Writer, writeWithCommas;

CodeLens[] getCodeLenses(ref Alloc alloc, in Program program, in CodeLensParams params) {
	Module* module_ = moduleAtUri(program, params.textDocument);
	return buildArray!CodeLens(alloc, (scope ref Builder!CodeLens out_) {
		withImportsAndReExportsOfModule!void(program, module_, (in ImportsAndReExports x) {
			if (!isEmpty(x)) {
				size_t maxUris = 4;
				string message = makeStringWithWriter(alloc, (scope ref Writer writer) {
					writeUrisOrCount(writer, "Module re-exported by ", x.reExports, maxUris);
					if (!isEmpty(x.imports)) {
						if (!isEmpty(x.reExports)) writer ~= "; ";
						writeUrisOrCount(writer, "Module used by ", x.imports, maxUris);
					}
				});
				out_ ~= CodeLens(LineAndCharacterRange.topOfFile, Command(message));
			}
		});
	});
}

private:

void writeUrisOrCount(scope ref Writer writer, in string description, in Uri[] uris, size_t max) {
	if (!isEmpty(uris)) {
		writer ~= description;
		if (uris.length > max) {
			writer ~= uris.length;
			writer ~= " other modules";
		} else
			writeWithCommas!Uri(writer, uris, (in Uri x) {
				writer ~= baseName(x);
			});
	}
}
