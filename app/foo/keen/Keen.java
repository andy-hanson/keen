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
	public static boolean notReferenceEqual(Object a, Object b) {
		return a != b;
	}

	public static boolean equalInt8(byte a, byte b) {
		// This seems silly, but in Java a byte parameter actually takes an int at runtime, so we need to be sure to only use the byte parts
		return (a & 0xff) == (b & 0xff);
	}
	public static boolean notEqualInt8(byte a, byte b) {
		return !equalInt8(a, b);
	}
	// This returns 'comparison', which has members 'less' = 0, 'equal' = 1, 'greater' = 2
	public static byte compareInt8(byte a, byte b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static boolean lessInt8(byte a, byte b) {
		return a < b;
	}
	public static boolean lessOrEqualInt8(byte a, byte b) {
		return a <= b;
	}
	public static boolean greaterInt8(byte a, byte b) {
		return a > b;
	}
	public static boolean greaterOrEqualInt8(byte a, byte b) {
		return a >= b;
	}

	public static boolean equalInt16(short a, short b) {
		// This seems silly, but in Java a short parameter actually takes an int at runtime, so we need to be sure to only use the short parts
		return (a & 0xffff) == (b & 0xffff);
	}
	public static boolean notEqualInt16(short a, short b) {
		return !equalInt16(a, b);
	}
	public static byte compareInt16(short a, short b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static boolean lessInt16(short a, short b) {
		return a < b;
	}
	public static boolean lessOrEqualInt16(short a, short b) {
		return a <= b;
	}
	public static boolean greaterInt16(short a, short b) {
		return a > b;
	}
	public static boolean greaterOrEqualInt16(short a, short b) {
		return a >= b;
	}

	public static boolean equalInt32(int a, int b) {
		return a == b;
	}
	public static boolean notEqualInt32(int a, int b) {
		return a != b;
	}
	public static byte compareInt32(int a, int b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static boolean lessInt32(int a, int b) {
		return a < b;
	}
	public static boolean lessOrEqualInt32(int a, int b) {
		return a <= b;
	}
	public static boolean greaterInt32(int a, int b) {
		return a > b;
	}
	public static boolean greaterOrEqualInt32(int a, int b) {
		return a >= b;
	}

	public static boolean equalInt64(long a, long b) {
		return a == b;
	}
	public static boolean notEqualInt64(long a, long b) {
		return a != b;
	}
	public static byte compareInt64(long a, long b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static boolean lessInt64(long a, long b) {
		return a < b;
	}
	public static boolean lessOrEqualInt64(long a, long b) {
		return a <= b;
	}
	public static boolean greaterInt64(long a, long b) {
		return a > b;
	}
	public static boolean greaterOrEqualInt64(long a, long b) {
		return a >= b;
	}

	private static byte toComparison(int a) {
		return a < 0 ? (byte) 0 : a > 0 ? (byte) 2 : (byte) 1;
	}

	public static byte compareNat8(byte a, byte b) {
		return toComparison(Byte.compareUnsigned(a, b));
	}
	public static boolean lessNat8(byte a, byte b) {
		return Byte.compareUnsigned(a, b) < 0;
	}
	public static boolean lessOrEqualNat8(byte a, byte b) {
		return Byte.compareUnsigned(a, b) <= 0;
	}
	public static boolean greaterNat8(byte a, byte b) {
		return Byte.compareUnsigned(a, b) > 0;
	}
	public static boolean greaterOrEqualNat8(byte a, byte b) {
		return Byte.compareUnsigned(a, b) >= 0;
	}

	public static byte compareNat16(short a, short b) {
		return toComparison(Short.compareUnsigned(a, b));
	}
	public static boolean lessNat16(short a, short b) {
		return Short.compareUnsigned(a, b) < 0;
	}
	public static boolean lessOrEqualNat16(short a, short b) {
		return Short.compareUnsigned(a, b) <= 0;
	}
	public static boolean greaterNat16(short a, short b) {
		return Short.compareUnsigned(a, b) > 0;
	}
	public static boolean greaterOrEqualNat16(short a, short b) {
		return Short.compareUnsigned(a, b) >= 0;
	}

	public static byte compareNat32(int a, int b) {
		return toComparison(Integer.compareUnsigned(a, b));
	}
	public static boolean lessNat32(int a, int b) {
		return Integer.compareUnsigned(a, b) < 0;
	}
	public static boolean lessOrEqualNat32(int a, int b) {
		return Integer.compareUnsigned(a, b) <= 0;
	}
	public static boolean greaterNat32(int a, int b) {
		return Integer.compareUnsigned(a, b) > 0;
	}
	public static boolean greaterOrEqualNat32(int a, int b) {
		return Integer.compareUnsigned(a, b) >= 0;
	}

	public static byte compareNat64(long a, long b) {
		return toComparison(Long.compareUnsigned(a, b));
	}
	public static boolean lessNat64(long a, long b) {
		return Long.compareUnsigned(a, b) < 0;
	}
	public static boolean lessOrEqualNat64(long a, long b) {
		return Long.compareUnsigned(a, b) <= 0;
	}
	public static boolean greaterNat64(long a, long b) {
		return Long.compareUnsigned(a, b) > 0;
	}
	public static boolean greaterOrEqualNat64(long a, long b) {
		return Long.compareUnsigned(a, b) >= 0;
	}

	public static boolean isNegative0(float a) {
		return Float.floatToIntBits(a) == 0x80000000;
	}
	public static boolean isPositive0(float a) {
		return Float.floatToIntBits(a) == 0;
	}
	public static boolean equalFloat32(float a, float b) {
		return Float.floatToIntBits(a) == Float.floatToIntBits(b);
	}
	public static boolean notEqualFloat32(float a, float b) {
		return !equalFloat32(a, b);
	}
	public static boolean equalFloat32IEEE(float a, float b) {
		return a == b;
	}
	// For floats, NaN < -Infinity < ... < -0 < 0 < ... < Infinity
	public static boolean lessFloat32(float a, float b) {
		return a < b || isNegative0(a) && isPositive0(b) || Float.isNaN(a) && !Float.isNaN(b);
	}
	public static boolean lessFloat32IEEE(float a, float b) {
		return a < b;
	}
	public static byte compareFloat32(float a, float b) {
		return lessFloat32(a, b) ? (byte) 0 : lessFloat32(b, a) ? (byte) 2 : (byte) 1;
	}
	public static byte compareFloat32IEEE(float a, float b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static boolean lessOrEqualFloat32(float a, float b) {
		return equalFloat32(a, b) || lessFloat32(a, b);
	}
	public static boolean greaterFloat32(float a, float b) {
		return lessFloat32(b, a);
	}
	public static boolean greaterOrEqualFloat32(float a, float b) {
		return equalFloat32(a, b) || greaterFloat32(a, b);
	}

	public static boolean isNegative0(double a) {
		return Double.doubleToLongBits(a) == 0x8000000000000000L;
	}
	public static boolean isPositive0(double a) {
		return Double.doubleToLongBits(a) == 0;
	}
	public static boolean equalFloat64(double a, double b) {
		return Double.doubleToLongBits(a) == Double.doubleToLongBits(b);
	}
	public static boolean notEqualFloat64(double a, double b) {
		return !equalFloat64(a, b);
	}
	public static boolean equalFloat64IEEE(double a, double b) {
		return a == b;
	}
	public static byte compareFloat64(double a, double b) {
		return lessFloat64(a, b) ? (byte) 0 : lessFloat64(b, a) ? (byte) 2 : (byte) 1;
	}
	public static byte compareFloat64IEEE(double a, double b) {
		return a < b ? (byte) 0 : a > b ? (byte) 2 : (byte) 1;
	}
	public static boolean lessFloat64(double a, double b) {
		return a < b || isNegative0(a) && isPositive0(b) || Double.isNaN(a) && !Double.isNaN(b);
	}
	public static boolean lessFloat64IEEE(double a, double b) {
		return a < b;
	}
	public static boolean lessOrEqualFloat64(double a, double b) {
		return equalFloat64(a, b) || lessFloat64(a, b);
	}
	public static boolean greaterFloat64(double a, double b) {
		return lessFloat64(b, a);
	}
	public static boolean greaterOrEqualFloat64(double a, double b) {
		return equalFloat64(a, b) || greaterFloat64(a, b);
	}

	public static byte divideUnsigned(byte a, byte b) {
		return (byte) (Byte.toUnsignedInt(a) / Byte.toUnsignedInt(b));
	}
	public static short divideUnsigned(short a, short b) {
		return (short) (Short.toUnsignedInt(a) / Short.toUnsignedInt(b));
	}
	public static byte remainderUnsigned(byte a, byte b) {
		return (byte) (Byte.toUnsignedInt(a) % Byte.toUnsignedInt(b));
	}
	public static short remainderUnsigned(short a, short b) {
		return (short) (Short.toUnsignedInt(a) % Short.toUnsignedInt(b));
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

	public static float float32FromNat64(long a) {
		return a < 0 ? (float) (a & Long.MAX_VALUE) + 0x1p63f : (float) a;
	}
	public static double float64FromNat64(long a) {
		return a < 0 ? (double) (a & Long.MAX_VALUE) + 0x1p63 : (double) a;
	}

	public static java.lang.ref.WeakReference<?> newWeakRef(Object a) {
		return new java.lang.ref.WeakReference<>(a);
	}
	public static Object weakRefGet(java.lang.ref.WeakReference<?> a) {
		return a == null ? null : a.get();
	}

	public static byte rotateLeftNat8(byte a, byte b) {
		int n = b & 0b111;
		return (byte) (((a & 0xff) << n) | ((a & 0xff) >>> (8 - n)));
	}
	public static short rotateLeftNat16(short a, short b) {
		int n = b & 0b1111;
		return (short) (((a & 0xffff) << n) | ((a & 0xffff) >>> (16 - n)));
	}
	public static long rotateLeftNat64(long a, long b) {
		return Long.rotateLeft(a, (int) b);
	}
	public static byte rotateRightNat8(byte a, byte b) {
		int n = b & 0b111;
		return (byte) (((a & 0xff) >>> n) | ((a & 0xff) << (8 - n)));
	}
	public static short rotateRightNat16(short a, short b) {
		int n = b & 0b1111;
		return (short) (((a & 0xffff) >>> n) | ((a & 0xffff) << (16 - n)));
	}
	public static long rotateRightNat64(long a, long b) {
		return Long.rotateRight(a, (int) b);
	}
}
