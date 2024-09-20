serve: index.js
	# TODO: THIS IS SHAMEFUL ----------------------------------------------------------------------------------------------------------
	python3 -m http.server -d .

index.js: script/*.crow
	crow check script/index.crow && crow build script/index.crow --out index.js
