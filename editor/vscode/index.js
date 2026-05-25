/*
If editing this file, run 'make install-vscode-extension' for the changes to take effect.
(You don't need to do that when rebuilding `bin/keen`.)
*/

const childProcess = require("child_process")
/** @typedef {import("vscode").ExtensionContext} ExtensionContext */
/** @typedef {import("vscode-languageclient").LanguageClientOptions} LanguageClientOptions */
/** @typedef {import("vscode-languageclient/lib/node/main.js").ServerOptions} ServerOptions */
const { LanguageClient } = require("vscode-languageclient/lib/node/main.js")

/** @type {LanguageClient} */
let client

/** @type {function(ExtensionContext): void} */
exports.activate = context => {
	/** @type {ServerOptions} */
	const serverOptions = { command: "keen", args: ["lsp"] }
	/** @type {LanguageClientOptions} */
	const clientOptions = {
		documentSelector: [
			{ scheme:"file", language:"keen" },
			{ scheme:"file", language:"kid" },
		],
		outputChannelName: "Keen language server",
		connectionOptions: {
			maxRestartCount: 0,
		},
		initializationOptions: {},
	}
	client = new LanguageClient("keen", "Keen language server", serverOptions, clientOptions)
	client.start()
}

/** @type {function(): Thenable<void> | undefined} */
exports.deactivate = () =>
	client?.stop()
