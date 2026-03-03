.PHONY: check test-end-to-end test-end-to-end-overwrite serve prepare-site test unit-test unit-test-java unit-test-js view-dependencies

include = $(shell find include -name '*.crow')
include_crow = $(shell find include/crow -name '*.crow')
include_compiler = $(shell find include/compiler -name '*.crow')
compiler_deps = $(include_crow) $(include_compiler) include/compiler/backend/java/lib/Crow.class bin/imports/date.txt bin/imports/commit-hash.txt

clean:
	mv bin/crow-lkg crow-lkg
	rm -rf bin site demo/webapp/db demo/*/index.js demo/*/index.js.map
	mkdir bin
	mv crow-lkg bin/crow-lkg

all: clean test serve

test: unit-test test-diagnostics test-end-to-end

unit-test: unit-test-java unit-test-js
unit-test-java: bin/crow $(include)
	bin/crow build include/crow-config.json --test --out bin/test
	bin/test
unit-test-js: bin/crow $(include)
	bin/crow build include/crow-config.json --test --out bin/test.js
	bin/test.js

test-diagnostics: bin/crow
	cd test/diagnostics && bash -c 'diff <(../../bin/crow check crow-config.json --no-color --all-errors 2>&1) expected.txt'

test-diagnostics-overwrite: bin/crow
	cd test/diagnostics && ../../bin/crow check crow-config.json --no-color --all-errors 2> expected.txt || true

test-end-to-end: bin/crow
	./test/end-to-end/main.crow
test-end-to-end-overwrite: bin/crow
	./test/end-to-end/main.crow --overwrite-output

today = $(shell date --iso-8601 --utc)

bin/imports/date.txt:
	mkdir -p bin/imports
	echo $(today) > bin/imports/date.txt

bin/imports/commit-hash.txt:
	mkdir -p bin/imports
	git rev-parse --short HEAD > bin/imports/commit-hash.txt

include/compiler/backend/java/lib/Crow.class: include/compiler/backend/java/lib/*.java
	javac include/compiler/backend/java/lib/*.java

update-lkg: bin/crow
	mv bin/crow-lkg bin/crow-lkg-BACKUP
	mv bin/crow bin/crow-lkg
	# Make sure it is self-compiled
	make bin/crow
	mv bin/crow bin/crow-lkg
	make bin/crow

check:
	bin/crow-lkg check include/crow-config.json

bin/crow: $(compiler_deps)
	bin/crow-lkg build include/compiler/app/main.crow --out bin/crow-tmp
	# Avoid directly writing to the file. This avoids crashing any IDE using the old version.
	mv bin/crow-tmp bin/crow

### Optional commands ###

bin/crow.js: $(compiler_deps)
	bin/crow build include/compiler/app/main.crow --out bin/crow.js

profile-check: bin/crow
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/crow check include/compiler/app/main.crow --times 30 --perf
	jmc

profile-translate-to-java: bin/crow
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/crow build include/compiler/app/main.crow --out bin/temp --times 30 --perf
	rm bin/temp
	jmc

view-dependencies: bin/crow
	bin/crow print dependencies include/crow-config.json | dot -Tsvg > bin/dependencies.svg
	xdg-open bin/dependencies.svg

### site ###

# TODO: bin/crow.tar.xz bin/crow-demo.tar.xz bin/crow.vsix
site-dependencies: bin/crow site/index.js site/worker.js site/crow-include.tar site/java-classes.tar

prepare-site: site-dependencies
	bin/crow site-src/build/site.crow

site/index.js: bin/crow site-src/script/*.crow site-src/script/*/*.crow
	mkdir -p site
	bin/crow build site-src/script/index.crow --out site/index.js
site/worker.js: bin/crow site-src/script/worker.crow $(compiler_deps)
	bin/crow build site-src/script/worker.crow --out site/worker.js

serve: site-dependencies
	( trap 'kill 0' INT; bin/crow run site-src/build/site.crow --watch & bin/crow build site-src/script/index.crow --out site/index.js --watch & ./site-src/build/serve.crow & wait )

### publish ###

include = include/*/*.crow include/*/*/*.crow include/*/*/*/*.crow
bin/crow.tar.xz: bin/crow $(include_crow)
	tar --create --xz --file bin/crow.tar.xz bin/crow include/crow

bin/crow-demo.tar.xz: demo/* demo/*/* demo/*/*/*
	tar --create --xz --file bin/crow-demo.tar.xz \
		--transform 'flags=r;s|demo|crow-demo|' --exclude crow-demo/extern demo

install-vscode-extension: bin/crow.vsix
	code --install-extension bin/crow.vsix
bin/crow.vsix: editor/vscode/* editor/vscode/node_modules
	cd editor/vscode && ./node_modules/@vscode/vsce/vsce package --allow-missing-repository --out ../../bin/crow.vsix
editor/vscode/node_modules:
	cd editor/vscode && npm install

site/crow-include.tar: $(include)
	tar -cf site/crow-include.tar -C include/crow .
site/java-classes.tar:
	rm -rf site/java-classes
	mkdir site/java-classes
	bin/crow print dependencies include/crow-config.json --format flat | \
		grep 'java:///java' | \
		sed 's|^java:///java/|classes/java/|' | \
		sed 's|%24|\$$|' | \
		sed 's|$$|.class|' | \
		xargs -d '\n' unzip -qq /usr/lib/jvm/java-25-openjdk-amd64/jmods/java.base.jmod -d site/java-classes || true
	tar -cf site/java-classes.tar -C site/java-classes/classes .
	rm -r site/java-classes
