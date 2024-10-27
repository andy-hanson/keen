module versionInfo;

@safe @nogc nothrow: // not pure

enum OS {
	none, // No capabilities in particular
	linux,
	nodeJs,
	web,
	windows,
}
enum JsTarget { browser, node }

OS getOS() {
	version (linux) {
		return OS.linux;
	} else version (Windows) {
		return OS.windows;
	} else version (WebAssembly) {
		return OS.web;
	} else
		static assert(false);
}

pure:

immutable struct VersionOptions {
	@safe @nogc pure nothrow:
	bool isSingleThreaded;
	bool stackTraceEnabled;

	static VersionOptions default_() =>
		VersionOptions(isSingleThreaded: false, stackTraceEnabled: true);
}

immutable struct VersionInfo {
	private:
	public OS os;
	VersionOptions options;
	public bool isInterpreted;
	bool isJit;
}

VersionInfo versionInfoForInterpret(OS os, VersionOptions options) =>
	VersionInfo(os: os, isInterpreted: true, options: options);

VersionInfo versionInfoForJIT(OS os, VersionOptions options) =>
	VersionInfo(os: os, isInterpreted: false, options: options);

VersionInfo versionInfoForBuildToC(OS os, VersionOptions options) =>
	VersionInfo(os: os, isInterpreted: false, options: options);

VersionInfo versionInfoForBuildToJS(JsTarget target) {
	OS jsOs = () {
		final switch (target) {
			case JsTarget.browser:
				return OS.web;
			case JsTarget.node:
				return OS.nodeJs;
		}
	}();
	return VersionInfo(jsOs, versionOptionsForJs(), isInterpreted: false);
}
private VersionOptions versionOptionsForJs() =>
	VersionOptions(isSingleThreaded: true, stackTraceEnabled: true);

enum VersionFun {
	isBigEndian,
	isInterpreted,
	isSingleThreaded,
	isStackTraceEnabled,
}

bool isVersion(in VersionInfo a, VersionFun fun) {
	final switch (fun) {
		case VersionFun.isBigEndian:
			version (BigEndian) {
				return true;
			} else {
				return false;
			}
		case VersionFun.isInterpreted:
			return a.isInterpreted;
		case VersionFun.isSingleThreaded:
			return a.options.isSingleThreaded;
		case VersionFun.isStackTraceEnabled:
			return a.options.stackTraceEnabled;
	}
}
