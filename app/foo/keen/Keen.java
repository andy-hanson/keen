package foo.keen;

public class Keen {
	public static void throw_(Throwable a) throws Throwable {
		throw a;
	}

	public static byte[][] stringArrayFromJavaStringArray(String[] a) {
		byte[][] res = new byte[a.length][];
		for (int i = 0; i < res.length; i++)
			res[i] = a[i].getBytes();
		return res;
	}

	public static boolean isNull(Object a) {
		return a == null;
	}
	public static boolean isNotNull(Object a) {
		return a != null;
	}
	public static boolean referenceEqual(Object a, Object b) {
		return a == b;
	}
	public static boolean equalInt8(byte a, byte b) {
		// This seems silly, but in Java a byte parameter actually takes an int at runtime, so we need to be sure to only use the byte parts
		return (a & 0xff) == (b & 0xff);
	}
	public static boolean equalInt16(short a, short b) {
		// This seems silly, but in Java a short parameter actually takes an int at runtime, so we need to be sure to only use the short parts
		return (a & 0xffff) == (b & 0xffff);
	}
	public static boolean equalInt32(int a, int b) {
		return a == b;
	}
	public static boolean equalInt64(long a, long b) {
		return a == b;
	}
	public static boolean equalFloat32(float a, float b) {
		return Float.floatToIntBits(a) == Float.floatToIntBits(b);
	}
	public static boolean equalFloat64(double a, double b) {
		return Double.doubleToLongBits(a) == Double.doubleToLongBits(b);
	}
	public static boolean equalFloat32IEEE(float a, float b) {
		return a == b;
	}
	public static boolean equalFloat64IEEE(double a, double b) {
		return a == b;
	}
	public static boolean lessFloat32IEEE(float a, float b) {
		return a < b;
	}
	public static boolean lessFloat64IEEE(double a, double b) {
		return a < b;
	}
	public static boolean isNegative0(float a) {
		return Float.floatToIntBits(a) == 0x80000000;
	}
	public static boolean isPositive0(float a) {
		return Float.floatToIntBits(a) == 0;
	}
	public static boolean isNegative0(double a) {
		return Double.doubleToLongBits(a) == 0x8000000000000000L;
	}
	public static boolean isPositive0(double a) {
		return Double.doubleToLongBits(a) == 0;
	}
	// This returns 'comparison', which has members 'less' = 0, 'equal' = 1, 'greater' = 2
	public static byte compareInt8(byte a, byte b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static byte compareInt16(short a, short b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static byte compareInt32(int a, int b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static byte compareInt64(long a, long b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	private static byte toComparison(int a) {
		return a < 0 ? (byte) 0 : a > 0 ? (byte) 2 : (byte) 1;
	}
	public static byte compareNat8(byte a, byte b) {
		return toComparison(Byte.compareUnsigned(a, b));
	}
	public static byte compareNat16(short a, short b) {
		return toComparison(Short.compareUnsigned(a, b));
	}
	public static byte compareNat32(int a, int b) {
		return toComparison(Integer.compareUnsigned(a, b));
	}
	public static byte compareNat64(long a, long b) {
		return toComparison(Long.compareUnsigned(a, b));
	}
	public static byte compareFloat32(float a, float b) {
		return lessFloat32(a, b) ? (byte) 0 : lessFloat32(b, a) ? (byte) 2 : (byte) 1;
	}
	private static boolean lessFloat32(float a, float b) {
		return a < b || isNegative0(a) && isPositive0(b) || Float.isNaN(a) && !Float.isNaN(b);
	}
	public static byte compareFloat64(double a, double b) {
		return lessFloat64(a, b) ? (byte) 0 : lessFloat64(b, a) ? (byte) 2 : (byte) 1;
	}
	private static boolean lessFloat64(double a, double b) {
		return a < b || isNegative0(a) && isPositive0(b) || Double.isNaN(a) && !Double.isNaN(b);
	}
	public static byte compareFloat32IEEE(float a, float b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static byte compareFloat64IEEE(double a, double b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static byte divideUnsigned(byte a, byte b) {
		return (byte) (Byte.toUnsignedInt(a) / Byte.toUnsignedInt(b));
	}
	public static short divideUnsigned(short a, short b) {
		return (short) (Short.toUnsignedInt(a) / Short.toUnsignedInt(b));
	}

	public static int nat32FromNat64(long a) {
		if (0 <= a && a <= 0xffffffffL)
			return (int) a;
		else
			throw new java.lang.OutOfMemoryError();
	}

	public static boolean fitsInNat32(long l) {
		return 0 <= l && l <= 0xffffffffL;
	}
	public static boolean fitsInInt32(long l) {
		return ((long) Integer.MIN_VALUE) <= l && l <= ((long) Integer.MAX_VALUE);
	}

	public static double float64FromNat64(long a) {
		return a < 0 ? (double) a + Math.pow(2, 64) : (double) a;
	}

	public static java.lang.ref.WeakReference<?> newWeakRef(Object a) {
		return new java.lang.ref.WeakReference<>(a);
	}
	public static Object weakRefGet(java.lang.ref.WeakReference<?> a) {
		return a == null ? null : a.get();
	}
}
