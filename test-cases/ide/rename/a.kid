"5:8":
	changes:
		"test:/rename/a.keen":
			-
				range:
					start: line: 4, character: 1
					end: line: 4, character: 4
				newText: "new-name"
		"test:/rename/b.keen":
			-
				range:
					start: line: 0, character: 0
					end: line: 0, character: 3
				newText: "new-name"
