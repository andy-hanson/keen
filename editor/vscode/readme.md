# Build

In the root of the `crow` repository, run `make editor/vscode/crow-0.0.0.vsix`.

# Install

First, the extension needs `crow` to be installed somewhere on the default PATH (e.g., `/usr/local/bin/crow`).
See https://crow-lang.org/download.html for instructions.

Then run:
```
code --install-extension crow/editor/vscode/crow-0.0.0.vsix
```

# Debug

To debug the VSCode extension:

* Run `code editor/vscode` to open vscode in the directory containing this readme.
* Use Ctrl+Shift+D to open the debugger pane on the left. Click the green arrow to launch the client.
* In both windows, run the command "Output: Focus on Output View".
* In the newly opened window, in the top-right of the output view, switch from 'Tasks' to 'Crow language server'.
