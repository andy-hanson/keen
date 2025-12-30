import { basicSetup } from "codemirror"
import { indentWithTab } from "@codemirror/commands"
import { LSPClient, languageServerExtensions } from "@codemirror/lsp-client"
import { EditorView, keymap } from "@codemirror/view"

const worker = new Worker("worker.js", { type: "module" })
worker.onmessage = async (event) => {
	const object = JSON.parse(event.data)
	if (perfReportIds.has(object.id)) {
		console.log(object.result)
	} else {
		for (const handler of handlers) {
			handler(event.data)
		}
	}
}

let handlers = []
const myTransport = {
	send(message) {
		// console.log("GONNA SEND", message)
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
	timeout: 60_000,
})
client.connect(myTransport)

const view = new EditorView({
	doc: 'main void()\n\tinfo log something\n',
	parent: document.body,
	extensions: [
		basicSetup,
		client.plugin("file:///main.crow"),
		keymap.of([indentWithTab]),
	],
})

const perfReportButton = document.createElement('button')
perfReportButton.textContent = 'Report perf (see console)'
document.body.append(perfReportButton)
const perfReportIds = new Set()
perfReportButton.onclick = () => {
	const id = 1000000 + Math.floor(Math.random() * 1000000)
	perfReportIds.add(id)
	worker.postMessage(JSON.stringify({
		id: id,
		method: 'custom/perf-report',
		params: {},
	}))
}
