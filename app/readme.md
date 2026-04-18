This directory is the code for the `keen` executable.

Keen processes code with a pipeline:

* First `frontend/parse` parses files to produce `model/ast`s.
* Then `frontend/check` converts the parsed files to the typed model `model/model`.
* Then `lower` converts the typed model to a simplified `model/low-model`.
* Then either `backend/java` or `backend/js` will translate it to the appropriate target.

The `frontend` steps are  tied together with `frontend/frontend.keen` which responds to file load events, parses the files and checks them. This is the one part of the frontend that is stateful, since in an IDE, files can change. However, it is not `global` since it is written to not load files itself, but just respond to events that it receives through `set-file`.

`server.keen` ties it all together. The server is also completely pure and never loads files itself. It's basically an LSP (Language Server Protocol) server, but even commands like `keen run` use it.

`main.keen` processes the command line, creates a `server`, loads the appropriate files and sends them to the server, and calls the server methods appropriate to the command. Besides `util/file-system.keen`, this is the only file that should contain I/O.

`ide` contains LSP (language server protocol) services. These operate on the `model/model`; the `low-model` (or `backend`) is not needed in the IDE.
