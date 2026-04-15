.PHONY: check test-end-to-end test-end-to-end-overwrite test unit-test unit-test-java unit-test-js view-dependencies

include = $(shell find include -name '*.keen')
include_keen = $(shell find include/keen -name '*.keen')
include_compiler = $(shell find include/compiler -name '*.keen')
compiler_deps = $(include_keen) $(include_compiler) include/compiler/backend/java/lib/Keen.class include/compiler/backend/java/lib/KeenClassLoader.class bin/imports/date.txt bin/imports/commit-hash.txt

clean:
	mv bin/keen-lkg keen-lkg
	rm -rf bin
	mkdir bin
	mv keen-lkg bin/keen-lkg

all: clean test

test: unit-test test-diagnostics test-end-to-end

unit-test: unit-test-java unit-test-js
unit-test-java: bin/keen $(include)
	bin/keen test include/config.kid
unit-test-js: bin/keen bin/java-classes.tar $(include)
	bin/keen build include/config.kid --test --out bin/test.js
	bin/test.js
	rm bin/test.js bin/test.js.map

test-diagnostics: bin/keen
	cd test/diagnostics && bash -c 'diff <(../../bin/keen check config.kid --no-color --all-errors 2>&1) expected.txt'

test-diagnostics-overwrite: bin/keen
	cd test/diagnostics && ../../bin/keen check config.kid --no-color --all-errors 2> expected.txt || true

test-end-to-end: bin/keen
	bin/keen test/end-to-end/main.keen
test-end-to-end-overwrite: bin/keen
	bin/keen test/end-to-end/main.keen --overwrite-output

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

update-lkg: bin/keen
	mv bin/keen bin/keen-lkg
	# Make sure it is self-compiled
	make bin/keen
	mv bin/keen bin/keen-lkg
	make bin/keen

check:
	bin/keen-lkg check include/config.kid

bin/keen: $(compiler_deps)
	bin/keen-lkg build include/compiler/app/main.keen --out bin/keen-tmp
	# Avoid directly writing to the file. This avoids crashing any IDE using the old version.
	mv bin/keen-tmp bin/keen

include = include/*/*.keen include/*/*/*.keen include/*/*/*/*.keen
bin/keen.tar.xz: bin/keen $(include_keen)
	tar --create --xz --file bin/keen.tar.xz bin/keen include/keen

install-vscode-extension: bin/keen.vsix
	code --install-extension bin/keen.vsix
bin/keen.vsix: editor/vscode/* editor/vscode/node_modules
	cd editor/vscode && ./node_modules/@vscode/vsce/vsce package --allow-missing-repository --out ../../bin/keen.vsix
editor/vscode/node_modules:
	cd editor/vscode && npm install

bin/java-classes.tar:
	rm -rf bin/java-classes
	mkdir bin/java-classes
	bin/keen print dependencies ../keen/include/config.kid --format flat | \
		grep 'java:///java' | \
		sed 's|^java:///java/|classes/java/|' | \
		sed 's|%24|\$$|' | \
		sed 's|$$|.class|' | \
		xargs -d '\n' unzip -qq /usr/lib/jvm/java-25-openjdk-amd64/jmods/java.base.jmod -d bin/java-classes || true
	tar -cf bin/java-classes.tar -C bin/java-classes/classes .
	rm -r bin/java-classes

### Optional commands ###

bin/keen.js: $(compiler_deps)
	bin/keen build include/compiler/app/main.keen --out bin/keen.js

profile-check: bin/keen
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/keen check include/compiler/app/main.keen --times 30 --perf
	jmc

profile-translate-to-java: bin/keen
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/keen build include/compiler/app/main.keen --out bin/temp --times 30 --perf
	rm bin/temp
	jmc

view-dependencies: bin/keen
	bin/keen print dependencies include/config.kid | dot -Tsvg > bin/dependencies.svg
	xdg-open bin/dependencies.svg
