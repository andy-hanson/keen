// Note: This file is inlined into 'bin/crow'.
// So if you edit this file, you need to build twice: 'make bin/crow && make update-lkg && rm bin/crow && make bin/crow' (TODO: can I make this happen automatically?)
public class Crow {
	public static byte[][] stringArrayFromJavaStringArray(String[] a) {
		byte[][] res = new byte[a.length][];
		for (int i = 0; i < res.length; i++)
			res[i] = a[i].getBytes();
		return res;
	}

	public static boolean referenceEqual(Object a, Object b) {
		return a == b;		
	}
	public static boolean equalInt8(byte a, byte b) {
		return a == b;
	}
	public static boolean equalInt16(short a, short b) {
		return a == b;
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
	public static boolean lessInt8(byte a, byte b) {
		return a < b;
	}
	public static boolean lessInt16(short a, short b) {
		return a < b;
	}
	public static boolean lessInt32(int a, int b) {
		return a < b;
	}
	public static boolean lessInt64(long a, long b) {
		return a < b;
	}
	public static boolean lessNat8(byte a, byte b) {
		return Byte.compareUnsigned(a, b) < 0;
	}
	public static boolean lessNat16(short a, short b) {
		return Short.compareUnsigned(a, b) < 0;
	}
	public static boolean lessNat32(int a, int b) {
		return Integer.compareUnsigned(a, b) < 0;
	}
	public static boolean lessNat64(long a, long b) {
		return Long.compareUnsigned(a, b) < 0;
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
