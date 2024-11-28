# This file is for Linux.
# WARN: If editing this file, you might need to change NMakefile too.

.PHONY: confirm-upload-site debug debug-dmd end-to-end-test end-to-end-test-overwrite serve prepare-site \
	show-dependencies test unit-test

# WARN: Does not clean `dyncall` as that takes too long to restore
# Also does not clean `node_modules` for the VSCode plugin
clean:
	rm -rf bin site demo/webapp/db demo/*/index.js demo/*/index.js.map

all: clean test lint serve

debug: bin/crow-debug
	gdb ./bin/crow-debug

debug-dmd: bin/crow-dmd
	gdb ./bin/crow-dmd

### test ###

test: unit-test crow-unit-tests test-extern-library end-to-end-test

unit-test: bin/crow-debug
	./bin/crow-debug self-test

crow-unit-tests: crow-unit-tests-interpreter crow-unit-tests-jit crow-unit-tests-aot crow-unit-tests-node-js
crow-unit-tests-interpreter: bin/crow
	bin/crow test include/crow-config.json
crow-unit-tests-jit: bin/crow
ifdef JIT
	bin/crow test include/crow-config.json --jit
	# TODO: test with '--optimize' too
endif
crow-unit-tests-aot: bin/crow
	bin/crow test include/crow-config.json --aot
	bin/crow test include/crow-config.json --aot --optimize
crow-unit-tests-node-js: bin/crow
	bin/crow test include/crow-config.json --node-js

test-extern-library: bin/crow bin/libexample.so
	bin/crow test/test-extern-library/main.crow
	# TODO: bin/crow run test/test-extern-library/main.crow --jit
	bin/crow run test/test-extern-library/main.crow --aot

bin/libexample.so: test/test-extern-library/example.c
	mkdir -p bin
	cc test/test-extern-library/example.c -Werror -Wextra -Wall -ansi -pedantic -shared -o bin/libexample.so

end-to-end-test: bin/crow
ifdef JIT
	bin/crow test/end-to-end/main.crow --include-jit
else
	bin/crow test/end-to-end/main.crow
endif

end-to-end-test-overwrite: bin/crow
	bin/crow test/end-to-end/main.crow --overwrite-output

### external dependencies ###

dyncall/dyncall/libdyncall_s.a: dyncall
	cd dyncall && ./configure
	cd dyncall && make

dyncall:
	hg clone https://dyncall.org/pub/dyncall/dyncall/

### D build ###

all_src_files = src/*.d \
	src/app/*.d \
	src/backend/*.c \
	src/backend/*.d \
	src/backend/*/*.d \
	src/concretize/*.d \
	src/document/*.d \
	src/frontend/*.d \
	src/frontend/check/*.d \
	src/frontend/check/checkCall/*.d \
	src/frontend/ide/*.d \
	src/frontend/parse/*.d \
	src/interpret/*.d \
	src/lib/*.d \
	src/lib/lsp/*.d \
	src/lower/*.d \
	src/model/*.d \
	src/test/*.d \
	src/test/*/* \
	src/util/*.d \
	src/util/alloc/*.d \
	src/util/col/*.d
d_dependencies = $(all_src_files) bin/d-imports/date.txt bin/d-imports/commit-hash.txt dyncall/dyncall/libdyncall_s.a

d_flags_common = -w -betterC -preview=dip1000 -preview=in -J=bin/d-imports -Jsrc/backend -J=src/test -J=include
dmd_flags_common = $(d_flags_common)
ldc_flags_common = $(d_flags_common)
ifdef JIT
	dmd_flags_common += -version=GccJitAvailable
	ldc_flags_common += --d-version=GccJitAvailable
endif

dmd_flags_assert = $(dmd_flags_common) -check=on -boundscheck=on
dmd_flags_debug = -debug -g -version=Debug -version=Test
ldc_flags_assert = $(ldc_flags_common) --enable-asserts=true --boundscheck=on
ldc_wasm_flags = -mtriple=wasm32-unknown-unknown-wasm -L-allow-undefined
ldc_fast_flags_no_tail_call = -O2 -L=--strip-all
ldc_fast_flags = $(ldc_fast_flags_no_tail_call) --d-version=TailRecursionAvailable
app_link = -L=-ldyncall_s -L=-ldyncallback_s -L=-ldynload_s -L=-lunwind \
	-L=-L./dyncall/dyncall -L=-L./dyncall/dyncallback -L=-L./dyncall/dynload
ifdef JIT
	app_link += -L=-lgccjit
endif

today = $(shell date --iso-8601 --utc)

bin/d-imports/date.txt:
	mkdir -p bin/d-imports
	echo $(today) > bin/d-imports/date.txt

bin/d-imports/commit-hash.txt:
	mkdir -p bin/d-imports
	git rev-parse --short HEAD > bin/d-imports/commit-hash.txt

debug_flags = --d-debug -g --d-version=Debug

bin/crow-debug: $(d_dependencies)
	ldc2 -ofbin/crow-debug $(ldc_flags_assert) $(debug_flags) --d-version=Test src/app/main.d -I=src -i $(app_link)
	rm bin/crow-debug.o

# This isn't used anywhere, but you could use it to test things out quickly, since compilation with DMD is much faster.
bin/crow-dmd: $(d_dependencies)
	dmd -ofbin/crow-dmd -m64 $(dmd_flags_assert) -debug -g -version=Debug -version=Test \
		src/app/main.d -I=src -i $(app_link)
	rm -f bin/crow-dmd.o

bin/crow: $(d_dependencies)
	ldc2 -ofbin/crow $(ldc_flags_assert) $(ldc_fast_flags) src/app/main.d -I=src -i $(app_link)
	rm bin/crow.o

# This isn't used anywhere, but you can rename the result to 'crow.wasm' to help debugging in the browser
bin/crow-debug.wasm: $(d_dependencies)
	# For some reason, Chrome crashes if this is not at least -O1
	ldc2 -ofbin/crow-debug.wasm $(debug_flags) $(ldc_flags_assert) $(ldc_wasm_flags) -O1 src/wasm.d -I=src -i
	rm bin/crow-debug.o

bin/crow.wasm: $(d_dependencies)
	# Build with a different name so it doesn't use the same '.o' file as 'bin/crow'
	ldc2 -ofbin/crow-wasm.wasm $(ldc_flags_assert) $(ldc_wasm_flags) $(ldc_fast_flags_no_tail_call) src/wasm.d -I=src -i
	rm bin/crow-wasm.o
	mv bin/crow-wasm.wasm bin/crow.wasm

### lint ###

lint: lint-basic lint-dscanner lint-d-imports-exports bin/dependencies.dot

lint-basic: bin/crow
	bin/crow test/lint-basic.crow

lint-dscanner:
	dub run dscanner --quiet -- --styleCheck src

lint-d-imports-exports: bin/crow
	bin/crow test/lint-d-imports-exports.crow

show-dependencies: bin/dependencies.svg
	open bin/dependencies.svg

bin/dependencies.svg: bin/dependencies.dot
	dot -Tsvg -o bin/dependencies.svg bin/dependencies.dot

bin/dependencies.dot: bin/crow src test/dependencies.crow
	bin/crow test/dependencies.crow

### site ###

prepare-site: bin/crow bin/crow.wasm bin/crow-x64.deb bin/crow-linux-x64.tar.xz bin/crow-demo.tar.xz bin/crow.vsix \
		site/index.js
	bin/crow run site-src/site.crow --aot

site/index.js: bin/crow site-src/script/*.crow site-src/script/*/*.crow
	mkdir -p site
	bin/crow build site-src/script/index.crow --out site/index.js

serve: prepare-site
	bin/crow run site-src/serve.crow --aot

### publish ###

all_include = include/*/*.crow include/*/*/*.crow include/*/*/*/*.crow
bin/crow-linux-x64.tar.xz: bin/crow $(all_include)
	tar --create --xz --file bin/crow-linux-x64.tar.xz bin/crow include

bin/crow-demo.tar.xz: demo/* demo/*/* demo/*/*/*
	tar --create --xz --file bin/crow-demo.tar.xz \
		--transform 'flags=r;s|demo|crow-demo|' --exclude crow-demo/extern demo

define newline


endef

define crow_deb_control =
Package: crow
Version: 0.0-$(today)
Section: base
Priority: optional
Architecture: amd64
Depends: libunwind-dev
Maintainer: Andy Hanson <andy-hanson@protonmail.com>
Description: Crow programming language

endef

bin/crow-x64.deb: bin/crow $(all_include)
	mkdir bin/deb
	mkdir bin/deb/usr
	mkdir bin/deb/usr/bin
	cp bin/crow bin/deb/usr/bin/crow
	mkdir bin/deb/usr/include
	cp -r include bin/deb/usr/include/crow
	mkdir bin/deb/DEBIAN
	@printf '$(subst $(newline),\n,${crow_deb_control})' > bin/deb/DEBIAN/control
	dpkg-deb --build bin/deb bin/crow-x64.deb
	rm -r bin/deb

bin/crow.vsix: editor/vscode/* editor/vscode/node_modules
	cd editor/vscode && ./node_modules/@vscode/vsce/vsce package --allow-missing-repository --out ../../bin/crow.vsix

install-vscode-extension: bin/crow.vsix
	code --install-extension bin/crow.vsix

editor/vscode/node_modules:
	cd editor/vscode && npm install

# `bin\crow-windows-x64.tar.xz` is uploaded by NMakefile
aws_upload_command = aws s3 sync site s3://crow-lang.org --delete \
	--exclude "bin\crow-windows-x64.tar.xz" --exclude "bin\crow-demo-windows.tar.xz"

confirm-upload-site: prepare-site
	$(aws_upload_command) --dryrun
	@echo -n "Make these changes to crow-lang.org? [y/n] " && read ans && [ $${ans:-n} = y ]

upload-site: prepare-site confirm-upload-site
	$(aws_upload_command)
