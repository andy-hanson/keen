.PHONY: check test-end-to-end test-end-to-end-overwrite test unit-test unit-test-java unit-test-js view-dependencies

lib = $(shell find lib -name '*.keen')
app = $(shell find app -name '*.keen')
compiler_deps = $(lib) $(app) app/backend/java/lib/Keen.class app/backend/java/lib/KeenClassLoader.class bin/imports/date.txt bin/imports/commit-hash.txt

clean:
	mv bin/keen-lkg keen-lkg
	rm -rf bin
	mkdir bin
	mv keen-lkg bin/keen-lkg

all: clean test bin/keen.tar.xz

test: unit-test test-diagnostics test-end-to-end

unit-test: unit-test-java unit-test-js
unit-test-java: bin/keen $(lib) $(app)
	bin/keen test app lib test
unit-test-js: bin/keen bin/java-classes.tar $(lib) $(app)
	bin/keen build app lib test --test --out bin/test.js
	bin/test.js
	rm bin/test.js bin/test.js.map

test-diagnostics: bin/keen
	cd test-cases/diagnostics && bash -c 'diff <(../../bin/keen check . --no-color --all-errors 2>&1) expected.txt'

test-diagnostics-overwrite: bin/keen
	cd test-cases/diagnostics && ../../bin/keen check . --no-color --all-errors 2> expected.txt || true

test-end-to-end: bin/keen
	bin/keen run test-cases/end-to-end
test-end-to-end-overwrite: bin/keen
	bin/keen run test-cases/end-to-end -- --overwrite-output

today = $(shell date --iso-8601 --utc)

bin/imports/date.txt:
	mkdir -p bin/imports
	echo $(today) > bin/imports/date.txt

bin/imports/commit-hash.txt:
	mkdir -p bin/imports
	git rev-parse --short HEAD > bin/imports/commit-hash.txt

app/backend/java/lib/Keen.class: app/backend/java/lib/Keen.java
	javac app/backend/java/lib/Keen.java
app/backend/java/lib/KeenClassLoader.class: app/backend/java/lib/KeenClassLoader.java
	javac app/backend/java/lib/KeenClassLoader.java

update-lkg: bin/keen
	mv bin/keen bin/keen-lkg
	# Make sure it is self-compiled
	make bin/keen
	mv bin/keen bin/keen-lkg
	make bin/keen

check:
	bin/keen-lkg check app lib test

bin/keen: $(compiler_deps)
	bin/keen-lkg build app --out bin/keen-tmp
	# Avoid directly writing to the file. This avoids crashing any IDE using the old version.
	mv bin/keen-tmp bin/keen

bin/keen.tar.xz: bin/keen $(lib)
	tar --create --xz --file bin/keen.tar.xz bin/keen lib

install-vscode-extension: bin/keen.vsix
	code --install-extension bin/keen.vsix
bin/keen.vsix: editor/vscode/* editor/vscode/node_modules
	cd editor/vscode && ./node_modules/@vscode/vsce/vsce package --allow-missing-repository --out ../../bin/keen.vsix
editor/vscode/node_modules:
	cd editor/vscode && npm install

bin/java-classes.tar:
	rm -rf bin/java-classes
	mkdir bin/java-classes
	bin/keen print dependencies app lib test --format flat | \
		grep 'java:///java' | \
		sed 's|^java:///java/|classes/java/|' | \
		sed 's|%24|\$$|' | \
		sed 's|$$|.class|' | \
		xargs -d '\n' unzip -qq /usr/lib/jvm/java-25-openjdk-amd64/jmods/java.base.jmod -d bin/java-classes || true
	tar -cf bin/java-classes.tar -C bin/java-classes/classes .
	rm -r bin/java-classes

### Optional commands ###

bin/keen.js: $(compiler_deps)
	bin/keen build app --out bin/keen.js

profile-check: bin/keen
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/keen check app lib test --times 30 --perf
	jmc

view-dependencies: bin/keen
	bin/keen print dependencies app | dot -Tsvg > bin/dependencies.svg
	xdg-open bin/dependencies.svg
