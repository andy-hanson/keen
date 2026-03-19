import java.io.ByteArrayInputStream;
import java.io.InputStream;

final class CrowClassLoader extends ClassLoader {
	private final java.util.concurrent.ConcurrentHashMap<String, byte[]> classes = new java.util.concurrent.ConcurrentHashMap<>();
	private final java.util.concurrent.ConcurrentHashMap<String, byte[]> resources = new java.util.concurrent.ConcurrentHashMap<>();

	public CrowClassLoader(ClassLoader parent) {
		super(parent);
	}

	public void addClassBytecode(String name, byte[] bytes) {
		classes.put(name, bytes);
	}
	public void addResource(String name, byte[] bytes) {
		resources.put(name, bytes);
	}

	@Override public Class findClass(String name) throws ClassNotFoundException {
		byte[] bytes = classes.get(name.replace(".", "/"));
		return bytes == null ? super.findClass(name) : defineClass(name, bytes, 0, bytes.length);
	}

	@Override public InputStream getResourceAsStream(String name) {
		byte[] bytes = resources.get(name);
		return bytes == null ? super.getResourceAsStream(name) : new ByteArrayInputStream(bytes);
	}
}
