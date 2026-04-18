"2:10":
	signatures:
		-
			label: "foo nat64(x nat64) (from test:/signature-help/overloads.keen line 5)"
			documentation: "a"
			parameters:
				- label: 10, 17
			activeParameter: 1
		-
			label: "foo nat64(x nat64, y string) (from test:/signature-help/overloads.keen line 7)"
			documentation: "b"
			parameters:
				- label: 10, 17
				- label: 19, 27
			activeParameter: 1
		-
			label: "foo nat64(x string) (from test:/signature-help/overloads.keen line 9)"
			documentation: "c"
			parameters:
				- label: 10, 18
			activeParameter: 1
	activeParameter: 1
