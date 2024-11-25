module app.command;

@safe @nogc pure nothrow:

import frontend.lang : CCompileOptions, JitOptions, MainKind;
import lib.server : PrintKind;
import model.model : BuildTarget;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : addIfNotContains, buildArray, Builder;
import util.string : CString;
import util.exitCode : ExitCode;
import util.union_ : Union;
import util.uri : FilePath, Uri;
import versionInfo : OS, VersionOptions;

immutable struct Command {
	CommandKind kind;
	CommandOptions options;
}

// options common to all commands
immutable struct CommandOptions {
	bool perf;
}

immutable struct CommandKind {
	mixin Union!(
		BuildCommand,
		CheckCommand,
		DocumentCommand,
		HelpCommand,
		LspCommand,
		PrintCommand,
		RunCommand,
		SelfTestCommand,
		VersionCommand);
}
immutable struct BuildCommand {
	MainKind main;
	BuildOptions options;
}
immutable struct CheckCommand {
	Uri[] rootUris;
}
immutable struct DocumentCommand {
	Uri[] rootUris;
}
// Used for either explicit '--help' or any error using CLI
immutable struct HelpCommand {
	string helpText;
	ExitCode exitCode;
}
immutable struct LspCommand {}
immutable struct PrintCommand {
	PrintKind kind;
	Uri mainUri;
}
immutable struct RunCommand {
	MainKind main;
	RunOptions options;
}
immutable struct SelfTestCommand {
	CString[] names;
}
immutable struct VersionCommand {}

immutable struct RunOptions {
	mixin Union!(AotRunOptions, InterpretRunOptions, JitRunOptions, NodeJsRunOptions);
}
immutable struct AotRunOptions {
	VersionOptions version_;
	CCompileOptions compileOptions;
}
immutable struct InterpretRunOptions {
	bool fakeExtern;
	VersionOptions version_;
}
immutable struct NodeJsRunOptions {}
immutable struct JitRunOptions {
	VersionOptions version_;
	JitOptions options;
}

bool isFakeExtern(in RunOptions a) =>
	a.isA!InterpretRunOptions && a.as!InterpretRunOptions.fakeExtern;

immutable struct BuildOptions {
	VersionOptions version_;
	SingleBuildOutput[] out_;
	CCompileOptions cCompileOptions;
}

immutable struct SingleBuildOutput {
	enum Kind { c, executable, jsScript, jsModules, nodeJsScript, nodeJsModules }
	Kind kind;
	FilePath path;
}

BuildTarget[] targetsForBuild(ref Alloc alloc, OS os, in BuildCommand x) =>
	buildArray!BuildTarget(alloc, (scope ref Builder!BuildTarget out_) {
		foreach (SingleBuildOutput output; x.options.out_)
			addIfNotContains!BuildTarget(out_, targetForBuildOutput(os, output.kind));
	});
private BuildTarget targetForBuildOutput(OS os, SingleBuildOutput.Kind a) {
	final switch (a) {
		case SingleBuildOutput.Kind.c:
		case SingleBuildOutput.Kind.executable:
			return BuildTarget.native(os);
		case SingleBuildOutput.Kind.jsScript:
		case SingleBuildOutput.Kind.jsModules:
		case SingleBuildOutput.Kind.nodeJsScript:
		case SingleBuildOutput.Kind.nodeJsModules:
			return BuildTarget.js;
	}
}
