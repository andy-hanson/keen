class ThreadLocalReentrantLock extends ThreadLocal<java.util.concurrent.locks.ReentrantLock> {
	@Override protected java.util.concurrent.locks.ReentrantLock initialValue() {
		java.util.concurrent.locks.ReentrantLock res = new java.util.concurrent.locks.ReentrantLock();
		res.lock();
		return res;
	}
}
