final class CrowClassLoader extends ClassLoader {
	private final java.util.concurrent.ConcurrentHashMap<String, byte[]> classes = new java.util.concurrent.ConcurrentHashMap<>();

	public CrowClassLoader(ClassLoader parent) {
		super(parent);
	}

	public void addClassBytecode(String name, byte[] bytes) {
		classes.put(name, bytes);
	}

	@Override public Class findClass(String name) throws ClassNotFoundException {
		byte[] bytes = classes.get(name.replace(".", "/")); // TODO:PERF classes.remove(name.replace(".", "/")); --------------
		return bytes == null ? super.findClass(name) : defineClass(name, bytes, 0, bytes.length);
	}
}
