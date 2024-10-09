/*
If editing this file, run 'make install-vscode-extension' for the changes to take effect.
(You don't need to do that when rebuilding `bin/crow`.)
*/

const childProcess = require("child_process")
const path = require("path")
/** @typedef {import("vscode").ExtensionContext} ExtensionContext */
/** @typedef {import("vscode").TextDocument} TextDocument */
const { FileType, Uri, workspace } = require("vscode")
/** @typedef {import("vscode-languageclient").LanguageClientOptions} LanguageClientOptions */
/** @typedef {import("vscode-languageclient/lib/node/main.js").ServerOptions} ServerOptions */
const { LanguageClient } = require("vscode-languageclient/lib/node/main.js")

/** @type {LanguageClient} */
let client

/** @type {function(ExtensionContext): void} */
exports.activate = context => {
	/** @type {ServerOptions} */
	const serverOptions = () =>
		Promise.resolve(childProcess.spawn("crow", ["lsp"], {stdio:'pipe'}))

	/** @type {LanguageClientOptions} */
	const clientOptions = {
		documentSelector: [{scheme:"file", language:"crow"}],
		outputChannelName: "Crow language server",
		connectionOptions: {
			maxRestartCount: 0,
		},
		initializationOptions: {
			unknownUris: true,
		},
	}
	client = new LanguageClient("crow", "Crow language server", serverOptions, clientOptions)
	client.start()

	client.onNotification("custom/unknownUris", withLogErrors("unknownUris", onUnknownUris))
}

/**
 * @template P, R
 * @param {string} description
 * @param {(p: P) => R} cb
 * @return {(p: P) => R}
 */
const withLogErrors = (description, cb) => {
	return p => {
		try {
			return cb(p)
		} catch (error) {
			logError(`Error in ${description}: ` + (/** @type {Error} */ (error)).stack)
			throw error
		}
	}
}

/** @type {function(string): void} */
const logError = message => {
	client.outputChannel.appendLine(message)
}

/** @type {function({unknownUris: ReadonlyArray<string>}): void} */
const onUnknownUris = ({unknownUris}) => {
	for (const uri of unknownUris)
		readFileAndNotify(uri)
}

const listedDirs = new Set()

const listFilesRecursive = dir => {
	if (!listedDirs.has(dir)) {
		listedDirs.add(dir)
		workspace.fs.readDirectory(Uri.parse(dir))
			.then(files => {
				for (const [name, type] of files) {
					const fileUri = `${dir}/${name}`
					switch (type) {
						case FileType.File:
							if (isRelevantFile(name))
								readFileAndNotify(fileUri)
							break
						case FileType.Directory:
							listFilesRecursive(fileUri)
							break
					}
				}
			})
			.catch(error => {
				logError(`Error reading directory: ${JSON.stringify(dir, error)}`)
			})
	}
}

/** @type {function(string): void} */
const readFileAndNotify = uri =>
	workspace.fs.readFile(Uri.parse(uri))
		.then(bytes => {
			const content = isRelevantFile(uri)
				? new TextDecoder().decode(bytes)
				: "" // Content of these files doesn't matter for frontend
			client.sendNotification("custom/readFileResult", {uri, type: "ok", content})
			if (uri.endsWith("/crow-config.json"))
				listFilesRecursive(path.dirname(uri))
		})
		.catch(error => {
			const isNotFound = error.code === "FileNotFound"
			if (!isNotFound)
				logError(`Error reading file: ${JSON.stringify({uri, error})}`)
			client.sendNotification("custom/readFileResult", {uri, type: isNotFound ? "notFound" : "error"})
		})

const isRelevantFile = name =>
	name.endsWith(".crow") || name.endsWith(".json")

/** @type {function(): Thenable<void> | undefined} */
exports.deactivate = () =>
	client && client.stop()
