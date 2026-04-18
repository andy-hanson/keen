# Keen

This readme describes how to build Keen from source.

For information about the language itself, visit the [website](https://keen.codes/).


# Setup

To work on Keen, you'll need these tools:

* [`git`](https://git-scm.com): Used to get this repository.
* [`java`](https://www.java.com/en/download/manual.jsp): Used to run Keen.
* [`node`](https://nodejs.org/): Used to test JS builds and to build the VSCode extension.

Then run:

```sh
git clone https://github.com/andy-hanson/keen.git
cd keen
make test
```


# Repository layout

* `app` is the source code for `keen` (the program used in `keen run`, etc.).
	More info in [app/readme.md](foo/readme.md).
* `editor` contains extensions for editors.
* `lib` is the Keen standard library.
* `test` contains unit tests of language features. These tests should not have diagnostics.
* `test-cases` is for tests that have diagnostics.
	- `test-cases/diagnostics` are checked as a single command with the output in `test-cases/diagnostics/expected.txt`.
		`make test-diagnostics-overwrite` updates it.
	- `test-cases/end-to-end` tests are each run independently, which makes them slow.
		`make test-end-to-end-overwrite` updates it.
	- `test-cases/ide` are used by `test/ide`. They can't go there because they have diagnostics.


# Development

For most changes you just need to run `make test`.

For development, avoid globally installed `keen` and instead add this repository's `bin` to the PATH.
(E.g., `export PATH=$PATH:~/keen/bin` in `.bashrc`, assuming you cloned this repository to your home directory.)

IDE extensions get `keen` from the PATH, so you can `make bin/keen` and reload the IDE and it will be using the latest code.
You don't need to reinstall the extension.

Keen is bootstrapped using `keen-lkg` ("last known good") which is excluded from `.gitignore`.
`make update-lkg` updates it. This should not be done often.
