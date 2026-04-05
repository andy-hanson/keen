.PHONY: check test-end-to-end test-end-to-end-overwrite test unit-test unit-test-java unit-test-js view-dependencies

include = $(shell find include -name '*.keen')
include_crow = $(shell find include/keen -name '*.keen')
include_compiler = $(shell find include/compiler -name '*.keen')
compiler_deps = $(include_crow) $(include_compiler) include/compiler/backend/java/lib/Keen.class include/compiler/backend/java/lib/KeenClassLoader.class bin/imports/date.txt bin/imports/commit-hash.txt

clean:
	mv bin/crow-lkg crow-lkg
	rm -rf bin
	mkdir bin
	mv crow-lkg bin/crow-lkg

all: clean test

test: unit-test test-diagnostics test-end-to-end

unit-test: unit-test-java unit-test-js
unit-test-java: bin/crow $(include)
	bin/crow build include/keen-config.json --test --out bin/test
	bin/test
	rm bin/test
unit-test-js: bin/crow bin/java-classes.tar $(include)
	bin/crow build include/keen-config.json --test --out bin/test.js
	bin/test.js
	rm bin/test.js bin/test.js.map

test-diagnostics: bin/crow
	cd test/diagnostics && bash -c 'diff <(../../bin/crow check keen-config.json --no-color --all-errors 2>&1) expected.txt'

test-diagnostics-overwrite: bin/crow
	cd test/diagnostics && ../../bin/crow check keen-config.json --no-color --all-errors 2> expected.txt || true

test-end-to-end: bin/crow
	./test/end-to-end/main.keen
test-end-to-end-overwrite: bin/crow
	./test/end-to-end/main.keen --overwrite-output

today = $(shell date --iso-8601 --utc)

bin/imports/date.txt:
	mkdir -p bin/imports
	echo $(today) > bin/imports/date.txt

bin/imports/commit-hash.txt:
	mkdir -p bin/imports
	git rev-parse --short HEAD > bin/imports/commit-hash.txt

include/compiler/backend/java/lib/Keen.class: include/compiler/backend/java/lib/Keen.java
	javac include/compiler/backend/java/lib/Keen.java
include/compiler/backend/java/lib/KeenClassLoader.class: include/compiler/backend/java/lib/KeenClassLoader.java
	javac include/compiler/backend/java/lib/KeenClassLoader.java

update-lkg: bin/crow
	mv bin/crow-lkg bin/crow-lkg-BACKUP
	mv bin/crow bin/crow-lkg
	# Make sure it is self-compiled
	make bin/crow
	mv bin/crow bin/crow-lkg
	make bin/crow

check:
	bin/crow-lkg check include/keen-config.json

bin/crow: $(compiler_deps)
	bin/crow-lkg build include/compiler/app/main.keen --out bin/crow-tmp
	# Avoid directly writing to the file. This avoids crashing any IDE using the old version.
	mv bin/crow-tmp bin/crow

include = include/*/*.keen include/*/*/*.keen include/*/*/*/*.keen
bin/crow.tar.xz: bin/crow $(include_crow)
	tar --create --xz --file bin/crow.tar.xz bin/crow include/keen

install-vscode-extension: bin/crow.vsix
	code --install-extension bin/crow.vsix
bin/crow.vsix: editor/vscode/* editor/vscode/node_modules
	cd editor/vscode && ./node_modules/@vscode/vsce/vsce package --allow-missing-repository --out ../../bin/crow.vsix
editor/vscode/node_modules:
	cd editor/vscode && npm install

bin/java-classes.tar:
	rm -rf bin/java-classes
	mkdir bin/java-classes
	crow print dependencies ../keen/include/keen-config.json --format flat | \
		grep 'java:///java' | \
		sed 's|^java:///java/|classes/java/|' | \
		sed 's|%24|\$$|' | \
		sed 's|$$|.class|' | \
		xargs -d '\n' unzip -qq /usr/lib/jvm/java-25-openjdk-amd64/jmods/java.base.jmod -d bin/java-classes || true
	tar -cf bin/java-classes.tar -C bin/java-classes/classes .
	rm -r bin/java-classes

### Optional commands ###

bin/crow.js: $(compiler_deps)
	bin/crow build include/compiler/app/main.keen --out bin/crow.js

profile-check: bin/crow
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/crow check include/compiler/app/main.keen --times 30 --perf
	jmc

profile-translate-to-java: bin/crow
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/crow build include/compiler/app/main.keen --out bin/temp --times 30 --perf
	rm bin/temp
	jmc

view-dependencies: bin/crow
	bin/crow print dependencies include/keen-config.json | dot -Tsvg > bin/dependencies.svg
	xdg-open bin/dependencies.svg
