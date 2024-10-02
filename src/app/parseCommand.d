module app.parseCommand;

@safe @nogc pure nothrow:

import app.command : BuildOptions, Command, CommandKind, CommandOptions, RunOptions, SingleBuildOutput;
import frontend.lang : CCompileOptions, CVersion, JitOptions, OptimizationLevel;
import frontend.parse.lexToken : NatAndOverflow, takeNat;
import lib.server : PrintKind;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.col.array : copyArray, findIndex, isEmpty, map, newArray, only;
import util.col.arrayBuilder : buildArray, Builder, finish;
import util.conv : isUint, safeToUint;
import util.exitCode : ExitCode;
import util.opt : force, has, MutOpt, none, noneMut, Opt, optIf, optOrDefault, some, someMut;
import util.sourceRange : LineAndColumn;
import util.string :
	CString,
	cString,
	endsWith,
	isDecimalDigit,
	MutCString,
	PrefixAndRest,
	startsWith,
	stringOfCString,
	trySplit,
	tryTakeChar;
import util.symbol : Extension, symbol;
import util.union_ : Union;
import util.uri :
	alterExtension,
	asFilePath,
	FilePath,
	getExtension,
	parseFilePathWithCwd,
	parseUriWithCwd,
	toUri,
	Uri,
	uriIsFile;
import util.util : castNonScope, enumEach, optEnumOfString, stringOfEnum, typeAs;
import util.writer : makeStringWithWriter, writeNewline, writeQuotedString, Writer, writeWithCommasAndAnd;
import versionInfo : OS, VersionOptions;

Command parseCommand(ref Alloc alloc, FilePath cwd, OS os, CString[] args) {
	string arg0 = isEmpty(args) ? "" : stringOfCString(args[0]);
	if (endsWith(arg0, ".crow"))
		return Command(
			CommandKind(CommandKind.Run(
				parseUriWithCwd(cwd, arg0), RunOptions(RunOptions.Interpret(VersionOptions.default_)), args[1 .. $])),
			CommandOptions()) ;
	else {
		Opt!CommandName optName = optEnumOfString!CommandName(arg0);
		return has(optName)
			? parseCommandFromName(alloc, cwd, os, force(optName), args[1 .. $])
			: Command(
				CommandKind(CommandKind.Help(
					helpAllText(alloc),
					!isEmpty(args) && (args[0] == "help" || args[0] == "--help") ? ExitCode.ok : ExitCode.error)),
				CommandOptions(perf: false));
	}
}

private:

Command parseCommandFromName(ref Alloc alloc, FilePath cwd, OS os, CommandName name, CString[] args) {
	SplitArgsAndOptions split = splitArgs(alloc, args);
	if (split.help)
		return Command(
			CommandKind(CommandKind.Help(helpForCommand(alloc, name), ExitCode.ok)),
			split.options);
	else {
		Diags diagsBuilder = Diags(&alloc);
		CommandKind res = parseCommandKind(alloc, cwd, os, name, split.args, diagsBuilder);
		Diag[] diags = finish(diagsBuilder);
		if (isEmpty(diags))
			return Command(res, split.options);
		else {
			string help = makeStringWithWriter(alloc, (scope ref Writer writer) {
				writer ~= "Command syntax error: ";
				foreach (Diag x; diags) {
					writeDiag(writer, x);
					writeNewline(writer, 0);
				}
				writeNewline(writer, 0);
				writeHelpForCommand(writer, name);
			});
			return Command(CommandKind(CommandKind.Help(help, ExitCode.error)), split.options);
		}
	}
}

CommandKind dummyCommand() =>
	CommandKind(CommandKind.Help("This should not appear", ExitCode.error));

enum CommandName {
	build,
	check,
	document,
	lsp,
	print,
	run,
	test,
	version_,
}

// We always combine this with the commandName, so no need to include it here
immutable struct Diag {
	immutable struct BuildOutBadFileExtension {
		Extension executableExtension;
	}
	immutable struct BuildOutBadPrefix { string prefix; }
	immutable struct DuplicatePart { CString tag; }
	immutable struct ExpectedCrowUri { string actual; }
	immutable struct ExpectedPaths { Opt!CString tag; }
	immutable struct NeedsSinglePath { size_t actual; }
	immutable struct ParseFilePath { CString actual; }
	immutable struct PrintKind {}
	immutable struct UnexpectedPart { CString tag; }
	immutable struct UnexpectedPartArgs { ArgsPart part; }
	immutable struct UnexpectedBefore { CString arg; }
	immutable struct RunArgNotSupportedInNodeJs {
		string arg;
	}
	immutable struct RunKindIncompatible {
		bool aot;
		bool jit;
		bool nodeJs;
	}
	immutable struct RunOptimizeNeedsAotOrJit {}

	mixin Union!(
		BuildOutBadFileExtension,
		BuildOutBadPrefix,
		DuplicatePart,
		ExpectedCrowUri,
		ExpectedPaths,
		NeedsSinglePath,
		ParseFilePath,
		PrintKind,
		UnexpectedPart,
		UnexpectedPartArgs,
		UnexpectedBefore,
		RunArgNotSupportedInNodeJs,
		RunKindIncompatible,
		RunOptimizeNeedsAotOrJit);
}
alias Diags = Builder!Diag;

void writeDiag(scope ref Writer writer, in Diag a) {
	a.matchIn!void(
		(in Diag.BuildOutBadFileExtension x) {
			writer ~= "Build output must be a '.c', '.js', or ";
			writeExtension(writer, x.executableExtension);
			writer ~= " file.";
		},
		(in Diag.BuildOutBadPrefix x) {
			writer ~= "Unrecognized output prefix ";
			writeQuotedString(writer, x.prefix);
			writer ~= ". An output can start with 'js:' or 'node-js:'.";
		},
		(in Diag.DuplicatePart x) {
			writer ~= "Argument ";
			writeQuotedString(writer, x.tag);
			writer ~= " appears twice.";
		},
		(in Diag.ExpectedCrowUri x) {
			writer ~= "Expected path to a '.crow' file, instead got ";
			writeQuotedString(writer, x.actual);
			writer ~= '.';
		},
		(in Diag.ExpectedPaths x) {
			if (has(x.tag)) {
				writer ~= "Argument ";
				writeQuotedString(writer, force(x.tag));
				writer ~= " expects a list of paths.";
			} else
				writer ~= "This command expects a list of paths.";
		},
		(in Diag.NeedsSinglePath x) {
			if (x.actual == 0)
				writer ~= "This command needs a path.";
			else {
				writer ~= "This command expects a single path. Instead got ";
				writer ~= x.actual;
				writer ~= '.';
			}
		},
		(in Diag.ParseFilePath x) {
			writer ~= "Not a valid file path: ";
			writeQuotedString(writer, x.actual);
			writer ~= '.';
		},
		(in Diag.PrintKind) {
			writer ~= "Not a valid print command.";
		},
		(in Diag.UnexpectedPart x) {
			writer ~= "Unexpected argument ";
			writeQuotedString(writer, x.tag);
			writer ~= '.';
		},
		(in Diag.UnexpectedPartArgs x) {
			writer ~= "Argument ";
			writeQuotedString(writer, x.part.tag);
			writer ~= " is a flag and should not have any values (starting with ";
			writeQuotedString(writer, x.part.args[0]);
			writer ~= ".";
		},
		(in Diag.UnexpectedBefore x) {
			writer ~= "*Unexpected un-named argument ";
			writeQuotedString(writer, x.arg);
			writer ~= '.';
		},
		(in Diag.RunArgNotSupportedInNodeJs x) {
			writer ~= "Running with node.js does not support the '";
			writer ~= x.arg;
			writer ~= "' option.";
		},
		(in Diag.RunKindIncompatible x) {
			writer ~= "Can not specify both ";
			withBuildStackArray!(void, string)(
				(ref StackArrayBuilder!string out_) {
					if (x.aot) out_ ~= "aot";
					if (x.jit) out_ ~= "jit";
					if (x.nodeJs) out_ ~= "nodeJs";
				},
				(scope string[] kinds) {
					writeWithCommasAndAnd!string(writer, kinds, (in string kind) {
						writer ~= "'--";
						writer ~= kind;
						writer ~= "'";
					});
				});
		},
		(in Diag.RunOptimizeNeedsAotOrJit) {
			writer ~= "'--optimize' must be combined with '--aot' or '--jit'.";
		});
}

void writeExtension(scope ref Writer writer, Extension a) {
	if (a == Extension.none)
		writer ~= "extensionless";
	else {
		writer ~= "\".";
		writer ~= stringOfEnum(a);
		writer ~= '"';
	}
}

CommandKind parseCommandKind(
	ref Alloc alloc,
	FilePath cwd,
	OS os,
	CommandName commandName,
	SplitArgs args,
	scope ref Diags diags,
) {
	final switch (commandName) {
		case CommandName.build:
			return parseBuildCommand(alloc, cwd, diags, os, args);
		case CommandName.check:
			expectEmptyParts(diags, args.parts);
			expectEmptyAfterDashDash(diags, args.afterDashDash);
			return CommandKind(CommandKind.Check(parseRootUris(alloc, cwd, diags, args.beforeFirstPart)));
		case CommandName.document:
			expectEmptyParts(diags, args.parts);
			expectEmptyAfterDashDash(diags, args.afterDashDash);
			return CommandKind(CommandKind.Document(parseRootUris(alloc, cwd, diags, args.beforeFirstPart)));
		case CommandName.lsp:
			expectAllEmpty(diags, args);
			return CommandKind(CommandKind.Lsp());
		case CommandName.print:
			return parsePrintCommand(alloc, cwd, diags, args);
		case CommandName.run:
			RunOptions options = parseRunOptions(alloc, os, diags, args.parts);
			return CommandKind(CommandKind.Run(
				parseMainUri(alloc, cwd, diags, args.beforeFirstPart),
				options,
				optOrDefault!(CString[])(castNonScope(args.afterDashDash), () => typeAs!(CString[])([]))));
		case CommandName.test:
			expectEmptyParts(diags, args.parts);
			expectEmptyAfterDashDash(diags, args.afterDashDash);
			return CommandKind(CommandKind.Test(copyArray(alloc, args.beforeFirstPart)));
		case CommandName.version_:
			expectAllEmpty(diags, args);
			return CommandKind(CommandKind.Version());
	}
}

void expectAllEmpty(scope ref Diags diags, in SplitArgs args) {
	expectEmptyBefore(diags, args.beforeFirstPart);
	expectEmptyParts(diags, args.parts);
	expectEmptyAfterDashDash(diags, args.afterDashDash);
}

void expectEmptyBefore(scope ref Diags diags, in CString[] before) {
	if (!isEmpty(before))
		diags ~= Diag(Diag.UnexpectedBefore(before[0]));
}
void expectEmptyParts(scope ref Diags diags, in ArgsPart[] parts) {
	foreach (ArgsPart part; parts)
		diags ~= Diag(Diag.UnexpectedPart(part.tag));
}
void expectEmptyAfterDashDash(scope ref Diags diags, in Opt!(CString[]) after) {
	if (has(after))
		diags ~= Diag(Diag.UnexpectedPart(cString!"--"));
}

public Extension defaultExecutableExtension(OS os) {
	final switch (os) {
		case OS.linux:
			return Extension.none;
		case OS.nodeJs:
		case OS.web:
			assert(false);
		case OS.windows:
			return Extension.exe;
	}
}

Uri parseMainUri(ref Alloc alloc, FilePath cwd, scope ref Diags diags, in CString[] args) {
	if (args.length != 1) {
		diags ~= Diag(Diag.NeedsSinglePath(args.length));
		return toUri(cwd); // dummy return value
	} else
		return parseCrowUri(alloc, cwd, diags, only(args));
}

Uri parseCrowUri(ref Alloc alloc, FilePath cwd, scope ref Diags diags, CString arg) {
	string argStr = stringOfCString(arg);
	Uri uri = parseUriWithCwd(cwd, argStr);
	if (getExtension(uri) != Extension.crow)
		diags ~= Diag(Diag.ExpectedCrowUri(argStr));
	return uri;
}

Uri[] parseRootUris(ref Alloc alloc, FilePath cwd, scope ref Diags diags, in CString[] args) {
	if (isEmpty(args))
		diags ~= Diag(Diag.ExpectedPaths(none!CString));
	return map(alloc, args, (ref CString arg) =>
		parseCrowUri(alloc, cwd, diags, arg));
}

CommandKind parsePrintCommand(ref Alloc alloc, FilePath cwd, scope ref Diags diags, in SplitArgs args) {
	expectEmptyParts(diags, args.parts);
	expectEmptyAfterDashDash(diags, args.afterDashDash);
	Opt!PrintKind kind = args.beforeFirstPart.length >= 2
		? parsePrintKind(args.beforeFirstPart[0], args.beforeFirstPart[2 .. $])
		: none!PrintKind;
	if (has(kind))
		return CommandKind(CommandKind.Print(force(kind), parseCrowUri(alloc, cwd, diags, args.beforeFirstPart[1])));
	else {
		diags ~= Diag(Diag.PrintKind());
		return dummyCommand;
	}
}

Opt!PrintKind parsePrintKind(in CString a, in CString[] args) {
	Opt!PrintKind expectEmptyArgs(PrintKind x) =>
		isEmpty(args) ? some(x) : none!PrintKind;

	Opt!PrintKind expectLineAndColumn(in PrintKind delegate(in LineAndColumn) @safe @nogc pure nothrow cb) {
		Opt!LineAndColumn lc = args.length == 1 ? parseLineAndColumn(args[0]) : none!LineAndColumn;
		return has(lc) ? some(cb(force(lc))) : none!PrintKind;
	}

	switch (stringOfCString(a)) {
		case "tokens":
			return expectEmptyArgs(PrintKind(PrintKind.Tokens()));
		case "ast":
			return expectEmptyArgs(PrintKind(PrintKind.Ast()));
		case "model":
			return expectEmptyArgs(PrintKind(PrintKind.Model()));
		case "concrete-model":
			return expectEmptyArgs(PrintKind(PrintKind.ConcreteModel()));
		case "low-model":
			return expectEmptyArgs(PrintKind(PrintKind.LowModel()));
		default:
			Opt!(PrintKind.Ide.Kind) kind = ideKind(stringOfCString(a));
			return has(kind)
				? expectLineAndColumn((in LineAndColumn lc) => PrintKind(PrintKind.Ide(force(kind), lc)))
				: none!PrintKind;
	}
}
Opt!(PrintKind.Ide.Kind) ideKind(in string a) {
	switch (a) {
		case "completion":
			return some(PrintKind.Ide.Kind.completion);
		case "definition":
			return some(PrintKind.Ide.Kind.definition);
		case "document-highlight":
			return some(PrintKind.Ide.Kind.documentHighlight);
		case "hover":
			return some(PrintKind.Ide.Kind.hover);
		case "references":
			return some(PrintKind.Ide.Kind.references);
		case "rename":
			return some(PrintKind.Ide.Kind.rename);
		case "signature-help":
			return some(PrintKind.Ide.Kind.signatureHelp);
		case "type-definition":
			return some(PrintKind.Ide.Kind.typeDefinition);
		default:
			return none!(PrintKind.Ide.Kind);
	}
}

public Opt!LineAndColumn parseLineAndColumn(in CString a) { // move? --------------------------------------------------------
	MutCString ptr = a;
	Opt!uint line = convertFrom1Indexed(tryTakeNat(ptr));
	bool colon = tryTakeChar(ptr, ':');
	Opt!uint column = convertFrom1Indexed(tryTakeNat(ptr));
	return has(line) && colon && has(column) && *ptr == '\0'
		? some(LineAndColumn(force(line), force(column)))
		: none!LineAndColumn;
}

Opt!uint convertFrom1Indexed(in Opt!uint a) =>
	has(a) && force(a) != 0
		? some(force(a) - 1)
		: none!uint;

Opt!uint tryTakeNat(ref MutCString ptr) {
	if (isDecimalDigit(*ptr)) {
		NatAndOverflow res = takeNat(ptr, 10);
		return !res.overflow && isUint(res.value)
			? some(safeToUint(res.value))
			: none!uint;
	} else
		return none!uint;
}

CommandKind parseBuildCommand(ref Alloc alloc, FilePath cwd, scope ref Diags diags, OS os, in SplitArgs args) {
	expectEmptyAfterDashDash(diags, args.afterDashDash);
	Uri main = parseMainUri(alloc, cwd, diags, args.beforeFirstPart);
	return CommandKind(CommandKind.Build(
		main,
		parseBuildOptions(alloc, cwd, diags, os, args.parts, main)));
}

RunOptions parseRunOptions(ref Alloc alloc, OS os, scope ref Diags diags, in ArgsPart[] argParts) {
	bool noStackTrace = false;
	bool aot = false;
	bool jit = false;
	bool nodeJs = false;
	bool optimize = false;
	bool singleThreaded = false;
	foreach (ArgsPart part; argParts) {
		expectFlag(diags, part);
		switch (stringOfCString(part.tag)) {
			case "--no-stack-trace":
				if (noStackTrace) diags ~= Diag(Diag.DuplicatePart(part.tag));
				noStackTrace = true;
				break;
			case "--aot":
				if (aot) diags ~= Diag(Diag.DuplicatePart(part.tag));
				aot = true;
				break;
			case "--jit":
				if (jit) diags ~= Diag(Diag.DuplicatePart(part.tag));
				jit = true;
				break;
			case "--node-js":
				if (nodeJs) diags ~= Diag(Diag.DuplicatePart(part.tag));
				nodeJs = true;
				break;
			case "--optimize":
				if (optimize) diags ~= Diag(Diag.DuplicatePart(part.tag));
				optimize = true;
				break;
			case "--single-threaded":
				if (singleThreaded) diags ~= Diag(Diag.DuplicatePart(part.tag));
				singleThreaded = true;
				break;
			default:
				diags ~= Diag(Diag.UnexpectedPart(part.tag));
		}
	}

	if ((uint(aot) + jit + nodeJs) > 1)
		diags ~= Diag(Diag.RunKindIncompatible(aot: aot, jit: jit, nodeJs: nodeJs));
	if (!aot && !jit && optimize)
		diags ~= Diag(Diag.RunOptimizeNeedsAotOrJit());
	if (nodeJs && (singleThreaded || optimize || noStackTrace))
		diags ~= Diag(Diag.RunArgNotSupportedInNodeJs(
			singleThreaded ? "--single-threaded" : optimize ? "--optimize" : "--no-stack-trace"));

	VersionOptions version_ = VersionOptions(isSingleThreaded: singleThreaded, stackTraceEnabled: !noStackTrace);
	return aot
		? RunOptions(RunOptions.Aot(
			version_,
			CCompileOptions(optimize ? OptimizationLevel.o2 : OptimizationLevel.none, CVersion.c11)))
		: jit
		? RunOptions(RunOptions.Jit(version_, optimize ? JitOptions(OptimizationLevel.o2) : JitOptions()))
		: nodeJs
		? RunOptions(RunOptions.NodeJs())
		: RunOptions(RunOptions.Interpret(version_));
}

void expectFlag(scope ref Diags diags, ArgsPart part) {
	if (!isEmpty(part.args))
		diags ~= Diag(Diag.UnexpectedPartArgs(part));
}

BuildOptions parseBuildOptions(
	ref Alloc alloc,
	FilePath cwd,
	scope ref Diags diags,
	OS os,
	in ArgsPart[] argParts,
	Uri mainUri,
) {
	SingleBuildOutput[] out_;
	bool optimize = false;
	bool c99 = false;
	bool noStackTrace = false;
	bool singleThreaded = false;
	foreach (ArgsPart part; argParts) {
		switch (stringOfCString(part.tag)) {
			case "--c99":
				if (c99)
					diags ~= Diag(Diag.DuplicatePart(part.tag));
				c99 = true;
				break;
			case "--no-stack-trace":
				if (noStackTrace) diags ~= Diag(Diag.DuplicatePart(part.tag));
				noStackTrace = true;
				break;
			case "--out":
				if (!isEmpty(out_))
					diags ~= Diag(Diag.DuplicatePart(part.tag));
				else
					out_ = parseBuildOut(alloc, cwd, os, diags, part);
				break;
			case "--optimize":
				expectFlag(diags, part);
				if (optimize)
					diags ~= Diag(Diag.DuplicatePart(part.tag));
				optimize = true;
				break;
			case "--single-threaded":
				expectFlag(diags, part);
				if (singleThreaded)
					diags ~= Diag(Diag.DuplicatePart(part.tag));
				singleThreaded = true;
				break;
			default:
				diags ~= Diag(Diag.UnexpectedPart(part.tag));
		}
	}

	SingleBuildOutput[] resOut = !isEmpty(out_)
		? out_
		: newArray(alloc, [
			SingleBuildOutput(SingleBuildOutput.Kind.executable, defaultExecutablePath(
				uriIsFile(mainUri) ? asFilePath(mainUri) : cwd / symbol!"main",
				os))]);
	return BuildOptions(
		VersionOptions(isSingleThreaded: singleThreaded, stackTraceEnabled: !noStackTrace),
		resOut,
		CCompileOptions(
			optimize ? OptimizationLevel.o2 : OptimizationLevel.none,
			c99 ? CVersion.c99 : CVersion.c11));
}

SingleBuildOutput[] parseBuildOut(ref Alloc alloc, FilePath cwd, OS os, scope ref Diags diags, ArgsPart part) {
	if (isEmpty(part.args))
		diags ~= Diag(Diag.ExpectedPaths(some(part.tag)));
	return buildArray!SingleBuildOutput(alloc, (scope ref Builder!SingleBuildOutput out_) {
		foreach (CString arg; part.args) {
			Opt!SingleBuildOutput output = parseSingleBuildOut(cwd, os, diags, arg);
			if (has(output))
				out_ ~= force(output);
		}
	});
}

Opt!SingleBuildOutput parseSingleBuildOut(FilePath cwd, OS os, scope ref Diags diags, in CString arg) {
	Opt!PrefixAndRest optPrefix = trySplit(arg, ':');
	if (has(optPrefix)) {
		PrefixAndRest pr = force(optPrefix);
		FilePath path = parseFilePathWithCwdOrDiag(diags, cwd, pr.rest);
		Opt!(SingleBuildOutput.Kind) kind = buildKindFromPrefix(pr.prefix, getExtension(path));
		if (has(kind))
			return some(SingleBuildOutput(force(kind), path));
		else {
			diags ~= Diag(Diag.BuildOutBadPrefix(pr.prefix));
			return none!SingleBuildOutput;
		}
	} else {
		FilePath path = parseFilePathWithCwdOrDiag(diags, cwd, arg);
		Opt!(SingleBuildOutput.Kind) kind = buildKindFromExtension(getExtension(path), os);
		if (has(kind))
			return some(SingleBuildOutput(force(kind), path));
		else {
			diags ~= Diag(Diag.BuildOutBadFileExtension(defaultExecutableExtension(os)));
			return none!SingleBuildOutput;
		}
	}
}

Opt!(SingleBuildOutput.Kind) buildKindFromPrefix(in string prefix, Extension extension) {
	switch (prefix) {
		case "js":
			return some(extension == Extension.js
				? SingleBuildOutput.Kind.jsScript
				: SingleBuildOutput.Kind.jsModules);
		case "node-js":
			return some(extension == Extension.js
				? SingleBuildOutput.Kind.nodeJsScript
				: SingleBuildOutput.Kind.nodeJsModules);
		default:
			return none!(SingleBuildOutput.Kind);
	}
}
Opt!(SingleBuildOutput.Kind) buildKindFromExtension(Extension extension, OS os) {
	switch (extension) {
		case Extension.c:
			return some(SingleBuildOutput.Kind.c);
		case Extension.js:
			return some(SingleBuildOutput.Kind.jsScript);
		default:
			return optIf(extension == defaultExecutableExtension(os), () =>
				SingleBuildOutput.Kind.executable);
	}
}


FilePath parseFilePathWithCwdOrDiag(scope ref Diags diags, FilePath cwd, in CString arg) =>
	optOrDefault!FilePath(parseFilePathWithCwd(cwd, arg), () {
		diags ~= Diag(Diag.ParseFilePath(arg));
		return cwd / symbol!"bogus";
	});

public FilePath defaultExecutablePath(FilePath base, OS os) =>
	alterExtension(base, defaultExecutableExtension(os));

immutable struct ArgsPart {
	CString tag; // includes the "--"
	CString[] args;
}

immutable struct SplitArgs {
	CString[] beforeFirstPart;
	ArgsPart[] parts;
	// After seeing a '--' we stop parsing and just return the rest raw.
	Opt!(CString[]) afterDashDash;
}

immutable struct SplitArgsAndOptions {
	SplitArgs args;
	CommandOptions options;
	bool help;
}

SplitArgsAndOptions splitArgs(ref Alloc alloc, return scope CString[] args) {
	Opt!size_t optFirstArgIndex = findIndex!CString(args, (in CString arg) =>
		startsWithDashDash(arg));
	if (!has(optFirstArgIndex))
		return SplitArgsAndOptions(SplitArgs(args, [], none!(CString[])), CommandOptions(perf: false));
	else {
		size_t firstArgIndex = force(optFirstArgIndex);
		Opt!size_t dashDash = findIndex!CString(args[firstArgIndex .. $], (in CString arg) =>
			arg == "--");
		NamedArgs namedArgs = splitNamedArgs(
			alloc, has(dashDash) ? args[firstArgIndex .. firstArgIndex + force(dashDash)] : args[firstArgIndex .. $]);
		return SplitArgsAndOptions(
			SplitArgs(
				args[0 .. firstArgIndex],
				namedArgs.parts,
				has(dashDash) ? some(args[firstArgIndex + force(dashDash) + 1 .. $]) : none!(CString[])),
			namedArgs.options,
			namedArgs.help);
	}
}

bool startsWithDashDash(in CString a) =>
	startsWith(a, "--");

struct NamedArgs {
	ArgsPart[] parts;
	CommandOptions options;
	bool help;
}

NamedArgs splitNamedArgs(ref Alloc alloc, in CString[] args) {
	bool help = false;
	bool perf = false;
	ArgsPart[] parts = buildArray!ArgsPart(alloc, (scope ref Builder!ArgsPart res) {
		assert(isEmpty(args) || startsWithDashDash(args[0]));
		MutOpt!size_t curPartStart;

		void finishPart(size_t i) {
			if (has(curPartStart)) {
				res ~= ArgsPart(args[force(curPartStart)], args[force(curPartStart) + 1 .. i]);
				curPartStart = noneMut!size_t;
			}
		}

		foreach (size_t i, CString arg; args) {
			if (startsWithDashDash(arg)) {
				finishPart(i);
				if (arg == "--help")
					help = true;
				else if (arg == "--perf")
					perf = true;
				else
					curPartStart = someMut(i);
			}
		}
		finishPart(args.length);
	});
	return NamedArgs(parts, CommandOptions(perf), help);
}

string helpAllText(ref Alloc alloc) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= "Command must be one of:" ~
			"\n\tcrow hello.crow (or any '.crow' file)";
		enumEach!CommandName((CommandName name) {
			if (!isInternalCommand(name)) {
				writer ~= "\n\t";
				writeCommand(writer, name);
			}
		});
		writer ~= ".\nFor more info, run e.g. 'crow build --help'.";
	});

bool isInternalCommand(CommandName name) {
	final switch (name) {
		case CommandName.build:
		case CommandName.check:
		case CommandName.document:
		case CommandName.lsp:
		case CommandName.run:
		case CommandName.version_:
			return false;
		case CommandName.print:
		case CommandName.test:
			return true;
	}
}

string helpForCommand(ref Alloc alloc, CommandName name) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writeHelpForCommand(writer, name);
	});

void writeHelpForCommand(scope ref Writer writer, CommandName name) {
	writer ~= "Command: ";
	writeCommand(writer, name);
	writer ~= "\n\n";
	writer ~= commandDescription(name);
}

void writeCommand(scope ref Writer writer, CommandName name) {
	writer ~= "crow ";
	writer ~= stringOfEnum(name);
	string options = describeCommandOptions(name);
	if (!isEmpty(options)) {
		writer ~= ' ';
		writer ~= options;
	}
}

string describeCommandOptions(CommandName name) {
	final switch (name) {
		case CommandName.build:
			return "PATH [--out PATH] [--optimize]";
		case CommandName.check:
			return "PATHS";
		case CommandName.document:
			return "PATHS";
		case CommandName.lsp:
			return "";
		case CommandName.print:
			return "[kind] PATH [LINE:COLUMN]";
		case CommandName.run:
			return "PATH [--aot] [--optimize] -- [program-args]";
		case CommandName.test:
			return "[name]";
		case CommandName.version_:
			return "";
	}
}

string commandDescription(CommandName name) {
	final switch (name) {
		case CommandName.build:
			return "Compiles the program at PATH." ~
				"\nOptions are:" ~
				"\n\t--out : Output path. Defaults to the input path with the extension changed." ~
				"\n\t\tIf this has a '.c' extension, it will output C source code instead." ~
				"\n\t--optimize : Enables optimizations." ~
				"\n\t--c99 : Compile to C99. (Default is C11 which is less verbose.)" ~
				buildRunCommonOptions;
		case CommandName.check:
			return "Prints any diagnostics for the module(s) at PATH(s) or their imports.\nNo options.";
		case CommandName.document:
			return "Generates JSON documentation for the module(s) at PATH(s).\nNo options.";
		case CommandName.lsp:
			return "This runs the Language Server Protocol through stdin/stdout.\nNo options.";
		case CommandName.print:
			return "Internal command for debugging. This should be one of:" ~
				"\ncrow print tokens PATH" ~
				"\ncrow print ast PATH" ~
				"\ncrow print model PATH" ~
				"\ncrow print concrete-model PATH" ~
				"\ncrow print low-model PATH" ~
				"\ncrow print hover PATH LINE:COLUMN" ~
				"\ncrow print definition PATH LINE:COLUMN" ~
				"\ncrow print document-highlight PATH LINE:COLUMN" ~
				"\ncrow print rename PATH LINE:COLUMN" ~
				"\ncrow print references PATH LINE:COLUMN" ~
				"\ncrow print signature-help PATH LINE:COLUMN" ~
				"\ncrow print type-definition PATH LINE:COLUMN";
		case CommandName.run:
			return "Runs the program at PATH." ~
				"\nArguments after '--' will be sent to the program." ~
				"\nOptions are:\n" ~
				"\n\t--aot : Instead of interpreting the program, builds an executable, runs it, then deletes it." ~
				"\n\t--optimize : Use with '--aot'. Enables optimizations." ~
				buildRunCommonOptions ~
				"\nWith no options, 'crow run foo.crow' is equivalent to 'crow foo.crow'.";
		case CommandName.test:
			return "Internal command to run unit tests." ~
				"\nIt optionally takes the name of the test suite to run (see 'test.d' for a list).";
		case CommandName.version_:
			return "Prints information about the version of 'crow'.\nNo options.";
	}
}

enum buildRunCommonOptions =
	"\n\t--single-threaded : See documentation for 'is-single-threaded' in 'crow/version'." ~
	"\n\t--no-stack-trace : See documentation for 'is-stack-trace-enabled' in 'crow/version'.";
