import { basicSetup } from "codemirror"
import { LSPClient, languageServerExtensions } from "@codemirror/lsp-client"
import { EditorView } from "@codemirror/view"

const worker = new Worker("worker.js", { type: "module" })
worker.onmessage = async (event) => {
	const { data } = event
	console.log("LE DATA", data)
	const object = JSON.parse(data)
	if (object.method === "custom/unknownUris") {
		for (const uri of object.params.unknownUris) {
			// TODO: do this in parallel
			const message = JSON.stringify({
				method: "custom/readFileResult",
				params: await getIt(uri),
			})
			console.log("GONNA SEND UNKNOWN URIS RESPONSE", message)
			worker.postMessage(message)
		}
	} else {
		for (const handler of handlers) {
			handler(data)
		}
	}
}

const getIt = async (uri) => {
	const path = mapUriToFetchPath(uri)
	if (path === null) return { uri, type: 'notFound' }

	const response = await fetch(path)
	if (response.status === 200) {
		return { uri, type: "ok", content: await response.text() }
	} else {
		debugger
		return { uri, type: response.status === 404 ? "notFound" : "error" }
	}
}

const mapUriToFetchPath = uri => {
	if (uri.endsWith("crow-config.json"))
		// Don't waste time looking for these
		return null
	else if (uri.startsWith(includePrefix))
		return `include/${uri.slice(includePrefix.length)}`
	else if (uri.startsWith(tutorialPrefix))
		return `tutorial/${uri.slice(tutorialPrefix)}`
	else
		return null
}
const includePrefix = 'file:///usr/local/bin/crow/include/'
const tutorialPrefix = 'file:///home/me/tutorial/'

let handlers = []
const myTransport = {
	send(message) {
		console.log("GONNA SEND", message)
		worker.postMessage(message)
	},
	subscribe(handler) {
		handlers.push(handler)
	},
	unsubscribe(handler) {
		handlers = handlers.filter((h) => h !== handler)
	},
}

// https://codemirror.net/docs/ref/#lsp-client.LSPClientConfig
const client = new LSPClient({
	extensions: languageServerExtensions(),
})
client.connect(myTransport)

const view = new EditorView({
	doc: "Start document",
	parent: document.body,
	extensions: [basicSetup, client.plugin("file:///main.crow")],
})

console.log("I am the index")
