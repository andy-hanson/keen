# Crow

This readme describes how to build Crow from source.

For information about the language itself, visit the [website](https://crow-lang.org/).


# Setup

To work on Crow, you'll need these tools:

* [`git`](https://git-scm.com): Used to get this repository.
* [`java`](https://www.java.com/en/download/manual.jsp): Used to run Crow.
* [`node`](https://nodejs.org/): Used to test JS builds and to build the VSCode extension.

Then run:

```sh
git clone https://github.com/andy-hanson/crow.git
cd crow
make test
```

# Testing

`make test` runs 3 kinds of tests:

* Unit tests. These can be placed anywhere in the code, but most are in `include/test`.
  Most tests should be unit tests, but they can't test compile errors.
* Tests in `test/diagnostics` are for testing compile errors.
  These are all tested with a single invocation of the compiler.
  If this changes, run `make test-diagnostics-overwrite`.
* A handful of tests in `test/end-to-end`.
  Since these each get their own process, they are slow.
  If adding or changing tests, run `make test-end-to-end-overwrite`.

# Publishing

Run `make upload-site` to build and publish. This requires you to have `aws` installed.
