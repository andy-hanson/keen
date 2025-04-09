[![Gitter](https://badges.gitter.im/crow-lang-org/community.svg)](
	https://gitter.im/crow-lang-org/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge)

# Crow

This readme describes how to build Crow from source.

For information about the language itself, visit the [website](https://crow-lang.org/).


# Setup

To work on Crow, you'll need these tools:

* [`java`](https://www.java.com/en/download/manual.jsp): Used to run Crow.
* [`git`](https://git-scm.com): Used to get this repository.
* [`node`](https://nodejs.org/): Used to test JS builds and to build the VSCode extension.
* Also install dependencies listed on the [download](https://crow-lang.org/download.html) page.
* On Linux: Optionally, [GraphViz](https://graphviz.org/download/) to support `make show-dependencies`.
* On Windows, use the "x64 Native Tools Command Prompt for VS 20__" (fill in the year) when running build commands.

Then run:

```sh
git clone https://github.com/andy-hanson/crow.git
cd crow
make test
```

This will build `bin/crow` (or `bin\crow.exe` on Windows), test, then serve the website on `localhost`.

You can also speed up builds by passing `-j4` (e.g. `make all -j4`), but it makes the output harder to read.

# Testing

`make test` runs all tests.

There are 2 kinds of tests:

* Unit tests in `src/test`. `make unit-test` runs these.
* End-to-end tests in the `test` directory. `make end-to-end-test` runs these.
	- If adding or changing tests, run `make end-to-end-test-overwrite`.

Before any pull request, you should also run `make all`.
This tests, lints, and starts serving the website.
Run the demo on the site to manually verify that WASM is still working.

# Debugging

### Debugging `crow` itself (compiler or interpreter)

Use `make debug`.

### Debugging Crow code

Currently, Crow has no debugger of its own, so you'll have to compile to C and debug that.
By default, crow compiles the C code with debug symbols.

For example:

```sh
crow build a.crow
gdb a
rbreak throw
run
```

# Building with libgccjit

Run `make all JIT=1` to build with libgccjit support. Use `crow run demo/hello.crow --jit` to test it out.

# Publishing

Run `make upload-site` to build and publish. This requires you to have `aws` installed.
You need to do this on both Linux and Windows.
(Windows uploads `crow-windows-x64.tar.xz` and `crow-demo-windows.tar.xz`, Linux handles everything else.)
