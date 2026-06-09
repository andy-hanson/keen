package org.example;

public class Example {
	public static int staticField;
	public int instanceField;

	public Example(int init) { instanceField = init; }

	public static void staticMethod(int[] x) {
		x[0] = 7;
		x[1] = 7;
		x[2] = 7;
	}

	public int instanceMethod() { return instanceField; }
}
