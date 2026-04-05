# Build

In the root of the `keen` repository, run `make editor/vscode/keen-0.0.0.vsix`.

# Install

First, the extension needs `keen` to be installed somewhere on the default PATH (e.g., `/usr/local/bin/keen`).
See https://keen-lang.org/download.html for instructions.

Then run:
```
code --install-extension keen/editor/vscode/keen-0.0.0.vsix
```

# Debug

To debug the VSCode extension:

* Run `code editor/vscode` to open vscode in the directory containing this readme.
* Use Ctrl+Shift+D to open the debugger pane on the left. Click the green arrow to launch the client.
* In both windows, run the command "Output: Focus on Output View".
* In the newly opened window, in the top-right of the output view, switch from 'Tasks' to 'Keen language server'.
