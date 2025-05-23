# This file is for Linux.
# WARN: If editing this file, you might need to change NMakefile too.

.PHONY: check confirm-upload-site end-to-end-test end-to-end-test-overwrite serve prepare-site test unit-test unit-test-java unit-test-js

all_include_crow = $(shell find include/crow -name '*.crow')
all_include_compiler = $(shell find include/compiler -name '*.crow' -not -path 'include/compiler/test/*')
all_include = $(shell find include -name '*.crow')

clean:
	mv bin/crow-lkg crow-lkg
	rm -rf bin site demo/webapp/db demo/*/index.js demo/*/index.js.map
	mkdir bin
	mv crow-lkg bin/crow-lkg

all: clean test lint serve

test: unit-test end-to-end-test

unit-test: unit-test-java unit-test-js
unit-test-java: bin/crow $(all_include)
	bin/crow build include/crow-config.json --test --out bin/test
	bin/test
unit-test-js: bin/crow $(all_include)
	bin/crow build include/crow-config.json --test --out bin/test.js
	bin/test.js

end-to-end-test: bin/crow
	bin/crow test/end-to-end/main.crow

end-to-end-test-overwrite: bin/crow
	bin/crow test/end-to-end/main.crow --overwrite-output

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

bin/crow: $(all_include_crow) $(all_include_compiler) include/compiler/backend/java/lib/Crow.class bin/imports/date.txt bin/imports/commit-hash.txt
	bin/crow-lkg build include/compiler/app/main.crow --out bin/crow-tmp
	# Avoid directly writing to the file. This avoids crashing any IDE using the old version.
	mv bin/crow-tmp bin/crow

profile-check: bin/crow
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/crow check include/compiler/app/main.crow --times 30 --perf
	jmc

profile-translate-to-java: bin/crow
	java -XX:StartFlightRecording=filename=profile.jfr,settings=profile -jar bin/crow build include/compiler/app/main.crow --out bin/temp --times 30 --perf
	rm bin/temp
	jmc

### site ###

prepare-site: bin/crow bin/crow-x64.deb bin/crow-demo.tar.xz bin/crow.vsix site/index.js
	bin/crow site-src/site.crow

site/index.js: bin/crow site-src/script/*.crow site-src/script/*/*.crow
	mkdir -p site
	bin/crow build site-src/script/index.crow --out site/index.js

serve: prepare-site
	bin/crow site-src/serve.crow

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
