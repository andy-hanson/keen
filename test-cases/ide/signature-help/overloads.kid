"2:10":
	signatures:
		-
			label: "foo nat32(x nat32) (from test:/signature-help/overloads.keen line 5)"
			documentation: "a"
			parameters:
				- label: 10, 17
			activeParameter: 0
		-
			label: "foo nat32(x nat32, y string) (from test:/signature-help/overloads.keen line 7)"
			documentation: "b"
			parameters:
				- label: 10, 17
				- label: 19, 27
			activeParameter: 0
		-
			label: "foo nat32(x string) (from test:/signature-help/overloads.keen line 9)"
			documentation: "c"
			parameters:
				- label: 10, 18
			activeParameter: 0
	activeParameter: 0
