module util.memory;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc, allocateUninitialized;
version (WebAssembly) {} else {
	import core.stdc.string : stdMemcpy = memcpy, stdMemmove = memmove, stdMemset = memset;
}

@trusted void initMemory(T)(T* ptr, const T value) {
	*(cast(byte[T.sizeof]*) ptr) = *(cast(const byte[T.sizeof]*) &value);
}
@trusted void initMemory(T)(T* ptr, ref const T value) {
	*(cast(byte[T.sizeof]*) ptr) = *(cast(const byte[T.sizeof]*) &value);
}

@system ubyte* memcpy(return scope ubyte* dest, scope const ubyte* src, size_t length) {
	version (WebAssembly) {
		return memmove(dest, src, length);
	} else {
		return cast(ubyte*) stdMemcpy(dest, src, length);
	}
}

@system ubyte* memmove(return scope ubyte* dest, scope const ubyte* src, size_t length) {
	version (WebAssembly) {
		if (dest < src) {
			foreach (size_t i; 0 .. length)
				dest[i] = src[i];
		} else {
			foreach_reverse (size_t i; 0 .. length)
				dest[i] = src[i];
		}
		return dest;
	} else
		return cast(ubyte*) stdMemmove(dest, src, length);
}

@system ubyte* memset(return scope ubyte* dest, ubyte value, size_t length) {
	version (WebAssembly) {
		foreach (size_t i; 0 .. length)
			dest[i] = value;
		return dest;
	} else
		return cast(ubyte*) stdMemset(dest, value, length);
}

void overwriteMemory(T)(T* ptr, T value) {
	initMemory!T(ptr, value);
}

@trusted T* allocate(T)(scope ref Alloc alloc, T value) {
	T* ptr = allocateUninitialized!T(alloc);
	initMemory!T(ptr, value);
	return ptr;
}

@trusted void copyToFrom(T)(scope T[] dest, in T[] source) {
	assert(dest.length == source.length);
	cast(void) memcpy(cast(ubyte*) dest.ptr, cast(ubyte*) source.ptr, T.sizeof * dest.length);
}

// For clearing memory which should now be unused
@system void ensureMemoryClear(T)(T* ptr) {
	cast(void) memset(cast(ubyte*) ptr, 0xff, T.sizeof);
}
