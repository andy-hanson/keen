
final class CrowClassLoader extends ClassLoader {
	static final CrowClassLoader loader = new CrowClassLoader();

	static Class<?> load(String name) {
		try {
			return loader.loadClass(name);
		} catch (ClassNotFoundException e) {
			throw new Error(e);
		}
	}

	static java.util.concurrent.ConcurrentHashMap<String, byte[]> classes = new java.util.concurrent.ConcurrentHashMap<>();
	static void add(String name, byte[] bytes) {
		classes.put(name, bytes);
	}

	@Override public Class findClass(String name) {
		byte[] bytes = classes.remove(name.replace(".", "/"));
		return bytes == null ? null : defineClass(name, bytes, 0, bytes.length);
	}
}