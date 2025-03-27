class Crow {
	static boolean referenceEqual(Object a, Object b) {
		return a == b;		
	}
	static boolean equalInt8(byte a, byte b) {
		return a == b;
	}
	static boolean equalInt16(short a, short b) {
		return a == b;
	}
	static boolean equalInt32(int a, int b) {
		return a == b;
	}
	static boolean equalInt64(long a, long b) {
		return a == b;
	}
	static boolean equalFloat32(float a, float b) {
		return a == b;
	}
	static boolean equalFloat64(double a, double b) {
		return a == b;
	}
	static boolean lessFloat32(float a, float b) {
		return a < b;
	}
	static boolean lessFloat64(double a, double b) {
		return a < b;
	}
	static boolean lessInt8(byte a, byte b) {
		return a < b;
	}
	static boolean lessInt16(short a, short b) {
		return a < b;
	}
	static boolean lessInt32(int a, int b) {
		return a < b;
	}
	static boolean lessInt64(long a, long b) {
		return a < b;
	}
	static boolean lessNat8(byte a, byte b) {
		return Byte.compareUnsigned(a, b) < 0;
	}
	static boolean lessNat16(short a, short b) {
		return Short.compareUnsigned(a, b) < 0;
	}
	static boolean lessNat32(int a, int b) {
		return Integer.compareUnsigned(a, b) < 0;
	}
	static boolean lessNat64(long a, long b) {
		return Long.compareUnsigned(a, b) < 0;
	}

	static int nat32FromNat64(long a) {
		if (0 <= a && a <= 0xffffffffL)
			return (int) a;
		else
			throw new java.lang.OutOfMemoryError();
	}

	static boolean fitsInNat32(long l) {
		return 0 <= l && l <= 0xffffffffL;
	}
	static boolean fitsInInt32(long l) {
		return ((long) Integer.MIN_VALUE) <= l && l <= ((long) Integer.MAX_VALUE);
	}

	static ThreadLocalReentrantLock curExclusion = new ThreadLocalReentrantLock();

	// TODO: Remove and support catching 'exception' natively -----------------------------------------------------------------
	// This must be public because it's called through reflection
	public static Throwable catchAll(Object fn, java.lang.invoke.MethodHandle callIt) {
		try {
			callIt.invoke(fn);
			return null;
		} catch (Throwable e) {
			return e;
		}
	}
	public static void yieldFiber() {
		java.util.concurrent.locks.ReentrantLock lock = curExclusion.get();
		lock.unlock();
		lock.lock();
	}
	static java.util.concurrent.locks.ReentrantLock getExclusion() {
		return curExclusion.get();
	}
	static void changeExclusion(java.util.concurrent.locks.ReentrantLock newExclusion) {
		java.util.concurrent.locks.ReentrantLock prevExclusion = curExclusion.get();
		prevExclusion.unlock();
		curExclusion.set(newExclusion);
		newExclusion.lock();
	}

	static <T> T throw_(String message) { // TODO: RM ---------------------------------------------------------------------------------------------------------------
		throw new Error(message);
	}

	static double float64FromNat64(long a) {
		return a < 0 ? (double) a + Math.pow(2, 64) : (double) a;
	}
	static double round(double a) {
		return (a < 0 ? -1 : 1) * Math.round(Math.abs(a));
	}

	static float atan2(float a, float b) {
		return (float) Math.atan2((double) a, (double) b);
	}
	static float pow(float a, float b) {
		return (float) Math.pow((double) a, (double) b);
	}

	static double acosh(double a) {
		return Math.log(a + Math.sqrt(a * a - 1.0));
	}
	static double asinh(double a) {
		return Math.log(a + Math.sqrt(a * a + 1.0));
	}
	static double atanh(double a) {
		return 0.5 * Math.log(Math.abs((a + 1) / (a - 1)));
	}

	static java.lang.invoke.MethodHandle funPointer(Class<?> class_, String methodName, Class<?> returnType) {
		return funPointerInner(class_, methodName, returnType);
	}
	static java.lang.invoke.MethodHandle funPointer(Class<?> class_, String methodName, Class<?> returnType, Class<?> arg0) {
		return funPointerInner(class_, methodName, returnType, arg0);
	}
	static java.lang.invoke.MethodHandle funPointer(Class<?> class_, String methodName, Class<?> returnType, Class<?> arg0, Class<?> arg1) {
		return funPointerInner(class_, methodName, returnType, arg0, arg1);
	}
	private static java.lang.invoke.MethodHandle funPointerInner(Class<?> class_, String methodName, Class<?> returnType, Class<?>... args) {
		try {
			return lookup.findStatic(class_, methodName, java.lang.invoke.MethodType.methodType(returnType, args));
		} catch (Throwable e) {
			// ----------------------------------------------------------------------------------------------------------------
			System.out.println("ERROR IS " + e);
			String message = "Could not find function " + class_.getName() + "." + methodName;
			message += " returning ";
			message += returnType;
			message += " with args (";
			for (int i = 0; i < args.length; i++) {
				if (i != 0) message += ", ";
				message += args[i];
			}
			message += ") because:\n";
			message += e;

			System.out.println("returnType == void.class? " + (returnType == void.class));

			System.out.println("All methods:");
			for (java.lang.reflect.Method method : class_.getMethods()) {
				System.out.println(method);
			}

			throw new Error(message);
		}
	}
	private static final java.lang.invoke.MethodHandles.Lookup lookup = java.lang.invoke.MethodHandles.lookup();

	static Object getStaticField(String className, String fieldName) throws Throwable {
		return Class.forName(className).getDeclaredField(fieldName).get(null);
	}
	static Object callNew(String className) throws Throwable {
		return callNewVarargs(className, new Object[] {});
	}
	static Object callNew(String className, Object arg) throws Throwable {
		return callNewVarargs(className, new Object[] { arg });
	}
	static Object callNew(String className, Object arg0, Object arg1) throws Throwable {
		return callNewVarargs(className, new Object[] { arg0, arg1 });
	}
	static Object callNew(String className, Object arg0, Object arg1, Object arg2) throws Throwable {
		return callNewVarargs(className, new Object[] { arg0, arg1, arg2 });
	}
	static Object callNewVarargs(String className, Object[] args) throws Throwable {
		return getConstructor(Class.forName(className), args).newInstance(args);
	}

	static Object callStatic(String className, String methodName) throws Throwable {
		return callStaticVarargs(className, methodName, new Object[] {});
	}
	static Object callStatic(String className, String methodName, Object arg) throws Throwable {
		return callStaticVarargs(className, methodName, new Object[] { arg });
	}
	static Object callStatic(String className, String methodName, Object arg0, Object arg1) throws Throwable {
		return callStaticVarargs(className, methodName, new Object[] { arg0, arg1 });
	}
	static Object callStatic(String className, String methodName, Object arg0, Object arg1, Object arg2) throws Throwable {
		return callStaticVarargs(className, methodName, new Object[] { arg0, arg1, arg2 });
	}
	static Object callStatic(String className, String methodName, Object arg0, Object arg1, Object arg2, Object arg3) throws Throwable {
		return callStaticVarargs(className, methodName, new Object[] { arg0, arg1, arg2, arg3 });
	}
	static Object callStaticVarargs(String className, String methodName, Object[] args) throws Throwable {
		return getMethod(Class.forName(className), methodName, args).invoke(null, args);
	}

	static Object callInstance(Object object, String name) throws Throwable {
		return callInstanceVarargs(object, name, new Object[] {});
	}
	static Object callInstance(Object object, String name, Object arg) throws Throwable {
		return callInstanceVarargs(object, name, new Object[] { arg });
	}
	static Object callInstance(Object object, String name, Object arg0, Object arg1) throws Throwable {
		return callInstanceVarargs(object, name, new Object[] { arg0, arg1 });
	}
	static Object callInstance(Object object, String name, Object arg0, Object arg1, Object arg2) throws Throwable {
		return callInstanceVarargs(object, name, new Object[] { arg0, arg1, arg2 });
	}
	static Object callInstanceVarargs(Object object, String name, Object[] args) throws Throwable {
		return getMethod(classOf(object), name, args).invoke(object, args);
	}

	void assertNonNull(Object object) {
		if (object == null) {
			throw new NullPointerException();
		}
	}

	private static java.lang.reflect.Constructor getConstructor(Class<?> class_, Object[] args) throws Throwable {
		Class<?>[] argClasses = classes(args);
		try {
			return class_.getConstructor(argClasses);
		} catch (NoSuchMethodException e) {
			throw new Error("TODO: advanced search for correct constructor to call");
		}
	}

	private static java.lang.reflect.Method getMethod(Class<?> class_, String methodName, Object[] args) throws Throwable {
		Class<?>[] argClasses = classes(args);
		try {
			return class_.getMethod(methodName, argClasses);
		} catch (NoSuchMethodException e) {
			java.lang.reflect.Method[] methods = class_.getMethods();
			java.lang.reflect.Method res = null;
			for (int i = 0; i < methods.length; i++) {
				java.lang.reflect.Method method = methods[i];
				if (method.getName().equals(methodName) && method.getParameterCount() == args.length && canCallMethod(method.getParameterTypes(), argClasses)) {
					if (res == null)
						res = methods[i];
					else
						throw new Error("Multiple methods could match the given arguments");
				}
			}
			if (res == null) throw e;
			return res;
		}
	}
	private static Class<?>[] classes(Object[] args) {
		Class<?>[] res = new Class<?>[args.length];
		for (int i = 0; i < res.length; i++)
			res[i] = classOf(args[i]);
		return res;
	}
	private static boolean canCallMethod(Class<?>[] parameterTypes, Class<?>[] argClasses) {
		for (int i = 0; i < parameterTypes.length; i++) {
			if (!parameterTypes[i].isAssignableFrom(argClasses[i]))
				return false;
		}
		return true;
	}
	private static Class classOf(Object a) {
		if (a == null)
			return Object.class;
		Class res = a.getClass();
		if (res == Integer.class)
			return int.class;
		// TODO: handle other primitives ---------------------------------------------------------------------------------------
		// TODO: could probably use isAssignableFrom instead of checking the name
		// HAX: Can't directly ask for a method on that class, so have to skip to the Path interface instead ----------------------------------
		else if (res.getName().equals("sun.nio.fs.UnixPath"))
			return java.nio.file.Path.class;
		// Similar HAX ------------------------------------------------------------------------------------------------------------
		else if (res.getName().equals("java.util.stream.ReferencePipeline$Head"))
			return java.util.stream.Stream.class;
		// Further HAX ------------------------------------------------------------------------------------------------------------
		else if (res.getName().equals("java.io.BufferedInputStream"))
			return java.io.InputStream.class;
		else
			return res;
	}

	static java.lang.ref.WeakReference<?> newWeakRef(Object a) {
		return new java.lang.ref.WeakReference<>(a);
	}
	static Object weakRefGet(java.lang.ref.WeakReference<?> a) {
		return a == null ? null : a.get();
	}
}
