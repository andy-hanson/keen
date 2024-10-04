module app.fileSystem;

@safe @nogc nothrow: // not pure

import core.stdc.errno : ENOENT, errno;
import core.stdc.stdio : fclose, ferror, fflush, fgets, FILE, fopen, fread, fseek, ftell, fwrite, SEEK_END, SEEK_SET;
version (Windows) {} else {
	import core.stdc.stdio : posixStderr = stderr, posixStdin = stdin, posixStdout = stdout;
}
import core.stdc.string : strerror;
import std.conv : octal;

version (Windows) {
	import core.sys.windows.core :
		CloseHandle,
		CP_UTF8,
		CreatePipe,
		CreateProcessA,
		DeleteFileA,
		DWORD,
		ERROR_BROKEN_PIPE,
		ERROR_FILE_NOT_FOUND,
		ERROR_SHARING_VIOLATION,
		FILE_ATTRIBUTE_ARCHIVE,
		FILE_ATTRIBUTE_DIRECTORY,
		FILE_ATTRIBUTE_NORMAL,
		FormatMessageA,
		FORMAT_MESSAGE_FROM_SYSTEM,
		FORMAT_MESSAGE_IGNORE_INSERTS,
		GetExitCodeProcess,
		GetFileAttributesA,
		GetLastError,
		GetModuleFileNameA,
		GetModuleHandle,
		GetStdHandle,
		HANDLE,
		HANDLE_FLAG_INHERIT,
		HMODULE,
		INFINITE,
		INVALID_FILE_ATTRIBUTES,
		LPCSTR,
		PROCESS_INFORMATION,
		ReadFile,
		SearchPathA,
		SECURITY_ATTRIBUTES,
		SetConsoleOutputCP,
		SetHandleInformation,
		Sleep,
		STARTF_USESTDHANDLES,
		STARTUPINFOA,
		STD_ERROR_HANDLE,
		STD_OUTPUT_HANDLE,
		WaitForSingleObject,
		WriteFile;
} else {
	import core.sys.posix.dirent : closedir, DIR, dirent, opendir, readdir;
	import core.sys.posix.fcntl : O_CREAT, O_EXCL, open, O_TRUNC, O_WRONLY;
	import core.sys.posix.spawn : posix_spawn;
	import core.sys.posix.stdio : fdopen;
	import core.sys.posix.sys.wait : waitpid;
	import core.sys.posix.sys.stat : mkdir, mode_t, lstat, pid_t, S_IFDIR, S_IFMT, S_IFREG, stat_t;
	import core.sys.posix.unistd : getcwd, read, readlink, rmdir, unlink, write;
}

import backend.writeToC : PathAndArgs;
import frontend.storage : ReadFileResult;
import model.diag : ReadFileDiag;
import model.lowModel : ExternLibrary, ExternLibraries;
import util.alloc.alloc : Alloc, allocateElements;
import util.alloc.stackAlloc :
	StackArrayBuilder, withBuildStackArrayImpure, withConcatImpure, withExactStackArrayImpure;
import util.col.array : endPtr, exists, newArray, sum;
import util.col.exactSizeArrayBuilder : ExactSizeArrayBuilder, finish;
import util.col.tempSet : TempSet, tryAdd, withTempSetImpure;
import util.conv : safeToInt, safeToUint;
import util.exitCode : eachUntilError, ExitCode, ExitCodeOrSignal, okAnd, onError, Signal;
import util.memory : memset;
import util.opt : force, has, MutOpt, none, noneMut, Opt, some, someMut;
import util.string : CString, cString, stringOfCString;
import util.symbol : alterExtension, Extension, Symbol, symbol, symbolOfString;
import util.unicode : FileContent;
import util.uri :
	alterExtension,
	alterExtensionWithHex,
	asFilePath,
	baseName,
	concatFilePathAndPath,
	countComponents,
	FilePath,
	FilePermissions,
	parent,
	parseFilePath,
	Path,
	PathAndContent,
	Uri,
	uriIsFile,
	withCStringOfFilePath;
import util.util : castImmutable, castNonScope_ref, todo, typeAs;
import util.writer : withStackWriterImpure, withStackWriterImpureCString, Writer, writeWithSeparatorAndFilter;

private enum OutPipe { stdout = 1, stderr = 2 }

private FILE* stdin() {
	version (Windows) {
		return __acrt_iob_func(0);
	} else {
		return posixStdin;
	}
}

@system CString readLineFromStdin(scope char[] buffer) {
	char* res = fgets(buffer.ptr, safeToInt(buffer.length), stdin);
	assert(res != null);
	return CString(castImmutable(res));
}

@system void readExactFromStdin(scope char[] buffer) {
	size_t n = fread(buffer.ptr, char.sizeof, buffer.length, stdin);
	assert(n == buffer.length);
}

@trusted ExitCode print(in string a) {
	writeLn(OutPipe.stdout, a);
	return ExitCode.ok;
}

ExitCode printCb(in void delegate(scope ref Writer writer) @safe @nogc pure nothrow cb) =>
	withStackWriterImpure(cb, (in string x) => print(x));

@trusted ExitCode printError(in string a) {
	writeLn(OutPipe.stderr, a);
	return ExitCode.error;
}

ExitCode printErrorCb(in void delegate(scope ref Writer writer) @safe @nogc nothrow cb) =>
	withStackWriterImpure(cb, (in string x) => printError(x));

// Unlike 'print' this does *not* add a newline.
@system void writeToStdoutAndFlush(in string a) {
	writeString(OutPipe.stdout, a);
	flush(OutPipe.stdout);
}

private void flush(OutPipe pipe) {
	fflush(fileForPipe(pipe));
}

private FILE* fileForPipe(OutPipe pipe) {
	version (Windows) {
		return __acrt_iob_func(pipe);
	} else {
		final switch (pipe) {
			case OutPipe.stdout:
				return posixStdout;
			case OutPipe.stderr:
				return posixStderr;
		}
	}
}

private @system void writeString(OutPipe pipe, in string a) {
	version (Windows) {
		SetConsoleOutputCP(CP_UTF8);
		HANDLE console = GetStdHandle(() {
			final switch (pipe) {
				case OutPipe.stdout:
					return STD_OUTPUT_HANDLE;
				case OutPipe.stderr:
					return STD_ERROR_HANDLE;
			}
		}());
		DWORD written = 0;
		int ok = WriteFile(console, a.ptr, safeToUint(a.length), &written, null);
		assert(ok == 1);
		assert(written == a.length);
	} else {
		write(pipe, a.ptr, safeToUint(a.length));
	}
}

private @system void writeLn(OutPipe pipe, in string a) {
	writeString(pipe, a);
	writeString(pipe, "\n");
	flush(pipe);
}

// Equivalent to 'rm -rf path'
private @trusted ExitCode removeFileOrDirectoryIfExists(FilePath path) {
	final switch (pathKind(path)) {
		case PathKind.doesNotExist:
			return ExitCode.ok;
		case PathKind.error:
			return printErrorCb((scope ref Writer writer) {
				writer ~= "Error removing path ";
				writer ~= path;
				writer ~= ": ";
				writeLastError(writer);
			});
		case PathKind.file:
			return removeFileIfExists(path);
		case PathKind.directory:
			return removeDirectoryRecursively(path);
		case PathKind.other:
			return printErrorCb((scope ref Writer writer) {
				writer ~= "Don't know how to delete unusual entity ";
				writer ~= path;
			});
	}
}

private enum PathKind { doesNotExist, error, file, directory, other }
private PathKind pathKind(FilePath path) {
	version (Windows) {
		DWORD attr = withCStringOfFilePath(path, (in CString x) @trusted => GetFileAttributesA(x.ptr));
		return attr == INVALID_FILE_ATTRIBUTES
			? (GetLastError() == ERROR_FILE_NOT_FOUND ? PathKind.doesNotExist : PathKind.error)
			: attr & FILE_ATTRIBUTE_DIRECTORY
			? PathKind.directory
			: (attr & FILE_ATTRIBUTE_ARCHIVE) || (attr & FILE_ATTRIBUTE_NORMAL)
			? PathKind.file
			: PathKind.other;
	} else {
		stat_t statResult;
		int err = withCStringOfFilePath(path, (in CString x) @trusted => lstat(x.ptr, &statResult));
		if (err == 0)
			return S_ISTYPE(statResult.st_mode, S_IFDIR)
				? PathKind.directory
				: S_ISTYPE(statResult.st_mode, S_IFREG)
				? PathKind.file
				: PathKind.other;
		else if (errno == ENOENT)
			return PathKind.doesNotExist;
		else
			return PathKind.error;
	}
}

version (Windows) {} else {
	// Taken from core.sys.posix.sys.stat (importing it causes linker errors)
	private bool S_ISTYPE(mode_t mode, uint mask) =>
		(mode & S_IFMT) == mask;
}

private ExitCode removeDirectoryRecursively(FilePath dirPath) =>
	okAnd(removeAllInDirectory(dirPath), () => removeEmptyDirectory(dirPath));

private ExitCode removeEmptyDirectory(FilePath dirPath) {
	int err = withCStringOfFilePath(dirPath, (in CString x) @trusted => rmdir(x.ptr));
	return err == 0 ? ExitCode.ok : printErrorCb((scope ref Writer writer) {
		writer ~= "Error removing directory ";
		writer ~= dirPath;
		writer ~= ": ";
		writeLastError(writer);
	});
}

private ExitCode removeAllInDirectory(FilePath dirPath) =>
	eachFileInDirectory(dirPath, okIfNotExists: true, cb: (FilePath path) =>
		removeFileOrDirectoryIfExists(path));

private @trusted ExitCode eachFileInDirectory(
	FilePath dirPath,
	bool okIfNotExists,
	in ExitCode delegate(FilePath) @safe @nogc nothrow cb,
) {
	version (Windows) {
		return todo!ExitCode("TODO: eachFileInDirectory");
	} else {
		DIR* dir = withCStringOfFilePath(dirPath, (in CString x) @trusted => opendir(x.ptr));
		if (dir == null) {
			if (okIfNotExists && errno == ENOENT)
				return ExitCode.ok;
			else
				return printErrorCb((scope ref Writer writer) {
					writer ~= "Error listing directory ";
					writer ~= dirPath;
					writer ~= ": ";
					writeLastError(writer);
				});
		} else {
			int exit = ExitCode.ok.value;
			while (exit == ExitCode.ok.value) {
				dirent* dirent = readdir(dir);
				if (dirent != null) {
					Symbol name = symbolOfString(stringOfCString(CString(castImmutable(dirent.d_name.ptr))));
					if (name != symbol!".." && name != symbol!".")
						exit = cb(dirPath / name).value;
				} else
					break;
			}
			closedir(dir);
			return ExitCode(exit);
		}
	}
}

private ExitCode removeFileIfExists(FilePath path) =>
	withCStringOfFilePath(path, (in CString cString) @trusted {
		version (Windows) {
			bool success = withRetry(() {
				int ok = DeleteFileA(cString.ptr);
				return ok == 1 || GetLastError() == ERROR_FILE_NOT_FOUND ? RetryResult.ok :
					GetLastError() == ERROR_SHARING_VIOLATION ? RetryResult.retry :
					RetryResult.error;
			});
		} else {
			bool success = () {
				final switch (unlink(cString.ptr)) {
					case 0:
						return true;
					case -1:
						return errno == ENOENT;
				}
			}();
		}
		return success ? ExitCode.ok : printErrorCb((scope ref Writer writer) {
			writer ~= "Error removing file ";
			writer ~= cString;
			writer ~= ": ";
			writeLastError(writer);
		});
	});

ExitCodeOrSignal withTempPath(
	Uri tempBasePath,
	Extension extension,
	in ExitCodeOrSignal delegate(FilePath) @safe @nogc nothrow cb,
) =>
	uriIsFile(tempBasePath)
		? withTempPath(asFilePath(tempBasePath), extension, cb)
		: ExitCodeOrSignal(printErrorCb((scope ref Writer writer) {
			writer ~= "Don't know where to put temporary file near ";
			writer ~= tempBasePath;
			writer ~= " (since it is not a file path)";
		}));

ExitCodeOrSignal withTempPath(
	FilePath tempBasePath,
	Extension extension,
	in ExitCodeOrSignal delegate(FilePath) @safe @nogc nothrow cb,
) {
	ubyte[8] bytes = getRandomBytes();
	FilePath tempPath = alterExtensionWithHex(tempBasePath, bytes, extension);
	ExitCodeOrSignal exit = cb(tempPath);
	ExitCodeOrSignal exit2 = ExitCodeOrSignal(removeFileOrDirectoryIfExists(tempPath));
	return okAnd(exit, () => exit2);
}

private @trusted ubyte[8] getRandomBytes() {
	version (Windows) {
		uint v0, v1;
		int err = rand_s(&v0) || rand_s(&v1);
		if (err != 0) todo!void("Error getting random bytes");
		return concat(bytesOfUint(v0), bytesOfUint(v1));
	} else {
		return getNRandomBytes!8();
	}
}

@trusted ubyte[n] getNRandomBytes(size_t n)() {
	version (Windows) {
		ubyte[n] res;
		assert(n % 8 == 0);
		for (size_t i = 0; i < n; i += 8) {
			foreach (size_t j, ubyte x; getRandomBytes())
				res[i + j] = x;
		}
		return res;
	} else {
		ubyte[n] out_;
		FILE* fd = fopen("/dev/urandom", "rb");
		if (fd == null)
			return todo!(ubyte[n])("missing /dev/urandom");
		scope(exit) fclose(fd);
		fread(out_.ptr, ubyte.sizeof, out_.length, fd);
		return out_;
	}
}

version (Windows) {
	private extern(C) int rand_s(uint* randomValue);
}

private ubyte[4] bytesOfUint(uint a) =>
	[cast(ubyte) (a >> 24), cast(ubyte) (a >> 16), cast(ubyte) (a >> 8), cast(ubyte) a];

private T[size0 + size1] concat(T, size_t size0, size_t size1)(in T[size0] a, in T[size1] b) {
	T[size0 + size1] res;
	foreach (size_t i; 0 .. size0)
		res[i] = a[i];
	foreach (size_t i; 0 .. size1)
		res[size0 + i] = b[i];
	return res;
}

private alias TempStrForPath = char[0x1000];

@trusted Opt!FilePath findPathToCCompiler() {
	version (Windows) {
		TempStrForPath res = void;
		int len = SearchPathA(null, "cl.exe", null, cast(uint) res.length, res.ptr, null);
		if (len == 0) {
			printError("Could not find cl.exe on path. Be sure you are using a Native Tools Command Prompt.");
			return none!FilePath;
		} else
			return some(parseFilePath(CString(cast(immutable) res.ptr)));
	} else
		return some(parseFilePath(cString!"/usr/bin/cc"));
}

@trusted ReadFileResult tryReadFile(ref Alloc alloc, Uri uri) {
	if (!uriIsFile(uri))
		return ReadFileResult(ReadFileDiag.notFound);

	MutOpt!(FILE*) optFd = openFileForRead(asFilePath(uri));
	if (!has(optFd))
		return errno == ENOENT
			? ReadFileResult(ReadFileDiag.notFound)
			: ReadFileResult(ReadFileDiag.error);
	FILE* fd = force(optFd);
	scope(exit) fclose(fd);

	int err = fseek(fd, 0, SEEK_END);
	if (err) todo!void("!");

	long ftellResult = ftell(fd);
	if (ftellResult < 0)
		todo!void("ftell failed");
	size_t fileSize = cast(size_t) ftellResult;
	if (fileSize == 0)
		return ReadFileResult(FileContent(newArray!(immutable ubyte)(alloc, [0])));
	else {
		ubyte[] result = allocateElements!ubyte(alloc, fileSize + 1);

		// Go back to the beginning so we can read
		int err2 = fseek(fd, 0, SEEK_SET);
		assert(err2 == 0);

		size_t nBytesRead = fread(result.ptr, ubyte.sizeof, fileSize, fd);
		assert(nBytesRead == fileSize);
		if (ferror(fd))
			todo!void("error reading file");
		result[nBytesRead] = '\0';

		return ReadFileResult(FileContent(cast(immutable) result));
	}
}

private @system MutOpt!(FILE*) openFileForRead(FilePath path) {
	FILE* res = withCStringOfFilePath(path, (in CString x) @trusted =>
		fopen(x.ptr, "rb"));
	return res == null ? noneMut!(FILE*) : someMut(res);
}
private @system MutOpt!(FILE*) openFileForWrite(FilePath path, FilePermissions permissions, FileOverwrite overwrite) {
	version (Windows) {
		// TODO: respect FileOverwrite flag
		FILE* res = withCStringOfFilePath(path, (in CString x) @trusted =>
			fopen(x.ptr, "w"));
		return res == null ? noneMut!(FILE*) : someMut!(FILE*)(res);
	} else {
		int flags = () {
			final switch (overwrite) {
				case FileOverwrite.forbid:
					return O_CREAT | O_EXCL | O_WRONLY;
				case FileOverwrite.allow:
					return O_CREAT | O_TRUNC | O_WRONLY;
			}
		}();
		int res = withCStringOfFilePath(path, (in CString x) @trusted =>
			open(x.ptr, flags, filePermissionsInt(permissions)));
		return res == -1 ? noneMut!(FILE*) : someMut(fdopen(res, "wb"));
	}
}
private int filePermissionsInt(FilePermissions permissions) {
	final switch (permissions) {
		case FilePermissions.regular:
			return octal!"666";
		case FilePermissions.executable:
			return octal!"777";
	}
}

enum FileOverwrite { forbid, allow }

@trusted ExitCode writeFile(FilePath path, in string content, FilePermissions permissions, FileOverwrite overwrite) {
	MutOpt!(FILE*) fd = tryOpenFileForWrite(path, permissions, overwrite);
	if (has(fd)) {
		scope(exit) fclose(force(fd));

		long wroteBytes = fwrite(content.ptr, char.sizeof, content.length, force(fd));
		if (wroteBytes != content.length) {
			if (wroteBytes == -1)
				todo!void("writeFile failed");
			else
				todo!void("writeFile -- didn't write all the bytes?");
		}
		return ExitCode.ok;
	} else
		return ExitCode.error;
}

private @system MutOpt!(FILE*) tryOpenFileForWrite(
	FilePath path,
	FilePermissions permissions,
	FileOverwrite overwrite,
) {
	MutOpt!(FILE*) res = openFileForWrite(path, permissions, overwrite);
	if (has(res))
		return res;
	else if (errno == ENOENT) {
		Opt!FilePath par = parent(path);
		return has(par) && makeDirectoryAndParents(force(par)) == ExitCode.ok
			? openFileForWrite(path, permissions, overwrite)
			: noneMut!(FILE*);
	} else {
		printErrorCb((scope ref Writer writer) {
			writer ~= "Failed to write file ";
			writer ~= path;
			writer ~= ": ";
			writeLastError(writer);
		});
		return noneMut!(FILE*);
	}
}

@trusted FilePath getCwd() {
	TempStrForPath res = void;
	const char* cwd = getcwd(res.ptr, res.length);
	return cwd == null
		? todo!FilePath("getcwd failed")
		: parseFilePath(CString(cast(immutable) cwd));
}

@trusted FilePath getPathToThisExecutable() {
	TempStrForPath res = void;
	version (Windows) {
		HMODULE mod = GetModuleHandle(null);
		assert(mod != null);
		DWORD size = GetModuleFileNameA(mod, res.ptr, res.length);
	} else {
		long size = readlink("/proc/self/exe", res.ptr, res.length);
	}
	assert(size > 0 && size < res.length);
	res[size] = '\0';
	return parseFilePath(CString(cast(immutable) res.ptr));
}

private ExitCode printSignalAndExit(ExitCodeOrSignal a) =>
	a.matchImpure!ExitCode(
		(in ExitCode x) =>
			x,
		(in Signal x) =>
			printErrorCb((scope ref Writer writer) {
				writer ~= "Program exited with signal ";
				writer ~= x.signal;
			}));

ExitCode runCompiler(in PathAndArgs pathAndArgs) =>
	// Extern library linker arguments are already in args
	printSignalAndExit(runCommon([], pathAndArgs, isCompile: true));

ExitCode cleanupCompile(FilePath cwd, FilePath cPath, FilePath exePath) {
	version (Windows) {
		removeFileIfExists(alterExtension(exePath, Extension.ilk));
		removeFileIfExists(alterExtension(exePath, Extension.pdb));
		Symbol objBaseName = alterExtension(baseName(cPath), Extension.obj);
		return removeFileIfExists(cwd / objBaseName);
	} else
		return ExitCode.ok;
}

ExitCodeOrSignal runProgram(in ExternLibraries externLibraries, in PathAndArgs pathAndArgs) =>
	runCommon(externLibraries, pathAndArgs, isCompile: false);

ExitCodeOrSignal runNodeJsProgram(in PathAndArgs pathAndArgs) =>
	withCStringOfFilePath(pathAndArgs.path, (in CString pathCString) {
		version (Windows) {
			return withConcatImpure!(ExitCodeOrSignal, CString)(
				[castNonScope_ref(pathCString)],
				pathAndArgs.args,
				(in CString[] args) =>
					runCommon(
						[],
						PathAndArgs(parseFilePath("C:\\Program Files\\nodejs\\node.exe"), args),
						isCompile: false));
		} else {
			return withConcatImpure!(ExitCodeOrSignal, CString)(
				[cString!"node", castNonScope_ref(pathCString)],
				pathAndArgs.args,
				(in CString[] args) =>
					runCommon([], PathAndArgs(parseFilePath("/usr/bin/env"), args), isCompile: false));
		}
	});

private @trusted ExitCodeOrSignal runCommon(
	in ExternLibraries externLibraries,
	in PathAndArgs pathAndArgs,
	bool isCompile,
) {
	version (Windows) {
		return withWindowsArgsCString(pathAndArgs, (in CString executablePath, in CString argsCString) @trusted {
			foreach (ExternLibrary x; externLibraries) {
				if (has(x.configuredDir)) {
					bool ok = withCStringOfFilePath(asFilePath(force(x.configuredDir)), (in CString x) =>
						SetDllDirectoryA(x.ptr));
					assert(ok);
				}
			}

			HANDLE stdoutRead;
			HANDLE stdoutWrite;
			HANDLE stderrRead;
			HANDLE stderrWrite;
			char[0x10000] stdoutBuf = void;
			char[0x10000] stderrBuf = void;

			if (isCompile) {
				SECURITY_ATTRIBUTES saAttr;
				saAttr.nLength = SECURITY_ATTRIBUTES.sizeof;
				saAttr.bInheritHandle = true;
				saAttr.lpSecurityDescriptor = null;

				if (!CreatePipe(&stdoutRead, &stdoutWrite, &saAttr, 0))
					todo!void("");
				if (!SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0))
					todo!void("");
				if (!CreatePipe(&stderrRead, &stderrWrite, &saAttr, 0))
					todo!void("");
				if (!SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0))
					todo!void("");
			}

			STARTUPINFOA startupInfo = void;
			memset(cast(ubyte*) &startupInfo, 0, STARTUPINFOA.sizeof);
			startupInfo.cb = STARTUPINFOA.sizeof;
			if (isCompile) {
				startupInfo.dwFlags = STARTF_USESTDHANDLES;
				startupInfo.hStdOutput = stdoutWrite;
				startupInfo.hStdError = stderrWrite;
			}

			PROCESS_INFORMATION processInfo;
			memset(cast(ubyte*) &processInfo, 0, PROCESS_INFORMATION.sizeof);
			int ok = CreateProcessA(
				executablePath.ptr,
				// not sure why Windows makes this mutable
				cast(char*) argsCString.ptr,
				null,
				null,
				true,
				0,
				null,
				null,
				&startupInfo,
				&processInfo);
			if (!ok) {
				printErrorCb((scope ref Writer writer) {
					writer ~= "Error spawning ";
					writer ~= argsCString;
					writer ~= '\n';
					writeLastError(writer);
				});
				return ExitCodeOrSignal(ExitCode.error);
			}

			if (isCompile) {
				verifyOk(CloseHandle(stdoutWrite));
				verifyOk(CloseHandle(stderrWrite));

				readFromPipe(stdoutBuf, stdoutRead);
				verifyOk(CloseHandle(stdoutRead));
				readFromPipe(stderrBuf, stderrRead);
				verifyOk(CloseHandle(stderrRead));
			}

			WaitForSingleObject(processInfo.hProcess, INFINITE);

			DWORD exitCode;
			int ok2 = GetExitCodeProcess(processInfo.hProcess, &exitCode);
			assert(ok2 == 1);

			if (isCompile && exitCode != 0) {
				printErrorCb((scope ref Writer writer) @trusted {
					writer ~= "Error running ";
					writer ~= argsCString;
					writer ~= "\nExit code ";
					writer ~= exitCode;
					writer ~= "\nStderr: ";
					writer ~= CString(castImmutable(stderrBuf.ptr));
					writer ~= "\nStdout: ";
					writer ~= CString(castImmutable(stdoutBuf.ptr));
				});
			}

			verifyOk(CloseHandle(processInfo.hProcess));
			verifyOk(CloseHandle(processInfo.hThread));

			return ExitCodeOrSignal(ExitCode(exitCode));
		});
	} else {
		pid_t pid;
		int spawnStatus = withConvertArgs!int(pathAndArgs, (in char* executablePath, in char** args) =>
			withEnvironForChildProcess!int(externLibraries, (in char** environ) @trusted =>
				posix_spawn(&pid, executablePath, null, null, cast(char**) args, environ)));
		if (spawnStatus == 0) {
			int waitStatus;
			int resPid = waitpid(pid, &waitStatus, 0);
			assert(resPid == pid);
			if (WIFEXITED(waitStatus))
				return ExitCodeOrSignal(ExitCode(WEXITSTATUS(waitStatus))); // only valid if WIFEXITED
			else if (WIFSIGNALED(waitStatus))
				return ExitCodeOrSignal(Signal(__WTERMSIG(waitStatus)));
			else
				return todo!ExitCodeOrSignal("process exited non-normally");
		} else
			return todo!ExitCodeOrSignal("posix_spawn failed");
	}
}

ExitCode writeFilesToDir(FilePath baseDir, in PathAndContent[] files) =>
	// First, build the directories we need.
	// Make sure to build from the bottom up.
	okAnd(buildDirectoriesForFiles(baseDir, files), () =>
		eachUntilError!PathAndContent(files, (ref PathAndContent file) =>
			writeFile(concatFilePathAndPath(baseDir, file.path), file.content, file.permissions, FileOverwrite.allow)));

private:

ExitCode buildDirectoriesForFiles(FilePath baseDir, in PathAndContent[] files) =>
	okAnd(makeDirectory(baseDir), () {
		size_t maxPaths = sum!PathAndContent(files, (in PathAndContent x) => countComponents(x.path));
		return withTempSetImpure!(ExitCode, Path)(maxPaths, (scope ref TempSet!Path done) {
			ExitCode ensureDir(Path a) {
				if (tryAdd(done, a)) {
					Opt!Path par = parent(a);
					ExitCode parentExit = has(par) ? ensureDir(force(par)) : ExitCode.ok;
					return okAnd(parentExit, () => makeDirectory(concatFilePathAndPath(baseDir, a)));
				} else
					return ExitCode.ok;
			}

			return eachUntilError!PathAndContent(files, (ref PathAndContent file) {
				Opt!Path par = parent(file.path);
				return has(par) ? ensureDir(force(par)) : ExitCode.ok;
			});
		});
	});

version (Windows) {
	enum RetryResult { ok, error, retry }
	@system bool withRetry(in RetryResult delegate() @nogc nothrow cb) {
		final switch (cb()) {
			case RetryResult.ok:
				return true;
			case RetryResult.error:
				return false;
			case RetryResult.retry:
				Sleep(10);
				return cb() == RetryResult.ok;
		}
	}

	extern(C) bool SetDllDirectoryA(scope LPCSTR);
}

version (Windows) {} else {
	Out withEnvironForChildProcess(Out)(
		in ExternLibraries externLibraries,
		in Out delegate(in immutable char**) @safe @nogc nothrow cb,
	) =>
		exists!ExternLibrary(externLibraries, (in ExternLibrary x) => has(x.configuredDir))
			? withLdLibraryPath(externLibraries, (in immutable char* ldLibraryPath) =>
				withBuildStackArrayImpure!(Out, immutable char*)(
					(scope ref StackArrayBuilder!(immutable char*) out_) @trusted {
						immutable(char*)* cur = __environ;
						while (*cur != null) {
							out_ ~= *cur;
							cur++;
						}
						out_ ~= ldLibraryPath;
						out_ ~= typeAs!(immutable char*)(null);
					},
					(scope immutable char*[] environ) @trusted => cb(environ.ptr)))
			: cb(__environ);

	Out withLdLibraryPath(Out)(
		in ExternLibraries externLibraries,
		in Out delegate(in immutable char*) @safe @nogc nothrow cb,
	) =>
		withStackWriterImpureCString!(Out, 0x1000)(
			(scope ref Writer writer) {
				writer ~= "LD_LIBRARY_PATH=";
				writeWithSeparatorAndFilter!ExternLibrary(
					writer,
					externLibraries,
					";",
					(in ExternLibrary x) => has(x.configuredDir),
					(in ExternLibrary x) {
						writer ~= '/';
						writer ~= asFilePath(force(x.configuredDir));
					});
			},
			(in CString x) => cb(x.ptr));
}

version (Windows) {
	extern(C) char* _getcwd(char* buffer, int maxlen);
	extern(C) int _mkdir(scope const char*, immutable uint);
	extern(C) int _rmdir(scope const char*);

	alias getcwd = _getcwd;
	alias mkdir = _mkdir;
	alias rmdir = _rmdir;
}

ExitCode makeDirectoryAndParents(FilePath dir) =>
	onError(makeDirectoryNoPrintErrors(dir), () {
		Opt!FilePath par = parent(dir);
		return errno == ENOENT && has(par)
			? okAnd(makeDirectoryAndParents(force(par)), () => makeDirectory(dir))
			: logMakeDirectoryError(dir);
	});

ExitCode makeDirectory(FilePath dir) =>
	onError(makeDirectoryNoPrintErrors(dir), () => logMakeDirectoryError(dir));

ExitCode logMakeDirectoryError(FilePath dir) =>
	printErrorCb((scope ref Writer writer) {
		writer ~= "Error making directory ";
		writer ~= dir;
		writer ~= ": ";
		writeLastError(writer);
	});

ExitCode makeDirectoryNoPrintErrors(FilePath dir) =>
	withCStringOfFilePath(dir, (in CString x) @trusted =>
		mkdir(x.ptr, octal!"700") == 0 ? ExitCode.ok : ExitCode.error);

version (Windows) {
	ExitCodeOrSignal withWindowsArgsCString(
		in PathAndArgs a,
		in ExitCodeOrSignal delegate(in CString, in CString) @safe @nogc nothrow cb,
	) =>
		withCStringOfFilePath(a.path, (in CString path) =>
			withStackWriterImpureCString((scope ref Writer writer) {
				writer ~= '"';
				writer ~= path;
				writer ~= '"';
				foreach (CString arg; a.args) {
					writer ~= ' ';
					writer ~= arg;
				}
			}, (in CString args) => cb(path, args)));
}

void verifyOk(int ok) {
	assert(ok == 1);
}

version (Windows) {
	@system ExitCode readFromPipe(ref char[0x10000] outBuf, HANDLE pipe) {
		char* out_ = outBuf.ptr;
		char* outEnd = endPtr(outBuf);
		while (out_ + 1 != outEnd) {
			assert(out_ < outEnd);
			uint nRead;
			if (ReadFile(pipe, out_, cast(uint) (outEnd - out_ - 1), &nRead, null) == 1) {
				out_ += nRead;
				continue;
			} else if (GetLastError() == ERROR_BROKEN_PIPE)
				break;
			else
				return printErrorCb((scope ref Writer writer) {
					writer ~= "Error in readFromPipe: ";
					writeLastError(writer);
				});
		}
		*out_ = '\0';
		return ExitCode.ok;
	}
}

@system Out withConvertArgs(Out)(
	in PathAndArgs a,
	in Out delegate(in char*, in char**) @safe @nogc nothrow cb,
) =>
	withCStringOfFilePath!Out(a.path, (in CString path) =>
		withExactStackArrayImpure!(Out, const char*)(
			a.args.length + 2,
			(scope ref ExactSizeArrayBuilder!(const char*) out_) @trusted {
				out_ ~= path.ptr;
				foreach (CString arg; a.args)
					out_ ~= arg.ptr;
				out_ ~= null;
				return cb(path.ptr, finish(out_).ptr);
			}));

extern(C) immutable char** __environ;

// Copying from /usr/include/dmd/druntime/import/core/sys/posix/sys/wait.d
// to avoid linking to druntime
int __WTERMSIG( int status ) { return status & 0x7F; }
int WEXITSTATUS( int status ) { return ( status & 0xFF00 ) >> 8; }
bool WIFEXITED( int status ) { return __WTERMSIG( status ) == 0; }
bool WIFSIGNALED( int status )
{
	return ( cast(byte) ( ( status & 0x7F ) + 1 ) >> 1 ) > 0;
}

@trusted void writeLastError(scope ref Writer writer) {
	version (Windows) {
		DWORD error = GetLastError();
		writer ~= "Windows error ";
		writer ~= error;
		writer ~= ": ";

		char[0x400] buffer;
		int size = FormatMessageA(
			FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
			null,
			error,
			0,
			buffer.ptr,
			buffer.length,
			null);
		assert(size != 0 && size < buffer.length);
		writer ~= castImmutable(buffer[0 .. size]);
	} else {
		writer ~= "Posix error ";
		writer ~= errno;
		writer ~= ": ";
		writer ~= CString(cast(immutable) strerror(errno));
	}
}

version (Windows) {
	extern(C) FILE* __acrt_iob_func(uint);
}
