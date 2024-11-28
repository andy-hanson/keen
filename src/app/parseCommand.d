module app.parseCommand;

@safe @nogc pure nothrow:

import app.command :
	AotRunOptions,
	BuildCommand,
	BuildOptions,
	CheckCommand,
	Command,
	CommandKind,
	CommandOptions,
	DocumentCommand,
	HelpCommand,
	InterpretRunOptions,
	JitRunOptions,
	LspCommand,
	NodeJsRunOptions,
	PrintCommand,
	RunCommand,
	RunOptions,
	SelfTestCommand,
	SingleBuildOutput,
	SingleBuildOutputKind,
	VersionCommand;
import frontend.lang : CCompileOptions, CVersion, FileType, fileType, JitOptions, MainKind, OptimizationLevel;
import frontend.parse.lexToken : NatAndOverflow, takeNat;
import lib.server :
	PrintAst,
	PrintConcreteModel,
	PrintIdeAtPos,
	PrintIdeAtPosKind,
	PrintIdeWholeFile,
	PrintKind,
	PrintLowModel,
	PrintModel;
import model.sourceRange : LineAndColumn;
import util.alloc.alloc : Alloc;
import util.alloc.stackAlloc : StackArrayBuilder, withBuildStackArray;
import util.col.array : copyArray, findIndex, isEmpty, map, newArray, only;
import util.col.arrayBuilder : buildArray, Builder, finish;
import util.conv : isUint, safeToUint;
import util.exitCode : ExitCode;
import util.opt : force, has, MutOpt, none, noneMut, Opt, optIf, optOrDefault, some, someMut;
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
			CommandKind(RunCommand(
				MainKind.fun(parseUriWithCwd(cwd, arg0), args[1 .. $]),
				RunOptions(InterpretRunOptions(fakeExtern: false, version_: VersionOptions.default_)))),
			CommandOptions()) ;
	else {
		Opt!CommandName optName = commandName(arg0);
		return has(optName)
			? parseCommandFromName(alloc, cwd, os, force(optName), args[1 .. $])
			: Command(
				CommandKind(HelpCommand(
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
			CommandKind(HelpCommand(helpForCommand(alloc, name), ExitCode.ok)),
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
			return Command(CommandKind(HelpCommand(help, ExitCode.error)), split.options);
		}
	}
}

CommandKind dummyCommand() =>
	CommandKind(HelpCommand("This should not appear", ExitCode.error));

enum CommandName {
	build,
	check,
	document,
	lsp,
	print,
	run,
	selfTest,
	test,
	version_,
}
Opt!CommandName commandName(in string a) {
	Opt!CommandName res = optEnumOfString!CommandName(a);
	return has(res) ? res : a == "self-test" ? some(CommandName.selfTest) : res;
}

// We always combine this with the commandName, so no need to include it here
immutable struct Diag {
	mixin Union!(
		BuildOutBadFileExtension,
		BuildOutBadPrefix,
		DuplicatePart,
		ExpectedCrowUri,
		ExpectedNat,
		ExpectedPaths,
		NeedsSinglePath,
		ParseFilePath,
		PrintKindInvalid,
		RedundantPart,
		RunArgNotSupportedInNodeJs,
		RunKindIncompatible,
		RunOptimizeNeedsAotOrJit,
		TestLineNumberInvalid,
		UnexpectedPart,
		UnexpectedPartArgs,
		UnexpectedBefore);
}
alias Diags = Builder!Diag;

immutable struct BuildOutBadFileExtension {
	Extension executableExtension;
}
immutable struct BuildOutBadPrefix { string prefix; }
immutable struct DuplicatePart { CString tag; }
immutable struct ExpectedCrowUri { string actual; }
immutable struct ExpectedNat { string actual; }
immutable struct ExpectedPaths { Opt!CString tag; }
immutable struct NeedsSinglePath { size_t actual; }
immutable struct ParseFilePath { CString actual; }
immutable struct PrintKindInvalid {}
immutable struct RedundantPart {
	CString redundantTag;
	CString otherTag; // This causes the redundantTag to be redundant
}
immutable struct RunArgNotSupportedInNodeJs {
	string arg;
}
immutable struct RunKindIncompatible {
	bool aot;
	bool jit;
	bool nodeJs;
}
immutable struct RunOptimizeNeedsAotOrJit {}
immutable struct TestLineNumberInvalid {}
immutable struct UnexpectedPart { CString tag; }
immutable struct UnexpectedPartArgs { ArgsPart part; }
immutable struct UnexpectedBefore { CString arg; }

void writeDiag(scope ref Writer writer, in Diag a) {
	a.matchIn!void(
		(in BuildOutBadFileExtension x) {
			writer ~= "Build output must be a '.c', '.js', or ";
			writeExtension(writer, x.executableExtension);
			writer ~= " file.";
		},
		(in BuildOutBadPrefix x) {
			writer ~= "Unrecognized output prefix ";
			writeQuotedString(writer, x.prefix);
			writer ~= ". An output can start with 'js:' or 'node-js:'.";
		},
		(in DuplicatePart x) {
			writer ~= "Argument ";
			writeQuotedString(writer, x.tag);
			writer ~= " appears twice.";
		},
		(in ExpectedCrowUri x) {
			writer ~= "Expected path to a '.crow' file, instead got ";
			writeQuotedString(writer, x.actual);
			writer ~= '.';
		},
		(in ExpectedNat x) {
			writer ~= "Expected argument to be a natural number, instead got ";
			writeQuotedString(writer, x.actual);
			writer ~= '.';
		},
		(in ExpectedPaths x) {
			if (has(x.tag)) {
				writer ~= "Argument ";
				writeQuotedString(writer, force(x.tag));
				writer ~= " expects a list of paths.";
			} else
				writer ~= "This command expects a list of paths.";
		},
		(in NeedsSinglePath x) {
			if (x.actual == 0)
				writer ~= "This command needs a path.";
			else {
				writer ~= "This command expects a single path. Instead got ";
				writer ~= x.actual;
				writer ~= '.';
			}
		},
		(in ParseFilePath x) {
			writer ~= "Not a valid file path: ";
			writeQuotedString(writer, x.actual);
			writer ~= '.';
		},
		(in PrintKindInvalid _) {
			writer ~= "Not a valid print command.";
		},
		(in RedundantPart x) {
			writer ~= "'";
			writer ~= x.redundantTag;
			writer ~= " is redundant given ";
			writer ~= "'";
			writer ~= x.otherTag;
			writer ~= "'.";
		},
		(in RunArgNotSupportedInNodeJs x) {
			writer ~= "Running with node.js does not support the '";
			writer ~= x.arg;
			writer ~= "' option.";
		},
		(in RunKindIncompatible x) {
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
		(in RunOptimizeNeedsAotOrJit _) {
			writer ~= "'--optimize' must be combined with '--aot' or '--jit'.";
		},
		(in TestLineNumberInvalid _) {
			writer ~= "Specifying a test line number only works when there is a single test file.";
		},
		(in UnexpectedPart x) {
			writer ~= "Unexpected argument ";
			writeQuotedString(writer, x.tag);
			writer ~= '.';
		},
		(in UnexpectedPartArgs x) {
			writer ~= "Argument ";
			writeQuotedString(writer, x.part.tag);
			writer ~= " is a flag and should not have any values (starting with ";
			writeQuotedString(writer, x.part.args[0]);
			writer ~= ".";
		},
		(in UnexpectedBefore x) {
			writer ~= "*Unexpected un-named argument ";
			writeQuotedString(writer, x.arg);
			writer ~= '.';
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
			return CommandKind(CheckCommand(parseRootUris(alloc, cwd, diags, args.beforeFirstPart)));
		case CommandName.document:
			expectEmptyParts(diags, args.parts);
			expectEmptyAfterDashDash(diags, args.afterDashDash);
			return CommandKind(DocumentCommand(parseRootUris(alloc, cwd, diags, args.beforeFirstPart)));
		case CommandName.lsp:
			expectAllEmpty(diags, args);
			return CommandKind(LspCommand());
		case CommandName.print:
			return parsePrintCommand(alloc, cwd, diags, args);
		case CommandName.run:
			RunOptions options = parseRunOptions(alloc, os, diags, args.parts, allowAll: false).runOptions;
			return CommandKind(RunCommand(
				MainKind.fun(
					parseMainUri(alloc, cwd, diags, args.beforeFirstPart),
					optOrDefault!(CString[])(castNonScope(args.afterDashDash), () => typeAs!(CString[])([]))),
				options));
		case CommandName.selfTest:
			expectEmptyParts(diags, args.parts);
			expectEmptyAfterDashDash(diags, args.afterDashDash);
			return CommandKind(SelfTestCommand(copyArray(alloc, args.beforeFirstPart)));
		case CommandName.test:
			RunOptionsAndAll options = parseRunOptions(alloc, os, diags, args.parts, allowAll: true);
			expectEmptyAfterDashDash(diags, args.afterDashDash);
			return CommandKind(RunCommand(
				parseMainKindForTest(alloc, cwd, diags, args.beforeFirstPart, options.all),
				options.runOptions));
		case CommandName.version_:
			expectAllEmpty(diags, args);
			return CommandKind(VersionCommand());
	}
}

void expectAllEmpty(scope ref Diags diags, in SplitArgs args) {
	expectEmptyBefore(diags, args.beforeFirstPart);
	expectEmptyParts(diags, args.parts);
	expectEmptyAfterDashDash(diags, args.afterDashDash);
}

void expectEmptyBefore(scope ref Diags diags, in CString[] before) {
	if (!isEmpty(before))
		diags ~= Diag(UnexpectedBefore(before[0]));
}
void expectEmptyParts(scope ref Diags diags, in ArgsPart[] parts) {
	foreach (ArgsPart part; parts)
		diags ~= Diag(UnexpectedPart(part.tag));
}
void expectEmptyAfterDashDash(scope ref Diags diags, in Opt!(CString[]) after) {
	if (has(after))
		diags ~= Diag(UnexpectedPart(cString!"--"));
}

public Extension defaultExecutableExtension(OS os) {
	final switch (os) {
		case OS.linux:
			return Extension.none;
		case OS.nodeJs:
		case OS.none:
		case OS.web:
			assert(false);
		case OS.windows:
			return Extension.exe;
	}
}

MainKind parseMainKindForTest(ref Alloc alloc, FilePath cwd, scope ref Diags diags, in CString[] args, bool all) {
	Opt!uint line = args.length == 2
		? parseLine(args[1])
		: none!uint;

	if (args.length == 2 && !has(line))
		diags ~= Diag(ExpectedNat(stringOfCString(args[1])));

	if (args.length != 1 && args.length != 2) {
		diags ~= Diag(NeedsSinglePath(args.length));
		return MainKind.testsAtUri(false, Uri.empty, none!uint); // dummy return value
	} else {
		string argStr = stringOfCString(args[0]);
		Uri uri = parseUriWithCwd(cwd, argStr);
		final switch (fileType(uri)) {
			case FileType.crow:
				if (all && has(line))
					diags ~= Diag(TestLineNumberInvalid());
				return MainKind.testsAtUri(all, uri, line);
			case FileType.crowConfig:
				if (has(line))
					diags ~= Diag(TestLineNumberInvalid());
				return MainKind.testsInConfig(all, uri);
			case FileType.other:
				diags ~= Diag(ExpectedCrowUri(argStr));
				return MainKind.testsAtUri(false, Uri.empty, none!uint); // dummy return value
		}
	}
}

Uri parseMainUri(ref Alloc alloc, FilePath cwd, scope ref Diags diags, in CString[] args) {
	if (args.length != 1) {
		diags ~= Diag(NeedsSinglePath(args.length));
		return toUri(cwd); // dummy return value
	} else
		return parseCrowUri(alloc, cwd, diags, only(args));
}

Uri parseCrowUri(ref Alloc alloc, FilePath cwd, scope ref Diags diags, CString arg) {
	string argStr = stringOfCString(arg);
	Uri uri = parseUriWithCwd(cwd, argStr);
	if (getExtension(uri) != Extension.crow)
		diags ~= Diag(ExpectedCrowUri(argStr));
	return uri;
}

Uri[] parseRootUris(ref Alloc alloc, FilePath cwd, scope ref Diags diags, in CString[] args) {
	if (isEmpty(args))
		diags ~= Diag(ExpectedPaths(none!CString));
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
		return CommandKind(PrintCommand(force(kind), parseCrowUri(alloc, cwd, diags, args.beforeFirstPart[1])));
	else {
		diags ~= Diag(PrintKindInvalid());
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
		case "ast":
			return expectEmptyArgs(PrintKind(PrintAst()));
		case "model":
			return expectEmptyArgs(PrintKind(PrintModel()));
		case "concrete-model":
			return expectEmptyArgs(PrintKind(PrintConcreteModel()));
		case "low-model":
			return expectEmptyArgs(PrintKind(PrintLowModel()));
		default:
			Opt!(PrintIdeAtPosKind) kindAtPos = ideAtPosKind(stringOfCString(a));
			if (has(kindAtPos))
				return expectLineAndColumn((in LineAndColumn lc) =>
					PrintKind(PrintIdeAtPos(force(kindAtPos), lc)));
			else {
				Opt!PrintIdeWholeFile kindWholeFile = ideWholeFileKind(stringOfCString(a));
				return has(kindWholeFile)
					? expectEmptyArgs(PrintKind(PrintIdeWholeFile(force(kindWholeFile))))
					: none!PrintKind;
			}
	}
}
Opt!(PrintIdeAtPosKind) ideAtPosKind(in string a) {
	switch (a) {
		case "completion":
			return some(PrintIdeAtPosKind.completion);
		case "definition":
			return some(PrintIdeAtPosKind.definition);
		case "document-highlights":
			return some(PrintIdeAtPosKind.documentHighlight);
		case "hover":
			return some(PrintIdeAtPosKind.hover);
		case "implementation":
			return some(PrintIdeAtPosKind.implementation);
		case "references":
			return some(PrintIdeAtPosKind.references);
		case "rename":
			return some(PrintIdeAtPosKind.rename);
		case "signature-help":
			return some(PrintIdeAtPosKind.signatureHelp);
		case "type-definition":
			return some(PrintIdeAtPosKind.typeDefinition);
		default:
			return none!(PrintIdeAtPosKind);
	}
}
Opt!PrintIdeWholeFile ideWholeFileKind(in string a) {
	switch (a) {
		case "code-lenses":
			return some(PrintIdeWholeFile.codeLenses);
		case "folding-ranges":
			return some(PrintIdeWholeFile.foldingRanges);
		case "inlay-hints":
			return some(PrintIdeWholeFile.inlayHints);
		case "tokens":
			return some(PrintIdeWholeFile.tokens);
		default:
			return none!PrintIdeWholeFile;
	}
}

public Opt!LineAndColumn parseLineAndColumn(in CString a) {
	MutCString ptr = a;
	Opt!uint line = convertFrom1Indexed(tryTakeNat(ptr));
	bool colon = tryTakeChar(ptr, ':');
	Opt!uint column = convertFrom1Indexed(tryTakeNat(ptr));
	return optIf(has(line) && colon && has(column) && *ptr == '\0', () =>
		LineAndColumn(force(line), force(column)));
}
Opt!uint parseLine(in CString a) {
	MutCString ptr = a;
	Opt!uint line = convertFrom1Indexed(tryTakeNat(ptr));
	return *ptr == '\0' ? line : none!uint;
}

Opt!uint convertFrom1Indexed(in Opt!uint a) =>
	optIf(has(a) && force(a) != 0, () =>
		force(a) - 1);

Opt!uint tryTakeNat(ref MutCString ptr) {
	if (isDecimalDigit(*ptr)) {
		NatAndOverflow res = takeNat(ptr, 10);
		return optIf(!res.overflow && isUint(res.value), () =>
			safeToUint(res.value));
	} else
		return none!uint;
}

CommandKind parseBuildCommand(ref Alloc alloc, FilePath cwd, scope ref Diags diags, OS os, in SplitArgs args) {
	expectEmptyAfterDashDash(diags, args.afterDashDash);
	SingleBuildOutput[] out_;
	bool optimize = false;
	bool c99 = false;
	bool noStackTrace = false;
	bool singleThreaded = false;
	bool test = false;
	bool all = false;

	foreach (ArgsPart part; args.parts) {
		void setFlag(ref bool flag) {
			expectFlag(diags, part);
			if (flag)
				diags ~= Diag(DuplicatePart(part.tag));
			flag = true;
		}
		switch (stringOfCString(part.tag)) {
			case "--c99":
				setFlag(c99);
				break;
			case "--no-stack-trace":
				setFlag(noStackTrace);
				break;
			case "--out":
				if (!isEmpty(out_))
					diags ~= Diag(DuplicatePart(part.tag));
				else
					out_ = parseBuildOut(alloc, cwd, os, diags, part);
				break;
			case "--optimize":
				setFlag(optimize);
				break;
			case "--single-threaded":
				setFlag(singleThreaded);
				break;
			case "--test":
				setFlag(test);
				break;
			case "--all":
				setFlag(all);
				break;
			default:
				diags ~= Diag(UnexpectedPart(part.tag));
		}
	}

	if (all && !test)
		diags ~= Diag(UnexpectedPart(cString!"--all"));

	MainKind main = test
		? parseMainKindForTest(alloc, cwd, diags, args.beforeFirstPart, all: all)
		: MainKind.fun(parseMainUri(alloc, cwd, diags, args.beforeFirstPart), []);
	SingleBuildOutput[] resOut = !isEmpty(out_)
		? out_
		: newArray(alloc, [
			SingleBuildOutput(SingleBuildOutputKind.executable, defaultExecutablePathForMain(main, cwd, os))]);
	BuildOptions options = BuildOptions(
		VersionOptions(isSingleThreaded: singleThreaded, stackTraceEnabled: !noStackTrace),
		resOut,
		CCompileOptions(
			optimize ? OptimizationLevel.o2 : OptimizationLevel.none,
			c99 ? CVersion.c99 : CVersion.c11));
	return CommandKind(BuildCommand(main, options));
}

immutable struct RunOptionsAndAll {
	RunOptions runOptions;
	bool all;
}
RunOptionsAndAll parseRunOptions(ref Alloc alloc, OS os, scope ref Diags diags, in ArgsPart[] argParts, bool allowAll) {
	bool noStackTrace = false;
	bool aot = false;
	bool jit = false;
	bool nodeJs = false;
	bool optimize = false;
	bool singleThreaded = false;
	bool all = false;
	bool fakeExtern = false;
	foreach (ArgsPart part; argParts) {
		void setFlag(ref bool flag) {
			expectFlag(diags, part);
			if (flag)
				diags ~= Diag(DuplicatePart(part.tag));
			flag = true;
		}
		switch (stringOfCString(part.tag)) {
			case "--all":
				if (allowAll)
					setFlag(all);
				else
					diags ~= Diag(UnexpectedPart(part.tag));
				break;
			case "--aot":
				setFlag(aot);
				break;
			case "--fake-extern":
				setFlag(fakeExtern);
				break;
			case "--jit":
				setFlag(jit);
				break;
			case "--node-js":
				setFlag(nodeJs);
				break;
			case "--no-stack-trace":
				setFlag(noStackTrace);
				break;
			case "--optimize":
				setFlag(optimize);
				break;
			case "--single-threaded":
				setFlag(singleThreaded);
				break;
			default:
				diags ~= Diag(UnexpectedPart(part.tag));
		}
	}

	if (fakeExtern && (aot || jit || nodeJs))
		diags ~= Diag(UnexpectedPart(cString!"--fake-extern"));
	if (fakeExtern && singleThreaded)
		diags ~= Diag(RedundantPart(cString!"--single-threaded", cString!"--fake-extern"));
	if ((uint(aot) + jit + nodeJs) > 1)
		diags ~= Diag(RunKindIncompatible(aot: aot, jit: jit, nodeJs: nodeJs));
	if (!aot && !jit && optimize)
		diags ~= Diag(RunOptimizeNeedsAotOrJit());
	if (nodeJs && (singleThreaded || optimize || noStackTrace))
		diags ~= Diag(RunArgNotSupportedInNodeJs(
			singleThreaded ? "--single-threaded" : optimize ? "--optimize" : "--no-stack-trace"));

	VersionOptions version_ = VersionOptions(
		isSingleThreaded: fakeExtern || singleThreaded,
		stackTraceEnabled: !noStackTrace);
	RunOptions res = aot
		? RunOptions(AotRunOptions(
			version_,
			CCompileOptions(optimize ? OptimizationLevel.o2 : OptimizationLevel.none, CVersion.c11)))
		: jit
		? RunOptions(JitRunOptions(version_, optimize ? JitOptions(OptimizationLevel.o2) : JitOptions()))
		: nodeJs
		? RunOptions(NodeJsRunOptions())
		: RunOptions(InterpretRunOptions(fakeExtern, version_));
	return RunOptionsAndAll(res, all);
}

void expectFlag(scope ref Diags diags, ArgsPart part) {
	if (!isEmpty(part.args))
		diags ~= Diag(UnexpectedPartArgs(part));
}

SingleBuildOutput[] parseBuildOut(ref Alloc alloc, FilePath cwd, OS os, scope ref Diags diags, ArgsPart part) {
	if (isEmpty(part.args))
		diags ~= Diag(ExpectedPaths(some(part.tag)));
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
		Opt!SingleBuildOutputKind kind = buildKindFromPrefix(pr.prefix, getExtension(path));
		if (has(kind))
			return some(SingleBuildOutput(force(kind), path));
		else {
			diags ~= Diag(BuildOutBadPrefix(pr.prefix));
			return none!SingleBuildOutput;
		}
	} else {
		FilePath path = parseFilePathWithCwdOrDiag(diags, cwd, arg);
		Opt!SingleBuildOutputKind kind = buildKindFromExtension(getExtension(path), os);
		if (has(kind))
			return some(SingleBuildOutput(force(kind), path));
		else {
			diags ~= Diag(BuildOutBadFileExtension(defaultExecutableExtension(os)));
			return none!SingleBuildOutput;
		}
	}
}

Opt!SingleBuildOutputKind buildKindFromPrefix(in string prefix, Extension extension) {
	switch (prefix) {
		case "js":
			return some(extension == Extension.js
				? SingleBuildOutputKind.jsScript
				: SingleBuildOutputKind.jsModules);
		case "node-js":
			return some(extension == Extension.js
				? SingleBuildOutputKind.nodeJsScript
				: SingleBuildOutputKind.nodeJsModules);
		default:
			return none!SingleBuildOutputKind;
	}
}
Opt!SingleBuildOutputKind buildKindFromExtension(Extension extension, OS os) {
	switch (extension) {
		case Extension.c:
			return some(SingleBuildOutputKind.c);
		case Extension.js:
			return some(SingleBuildOutputKind.jsScript);
		default:
			return optIf(extension == defaultExecutableExtension(os), () =>
				SingleBuildOutputKind.executable);
	}
}

FilePath parseFilePathWithCwdOrDiag(scope ref Diags diags, FilePath cwd, in CString arg) =>
	optOrDefault!FilePath(parseFilePathWithCwd(cwd, arg), () {
		diags ~= Diag(ParseFilePath(arg));
		return cwd / symbol!"bogus";
	});

FilePath defaultExecutablePathForMain(MainKind main, FilePath cwd, OS os) =>
	defaultExecutablePath(
		uriIsFile(main.mainUriForAllArgs) ? asFilePath(main.mainUriForAllArgs) : cwd / symbol!"main",
		os);
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
		case CommandName.test:
		case CommandName.version_:
			return false;
		case CommandName.print:
		case CommandName.selfTest:
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
		case CommandName.selfTest:
			return "[name]";
		case CommandName.test:
			return "PATH [line number] [--all]";
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
				"\n\t--test: Ignore the 'main' function and compile a program that runs tests." ~
				"\n\t\t--all: Works with '--test'. Runs all tests in all included files." ~
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
				"\ncrow print ast PATH" ~
				"\ncrow print model PATH" ~
				"\ncrow print concrete-model PATH" ~
				"\ncrow print low-model PATH" ~
				"\n" ~
				"\ncrow print code-lenses PATH" ~
				"\ncrow print definition PATH LINE:COLUMN" ~
				"\ncrow print document-highlights PATH LINE:COLUMN" ~
				"\ncrow print folding-ranges PATH" ~
				"\ncrow print hover PATH LINE:COLUMN" ~
				"\ncrow print inlay-hints PATH" ~
				"\ncrow print references PATH LINE:COLUMN" ~
				"\ncrow print rename PATH LINE:COLUMN" ~
				"\ncrow print signature-help PATH LINE:COLUMN" ~
				"\ncrow print tokens PATH" ~
				"\ncrow print type-definition PATH LINE:COLUMN";
		case CommandName.run:
			return "Runs the program at PATH." ~
				"\nArguments after '--' will be sent to the program." ~
				"\nOptions are:\n" ~
				"\n\t--aot : Instead of interpreting the program, builds an executable, runs it, then deletes it." ~
				"\n\t--optimize : Use with '--aot'. Enables optimizations." ~
				buildRunCommonOptions ~
				"\nWith no options, 'crow run foo.crow' is equivalent to 'crow foo.crow'.";
		case CommandName.selfTest:
			return "Runs the 'crow' executable's internal tests." ~
				"\nIt optionally takes the name of the test suite to run (see 'test.d' for a list).";
		case CommandName.test:
			return "Runs tests at PATH." ~
				"\nIf PATH is a 'crow-config' file, searches its directory (recursively) for '.crow' files"~
					" that would have it as their config." ~
				"\nIf PATH is a file, runs tests in that file." ~
				"\nYou can also specify the line number of a 'test' keyword to run only that test." ~
				"\nIf '--all' is specified, runs all tests in reachable files, including library tests.";
		case CommandName.version_:
			return "Prints information about the version of 'crow'.\nNo options.";
	}
}

enum buildRunCommonOptions =
	"\n\t--single-threaded : See documentation for 'is-single-threaded' in 'crow/version'." ~
	"\n\t--no-stack-trace : See documentation for 'is-stack-trace-enabled' in 'crow/version'.";
